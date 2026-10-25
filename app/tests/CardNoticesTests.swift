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
        // #125 review at 31cb375 (the views are not in this binary: their wiring checked as written)
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func code(_ f: String) -> String {
            ((try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) ?? "")
                .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        }
        let split = code("Main/MainSplitView.swift"), float = code("Main/FloatPanel.swift")
        // 1. one float per app, whatever the window does: not the window view's; started once; it drives itself
        check(!split.contains("FloatController()") && !split.contains("FrontmostMonitor()") && split.contains("FloatController.shared.start(shell)"),
              "the window starts the app's one float, owns none")
        check(float.contains("static let shared = FloatController()") && float.contains("guard self.shell == nil else { return }")
              && float.contains("Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true)") && float.contains("monitor.onRaw = {"),
              "the float: one, started once, driven by its own timer and every change of the window seen")
        // 2. a chat task's end: CardNotices' notification only
        check(float.contains("o.finish(passed: passed, summary: summary, notify: false)") && !float.contains("base.finish("),
              "the chat island finishes without the island's own notification")
        // 3. the float answers by the window's state at the click
        let buttons = float.components(separatedBy: "struct FloatCard").last ?? ""
        check(buttons.components(separatedBy: "if FloatController.shared.answersNow() {").count - 1 == 3 && float.contains("frontNow: FrontmostMonitor.observe() == .front, float: visibility())"),
              "every float answer button checks the window's state now")
        // #125 Codex review at 2f29d42: the float's card says all an approval does, from the chat's CardLayout; the way
        // to the main window selects the card's own conversation first
        let floatCard = float.components(separatedBy: "struct FloatCard").last ?? ""
        check(floatCard.contains("if let c = layout.consent { ConsentFields(consent: c) }") && floatCard.contains("ForEach(Array(layout.beyond.enumerated())")
              && floatCard.contains("if let t = layout.shownText") && floatCard.contains("FloatController.shared.cardLaidOut(card, height: h)"),
              "the float card: shown text, beyond lines, every consent field, its height measured")
        check(floatCard.contains("shell.select(sessionId); MainWindow.comeBack(g)"), "去主窗口回答: the card's conversation selected, then the window")
        check(float.contains("CardPlacement.fitsFloat(structure: card.answerableInFloat, height: cardHeights[ShellModel.cardKey(card)], room: cardRoom)")
              && float.contains("visibleFrame.height") && !float.contains("fitsFloat: card.answerableInFloat"),
              "the float's fit: structure and measured height, against the room the panel has on its screen")
        check(float.contains("if let shell { update(shell, window: monitor.window, frontNow: FrontmostMonitor.observe() == .front, lang: AppLanguage.current()) }"), "a card laid out anew: placed and sized at once")
        // #125 Codex re-review at d08465d: the summary's title is bounded, its button always under it
        check(float.contains("static let summaryLines = 2") && float.contains(".lineLimit(FloatCard.summaryLines).truncationMode(.tail)"), "the summary title: two lines at most")
        let shown = float.components(separatedBy: "struct FloatCard").last ?? ""
        check(shown.components(separatedBy: "summaryTitle(layout)").count - 1 == 2 && !shown.contains("            default:\n                title(layout)"),
              "the summary and the expired card use the bounded title")
        // the float's places in the UI log (A2 with #123): shown whole / as its summary once it can be seen, its picks
        check(float.contains("switch fact == .visible ? pl.shown : .ended {") && float.contains("shell.cardPlaced(card, place: .float, in: s)")
              && float.contains("shell.cardPlaced(card, place: .floatSummary, in: s)") && float.contains("shell.click(c.button, session: sessionId, place: .float)"),
              "the float logs where it shows the card and that its picks are the float's")
        do {
            let r = CardStoreTests.Rig(); r.ask("a1", "plan")
            var log: [UIEvent] = []
            r.m.uiRecord = { log.append($0) }
            let c = r.model("a1")!
            r.m.cardPlaced(c, place: .floatSummary, in: r.state); r.m.cardPlaced(c, place: .floatSummary, in: r.state)
            r.m.cardPlaced(c, place: .float, in: r.state); r.m.cardPlaced(c, place: .chat, in: r.state)
            let places = log.compactMap { e -> UIEvent.Place? in if case .cardShown(_, _, _, let p, _, _, _) = e { return p }; return nil }
            check(places == [.floatSummary, .float], "each float place logged once, the chat's not from here: \(places)")
            r.m.fit(c)
            _ = r.m.click(c.buttons.first { $0.role == .approve }!, session: CardStoreTests.sid, place: .float)
            let picks = log.compactMap { e -> UIEvent.Place? in if case .cardPick(_, _, _, _, _, let p, _) = e { return p }; return nil }
            check(picks == [.float], "a float pick: place float: \(picks)")
        }
        // ids are what they are about
        check(CardNotices.askId("ask_1") == "ask:ask_1" && CardNotices.runId("run_1") == "run:run_1", "ids by card and by run")
    }
}
