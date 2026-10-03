// The wire between DeskMind.app and DeskMind Hands.app: one JSON object per line over a Unix socket.

import Foundation

enum DeskMindIPC {
    static let helperLabel = "ai.deskmind.hands"
    static let agentPlist = "ai.deskmind.hands.plist"

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DeskMind", isDirectory: true)
    }

    static var socketPath: String { supportDir.appendingPathComponent("hands.sock").path }

    /// Every request carries the main app's language: the helper has no settings of its own (another bundle id,
    /// other defaults) and words its steps, hints and errors in the language of the last request it saw.
    static func withLang(_ body: [String: Any]) -> [String: Any] {
        var body = body
        if body["lang"] == nil { body["lang"] = ResolvedLang.current.rawValue }
        return body
    }

    /// Send one request and read one line back. Returns nil when the helper is not listening.
    static func request(_ body: [String: Any], timeout: TimeInterval = 20) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok, var data = try? JSONSerialization.data(withJSONObject: withLang(body)) else { return nil }
        data.append(0x0A)
        let sent = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        guard sent == data.count else { return nil }
        var reply = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            reply.append(buf, count: n)
            if buf[..<n].contains(0x0A) { break }
        }
        return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
    }
}

extension DeskMindIPC {
    /// Send one request and hand every line of the reply to `onLine` until the helper closes the connection.
    /// Returns false when the helper is not listening.
    @discardableResult
    static func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Void) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok, var data = try? JSONSerialization.data(withJSONObject: withLang(body)) else { return false }
        data.append(0x0A)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            pending.append(buf, count: n)
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { onLine(obj) }
            }
        }
        return true
    }
}
