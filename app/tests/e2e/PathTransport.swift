// The helper's socket wire (DeskMindIPC's), at a path of its own: the session e2e clients (SessionClientE2E,
// ShellE2E) reach the test helper through it.

import Foundation

/// SessionTransport over a socket path of its own (DeskMindIPC's wire, at another path).
final class PathTransport: SessionTransport {
    let path: String
    init(path: String) { self.path = path }

    private func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 } }
        if !ok { close(fd); return nil }
        return fd
    }

    private func write(_ fd: Int32, _ body: [String: Any]) -> Bool {
        guard var d = try? JSONSerialization.data(withJSONObject: body) else { return false }
        d.append(0x0A)
        return d.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, d.count) } == d.count
    }

    func request(_ body: [String: Any]) -> [String: Any]? {
        guard let fd = connect() else { return nil }
        defer { close(fd) }
        guard write(fd, body) else { return nil }
        var reply = Data(), buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            reply.append(buf, count: n)
            if buf[..<n].contains(0x0A) { break }
        }
        return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
    }

    func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool {
        guard let fd = connect() else { return false }
        defer { close(fd) }
        guard write(fd, body) else { return false }
        var pending = Data(), buf = [UInt8](repeating: 0, count: 8192)
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let r = poll(&pfd, 1, Int32(SessionClient.idleTick * 1000))
            if r < 0 { if errno == EINTR { continue }; break }
            if r == 0 { if !onIdle() || stopped { break }; continue }
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            pending.append(buf, count: n)
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                if let obj = DeskMindIPC.lineObject(Data(line)), !onLine(obj) { return true }
            }
        }
        return true
    }
    /// Ends the watch at its next quiet moment.
    var stopped = false
}
