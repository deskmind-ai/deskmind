// The app's session client (Shared/SessionClient.swift, the reducer behind it) against the real helper: SessionE2E
// `serve` (Helper/SessionHost.swift on its own socket) with `harness.mjs session` processes and the fake model service
// (fake_model.py). Run by tests/e2e/session_e2e.py after its own checks, on a helper of its own:
//
//   SessionClientE2E <socket> <config>
//
// Prints PASS or FAIL per check; the exit status is the number of failures. Built with PathTransport.swift.

import Foundation

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

        // the same words sent again with their client_id (an ack the app missed): the session does them once
        // (session.duplicate, harness#59), whichever process gets them
        let firstId = s.taken.sorted().first ?? ""
        let line: [String: Any] = ["type": "say", "text": "你好", "client_id": firstId]
        check(transport.request(SessionClient.Request.send(sessionId: sid, line: line))?["ok"] as? Bool == true, "the first say's line again")
        usleep(1_500_000)
        s = client.state(sid)
        check(s.messages.filter { $0.text == "你好" }.count == 1 && assistant().count == 3 && s.outbox.isEmpty, "stored once, no new reply: \(s.messages.map(\.text).suffix(3))")

        // stop {client_id} (harness#72): a cua the session never got — answered `none` (not stored) and the cua
        // cancelled (stored); that cua sent after it is refused `cancelled`, its words not run
        let cancelled = "c_e2e_cancelled"
        check(client.send(.stopCua(clientId: cancelled), to: sid) == .sent, "stop {client_id} sent")
        check(until { client.state(sid).stopAcks[cancelled]?.result == "none" }, "its ack: none (\(String(describing: client.state(sid).stopAcks[cancelled])))")
        check(until { client.state(sid).cancelledCuas.contains(cancelled) }, "session.cua_cancelled stored")
        check(client.send(.cua("打开计算器"), to: sid, clientId: cancelled) == .sent, "the cancelled cua sent after it")
        check(until { client.state(sid).outbox.first { $0.id == cancelled }?.refused == "cancelled" }, "refused cancelled: \(client.state(sid).outbox)")
        check(client.state(sid).tasks.isEmpty, "no task started")
        // the same stop again: the same answer
        check(client.send(.stopCua(clientId: cancelled), to: sid) == .sent && until { client.state(sid).stopAcks[cancelled]?.result == "none" }, "stopped again: the same answer")

        // the session ended by the app: its exit (pid, start_seq, last_seq) heard; not opened again by a watch or a send
        check(client.end(sid), "end")
        check(until { client.state(sid).exited != nil }, "its exit heard: exited \(String(describing: client.state(sid).exited))")
        check(client.send(.say("还在吗"), to: sid) != .sent, "a send to the ended session is not sent")
        transport.stopped = true
        _ = until(5) { watcher.isFinished }
        exit(Int32(failures))
    }
}
