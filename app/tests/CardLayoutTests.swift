// M2 A2: each option has exactly one control; 「可以」 takes a click only once the whole card has been seen. The four card
// kinds (plan, action, choice, missing information), the shapes the harness builds and the recorded ones, and what it
// may send that this app does not know (an unknown kind of card or option, an option with no words, more than nine).
//
// - controlTables: card × its options → the controls: one per option with words, its index, kind and words its own,
//   its role from the handoff's §1.4 table (written out here), list or button, the keys 1–9 in the order shown.
// - sendTables: through the window's model, each control (by click, and by its key) sends its own option's index with
//   the card's ask_id, and nothing else — the old approve/deny squash can't come back in the new window.
// - wholeCardTests: before the card's end was on screen, approve-type controls (and their keys) send nothing; the rest
//   do; after, all do.
// - factsTests: the plan's steps and the consent's outgoing lines are on the card, with the text whole.
// - keyGateTests: which key-downs are 1–9.
// Run from DecisionTests.main (build.sh).

import Foundation

enum CardLayoutTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "layout: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("layout.controlTables"); controlTables()
        DecisionTests.group("layout.sendTables"); sendTables()
        DecisionTests.group("layout.wholeCardTests"); wholeCardTests()
        DecisionTests.group("layout.factsTests"); factsTests()
        DecisionTests.group("layout.keyGateTests"); keyGateTests()
        DecisionTests.group("layout.typingGuardTests"); typingGuardTests()
    }

    // MARK: samples

    static func opt(_ kind: String, _ text: String) -> [String: Any] { ["kind": kind, "text": text] }

    /// A recorded card (tests/fixtures/session), as the harness sent it.
    static func recorded(_ name: String) -> [String: Any] {
        guard let l = SessionTests.lines(name).first(where: { $0.event.kind == "ask" }), case .ask(let a) = l.event,
              let d = try? JSONEncoder().encode(a.card), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            check(false, "\(name): a recorded card"); return [:]
        }
        return o
    }

    /// The cards: recorded, the harness's builders' shapes (harness src/executor/service.ts, orchestrator/index.ts,
    /// skills/library.ts), and what an app must still handle.
    static func samples() -> [(name: String, card: [String: Any])] {
        let consent: [String: Any] = ["action": "click", "action_text": "在 Mail 里点「发送」", "object": "window:mail#12", "object_label": "Mail「周报」",
                                      "consequence": "external", "site": "mail.example.com",
                                      "outgoing": [["kind": "to", "label": "收件人", "value": "wang@example.com"],
                                                   ["kind": "subject", "label": "主题", "value": "周报"], ["kind": "body", "label": "正文", "value": "本周…"]]]
        var many: [[String: Any]] = (1...11).map { opt("reading", "第\($0)种") }
        many.append(opt("cancel", "先别做了"))
        return [
            ("plan (recorded)", recorded("task-card")),
            ("missing (recorded)", recorded("task-question")),
            ("action: consent", ["kind": "action", "text": "这会把内容发出去：在 Mail 里点「发送」", "free_text": false, "blocking": true, "consent": consent,
                                 "options": [opt("approve", "可以"), opt("skip_step", "这一步不要"), opt("cancel", "先别做了")]]),
            ("action: reconcile", ["kind": "action", "text": "文件和计划对不上，接着做吗？", "free_text": false, "blocking": true,
                                   "options": [opt("approve", "接着做"), opt("cancel", "先停下")]]),
            ("action: words", ["kind": "action", "text": "要把「旧稿」移到废纸篓", "free_text": true, "blocking": true,
                               "options": [opt("approve", "可以"), opt("skip_step", "这一步不要，其余照做"), opt("cancel", "先别做了")]]),
            ("ambiguity", ["kind": "ambiguity", "text": "「周报」是哪一个？", "free_text": true, "blocking": true,
                           "options": [opt("reading", "周报.txt"), opt("reading", "周报-终稿.txt"), opt("reading", "周报(1).txt"),
                                       opt("delegate", "由你决定"), opt("cancel", "先别做了")]]),
            ("ambiguity: no words", ["kind": "ambiguity", "text": "以后按哪个整理？", "free_text": false, "blocking": true,
                                     "options": [opt("reading", "按日期"), opt("reading", "按类型"), opt("never_ask_this", "以后别问")]]),
            ("missing: values", ["kind": "missing", "text": "发给谁？", "free_text": true, "blocking": true,
                                 "options": [opt("value", "小王"), opt("value", "小李"), opt("delegate", "由你决定"), opt("cancel", "先别做了")]]),
            ("plan: same words twice", ["kind": "plan", "text": "两步", "free_text": true, "blocking": true,
                                        "options": [opt("approve", "可以"), opt("other", "可以"), opt("cancel", "先别做了")]]),
            ("an option with no words", ["kind": "ambiguity", "text": "哪个？", "free_text": true, "blocking": true,
                                         "options": [opt("reading", "甲"), opt("reading", ""), opt("reading", "丙"), opt("cancel", "先别做了")]]),
            ("unknown kinds", ["kind": "zzz_new", "text": "新种类的卡", "free_text": false, "blocking": true,
                               "options": [opt("proposal", "这样改"), opt("undo_and_reading", "撤回再按这个"), opt("zzz", "新选项"), opt("approve", "好")]]),
            ("result_check", ["kind": "result_check", "text": "做完了，对吗？", "free_text": true, "blocking": true,
                              "options": [opt("approve", "对"), opt("other", "不对"), opt("cancel", "先别做了")]]),
            ("cannot", ["kind": "cannot", "text": "这样做不到", "free_text": true, "blocking": true,
                        "options": [opt("proposal", "改成这样"), opt("cancel", "算了")]]),
            ("eleven picks", ["kind": "ambiguity", "text": "哪一种？", "free_text": true, "blocking": true, "options": many]),
        ]
    }

    /// The handoff's §1.4 table (an option's kind → what its control is), written out: the test's own, not the app's.
    static let roles: [String: CardModel.Role] = ["approve": .approve, "skip_step": .skipStep, "cancel": .cancel, "reading": .choice,
                                                  "value": .choice, "proposal": .choice, "undo_and_reading": .choice, "delegate": .delegate,
                                                  "undo": .undo]
    static func role(_ kind: String) -> CardModel.Role { roles[kind] ?? .other }

    static func model(_ card: [String: Any], askId: String = "a1") -> CardModel {
        let d = try! JSONSerialization.data(withJSONObject: card)
        let e = try! JSONDecoder().decode(CardEvent.self, from: d)
        return CardModel(card: e, runId: CardStoreTests.rid, askId: askId)
    }

    // MARK: - controls

    static func controlTables() {
        var rows = 0
        for (name, json) in samples() {
            let options = (json["options"] as? [[String: Any]]) ?? []
            let card = model(json)
            let l = CardLayout(card)
            let texted = options.indices.filter { !((options[$0]["text"] as? String) ?? "").isEmpty }
            // one control per option with words: the same set, none twice
            let idx = l.controls.map(\.index)
            check(idx.sorted() == texted && Set(idx).count == idx.count, "\(name): one control per option with words: \(idx) vs \(texted)")
            for c in l.controls {
                let o = options[c.index]
                let k = o["kind"] as? String ?? "", t = o["text"] as? String ?? ""
                check(c.button.kind == k && c.button.text == t && c.button.askId == "a1" && c.button.runId == CardStoreTests.rid,
                      "\(name): control \(c.index) is its own option's (\(k) \(t))")
                check(c.button.role == role(k), "\(name): \(k) → \(role(k)), got \(c.button.role)")
                check(c.slot == (role(k) == .choice ? .list : .button), "\(name): \(k) in the \(role(k) == .choice ? "list" : "buttons")")
                check(c.prominent == (k == "approve"), "\(name): only approve is the prominent one")
            }
            // shown: the list first, then the buttons, each in the harness's order; keys 1–9 in that order
            let list = texted.filter { role(options[$0]["kind"] as? String ?? "") == .choice }
            let rest = texted.filter { role(options[$0]["kind"] as? String ?? "") != .choice }
            check(idx == list + rest, "\(name): shown in order, the list then the buttons: \(idx)")
            for (i, c) in l.controls.enumerated() {
                check(c.key == (i < 9 ? i + 1 : nil), "\(name): control \(i + 1)'s key: \(String(describing: c.key))")
                if let k = c.key { check(l.control(forKey: k) == c, "\(name): key \(k) picks it") }
            }
            check(l.control(forKey: 0) == nil && l.control(forKey: 10) == nil && (l.controls.count >= 9 || l.control(forKey: l.controls.count + 1) == nil),
                  "\(name): no key past its controls")
            check(l.field == (json["free_text"] as? Bool ?? false), "\(name): its own field iff it takes words")
            check(l.text == (json["text"] as? String ?? ""), "\(name): the text whole")
            for c in l.controls { check(!CardLayout.hint(c, lang: .zhHans).isEmpty, "\(name): VoiceOver hint for \(c.button.kind)") }
            rows += 1
        }
        check(rows == samples().count, "every sample: \(rows)")
    }

    // MARK: - what each control sends

    static func sendTables() {
        for (name, json) in samples() {
            let options = (json["options"] as? [[String: Any]]) ?? []
            for c in CardLayout(model(json)).controls {
                for byKey in [false, true] {
                    if byKey && c.key == nil { continue }
                    let r = CardStoreTests.Rig()
                    r.ask("a1", card: json)
                    guard let m = r.model("a1") else { check(false, "\(name): the card is open"); continue }
                    r.m.cardBody(m, contentHeight: 1, visibleHeight: 1, offset: 0)
                    if byKey { check(r.m.pressKey(c.key!), "\(name): key \(c.key!) picks") } else { r.m.click(c.button) }
                    r.timers.advance(CardStore.takeBack)
                    let sent = r.wire.answers("a1")
                    let kind = options[c.index]["kind"] as? String ?? ""
                    check(sent.count == 1 && sent.first?["option"] as? Int == c.index && sent.first?["ask_id"] as? String == "a1",
                          "\(name): \(byKey ? "key \(c.key!)" : "a click") on \(kind) «\(c.button.text)» sends option \(c.index): \(sent)")
                }
            }
            // a key past the card's controls picks nothing (and is the window's)
            let r = CardStoreTests.Rig()
            r.ask("a1", card: json)
            let n = CardLayout(model(json)).controls.count
            if n < 9 { check(!r.m.pressKey(n + 1) && r.wire.count("answer") == 0, "\(name): key \(n + 1) picks nothing") }
        }
        // no card open (expired, answered): the keys pick nothing
        let r = CardStoreTests.Rig()
        r.ask("a1")
        r.void("a1", "timeout")
        check(!r.m.pressKey(1), "an expired card: key 1 picks nothing")
    }

    // MARK: - the whole card first

    static func wholeCardTests() {
        for (name, json) in samples() {
            let card = model(json)
            for c in CardLayout(card).controls {
                // (handoff: approve, "you decide"; and a kind this app does not know, which might approve: it fails closed)
                let waits = c.button.role == .approve || c.button.role == .delegate || c.button.role == .other
                let r = CardStoreTests.Rig()
                r.ask("a1", card: json)
                guard let m = r.model("a1") else { continue }
                check(r.m.buttonEnabled(c.button, card: m, in: r.state) == !waits, "\(name): \(c.button.kind) \(waits ? "off" : "on") before the card was seen")
                // half way down a long card: still not seen
                r.m.cardBody(m, contentHeight: 900, visibleHeight: 200, offset: 300)
                if let k = c.key { r.m.pressKey(k) } else { r.m.click(c.button) }
                r.timers.advance(CardStore.takeBack)
                check(r.wire.count("answer") == (waits ? 0 : 1), "\(name): \(c.button.kind) before the end was on screen: \(r.wire.count("answer")) sent")
                if waits {
                    r.m.cardBody(m, contentHeight: 900, visibleHeight: 200, offset: 700)
                    check(r.m.buttonEnabled(c.button, card: m, in: r.state), "\(name): \(c.button.kind) on once the end was on screen")
                    if let k = c.key { r.m.pressKey(k) } else { r.m.click(c.button) }
                    r.timers.advance(CardStore.takeBack)
                    check(r.wire.answers("a1").first?["option"] as? Int == c.index, "\(name): then it sends")
                }
            }
        }
    }

    // MARK: - the facts on the card

    static func factsTests() {
        let plan = CardLayout(model(recorded("task-card")))
        check(plan.kind == .plan && plan.plan.count == 1 && plan.plan[0].purpose == "把正文改成「新的」" && plan.plan[0].objects == ["编辑器「笔记.txt」"]
              && plan.plan[0].changesYours && !plan.plan[0].sendsOut, "the recorded plan: its step, what it touches, that it changes your things: \(plan.plan)")
        check(plan.text.contains("可以吗"), "the plan's text stays whole beside its steps")
        var two = recorded("task-card")
        two["plan"] = ["steps": [["purpose": "打开网页邮箱", "class": "read", "objects": [], "sites": [["host": "mail.example.com"]]],
                                 ["purpose": "发出周报", "class": "external", "objects": [["ref": "window:mail", "label": "", "owner": "", "marks": []]],
                                  "sites": [["host": "mail.example.com", "sends": "正文、附件", "asks_each": true]]]],
                       "foreground": ["apps": ["Safari"], "note": ""]]
        let p2 = CardLayout(model(two))
        check(p2.plan.map(\.n) == [1, 2] && !p2.plan[0].sendsOut && p2.plan[1].sendsOut && p2.plan[1].objects == ["window:mail"]
              && p2.plan[1].sites == [CardLayout.Site(host: "mail.example.com", sends: "正文、附件", asksEach: true)] && p2.foreground == ["Safari"],
              "two steps: the external one sends out, its site and what goes; an object with no label shows its ref; the front app")
        let action = CardLayout(model(samples().first { $0.name == "action: consent" }!.card))
        check(action.consent == CardLayout.Consent(action: "在 Mail 里点「发送」", object: "Mail「周报」", site: "mail.example.com",
                                                   outgoing: [.init(label: "收件人", value: "wang@example.com"), .init(label: "主题", value: "周报"), .init(label: "正文", value: "本周…")]),
              "the action card: the action, its object, the site, every line of what goes out: \(String(describing: action.consent))")
        check(CardLayout(model(samples().first { $0.name == "ambiguity" }!.card)).consent == nil, "no consent on a choice card")
        // VoiceOver's card label: its state, its kind, its first sentence, its number of options (handoff §3.10)
        let hint = CardLayout.hint(action.controls[0], lang: .zhHans)
        check(hint == "同意，任务接着做。按 1", "an approve's hint says what it does and its key: \(hint)")
    }

    // MARK: - the keys

    static func keyGateTests() {
        for n in 1...9 { check(CardKeys.number(characters: "\(n)", commandLike: false, mainWindowIsKey: true, editingText: false) == n, "\(n) is key \(n)") }
        check(CardKeys.number(characters: "1", commandLike: false, mainWindowIsKey: true, editingText: false, isRepeat: true) == nil, "an auto-repeat: no key")
        for c in ["0", "a", "10", "", "１"] { check(CardKeys.number(characters: c, commandLike: false, mainWindowIsKey: true, editingText: false) == nil, "«\(c)» is no key") }
        check(CardKeys.number(characters: nil, commandLike: false, mainWindowIsKey: true, editingText: false) == nil, "no characters: no key")
        check(CardKeys.number(characters: "1", commandLike: true, mainWindowIsKey: true, editingText: false) == nil, "⌘1 / ⌃1 / ⌥1: not a card key")
        check(CardKeys.number(characters: "1", commandLike: false, mainWindowIsKey: false, editingText: false) == nil, "the main window not the key one: no key")
        check(CardKeys.number(characters: "1", commandLike: false, mainWindowIsKey: true, editingText: true) == nil, "typing in a field: the digit is typed")
        // the monitor goes through the gate and the model, nothing else
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Main/CardViews.swift")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let monitor = text.components(separatedBy: "struct CardKeyMonitor").dropFirst().first ?? ""
        check(monitor.contains("e.window === w") && monitor.contains("w.firstResponder is NSText"),
              "the key monitor: its own window only, and says whether a field is typed in")
        check(monitor.contains("e.isARepeat") && !monitor.contains("CardKeys.number("), "the monitor hands every key-down, with its repeat flag, to the model's gate")
        let main = (try? String(contentsOf: url.deletingLastPathComponent().appendingPathComponent("MainSplitView.swift"), encoding: .utf8)) ?? ""
        check(main.contains("shell.keyDown(characters:"), "the chat column hands every key-down to the model")
    }

    // MARK: - typing never lands on a card (#111 review at 8fc3cdb)

    /// The user types in the composer; a card arrives; the composer is disabled and SwiftUI may drop the focus, so the
    /// next key-downs no longer go to a field. Digits typed on must not answer the card ("3" is 先别做了: at once, the task
    /// ends). The guards are times, not the focus: a key picks only after `CardKeys.quiet` with no key-down at all, on a
    /// card on screen for `CardKeys.cardOnScreen`.
    static func typingGuardTests() {
        func key(_ r: CardStoreTests.Rig, _ c: String, editing: Bool = false, repeating: Bool = false) -> Bool {
            r.m.keyDown(characters: c, commandLike: false, mainWindowIsKey: true, editingText: editing, isRepeat: repeating)
        }
        func arrive(_ r: CardStoreTests.Rig) -> CardModel {
            r.ask("a1")
            let m = r.model("a1")!
            r.m.cardShown(m)                                      // (on screen now)
            r.m.cardBody(m, contentHeight: 1, visibleHeight: 1, offset: 0)
            return m
        }
        // typing in the composer (a field), the card comes, the focus is gone, the user types digits on at 0.2 s a key
        let r = CardStoreTests.Rig()
        for ch in "明天发周报给" { _ = key(r, String(ch), editing: true); r.timers.advance(0.2) }
        _ = arrive(r)
        var picked = false
        for ch in "2023年3月" { picked = key(r, String(ch)) || picked; r.timers.advance(0.2) }
        r.timers.advance(CardStore.takeBack * 2)
        check(!picked && r.wire.count("answer") == 0 && r.phase("a1") == .open, "digits typed on after the card came (focus gone): nothing picked, nothing sent")
        // a pause, then a deliberate key: it picks (through the take-back)
        r.timers.advance(CardKeys.quiet)
        check(key(r, "1") && r.phase("a1")?.pending != nil, "after a pause of \(CardKeys.quiet) s: key 1 picks")
        // a digit inside a burst renews the guard: 2 then 3 at 0.5 s apart after a pause — only the 2 picks
        let b = CardStoreTests.Rig()
        _ = arrive(b)
        b.timers.advance(2)
        check(key(b, "2"), "a first key after a pause picks")
        b.timers.advance(0.5)
        check(!key(b, "3") && b.wire.count("answer") == 0, "the next one 0.5 s later does not (先别做了 would go at once)")
        // the card must have been on screen: a pause, the card comes, a key at once does nothing
        let c = CardStoreTests.Rig()
        c.timers.advance(5)
        _ = arrive(c)
        c.timers.advance(CardKeys.cardOnScreen / 2)
        check(!key(c, "1") && c.phase("a1") == .open, "a key \(CardKeys.cardOnScreen / 2) s after the card came: nothing")
        c.timers.advance(CardKeys.cardOnScreen + CardKeys.quiet)
        check(key(c, "1"), "on screen \(CardKeys.cardOnScreen) s and quiet: it picks")
        // a card never on screen (another session shown, the window hidden): no key picks on it
        let d = CardStoreTests.Rig()
        d.ask("a1")
        d.timers.advance(5)
        check(!key(d, "1"), "a card not on screen: nothing")
        // auto-repeat: a held key never picks, and keeps the guard (it is typing)
        let e = CardStoreTests.Rig()
        _ = arrive(e)
        e.timers.advance(5)
        check(!key(e, "1", repeating: true) && e.phase("a1") == .open, "an auto-repeat: nothing")
        e.timers.advance(0.1)
        check(!key(e, "1"), "and the key right after it is still inside the burst")
        // typing in a field (the card's own words): never a key
        let f = CardStoreTests.Rig()
        _ = arrive(f)
        f.timers.advance(5)
        check(!key(f, "1", editing: true), "typing in a field: the digit is typed")
        check(CardKeys.cardOnScreen >= 0.8 && CardKeys.quiet >= 0.8 && CardKeys.cardOnScreen <= 2 && CardKeys.quiet <= 2, "the guards: about a second")
    }
}
