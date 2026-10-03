// The local planner: DeskMind Brain's server, one process serving both tiers (fast model answers, the routing
// rules escalate to the strong one), run by the helper as a child on a fixed localhost port and restarted if it
// dies. hands talks to it over /v1/systemone exactly as it talks to any planner.

import Foundation

enum BrainServer {
    static let port = 18850
    static var url: String { "http://127.0.0.1:\(port)" }
    static let modelName = "deskmind-local"

    nonisolated(unsafe) static var process: Process?
    nonisolated(unsafe) static var state = "stopped"      // stopped | missing | loading | ready | failed
    nonisolated(unsafe) static var detail = ""
    nonisolated(unsafe) static var startedAt = Date.distantPast
    private static let lock = NSLock()

    static var logURL: URL { DeskMindIPC.supportDir.appendingPathComponent("brain.log") }

    /// Start the server if the models are in place and it is not already up. Safe to call repeatedly.
    static func ensure() {
        lock.lock(); defer { lock.unlock() }
        if let p = process, p.isRunning { return }
        // A server left by an earlier helper (a restart after a grant) is still on the port: use it -- only when it
        // proves to be ours (see ServerAuth). Anything else on the port is not talked to.
        if ServerAuth.ours("\(url)/v1/models") { state = "ready"; detail = "adopted"; return }
        if ServerAuth.status("\(url)/v1/models", withToken: false) != nil && !ServerAuth.reclaimStale(port: port) {
            state = "failed"; detail = "port \(port) is used by another program"; return
        }
        guard let dirs = DeskMindModels.readyDirs(), let fast = dirs[.fast], let strong = dirs[.strong] else {
            state = "missing"; detail = "models are not downloaded yet"; return
        }
        let runtime = Runner.runtime
        let p = Process()
        p.executableURL = runtime.appendingPathComponent("python/bin/python3.12")
        p.arguments = ["-m", "deskmind_brain.serve",
                       "--predictor", "mlx:\(fast.path)", "--escalate-to", "mlx:\(strong.path)",
                       "--two-stage", "--port", "\(port)", "--model-name", modelName,
                       "--threshold", String(DeskMindModels.routingThreshold()),
                       // Routing decisions, metadata only (no request contents), next to the helper's other logs.
                       "--routing-log", DeskMindIPC.supportDir.appendingPathComponent("routing.jsonl").path]
        p.currentDirectoryURL = DeskMindIPC.supportDir
        p.environment = [
            "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin",
            "PYTHONPATH": runtime.appendingPathComponent("site-brain").path,
            "PYTHONNOUSERSITE": "1",
            "PYTHONPYCACHEPREFIX": DeskMindIPC.supportDir.appendingPathComponent("pycache").path,
            // Nothing leaves the machine: tokenizers and weights are local directories.
            "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
            "DESKMIND_BRAIN_TOKEN": ServerAuth.token,
        ]
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        p.standardOutput = log; p.standardError = log
        p.terminationHandler = { proc in
            lock.lock(); defer { lock.unlock() }
            if process === proc { process = nil; state = "failed"; detail = "exited with \(proc.terminationStatus)" }
        }
        do { try p.run() } catch { state = "failed"; detail = error.localizedDescription; return }
        process = p; state = "loading"; detail = ""; startedAt = Date()
        // Ready when /v1/models answers.
        DispatchQueue.global().async {
            for _ in 0..<180 {
                if process !== p { return }
                if ServerAuth.status("\(url)/v1/models", withToken: true) == 200 {
                    lock.lock(); if process === p { state = "ready" }; lock.unlock()
                    return
                }
                Thread.sleep(forTimeInterval: 1)
            }
            lock.lock(); if process === p { state = "failed"; detail = "did not answer within 3 minutes" }; lock.unlock()
        }
    }

    static func stop() {
        lock.lock(); defer { lock.unlock() }
        process?.terminate(); process = nil; state = "stopped"
    }

    static func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: Any] = ["state": state, "detail": detail, "url": url, "port": port,
                                  "uptime_s": process == nil ? 0 : Int(Date().timeIntervalSince(startedAt))]
        if state == "failed" {
            let (hint, action) = diagnose()
            out["hint"] = hint; out["action"] = action
        }
        return out
    }

    /// The last lines of brain.log, read as a user would need them: what went wrong and the one thing to do.
    /// action: "retry" | "redownload" | "free_memory" | "report".
    static func diagnose() -> (String, String) {
        let lang = ResolvedLang.current
        let tail = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").suffix(4000).lowercased()
        if detail.contains("used by another program") {
            return (L("Port %d is used by another program, so DeskMind will not talk to it. Quit that program (or restart the Mac), then click “Retry”.", port,
                      lang: lang), "retry")
        }
        if tail.contains("address already in use") {
            return (L("Port %d is taken: an old model server may still be running. Click “Retry” to restart it.", port,
                      lang: lang), "retry")
        }
        if tail.contains("out of memory") || tail.contains("memoryerror") || tail.contains("metal")
            && tail.contains("alloc") {
            return (L("Not enough memory: the models need about 7 GB free. Quit a few memory-hungry apps, then click “Retry”.",
                      lang: lang), "free_memory")
        }
        if tail.contains("safetensors") || tail.contains("no such file") || tail.contains("tokenizer")
            || tail.contains("unexpected end") || tail.contains("invalid header") {
            return (L("The model files look incomplete or damaged. Click “Re-download” to check them and fetch what's missing.",
                      lang: lang), "redownload")
        }
        if tail.contains("did not answer") || detail.contains("did not answer") {
            return (L("The model took over 3 minutes to load; the Mac may be busy. Click “Retry” to try again.", lang: lang), "retry")
        }
        return (L("The model server quit unexpectedly. Click “Retry”; if it keeps happening, open the log in Developer tools and send it to us.",
                  lang: lang), "report")
    }
}
