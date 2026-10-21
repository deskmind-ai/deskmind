// The helper's chat-session ops (Helper/SessionHost.swift) on a socket of their own, for tests/e2e/session.sh: the
// same SessionHost.serve the helper's socket calls, with `harness.mjs session` processes on the simulated computer
// and a fake model service on localhost (fake_model.py). Nothing on this Mac is driven; nothing touches the real
// Application Support folder.
//
//   SessionE2E serve <socket> <dir> <node> <harness.mjs> <idle seconds>   (LOCAL_URL / LOCAL_API_KEY passed on)
//   SessionE2E lock <dir>                                                  the machine lock: take, busy, stale
//   SessionE2E linger <dir>                                                a finished run's undo: lock, expiry
//   SessionE2E leftover <dir>                                              what an ended session or run leaves up
//
// `serve` adds test ops beside the session ops: `e2e.ui` (what the live card and the recording were driven with, by
// run), `e2e.state` (SessionHost.taskRunning), `e2e.begin {run_id}` (what `op run` does as it starts: the machine lock
// and computer.last, the lock let go again at once, as at its task_done).
// `lock` and `linger` print PASS or FAIL per check; their exit status is the number of failures.

import AppKit
import Foundation

@main
enum SessionE2E {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL") \(what)")
        if !ok { failures += 1 }
    }

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let a = CommandLine.arguments
        if a.count == 3, a[1] == "lock" { lock(dir: a[2]) }
        if a.count == 3, a[1] == "linger" { linger(dir: a[2]) }
        if a.count == 3, a[1] == "leftover" { leftover(dir: a[2]) }
        guard a.count == 7, a[1] == "serve" else {
            print("usage: SessionE2E serve <socket> <dir> <node> <harness.mjs> <idle s> | lock <dir>"); exit(2)
        }
        let dir = URL(fileURLWithPath: a[3])
        let pass = ProcessInfo.processInfo.environment.filter { ["LOCAL_URL", "LOCAL_API_KEY", "TMPDIR"].contains($0.key) }
        SessionHost.setup = .init(node: URL(fileURLWithPath: a[4]), bundle: URL(fileURLWithPath: a[5]), dir: dir, cwd: nil,
                                  logs: dir.appendingPathComponent("logs"),
                                  environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"].merging(pass) { x, _ in x } },
                                  prepare: {}, idleSeconds: Double(a[6]) ?? 300, driver: "sim")
        SessionHost.setup.ui = .init(start: { run, _, _ in note(run, "start") }, show: { run, ev in note(run, "show", ev) },
                                     record: { run, ev in note(run, "record", ev) }, finish: { run, st in note(run, "finish", ["status": "\(String(describing: st))"]) })
        serve(path: a[2])
    }

    // what the live card and the recording were driven with
    nonisolated(unsafe) static var ui: [[String: Any]] = []
    static let uiLock = NSLock()
    static func note(_ run: String, _ what: String, _ ev: [String: Any] = [:]) {
        uiLock.lock(); ui.append(["run_id": run, "what": what, "event": ev["event"] ?? ev["status"] ?? ""]); uiLock.unlock()
    }

    static func testOp(_ req: [String: Any]) -> [String: Any]? {
        switch req["op"] as? String {
        case "e2e.ui":
            uiLock.lock(); defer { uiLock.unlock() }
            return ["ok": true, "ui": ui]
        case "e2e.state":
            return ["ok": true, "task_running": SessionHost.taskRunning]
        case "e2e.begin":
            switch ComputerLock.begin(runID: req["run_id"] as? String ?? "run_e2e") {
            case .taken(let release): release(); return ["ok": true]
            case .busy(let held): return ["ok": false, "code": "computer_busy", "held": held]
            case .failed(let why), .unrecorded(let why): return ["ok": false, "error": why]
            }
        default: return nil
        }
    }

    /// The helper's accept loop (HandsHelper.serve), with only the session ops behind it.
    static func serve(path: String) {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
        guard bound, listen(fd, 8) == 0 else { print("cannot listen on \(path)"); exit(1) }
        print("listening"); fflush(stdout)
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { continue }
            DispatchQueue.global().async {
                defer { close(c) }
                var data = Data()
                var buf = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(c, &buf, buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                    if buf[..<n].contains(0x0A) { break }
                }
                let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if SessionHost.serve(req, fd: c) { return }
                if let r = testOp(req), var out = try? JSONSerialization.data(withJSONObject: r) {
                    out.append(0x0A); _ = SessionHost.writeAll(c, out); return
                }
                _ = SessionHost.writeAll(c, Data(#"{"ok":false,"error":"unknown op"}"#.utf8 + [0x0A]))
            }
        }
    }

    /// ComputerLock against a lock file in `dir`: taken when free, busy while a live process holds it (a session, or
    /// only its executor), taken over when its holders are gone, and released only while it is still ours.
    static func lock(dir: String) {
        SessionHost.setup = .init(node: URL(fileURLWithPath: "/"), bundle: URL(fileURLWithPath: "/"), dir: URL(fileURLWithPath: dir), cwd: nil,
                                  logs: URL(fileURLWithPath: dir), environment: { [:] }, prepare: {}, idleSeconds: 300)
        let file = ComputerLock.file.path
        try? FileManager.default.removeItem(atPath: file)
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        func content() -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file)))) as? [String: Any] ?? [:]
        }
        guard case .taken(let release) = ComputerLock.take(runID: "run_t") else { check(false, "a free lock is taken"); exit(1) }
        check(content()["pid"] as? Int == me && content()["run_id"] as? String == "run_t", "it names this process: \(content())")
        check(ComputerLock.holder() != nil, "held")
        if case .busy = ComputerLock.take(runID: "run_2") { check(true, "a second take is busy") } else { check(false, "a second take is busy") }
        release()
        check(!FileManager.default.fileExists(atPath: file), "released")
        // a lock whose holders are gone (a pid that is no process)
        var dead: Int32 = 99_999
        while ComputerLock.alive(dead) { dead -= 1 }
        try? #"{"pid":\#(dead),"session_id":"ses_old","run_id":"run_old"}"#.write(toFile: file, atomically: true, encoding: .utf8)
        check(ComputerLock.holder() == nil, "a dead holder holds nothing")
        if case .taken(let r) = ComputerLock.take(runID: "run_3") {
            check(content()["run_id"] as? String == "run_3", "a stale lock is taken over"); r()
        } else { check(false, "a stale lock is taken over") }
        // a live holder: the session (pid 1 stands for a live process this user cannot signal), or only its executor
        for (text, what) in [(#"{"pid":1,"session_id":"s","run_id":"r"}"#, "a live session"),
                             (#"{"pid":\#(dead),"session_id":"s","run_id":"r","executor_pid":1}"#, "a killed session's executor still stopping")] {
            try? text.write(toFile: file, atomically: true, encoding: .utf8)
            if case .busy = ComputerLock.take(runID: "run_4") { check(true, "busy while \(what) holds it") } else { check(false, "busy while \(what) holds it") }
            check((try? String(contentsOfFile: file, encoding: .utf8)) == text, "\(what): its lock untouched")
        }
        // released only while ours: a lock replaced meanwhile is left alone
        if case .taken(let r) = { try? FileManager.default.removeItem(atPath: file); return ComputerLock.take(runID: "run_5") }() {
            let other = #"{"pid":1,"session_id":"other","run_id":"r"}"#
            try? other.write(toFile: file, atomically: true, encoding: .utf8)
            r()
            check((try? String(contentsOfFile: file, encoding: .utf8)) == other, "a release leaves another's lock")
        } else { check(false, "taken again") }
        try? FileManager.default.removeItem(atPath: file)
        print(failures == 0 ? "lock: all passed" : "lock: \(failures) failed")
        exit(Int32(min(failures, 100)))
    }

    /// The old path's finished run (HarnessRun.Lingering, op respond) with a stand-in process (`cat`, which waits on its
    /// stdin as a lingering harness run does): its answer takes the machine lock (refused while another holds it), one
    /// answer per card, the lock goes with the process; and its undo expires once computer.last names another task —
    /// at the answer, and by itself while it lingers.
    static func linger(dir: String) {
        SessionHost.setup = .init(node: URL(fileURLWithPath: "/"), bundle: URL(fileURLWithPath: "/"), dir: URL(fileURLWithPath: dir), cwd: nil,
                                  logs: URL(fileURLWithPath: dir), environment: { [:] }, prepare: {}, idleSeconds: 300)
        let fm = FileManager.default
        try? fm.removeItem(atPath: ComputerLock.file.path); try? fm.removeItem(atPath: ComputerLock.lastFile.path)
        HarnessRun.lastEvery = 0.05
        func content() -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: ComputerLock.file))) as? [String: Any] ?? [:]
        }
        func until(_ f: () -> Bool, _ s: Double = 5) -> Bool {
            let t = Date().addingTimeInterval(s)
            while Date() < t { if f() { return true }; Thread.sleep(forTimeInterval: 0.02) }
            return f()
        }
        /// a finished run `run` of this helper's, lingering: begun (lock + computer.last), lock let go at its task_done
        func lingering(_ run: String) -> (HarnessRun.Lingering, Thread)? {
            guard case .taken(let release) = ComputerLock.begin(runID: run) else { check(false, "\(run) begins"); return nil }
            release()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/cat")
            let inPipe = Pipe()
            p.standardInput = inPipe; p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch { check(false, "cat: \(error)"); return nil }
            let l = HarnessRun.Lingering(process: p, input: inPipe.fileHandleForWriting)
            l.runID = run
            HarnessRun.lingering = l
            let t = Thread { HarnessRun.watchLingering(l) }
            t.start()
            return (l, t)
        }

        check(ComputerLock.lastRunID() == nil, "no task yet: computer.last names none")
        guard let (l1, _) = lingering("run_old") else { exit(1) }
        check(ComputerLock.lastRunID() == "run_old" && !fm.fileExists(atPath: ComputerLock.file.path), "op run's start names it in computer.last; the lock went at its task_done")
        check(HarnessRun.undoWaiting, "its undo can be asked for: a restart waits (undoWaiting)")
        // another task holds the Mac (a live process): the answer is refused, its lock untouched
        let other = #"{"pid":1,"session_id":"ses_x","run_id":"run_x"}"#
        try? other.write(to: ComputerLock.file, atomically: true, encoding: .utf8)
        let busy = HarnessRun.respond(runID: "run_old", option: 1)
        check(busy["code"] as? String == "computer_busy" && (try? String(contentsOf: ComputerLock.file, encoding: .utf8)) == other,
              "an undo while another task holds the Mac: computer_busy, its lock untouched (\(busy))")
        try? fm.removeItem(at: ComputerLock.file)
        // free: the answer takes the lock, for this run's undo, held by the lingering process too
        let r = HarnessRun.respond(runID: "run_old", option: 1)
        let c = content()
        check(r["ok"] as? Bool == true && c["run_id"] as? String == "run_old" && c["undo"] as? Bool == true
              && c["executor_pid"] as? Int == Int(l1.process.processIdentifier), "the undo holds the machine lock while it acts: \(c)")
        if case .busy = ComputerLock.begin(runID: "run_session") { check(true, "no task starts during the undo") } else { check(false, "no task starts during the undo") }
        check(ComputerLock.lastRunID() == "run_old", "and computer.last is left alone")
        let twice = HarnessRun.respond(runID: "run_old", option: 1)
        check(twice["ok"] as? Bool == false && twice["code"] as? String == "busy", "one answer per card: \(twice)")
        // its process ends (the undo done, or its linger over): the lock goes with it
        l1.process.terminate()
        check(until { !fm.fileExists(atPath: ComputerLock.file.path) && !HarnessRun.undoWaiting }, "the process gone: the lock let go, nothing lingers")

        // undo expires when another computer task starts on this Mac: at the answer...
        HarnessRun.lastEvery = 30   // its watch asleep: the answer itself finds it out
        guard let (l2, _) = lingering("run_two") else { exit(1) }
        try? ComputerLock.setLast("run_ses")   // a session's task began (harness setLastTask)
        let expired = HarnessRun.respond(runID: "run_two", option: 1)
        check(expired["code"] as? String == "undo_expired" && !fm.fileExists(atPath: ComputerLock.file.path), "an undo after another task began: undo_expired, the Mac not taken (\(expired))")
        check(until { !l2.process.isRunning } && !HarnessRun.undoWaiting, "and the finished run is let go (its stdin closed, it exits)")
        HarnessRun.lastEvery = 0.05

        // ...and by itself while it lingers (a session's task, or a new op run, names itself in computer.last)
        guard let (l3, _) = lingering("run_three") else { exit(1) }
        check(HarnessRun.undoWaiting, "lingering again")
        if case .taken(let rel) = ComputerLock.begin(runID: "run_next") { rel() }
        check(until { !l3.process.isRunning } && HarnessRun.lingering == nil && !HarnessRun.undoWaiting, "a new task began: the lingering run is let go by itself")
        let late = HarnessRun.respond(runID: "run_three", option: 1)
        check(late["ok"] as? Bool == false && late["code"] as? String == "undo_expired", "its undo is gone, and said so: \(late)")
        // computer.last cannot be written (here: a folder in its place): the task does not start, and the lock is let go
        try? fm.removeItem(at: ComputerLock.lastFile)
        try? fm.createDirectory(at: ComputerLock.lastFile.appendingPathComponent("x"), withIntermediateDirectories: true)
        if case .unrecorded = ComputerLock.begin(runID: "run_unrecorded") { check(true, "computer.last not written: unrecorded") }
        else { check(false, "computer.last not written: unrecorded") }
        check(!fm.fileExists(atPath: ComputerLock.file.path), "and the lock let go: nothing starts under it")
        try? fm.removeItem(at: ComputerLock.lastFile)
        print(failures == 0 ? "linger: all passed" : "linger: \(failures) failed")
        exit(Int32(min(failures, 100)))
    }

    /// A session process that ends while its task's executor is still up (a stand-in: /bin/sh that starts a child
    /// ignoring SIGTERM, then exits at stdin's end), on each way a session ends (`end`, idle, the helper exiting), and
    /// an op run whose harness exits leaving a child: the helper keeps track of what is left, holds the machine lock
    /// while it is up (a session's task is refused), and its own next run ends it first or is refused.
    static func leftover(dir: String) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: dir)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("fake-session.sh")
        // the session protocol's first line, an "executor" left behind, then wait for stdin's end
        try? #"""
        echo '{"kind":"session.start","last_seq":0,"resumed":false}'
        ( trap '' TERM; exec sleep 300 ) </dev/null >/dev/null 2>&1 &
        echo $! > "$EXECUTOR_PID"
        cat > /dev/null
        exit 0
        """#.write(to: script, atomically: true, encoding: .utf8)
        let pidFile = root.appendingPathComponent("executor.pid")
        SessionHost.setup = .init(node: URL(fileURLWithPath: "/bin/sh"), bundle: script, dir: root, cwd: nil,
                                  logs: root.appendingPathComponent("logs"),
                                  environment: { ["PATH": "/usr/bin:/bin", "EXECUTOR_PID": pidFile.path] },
                                  prepare: {}, idleSeconds: 1)
        SessionHost.setup.ui = .init(start: { _, _, _ in }, show: { _, _ in }, record: { _, _ in }, finish: { _, _ in })
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        func until(_ f: () -> Bool, _ s: Double = 10) -> Bool {
            let t = Date().addingTimeInterval(s)
            while Date() < t { if f() { return true }; Thread.sleep(forTimeInterval: 0.05) }
            return f()
        }
        func owner() -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: ComputerLock.file))) as? [String: Any] ?? [:]
        }
        func executor() -> pid_t { pid_t((try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 }
        func helperHolds() -> Bool { ComputerLock.holder() != nil && owner()["pid"] as? Int == me }
        func sessionTaskRefused() -> Bool { if case .busy = ComputerLock.take(runID: "run_session") { return true }; return false }
        /// open the fake session, wait for its executor; nil when it did not start
        func open(_ id: String) -> pid_t? {
            try? fm.removeItem(at: pidFile)
            let r = SessionHost.open(["session_id": id])
            SessionHost.setup.idleSeconds = id == "ses_idle" ? 1 : 300   // only that one is let go as idle
            guard r["ok"] as? Bool == true, until({ executor() > 0 }) else { check(false, "\(id) opens: \(r)"); return nil }
            Thread.sleep(forTimeInterval: 0.6)   // the tree has been looked at with the executor in it
            return executor()
        }

        // 1. session.end while its executor is up: tracked, the Mac held; the next op run ends it
        guard let ex1 = open("ses_end") else { exit(1) }
        check(ComputerLock.holder() == nil, "a session with nothing running holds nothing")
        _ = SessionHost.end(sessionID: "ses_end")
        check(until { helperHolds() && HarnessRun.acting }, "session.end, its executor still up: the helper holds the Mac for it (\(owner()))")
        check(ComputerLock.alive(ex1) && sessionTaskRefused(), "a session's task is refused meanwhile (computer_busy)")
        check(!HarnessRun.closeLingering(grace: 0.1, term: 0.1, kill: 0.1, signal: { _, _ in 0 }) && ComputerLock.alive(ex1),
              "an op run whose kill does not take: refused (previous_run_alive), still tracked")
        check(HarnessRun.acting && helperHolds(), "and the Mac still held")
        check(HarnessRun.closeLingering(grace: 0.1, term: 0.3, kill: 2) && !ComputerLock.alive(ex1), "the next op run ends it first")
        ActingGuard.drop()
        check(!HarnessRun.acting && ComputerLock.holder() == nil, "then nothing acts, the Mac is free")

        // 2. closed as idle (stdin closed by the reaper), the executor then exits by itself: the lock goes with it
        guard let ex2 = open("ses_idle") else { exit(1) }
        check(until({ ComputerLock.holder() != nil }, 20) && helperHolds() && ComputerLock.alive(ex2), "closed as idle, its executor up: the Mac held")
        kill(ex2, SIGKILL)
        check(until { ComputerLock.holder() == nil && !HarnessRun.acting }, "the executor gone by itself: the lock let go")

        // 3. the helper exiting (SessionHost.shutdown): no executor left behind
        guard let ex3 = open("ses_exit") else { exit(1) }
        SessionHost.shutdown(wait: 1)
        check(until { !ComputerLock.alive(ex3) }, "the helper exiting ends what its sessions left (SIGTERM ignored: SIGKILL)")

        // 4. an op run whose harness exits leaving a child up (vice versa): the run's lock is kept for it
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "( trap '' TERM; exec sleep 300 ) & echo $! > \"\(pidFile.path)\"; sleep 0.6"]
        try? fm.removeItem(at: pidFile)
        guard case .taken(let release) = ComputerLock.begin(runID: "run_op") else { check(false, "op run begins"); exit(1) }
        try? p.run()
        HarnessRun.record(p)
        p.waitUntilExit()
        let ex4 = executor()
        ActingGuard.start(handing: release)   // the run is over (HandsHelper's defer)
        check(ComputerLock.alive(ex4) && helperHolds() && owner()["run_id"] as? String == "run_op",
              "an op run's harness gone, its child up: the run's lock kept (\(owner()))")
        check(sessionTaskRefused(), "a session's task is refused meanwhile")
        kill(ex4, SIGKILL)
        check(until { ComputerLock.holder() == nil && !HarnessRun.acting }, "the child gone: the Mac free")
        // a run that left nothing: the lock goes at once
        if case .taken(let r) = ComputerLock.begin(runID: "run_clean") { ActingGuard.start(handing: r) }
        check(ComputerLock.holder() == nil, "a run that left nothing up lets the Mac go at its end")
        print(failures == 0 ? "leftover: all passed" : "leftover: \(failures) failed")
        exit(Int32(min(failures, 100)))
    }
}
