// The app's session client (Shared/SessionClient.swift, the reducer behind it) against the real helper: SessionE2E
// `serve` (Helper/SessionHost.swift on its own socket) with `harness.mjs session` processes and the fake model service
// (fake_model.py). Run by tests/e2e/session_e2e.py after its own checks, on a helper of its own:
//
//   SessionClientE2E <socket> <config>
//
// Prints PASS or FAIL per check; the exit status is the number of failures.

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

@main
enum SessionClientE2E {
    nonisolated(unsafe) static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL") client: \(what)")
        if !ok { failures += 1 }
    }
    static func until(_ timeout: Double = 30, _ f: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if f() { return true }; usleep(50_000) }
        return f()
    }

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let a = CommandLine.arguments
        guard a.count == 3 else { print("usage: SessionClientE2E <socket> <config>"); exit(2) }
        let transport = PathTransport(path: a[1])
        let client = SessionClient(transport: transport)
        let watcher = Thread { _ = client.watch() }
        watcher.start()

        guard let sid = client.open(config: a[2], lang: "zh") else { check(false, "session.open"); exit(1) }
        check(sid.hasPrefix("ses_"), "open: \(sid)")
        let assistant = { client.state(sid).messages.filter { $0.role == "assistant" && !$0.streaming } }

        // a say: held until the session takes it (its stored message with the client_id), then the reply
        check(client.send(.say("你好"), to: sid) == .sent, "say sent")
        check(until { assistant().count == 1 }, "the reply: \(assistant().map(\.text))")
        var s = client.state(sid)
        check(s.outbox.isEmpty && s.taken.count == 1 && s.messages.first?.text == "你好", "taken by its stored message (client_id echoed): outbox \(s.outbox), taken \(s.taken)")
        check(s.status == .done(at: s.messages.last?.t, stopped: false), "the dot: done (\(s.status))")

        // a say while a long reply streams: refused busy by the session → unsent; resent after: taken
        check(client.send(.say("讲个长故事"), to: sid) == .sent, "a long reply asked for")
        check(until { client.state(sid).streamingMessage != nil }, "it streams")
        check(client.send(.say("再说一句"), to: sid) == .sent, "a second say sent meanwhile")
        check(until { client.state(sid).unsent.first?.refused == "busy" }, "refused busy: back in unsent (\(client.state(sid).outbox))")
        check(until(60) { assistant().count == 2 }, "the long reply done")
        let id = client.state(sid).unsent.first?.id ?? ""
        check(client.resend(id, in: sid) == .sent, "重新发送")
        check(until { client.state(sid).outbox.isEmpty && assistant().count == 3 }, "resent words taken once, answered: \(client.state(sid).messages.map(\.text))")
        s = client.state(sid)
        check(s.messages.filter { $0.text == "再说一句" }.count == 1, "stored once")
        check(!s.hasGap && s.lastSeq == s.messages.compactMap(\.seq).max(), "every stored line in place: lastSeq \(s.lastSeq)")

        // the session ended by the app: its exit (pid, start_seq, last_seq) heard; not opened again by a watch or a send
        check(client.end(sid), "end")
        check(until { client.state(sid).exited != nil }, "its exit heard: exited \(String(describing: client.state(sid).exited))")
        check(client.send(.say("还在吗"), to: sid) != .sent, "a send to the ended session is not sent")
        transport.stopped = true
        _ = until(5) { watcher.isFinished }
        exit(Int32(failures))
    }
}
