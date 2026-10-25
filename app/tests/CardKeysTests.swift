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
        // the fold: kept by the shell, and opening it never moves the card (its height counts folded)
        let f = R(); f.ask("a1")
        guard let m = f.model("a1") else { check(false, "the card"); return }
        f.m.pinRoom(columnHeight: 1000); f.m.cardLaidOut(m, height: 300)
        check(f.m.cardFits(m) && !f.m.detailsOpen(m), "fits, folded")
        f.m.setDetails(m, open: true)
        f.m.cardLaidOut(m, height: 900)                     // open: taller than the room
        check(f.m.detailsOpen(m) && f.m.cardFits(m) && f.m.cardPinnedWhole(m), "opened: still pinned, still open (its folded height counts)")
        f.m.setDetails(m, open: false); f.m.cardLaidOut(m, height: 300)
        check(!f.m.detailsOpen(m) && f.m.cardFits(m), "folded again")
        // two views for a moment (pinned → in place): appear before disappear keeps the keys
        f.m.cardShown(m); f.timers.advance(CardKeys.cardOnScreen + 0.1); f.m.enterCardMode(m)
        f.m.cardShown(m); f.m.cardHidden(m)
        check(f.m.keysActive(m), "the new view came before the old one went: card mode stays")
        f.m.cardHidden(m)
        check(!f.m.keysActive(m), "the last view went: card mode ends")
        // the card answered: its layout facts go
        f.m.setDetails(m, open: true)
        f.resumed("a1")
        check(f.m.cardHeights.isEmpty && f.m.openDetails.isEmpty, "answered: its height and fold forgotten")
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
}
