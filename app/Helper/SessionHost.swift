// Chat sessions: one `harness.mjs session` process per open session (deskmind-ai/harness docs/protocol.md
// 「会话（第 1 版）」), started by this helper with the harness's environment (HarnessRun.environment: the keys, Brain,
// hands), so the computer tasks a session starts run with this helper's permissions. The main app talks to them over
// the helper's socket:
//
//   session.open  {session_id?, config?, lang?, driver?, scope?, live_view?} → {ok, session_id, resumed, last_seq, pid}
//                 starts the session's process (a known id resumes it; none makes a new one), or finds it running
//                 (`already_open`, with the last stored seq it has sent). `live_view` (default true, as for `op run`;
//                 false is kept): a task of the session shows the live card
//   session.send  {session_id, line}     one control line (SessionWire.validate: a JSON object of a known type)
//   session.end   {session_id, when_idle?}  ends the process only when the session is idle: the helper writes it
//                                        `end_if_idle` (harness#62; SessionWire.EndAsk) and the session decides — it
//                                        ends, or refuses (`not_idle`, with `why`). `when_idle: true` (a restart so a new
//                                        key reaches it): ended now if idle, else at its next idle moment (`deferred`)
//   session.history {session_id, after_seq?, runs?: {run_id: after_seq}}
//                                        the session's stored lines after the cursor, and its tasks' (from session.jsonl
//                                        and runs/<run>/events.jsonl), with `open` (a process of it runs here) and the
//                                        last stored seq: reading a session needs no process
//   session.delete {session_id}          the user deletes the session: its process (if any) is ended and waited for,
//                                        then its folder (history, task runs) and its stderr log are removed. Refused
//                                        (`task_running`) while a task of it runs, and (`busy`) while it is opening or
//                                        a process of it from an earlier helper still holds its lock
//   sessions.list                        `harness.mjs sessions list`, each marked `open` when its process runs here,
//                                        with `keys` (the models.env digest that process started with, ModelKeys) and
//                                        `ending` (a restart asked, at its next idle moment); `keys` at the top: the
//                                        file's digest now — a process whose `keys` differ runs on keys no longer saved.
//                                        One whose session.start has not come yet: `starting`; not `open`.
//                                        `processes`: every session process this helper holds (being spawned, started
//                                        with nothing stored yet, running), stored or not — {session_id, open, keys
//                                        (absent: not read yet), ending, starting?}: what the app's keys rounds read
//   models.off {off}                     cloud models off (the app's engine setting, from any window): this helper
//                                        holds it for every session it runs, whichever client — persisted in its
//                                        folder (`models-off`). While off: every running session process is written
//                                        set_config null at once, and every one it starts gets it as its first control;
//                                        a control that needs a model (say, cua, retry, steer, queue_send_now, a
//                                        set_config that is not null) is refused `no_model`, as the session would
//   sessions.watch {after: {session_id: after_seq}, runs?: {run_id: after_seq}}
//                 one long-lived connection: every session's lines (each has its session_id), from the cursors on.
//                 On connect each running session is sent `attach{after_seq}` and replays what is stored after it;
//                 each named task of it (its folder is under the session's runs/) is replayed after its cursor with
//                 `attach{run_id}`, and a task still open from its start when not named (its card may wait). Each
//                 connection gets, per stream (the session's stored lines; each task's lines), the replay first, then
//                 the live lines, with contiguous seqs: a live task line that overtakes its replay is held until the
//                 replay below it has been sent (SessionWire.Gate). The
//                 first line is {"kind":"helper.watching","open":[…],"idle":[…],"last_seq":{…}} (`idle`: sessions this
//                 helper closed because they were idle, not opened since; `last_seq`: the last stored seq of each session
//                 whose process ended in this helper, not open now); a process that ends says
//                 {"kind":"helper.session_exit","session_id":…,"code":…,"pid":…,"start_seq":…,"last_seq":…,"idle"?:true}:
//                 which process (pid), the stored seq it began after (its session.start's last_seq) and the last stored
//                 seq it sent; `idle` when this helper closed it because nothing was going on (no run was cut).
//
// Tasks of a session drive the live card and the recording as the helper's own runs do (HarnessRun.show), from the
// executor events the session forwards: only a task that runs in this helper now (SessionWire.Live), never a replay.
//
// Lifecycle (owner 10-21): the processes are this helper's children. When the helper exits, their stdin reaches its
// end and each stops its running task itself (the harness's "app went away"). The main app closing changes nothing:
// a session keeps its task running and its card waiting. A session quiet for `idleSeconds` is asked to end if it is
// idle (`end_if_idle`: the session decides — no reply, nothing queued, no task open, no recovery under way), watched or
// not (#107 review: each process is ~80 MB). The watch goes on; the next send (or open) starts it again.

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
        /// A session process's environment, from the one read of models.env its digest is of (`keys`: #107 review at
        /// 36c5737 — two reads let a save between them give a process one key file and its digest another's).
        var environment: (_ keys: [String: String]) -> [String: String]
        var prepare: () throws -> Void
        /// How long a session with nothing going on and nobody watching stays up.
        var idleSeconds: Double
        /// The driver a session's tasks run on, unless session.open names one (`sim` in tests).
        var driver = "hands"
        /// The live card and the recording (`UI.standard`; a recorder in tests).
        var ui = UI.standard
        /// Called once a spawn is listed (`spawning`), before its read of models.env: a test's pause (none in the app).
        var beforeKeys: () -> Void = {}

        static func standard() -> Setup {
            Setup(node: HarnessRun.node, bundle: HarnessRun.bundle, dir: DeskMindIPC.supportDir, cwd: Runner.work,
                  logs: DeskMindIPC.supportDir.appendingPathComponent("work/session-logs"),
                  environment: { HarnessRun.environment(keys: $0) }, prepare: Runner.prepareWork,
                  idleSeconds: max(10, UserDefaults.standard.object(forKey: "sessions.idleSeconds") as? Double ?? 300))
        }
    }
    nonisolated(unsafe) static var setup = Setup.standard()

    /// What a live task of a session drives on this Mac, by run: its card (when the session shows one), the
    /// recording's app list, and the card's end.
    struct UI {
        var start: (_ run: String, _ goal: String, _ onStop: @escaping () -> Void) -> Void
        /// An event of the task the card follows (HarnessRun.show).
        var show: (_ run: String, _ ev: [String: Any]) -> Void
        /// An event of a live task without the card: the recording only (HarnessRun.recordApp).
        var record: (_ run: String, _ ev: [String: Any]) -> Void
        var finish: (_ run: String, _ status: LiveView.Status?) -> Void

        // (every live task's events also go to the live view's feed -- LiveWatch -- with a card or without)
        static let standard = UI(start: { _, goal, onStop in LiveCard.start(bundles: [], goal: goal, onStop: onStop) },
                                 show: { run, ev in LiveWatch.note(run: run, ev); HarnessRun.show(ev) },
                                 record: { run, ev in LiveWatch.note(run: run, ev); HarnessRun.recordApp(ev) },
                                 finish: { run, status in LiveWatch.ended(run); LiveCard.finish(status) })
    }

    static let ops: Set<String> = ["session.open", "session.send", "session.end", "session.delete", "session.history", "sessions.list", "sessions.watch",
                                   "models.off"]

    // MARK: state (under `lock`)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var sessions: [String: Session] = [:]
    nonisolated(unsafe) private static var opening: Set<String> = []
    /// Sessions being spawned, not in `sessions` yet: listed (`starting`) from before their read of models.env to
    /// their entry in `sessions`, with that read's digest once it is made (nil before: unknown). #107 review at
    /// 36c5737: a process that had read the keys before it was listed was missed by a save meanwhile.
    nonisolated(unsafe) private static var spawning: [String: String?] = [:]
    nonisolated(unsafe) private static var watchers: [Watcher] = []
    nonisolated(unsafe) private static var reaping = false
    nonisolated(unsafe) private static var expiring = false
    /// Sessions this helper closed because they were idle, not opened since (helper.watching's `idle`).
    nonisolated(unsafe) private static var idleClosed: Set<String> = []
    /// The last stored seq of each session whose process ended in this helper (helper.watching's `last_seq`): a
    /// watch that comes later reads the stored log of only those it has not all of.
    nonisolated(unsafe) private static var exitedLastSeq: [String: Int] = [:]
    /// Cloud models off (models.off), read from its file the first time it is needed (under lock). The file says "0"
    /// (on) or "1" (off); missing or unreadable: off — the safe side — until a client asserts the bit (the app does on
    /// every connect, and wherever the engine setting is written).
    nonisolated(unsafe) private static var offLoaded = false
    nonisolated(unsafe) private static var offBit = true
    private static var offFile: URL { setup.dir.appendingPathComponent("models-off") }
    private static var modelsAreOff: Bool {     // under lock
        if !offLoaded {
            let text = (try? String(contentsOf: offFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            offBit = text != "0"
            offLoaded = true
        }
        return offBit
    }
    /// The bit, for the helper's status and its op run (HandsHelper).
    static var modelsOffNow: Bool { lock.lock(); defer { lock.unlock() }; return modelsAreOff }
    /// One models.off at a time: the bit in memory and its file never disagree.
    private static let offSerial = NSLock()

    /// An op run the bit refuses (the old window's run with the cloud engine): its error event, else nil. Local-engine
    /// runs are not the cloud's and go on.
    static func refusesRun(_ req: [String: Any]) -> [String: Any]? {
        guard req["engine"] as? String == "harness", req["goal"] is String, modelsOffNow else { return nil }
        return ["event": "error", "code": "no_model",
                "error": L("The cloud model is off. Turn it on in the model settings to run this task.", lang: ResolvedLang.current)]
    }
    private static let nullConfig: [String: Any] = ["type": "set_config", "config": NSNull()]
    /// What else stops when cloud models go off: the helper's harness op run (HandsHelper sets it; tests count it).
    nonisolated(unsafe) static var onModelsOff: () -> Void = {}

    /// models.off {off}: holds the bit for every session this helper runs (and persists it), and with the models off
    /// writes set_config null to every running session process now.
    /// One at a time (`offSerial`). Off: the running sessions are nulled first, a harness op run going is stopped
    /// (`onModelsOff`), then the bit is written down, and the reply comes only after all of it. The bit in memory is
    /// the one that holds; a file that could not be written is said (`persisted: false`, still ok: the app does not
    /// send it again for that); for an off, the file is removed then, so the next start reads it missing — off, the
    /// safe side — until the app asserts it.
    static func modelsOff(_ req: [String: Any]) -> [String: Any] {
        guard let off = req["off"] as? Bool else { return ["ok": false, "code": "bad_request", "error": "models.off needs off (true or false)"] }
        offSerial.lock(); defer { offSerial.unlock() }
        lock.lock()
        _ = modelsAreOff
        offBit = off
        let running = sessions.values.filter { $0.started && !$0.closing }
        lock.unlock()
        if off {
            for s in running { s.writeGate.lock(); _ = s.write(nullConfig); s.writeGate.unlock() }
            onModelsOff()
        }
        var persisted = true
        do { try Data((off ? "1" : "0").utf8 + [0x0A]).write(to: offFile, options: .atomic) } catch {
            NSLog("DeskMind Hands: models.off not written down: \(error.localizedDescription)")
            persisted = false
            // an "on" left in the file must not outlive an "off": no file reads as off at the next start
            if off { try? FileManager.default.removeItem(at: offFile) }
        }
        return ["ok": true, "off": off, "persisted": persisted]
    }
    /// How long `session.end` waits for the session's answer to its end_if_idle (it answers in order, at once: this
    /// only bounds a session that hangs).
    static let endAnswerTimeout: Double = 15
    /// How long a control line waits for an end_if_idle under way (the session answers it at once): a line written
    /// after it to a session that then ends would be lost; after its answer it goes to the session, or is not_open
    /// (the app opens the session again and sends it there).
    static let endAskHold: Double = 2

    /// The helper's end_if_idle under way: answered by the session's refusal (`why`) or by its process's exit (`ended`).
    final class EndAsk {
        let wire = SessionWire.EndAsk()
        let answered = DispatchGroup()
        var why: [String]?
        var ended = false
        init() { answered.enter() }
    }

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
        /// Show a task's live card (session.open's `live_view`, on unless the app says false, as for `op run`).
        var liveView = true
        /// Which lines are new in this process and which tasks are live in it (SessionWire.Live).
        var live = SessionWire.Live()
        /// Its session.start's `last_seq`: the stored seq this process began after.
        var startSeq = 0
        /// session.start came: from then on its lines go to the watching connections (before it, a refusal is the
        /// opener's: busy, bad_config).
        var started = false
        var first: [String: Any]?
        let firstLine = DispatchSemaphore(value: 0)
        /// The helper's end_if_idle under way, if any (one at a time).
        var ask: EndAsk?
        /// Held while a control line is checked against an end_if_idle under way and written, and while an
        /// end_if_idle is decided and written: neither slips between the other's check and its write (a line written
        /// after an end_if_idle that ends the session would be lost after its ok).
        let writeGate = NSLock()
        /// Closed by this helper's end_if_idle (it was idle): its exit says so (no run was cut).
        var closedIdle = false
        /// A restart the app asked for (session.end when_idle): asked again at its next idle moment.
        var endWhenIdle = false
        /// The model keys file's digest as this process read it when it started (ModelKeys; sessions.list's `keys`):
        /// the app asks a process for a restart while this is not the file's now.
        var keysDigest: String?
        // the reader thread's own: the live card's view of each live task
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
                if !SessionHost.writeAll(fd, line) { closed = true; Darwin.shutdown(fd, SHUT_RDWR) }
            }
        }

        /// No line is written after this returns: the connection's fd can be closed.
        func finish() { queue.sync { closed = true } }
    }

    /// A session's id is a folder name (harness SESSION_ID).
    static func validID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
    }

    /// A task of some session is running (not yet at its session.task_end), or a finished one's result card still
    /// offers undo (its executor lingers): the helper does not restart under either.
    static var taskRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.contains { $0.activity.holdsRestart }
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
        case "session.end": reply = end(sessionID: req["session_id"] as? String ?? "", whenIdle: req["when_idle"] as? Bool == true)
        case "session.history": reply = history(req)
        case "session.delete": reply = delete(sessionID: req["session_id"] as? String ?? "")
        case "models.off": reply = modelsOff(req)
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
        // one opener per id at a time; a process on its way out is waited for (its lock is the session's): one closing,
        // one asked to end if idle (its answer may be its exit), one that exited and is not reaped yet
        let until = Date().addingTimeInterval(20)
        while true {
            lock.lock()
            if let s = sessions[id], s.started, !s.closing, s.ask == nil, s.process.isRunning {
                if let liveView { s.liveView = liveView }
                s.lastActive = Date()
                lock.unlock()
                return ["ok": true, "session_id": id, "resumed": s.first?["resumed"] as? Bool ?? true, "already_open": true,
                        "last_seq": s.live.lastSeq, "pid": Int(s.process.processIdentifier)]
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
            do { s = try spawn(id: id, header: header, liveView: liveView ?? true) } catch {
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
        // listed before it reads the keys (its digest unknown meanwhile), and until it is in `sessions` — whatever
        // happens on the way (a failed launch leaves nothing listed)
        lock.lock(); spawning[id] = .some(nil); lock.unlock()
        defer { lock.lock(); spawning[id] = nil; lock.unlock() }
        setup.beforeKeys()
        // ONE read of the keys file: the environment the process gets and the digest the helper reports are of it
        let keysEnv = HarnessRun.modelEnv()
        let keys = ModelKeys.digest(env: keysEnv)
        lock.lock(); spawning[id] = .some(keys); lock.unlock()
        p.environment = setup.environment(keysEnv)
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = err ?? FileHandle.nullDevice
        try p.run()
        try? err?.close()
        let s = Session(id: id, process: p, input: inPipe.fileHandleForWriting)
        s.liveView = liveView
        s.keysDigest = keys
        // The header, then a replay for whoever watches: the stored events after the earliest cursor among them. Written
        // under the lock, so a connection that starts watching meanwhile (sessions.watch) writes its attach after the
        // header: a first line with a type is no header, and the session would refuse to start.
        lock.lock()
        sessions[id] = s
        spawning[id] = nil              // (in `sessions` now, under the same lock: never missing from a list between)
        idleClosed.remove(id); exitedLastSeq[id] = nil
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
        guard let found = sessions[sessionID] else {
            lock.unlock(); return ["ok": false, "code": "not_open", "error": "session \(sessionID) is not open"]
        }
        lock.unlock()
        let notOpen: [String: Any] = ["ok": false, "code": "not_open", "error": "session \(sessionID) is not open"]
        // an end_if_idle under way: wait for its answer (at once) outside the gate, then check again under it, so the
        // line is never written after an end_if_idle that ends the session. Unanswered in time: not written (not
        // open: the app opens the session again and sends it there), never written blind
        found.writeGate.lock()
        lock.lock()
        while let ask = found.ask {
            lock.unlock(); found.writeGate.unlock()
            // unanswered in time: the process is still there, its end undecided — not "not open" (the app would read
            // it as exited): `busy_ending`, the app sends the line again
            if ask.answered.wait(timeout: .now() + endAskHold) == .timedOut {
                return ["ok": false, "code": "busy_ending", "error": "session \(sessionID) is deciding whether to end"]
            }
            found.writeGate.lock(); lock.lock()
        }
        // cloud models off: what needs a model is refused, from any client, as the session refuses it (no_model) —
        // the refusal goes to every watching connection too, with the line's client_id
        if modelsAreOff && SessionWire.needsModel(o) {
            var e: [String: Any] = ["kind": "session.error", "session_id": sessionID, "code": "no_model",
                                    "control": o["type"] as? String ?? "", "text": "cloud models are off"]
            if let c = o["client_id"] as? String { e["client_id"] = c }
            for w in watchers { var g = w.gate(sessionID); for x in g.admit(e) { if let d = lineData(x) { w.send(d) } }; w.gates[sessionID] = g }
            lock.unlock(); found.writeGate.unlock()
            var r: [String: Any] = ["ok": false, "code": "no_model", "control": o["type"] as? String ?? "", "error": "cloud models are off"]
            if let c = o["client_id"] as? String { r["client_id"] = c }
            return r
        }
        guard let s = sessions[sessionID], s === found, s.started, !s.closing else {
            lock.unlock(); found.writeGate.unlock(); return notOpen
        }
        defer { s.writeGate.unlock() }
        s.lastActive = Date()
        // a replay of a task the app asks for itself: the connections that have nothing of it take it from its cursor
        if o["type"] as? String == "attach", let run = o["run_id"] as? String {
            let after = (o["after_seq"] as? NSNumber)?.intValue ?? 0
            for w in watchers { var g = w.gate(sessionID); g.adopt(run, after: after); w.gates[sessionID] = g }
        }
        lock.unlock()
        if let error = s.write(o) { return ["ok": false, "error": error] }
        return ["ok": true]
    }

    /// The app ends a session: only when it is idle, as the session itself decides (`end_if_idle`, never the app's or
    /// this helper's reading of its state). `whenIdle` (a restart so that a new key reaches it): ended now if idle,
    /// else asked again once it may be (`deferred`); otherwise refused (`not_idle`, with the session's `why`).
    static func end(sessionID: String, whenIdle: Bool = false) -> [String: Any] {
        lock.lock()
        guard let s = sessions[sessionID], !s.closing else {
            lock.unlock(); return ["ok": false, "code": "not_open", "error": "session \(sessionID) is not open"]
        }
        if whenIdle { s.endWhenIdle = true }
        lock.unlock()
        let answer = endIfIdle(s, wait: true)
        switch answer.code {
        case nil: return ["ok": true]
        case "not_open"?: return ["ok": false, "code": "not_open", "error": "session \(sessionID) is not open"]
        default:
            if whenIdle { return ["ok": true, "deferred": true] }
            return ["ok": false, "code": "not_idle", "why": answer.why, "error": "session \(sessionID) is not idle"]
        }
    }

    /// Asks the session to end if it is idle (`end_if_idle`, one ask at a time: a second asker shares the first's
    /// answer). `wait`: until it answers (bounded by `endAnswerTimeout`); else only asked (the reaper), its answer
    /// handled as it comes. nil when it ended; else "not_open", "not_idle" (with the session's `why`), "asked" or
    /// "timeout".
    @discardableResult
    static func endIfIdle(_ s: Session, wait: Bool, quietOnly: Bool = false) -> (code: String?, why: [String]) {
        s.writeGate.lock()
        lock.lock()
        guard sessions[s.id] === s, s.started, !s.closing else { lock.unlock(); s.writeGate.unlock(); return ("not_open", []) }
        // the reaper's ask: only if still quiet, checked under the gate (a line sent since moved lastActive)
        if quietOnly && !(s.ask == nil && s.activity.idle && (s.endWhenIdle || Date().timeIntervalSince(s.lastActive) > setup.idleSeconds)) {
            lock.unlock(); s.writeGate.unlock(); return ("skipped", [])
        }
        let ask: EndAsk
        var write = false
        if let a = s.ask { ask = a } else { ask = EndAsk(); s.ask = ask; write = true }
        lock.unlock()
        if write, s.write(ask.wire.line) != nil {
            lock.lock(); if s.ask === ask { s.ask = nil; ask.answered.leave() }; lock.unlock()
            s.writeGate.unlock()
            return ("not_open", [])
        }
        s.writeGate.unlock()
        guard wait else { return ("asked", []) }
        if ask.answered.wait(timeout: .now() + endAnswerTimeout) == .timedOut { return ("timeout", []) }
        lock.lock(); defer { lock.unlock() }
        if ask.ended { return (nil, []) }
        if let why = ask.why { return ("not_idle", why) }
        return ("not_open", [])             // its process exited, not as this answer (an error)
    }

    /// The user deletes a session (the main app's session list): its process, if one runs here, is ended and waited
    /// for; then its folder — the history and its tasks' run folders — and its stderr log are removed. Nothing is
    /// removed while a task of it runs (the user stops it first: a delete is never a stop), while it is being opened,
    /// or while a process of it this helper does not know (an earlier helper's, still stopping its task) holds the
    /// session's lock.
    static func delete(sessionID id: String) -> [String: Any] {
        guard validID(id) else { return ["ok": false, "code": "bad_request", "error": "a session id is letters, digits, _ and -, at most 64"] }
        lock.lock()
        if opening.contains(id) { lock.unlock(); return ["ok": false, "code": "busy", "error": "session \(id) is opening"] }
        let s = sessions[id]
        if let s, !s.activity.running.isEmpty {
            lock.unlock(); return ["ok": false, "code": "task_running", "error": "a task of session \(id) is running"]
        }
        opening.insert(id)                  // no open of it meanwhile (session.open waits on it)
        s?.closing = true
        lock.unlock()
        defer { lock.lock(); opening.remove(id); lock.unlock() }
        if let s {
            _ = s.write(["type": "end"])
            s.closeInput()
            let until = Date().addingTimeInterval(15)
            while Date() < until {
                lock.lock(); let gone = sessions[id] !== s; lock.unlock()
                if gone && !s.process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            lock.lock(); let gone = sessions[id] !== s; lock.unlock()
            if !gone || s.process.isRunning { return ["ok": false, "code": "busy", "error": "session \(id) is still closing"] }
        }
        let folder = setup.dir.appendingPathComponent("sessions/\(id)")
        // a process of it from an earlier helper (stopping its task when that helper went) still holds its lock
        if let text = try? String(contentsOf: folder.appendingPathComponent("lock"), encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0, kill(pid, 0) == 0 || errno == EPERM {
            return ["ok": false, "code": "busy", "error": "session \(id) is held by process \(pid)"]
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) {
            do { try fm.removeItem(at: folder) } catch { return ["ok": false, "error": "remove: \(error.localizedDescription)"] }
        }
        try? fm.removeItem(at: setup.logs.appendingPathComponent("\(id).stderr"))
        lock.lock(); idleClosed.remove(id); exitedLastSeq[id] = nil; lock.unlock()
        return ["ok": true, "session_id": id]
    }

    /// A session's stored lines after `after_seq`, and each of its tasks' lines after its cursor (`runs`), read from its
    /// folder (the files the session replays from): the app reads a session without a process. `open`: a process of it
    /// runs here (its live lines come through the watch). Lines are as the session sends them (with session_id).
    static func history(_ req: [String: Any]) -> [String: Any] {
        let id = req["session_id"] as? String ?? ""
        guard validID(id) else { return ["ok": false, "code": "bad_request", "error": "a session id is letters, digits, _ and -, at most 64"] }
        let after = (req["after_seq"] as? NSNumber)?.intValue ?? 0
        let runs = ((req["runs"] as? [String: Any]) ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
        let folder = setup.dir.appendingPathComponent("sessions/\(id)")
        guard let stored = readLines(folder.appendingPathComponent("session.jsonl")) else {
            return ["ok": false, "code": "not_found", "error": "no session \(id)"]
        }
        var out: [[String: Any]] = []
        var last = 0
        var tasks: [String] = []
        for var e in stored {
            guard let seq = SessionWire.ownSeq(e) else { continue }
            last = max(last, seq)
            if e["kind"] as? String == "session.task", let r = e["run_id"] as? String, validID(r) { tasks.append(r) }
            if seq > after { e["session_id"] = id; out.append(e) }
        }
        for r in tasks {
            for var e in readLines(folder.appendingPathComponent("runs/\(r)/events.jsonl")) ?? [] {
                guard let seq = (e["seq"] as? NSNumber)?.intValue, seq > runs[r] ?? 0 else { continue }
                e["session_id"] = id
                if e["run_id"] == nil { e["run_id"] = r }
                out.append(e)
            }
        }
        lock.lock()
        let open = sessions[id].map { !$0.closing } ?? false
        lock.unlock()
        return ["ok": true, "session_id": id, "open": open, "last_seq": last, "lines": out]
    }

    /// A JSON-lines file's objects (a line that does not read — one being written — is left); nil when there is none.
    private static func readLines(_ url: URL) -> [[String: Any]]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return data.split(separator: 0x0A).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
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
        // (the file now, read before the processes' digests: a save meanwhile shows as owed, never as applied)
        let keysNow = ModelKeys.digest(env: HarnessRun.modelEnv())
        lock.lock()
        // a process spawned whose session.start has not come yet (`starting`) has read its keys already: reported with
        // its digest too (#107 review at 85d81f6: missed, a key saved while it started left it on the old one)
        var running: [String: (keys: String?, ending: Bool, starting: Bool)] = [:]
        for (id, s) in sessions where !s.closing && (s.started || s.process.isRunning) {
            running[id] = (s.keysDigest, s.endWhenIdle, !s.started)
        }
        // being spawned: `starting`, its digest once it has read the keys (none: unknown, owed until known)
        for (id, k) in spawning where running[id] == nil { running[id] = (k, false, true) }
        lock.unlock()
        let reported = items.map { i -> [String: Any] in
            var i = i
            let r = running[i["session_id"] as? String ?? ""]
            i["open"] = r.map { !$0.starting } ?? false
            if let r {
                if let k = r.keys { i["keys"] = k }
                i["ending"] = r.ending
                if r.starting { i["starting"] = true }
            }
            return i
        }
        // the keys rounds read this helper's own process table, never the stored list: every process it holds — being
        // spawned, started with nothing stored yet, running — is there by construction (#107 review at 588dbad: one
        // started whose history was not on disk yet was in neither list, and kept the old key)
        let processes = running.keys.sorted().map { id -> [String: Any] in
            let r = running[id]!
            var p: [String: Any] = ["session_id": id, "open": !r.starting, "ending": r.ending]
            if r.starting { p["starting"] = true }
            if let k = r.keys { p["keys"] = k }
            return p
        }
        return ["ok": true, "keys": keysNow, "sessions": reported, "processes": processes]
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
            var g = w.gate(id)
            attach.append((s, ["type": "attach", "after_seq": g.after]))
            // its tasks the app names, after their cursors; a task still open (running, or its result card answerable)
            // from its start when not named: its card may be waiting. Their live lines wait for their replay (Gate).
            for run in Set(runs.keys.filter { hasRun(id, $0) }).union(s.activity.open) {
                g.expect(run)
                attach.append((s, ["type": "attach", "run_id": run, "after_seq": runs[run] ?? 0]))
            }
            w.gates[id] = g
        }
        let ended = exitedLastSeq.filter { !open.contains($0.key) }
        if let line = lineData(["kind": "helper.watching", "open": open.sorted(), "idle": idleClosed.subtracting(open).sorted(),
                                "last_seq": ended, "models_off": modelsAreOff]) { w.send(line) }
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
        // which process ended: its pid, the stored seq it began after (start_seq) and the last it sent (last_seq), so the
        // app tells this process's runs from a newer one's whatever order lines arrive in
        var exit: [String: Any] = ["kind": "helper.session_exit", "session_id": s.id, "code": code,
                                   "pid": Int(s.process.processIdentifier), "start_seq": s.startSeq, "last_seq": s.live.lastSeq]
        // an end_if_idle under way that the process ended on: it was idle (a clean exit; another is an error)
        let ask = s.ask
        s.ask = nil
        if let ask, code == 0 { ask.ended = true; s.closedIdle = true }
        if s.closedIdle { exit["idle"] = true; if sessions[s.id] == nil { idleClosed.insert(s.id) } }
        exitedLastSeq[s.id] = s.live.lastSeq
        let line = wasStarted ? lineData(exit) : nil
        if let line { for w in watchers { w.send(line) } }
        lock.unlock()
        ask?.answered.leave()
        if s.closedIdle { NSLog("DeskMind Hands: session \(s.id) idle; closed it") }
        s.firstLine.signal()
        if let run = s.cardRun { setup.ui.finish(run, .failed); s.cardRun = nil }
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
            if kind == "session.start" {
                // cloud models off: no model from its first control on, before any client's line can be written
                // (a send waits for `started`)
                if modelsAreOff { lock.unlock(); s.writeGate.lock(); _ = s.write(nullConfig); s.writeGate.unlock(); lock.lock() }
                s.started = true
                s.startSeq = (e["last_seq"] as? NSNumber)?.intValue ?? 0
                s.live = SessionWire.Live(lastSeq: s.startSeq)
            }
            lock.unlock()
            if first { s.firstLine.signal() }
            if kind != "session.start" { return }
            lock.lock()
        }
        // the refusal of the helper's own end_if_idle: its answer (by the client_id and the code only), passed on to nobody
        if SessionWire.EndAsk.isRefusal(e) {
            var answered: EndAsk?
            if let a = s.ask, a.wire.refused(e) { a.why = SessionWire.EndAsk.why(e); s.ask = nil; answered = a }
            lock.unlock()
            answered?.answered.leave()
            return
        }
        // what the session has going on, and what drives the card: from new lines only, never from a replay
        var drive = false
        var ended: String?
        if kind.hasPrefix("session.") {
            if s.live.note(e) {
                s.activity.note(e)
                if kind == "session.task_end" || kind == "session.task_closed" { ended = e["run_id"] as? String }
            }
        } else if e["run_id"] is String {
            drive = s.live.show(e)
        }
        let raw = s.activity.raw[e["run_id"] as? String ?? ""] ?? ""
        let liveView = s.liveView
        var hold = false
        for w in watchers {
            var g = w.gate(s.id)
            for o in g.admit(e) { if let line = lineData(o) { w.send(line) } }
            hold = hold || g.holding
            w.gates[s.id] = g
        }
        if hold { scheduleExpiry() }
        // a restart waits for the session to be idle: asked again when what may have been going on ends
        let ends: Set<String> = ["session.task_end", "session.task_closed", "session.message", "session.error", "session.queue"]
        let recheck = s.endWhenIdle && !s.closing && s.ask == nil && ends.contains(kind) && s.activity.idle
        lock.unlock()
        if recheck { DispatchQueue.global().async { endIfIdle(s, wait: false) } }
        if drive, let run = e["run_id"] as? String { self.drive(s, run: run, e, raw: raw, liveView: liveView) }
        // a task that ended without its executor's task_done (the executor died, the app went away): its card ends
        // here, or it would stay up and keep every later task of the session from showing one
        if let run = ended {
            s.cards[run] = nil
            if s.cardRun == run {
                setup.ui.finish(run, kind == "session.task_end" ? HarnessRun.ending(e["status"] as? String) : .failed)
                s.cardRun = nil
            }
        }
    }

    /// A watching connection's task lines held for a replay that has not come (SessionWire.Gate.expire): let go, in
    /// order, once they have waited `Gate.holdLimit`. Under lock.
    private static func scheduleExpiry() {
        guard !expiring else { return }
        expiring = true
        DispatchQueue.global().asyncAfter(deadline: .now() + SessionWire.Gate.holdLimit + 0.1) {
            lock.lock()
            expiring = false
            var again = false
            for w in watchers {
                for (sid, gate) in w.gates where gate.holding {
                    var g = gate
                    let out = g.expire()
                    if !out.isEmpty { NSLog("DeskMind Hands: session \(sid): \(out.count) task lines passed on without their replay") }
                    for o in out { if let line = lineData(o) { w.send(line) } }
                    again = again || g.holding
                    w.gates[sid] = g
                }
            }
            if again { scheduleExpiry() }
            lock.unlock()
        }
    }

    /// A live task's event (SessionWire.Live.show: started in this process, not ended, not shown before): the card
    /// follows the first such task while the session shows cards; any other only feeds the recording's app list.
    private static func drive(_ s: Session, run: String, _ e: [String: Any], raw: String, liveView: Bool) {
        let kind = e["kind"] as? String ?? ""
        if kind == "start" && liveView && s.cardRun == nil {
            s.cardRun = run
            setup.ui.start(run, raw) { [weak s] in _ = s?.write(["type": "stop", "run_id": run]) }
        }
        var st = s.cards[run] ?? HarnessEvents.State()
        let out = HarnessEvents.translate(e, state: &st, title: raw, hasFolder: false, pid: Int(s.process.processIdentifier))
        s.cards[run] = st
        if s.cardRun == run { for ev in out { setup.ui.show(run, ev) } }
        else { for ev in out { setup.ui.record(run, ev) } }
        if kind == "task_done" {
            s.cards[run] = nil
            if s.cardRun == run { setup.ui.finish(run, HarnessRun.ending(e["status"] as? String)); s.cardRun = nil }
        }
    }

    // MARK: idle

    /// Every few seconds: a session quiet for `idleSeconds` (or one the app asked to restart) is asked to end if it is
    /// idle (`end_if_idle`), watched or not; the session decides. The watch goes on without it; the next send or open
    /// starts it again.
    private static func startReaper() {   // under lock
        guard !reaping else { return }
        reaping = true
        let every = min(15, max(1, setup.idleSeconds / 4))
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: every)
                lock.lock()
                var due: [Session] = []
                for s in sessions.values where s.started && !s.closing && s.ask == nil && s.activity.idle
                    && (s.endWhenIdle || Date().timeIntervalSince(s.lastActive) > setup.idleSeconds) {
                    due.append(s)
                }
                lock.unlock()
                for s in due { endIfIdle(s, wait: false, quietOnly: true) }
            }
        }
    }
}
