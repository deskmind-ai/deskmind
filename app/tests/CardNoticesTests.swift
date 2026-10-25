// A chat task's notifications (Shared/CardNotices.swift, A7): what CardPlacement says, carried out with ids that can be
// taken away -- posted once, reminded once at 20 s, gone when seen, answered, voided or expired, never posted again for
// the same card however often the window flips, and cleaned up at launch.
import Foundation

enum CardNoticesTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "notices: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("notices.table"); tableTests()
    }

    final class Fake: CardNotifier {
        var posts: [String] = [], removes: [String] = [], shown: [String] = []
        func post(id: String, title: String, body: String) { posts.append(id) }
        func remove(ids: [String]) { removes += ids }
        func delivered(_ done: @escaping ([String]) -> Void) { done(shown) }
    }

    static func tableTests() {
        typealias P = CardPlacement
        let f = Fake(), n = CardNotices(f)
        func place(_ phase: CardPhase, window: MainWindowState, float: P.Float, ask: String, now: Double) {
            let p = P.place(phase, fitsFloat: false, window: window, frontNow: window == .front, float: float, notified: n.notified(ask, now: now))
            n.card(ask, placement: p, title: "t", body: "b", now: now)
        }
        // the float unseen, the window away: posted once
        place(.open, window: .away, float: .hidden, ask: "a1", now: 0)
        place(.open, window: .away, float: .hidden, ask: "a1", now: 5)
        check(f.posts == ["ask:a1"], "posted once: \(f.posts)")
        // reminded once at 20 s, not again
        place(.open, window: .away, float: .hidden, ask: "a1", now: 20)
        place(.open, window: .away, float: .hidden, ask: "a1", now: 45)
        check(f.posts == ["ask:a1", "ask:a1"], "reminded once at 20 s: \(f.posts)")
        // seen (the window in front): taken away; unseen again: not posted again for this card
        place(.open, window: .front, float: .hidden, ask: "a1", now: 50)
        check(f.removes == ["ask:a1"], "seen: taken away: \(f.removes)")
        for t in [51.0, 80, 120] { place(.open, window: .away, float: .hidden, ask: "a1", now: t) }
        check(f.posts.count == 2, "the window flipping back and forth: never posted again: \(f.posts)")
        // the card answered (none waits): nothing on screen to take away
        n.card(nil, placement: nil, title: "", body: "", now: 130)
        check(f.removes == ["ask:a1"], "answered after it was taken away: nothing more")
        // a new card, then it is replaced (a newer card): the old one goes
        place(.open, window: .away, float: .hidden, ask: "a2", now: 140)
        place(.open, window: .away, float: .hidden, ask: "a3", now: 141)
        check(f.posts.suffix(2) == ["ask:a2", "ask:a3"] && f.removes.last == "ask:a2", "replaced: the old one goes, the new one posted")
        // expired: the old notification goes, no new one
        place(CardPhase.expired(late: false, answerNow: .offered), window: .away, float: .hidden, ask: "a3", now: 800)
        check(f.removes.last == "ask:a3" && f.posts.count == 4, "expired: taken away, never posted for it")
        // the float seen: no notification at all
        let g = Fake(), m = CardNotices(g)
        let p = P.place(.open, fitsFloat: true, window: .behindVisible, frontNow: false, float: .visible, notified: nil)
        m.card("b1", placement: p, title: "t", body: "b", now: 0)
        check(g.posts.isEmpty, "the float in sight: nothing posted")
        // a task's end, unseen: said once; seen: taken away
        m.ended("run_r", title: "t", body: "b", seen: false); m.ended("run_r", title: "t", body: "b", seen: false)
        check(g.posts == ["run:run_r"], "a task's end unseen: said once")
        m.ended("run_r", title: "t", body: "b", seen: true)
        check(g.removes == ["run:run_r"], "seen: taken away")
        // launch: a card's notification left by an app that went away, its card no longer waiting: gone
        let h = Fake(); h.shown = ["ask:a1", "ask:a9", "run:run_r"]
        CardNotices(h).cleanUp(waiting: ["a1"])
        check(h.removes == ["ask:a9"], "launch: stale card notifications go, a waiting card's stays, task ends are not touched: \(h.removes)")
        // A5: the 0.5 window's sessions open with live_view false (it draws the float; the helper starts no live card)
        let mock = SessionTests.MockTransport()
        mock.replies[SessionClient.Op.open] = ["ok": true, "session_id": "ses_f"]
        let c = SessionClient(transport: mock)
        c.liveView = false
        _ = c.open(sessionId: "ses_f")
        check(mock.requests.first { $0["op"] as? String == SessionClient.Op.open }?["live_view"] as? Bool == false, "session.open with live_view false")
        let src = (try? String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Main/MainSplitView.swift"), encoding: .utf8)) ?? ""
        check(src.contains("m.client.liveView = false"), "the window's client asks for no helper live card")
        // ids are what they are about
        check(CardNotices.askId("ask_1") == "ask:ask_1" && CardNotices.runId("run_1") == "run:run_1", "ids by card and by run")
    }
}
