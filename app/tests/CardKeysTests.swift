// The keys on a card (A2, plan §1.5 with #111's explicit-move rule kept: fable 10-25): the table cell by cell
// (CardKeys.action), then the cells that act, through the window's model -- Esc takes a held pick back, Return sends
// it now, Return never says yes from outside -- and the states around them: an expired card, a card voided while its
// pick is held, a card that arrives while the user types in the chat.
import Foundation

enum CardKeysTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "card-keys: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("card-keys.table"); tableTests()
        DecisionTests.group("card-keys.model"); modelTests()
        DecisionTests.group("card-keys.review124"); review124Tests()
        DecisionTests.group("card-keys.focus"); focusTests()
        DecisionTests.group("card-keys.steer"); steerTests()
        DecisionTests.group("card-keys.steer-gate"); steerGateRepros(); steerInterleavings()
    }

    typealias K = CardKeys
    static let esc = "\u{1b}", tab = "\t", backTab = "\u{19}", ret = "\r", enter = "\u{3}", space = " "

    static func tableTests() {
        let out = K.Context(inCard: false, held: false, editing: false, composing: false)
        let inCard = K.Context(inCard: true, held: false, editing: false, composing: false)
        let held = K.Context(inCard: true, held: true, editing: false, composing: false)
        let heldOut = K.Context(inCard: false, held: true, editing: false, composing: false)
        let typing = K.Context(inCard: false, held: false, editing: true, composing: false)
        let typingHeld = K.Context(inCard: true, held: true, editing: true, composing: false)
        let composing = K.Context(inCard: true, held: true, editing: false, composing: true)
        // (state, key) → action
        let rows: [(String, K.Context, String, K.KeyAction)] = [
            ("out", out, "3", .none), ("out", out, tab, .enterCard), ("out", out, backTab, .enterCard), ("out", out, esc, .enterCard),
            ("out", out, ret, .none), ("out", out, enter, .none), ("out", out, space, .none), ("out", out, "a", .none),
            ("in", inCard, "3", .digit(3)), ("in", inCard, "1", .digit(1)), ("in", inCard, "9", .digit(9)), ("in", inCard, "0", .none),
            ("in", inCard, tab, .none), ("in", inCard, esc, .leaveCard), ("in", inCard, ret, .none), ("in", inCard, space, .none),
            ("held", held, "2", .digit(2)), ("held", held, esc, .takeBack), ("held", held, ret, .sendNow), ("held", held, enter, .sendNow),
            ("held", held, tab, .none), ("held", held, space, .none),
            ("held, out of card", heldOut, esc, .takeBack), ("held, out of card", heldOut, ret, .sendNow), ("held, out of card", heldOut, "2", .digit(2)),
            ("typing", typing, "3", .none), ("typing", typing, tab, .none), ("typing", typing, esc, .none), ("typing", typing, ret, .none),
            ("typing, held", typingHeld, ret, .none), ("typing, held", typingHeld, esc, .none), ("typing, held", typingHeld, "2", .none),
            ("composing", composing, esc, .none), ("composing", composing, ret, .none), ("composing", composing, "1", .none),
        ]
        for (name, c, key, want) in rows {
            let got = K.action(characters: key, commandLike: false, isRepeat: false, c)
            check(got == want, "\(name), \(key.debugDescription): \(want), got \(got)")
        }
        // ⌘⌃⌥ and auto-repeats never act here (Return in the chat field steers and voids the card: A9, decision 3)
        for c in [out, inCard, held] {
            for key in ["3", tab, esc, ret] {
                check(K.action(characters: key, commandLike: true, isRepeat: false, c) == .none, "⌘ + \(key.debugDescription): nothing")
                check(K.action(characters: key, commandLike: false, isRepeat: true, c) == .none, "repeated \(key.debugDescription): nothing")
            }
        }
        check(K.action(characters: nil, commandLike: false, isRepeat: false, held) == .none, "no characters: nothing")
    }

    static func modelTests() {
        typealias R = CardStoreTests.Rig
        func key(_ r: R, _ k: String, editing: Bool = false) -> Bool {
            r.m.keyDown(characters: k, commandLike: false, mainWindowIsKey: true, editingText: editing, isRepeat: false)
        }
        func into(_ r: R, _ id: String) -> CardModel? {
            guard let m = r.model(id) else { return nil }
            r.m.fit(m); r.m.cardShown(m); r.timers.advance(CardKeys.cardOnScreen + 0.1); r.m.enterCardMode(m)
            return m
        }
        // Return from outside never says yes
        do {
            let r = R(); r.ask("a1")
            guard let m = r.model("a1") else { check(false, "the card"); return }
            r.m.fit(m); r.m.cardShown(m); r.timers.advance(2)
            check(!key(r, ret) && r.phase("a1") == .open, "Return outside the card: nothing")
            check(!key(r, "1") && r.phase("a1") == .open, "a digit outside the card: nothing (an explicit move first)")
            check(!key(r, tab) && r.m.keysActive(m), "Tab: into the card (not consumed: the focus moves)")
        }
        // held: Esc takes it back (nothing sent); Return sends it at once
        do {
            let r = R(); r.ask("a1")
            guard into(r, "a1") != nil else { check(false, "the card"); return }
            check(key(r, "1") && r.phase("a1")?.pending != nil, "1: held")
            check(key(r, esc) && r.phase("a1") == .open, "Esc while held: taken back")
            r.timers.advance(CardStore.takeBack + 1)
            check(r.wire.count("answer") == 0, "nothing sent")
            check(key(r, "1") && r.phase("a1")?.pending != nil, "picked again")
            check(key(r, ret), "Return while held: sent now (consumed)")
            check(r.wire.answers("a1").count == 1 && { if case .sent = r.phase("a1") { return true }; return false }(), "sent at once, once")
            r.timers.advance(CardStore.takeBack + 1)
            check(r.wire.answers("a1").count == 1, "and not again when the 3 s run out")
            check(!key(r, ret) && !key(r, esc), "Return / Esc on a sent card: nothing")
        }
        // Esc in the card, nothing held: out of the card
        do {
            let r = R(); r.ask("a1")
            guard let m = into(r, "a1") else { check(false, "the card"); return }
            check(!key(r, esc) && !r.m.keysActive(m), "Esc in the card: out of it")
        }
        // an expired action card: every key dead
        do {
            let r = R(); r.ask("a1")
            guard into(r, "a1") != nil else { check(false, "the card"); return }
            r.void("a1", CardState.timeout)
            for k in ["1", "2", ret, esc] { _ = key(r, k) }
            r.timers.advance(CardStore.takeBack + 1)
            check(r.wire.count("answer") == 0, "an expired card: no key answers it")
        }
        // voided by a steer / stopped while held: the countdown is cancelled, Esc / Return do nothing, nothing is sent
        for why in ["steer", "stop"] {
            let r = R(); r.ask("a1")
            guard into(r, "a1") != nil else { check(false, "the card"); return }
            _ = key(r, "1")
            r.void("a1", why)
            check(!key(r, ret) && !key(r, esc), "\(why) while held: Return / Esc do nothing")
            r.timers.advance(CardStore.takeBack + 1)
            check(r.wire.count("answer") == 0, "\(why) while held: nothing sent")
        }
        // a card arriving while the user types in the chat: digits are text, Return is the composer's
        do {
            let r = R(); r.ask("a1")
            guard let m = r.model("a1") else { check(false, "the card"); return }
            r.m.fit(m); r.m.cardShown(m); r.timers.advance(2)
            check(!key(r, "1", editing: true) && !key(r, ret, editing: true) && !key(r, tab, editing: true), "typing in the chat: no key is the card's")
            check(r.phase("a1") == .open && !r.m.keysActive(m), "the card still waits, not entered")
        }
    }

    /// #124 review at 64547f9: H2's fields never lose a card; the fold stays with the card and never moves it; a card
    /// with two views for a moment keeps its keys; a card's layout facts go when it is no longer pinned.
    static func review124Tests() {
        typealias R = CardStoreTests.Rig
        // lenient: a headline / beyond / detail of the wrong type is none, and the card is still there
        let bad: [String: Any] = ["kind": "ambiguity", "text": "哪一份？", "blocking": true, "free_text": false, "headline": 5, "beyond": "x",
                                  "options": [["kind": "reading", "text": "周报.txt", "detail": ["no"]], ["kind": "cancel", "text": "先别做了"]]]
        let r = R(); r.ask("a1", card: bad)
        if let m = r.model("a1") {
            check(m.headline == nil && m.beyond.isEmpty && m.buttons.first?.detail == nil && m.buttons.count == 2,
                  "wrong types: no headline, beyond or detail -- the card itself still shows: \(m.buttons.map(\.text))")
        } else { check(false, "a card whose H2 fields have the wrong type is still a card") }
        let good: [String: Any] = ["kind": "ambiguity", "text": "哪一份？", "blocking": true, "free_text": false, "headline": "「上周的报告」指的是哪一份？",
                                   "beyond": ["备忘录「购物清单」"], "options": [["kind": "reading", "text": "周报.txt", "detail": "9 月 2 日改的"], ["kind": "cancel", "text": "先别做了"]]]
        let g = R(); g.ask("a1", card: good)
        if let m = g.model("a1") {
            let l = CardLayout(m)
            check(l.title == "「上周的报告」指的是哪一份？" && l.beyond == ["备忘录「购物清单」"] && l.folds && m.buttons.first?.detail == "9 月 2 日改的", "H2's fields read")
        } else { check(false, "the H2 card") }
        // an action card with a headline and no consent fields: its text is not folded away
        let act: [String: Any] = ["kind": "action", "text": "在 Mail 里点「发送」", "blocking": true, "free_text": false, "headline": "要发出去吗？",
                                  "options": [["kind": "approve", "text": "可以"], ["kind": "cancel", "text": "先别做了"]]]
        let a = R(); a.ask("a1", card: act)
        if let m = a.model("a1") { check(!CardLayout(m).folds, "an action card with no fields: its text stays shown") }
        // #124 Codex review at 80c339e: the card's height as it is -- opened past the room, it moves to the chat, open,
        // its keys off (its controls may be off screen); folded again, pinned again; the fold and the typed words go
        // with it (the shell's, by card key)
        let f = R(); f.ask("a1")
        guard let m = f.model("a1") else { check(false, "the card"); return }
        f.m.pinRoom(columnHeight: 600); f.m.cardLaidOut(m, height: 136)
        f.m.cardShown(m); f.timers.advance(CardKeys.cardOnScreen + 0.1); f.m.enterCardMode(m)
        let skip = CardLayout(m).controls.first { $0.button.role == .skipStep }!
        check(f.m.cardFits(m) && f.m.cardPinnedWhole(m) && f.m.keyWorks(m, skip), "136 pt in a 600 pt window: pinned, its keys on")
        f.m.setCardDraft(m, "改成下午三点")
        f.m.setDetails(m, open: true)
        f.m.cardLaidOut(m, height: 815)                     // opened: past the room (300)
        check(f.m.detailsOpen(m) && !f.m.cardFits(m) && !f.m.cardPinnedWhole(m), "opened to 815 pt: in place in the chat, still open")
        check(!f.m.keyWorks(m, skip), "and no key works on it (its controls may be off screen)")
        check(f.m.cardDraft(m) == "改成下午三点", "the typed words went with it")
        f.m.setDetails(m, open: false); f.m.cardLaidOut(m, height: 136)
        check(!f.m.detailsOpen(m) && f.m.cardPinnedWhole(m) && f.m.cardDraft(m) == "改成下午三点", "folded again: pinned again, the words still there")
        // two views for a moment (pinned → in place): appear before disappear keeps the keys
        f.m.cardShown(m); f.timers.advance(CardKeys.cardOnScreen + 0.1); f.m.enterCardMode(m)
        f.m.cardShown(m); f.m.cardHidden(m)
        check(f.m.keysActive(m), "the new view came before the old one went: card mode stays")
        f.m.cardHidden(m); f.m.cardHidden(m)     // (the view shown above, and this one)
        check(!f.m.keysActive(m), "the last view went: card mode ends")
        // lead 10-25: a tall card in the chat answered by keys alone -- Tab moves into it, Space on the focused option
        // (AppKit presses the button: its action, ShellModel.click) picks it, digits do nothing
        do {
            let t = R(); t.ask("a1", "ambiguity")
            guard let tm = t.model("a1") else { check(false, "the tall card"); return }
            t.m.pinRoom(columnHeight: 600); t.m.cardLaidOut(tm, height: 900); t.m.cardShown(tm); t.timers.advance(2)
            check(!t.m.cardPinnedWhole(tm), "tall: in place in the chat")
            _ = t.m.keyDown(characters: Self.tab, commandLike: false, mainWindowIsKey: true, editingText: false, isRepeat: false)
            check(t.m.keysActive(tm), "Tab: into the card")
            check(!t.m.keyDown(characters: "1", commandLike: false, mainWindowIsKey: true, editingText: false, isRepeat: false) && t.phase("a1") == .open,
                  "a digit: nothing (it acts from a distance)")
            let reading = tm.buttons.first { $0.role == .choice }!
            check(t.m.buttonEnabled(reading, card: tm, in: t.state) && t.m.click(reading) && t.phase("a1")?.pending != nil,
                  "Space on the focused option: picked (held for its take-back)")
            _ = t.m.keyDown(characters: Self.esc, commandLike: false, mainWindowIsKey: true, editingText: false, isRepeat: false)
            check(t.phase("a1") == .open, "Esc: taken back")
            t.m.requestScroll(to: ShellModel.optionAnchor(tm, reading.index))
            check(t.m.scrollRequest?.id == "option/\(ShellModel.cardKey(tm))/\(reading.index)", "the focused option asks to be scrolled into view")
        }
        // the card answered: its layout facts and its words go
        f.m.setDetails(m, open: true)
        f.resumed("a1")
        check(f.m.cardHeights.isEmpty && f.m.openDetails.isEmpty && f.m.cardDrafts.isEmpty, "answered: its height, fold and words forgotten")
        // #124 Codex review at 80c339e: what an approval would do is always on screen when it takes a click -- with a
        // headline, the text is shown under it unless the card folds it (and it folds only where its fields or its
        // beyond lines say what goes out)
        let shapes: [(String, [String: Any], Bool)] = [
            ("action, headline, no fields", ["kind": "action", "text": "在 Mail 里点「发送」", "headline": "要发出去吗？", "blocking": true, "free_text": false,
                                            "options": [["kind": "approve", "text": "可以"], ["kind": "cancel", "text": "先别做了"]]], true),
            ("action, no headline", ["kind": "action", "text": "在 Mail 里点「发送」", "blocking": true, "free_text": false,
                                     "options": [["kind": "approve", "text": "可以"]]], true),
            ("ambiguity, headline", ["kind": "ambiguity", "text": "两份报告都像", "headline": "哪一份？", "blocking": true, "free_text": false,
                                     "options": [["kind": "reading", "text": "a"], ["kind": "delegate", "text": "由你决定"]]], false),
        ]
        for (name, json, textAlwaysShown) in shapes {
            let r = R(); r.ask("a1", card: json)
            guard let cm = r.model("a1") else { check(false, name); continue }
            let l = CardLayout(cm)
            let visible = l.title == cm.text || l.shownText == cm.text
            check(visible || (l.folds && !textAlwaysShown), "\(name): the text on screen (title \(l.title == cm.text), shown \(l.shownText != nil), folds \(l.folds))")
            if textAlwaysShown { check(visible, "\(name): never only in a fold") }
        }
        // the view draws what the layout says is shown (the text under the title)
        let view = (try? String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Main/CardViews.swift"), encoding: .utf8)) ?? ""
        check(view.contains("if let t = layout.shownText {") && view.contains("private var words: Binding<String> { Binding(get: { shell.cardDraft(card) }")
              && !view.contains("@State private var words"), "CardView draws shownText; its words are the shell's")
    }

    /// The focus funnel (lead 10-25): only the user's Esc out of a card, in the key window, asks the composer for the
    /// typing -- once; nothing a card does on its own asks, and a request goes when the window stops being the key one.
    static func focusTests() {
        typealias R = CardStoreTests.Rig
        func pressEsc(_ r: R) { _ = r.m.keyDown(characters: Self.esc, commandLike: false, mainWindowIsKey: true, editingText: false, isRepeat: false) }
        let r = R(); r.ask("a1")
        guard let m = r.model("a1") else { check(false, "the card"); return }
        r.m.fit(m); r.m.cardShown(m); r.timers.advance(CardKeys.cardOnScreen + 0.1)
        check(r.m.focusRequest == 0, "a card arrived: no focus request")
        pressEsc(r)                                    // not in the card: Esc moves into it, asks nothing
        check(r.m.keysActive(m) && r.m.focusRequest == 0, "Esc into the card: no request")
        pressEsc(r)                                    // in the card: out of it, back to the composer
        let n = r.m.focusRequest
        check(n == 1 && !r.m.keysActive(m), "Esc out of the card: one request")
        check(r.m.takeFocus(n) && !r.m.takeFocus(n), "taken once (a re-render does not focus again)")
        // a request made, then the window stops being the key one before the composer takes it: dropped
        r.m.enterCardMode(m)
        pressEsc(r)
        r.m.windowLeft()
        check(!r.m.takeFocus(r.m.focusRequest), "the window no longer key: the pending request dropped")
        r.m.windowReturned()
        check(!r.m.takeFocus(r.m.focusRequest), "and not taken when it is key again")
        // the card answered, voided, a new one: none of it asks
        let before = r.m.focusRequest
        r.resumed("a1"); r.ask("a2"); r.void("a2", "steer"); r.ask("a3")
        check(r.m.focusRequest == before, "cards arriving, answered, voided: no request")
        // Esc while typing in a field: the field's, no request
        let q = R(); q.ask("a1")
        if let qm = q.model("a1") {
            q.m.fit(qm); q.m.cardShown(qm); q.timers.advance(2); q.m.enterCardMode(qm)
            _ = q.m.keyDown(characters: Self.esc, commandLike: false, mainWindowIsKey: true, editingText: true, isRepeat: false)
            check(q.m.focusRequest == 0, "Esc in a field: no request")
        }
    }

    /// A9 (owner 10-25, plan §8): Return with words while a card waits steers the task. In one step the held pick goes
    /// (never sent), the steer is marked on its way (the card's options take nothing), then it is written; the mark ends
    /// on every path -- refused (card_open, a harness before H5: the words shown not delivered, never sent again by
    /// themselves), taken, the card ended -- and the card's own ending is only the run's word (ask_void why steer).
    static func steerTests() {
        typealias R = CardStoreTests.Rig
        let r = R(); r.ask("a1")
        guard let m = r.model("a1") else { check(false, "the card"); return }
        r.m.fit(m)
        let approve = m.buttons.first { $0.role == .approve }!
        check(r.m.click(approve) && r.phase("a1")?.pending != nil, "a pick held")
        r.m.client.makeClientId = { "c_steer" }
        r.m.draft = "改成发给小李"
        check(r.m.composer.enabled, "the composer takes words while the card waits")
        r.m.submit()
        check(r.phase("a1") == .open, "Return: the held pick dropped")
        r.timers.advance(CardStore.takeBack + 1)
        check(r.wire.answers("a1").isEmpty, "and never sent")
        check(r.m.client.state(CardStoreTests.sid).steers.contains { $0.clientId == "c_steer" } && onWay(r.m) && !r.m.canSend(approve), "the steer on its way: the card takes nothing")
        check(r.wire.count("steer") == 1, "the steer written: \(r.wire.count("steer"))")
        // a harness before H5 refuses it: the card takes picks again, the words not delivered (and not sent again)
        r.feed(["kind": "session.error", "session_id": CardStoreTests.sid, "code": "card_open", "control": "steer", "client_id": "c_steer", "text": "x"])
        check(!onWay(r.m) && r.m.canSend(approve), "refused card_open: the card takes picks again")
        check(r.m.client.state(CardStoreTests.sid).unsent.contains { $0.id == "c_steer" && $0.refused == "card_open" } && r.wire.count("steer") == 1,
              "the words shown not delivered, not sent again")
        // again; this time the session takes it and voids the card (H5): the card ends by the run's word
        r.m.client.makeClientId = { "c_steer2" }
        r.m.draft = "还是发给老王"
        r.m.submit()
        check(onWay(r.m), "on its way")
        // the session took it (stored), its ask_void not here yet: still marked, the card takes nothing
        r.feed(["kind": "session.message", "session_id": CardStoreTests.sid, "seq": 3, "msg_id": "u_s", "role": "user", "text": "还是发给老王", "client_id": "c_steer2"])
        check(onWay(r.m) && !r.m.canSend(approve), "taken, the card still open: still marked, no click")
        r.void("a1", "steer")
        check(!onWay(r.m) && r.phase("a1") == .voided("steer"), "ask_void why steer: the card ended, the mark gone")
        // an empty Return does nothing
        let q = R(); q.ask("a1")
        q.m.draft = "   "
        q.m.submit()
        check(q.wire.count("steer") == 0 && !onWay(q.m) && q.phase("a1") == .open, "an empty Return: nothing")
    }

    // MARK: #125 Codex re-reviews at d08465d and 3c6f5cc: the write lane decides, at the write

    /// A steer for the card is on its way, as the client that writes the lines keeps it.
    static func onWay(_ m: ShellModel, _ ask: String = "a1") -> Bool {
        m.client.state(CardStoreTests.sid).steerPending(runId: CardStoreTests.rid, askId: ask)
    }
    static func refuse(_ r: CardStoreTests.Rig, _ cid: String) {
        r.feed(["kind": "session.error", "session_id": CardStoreTests.sid, "code": "card_open", "control": "steer", "client_id": cid, "text": "x"])
    }
    /// The wire in order: (type, ask_id).
    static func written(_ r: CardStoreTests.Rig) -> [(String, String?)] { r.wire.lines.map { ($0.line["type"] as? String ?? "", $0.line["ask_id"] as? String) } }
    /// The steers' client ids as written, in order (never assumed: read from the wire).
    static func steerIds(_ r: CardStoreTests.Rig) -> [String] { r.wire.lines.compactMap { $0.line["type"] as? String == "steer" ? $0.line["client_id"] as? String : nil } }

    /// A rig whose write lane holds its jobs until they are run (`step` one, `drain` all): putting a line in and
    /// writing it are two moves, as on the app's serial queue.
    final class LaneRig {
        let r = CardStoreTests.Rig()
        var q: [() -> Void] = []
        init(ask: String = "a1") {
            r.ask(ask, "plan")
            let m = ShellModel(client: SessionClient(transport: r.wire), defaults: ShellTests.scratchDefaults(), config: { "openai:local|fake" },
                               lang: { .zhHans }, takeBackAfter: r.timers.after, now: { [r] in r.timers.now }, work: { $0() }, deliver: { $0() },
                               lane: { [unowned self] in self.q.append($0) })
            m.selected = CardStoreTests.sid
            r.m = m
            for l in r.fed { m.client.feed(l) }
        }
        var m: ShellModel { r.m }
        func step() { if !q.isEmpty { q.removeFirst()() } }
        func drain() { while !q.isEmpty { step() } }
    }

    static func steerGateRepros() {
        typealias R = CardStoreTests.Rig
        // 1. a steer refused, a pick held, the steer sent again: the held pick's time out writes nothing
        do {
            let r = R(); r.ask("a1", "plan")
            r.m.draft = "改成发给小李"; r.m.submit()
            let c1 = steerIds(r)[0]
            refuse(r, c1)
            r.click("a1", .approve)
            check(r.phase("a1")?.pending != nil, "1: the pick held once the refused steer let go")
            r.m.resend(c1)
            check(r.wire.count("steer") == 2 && onWay(r.m), "1: sent again, on its way again")
            r.timers.advance(CardStore.takeBack + 1)
            check(r.wire.answers("a1").isEmpty, "1: the held approve never written after the resent steer: \(written(r))")
            refuse(r, c1)
            check(!onWay(r.m), "1: refused again: let go")
        }
        // 1b. the resend in the lane, an unrelated line first: the bubble's old refusal is not the resent steer's end
        do {
            let l = LaneRig()
            l.m.draft = "改成发给小李"; l.m.submit(); l.drain()
            let c1 = steerIds(l.r)[0]
            refuse(l.r, c1)
            check(!onWay(l.m), "1b: refused: let go")
            l.m.resend(c1)
            l.r.feed(["kind": "session.message", "session_id": CardStoreTests.sid, "seq": 9, "msg_id": "m9", "role": "assistant", "text": "好"])
            check(onWay(l.m), "1b: the resent steer on its way before its line went")
            l.r.click("a1", .approve); l.r.timers.advance(CardStore.takeBack + 1); l.drain()
            check(l.r.wire.answers("a1").isEmpty && l.r.wire.count("steer") == 2, "1b: no answer around the resent steer: \(written(l.r))")
        }
        // 1c. (Codex at 3c6f5cc, 1) two quick 「重新发送」: one attempt in the lane, its end the only end
        do {
            let l = LaneRig()
            l.m.draft = "改成发给小李"; l.m.submit(); l.drain()
            let c1 = steerIds(l.r)[0]
            refuse(l.r, c1)
            l.m.resend(c1); l.m.resend(c1)
            check(l.q.count == 1, "1c: the second click puts nothing in: \(l.q.count)")
            let approve = l.r.model("a1")!.buttons.first { $0.role == .approve }!
            check(!l.m.canSend(approve), "1c: the card takes nothing while the attempt waits")
            l.drain()
            check(l.r.wire.count("steer") == 2 && onWay(l.m), "1c: written once more, on its way")
            l.r.click("a1", .approve); l.r.timers.advance(CardStore.takeBack + 1); l.drain()
            check(l.r.wire.answers("a1").isEmpty, "1c: nothing written: \(written(l.r))")
        }
        // 2. typed words while a steer is on its way: the field takes none, the words go nowhere
        do {
            let r = R(); r.ask("a1", "plan")
            r.m.draft = "改成发给小李"; r.m.submit()
            let c = r.model("a1")!
            check(!r.m.wordsEnabled(c, in: r.state), "2: the card's field takes no words")
            r.words("a1", "就这样")
            r.timers.advance(CardStore.takeBack + 1)
            check(r.wire.answers("a1").isEmpty, "2: typed words never written: \(written(r))")
        }
        // 2b. (Codex at 3c6f5cc, 2) the approve's time out put its answer in the lane, then the steer: the answer was
        // first, and goes first -- never after the steer
        do {
            let l = LaneRig()
            l.r.click("a1", .approve); l.r.timers.advance(CardStore.takeBack + 1)
            check(l.q.count == 1, "2b: the answer in the lane, not written")
            l.m.draft = "改成发给小李"; l.m.submit()
            l.drain()
            let order = written(l.r).map(\.0).filter { $0 == "answer" || $0 == "steer" }
            check(order == ["answer", "steer"], "2b: the wire in the lane's order: \(order)")
        }
        // 2c. (Codex at a79b086) a steer in the lane, a new card arrives and is answered: the lane holds the answer
        // back; the steer refused, the card takes an answer again (never stuck 「已发送」)
        do {
            let l = LaneRig()
            l.r.void("a1", "steer")
            l.m.draft = "改成发给小李"; l.m.submit()
            l.r.ask("a2", "plan")
            l.r.click("a2", .cancel)          // (cancel: written at once -- into the lane, after the steer)
            l.drain()
            check(l.r.wire.answers("a2").isEmpty, "2c: the answer not written after the steer")
            let cid = steerIds(l.r)[0]
            refuse(l.r, cid)
            let c = l.r.model("a2")!
            check(c.buttons.contains { l.m.canSend($0) } && l.m.wordsEnabled(c, in: l.r.state), "2c: the steer over, the card answerable: \(String(describing: l.r.phase("a2")))")
            l.r.click("a2", .approve); l.r.timers.advance(CardStore.takeBack + 1); l.drain()
            check(l.r.wire.answers("a2").count == 1, "2c: and its answer goes")
        }
        // 3. two steers: the first's refusal leaves the second on its way
        do {
            let r = R(); r.ask("a1", "plan")
            r.m.draft = "改成发给小李"; r.m.submit()
            r.m.draft = "还是发给老王"; r.m.submit()
            let ids = steerIds(r)
            check(ids.count == 2 && Set(ids).count == 2, "3: both written, each its own id")
            refuse(r, ids[0])
            let approve = r.model("a1")!.buttons.first { $0.role == .approve }!
            check(!r.m.canSend(approve), "3: the second still on its way: the card takes nothing")
            r.click("a1", .approve); r.timers.advance(CardStore.takeBack + 1)
            check(r.wire.answers("a1").isEmpty, "3: nothing written")
            refuse(r, ids[1])
            check(!onWay(r.m) && r.m.canSend(approve), "3: both refused: the card takes picks again")
        }
    }

    /// Random orders of the moves that put a line in the lane (steer, resend, pick, words, cancel, float click, a
    /// time out) and of the lane writing its next line, with the session's own words meanwhile (a refusal of a written
    /// steer, its taking, ask_void, a new card). Oracle -- the wire and the fed lines only: no answer line for a card
    /// while a steer written for it (while open) is neither refused after it went nor ended by the card's end; and the
    /// card's options take nothing then.
    static func steerInterleavings() {
        var bad = 0, answers = 0
        for seed in 0..<300 {
            var g = CardStoreTests.RNG(x: UInt64(seed) &* 2654435761 &+ 11)
            let l = LaneRig()
            let r = l.r
            var asks = 1, open: String? = "a1", msgSeq = 3
            var pending: [String: Set<String>] = [:]      // by card: steers written while it was open, not refused since
            var live: Set<String> = []                     // steers whose last attempt went and is not refused
            var answered: Set<String> = []                 // cards an answer of ours was written for
            r.wire.onLine = { line in
                switch line["type"] as? String {
                case "steer":
                    if let cid = line["client_id"] as? String { live.insert(cid); if let o = open { pending[o, default: []].insert(cid) } }
                case "answer":
                    answers += 1
                    if let a = line["ask_id"] as? String { answered.insert(a) }
                    if let a = line["ask_id"] as? String, !(pending[a] ?? []).isEmpty { bad += 1; print("seed \(seed): answer for \(a) with \(pending[a]!) on its way") }
                default: break
                }
            }
            for _ in 0..<50 {
                switch g.next(15) {
                case 0, 13: l.m.draft = "改一下 \(g.next(100))"; l.m.submit()
                case 2:
                    let unsent = l.m.client.state(CardStoreTests.sid).unsent.filter { if case .steer? = $0.original { return true }; return false }
                    if !unsent.isEmpty { l.m.resend(unsent[g.next(unsent.count)].id) }
                case 3:
                    let can = live.sorted()
                    if !can.isEmpty { let c = can[g.next(can.count)]; live.remove(c); for k in pending.keys { pending[k]?.remove(c) }; refuse(r, c) }
                case 4:
                    let can = live.sorted()
                    if !can.isEmpty {
                        let c = can[g.next(can.count)]; msgSeq += 1
                        r.feed(["kind": "session.message", "session_id": CardStoreTests.sid, "seq": msgSeq, "msg_id": "u\(msgSeq)", "role": "user", "text": "改", "client_id": c])
                    }
                case 1, 5: if let o = open { r.click(o, .approve) }
                case 6: if let o = open { r.words(o, "就这样") }
                case 7, 14: if let o = open { r.click(o, .cancel) }
                case 8: if let o = open, let c = r.model(o), let b = c.buttons.first(where: { $0.role == .approve }) { l.m.click(b, session: CardStoreTests.sid, place: .float) }
                case 9: r.timers.advance(Double(g.next(4)) + 0.5)
                case 10, 11: l.step()
                default:
                    if let o = open { r.void(o, "steer"); pending[o] = nil; open = nil }
                    else { asks += 1; open = "a\(asks)"; r.ask(open!, "plan") }
                }
                if let o = open, !(pending[o] ?? []).isEmpty, let c = r.model(o), c.buttons.contains(where: { l.m.canSend($0) }) {
                    bad += 1; print("seed \(seed): \(o) takes a click with a steer on its way")
                }
                // every steer for the open card over, nothing of ours for it in the lane or written: it takes an answer
                if let o = open, (pending[o] ?? []).isEmpty, l.q.isEmpty, !answered.contains(o), !l.m.client.state(CardStoreTests.sid).steerPending(runId: CardStoreTests.rid, askId: o),
                   let c = r.model(o), !c.buttons.contains(where: { l.m.canSend($0) }) {
                    bad += 1; print("seed \(seed): \(o) stuck: no steer on its way, nothing sent, takes no answer (\(String(describing: r.phase(o))))")
                }
            }
            l.drain()
        }
        check(bad == 0 && answers > 100, "no answer written, no option taking a click, while a steer for the card is on its way: \(bad) (answers written: \(answers))")
    }
}
