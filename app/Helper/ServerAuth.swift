// The local model servers' token. Anything on this Mac can open 127.0.0.1:18850, so a server already on the port
// could be any program's: adopted as the Brain, it would see every screen state and steer a helper that holds
// Accessibility (10-02 review). The helper makes one random token per install (Application Support, 0600), starts
// the Brain and Eyes servers with it (DESKMIND_BRAIN_TOKEN, DESKMIND_EYES_TOKEN: they then answer nothing without it),
// hands sends it (SYSTEMONE_API_KEY, HANDS_GROUNDER_TOKEN), and a server found on the port is adopted only when it
// refuses a request without the token and answers one with it.

import Darwin
import Foundation
import Security

enum ServerAuth {
    static var tokenURL: URL { DeskMindIPC.supportDir.appendingPathComponent("servers.token") }

    /// The token, made on first use and kept, so a server started by an earlier helper (a restart after a grant)
    /// can still be adopted.
    static let token: String = {
        if let t = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           t.count >= 32 { return t }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: DeskMindIPC.supportDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tokenURL.path, contents: Data(t.utf8),
                                       attributes: [.posixPermissions: 0o600])
        return t
    }()

    /// The HTTP status of a GET, with or without the token; nil when nothing answers.
    static func status(_ url: String, withToken: Bool, timeout: TimeInterval = 3) -> Int? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        if withToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var code: Int?
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            code = (resp as? HTTPURLResponse)?.statusCode; done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        return code
    }

    /// Ours: it refuses a request without the token and answers one with it.
    static func ours(_ url: String) -> Bool {
        status(url, withToken: false) == 401 && status(url, withToken: true) == 200
    }

    /// A server on `port` run by DeskMind's own runtime (its executable inside a "DeskMind Hands.app" bundle's
    /// runtime), but not answering to this token: one an earlier version started before servers had tokens, still
    /// running after an update. It is stopped, so the port can be used again; true when the port is then free.
    /// Anything else on the port is left alone.
    static func reclaimStale(port: Int) -> Bool {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let out = Pipe(); lsof.standardOutput = out; lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return false }
        lsof.waitUntilExit()
        let pids = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        guard !pids.isEmpty else { return true }
        for pid in pids {
            var buf = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
            let path = String(cString: buf)
            guard path.contains("/DeskMind Hands.app/Contents/Resources/runtime/") else { return false }
        }
        pids.forEach { kill($0, SIGTERM) }
        for _ in 0..<50 {
            if status("http://127.0.0.1:\(port)/", withToken: false, timeout: 0.5) == nil { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }
}
