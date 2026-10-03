// The vision model: DeskMind Eyes' grounding server, which hands asks "where is the search box?" when an app has no
// accessibility tree to read (NetEase Cloud Music, most Electron and game-engine apps). Run by the helper as a child
// on a fixed localhost port, like the Brain -- but only on demand: it holds about 4 GB while loaded, on top of the
// Brain's 7, and a user who only ever works with Finder and TextEdit should never pay for it. So it is started before
// a run when the model is downloaded (or as soon as a request names such an app: see Runner.prewarm), and
// stopped after thirty minutes with no run.
//
// The server (deskmind_eyes/ground_server.py) has one endpoint, POST /ground, and starts listening only once the
// model is loaded: an open port is the readiness signal.

import Foundation

enum EyesServer {
    static let port = 18851
    static var url: String { "http://127.0.0.1:\(port)/ground" }
    static var healthURL: String { "http://127.0.0.1:\(port)/health" }
    /// Thirty minutes: at ten, a user coming back to DeskMind a quarter of an hour later waited ~10 s for it to load
    /// again, on top of the rest of the first look.
    static let idleLimit: TimeInterval = 1800

    nonisolated(unsafe) static var process: Process?
    nonisolated(unsafe) static var state = "stopped"      // stopped | missing | loading | ready | failed
    nonisolated(unsafe) static var detail = ""
    nonisolated(unsafe) static var lastUsed = Date()
    nonisolated(unsafe) private static var watching = false
    private static let lock = NSLock()

    static var logURL: URL { DeskMindIPC.supportDir.appendingPathComponent("eyes.log") }

    /// Is something answering on the port? A TCP connect, not an HTTP request: the server has no GET route, and
    /// an error page would read as "up" or "down" depending on the client.
    static func listening() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// Start the server if the model is in place and it is not already up. Safe to call repeatedly.
    static func ensure() {
        lock.lock(); defer { lock.unlock() }
        lastUsed = Date()
        if let p = process, p.isRunning { return }
        // One left by an earlier helper (a restart after a grant) is still on the port: use it -- only when it proves
        // to be ours (see ServerAuth).
        if listening() {
            if ServerAuth.ours(healthURL) { state = "ready"; detail = "adopted"; return }
            if !ServerAuth.reclaimStale(port: port) {
                state = "failed"; detail = "port \(port) is used by another program"; return
            }
        }
        guard let dir = DeskMindModels.eyesDir() else {
            state = "missing"; detail = "the vision model is not downloaded"; return
        }
        let runtime = Runner.runtime
        let p = Process()
        p.executableURL = runtime.appendingPathComponent("python/bin/python3.12")
        p.arguments = ["-m", "deskmind_eyes.ground_server", "--model", dir.path, "--port", "\(port)"]
        p.currentDirectoryURL = DeskMindIPC.supportDir
        p.environment = [
            "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin",
            "PYTHONPATH": runtime.appendingPathComponent("site-eyes").path,
            "PYTHONNOUSERSITE": "1", "PYTHONUNBUFFERED": "1",
            "PYTHONPYCACHEPREFIX": DeskMindIPC.supportDir.appendingPathComponent("pycache").path,
            // Nothing leaves the machine: the processor and weights are a local directory.
            "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
            "DESKMIND_EYES_TOKEN": ServerAuth.token,
        ]
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        p.standardOutput = log; p.standardError = log
        p.terminationHandler = { proc in
            lock.lock(); defer { lock.unlock() }
            if process === proc { process = nil; state = "failed"; detail = "exited with \(proc.terminationStatus)" }
        }
        do { try p.run() } catch { state = "failed"; detail = error.localizedDescription; return }
        process = p; state = "loading"; detail = ""
        DispatchQueue.global().async {
            for _ in 0..<180 {
                if process !== p { return }
                if listening() {
                    lock.lock(); if process === p { state = "ready" }; lock.unlock()
                    return
                }
                Thread.sleep(forTimeInterval: 1)
            }
            lock.lock(); if process === p { state = "failed"; detail = "did not answer within 3 minutes" }; lock.unlock()
        }
        watchIdle()
    }

    /// Wait until the server answers, at most `timeout` seconds. False if it is not there by then (still loading,
    /// failed, or no model): the run goes ahead, and a vision step that needs it reports the missing grounder.
    static func waitReady(timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            lock.lock(); let s = state; lock.unlock()
            if s == "ready" { return true }
            if s != "loading" || Runner.cancelled { return false }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// A run keeps it: the helper calls this when one ends, and the idle clock starts from there.
    static func touch() { lock.lock(); lastUsed = Date(); lock.unlock() }

    /// Once a minute: stopped after idleLimit with no run. A run in progress counts as use, however long it is.
    private static func watchIdle() {
        guard !watching else { return }
        watching = true
        DispatchQueue.global(qos: .utility).async {
            while true {
                Thread.sleep(forTimeInterval: 60)
                lock.lock()
                let running = process?.isRunning == true
                let idle = Date().timeIntervalSince(lastUsed)
                lock.unlock()
                if !running { break }
                if Runner.current != nil { touch(); continue }
                if idle > idleLimit { stop(); break }
            }
            lock.lock(); watching = false; lock.unlock()
        }
    }

    static func stop() {
        lock.lock(); defer { lock.unlock() }
        process?.terminate(); process = nil; state = "stopped"
    }

    static func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["state": state, "detail": detail, "url": url, "port": port,
                "present": DeskMindModels.eyesDir() != nil]
    }
}
