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
    /// Application Support/DeskMind/models.env (YY_URL, YY_API_KEY, OPENROUTER_API_KEY, ...). Values never logged.
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
        let runs = DeskMindIPC.supportDir.appendingPathComponent("work/harness-runs")
        try? fm.createDirectory(at: runs, withIntermediateDirectories: true)
        let python = runtime.appendingPathComponent("python/bin/python3.12").path
        let pythonPath = "\(work.path):\(runtime.appendingPathComponent("site").path)"

        let p = Process()
        p.executableURL = node
        p.arguments = [bundle.path, "app-run", "--runs", runs.path]
        p.currentDirectoryURL = work
        var env: [String: String] = [
            "HOME": NSHomeDirectory(),
            "PATH": "\(runtime.appendingPathComponent("bin").path):/usr/bin:/bin",
            "DESKMIND_MACTOOLS": runtime.appendingPathComponent("bin/mactools").path,
            "DESKMIND_BRAIN_URL": BrainServer.url, "DESKMIND_BRAIN_TOKEN": ServerAuth.token,
            // the execution layer: hands' executor on the bundled Python, in the same working copy `hands do` uses
            "DESKMIND_HANDS_DIR": work.path,
            "DESKMIND_HANDS_CMD": "PYTHONPATH=\"\(pythonPath)\" PYTHONNOUSERSITE=1 PYTHONUNBUFFERED=1 "
                + "PYTHONPYCACHEPREFIX=\"\(DeskMindIPC.supportDir.appendingPathComponent("pycache").path)\" "
                + "HANDS_PEEKABOO_TRANSPORT=mcp HANDS_PERMISSIONS_VERIFIED=\(CGPreflightScreenCaptureAccess() ? "1" : "0") "
                + "HANDS_SPECTATOR_APPS=ai.deskmind.app,ai.deskmind.hands "
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
                        if ev["event"] as? String == "ask" {
                            LiveCard.status(.waitingForUser, words: ev["approval"] as? Bool == true
                                            ? L("Waiting for your approval in DeskMind", lang: ResolvedLang.current)
                                            : L("Waiting for your answer in DeskMind", lang: ResolvedLang.current))
                        }
                        if ev["event"] as? String == "step" { LiveCard.status(.working) }
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
        _ = emit(HarnessEvents.done(state: state, terminationStatus: p.terminationStatus, stopped: stopped, stderrTail: tail))
    }

    /// Stop: the harness has no stdin command for it (a line without an ask_id would be read as an answer), so the
    /// process is asked to end, then ended. Its executor refuses every action from the first signal on.
    static func stop(_ p: Process) {
        p.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
    }
}
