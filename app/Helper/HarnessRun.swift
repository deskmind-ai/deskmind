// The harness engine: `runtime/node/bin/node runtime/harness/harness.mjs app-run`, the request on its stdin, its
// events on stdout (one JSON per line), the user's answers back on stdin. hands stays the execution layer under it:
// the harness starts `deskmind_hands.executor` itself (DESKMIND_HANDS_CMD) with the same bundled Python and tree
// `hands do` uses. Behind the request's `engine: "harness"`; `hands do` is untouched.

import AppKit
import Foundation

enum HarnessRun {
    nonisolated(unsafe) static var state = HarnessEvents.State()
    /// The running harness's stdin, for answers (Runner.answer routes here while a harness run is current).
    nonisolated(unsafe) static var input: FileHandle?
    private static let lock = NSLock()

    /// How long a finished run's process stays up for the result card's answer (`--linger`): undo needs the executor's
    /// receipts, which live in that process. The run itself is over at task_done (the helper is free for the next one).
    static let lingerSeconds = 600

    /// A run past its task_done whose process is still up: its stdin, for the result card's `respond`; and that
    /// answer's `result_response`, once the harness writes it. All under `lock`.
    final class Lingering {
        let process: Process
        let input: FileHandle
        var runID = ""
        var response: [String: Any]?
        /// task_done passed on: the run's lines from then on are this process's (result_response), not the run's.
        var over = false
        /// The card was answered: one answer per card (the harness reads only the first); an undo may be going until
        /// its result_response comes.
        var responded = false
        /// Its process group, as the machine lock names it (ComputerLock).
        var pgid: Int32 { process.processIdentifier }
        /// The machine lock as this run last wrote it: every change of it is made from exactly this (compare-and-set),
        /// so nothing of this run writes over what another writer (its undo, a new task) made of it since.
        var holder: SessionWire.Holder?
        private(set) var closed = false
        init(process: Process, input: FileHandle) { self.process = process; self.input = input }
        /// stdin closed (EOF): the harness stops waiting for a respond and exits. Once; called under `lock`.
        func close() { if !closed { closed = true; try? input.close() } }
    }
    nonisolated(unsafe) static var lingering: Lingering?
    /// The last finished run whose undo expired (another task started on this Mac): a late answer to its card is told
    /// so (`undo_expired`), not just that nothing waits. Under `lock`.
    nonisolated(unsafe) static var expiredRun: String?
    /// The error a run is refused with when the last run's process would not end (ComputerLock.acquire: `alive`).
    static let stillRunning: [String: Any] = [
        "event": "error", "code": "previous_run_alive",
        "error": "the last task's process has not ended (it may still be undoing), so this task was not started",
    ]

    /// One of the run's events to the app. task_done: the machine lock says lingering and the run is registered as
    /// lingering before the app hears of it (an undo clicked at once is let through), and the run is over only once
    /// task_done has been sent -- the run thread then sends `done`, which must come after.
    static func pass(_ ev: [String: Any], linger: Lingering, emit: ([String: Any]) -> Bool) {
        let done = ev["event"] as? String == "task_done"
        if done {
            settle(linger)
            finished(linger, runID: ev["run_id"] as? String ?? "")
        }
        _ = emit(ev)
        if done { lock.lock(); linger.over = true; lock.unlock() }
    }

    /// task_done is being passed on: its result card can be answered (op respond) from now on. Registered before the
    /// event reaches the app, so an undo clicked the moment the card shows finds the run (it was registered on the run
    /// thread's next poll, up to 250 ms later).
    static func finished(_ linger: Lingering, runID: String) {
        lock.lock(); defer { lock.unlock() }
        if !runID.isEmpty { linger.runID = runID }
        if linger.process.isRunning && !linger.closed { lingering = linger; expiredRun = nil }
    }

    /// Each run's own stdout / stderr copies (`<run_id>.stdout|.stderr`): a lingering process writes on after the
    /// next run has started, and must not write into that run's files. The last `logsKept` runs' are kept.
    static var logs: URL { DeskMindIPC.supportDir.appendingPathComponent("work/harness-logs") }
    static let logsKept = 5

    private static func pruneLogs() {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.creationDateKey]
        let files = ((try? fm.contentsOfDirectory(at: logs, includingPropertiesForKeys: Array(keys))) ?? [])
            .map { ($0, (try? $0.resourceValues(forKeys: keys).creationDate) ?? .distantPast) }
            .sorted { $0.1 < $1.1 }.map(\.0)
        let runs = files.map { $0.deletingPathExtension().lastPathComponent }
        var seen: [String] = []
        for r in runs where !seen.contains(r) { seen.append(r) }
        let drop = Set(seen.dropLast(logsKept))
        for (f, r) in zip(files, runs) where drop.contains(r) { try? fm.removeItem(at: f) }
    }

    /// A finished run's result card can still be answered (its process lingers): the helper does not restart under it.
    static var undoWaiting: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let l = lingering else { return false }
        return !l.closed && l.process.isRunning
    }

    /// The user's answer to the finished run's result card (op `respond`): `{"type":"respond","option":n}` on the
    /// lingering process's stdin. `wait` seconds (at most 15): wait for its `result_response` and return it.
    /// Undo acts on the Mac: the answer is let through only while the machine lock names this run, lingering, and it
    /// acts again until its result_response (ComputerLock.undo). Another task started on this Mac since ended it
    /// (owner 10-21): `undo_expired`.
    /// The run acts no more (its task_done, or its undo's result_response): the lock goes from the acting holder this
    /// run last wrote to lingering -- only if it is still exactly that.
    static func settle(_ l: Lingering) {
        lock.lock(); let h = l.holder; lock.unlock()
        guard let h, let n = ComputerLock.linger(h) else { return }
        lock.lock(); l.holder = n; lock.unlock()
    }

    static func respond(runID: String, option: Int, wait: Double = 0) -> [String: Any] {
        guard var line = try? JSONSerialization.data(withJSONObject: ["type": "respond", "option": option]) else {
            return ["ok": false, "error": "bad option"]
        }
        line.append(0x0A)
        // which run, under `lock`; the machine lock is asked outside it (its flock may wait on another process, and a
        // stop or an answer must not wait behind that), then the run is looked at again
        lock.lock()
        guard let l = lingering, !l.closed, l.process.isRunning else {
            let expired = expiredRun.map { runID.isEmpty || runID == $0 } ?? false
            lock.unlock()
            return expired ? undoExpired : ["ok": false, "error": "no finished run is waiting for an answer"]
        }
        if !runID.isEmpty && runID != l.runID {
            lock.unlock(); return ["ok": false, "error": "the run waiting for an answer is \(l.runID), not \(runID)"]
        }
        if l.responded {
            lock.unlock(); return ["ok": false, "code": "busy", "error": "this result card was answered already"]
        }
        l.responded = true    // this answer's: a second one waits for nothing
        let seen = l.holder
        lock.unlock()
        switch seen.map(ComputerLock.undo) ?? .expired {
        case .ok(let acting): lock.lock(); l.holder = acting; lock.unlock()
        case .busy:
            lock.lock(); l.responded = false; lock.unlock()   // not this answer's: the card can still be answered after it
            return ["ok": false, "code": "busy", "error": "an answer to this card is being carried out"]
        case .failed:
            lock.lock(); l.responded = false; lock.unlock()
            return ["ok": false, "error": "the machine lock could not be read or written"]
        case .expired:
            lock.lock(); l.close(); if lingering === l { lingering = nil }; expiredRun = l.runID; lock.unlock()
            NSLog("DeskMind Hands: respond refused: another computer task started on this Mac since \(l.runID)")
            return undoExpired
        }
        lock.lock()
        let gone = l.closed || !l.process.isRunning
        if !gone {
            do { try l.input.write(contentsOf: line) } catch {
                lock.unlock()
                settle(l)
                return ["ok": false, "error": "write: \(error.localizedDescription)"]
            }
        }
        lock.unlock()
        if gone { settle(l); return undoExpired }
        let until = Date().addingTimeInterval(min(max(wait, 0), 15))
        while Date() < until {
            lock.lock(); let r = l.response; lock.unlock()
            if let r { return ["ok": true, "run_id": l.runID, "result": r] }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return ["ok": true, "run_id": l.runID]
    }

    private static let undoExpired: [String: Any] = ["ok": false, "code": "undo_expired",
                                                      "error": "another computer task started on this Mac; this task's undo has expired"]

    /// While `l` lingers, until its process exits (it answered its card, its linger ran out, or a new task on this Mac
    /// ended its group: its undo expired). The machine lock goes once nothing of its group is left.
    static func watchLingering(_ l: Lingering) {
        l.process.waitUntilExit()
        lock.lock()
        if !l.responded { expiredRun = l.runID }
        l.close(); if lingering === l { lingering = nil }
        lock.unlock()
        ComputerLock.free(runID: l.runID, pgid: l.pgid)
        // gone during an undo (the lock still says it acts): what is left of its group is ended after a grace
        ComputerLock.reapLeftovers(runID: l.runID, pgid: l.pgid)
    }

    /// The lingering run was ended (「清除全部」): its card can no longer be answered. True, for chaining.
    @discardableResult
    static func dropLingering() -> Bool {
        lock.lock(); if let l = lingering { l.close(); lingering = nil; expiredRun = l.runID }; lock.unlock()
        return true
    }

    /// Whether `p` is a finished run's lingering process (the stop path leaves it alone).
    static func isLingering(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return lingering?.process === p
    }

    static var node: URL { Runner.runtime.appendingPathComponent("node/bin/node") }
    static var bundle: URL { Runner.runtime.appendingPathComponent("harness/harness.mjs") }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: node.path) && FileManager.default.fileExists(atPath: bundle.path) }

    /// The model services' settings, until the app has a place for keys: KEY=VALUE lines in
    /// Application Support/DeskMind/models.env (DEEPSEEK_API_KEY for the default config, OPENROUTER_API_KEY,
    /// VOLCENGINE_API_KEY, YY_URL + YY_API_KEY for the in-house gateway). Values never logged.
    static func modelEnv() -> [String: String] {
        let url = DeskMindIPC.supportDir.appendingPathComponent("models.env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            if !k.isEmpty { out[k] = v }
        }
        return out
    }

    /// `harness.mjs model-check --config X` with the keys from models.env: {ok, model, ms} or {ok: false, error}.
    /// The harness strips anything key-like from a service's error; nothing here logs the environment.
    static func modelCheck(config: String, extra: [String: String] = [:]) -> [String: Any] {
        guard available else { return ["ok": false, "error": "this build has no harness runtime"] }
        let p = Process()
        p.executableURL = node
        p.arguments = [bundle.path, "model-check", "--config", config]
        var env: [String: String] = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        for (k, v) in modelEnv() { env[k] = v }
        for (k, v) in extra where k.range(of: "^[A-Z][A-Z0-9_]*$", options: .regularExpression) != nil { env[k] = v }   // the sheet's unsaved values
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return ["ok": false, "error": "launch: \(error.localizedDescription)"] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Any] ?? ["ok": false, "error": "no answer from the harness (exit \(p.terminationStatus))"]
    }

    /// The harness's environment, for a run (`app-run`) and for a chat session (`session`, SessionHost), whose
    /// executors inherit it: the model keys (models.env), Brain as the first judge, the judge's learning files, and the
    /// execution layer (hands' executor on the bundled Python). `apps`: the apps a request names, which may be brought
    /// forward for a step (a session names none: its tasks are not known when it starts).
    /// `keys`: models.env as already read (a session's one read, its digest's: SessionHost.spawn); nil: read here.
    static func environment(apps: [String] = [], keys: [String: String]? = nil) -> [String: String] {
        let runtime = Runner.runtime, work = Runner.work
        let python = runtime.appendingPathComponent("python/bin/python3.12").path
        let pythonPath = "\(work.path):\(runtime.appendingPathComponent("site").path)"
        // The vision model, as for `hands do` (Runner.run): when the run may drive an app with no accessibility tree
        // and the model is downloaded, the Eyes server is up before the first step, and the executor's driver reads
        // such a window from its pixels (OCR words, grounded controls) — the same observe/perform, another source.
        // Which apps a task uses is not known before the run any more (the app reads no app names out of the
        // instruction, owner 10-20), so the vision model is started on demand: the executor is told where it would
        // be and how to ask for it (this helper's socket, op "eyes"), and the first time a window has to be read from
        // its pixels it asks, and waits the five seconds or so it takes. Loading it for every run cost ~4 GB beside
        // Brain's on a 16 GB Mac (deskmind #96 review).
        var eyes = ""
        if DeskMindModels.eyesDir() != nil {
            eyes = "HANDS_GROUNDER_URL=\"\(EyesServer.url)\" HANDS_GROUNDER_TOKEN=\"\(ServerAuth.token)\" "
                + "HANDS_HELPER_SOCKET=\"\(DeskMindIPC.socketPath)\" "
        }
        var env: [String: String] = [
            "HOME": NSHomeDirectory(),
            "PATH": "\(runtime.appendingPathComponent("bin").path):/usr/bin:/bin",
            "DESKMIND_MACTOOLS": runtime.appendingPathComponent("bin/mactools").path,
            "DESKMIND_BRAIN_URL": BrainServer.url, "DESKMIND_BRAIN_TOKEN": ServerAuth.token,
            // DeskMind Brain answers the executor's judge questions first (it may approve on its own above the floor,
            // never refuse alone; the cloud model decides the rest): measured 10-18 on the gym, 70% settled locally,
            // 0 wrong approvals, 20/20 passed. Off when the server is not up: the cloud model judges alone.
            "DESKMIND_BRAIN_JUDGE": BrainServer.status()["state"] as? String == "ready" ? "1" : "0",
            // The judge's routing table (which question kinds Brain is asked) learns across runs from sampled shadow
            // comparisons with the cloud judge (one in ten settled answers): docs/localization-2026-10-19.md
            "DESKMIND_JUDGE_STATS": DeskMindIPC.supportDir.appendingPathComponent("judge-stats.json").path,
            "DESKMIND_JUDGE_SHADOW": "0.1",
            // the cloud judge is asked alongside Brain and abandoned when Brain settles: a refusing Brain costs no time
            "DESKMIND_JUDGE_RACE": "1",
            // the execution layer: hands' executor on the bundled Python, in the same working copy `hands do` uses
            "DESKMIND_HANDS_DIR": work.path,
            "DESKMIND_HANDS_CMD": "PYTHONPATH=\"\(pythonPath)\" PYTHONNOUSERSITE=1 PYTHONUNBUFFERED=1 "
                + "PYTHONPYCACHEPREFIX=\"\(DeskMindIPC.supportDir.appendingPathComponent("pycache").path)\" "
                + "HANDS_PEEKABOO_TRANSPORT=mcp HANDS_PERMISSIONS_VERIFIED=\(CGPreflightScreenCaptureAccess() ? "1" : "0") "
                + "HANDS_SPECTATOR_APPS=ai.deskmind.app,ai.deskmind.hands "
                // the apps the request names may be brought forward for a step (briefly, only while the user is
                // still; the executor adds any app it opened a window of); a person at their Mac is waited for
                + "HANDS_FLASH_APPS=\"\(apps.joined(separator: ","))\" HANDS_FLASH_WAIT_S=1800 "
                + "HANDS_TAKEOVER_FILE=\"\(Runner.takeoverFile.path)\" " + eyes
                + "\"\(python)\" -m deskmind_hands.executor",
        ]
        for (k, v) in keys ?? modelEnv() where env[k] == nil { env[k] = v }
        return env
    }

    /// The user's answer (the main app's `answer` request) to the open card: the clicked option's index, the approve
    /// option, the way out, or their words. Refused -- `{ok: false, code: "stale_card"}` -- when the request names a
    /// card that is no longer the open one, or an option that is not the open card's: the window showed an older card
    /// (voided by a steer, say) while the helper already held the next, and Approve on the old plan must not approve
    /// the new one. The window has dropped the card it answered either way; the open card comes as its own ask.
    static func answer(_ req: [String: Any]) -> [String: Any] {
        let button = HarnessEvents.CardButton(request: req)
        let askID = req["ask_id"] as? String
        lock.lock(); defer { lock.unlock() }
        guard let h = input else { return ["ok": false, "error": "no harness run is going"] }
        if let why = HarnessEvents.refusal(button, askID: askID, state: state) {
            NSLog("DeskMind Hands: answer not sent: \(why)")
            return ["ok": false, "code": "stale_card", "error": why]
        }
        // cloud models off: only the way out and undo (no model needed); anything else would let the run go on
        if SessionHost.modelsOffNow && !HarnessEvents.needsNoModel(button, state: state) {
            return ["ok": false, "code": "no_model",
                    "error": L("The cloud model is off. Turn it on in the model settings to run this task.", lang: ResolvedLang.current)]
        }
        guard let line = HarnessEvents.answerLine(button, askID: askID, state: state),
              var data = try? JSONSerialization.data(withJSONObject: line) else { return ["ok": false, "error": "nothing to send for this button"] }
        data.append(0x0A)
        do { try h.write(contentsOf: data) } catch { return ["ok": false, "error": "write: \(error.localizedDescription)"] }
        state.askID = nil; state.askOptions = []
        return ["ok": true]
    }

    static func run(_ spec: Runner.Spec, emit unlocked: @escaping ([String: Any]) -> Bool) {
        let emitLock = NSLock()
        let emit: ([String: Any]) -> Bool = { e in emitLock.lock(); defer { emitLock.unlock() }; return unlocked(e) }
        // Busy (since the request was taken: Runner.accept) until task_done (this function returns then), not until the
        // process exits: it lingers for the result card's answer, and the next run may start meanwhile.
        defer { Runner.busy = false }
        Runner.clearing.lock(); Runner.clearing.unlock()    // a 「清除全部」 going ends first: it takes none of this run's files
        guard available else {
            _ = emit(["event": "error", "code": "harness_missing", "error": "this build has no harness runtime"]); return
        }
        do { try Runner.prepareWork() } catch {
            _ = emit(["event": "error", "error": "prepare: \(error.localizedDescription)"]); return
        }
        let fm = FileManager.default
        let work = Runner.work
        let runs = Runner.harnessRuns
        try? fm.createDirectory(at: runs, withIntermediateDirectories: true)
        defer { if DeskMindModels.eyesDir() != nil { EyesServer.touch() } }   // the idle clock starts when the run ends

        let p = Process()
        p.executableURL = node
        p.arguments = [bundle.path, "app-run", "--runs", runs.path, "--linger", String(lingerSeconds)]
        p.currentDirectoryURL = work
        p.environment = environment(apps: spec.apps.map(\.bundle))
        let outPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardInput = inPipe
        // the run's id is the helper's, so its logs are named before the process starts (the harness takes it as given)
        let runID = spec.runID ?? "run_" + UUID().uuidString.lowercased().prefix(8)
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let errURL = logs.appendingPathComponent("\(runID).stderr")
        fm.createFile(atPath: errURL.path, contents: nil)
        p.standardError = try? FileHandle(forWritingTo: errURL)
        let outURL = logs.appendingPathComponent("\(runID).stdout")
        fm.createFile(atPath: outURL.path, contents: nil)
        let outLog = try? FileHandle(forWritingTo: outURL)
        pruneLogs()    // after this run's files are made, so they count among the ones kept
        // One path, under the machine lock (ComputerLock): accepted (Runner.accept, before this function) → the lock →
        // launched (Runner.launch, under the stop's lock: a stop since it was accepted keeps it from starting). In one
        // guarded step: refused while a task acts on this Mac; a finished run lingering for its card (this helper's,
        // or a session's) is ended -- its undo expires; the harness is started (a process group of its own) and named
        // in the lock, before it is sent its task. Refused or not started: busy is let go by the defer above.
        var launchError = "", stoppedFirst = false
        var acquired: SessionWire.Holder?
        switch ComputerLock.acquire(runID: runID, by: "helper", spawn: {
            do {
                guard try Runner.launch(p) else { stoppedFirst = true; return nil }
                return p.processIdentifier
            } catch { launchError = error.localizedDescription; return nil }
        }) {
        case .busy(let h):
            NSLog("DeskMind Hands: run refused: \(h.runID) (\(h.by)) acts on this Mac")
            _ = Runner.release(); _ = emit(ComputerLock.busy); return
        case .alive(let h):
            NSLog("DeskMind Hands: run refused: the lingering run \(h.runID) would not end")
            _ = Runner.release(); _ = emit(stillRunning); return
        case .failed(let why):
            NSLog("DeskMind Hands: run refused: \(why)")
            _ = Runner.release(); _ = emit(["event": "error", "error": why]); return
        case .ok(nil):
            _ = Runner.release()
            if stoppedFirst { _ = emit(["event": "done", "exit": 0, "reason": "cancelled", "passed": 0, "total": 0, "stderr_tail": ""]) }
            else { _ = emit(["event": "error", "error": "launch: \(launchError)"]) }
            return
        case .ok(let h):
            acquired = h
        }
        // this helper's own lingering run, if it was the one ended: its card can no longer be answered
        lock.lock(); if let l = lingering { l.close(); lingering = nil; expiredRun = l.runID }; lock.unlock()
        // once task_done is passed on (`linger.over`), the run's lines go to `linger` (result_response), not to this
        // run's connection, and the state is the next run's
        let linger = Lingering(process: p, input: inPipe.fileHandleForWriting)
        linger.runID = runID
        linger.holder = acquired
        lock.lock(); state = HarnessEvents.State(); input = inPipe.fileHandleForWriting; stoppedForModelsOff = false; lock.unlock()
        // a stop between the launch and here found no stdin to write to (it terminated the process): the stop line too
        if Runner.cancelled { Runner.stopRequested = true; stop(p) }
        // cloud models turned off since the run was accepted (refusesRun), while it waited for the lock or its folder:
        // its stop found no run going (input was nil), so it is seen here — `input` set first, then the bit read, as
        // models.off sets the bit, then stops: the request never goes, the harness ends with nothing to do
        let offSinceAccepted = SessionHost.modelsOffNow
        if offSinceAccepted {
            NSLog("DeskMind Hands: cloud models off before the run started: not starting it")
            lock.lock(); stoppedForModelsOff = true; lock.unlock()
            Runner.stopRequested = true
            try? inPipe.fileHandleForWriting.close()      // (no request: it exits at once)
        }

        // The request: one JSON line, then stdin stays open for answers.
        var req: [String: Any] = ["run_id": runID, "raw": spec.goal ?? "", "config": spec.config, "lang": spec.lang, "driver": "hands",
                                  "apps": spec.apps.map(\.bundle)]
        if let folder = spec.folder { req["scope"] = folder }
        if !offSinceAccepted, var line = try? JSONSerialization.data(withJSONObject: req) { line.append(0x0A); try? inPipe.fileHandleForWriting.write(contentsOf: line) }
        if spec.liveView {
            // the new engine names no apps before the run: the card waits for the first step's window, not Finder
            LiveCard.start(bundles: spec.apps.map(\.bundle), goal: spec.goal ?? "", onStop: Runner.requestStop)
        }
        defer { LiveCard.finish(nil) }

        let reader = DispatchGroup()
        reader.enter()
        let pid = Int(p.processIdentifier)
        DispatchQueue.global().async {
            defer { reader.leave() }
            let h = outPipe.fileHandleForReading
            var pending = Data()
            while true {
                let chunk = h.availableData
                if chunk.isEmpty { break }
                try? outLog?.write(contentsOf: chunk)
                pending.append(chunk)
                while let nl = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<nl]
                    pending.removeSubrange(pending.startIndex...nl)
                    guard let e = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                    lock.lock()
                    if linger.over {
                        // the answer is carried out: it acts no more
                        if e["kind"] as? String == "result_response" {
                            linger.response = e
                            lock.unlock(); settle(linger); continue
                        }
                        lock.unlock(); continue
                    }
                    let out = HarnessEvents.translate(e, state: &state, title: spec.goal ?? "", hasFolder: spec.folder != nil, pid: pid)
                    lock.unlock()
                    for ev in out {
                        show(ev)
                        pass(ev, linger: linger, emit: emit)
                    }
                }
            }
        }
        // The run is over at task_done, or when the process ends without one (then its last lines are read first).
        let isOver = { lock.lock(); defer { lock.unlock() }; return linger.over }
        while p.isRunning && !isOver() { Thread.sleep(forTimeInterval: 0.25) }
        if !isOver() { _ = reader.wait(timeout: .now() + 3) }
        // no longer the run's process before its stdin is let go: a stop from now on would find no stdin and kill a
        // process kept up for the result card (its undo with it); whether this run was stopped, read once
        let stopped = Runner.release()
        lock.lock()
        linger.over = true; input = nil
        let lingers = p.isRunning
        // registered at task_done already (pass); not again once it was let go meanwhile (undo expired)
        if lingers { if !linger.closed { lingering = linger } } else { linger.close(); if lingering === linger { lingering = nil } }
        lock.unlock()
        if !lingers {
            // its harness gone: the lock goes with its group; what is left of it after a run that never said task_done
            // still acts (the next task is refused) until it ends, or is ended after a grace (reapLeftovers decides on
            // the lock's state)
            ComputerLock.free(runID: runID, pgid: p.processIdentifier)
            ComputerLock.reapLeftovers(runID: runID, pgid: p.processIdentifier)
        }
        if lingers {
            // The process waits up to `lingerSeconds` for the result card's answer (op respond), then exits; or sooner,
            // when a new task on this Mac ends its group (ComputerLock.acquire). Its log is closed once it is gone.
            DispatchQueue.global().async {
                watchLingering(linger)
                _ = reader.wait(timeout: .now() + 3)
                try? outLog?.close()
            }
        } else {
            _ = reader.wait(timeout: .now() + 3)    // the last lines into the log (at once when they are read already)
            try? outLog?.close()
        }
        LiveCard.finish(stopped ? .stopped : ending(state.finished?["harness_status"] as? String))
        let tail = String(decoding: ((try? Data(contentsOf: errURL)) ?? Data()).suffix(600), as: UTF8.self)
        Runner.pruneHarnessRuns(keep: 10)    // after the run, so this one counts among the ten kept
        // a lingering process has no exit status yet (reading it would raise); a run that wrote task_done needs none
        var done = HarnessEvents.done(state: state, terminationStatus: lingers ? 0 : p.terminationStatus, stopped: stopped, stderrTail: tail)
        // stopped because cloud models went off: said so (the harness records it as a stop by the app; the window says why)
        lock.lock(); let forModelsOff = stoppedForModelsOff; lock.unlock()
        if forModelsOff { done = HarnessEvents.stoppedForModelsOff(done) }
        _ = emit(done)
    }

    /// What the live card and the recording make of one of the app's events (HarnessEvents.translate): the run waits
    /// for the user, pauses while they use the Mac, or takes a step in a window (the card follows that window, the
    /// recording takes in its app). For a run of this helper's own and for a task of a chat session (SessionHost) alike.
    static func show(_ ev: [String: Any]) {
        switch ev["event"] as? String {
        case "ask":
            LiveCard.status(.waitingForUser, words: ev["approval"] as? Bool == true
                            ? L("Waiting for your approval in DeskMind", lang: ResolvedLang.current)
                            : L("Waiting for your answer in DeskMind", lang: ResolvedLang.current))
        case "waiting" where ev["ask_id"] == nil:   // the executor waits for the user to pause
            LiveCard.status(.paused, words: L("Paused while you use your Mac", lang: ResolvedLang.current))
        case "resumed" where ev["ask_id"] == nil, "ask_closed":
            LiveCard.status(.working)
        case "step":
            // The card shows the window the step acted in: the executor names it by bundle id and
            // CGWindow number (window:<bundle>#<number>), which is what the card captures by.
            if let n = windowNumber(ev) { LiveCard.observed(windows: [["id": n, "active": true]], app: "") }
            recordApp(ev)
            let human = ev["human"] as? String ?? ""
            LiveCard.stepped(n: ev["n"] as? Int ?? 0, words: human, target: nil,
                             click: human.hasPrefix("click") || human.hasPrefix("double-click") || human.hasPrefix("select"))
        default: break
        }
    }

    /// The recording's part of an event: a step in a window takes that window's app into the recording, as it goes (no
    /// list before). For a live task whose card is not shown (another session's) it is all there is.
    static func recordApp(_ ev: [String: Any]) {
        guard ev["event"] as? String == "step", windowNumber(ev) != nil, let object = ev["object"] as? String else { return }
        let bundle = HarnessEvents.appOf(object)
        if !bundle.isEmpty { ScreenRecorder.addApp(bundle) }
    }

    /// A step's window (window:<bundle>#<number>): its CGWindow number.
    private static func windowNumber(_ ev: [String: Any]) -> Int? {
        guard let object = ev["object"] as? String, let hash = object.lastIndex(of: "#") else { return nil }
        return Int(object[object.index(after: hash)...])
    }

    /// How the live card says a task ended, from its task_done status.
    static func ending(_ status: String?) -> LiveView.Status {
        switch status {
        case "succeeded": return .done
        case "stopped", "cancelled": return .stopped
        default: return .failed
        }
    }

    /// Cloud models turned off (models.off): a harness op run going is stopped by its normal stop path (Runner's
    /// Stop), and says why (`stoppedForModelsOff`: its done event's reason "models_off"); one that wrote task_done and
    /// lingers for its result card is left alone (its undo needs no model). A run accepted but not started yet sees the
    /// bit itself before its request goes (run): models.off sets the bit before it calls this, so one side always
    /// sees the other.
    static func stopForModelsOff() {
        lock.lock(); let going = input != nil; lock.unlock()
        guard going, let p = Runner.current, p.isRunning, !isLingering(p) else { return }
        NSLog("DeskMind Hands: cloud models off: stopping the harness run")
        lock.lock(); stoppedForModelsOff = true; lock.unlock()
        Runner.requestStop()
    }
    /// This run was stopped because cloud models went off (reset at each run's start).
    nonisolated(unsafe) static var stoppedForModelsOff = false
    /// The processes a stop was already scheduled for: a stop asked again (a repeated models.off, Stop pressed twice)
    /// schedules no second interrupt — a second SIGINT would cut short the harness's wait for an action still out at
    /// the driver.
    nonisolated(unsafe) private static var stopping: Set<Int32> = []
    /// How many stops scheduled their signals (tests).
    nonisolated(unsafe) static var stopSchedules = 0

    /// Stop: the harness reads `{"stop":true}` on its stdin as the stop switch (its executor refuses every action from
    /// then on and the run ends as stopped); a process that does not end on that is interrupted, then terminated.
    /// The interrupt starts the harness's own stop: up to 0.8 s for the run to end, then up to 10 s more for an action
    /// still out at the driver (docs/protocol.md, signals). A second signal cuts that wait short, so the terminate
    /// comes 12 s after the interrupt (15 s after the stop line; it was 8 s, inside the wait). A run that has written
    /// task_done and lingers for the result card's answer is left alone. Once per process.
    static func stop(_ p: Process) {
        lock.lock()
        let pid = p.processIdentifier
        guard !stopping.contains(pid) else { lock.unlock(); return }
        stopping.insert(pid)
        stopSchedules += 1
        if let h = input, var line = try? JSONSerialization.data(withJSONObject: ["stop": true]) { line.append(0x0A); try? h.write(contentsOf: line) }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning && !isLingering(p) { p.interrupt() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            if p.isRunning && !isLingering(p) { p.terminate() }
            lock.lock(); stopping.remove(pid); lock.unlock()
        }
    }
}
