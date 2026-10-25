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
}
