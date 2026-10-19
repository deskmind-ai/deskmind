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

    /// The user's answer to the open card: an option's index, or their words. False when nothing is asked.
    static func answer(reply: String, approve: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let h = input, let line = HarnessEvents.answerLine(reply: reply, approve: approve, state: state),
              var data = try? JSONSerialization.data(withJSONObject: line) else { return false }
        data.append(0x0A)
        do { try h.write(contentsOf: data) } catch { return false }
        state.askID = nil
        return true
    }

    static func run(_ spec: Runner.Spec, emit unlocked: @escaping ([String: Any]) -> Bool) {
        let emitLock = NSLock()
        let emit: ([String: Any]) -> Bool = { e in emitLock.lock(); defer { emitLock.unlock() }; return unlocked(e) }
        Runner.busy = true; Runner.cancelled = false
        defer { Runner.busy = false }
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
        var eyes = ""
        if spec.mayNeedVision && DeskMindModels.eyesDir() != nil {
            EyesServer.ensure()
            _ = emit(["event": "preparing", "what": "eyes"])
            if EyesServer.waitReady(timeout: 90) { eyes = "HANDS_GROUNDER_URL=\"\(EyesServer.url)\" HANDS_GROUNDER_TOKEN=\"\(ServerAuth.token)\" " }
        }
        defer { if !eyes.isEmpty { EyesServer.touch() } }   // the idle clock starts when the run ends

        let p = Process()
        p.executableURL = node
        p.arguments = [bundle.path, "app-run", "--runs", runs.path]
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
        let errURL = DeskMindIPC.supportDir.appendingPathComponent("work/last-run.stderr")
        fm.createFile(atPath: errURL.path, contents: nil)
        p.standardError = try? FileHandle(forWritingTo: errURL)
        let outURL = DeskMindIPC.supportDir.appendingPathComponent("work/last-run.stdout")
        fm.createFile(atPath: outURL.path, contents: nil)
        let outLog = try? FileHandle(forWritingTo: outURL)
        do { try p.run() } catch {
            _ = emit(["event": "error", "error": "launch: \(error.localizedDescription)"]); return
        }
        Runner.current = p; Runner.stopRequested = false
        lock.lock(); state = HarnessEvents.State(); input = inPipe.fileHandleForWriting; lock.unlock()

        // The request: one JSON line, then stdin stays open for answers.
        var req: [String: Any] = ["raw": spec.goal ?? "", "config": spec.config, "lang": spec.lang, "driver": "hands",
                                  "apps": spec.apps.map(\.bundle)]
        if let folder = spec.folder { req["scope"] = folder }
        if var line = try? JSONSerialization.data(withJSONObject: req) { line.append(0x0A); try? inPipe.fileHandleForWriting.write(contentsOf: line) }
        if spec.liveView {
            LiveCard.start(bundles: spec.apps.isEmpty ? ["com.apple.finder"] : spec.apps.map(\.bundle), goal: spec.goal ?? "", onStop: Runner.requestStop)
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
                        case "resumed" where ev["ask_id"] == nil:
                            LiveCard.status(.working)
                        case "step":
                            // The card shows the window the step acted in: the executor names it by bundle id and
                            // CGWindow number (window:<bundle>#<number>), which is what the card captures by.
                            if let object = ev["object"] as? String, let hash = object.lastIndex(of: "#"), let n = Int(object[object.index(after: hash)...]) {
                                LiveCard.observed(windows: [["id": n, "active": true]], app: "")
                            }
                            let human = ev["human"] as? String ?? ""
                            LiveCard.stepped(n: ev["n"] as? Int ?? 0, words: human, target: nil,
                                             click: human.hasPrefix("click") || human.hasPrefix("double-click") || human.hasPrefix("select"))
                        default: break
                        }
                        _ = emit(ev)
                    }
                }
            }
        }
        while p.isRunning { Thread.sleep(forTimeInterval: 0.25) }
        _ = reader.wait(timeout: .now() + 3)
        try? outLog?.close()
        lock.lock(); input = nil; lock.unlock()
        try? inPipe.fileHandleForWriting.close()
        let stopped = Runner.stopRequested
        Runner.stopRequested = false
        Runner.current = nil
        LiveCard.finish(stopped ? .stopped : state.finished?["harness_status"] as? String == "succeeded" ? .done : .failed)
        let tail = String(decoding: ((try? Data(contentsOf: errURL)) ?? Data()).suffix(600), as: UTF8.self)
        Runner.pruneHarnessRuns(keep: 10)    // after the run, so this one counts among the ten kept
        _ = emit(HarnessEvents.done(state: state, terminationStatus: p.terminationStatus, stopped: stopped, stderrTail: tail))
    }

    /// Stop: the harness reads `{"stop":true}` on its stdin as the stop switch (its executor refuses every action from
    /// then on and the run ends as stopped); a process that does not end on that is interrupted, then terminated.
    static func stop(_ p: Process) {
        lock.lock()
        if let h = input, var line = try? JSONSerialization.data(withJSONObject: ["stop": true]) { line.append(0x0A); try? h.write(contentsOf: line) }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.interrupt() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { if p.isRunning { p.terminate() } }
    }
}
