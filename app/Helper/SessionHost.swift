// Chat sessions: one `harness.mjs session` process per open session (deskmind-ai/harness docs/protocol.md
// 「会话（第 1 版）」), started by this helper with the harness's environment (HarnessRun.environment: the keys, Brain,
// hands), so the computer tasks a session starts run with this helper's permissions. The main app talks to them over
// the helper's socket:
//
//   session.open  {session_id?, config?, lang?, driver?, scope?, live_view?} → {ok, session_id, resumed, last_seq, pid}
//                 starts the session's process (a known id resumes it; none makes a new one), or finds it running
//   session.send  {session_id, line}     one control line (SessionWire.validate: a JSON object of a known type)
//   session.end   {session_id}           `end`, then stdin closed: a running task is stopped, the process exits
//   sessions.list                        `harness.mjs sessions list`, each marked `open` when its process runs here
//   sessions.watch {after: {session_id: after_seq}, runs?: {run_id: after_seq}}
//                 one long-lived connection: every session's lines (each has its session_id), from the cursors on.
//                 On connect each running session is sent `attach{after_seq}` and replays what is stored after it;
//                 each named task of it (its folder is under the session's runs/) is replayed after its cursor with
//                 `attach{run_id}`, and a task still open from its start when not named (its card may wait). Each
//                 connection gets stored lines in order and once, and a task's lines once (SessionWire.Gate). The
//                 first line is {"kind":"helper.watching","open":[…]}; a process that ends says
//                 {"kind":"helper.session_exit","session_id":…,"code":…}.
//
// Tasks of a session drive the live card and the recording as the helper's own runs do (HarnessRun.show), from the
// executor events the session forwards.
//
// Lifecycle (owner 10-21): the processes are this helper's children. When the helper exits, their stdin reaches its
// end and each stops its running task itself (the harness's "app went away"). The main app closing changes nothing:
// a session keeps its task running and its card waiting. A session with nothing going on (SessionWire.Activity) and no
// watching connection for `idleSeconds` has its stdin closed, and its process exits on its own.

import AppKit
import Foundation

enum SessionHost {
    struct Setup {
        var node: URL
        var bundle: URL
        /// The folder that holds `sessions/` (the harness's `--dir`).
        var dir: URL
        var cwd: URL?
        /// Each session process's stderr: `<session_id>.stderr`.
        var logs: URL
        var environment: () -> [String: String]
        var prepare: () throws -> Void
        /// How long a session with nothing going on and nobody watching stays up.
        var idleSeconds: Double
        /// The driver a session's tasks run on, unless session.open names one (`sim` in tests).
        var driver = "hands"

        static func standard() -> Setup {
            Setup(node: HarnessRun.node, bundle: HarnessRun.bundle, dir: DeskMindIPC.supportDir, cwd: Runner.work,
                  logs: DeskMindIPC.supportDir.appendingPathComponent("work/session-logs"),
                  environment: { HarnessRun.environment() }, prepare: Runner.prepareWork,
                  idleSeconds: max(10, UserDefaults.standard.object(forKey: "sessions.idleSeconds") as? Double ?? 300))
        }
    }
    nonisolated(unsafe) static var setup = Setup.standard()

    static let ops: Set<String> = ["session.open", "session.send", "session.end", "sessions.list", "sessions.watch"]

    // MARK: state (under `lock`)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var sessions: [String: Session] = [:]
    nonisolated(unsafe) private static var opening: Set<String> = []
    nonisolated(unsafe) private static var watchers: [Watcher] = []
    nonisolated(unsafe) private static var reaping = false

    final class Session {
        let id: String
        let process: Process
        private let input: FileHandle
        private let writeLock = NSLock()
        private var inputClosed = false
        // under SessionHost.lock
        var activity = SessionWire.Activity()
        var lastActive = Date()
        var closing = false
        var liveView = false
        /// session.start came: from then on its lines go to the watching connections (before it, a refusal is the
        /// opener's: busy, bad_config).
        var started = false
        var first: [String: Any]?
        let firstLine = DispatchSemaphore(value: 0)
        // the reader thread's own: the live card's view of each task
        var inspect = SessionWire.Gate(after: 0)
        var cards: [String: HarnessEvents.State] = [:]
        var cardRun: String?

        init(id: String, process: Process, input: FileHandle) { self.id = id; self.process = process; self.input = input }

        /// One control line on its stdin; nil, or why it could not be written.
        func write(_ o: [String: Any]) -> String? {
            guard var data = try? JSONSerialization.data(withJSONObject: o) else { return "not JSON" }
            data.append(0x0A)
            writeLock.lock(); defer { writeLock.unlock() }
            if inputClosed { return "the session is closing" }
            do { try input.write(contentsOf: data) } catch { return "write: \(error.localizedDescription)" }
            return nil
        }

        /// stdin's end: the process finishes what it is doing (a running task is stopped) and exits.
        func closeInput() {
            writeLock.lock(); defer { writeLock.unlock() }
            if !inputClosed { inputClosed = true; try? input.close() }
        }
    }

    final class Watcher {
        let fd: Int32
        private let queue = DispatchQueue(label: "ai.deskmind.hands.sessions.watch")
        private var closed = false   // on `queue`
        // under SessionHost.lock
        var gates: [String: SessionWire.Gate] = [:]
        let after: [String: Int]
        /// Per run (a run id is unique across sessions): the last executor seq the app has.
        let runs: [String: Int]

        init(fd: Int32, after: [String: Int], runs: [String: Int]) {
            self.fd = fd; self.after = after; self.runs = runs
        }

        func gate(_ sid: String) -> SessionWire.Gate {
            gates[sid] ?? SessionWire.Gate(after: after[sid] ?? 0, runs: runs)
        }

        /// In order, off the caller's thread. A connection that does not take a line within the socket's send timeout
        /// is dropped (its read side is shut, so its own thread ends the watch).
        func send(_ line: Data) {
            queue.async { [self] in
                guard !closed else { return }
                if !SessionHost.writeAll(fd, line) { closed = true; shutdown(fd, SHUT_RDWR) }
            }
        }

        /// No line is written after this returns: the connection's fd can be closed.
        func finish() { queue.sync { closed = true } }
    }

    /// A session's id is a folder name (harness SESSION_ID).
    static func validID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
    }

    /// A task of some session is running (not yet at its session.task_end): the helper does not restart under it.
    static var taskRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.contains { !$0.activity.running.isEmpty }
    }

    // MARK: the socket

    /// The session ops of a connection (`ops`): the reply written to `fd`, or for sessions.watch the stream, until the
    /// other side closes. False for any other op.
    static func serve(_ req: [String: Any], fd: Int32) -> Bool {
        guard let op = req["op"] as? String, ops.contains(op) else { return false }
        if op == "sessions.watch" { watch(req, fd: fd); return true }
        let reply: [String: Any]
        switch op {
        case "session.open": reply = open(req)
        case "session.send": reply = send(sessionID: req["session_id"] as? String ?? "", line: req["line"])
        case "session.end": reply = end(sessionID: req["session_id"] as? String ?? "")
        default: reply = list()
        }
        var out = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
        out.append(0x0A)
        _ = writeAll(fd, out)
        return true
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    // MARK: ops

    static func open(_ req: [String: Any]) -> [String: Any] {
        let id = (req["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "ses_" + UUID().uuidString.lowercased().prefix(8)
        guard validID(id) else { return ["ok": false, "code": "bad_request", "error": "a session id is letters, digits, _ and -, at most 64"] }
        for k in ["config", "lang", "driver", "scope"] where req[k] != nil && !(req[k] is String) {
            return ["ok": false, "code": "bad_request", "error": "\(k) must be a string"]
        }
        let liveView = req["live_view"] as? Bool
        // one opener per id at a time; a process on its way out is waited for (its lock is the session's)
        let until = Date().addingTimeInterval(20)
        while true {
            lock.lock()
            if let s = sessions[id], s.started, !s.closing {
                if let liveView { s.liveView = liveView }
                s.lastActive = Date()
                lock.unlock()
                return ["ok": true, "session_id": id, "resumed": s.first?["resumed"] as? Bool ?? true, "already_open": true,
                        "pid": Int(s.process.processIdentifier)]
            }
            if sessions[id] == nil && !opening.contains(id) { opening.insert(id); lock.unlock(); break }
            lock.unlock()
            if Date() > until { return ["ok": false, "code": "busy", "error": "session \(id) is still closing"] }
            Thread.sleep(forTimeInterval: 0.1)
        }
        defer { lock.lock(); opening.remove(id); lock.unlock() }
        guard FileManager.default.isExecutableFile(atPath: setup.node.path), FileManager.default.fileExists(atPath: setup.bundle.path) else {
            return ["ok": false, "code": "harness_missing", "error": "this build has no harness runtime"]
        }
        do { try setup.prepare() } catch { return ["ok": false, "error": "prepare: \(error.localizedDescription)"] }
        var header: [String: Any] = ["session_id": id, "driver": req["driver"] as? String ?? setup.driver]
        for k in ["config", "lang", "scope"] { if let v = req[k] as? String { header[k] = v } }
        // A process of this session that outlived the last helper (stopping its task, up to 12 s) still holds the
        // session's lock: the harness says busy and exits; tried again until it has gone.
        while true {
            let s: Session
            do { s = try spawn(id: id, header: header, liveView: liveView ?? false) } catch {
                return ["ok": false, "error": "launch: \(error.localizedDescription)"]
            }
            _ = s.firstLine.wait(timeout: .now() + 20)
            lock.lock(); let first = s.first; lock.unlock()
            if first?["kind"] as? String == "session.start" {
                return ["ok": true, "session_id": id, "resumed": first?["resumed"] as? Bool ?? false, "last_seq": first?["last_seq"] ?? 0,
                        "pid": Int(s.process.processIdentifier)]
            }
            s.closeInput()
            if first?["code"] as? String == "busy" && Date() < until.addingTimeInterval(-0.5) {
                s.process.waitUntilExit()
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            if first == nil && s.process.isRunning { s.process.terminate() }
            return ["ok": false, "code": first?["code"] as? String ?? "no_start",
                    "error": first?["text"] as? String ?? "the session process did not start"]
        }
    }

    private static func spawn(id: String, header: [String: Any], liveView: Bool) throws -> Session {
        let fm = FileManager.default
        try? fm.createDirectory(at: setup.logs, withIntermediateDirectories: true)
        let errURL = setup.logs.appendingPathComponent("\(id).stderr")
        if !fm.fileExists(atPath: errURL.path) { fm.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let err = try? FileHandle(forWritingTo: errURL)
        _ = try? err?.seekToEnd()
        let p = Process()
        p.executableURL = setup.node
        p.arguments = [setup.bundle.path, "session", "--dir", setup.dir.path]
        if let cwd = setup.cwd { p.currentDirectoryURL = cwd }
        p.environment = setup.environment()
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = err ?? FileHandle.nullDevice
        try p.run()
        try? err?.close()
        let s = Session(id: id, process: p, input: inPipe.fileHandleForWriting)
        s.liveView = liveView
        // The header, then a replay for whoever watches: the stored events after the earliest cursor among them. Written
        // under the lock, so a connection that starts watching meanwhile (sessions.watch) writes its attach after the
        // header: a first line with a type is no header, and the session would refuse to start.
        lock.lock()
        sessions[id] = s
        _ = s.write(header)
        var after: Int?
        for w in watchers {
            let a = w.gate(id).after
            after = min(after ?? a, a)
        }
        if let after { _ = s.write(["type": "attach", "after_seq": after]) }
        for w in watchers {
            for (run, n) in w.runs where hasRun(id, run) { _ = s.write(["type": "attach", "run_id": run, "after_seq": n]) }
        }
        startReaper()
        lock.unlock()
        Thread.detachNewThread { read(s, outPipe.fileHandleForReading) }
        return s
    }

    static func send(sessionID: String, line: Any?) -> [String: Any] {
        let v = SessionWire.validate(line)
        guard let o = v.line else { return ["ok": false, "code": "bad_line", "error": v.error ?? "bad line"] }
        lock.lock()
        guard let s = sessions[sessionID], s.started, !s.closing else {
            lock.unlock(); return ["ok": false, "code": "not_open", "error": "session \(sessionID) is not open"]
        }
        s.lastActive = Date()
        lock.unlock()
        if let error = s.write(o) { return ["ok": false, "error": error] }
        return ["ok": true]
    }

    static func end(sessionID: String) -> [String: Any] {
        lock.lock()
        guard let s = sessions[sessionID], !s.closing else {
            lock.unlock(); return ["ok": false, "code": "not_open", "error": "session \(sessionID) is not open"]
        }
        s.closing = true
        lock.unlock()
        _ = s.write(["type": "end"])
        s.closeInput()
        return ["ok": true]
    }

    static func list() -> [String: Any] {
        guard FileManager.default.isExecutableFile(atPath: setup.node.path), FileManager.default.fileExists(atPath: setup.bundle.path) else {
            return ["ok": false, "code": "harness_missing", "error": "this build has no harness runtime"]
        }
        let p = Process()
        p.executableURL = setup.node
        p.arguments = [setup.bundle.path, "sessions", "list", "--dir", setup.dir.path]
        p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return ["ok": false, "error": "launch: \(error.localizedDescription)"] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return ["ok": false, "error": "no list from the harness (exit \(p.terminationStatus))"]
        }
        lock.lock()
        let running = Set(sessions.filter { $0.value.started && !$0.value.closing }.keys)
        lock.unlock()
        return ["ok": true, "sessions": items.map { i -> [String: Any] in
            var i = i; i["open"] = running.contains(i["session_id"] as? String ?? ""); return i
        }]
    }

    // MARK: watching

    static func watch(_ req: [String: Any], fd: Int32) {
        let after = ((req["after"] as? [String: Any]) ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
        let runs = ((req["runs"] as? [String: Any]) ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let w = Watcher(fd: fd, after: after, runs: runs)
        lock.lock()
        watchers.append(w)
        var attach: [(Session, [String: Any])] = []
        var open: [String] = []
        // a session still starting is attached too: its header is on its stdin already (spawn)
        for (id, s) in sessions where !s.closing {
            open.append(id)
            let g = w.gate(id)
            w.gates[id] = g
            attach.append((s, ["type": "attach", "after_seq": g.after]))
            // its tasks the app names, after their cursors; a task still open (running, or its result card answerable)
            // from its start when not named: its card may be waiting
            for run in Set(runs.keys.filter { hasRun(id, $0) }).union(s.activity.open) {
                attach.append((s, ["type": "attach", "run_id": run, "after_seq": runs[run] ?? 0]))
            }
        }
        if let line = lineData(["kind": "helper.watching", "open": open.sorted()]) { w.send(line) }
        lock.unlock()
        for (s, a) in attach { _ = s.write(a) }
        // until the other side closes (or a write to it failed and shut it)
        var buf = [UInt8](repeating: 0, count: 512)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
        }
        lock.lock()
        watchers.removeAll { $0 === w }
        if watchers.isEmpty { for s in sessions.values { s.lastActive = Date() } }   // the idle clock starts now
        lock.unlock()
        w.finish()
    }

    /// Whether `run` is a task of session `sid`: its run folder is in the session's (harness: sessions/<sid>/runs/).
    private static func hasRun(_ sid: String, _ run: String) -> Bool {
        validID(run) && FileManager.default.fileExists(atPath: setup.dir.appendingPathComponent("sessions/\(sid)/runs/\(run)").path)
    }

    // MARK: a session's lines

    private static func read(_ s: Session, _ h: FileHandle) {
        var pending = Data()
        while true {
            let chunk = h.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                guard var e = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                if e["session_id"] == nil { e["session_id"] = s.id }
                received(s, e)
            }
        }
        s.process.waitUntilExit()
        let code = Int(s.process.terminationStatus)
        lock.lock()
        if sessions[s.id] === s { sessions[s.id] = nil }
        let wasStarted = s.started
        if s.first == nil { s.first = ["kind": "session.error", "code": "exited", "text": "the session process exited (\(code))"] }
        let line = wasStarted ? lineData(["kind": "helper.session_exit", "session_id": s.id, "code": code]) : nil
        if let line { for w in watchers { w.send(line) } }
        lock.unlock()
        s.firstLine.signal()
        if s.cardRun != nil { LiveCard.finish(.failed); s.cardRun = nil }
    }

    private static func lineData(_ e: [String: Any]) -> Data? {
        guard var d = try? JSONSerialization.data(withJSONObject: e) else { return nil }
        d.append(0x0A)
        return d
    }

    private static func received(_ s: Session, _ e: [String: Any]) {
        let kind = e["kind"] as? String ?? ""
        lock.lock()
        s.lastActive = Date()
        if !s.started {
            // the first line: session.start, or why it could not start (only the opener hears that)
            let first = s.first == nil
            if first { s.first = e }
            if kind == "session.start" { s.started = true }
            lock.unlock()
            if first { s.firstLine.signal() }
            if kind != "session.start" { return }
            lock.lock()
        }
        s.activity.note(e)
        let raw = s.activity.raw[e["run_id"] as? String ?? ""] ?? ""
        let liveView = s.liveView
        if let line = lineData(e) {
            for w in watchers {
                var g = w.gate(s.id)
                if g.admit(e) { w.send(line) }
                w.gates[s.id] = g
            }
        }
        lock.unlock()
        // the live card and the recording, from the task's own events (each once: a replay is not shown again)
        if !kind.hasPrefix("session."), let run = e["run_id"] as? String, s.inspect.admit(e) {
            drive(s, run: run, e, raw: raw, liveView: liveView)
        }
    }

    private static func drive(_ s: Session, run: String, _ e: [String: Any], raw: String, liveView: Bool) {
        let kind = e["kind"] as? String ?? ""
        if kind == "start" && liveView && s.cardRun == nil {
            s.cardRun = run
            LiveCard.start(bundles: [], goal: raw, onStop: { [weak s] in _ = s?.write(["type": "stop", "run_id": run]) })
        }
        var st = s.cards[run] ?? HarnessEvents.State()
        let out = HarnessEvents.translate(e, state: &st, title: raw, hasFolder: false, pid: Int(s.process.processIdentifier))
        s.cards[run] = st
        if s.cardRun == run { for ev in out { HarnessRun.show(ev) } }
        else { for ev in out where ev["event"] as? String == "step" { HarnessRun.show(ev) } }   // the recording only
        if kind == "task_done" {
            s.cards[run] = nil
            if s.cardRun == run { LiveCard.finish(HarnessRun.ending(e["status"] as? String)); s.cardRun = nil }
        }
    }

    // MARK: idle

    /// Every few seconds: a session with nothing going on (no task running or answerable, nothing queued) and nobody
    /// watching for `idleSeconds` has its stdin closed; its process stores a reply still in progress, then exits.
    private static func startReaper() {   // under lock
        guard !reaping else { return }
        reaping = true
        let every = min(15, max(1, setup.idleSeconds / 4))
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: every)
                lock.lock()
                var idle: [Session] = []
                if watchers.isEmpty {
                    for s in sessions.values where s.started && !s.closing && s.activity.idle
                        && Date().timeIntervalSince(s.lastActive) > setup.idleSeconds {
                        s.closing = true; idle.append(s)
                    }
                }
                lock.unlock()
                for s in idle { NSLog("DeskMind Hands: session \(s.id) idle and unwatched; closing it"); s.closeInput() }
            }
        }
    }
}

/// The machine-wide one-task rule (harness sessions/computer.lock): a session takes it for each computer task; the
/// helper's own runs (`op run`) take it too, so neither starts while the other drives the Mac. The same lock file the
/// harness makes: content written to a file of our own, then hard-linked to the name (it is never seen empty); a lock
/// whose holders are all gone is renamed aside and taken over, and put back if it turns out to be a newer one.
enum ComputerLock {
    enum Outcome { case taken(() -> Void), busy(String), failed(String) }

    static var file: URL { SessionHost.setup.dir.appendingPathComponent("sessions/computer.lock") }

    static func alive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

    private static func text(_ path: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The lock's text while a live process holds it, else nil.
    static func holder() -> String? {
        let t = text(file.path)
        return SessionWire.lockHeld(t, alive: alive) ? t : nil
    }

    static func take(runID: String) -> Outcome {
        let fm = FileManager.default
        let path = file.path
        do { try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { return .failed(error.localizedDescription) }
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let data = try? JSONSerialization.data(withJSONObject: ["pid": Int(pid), "session_id": "", "run_id": runID, "by": "helper"]),
              let content = String(data: data, encoding: .utf8) else { return .failed("lock text") }
        let tag = { "\(pid).\(UUID().uuidString.lowercased().prefix(8))" }
        let tmp = "\(path).\(tag())"
        guard fm.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else { return .failed("cannot write \(tmp)") }
        defer { unlink(tmp) }
        for _ in 0..<5 {
            if link(tmp, path) == 0 {
                return .taken({ if text(path) == content { unlink(path) } })
            }
            guard errno == EEXIST else { return .failed(String(cString: strerror(errno))) }
            guard let held = text(path) else { continue }           // released meanwhile
            if SessionWire.lockHeld(held, alive: alive) { return .busy(held) }
            let aside = "\(path).stale.\(tag())"
            if rename(path, aside) != 0 { continue }                 // someone else moved it
            if text(aside) == held { unlink(aside); continue }
            _ = link(aside, path); unlink(aside)                         // a newer lock was caught: given back
            return .busy(text(path) ?? "")
        }
        return .busy(text(path) ?? "")
    }
}
