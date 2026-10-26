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
        DecisionTests.group("layout.cardModeTests"); cardModeTests()
        DecisionTests.group("layout.cardModeEndsTests"); cardModeEndsTests()
        DecisionTests.group("layout.labelIsKeyTests"); labelIsKeyTests()
        DecisionTests.group("layout.escTabTests"); escTabTests()
        DecisionTests.group("layout.gateFlipTests"); gateFlipTests()
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
                    r.m.fit(m)
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

    // MARK: - every option at once (A2, invariant 3)

    /// The card never scrolls inside: each option takes a click the moment the card shows, whatever its height. A card
    /// too tall for the pinned place stays in place in the chat; there no digit picks -- its controls may be off screen
    /// (#124 Codex review at 80c339e) -- while Tab, Space and Esc, which act on what has the focus, still do (CardKeysTests).
    static func wholeCardTests() {
        for (name, json) in samples() {
            let card = model(json)
            for c in CardLayout(card).controls {
                let approveType = c.button.role == .approve || c.button.role == .delegate || c.button.role == .other
                for tall in [false, true] {
                    // a click: at once, on any card
                    let r = CardStoreTests.Rig()
                    r.ask("a1", card: json)
                    guard let m = r.model("a1") else { continue }
                    r.m.pinRoom(columnHeight: 1000); r.m.cardLaidOut(m, height: tall ? 900 : 200)
                    check(r.m.cardFits(m) == !tall && r.m.cardPinnedWhole(m) == !tall, "\(name): \(tall ? "tall: in place in the chat" : "fits: pinned")")
                    check(r.m.buttonEnabled(c.button, card: m, in: r.state), "\(name), \(tall ? "tall" : "fits"): \(c.button.kind) takes a click at once")
                    r.m.click(c.button)
                    r.timers.advance(CardStore.takeBack)
                    check(r.wire.answers("a1").first?["option"] as? Int == c.index, "\(name), \(tall ? "tall" : "fits"): a click on \(c.button.kind) sends it")
                    // its key, in card mode
                    guard let k = c.key else { continue }
                    let q = CardStoreTests.Rig()
                    q.ask("a1", card: json)
                    guard let qm = q.model("a1") else { continue }
                    q.m.pinRoom(columnHeight: 1000); q.m.cardLaidOut(qm, height: tall ? 900 : 200)
                    q.m.cardShown(qm); q.timers.advance(CardKeys.cardOnScreen + 0.1); q.m.enterCardMode(qm)
                    let works = !tall
                    _ = approveType
                    let ctl = CardLayout(qm).controls.first { $0.index == c.index }!
                    check(q.m.keyWorks(qm, ctl) == works, "\(name), \(tall ? "tall" : "fits"): key \(k) on \(c.button.kind) \(works ? "works" : "does nothing")")
                    _ = q.m.keyDown(characters: "\(k)", commandLike: false, mainWindowIsKey: true, editingText: false, isRepeat: false)
                    q.timers.advance(CardStore.takeBack)
                    check((q.wire.answers("a1").first?["option"] as? Int == c.index) == works, "\(name), \(tall ? "tall" : "fits"): key \(k) sends \(c.button.kind): \(works)")
                }
            }
        }
        // not laid out yet: drawn pinned (to be measured); its approve-type keys wait
        let r = CardStoreTests.Rig()
        r.ask("a1", "action")
        if let m = r.model("a1") {
            check(r.m.cardPinnedWhole(m) && !r.m.cardFits(m), "not laid out: pinned, not known to fit")
            r.m.pinRoom(columnHeight: 1000); r.m.cardLaidOut(m, height: 600)
            check(!r.m.cardFits(m), "600 in a 1000 column (room 500): too tall")
            r.m.pinRoom(columnHeight: 1400)
            check(r.m.cardFits(m), "the window grew (room 700): it fits now -- pinned again")
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
                                                   outgoing: [.init(label: "收件人", value: "wang@example.com", kind: "to"), .init(label: "主题", value: "周报", kind: "subject"),
                                                              .init(label: "正文", value: "本周…", kind: "body")]),
              "the action card: the action, its object, the site, every line of what goes out: \(String(describing: action.consent))")
        // U3 §2.2: 「要发出去的」 by the executor's kinds and order, never by what a label says; no line lost
        typealias O = CardLayout.Outgoing
        func block(_ o: [O]) -> CardLayout.Block { CardLayout.Consent(action: "", object: "", site: nil, outgoing: o).block }
        let mail = block([O(label: "url", value: "https://mail.example.com", kind: "url"), O(label: "收件人", value: "许诺", kind: "field"),
                          O(label: "主题", value: "Re: 方案评审", kind: "field"), O(label: "typed", value: "我看一下再说", kind: "typed"),
                          O(label: "text", value: "10月20日 许诺 写道", kind: "text")])
        check(mail.lead?.value == "我看一下再说" && mail.fields.map(\.label) == ["收件人", "主题"] && mail.text.map(\.value) == ["10月20日 许诺 写道"]
              && mail.other.map(\.kind) == ["url"] && mail.count == 5, "mail: what was typed leads, the fields in order, the window's text, the URL kept: \(mail)")
        let picked = block([O(label: "选项", value: "加急", kind: "selected")])
        check(picked.lead == nil && picked.selected.map(\.value) == ["加急"] && picked.count == 1, "only a picked item: no lead, the item")
        let noTyped = block([O(label: "金额", value: "120", kind: "field"), O(label: "备注", value: "x", kind: "field")])
        check(noTyped.lead?.label == "金额" && noTyped.fields.map(\.label) == ["备注"], "nothing typed: the first field leads")
        check(block([]).count == 0 && block([]).lead == nil, "nothing goes out: an empty block")
        var g = CardStoreTests.RNG(x: 77)
        let kinds = ["field", "selected", "typed", "text", "url", "other"]
        for _ in 0..<300 {
            let o = (0..<g.next(9)).map { i in O(label: "l\(i)", value: "v\(i)", kind: kinds[g.next(kinds.count)]) }
            let b = block(o)
            let all = (b.lead.map { [$0] } ?? []) + b.fields + b.selected + b.text + b.other
            if Set(all.map(\.value)) != Set(o.map(\.value)) || all.count != o.count { check(false, "a line lost or twice: \(o) -> \(b)"); break }
        }
        check(CardLayout(model(samples().first { $0.name == "ambiguity" }!.card)).consent == nil, "no consent on a choice card")
        // VoiceOver's card label: its state, its kind, its first sentence, its number of options (handoff §3.10)
        let hint = CardLayout.hint(action.controls[0], keys: true, lang: .zhHans)
        check(hint == "同意，任务接着做。按 1" && CardLayout.hint(action.controls[0], lang: .zhHans) == "同意，任务接着做",
              "an approve's hint says what it does, and its key only while keys act: \(hint)")
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
        // (the one wiring, ShellModel.cardKeyHandlers — its handlers are run in SurfaceTests.goalCardKeysTests)
        check(main.contains("CardKeyMonitor(shell.cardKeyHandlers)"), "the chat column hands every key-down to the model")
    }

    // MARK: - card mode: keys act only after an explicit move into the card (#111 reviews at 8fc3cdb and 86878f6)

    /// The rows of ShellModel's card-mode table, through the model on the simulated helper. The user's moves: typing
    /// (a field being edited, or not once the composer was disabled and the focus went), a click on the card, Esc / Tab;
    /// a digit acts on the card only in card mode for that card.
    static func cardModeTests() {
        typealias Rig = CardStoreTests.Rig
        func key(_ r: Rig, _ c: String, editing: Bool = false, repeating: Bool = false, cmd: Bool = false) -> Bool {
            r.m.keyDown(characters: c, commandLike: cmd, mainWindowIsKey: true, editingText: editing, isRepeat: repeating)
        }
        /// A card on screen (its whole body seen) — and, after `wait` seconds, the move given.
        func arrive(_ r: Rig, _ id: String = "a1", kind: String = "action") -> CardModel {
            r.ask(id, kind)
            let m = r.model(id)!
            r.m.cardShown(m)
            r.m.fit(m)
            return m
        }
        // row 1: the composer was being typed in, the card came, the focus went; digits after any pause: never the card's
        let a = Rig()
        for ch in "明天发周报给" { _ = key(a, String(ch), editing: true); a.timers.advance(0.2) }
        let ca = arrive(a)
        var picked = false
        for ch in "2023年3月" { picked = key(a, String(ch)) || picked; a.timers.advance(0.2) }
        a.timers.advance(1.1)
        picked = key(a, "1") || picked                                 // (Codex: a 1.1 s pause, then 1)
        a.timers.advance(5)
        picked = key(a, "3") || picked
        a.timers.advance(CardStore.takeBack * 2)
        check(!picked && a.wire.count("answer") == 0 && a.phase("a1") == .open, "no move into the card: digits after any pause never reach it")
        check(!a.m.keysActive(ca), "and its keys are not shown")
        // row 1b: a field being edited, even in card mode
        a.m.enterCardMode(ca)
        check(a.m.keysActive(ca) && !key(a, "1", editing: true) && a.phase("a1") == .open, "in card mode, typing in a field: the digit is typed")
        // row 2: an explicit move (a click on the card; Esc; Tab), the card on screen ≥ 1 s: the digit picks that option
        for move in ["click", "esc", "tab"] {
            let r = Rig()
            let c = arrive(r)
            r.timers.advance(CardKeys.cardOnScreen)
            switch move {
            case "click": r.m.enterCardMode(c)
            case "esc": check(!key(r, "\u{1b}"), "Esc is not consumed")
            default: check(!key(r, "\t"), "Tab is not consumed")
            }
            check(r.m.keysActive(c), "\(move): card mode, its keys shown")
            check(key(r, "2") && r.phase("a1")?.pending == .option(runId: CardStoreTests.rid, askId: "a1", option: 1), "\(move): 2 picks 这一步不要 (held)")
            check(!key(r, "2", repeating: true) && !key(r, "1", cmd: true), "\(move): an auto-repeat or ⌘1: nothing")
        }
        // a move made as the card appeared does not count (the card shown < 1 s)
        let b = Rig()
        let cb = arrive(b)
        b.timers.advance(CardKeys.cardOnScreen / 2)
        _ = key(b, "\u{1b}"); b.m.enterCardMode(cb)
        check(!b.m.keysActive(cb) && !key(b, "1"), "a move within \(CardKeys.cardOnScreen) s of the card appearing: no card mode")
        // the whole card first: approve's key picks nothing before the body's end was on screen
        let w = Rig()
        w.ask("a1")
        let cw = w.model("a1")!
        w.m.cardShown(cw); w.timers.advance(2); w.m.enterCardMode(cw)
        _ = key(w, "1")
        w.timers.advance(CardStore.takeBack)
        check(w.wire.count("answer") == 0, "in card mode, approve before the whole card was seen: nothing")
        // row 3: a pick held, another option's key replaces it, the take-back starts again
        let c = Rig()
        let cc = arrive(c)
        c.timers.advance(2); c.m.enterCardMode(cc)
        _ = key(c, "1")
        c.timers.advance(0.5)
        check(key(c, "2"), "a second key within the take-back is taken")
        c.timers.advance(CardStore.takeBack - 0.1)
        check(c.wire.count("answer") == 0, "the take-back started again at the second key")
        c.timers.advance(0.2)
        check(c.wire.answers("a1").map { $0["option"] as? Int } == [1], "only the replacement goes: \(c.wire.answers("a1"))")
        // row 4: a pick held, the way out's key cancels now (Codex: 1 then 3 within 0.5 s)
        let d = Rig()
        let cd = arrive(d)
        d.timers.advance(2); d.m.enterCardMode(cd)
        _ = key(d, "1")
        d.timers.advance(0.5)
        _ = key(d, "3")
        check(d.wire.answers("a1").map { $0["option"] as? Int } == [2], "the way out's key: sent at once: \(d.wire.answers("a1"))")
        d.timers.advance(CardStore.takeBack * 2)
        check(d.wire.answers("a1").count == 1, "and the held approve never goes")
        // row 4b: 「先别做了」 clicked while a key's pick is held: the same
        let d2 = Rig()
        let cd2 = arrive(d2)
        d2.timers.advance(2); d2.m.enterCardMode(cd2)
        _ = key(d2, "1")
        d2.m.click(cd2.buttons.first { $0.role == .cancel }!)
        d2.timers.advance(CardStore.takeBack * 2)
        check(d2.wire.answers("a1").map { $0["option"] as? Int } == [2], "先别做了 clicked: cancels at once")
        // row 5: a new card while in card mode needs a new move
        let e = Rig()
        let ce = arrive(e)
        e.timers.advance(2); e.m.enterCardMode(ce)
        e.resumed("a1")                                              // (answered elsewhere; the task asks again)
        let ce2 = arrive(e, "a2")
        e.timers.advance(2)
        check(!e.m.keysActive(ce2) && !key(e, "2") && e.phase("a2") == .open, "a new card: no keys until a move into it")
        e.m.enterCardMode(ce2)
        check(key(e, "2"), "after a click on it: keys")
        // the label rule: a key's label is shown iff pressing it does what it says — a result card takes no keys
        let u = Rig()
        u.ask("a1"); u.resumed("a1")
        u.emit("task_done", ["status": "succeeded", "reason": "", "summary": "",
                             "result_card": ["kind": "result", "text": "改好了", "blocking": false, "free_text": false,
                                             "options": [["kind": "approve", "text": "好的"], ["kind": "undo", "text": "撤回"]]]])
        guard let rc = u.state.task(CardStoreTests.rid)?.resultCard else { check(false, "the result card"); return }
        let rm = CardModel(resultCard: rc, runId: CardStoreTests.rid)
        u.m.cardShown(rm); u.timers.advance(2); u.m.enterCardMode(rm)
        check(!u.m.keysActive(rm) && !key(u, "2") && u.wire.count("respond") == 0, "a result card: no keys shown, none act")
        let rl = CardLayout(rm)
        check(rl.controls.allSatisfy { !CardLayout.hint($0, keys: u.m.keysActive(rm), lang: .en).contains("Key") }, "and no key in its hints")
        for r in [a, c] {   // (a card's label and its key agree: off without card mode, on in it)
            let m = r.model("a1")!
            check(CardLayout(m).controls.allSatisfy { CardLayout.hint($0, keys: r.m.keysActive(m), lang: .en).contains("Key") == r.m.keysActive(m) },
                  "hints say a key exactly when keys act")
        }
    }

    // MARK: - card mode ends; a label iff its key acts; Esc / Tab (#111 review at 82ce551, its repros adopted)

    static func modeKey(_ r: CardStoreTests.Rig, _ c: String, editing: Bool = false, repeating: Bool = false, cmd: Bool = false, composing: Bool = false) -> Bool {
        r.m.keyDown(characters: c, commandLike: cmd, mainWindowIsKey: true, editingText: editing, isRepeat: repeating, composing: composing)
    }
    static func modeArrive(_ r: CardStoreTests.Rig, _ id: String = "a1", kind: String = "action", seen: Bool = true) -> CardModel {
        r.ask(id, kind)
        let m = r.model(id)!
        r.m.cardShown(m)
        if seen { r.m.fit(m) }
        return m
    }

    /// Card mode ends when the card is no longer on screen in the key window: the card's view goes (the window closed,
    /// the card answered), the window stops being the key one or another app comes forward (CardKeyMonitor's
    /// notifications: leaveCardMode), another session is shown. Back again: a new move, and 1 s on screen first.
    static func cardModeEndsTests() {
        // (repro a) the window closed and opened again
        let r = CardStoreTests.Rig()
        let c = modeArrive(r)
        r.timers.advance(2); r.m.enterCardMode(c)
        r.m.cardHidden(c); r.timers.advance(3600); r.m.cardShown(c)
        check(!r.m.keysActive(c), "window closed and reopened: card mode is not still on (no labels at once)")
        check(!modeKey(r, "3") && r.wire.count("answer") == 0, "and the first digit (3 = 先别做了) sends nothing")
        r.m.enterCardMode(c)
        check(!r.m.keysActive(c), "a move right after it is back: not yet (1 s on screen again)")
        r.timers.advance(CardKeys.cardOnScreen); r.m.enterCardMode(c)
        check(r.m.keysActive(c), "after 1 s on screen and a new move: card mode")
        // (repro b) another session shown, then back
        let s = CardStoreTests.Rig()
        let cs = modeArrive(s)
        s.timers.advance(2); s.m.enterCardMode(cs)
        s.m.selected = "ses_other"
        check(!s.m.keysActive(cs), "another session shown: card mode ends (even before the card's view goes)")
        s.m.cardHidden(cs); s.timers.advance(60)
        s.m.selected = CardStoreTests.sid; s.m.cardShown(cs)
        check(!modeKey(s, "2") && s.phase("a1") == .open, "back from another session: a digit at once does not pick")
        // an animated replacement: the new card appears before the old one (in card mode) disappears — the old one's going
        // touches only its own state; after 1 s the new card enters card mode
        let n = CardStoreTests.Rig()
        let cn = modeArrive(n)
        n.timers.advance(2); n.m.enterCardMode(cn)
        n.feed(n.line("ask_void", ["ask_id": "a1", "why": "steer"]))
        let cn2 = modeArrive(n, "a2")                     // (appears first)
        n.m.cardHidden(cn)                                // (then the old one goes)
        n.timers.advance(CardKeys.cardOnScreen)
        _ = modeKey(n, "\u{1b}")
        check(n.m.keysActive(cn2), "new card shown, then the old (in card mode) hidden: after 1 s Esc enters the new card's card mode")
        let n2 = CardStoreTests.Rig()                     // (and in the other order, and by a click)
        let cm = modeArrive(n2)
        n2.timers.advance(2); n2.m.enterCardMode(cm)
        n2.feed(n2.line("ask_void", ["ask_id": "a1", "why": "steer"]))
        n2.m.cardHidden(cm)
        let cm2 = modeArrive(n2, "a2")
        n2.timers.advance(CardKeys.cardOnScreen); n2.m.enterCardMode(cm2)
        check(n2.m.keysActive(cm2) && !n2.m.keysActive(cm), "old hidden first, then the new shown: a click after 1 s enters the new card")
        // the window stops being the key one / another app comes forward
        let w = CardStoreTests.Rig()
        let cw = modeArrive(w)
        w.timers.advance(2); w.m.enterCardMode(cw)
        w.m.leaveCardMode()
        check(!w.m.keysActive(cw) && !modeKey(w, "2"), "the window resigned key or the app went back: card mode ends")
        // the monitor turns those into leaveCardMode
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Main/CardViews.swift")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let monitor = text.components(separatedBy: "struct CardKeyMonitor").dropFirst().first ?? ""
        for n in ["NSWindow.didResignKeyNotification", "NSWindow.willCloseNotification", "NSWindow.didMiniaturizeNotification",
                  "NSApplication.didResignActiveNotification", "NSWindow.didBecomeKeyNotification", "NSWindow.didDeminiaturizeNotification",
                  "NSApplication.didBecomeActiveNotification", "NSWindow.didUpdateNotification"] {
            check(monitor.contains(n), "the monitor observes \(n)")
        }
        check(monitor.contains("monitor.onLeave()") && monitor.contains("monitor.onReturn()") && monitor.contains("monitor.onFocus("),
              "it reports leaving, returning and where the typing is")
        let main = (try? String(contentsOf: url.deletingLastPathComponent().appendingPathComponent("MainSplitView.swift"), encoding: .utf8)) ?? ""
        check(main.contains("CardKeyMonitor(shell.cardKeyHandlers)"), "the chat column wires them to the model (ShellModel.cardKeyHandlers)")
        // card mode belongs to the card by its run and ask_id: an older result card of the session shows no digits
        let o = CardStoreTests.Rig()
        o.ask("a0"); o.resumed("a0")
        o.emit("task_done", ["status": "succeeded", "reason": "", "summary": "",
                             "result_card": ["kind": "result", "text": "改好了", "blocking": false, "free_text": false,
                                             "options": [["kind": "approve", "text": "好的"], ["kind": "undo", "text": "撤回"]]]])
        let old = CardModel(resultCard: o.state.task(CardStoreTests.rid)!.resultCard!, runId: CardStoreTests.rid)
        o.feed(["kind": "session.task", "session_id": CardStoreTests.sid, "seq": 3, "msg_id": "u2", "run_id": "r2", "raw": "再来", "by": "slash"])
        o.feed(["kind": "ask", "session_id": CardStoreTests.sid, "run_id": "r2", "seq": 1, "ask_id": "b1", "card": CardStoreTests.cardJSON("action")])
        let newer = CardModel(card: o.state.task("r2")!.cards[0].card, runId: "r2", askId: "b1")
        o.m.cardShown(newer); o.m.cardShown(old); o.m.fit(newer)
        o.timers.advance(2); o.m.enterCardMode(newer)
        check(o.m.keysActive(newer) && !o.m.keysActive(old), "card mode is the new card's, not the older result card's")
        check(CardLayout(old).controls.allSatisfy { !o.m.keyWorks(old, $0) }, "the older result card: no digits")
    }

    /// The label (KeyCap), the hint's "Key n" and the dispatcher read one predicate, keyWorks; a key that does nothing
    /// passes on (keyDown false). Checked against the dispatcher's real result, control by control, card by card, in
    /// each state: no card mode; card mode with the card not yet seen whole; card mode, seen.
    static func labelIsKeyTests() {
        for (name, json) in samples() where (json["kind"] as? String) != nil {
            let layout = CardLayout(model(json))
            for c in layout.controls where c.key != nil {
                for state in ["no mode", "mode, not seen", "mode, seen"] {
                    let r = CardStoreTests.Rig()
                    r.ask("a1", card: json)
                    let m = r.model("a1")!
                    r.m.cardShown(m)
                    if state == "mode, seen" { r.m.fit(m) }
                    r.timers.advance(2)
                    if state != "no mode" { _ = modeKey(r, "\u{1b}") }
                    let label = r.m.keyWorks(m, c)
                    let hintSays = CardLayout.hint(c, keys: r.m.keyWorks(m, c), lang: .en).contains("Key \(c.key!)")
                    let consumed = modeKey(r, String(c.key!))
                    r.timers.advance(CardStore.takeBack + 0.1)
                    let acted = r.phase("a1")?.pending != nil || r.wire.count("answer") > 0
                    check(label == acted && consumed == acted && hintSays == acted,
                          "\(name), \(state), key \(c.key!) (\(c.button.kind)): label \(label), hint \(hintSays), consumed \(consumed), acted \(acted)")
                }
            }
        }
        // the view's labels and hints read keyWorks (never keysActive alone)
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Main/CardViews.swift")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check(text.components(separatedBy: "KeyCap(n: k)").count - 1 == 2 && text.components(separatedBy: "if shell.keyWorks(card, c), let k = c.key { KeyCap(n: k) }").count - 1 == 2
              && text.contains("CardLayout.hint(c, keys: shell.keyWorks(card, c)") && !text.contains("keysActive"), "labels and hints: keyWorks")
        // a click by VoiceOver presses the same action as the mouse: the control's Button runs shell.click
        check(text.contains("let action = { _ = shell.click(b) }") && text.components(separatedBy: "Button(action: action)").count - 1 == 2,
              "VoiceOver's press and the mouse click are the same action")
        // a click on an option (the mouse, or VoiceOver's press: that action) is a move into the card
        let r = CardStoreTests.Rig()
        let m = modeArrive(r, kind: "ambiguity", seen: false)
        r.timers.advance(2)
        r.m.click(m.buttons.first { $0.role == .choice }!)
        check(r.m.keysActive(m), "a click on an option: card mode")
        let r2 = CardStoreTests.Rig()
        let m2 = modeArrive(r2, seen: false)
        r2.timers.advance(2)
        r2.m.click(m2.buttons.first { $0.role == .approve }!)      // (A2: an approve takes a click at once)
        check(r2.m.keysActive(m2) && r2.phase("a1")?.pending != nil, "a click on an approve: a pick held, and a move into the card")
    }

    /// Esc and Tab (⇧Tab too) enter card mode only with no ⌘⌃⌥, not repeated, no field being edited and no input-method
    /// composition (Esc there cancels the candidates); they are never consumed.
    static func escTabTests() {
        func entered(_ ch: String, editing: Bool = false, repeating: Bool = false, cmd: Bool = false, composing: Bool = false) -> Bool {
            let r = CardStoreTests.Rig()
            let c = modeArrive(r)
            r.timers.advance(5)
            let consumed = modeKey(r, ch, editing: editing, repeating: repeating, cmd: cmd, composing: composing)
            check(!consumed, "\(ch.unicodeScalars.first!.value): never consumed")
            return r.m.keysActive(c)
        }
        check(entered("\u{1b}") && entered("\t") && entered("\u{19}"), "Esc, Tab, ⇧Tab: card mode")
        check(!entered("\u{1b}", editing: true), "Esc in a field (an input method's cancel): no card mode")
        check(!entered("\u{1b}", composing: true) && !entered("\t", composing: true), "an input-method composition under way: no card mode")
        check(!entered("\u{1b}", cmd: true) && !entered("\t", cmd: true), "⌘Esc, ⌃Tab: no card mode")
        check(!entered("\u{1b}", repeating: true), "Esc auto-repeat: no card mode")
        check(!entered("\t", editing: true), "Tab in a field: no card mode")
        // (repro) Esc in the card's own field, then the user clicks the chat (no move), then 3: nothing goes
        let r = CardStoreTests.Rig()
        let c = modeArrive(r)
        r.timers.advance(5)
        _ = modeKey(r, "\u{1b}", editing: true)
        _ = modeKey(r, "3")
        check(!r.m.keysActive(c) && r.wire.count("answer") == 0, "Esc while editing, then 3: 先别做了 is not sent")
        // a digit during a composition never reaches the card (it is the input method's)
        let k = CardStoreTests.Rig()
        let ck = modeArrive(k)
        k.timers.advance(5); k.m.enterCardMode(ck)
        check(!modeKey(k, "1", composing: true), "a digit while an input method composes: not the card's")
    }

    // MARK: - every gate of the key path is keyWorks's (#111 review at ba3eec8, its repros adopted)

    /// One rig with every gate of a key open (card mode on the pinned card, on screen in the key window for 1 s, seen
    /// whole, cloud on, no field edited, no composition), then each gate flipped in turn: for every control of the
    /// card, the label (keyWorks), whether the key-down was consumed and whether anything was picked or sent agree. A
    /// gate the dispatcher had outside keyWorks would show here as label ≠ consumed or consumed ≠ acted.
    static func gateFlipTests() {
        let gates = ["none", "no card mode", "a newer card", "card hidden", "window left", "window back 0.1 s",
                     "field edited", "composing", "cloud off", "not seen whole", "answered", "sent", "expired", "a pick of it held"]
        for kind in ["action", "ambiguity", "plan", "missing"] {
            for gate in gates {
                let o = CardStoreTests.OffRig()
                o.feed { $0.ask("a1", kind) }
                var m = o.card("a1")
                o.m.cardShown(m)
                if gate != "not seen whole" { o.m.fit(m) }
                o.timers.advance(2)
                if gate != "no card mode" { _ = o.m.keyDown(characters: "\u{1b}", commandLike: false, mainWindowIsKey: true, editingText: false, isRepeat: false) }
                var editing = false, composing = false
                switch gate {
                case "a newer card":
                    o.feed { $0.void("a1", "steer"); $0.ask("a2", kind) }
                    m = o.card("a2"); o.m.cardShown(m); o.m.fit(m); o.timers.advance(2)
                case "card hidden": o.m.cardHidden(m)
                case "window left": o.m.windowLeft()
                case "window back 0.1 s":
                    o.m.windowLeft(); o.timers.advance(30); o.m.windowReturned(); o.timers.advance(0.1)
                    _ = o.m.keyDown(characters: "\u{1b}", commandLike: false, mainWindowIsKey: true, editingText: false, isRepeat: false)
                case "field edited": editing = true; o.m.focusChanged(editing: true, composing: false)
                case "composing": composing = true; editing = true; o.m.focusChanged(editing: true, composing: true)
                case "cloud off": o.set(cloud: false); o.m.refreshSettings(); o.runWork()
                case "answered": o.feed { $0.resumed("a1") }
                case "sent": o.m.click(m.buttons.first { $0.role == .cancel }!); o.runWork()
                case "expired": o.feed { $0.void("a1", CardState.timeout) }
                case "a pick of it held": o.m.click(m.buttons.first { $0.role != .cancel && !$0.role.needsWholeBody } ?? m.buttons[0])
                default: break
                }
                for c in CardLayout(m).controls where c.key != nil {
                    // each control on its own copy of the state: replay this gate's rig up to here
                    let label = o.m.keyWorks(m, c)
                    let answersBefore = o.answers(), heldBefore = o.m.cards.picks
                    let consumed = o.m.keyDown(characters: String(c.key!), commandLike: false, mainWindowIsKey: gate != "window left",
                                               editingText: editing, isRepeat: false, composing: composing)
                    o.runWork()
                    let acted = o.answers() > answersBefore || o.m.cards.picks != heldBefore
                    check(label == consumed && consumed == acted,
                          "\(kind), \(gate), key \(c.key!) (\(c.button.kind)): label \(label), consumed \(consumed), acted \(acted)")
                    if gate == "none" || gate == "a pick of it held" { break }      // (one act changes the state; the first control decides)
                }
            }
        }
        // (repro B1) leaving and coming back restarts the 1 s: an Esc 0.1 s after the return enters nothing
        let r = CardStoreTests.Rig()
        let c = modeArrive(r)
        r.timers.advance(2); r.m.enterCardMode(c)
        r.m.windowLeft(); r.timers.advance(30); r.m.windowReturned(); r.timers.advance(0.1)
        _ = modeKey(r, "\u{1b}")
        check(!r.m.keysActive(c), "back in the window 0.1 s: an Esc enters no card mode")
        r.timers.advance(CardKeys.cardOnScreen); _ = modeKey(r, "\u{1b}")
        check(r.m.keysActive(c), "after 1 s back: it does")
        // (repro B3) Tab enters card mode, then the focus is in a field: no labels, the digit is typed
        let t = CardStoreTests.Rig()
        let ct = modeArrive(t)
        t.timers.advance(2)
        _ = modeKey(t, "\t")
        t.m.focusChanged(editing: true, composing: false)
        let ctl = CardLayout(ct).controls.first { $0.key != nil }!
        check(!t.m.keyWorks(ct, ctl) && !modeKey(t, String(ctl.key!), editing: true), "after Tab, the focus in a field: no label, the key is typed")
        t.m.focusChanged(editing: false, composing: false)
        check(t.m.keyWorks(ct, ctl), "the focus out of the field again: the label is back (card mode kept)")
        // the dispatcher has no gate of its own: after keyWorks it picks
        let src = (try? String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Shared/Shell.swift"), encoding: .utf8)) ?? ""
        let body = src.components(separatedBy: "    func keyDown(").dropFirst().first?.components(separatedBy: "\n    }\n").first ?? ""
        check(body.contains("keyWorks(p, ctl)") && body.contains("return pick(") && !body.contains("click(") && !body.contains("bodySeen") && !body.contains("cloudAllows"),
              "keyDown: keyWorks, then pick — no other gate")
    }
}
