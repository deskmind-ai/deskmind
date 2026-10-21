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
    /// answer's `result_response`, once the harness writes it.
    final class Lingering {
        let process: Process
        let input: FileHandle
        var runID = ""
        var response: [String: Any]?
        private var closed = false
        init(process: Process, input: FileHandle) { self.process = process; self.input = input }
        /// stdin closed (EOF): the harness stops waiting for a respond and exits. Once; called under `lock`.
        func close() { if !closed { closed = true; try? input.close() } }
    }
    nonisolated(unsafe) static var lingering: Lingering?

    /// Let the lingering run go, before a new run starts, so two harness processes never drive the desktop at once
    /// (an undo still going in the old one): its stdin is closed, so it exits (it would by itself after
    /// `lingerSeconds`); waited for up to 3 s, then terminated, and waited for up to 2 s more.
    static func closeLingering() {
        lock.lock()
        let l = lingering
        l?.close(); lingering = nil
        lock.unlock()
        guard let p = l?.process else { return }
        if waitForExit(p, seconds: 3) { return }
        NSLog("DeskMind Hands: the finished run's process did not exit on stdin closed; terminating it")
        p.terminate()
        if !waitForExit(p, seconds: 2) { NSLog("DeskMind Hands: the finished run's process is still running") }
    }

    private static func waitForExit(_ p: Process, seconds: Double) -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while p.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.05) }
        return !p.isRunning
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

    /// The user's answer to the finished run's result card (op `respond`): `{"type":"respond","option":n}` on the
    /// lingering process's stdin. `wait` seconds (at most 15): wait for its `result_response` and return it.
    static func respond(runID: String, option: Int, wait: Double = 0) -> [String: Any] {
        lock.lock()
        guard let l = lingering, l.process.isRunning else {
            lock.unlock(); return ["ok": false, "error": "no finished run is waiting for an answer"]
        }
        if !runID.isEmpty && runID != l.runID {
            lock.unlock(); return ["ok": false, "error": "the run waiting for an answer is \(l.runID), not \(runID)"]
        }
        guard var line = try? JSONSerialization.data(withJSONObject: ["type": "respond", "option": option]) else {
            lock.unlock(); return ["ok": false, "error": "bad option"]
        }
        line.append(0x0A)
        do { try l.input.write(contentsOf: line) } catch {
            lock.unlock(); return ["ok": false, "error": "write: \(error.localizedDescription)"]
        }
        lock.unlock()
        let until = Date().addingTimeInterval(min(max(wait, 0), 15))
        while Date() < until {
            lock.lock(); let r = l.response; lock.unlock()
            if let r { return ["ok": true, "run_id": l.runID, "result": r] }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return ["ok": true, "run_id": l.runID]
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
        Runner.busy = true; Runner.cancelled = false
        // Busy until task_done (this function returns then), not until the process exits: it lingers for the result
        // card's answer, and the next run may start meanwhile.
        defer { Runner.busy = false }
        closeLingering()    // after busy is set: no second run starts while it is waited for
        guard available else {
            _ = emit(["event": "error", "code": "harness_missing", "error": "this build has no harness runtime"]); return
        }
        do { try Runner.prepareWork() } catch {
            _ = emit(["event": "error", "error": "prepare: \(error.localizedDescription)"]); return
        }
        let fm = FileManager.default
        let runtime = Runner.runtime, work = Runner.work
        let runs = Runner.harnessRuns
        try? fm.createDirectory(at: runs, withIntermediateDirectories: true)
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
        defer { if !eyes.isEmpty { EyesServer.touch() } }   // the idle clock starts when the run ends

        let p = Process()
        p.executableURL = node
        p.arguments = [bundle.path, "app-run", "--runs", runs.path, "--linger", String(lingerSeconds)]
        p.currentDirectoryURL = work
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
                + "HANDS_FLASH_APPS=\"\(spec.apps.map(\.bundle).joined(separator: ","))\" HANDS_FLASH_WAIT_S=1800 "
                + "HANDS_TAKEOVER_FILE=\"\(Runner.takeoverFile.path)\" " + eyes
                + "\"\(python)\" -m deskmind_hands.executor",
        ]
        for (k, v) in modelEnv() where env[k] == nil { env[k] = v }
        p.environment = env
        let outPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardInput = inPipe
        // the run's id is the helper's, so its logs are named before the process starts (the harness takes it as given)
        let runID = "run_" + UUID().uuidString.lowercased().prefix(8)
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let errURL = logs.appendingPathComponent("\(runID).stderr")
        fm.createFile(atPath: errURL.path, contents: nil)
        p.standardError = try? FileHandle(forWritingTo: errURL)
        let outURL = logs.appendingPathComponent("\(runID).stdout")
        fm.createFile(atPath: outURL.path, contents: nil)
        let outLog = try? FileHandle(forWritingTo: outURL)
        pruneLogs()    // after this run's files are made, so they count among the ones kept
        do { try p.run() } catch {
            _ = emit(["event": "error", "error": "launch: \(error.localizedDescription)"]); return
        }
        Runner.current = p; Runner.stopRequested = false
        let linger = Lingering(process: p, input: inPipe.fileHandleForWriting)
        // set by the reader once task_done is passed on: from then on its lines go to `linger` (result_response), not
        // to this run's connection, and the state is the next run's
        var over = false
        lock.lock(); state = HarnessEvents.State(); input = inPipe.fileHandleForWriting; lock.unlock()

        // The request: one JSON line, then stdin stays open for answers.
        var req: [String: Any] = ["run_id": runID, "raw": spec.goal ?? "", "config": spec.config, "lang": spec.lang, "driver": "hands",
                                  "apps": spec.apps.map(\.bundle)]
        if let folder = spec.folder { req["scope"] = folder }
        if var line = try? JSONSerialization.data(withJSONObject: req) { line.append(0x0A); try? inPipe.fileHandleForWriting.write(contentsOf: line) }
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
                    if over {
                        if e["kind"] as? String == "result_response" { linger.response = e }
                        lock.unlock(); continue
                    }
                    let out = HarnessEvents.translate(e, state: &state, title: spec.goal ?? "", hasFolder: spec.folder != nil, pid: pid)
                    lock.unlock()
                    for ev in out {
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
                            if let object = ev["object"] as? String, let hash = object.lastIndex(of: "#"), let n = Int(object[object.index(after: hash)...]) {
                                LiveCard.observed(windows: [["id": n, "active": true]], app: "")
                                // the recording takes in each app the task works in, as it goes (no list before)
                                let bundle = HarnessEvents.appOf(object)
                                if !bundle.isEmpty { ScreenRecorder.addApp(bundle) }
                            }
                            let human = ev["human"] as? String ?? ""
                            LiveCard.stepped(n: ev["n"] as? Int ?? 0, words: human, target: nil,
                                             click: human.hasPrefix("click") || human.hasPrefix("double-click") || human.hasPrefix("select"))
                        default: break
                        }
                        _ = emit(ev)
                        if ev["event"] as? String == "task_done" {
                            lock.lock(); over = true; linger.runID = ev["run_id"] as? String ?? ""; lock.unlock()
                        }
                    }
                }
            }
        }
        // The run is over at task_done, or when the process ends without one (then its last lines are read first).
        let isOver = { lock.lock(); defer { lock.unlock() }; return over }
        while p.isRunning && !isOver() { Thread.sleep(forTimeInterval: 0.25) }
        if !isOver() { _ = reader.wait(timeout: .now() + 3) }
        lock.lock()
        over = true; input = nil
        let lingers = p.isRunning
        if lingers { lingering = linger } else { linger.close() }
        lock.unlock()
        if lingers {
            // The process waits up to `lingerSeconds` for the result card's answer (op respond), then exits; or sooner,
            // when the next run closes its stdin. Its log is closed once it is gone.
            DispatchQueue.global().async {
                p.waitUntilExit()
                _ = reader.wait(timeout: .now() + 3)
                try? outLog?.close()
                lock.lock(); linger.close(); if lingering === linger { lingering = nil }; lock.unlock()
            }
        } else {
            _ = reader.wait(timeout: .now() + 3)    // the last lines into the log (at once when they are read already)
            try? outLog?.close()
        }
        let stopped = Runner.stopRequested
        Runner.stopRequested = false
        Runner.current = nil
        LiveCard.finish(stopped ? .stopped : state.finished?["harness_status"] as? String == "succeeded" ? .done : .failed)
        let tail = String(decoding: ((try? Data(contentsOf: errURL)) ?? Data()).suffix(600), as: UTF8.self)
        Runner.pruneHarnessRuns(keep: 10)    // after the run, so this one counts among the ten kept
        // a lingering process has no exit status yet (reading it would raise); a run that wrote task_done needs none
        _ = emit(HarnessEvents.done(state: state, terminationStatus: lingers ? 0 : p.terminationStatus, stopped: stopped, stderrTail: tail))
    }

    /// Stop: the harness reads `{"stop":true}` on its stdin as the stop switch (its executor refuses every action from
    /// then on and the run ends as stopped); a process that does not end on that is interrupted, then terminated.
    /// The interrupt starts the harness's own stop: up to 0.8 s for the run to end, then up to 10 s more for an action
    /// still out at the driver (docs/protocol.md, signals). A second signal cuts that wait short, so the terminate
    /// comes 12 s after the interrupt (15 s after the stop line; it was 8 s, inside the wait). A run that has written
    /// task_done and lingers for the result card's answer is left alone.
    static func stop(_ p: Process) {
        lock.lock()
        if let h = input, var line = try? JSONSerialization.data(withJSONObject: ["stop": true]) { line.append(0x0A); try? h.write(contentsOf: line) }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning && !isLingering(p) { p.interrupt() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { if p.isRunning && !isLingering(p) { p.terminate() } }
    }
}
