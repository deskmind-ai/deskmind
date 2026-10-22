// The wire between DeskMind.app and DeskMind Hands.app: one JSON object per line over a Unix socket.

import Foundation

enum DeskMindIPC {
    static let helperLabel = "ai.deskmind.hands"
    static let agentPlist = "ai.deskmind.hands.plist"

    /// A test's own folder in place of Application Support/DeskMind (tests/e2e: a run's files never touch the user's).
    nonisolated(unsafe) static var supportOverride: URL?

    static var supportDir: URL {
        if let o = supportOverride { return o }
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
    /// Deepest nesting of arrays and objects a streamed line may have: JSONSerialization recurses per level and a line
    /// a few hundred deep overflows a background thread's 512 KB stack (the watch runs on one). Nothing real comes
    /// near this deep.
    static let maxLineDepth = 100

    /// Whether `data`'s arrays and objects nest no deeper than `limit` (strings, with their escapes, skipped).
    static func nestingWithin(_ data: Data, limit: Int) -> Bool {
        var depth = 0, inString = false, escaped = false
        for b in data {
            if inString {
                if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
                continue
            }
            switch b {
            case 0x22: inString = true
            case 0x5B, 0x7B: depth += 1; if depth > limit { return false }
            case 0x5D, 0x7D: depth -= 1
            default: break
            }
        }
        return true
    }

    /// One streamed line as a JSON object; nil when it is not one, or nests deeper than `maxLineDepth`.
    static func lineObject(_ data: Data) -> [String: Any]? {
        guard nestingWithin(data, limit: maxLineDepth) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Send one request and hand every line of the reply to `onLine` until the helper closes the connection.
    /// Returns false when the helper is not listening.
    @discardableResult
    static func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Void) -> Bool {
        streamWhile(body) { onLine($0); return true }
    }

    /// The same, until the helper closes the connection or `onLine` returns false (the caller is done with it). With
    /// `idle`, `onIdle` is asked each time nothing came for that long; false ends the stream too.
    static func streamWhile(_ body: [String: Any], idle: TimeInterval? = nil, onIdle: (() -> Bool)? = nil,
                            _ onLine: @escaping ([String: Any]) -> Bool) -> Bool {
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
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let wait: Int32 = idle.map { Int32(max(1, $0 * 1000)) } ?? -1
        reading: while true {
            let r = poll(&pfd, 1, wait)
            if r < 0 { if errno == EINTR { continue }; break }
            if r == 0 { if let onIdle, !onIdle() { break reading }; continue }
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            pending.append(buf, count: n)
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                if let obj = lineObject(Data(line)), !onLine(obj) { break reading }
            }
        }
        return true
    }
}
