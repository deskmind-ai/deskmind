// The helper's chat-session ops (Helper/SessionHost.swift) on a socket of their own, for tests/e2e/session.sh: the
// same SessionHost.serve the helper's socket calls, with `harness.mjs session` processes on the simulated computer
// and a fake model service on localhost (fake_model.py). Nothing on this Mac is driven; nothing touches the real
// Application Support folder.
//
//   SessionE2E serve <socket> <dir> <node> <harness.mjs> <idle seconds>   (LOCAL_URL / LOCAL_API_KEY passed on)
//   SessionE2E lock <dir>                                                  the machine lock's protocol, real groups
//   SessionE2E linger <dir>                                                a finished run's undo on the lock
//   SessionE2E holdrun <dir>                                               hold the Mac with a run (to be SIGKILLed)
//   SessionE2E tryacquire <dir>                                            one acquire: ok | busy | alive
//
// `serve` adds test ops beside the session ops: `e2e.ui` (what the live card and the recording were driven with, by
// run), `e2e.state` (SessionHost.taskRunning), `e2e.acquire {run_id}` (an op run that starts on the lock and is over
// at once: ok, or computer_busy).
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
        if a.count == 3, a[1] == "holdrun" { holdRun(dir: a[2]) }
        if a.count == 3, a[1] == "tryacquire" { tryAcquire(dir: a[2]) }
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
        case "e2e.acquire":
            let run = req["run_id"] as? String ?? "run_e2e"
            let p = executor("true")
            switch start(run, p) {
            case .ok: p.waitUntilExit(); ComputerLock.free(runID: run, pgid: p.processIdentifier); return ["ok": true]
            case .busy(let h): return ["ok": false, "code": "computer_busy", "held_by": h.runID]
            case .alive(let h): return ["ok": false, "code": "previous_run_alive", "held_by": h.runID]
            case .failed(let why): return ["ok": false, "error": why]
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

    static func setup(_ dir: String) {
        SessionHost.setup = .init(node: URL(fileURLWithPath: "/"), bundle: URL(fileURLWithPath: "/"), dir: URL(fileURLWithPath: dir), cwd: nil,
                                  logs: URL(fileURLWithPath: dir), environment: { [:] }, prepare: {}, idleSeconds: 300)
    }

    static func until(_ f: () -> Bool, _ s: Double = 5) -> Bool {
        let t = Date().addingTimeInterval(s)
        while Date() < t { if f() { return true }; Thread.sleep(forTimeInterval: 0.02) }
        return f()
    }

    /// A stand-in executor: /bin/sh running `script`, the leader of its own process group (as Process starts a child).
    static func executor(_ script: String, stdin: Pipe? = nil) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        if let stdin { p.standardInput = stdin }
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        return p
    }

    /// Acquire for `run` with `p` as its executor; nil when refused.
    static func start(_ run: String, _ p: Process, by: String = "helper", hold: Double = 0) -> ComputerLock.Acquired {
        ComputerLock.acquire(runID: run, by: by, spawn: {
            do { try p.run() } catch { return nil }
            if hold > 0 { Thread.sleep(forTimeInterval: hold) }   // still inside the guard
            return p.processIdentifier
        })
    }

    static func killGroup(_ pgid: Int32) { Darwin.kill(-pgid, SIGKILL) }

    /// The machine lock's protocol on real process groups (ComputerLock; harness docs/protocol.md 「电脑锁」).
    static func lock(dir: String) {
        setup(dir)
        let fm = FileManager.default
        try? fm.removeItem(at: ComputerLock.file)
        let a = executor("sleep 30")
        guard case .ok(let h?) = start("run_a", a) else { check(false, "a free Mac is taken"); exit(1) }
        check(h.acting && h.pgid == a.processIdentifier && h.start == ComputerLock.startOf(a.processIdentifier) && h.owner == getpid(),
              "the holder is the executor's group, acting, written before its task is sent: \(h)")
        check(ComputerLock.read() == h, "as read back from the file")
        var spawned = false
        if case .busy(let b) = ComputerLock.acquire(runID: "run_b", by: "helper", spawn: { spawned = true; return nil }), b.runID == "run_a", !spawned {
            check(true, "a holder that acts refuses the next task, which starts nothing")
        } else { check(false, "a holder that acts refuses the next task, which starts nothing") }

        // its task_done: lingering; the next task ends its group (deaf to SIGTERM: SIGKILL), its undo expiring
        check(ComputerLock.linger(runID: "run_a", pgid: a.processIdentifier) && ComputerLock.read()?.state == "lingering", "task_done: lingering")
        killGroup(a.processIdentifier); a.waitUntilExit()
        let deaf = executor("trap '' TERM; while :; do sleep 0.1; done")
        _ = start("run_d", deaf)
        ComputerLock.linger(runID: "run_d", pgid: deaf.processIdentifier)
        let c = executor("sleep 30")
        if case .ok(let hc?) = ComputerLock.acquire(runID: "run_c", by: "helper", term: 0.3, kill: 2, spawn: { try? c.run(); return c.processIdentifier }) {
            check(!deaf.isRunning && hc.runID == "run_c", "a lingering run is ended (SIGTERM ignored: SIGKILL) and the new task takes the Mac")
        } else { check(false, "a lingering run is ended and the new task takes the Mac") }

        // undo: only its own lingering run; it acts again until its result_response
        check(ComputerLock.undo(runID: "run_c", pgid: c.processIdentifier) == .busy, "no undo before its task_done")
        ComputerLock.linger(runID: "run_c", pgid: c.processIdentifier)
        check(ComputerLock.undo(runID: "run_x", pgid: c.processIdentifier) == .expired, "another run's undo: expired")
        check(ComputerLock.undo(runID: "run_c", pgid: c.processIdentifier) == .ok && ComputerLock.read()?.acting == true, "its own: acting again")
        if case .busy = start("run_e", executor("true")) { check(true, "a new task is refused while an undo acts") } else { check(false, "a new task is refused while an undo acts") }
        killGroup(c.processIdentifier); c.waitUntilExit()

        // an executor that exits leaving a child: the group holds the Mac, acting; free keeps it; gone: free removes it
        let leaving = executor("sleep 30 & exit 0")
        _ = start("run_l", leaving)
        leaving.waitUntilExit()
        let hl = ComputerLock.read()!
        ComputerLock.free(runID: "run_l", pgid: leaving.processIdentifier)
        check(ComputerLock.held(hl) && ComputerLock.read() == hl, "its executor gone, its child up: still held, acting")
        if case .busy = start("run_f", executor("true")) { check(true, "the next task is refused") } else { check(false, "the next task is refused") }
        killGroup(leaving.processIdentifier)
        check(until { !ComputerLock.held(hl) }, "the child gone: nothing holds it")
        ComputerLock.free(runID: "run_l", pgid: leaving.processIdentifier)
        check(!fm.fileExists(atPath: ComputerLock.file.path), "and its owner removes it")

        // a holder with another start time (the group id reused): nothing holds it
        let g = executor("sleep 30"); _ = start("run_g", g)
        var stale = ComputerLock.read()!; stale.start -= 3600
        check(!ComputerLock.held(stale) && ComputerLock.held(ComputerLock.read()!), "a reused id (another start time) holds nothing")
        killGroup(g.processIdentifier); g.waitUntilExit()

        // orphaned: acting, its owner (a killed helper) and its leader gone, a child of its group up -- refused for
        // orphanSeconds (the first look marks it), then ended by the next task
        try? fm.removeItem(at: ComputerLock.file)
        let orphanLeader = executor("sleep 30 & exit 0")
        try? orphanLeader.run(); orphanLeader.waitUntilExit()
        let og = orphanLeader.processIdentifier
        let orphan = SessionWire.Holder(state: "acting", pgid: og, pid: og, start: 0, runID: "run_orphan", sessionID: "", by: "helper", owner: 99_999_99, t: 0)
        try? orphan.json.write(to: ComputerLock.file)
        let t0 = Date().timeIntervalSince1970
        let firstLook = ComputerLock.acquire(runID: "run_o1", by: "helper", now: t0, spawn: { nil })
        if case .busy = firstLook, ComputerLock.read()?.orphanSince == t0 { check(true, "an orphaned holder: refused at first, marked") }
        else { check(false, "an orphaned holder: refused at first, marked (\(String(describing: ComputerLock.read())))") }
        if case .busy = ComputerLock.acquire(runID: "run_o2", by: "helper", now: t0 + ComputerLock.orphanSeconds - 1, spawn: { nil }) { check(true, "still refused within the grace") }
        else { check(false, "still refused within the grace") }
        let after = executor("sleep 30")
        if case .ok(let ha?) = ComputerLock.acquire(runID: "run_o3", by: "helper", term: 0.5, kill: 1, now: t0 + ComputerLock.orphanSeconds,
                                                    spawn: { try? after.run(); return after.processIdentifier }) {
            check(ha.runID == "run_o3" && !ComputerLock.groupAlive(og), "after the grace the next task ends it and takes the Mac")
        } else { check(false, "after the grace the next task ends it and takes the Mac") }
        killGroup(after.processIdentifier); after.waitUntilExit()
        // a live owner's acting run is never orphaned, even with its leader gone and a child of its group up
        let mine = executor("sleep 30 & exit 0")
        _ = start("run_live", mine)
        mine.waitUntilExit()
        let tLive = Date().timeIntervalSince1970
        if case .busy = ComputerLock.acquire(runID: "run_l2", by: "helper", now: tLive, spawn: { nil }),
           case .busy = ComputerLock.acquire(runID: "run_l3", by: "helper", now: tLive + 999, spawn: { nil }),
           ComputerLock.read()?.orphanSince == nil {
            check(true, "a live owner's run (its leader gone, a child up): refused, never orphaned")
        } else { check(false, "a live owner's run (its leader gone, a child up): refused, never orphaned") }
        killGroup(mine.processIdentifier)

        // the lock cannot be written (a folder in its place): the task is refused and what it started is ended
        try? fm.removeItem(at: ComputerLock.file)
        try? fm.createDirectory(at: ComputerLock.file.appendingPathComponent("x"), withIntermediateDirectories: true)
        let unrecorded = executor("sleep 30")
        if case .failed = start("run_w", unrecorded) {
            check(until { !unrecorded.isRunning }, "an unwritable lock: refused, and the started process ended (it must not act unrecorded)")
        } else { check(false, "an unwritable lock: refused") }
        try? fm.removeItem(at: ComputerLock.file)

        // two op runs at once (forced interleaving): B asks while A is inside the guard, its executor started and not
        // yet written. B waits for the guard, then finds A acting: busy -- nothing of A's is ended.
        try? fm.removeItem(at: ComputerLock.file)
        let ea = executor("sleep 30")
        var ra: ComputerLock.Acquired?, rb: ComputerLock.Acquired?
        let both = DispatchGroup()
        DispatchQueue.global().async(group: both) { ra = start("run_A", ea, hold: 0.8) }
        Thread.sleep(forTimeInterval: 0.3)
        DispatchQueue.global().async(group: both) { rb = start("run_B", executor("sleep 30")) }
        both.wait()
        if case .ok(_?) = ra, case .busy(let hb) = rb { check(hb.runID == "run_A" && ea.isRunning, "two at once: A takes the Mac, B is busy, A's executor untouched") }
        else { check(false, "two at once: A takes the Mac, B is busy (\(String(describing: ra)), \(String(describing: rb)))") }
        killGroup(ea.processIdentifier)
        print(failures == 0 ? "lock: all passed" : "lock: \(failures) failed")
        exit(Int32(min(failures, 100)))
    }

    /// The old path's finished run (HarnessRun.Lingering, op respond) on the lock, with a stand-in harness (`cat`
    /// waiting on its stdin, as a lingering run does).
    static func linger(dir: String) {
        setup(dir)
        let fm = FileManager.default
        try? fm.removeItem(at: ComputerLock.file)
        /// a run of this helper's: started on the lock, its task_done passed to the app through HarnessRun.pass
        func run(_ id: String, onDone: @escaping ([String: Any]) -> Void = { _ in }) -> HarnessRun.Lingering? {
            let input = Pipe()
            let p = executor("cat > /dev/null", stdin: input)
            guard case .ok(_?) = start(id, p) else { check(false, "\(id) starts"); return nil }
            let l = HarnessRun.Lingering(process: p, input: input.fileHandleForWriting)
            l.runID = id
            HarnessRun.pass(["event": "task_done", "run_id": id], linger: l) { ev in onDone(ev); return true }
            Thread.detachNewThread { HarnessRun.watchLingering(l) }
            return l
        }
        // an undo clicked the moment task_done reaches the app
        var atOnce: [String: Any] = [:]
        var stateThen = ""
        guard let l1 = run("run_old", onDone: { ev in
            stateThen = ComputerLock.read()?.state ?? "none"
            atOnce = HarnessRun.respond(runID: ev["run_id"] as? String ?? "", option: 1)
        }) else { exit(1) }
        check(stateThen == "lingering" && atOnce["ok"] as? Bool == true, "an undo right at task_done is let through (the lock said lingering first): \(atOnce)")
        check(ComputerLock.read()?.acting == true, "the undo acts: the lock says acting")
        if case .busy = start("run_session", executor("true"), by: "session") { check(true, "no task starts during the undo") } else { check(false, "no task starts during the undo") }
        let twice = HarnessRun.respond(runID: "run_old", option: 1)
        check(twice["code"] as? String == "busy", "one answer per card: \(twice)")
        check(HarnessRun.undoWaiting, "its process lingers: a restart waits")
        l1.process.terminate()
        check(until { !fm.fileExists(atPath: ComputerLock.file.path) && !HarnessRun.undoWaiting }, "its process gone: the lock goes with it")

        // a new task on this Mac (a session's, here) ends the lingering run: its undo expired
        guard let l2 = run("run_two") else { exit(1) }
        check(ComputerLock.read()?.state == "lingering" && HarnessRun.undoWaiting, "lingering for its card")
        let s = executor("sleep 30")
        if case .ok(_?) = start("run_ses", s, by: "session") { check(!l2.process.isRunning, "a new task ends the lingering run first") }
        else { check(false, "a new task ends the lingering run first") }
        check(until { HarnessRun.lingering == nil && !HarnessRun.undoWaiting }, "and the helper lets it go")
        let late = HarnessRun.respond(runID: "run_two", option: 1)
        check(late["code"] as? String == "undo_expired", "its undo, asked afterwards: undo_expired (\(late))")
        killGroup(s.processIdentifier)
        print(failures == 0 ? "linger: all passed" : "linger: \(failures) failed")
        exit(Int32(min(failures, 100)))
    }

    /// A helper's run that holds the Mac, for a test that kills this process outright (SIGKILL): its executor (a group
    /// whose leader starts a child) outlives it. Prints the group id, then waits.
    static func holdRun(dir: String) {
        setup(dir)
        let p = executor("sleep 300 & sleep 300")
        guard case .ok(let h?) = start("run_held", p) else { print("refused"); exit(1) }
        print(h.pgid); fflush(stdout)
        while true { Thread.sleep(forTimeInterval: 60) }
    }

    /// One acquire, as a new helper's op run would: prints ok, busy or alive.
    static func tryAcquire(dir: String) {
        setup(dir)
        let p = executor("true")
        switch start("run_try", p) {
        case .ok: print("ok")
        case .busy(let h): print("busy \(h.runID)")
        case .alive(let h): print("alive \(h.runID)")
        case .failed(let why): print("failed \(why)")
        }
        exit(0)
    }
}
