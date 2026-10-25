// M2 A3: the result card and undo (plan §3 invariant 4, as harness H2 landed): the undo button takes a click if and
// only if the session's result card is `open` with undo offered and its process alive; the undo's outcome is the
// harness's record (session.task_undo) only; 「撤回中」 never reads as expired or undone. And the task's message: who
// started it, where it is, how it ended, in both languages; the colours' contrast; the window's view files.
//
// - orderTests: modelled harness histories (host.ts's resultCard: none → open → undoing | closed; the process alive or
//   not; the undo's record) over {task_done, task_end, task_respond, result_card_closed, task_undo, task_closed,
//   session_exit}: every order of their lines, the app's enabled undo and shown outcome checked against the model
//   after all of them, and at every point the delivered lines are exactly a prefix of the history; a replay mid-way.
// - clickTests: one respond per click on undo; none after the state left open.
// - lineTests, contrastTests, viewTests.
// Run from DecisionTests.main (build.sh).

import Foundation

enum TaskResultTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "result: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("result.orderTests"); orderTests()
        DecisionTests.group("result.clickTests"); clickTests()
        DecisionTests.group("result.lineTests"); lineTests()
        DecisionTests.group("result.contrastTests"); contrastTests()
        DecisionTests.group("result.viewTests"); viewTests()
        DecisionTests.group("result.refusalMatchTests"); refusalMatchTests()
        DecisionTests.group("result.canSendTableTests"); canSendTableTests()
        RvA3Tests.run()
    }

    static let L = SessionTests.L
    static func ex(_ seq: Int, _ body: String) -> ProtocolLine { SessionTests.ex(seq, body) }
    static func se(_ seq: Int?, _ body: String) -> ProtocolLine { SessionTests.se(seq, body) }

    static let undoCard = #""result_card":{"kind":"result","text":"做了：新建 a.txt","options":[{"kind":"approve","text":"好的"},{"kind":"undo","text":"撤回"}]}"#
    static let noUndoCard = #""result_card":{"kind":"result","text":"做了：在 Mail 里点了「发送」。界面上的操作撤不回","options":[{"kind":"approve","text":"好的"}]}"#

    // MARK: - the modelled harness

    /// The harness's own record of the result card (host.ts `resultCard`, `undoRecorded`; the helper's process table),
    /// stepped by what each line says happened.
    struct Harness {
        enum Card: Equatable { case none, open, undoing, closed(String) }
        var card: Card = .none
        var offered = false
        var alive = true
        var record: String? = nil        // the undo's record: "undone n/m", "expired", "unknown"
        var responded = false

        /// The undo button, as invariant 4 says from this record.
        var undoEnabled: Bool { card == .open && offered && alive }
        /// What the app must say of the undo.
        var outcome: String {
            if let r = record { return r }
            if card == .undoing { return "undoing" }
            return "-"
        }
    }

    /// One history: the lines in the harness's order, each with what it does to the record.
    typealias Step = (line: ProtocolLine, apply: (inout Harness) -> Void)

    static let begin: [ProtocolLine] = [SessionTests.taskR1, ex(1, #""kind":"start","raw":"x""#)]

    static func histories() -> [(name: String, steps: [Step])] {
        let done = ex(2, #""kind":"task_done","undo_until":2000000000,"status":"succeeded","reason":"","summary":"s","# + undoCard)
        let endOpen = se(2, #""kind":"session.task_end","run_id":"r1","status":"succeeded","summary":"s","undo":"open","undo_until":2000000000"#)
        func respond(_ seq: Int, undo: Bool) -> ProtocolLine { se(seq, #""kind":"session.task_respond","run_id":"r1","option":\#(undo ? 1 : 0),"undo":\#(undo)"#) }
        func closed(_ seq: Int, _ why: String) -> ProtocolLine { se(seq, #""kind":"session.task_closed","run_id":"r1","why":"\#(why)""#) }
        func exit(_ last: Int) -> ProtocolLine { L(#"{"kind":"helper.session_exit","session_id":"s","code":0,"last_seq":\#(last)}"#) }
        let cardClosed = ex(3, #""kind":"result_card_closed","why":"expired""#)
        let offer: Step = (done, { $0.card = .open; $0.offered = true })
        let endO: Step = (endOpen, { _ in })
        return [
            // all seven: a respond that came just after the deadline (the session had not yet seen result_card_closed)
            ("respond at the deadline", [offer, endO,
                (respond(3, undo: true), { $0.card = .undoing; $0.responded = true }),
                (cardClosed, { _ in }),
                (se(4, #""kind":"session.task_undo","run_id":"r1","undone":0,"total":0,"refused":"expired""#), { $0.card = .closed("answered"); $0.record = "expired" }),
                (closed(5, "linger"), { _ in }),
                (exit(5), { $0.alive = false })]),
            ("undone", [offer, endO,
                (respond(3, undo: true), { $0.card = .undoing }),
                (se(4, #""kind":"session.task_undo","run_id":"r1","undone":1,"total":1,"refused":null"#), { $0.card = .closed("answered"); $0.record = "undone 1/1" }),
                (closed(5, "linger"), { _ in }), (exit(5), { $0.alive = false })]),
            ("undone in part", [offer, endO,
                (respond(3, undo: true), { $0.card = .undoing }),
                (se(4, #""kind":"session.task_undo","run_id":"r1","undone":1,"total":2,"refused":"the file changed""#), { $0.card = .closed("answered"); $0.record = "undone 1/2" }),
                (closed(5, "linger"), { _ in })]),
            ("its deadline", [offer, endO, (cardClosed, { $0.card = .closed("expired") }), (closed(3, "linger"), { _ in }), (exit(3), { $0.alive = false })]),
            ("a new task", [offer, endO, (closed(3, "new_task"), { $0.card = .closed("gone") })]),
            ("the helper went", [offer, endO, (exit(2), { $0.alive = false })]),
            ("the helper went while undoing", [offer, endO, (respond(3, undo: true), { $0.card = .undoing }), (exit(3), { $0.alive = false })]),
            ("OK", [offer, endO, (respond(3, undo: false), { $0.card = .closed("answered") }), (closed(4, "linger"), { _ in }), (exit(4), { $0.alive = false })]),
            ("no undo offered", [(ex(2, #""kind":"task_done","status":"succeeded","reason":"","summary":"s","# + noUndoCard), { $0.card = .open }),
                (se(2, #""kind":"session.task_end","run_id":"r1","status":"succeeded","summary":"s","undo":"none""#), { _ in }),
                (closed(3, "linger"), { $0.card = .closed("gone") })]),
        ]
    }

    /// The app's view of the undo, from its own state (what the button and the line read).
    static func app(_ s: SessionState) -> (enabled: Bool, outcome: String) {
        guard let t = s.task("r1") else { return (false, "-") }
        let enabled = SessionClient.refusal(.respond(runId: "r1", option: 1), in: s) == nil && t.resultCard?.options.count == 2
        let outcome: String
        switch t.resultCardState {
        case .undone(let n, let m, _): outcome = "undone \(n)/\(m)"
        case .undoExpired: outcome = "expired"
        case .undoUnknown: outcome = "unknown"
        case .undoing: outcome = "undoing"
        default: outcome = "-"
        }
        return (enabled, outcome)
    }

    static func permutations<T>(_ a: [T]) -> [[T]] {
        if a.count <= 1 { return [a] }
        var out: [[T]] = []
        for i in a.indices { var r = a; let x = r.remove(at: i); out += permutations(r).map { [x] + $0 } }
        return out
    }

    static func orderTests() {
        var orders = 0, wrong: [String] = []
        for (name, steps) in histories() {
            // the model after each prefix of the history
            var h = Harness(), models = [h]
            for st in steps { st.apply(&h); models.append(h) }
            let lines = steps.map(\.line)
            for (n, order) in permutations(Array(lines.indices)).enumerated() {
                var s = SessionReducer.reduce(SessionState(), begin)
                var delivered: Set<Int> = []
                for (k, i) in order.enumerated() {
                    s = SessionReducer.reduce(s, lines[i])
                    delivered.insert(i)
                    // a replay mid-way (the app restarted: everything delivered so far, twice)
                    if k == order.count / 2 && n % 7 == 0 {
                        let so = delivered.sorted().map { lines[$0] }
                        s = SessionReducer.reduce(SessionReducer.reduce(SessionState(), begin + so), begin + so)
                    }
                    // the delivered lines are exactly a prefix of the history: the app knows what the harness knew then
                    if delivered == Set(0..<delivered.count) {
                        let m = models[delivered.count], a = app(s)
                        if a.enabled != m.undoEnabled || a.outcome != m.outcome {
                            wrong.append("\(name), order \(order), after \(delivered.count): app \(a), harness \(m.undoEnabled) \(m.outcome)")
                        }
                    }
                }
                orders += 1
            }
        }
        check(wrong.isEmpty, "\(wrong.count) wrong in \(orders) orders: \(wrong.prefix(4))")
        check(orders >= 5040, "every order of the seven: \(orders) orders tried")
        // 「撤回中」 never reads as expired or undone, in any order of the undoing histories' lines up to the record
        for (name, steps) in histories() where name.contains("undoing") {
            for order in permutations(Array(steps.indices)) {
                let s = SessionReducer.reduce(SessionReducer.reduce(SessionState(), begin), order.map { steps[$0].line })
                if let t = s.task("r1"), t.resultCardState != .undoing { check(false, "\(name) \(order): \(t.resultCardState)") }
            }
        }
    }

    // MARK: - clicks

    static func clickTests() {
        func rig() -> CardStoreTests.Rig {
            let r = CardStoreTests.Rig()
            r.emit("task_done", ["status": "succeeded", "reason": "", "summary": "s", "undo_until": 2_000_000_000,
                                 "result_card": ["kind": "result", "text": "做了：新建 a.txt", "blocking": false, "free_text": false,
                                                 "options": [["kind": "approve", "text": "好的"], ["kind": "undo", "text": "撤回"]]]])
            r.feed(["kind": "session.task_end", "session_id": CardStoreTests.sid, "seq": 3, "run_id": CardStoreTests.rid, "status": "succeeded",
                    "summary": "s", "undo": "open", "undo_until": 2_000_000_000])
            return r
        }
        func undoButton(_ r: CardStoreTests.Rig) -> (CardModel, CardModel.Button) {
            let m = CardModel(resultCard: r.state.task(CardStoreTests.rid)!.resultCard!, runId: CardStoreTests.rid)
            return (m, m.buttons.first { $0.role == .undo }!)
        }
        let r = rig()
        let (m, undo) = undoButton(r)
        check(r.m.buttonEnabled(undo, card: m, in: r.state), "open, undo offered: the button takes a click")
        r.m.click(undo); r.m.click(undo)
        check(r.wire.count("respond") == 1 && r.wire.lines.last.map({ var l = $0.line; l["req_id"] = nil; return l }) as NSDictionary? == ["type": "respond", "run_id": CardStoreTests.rid, "option": 1] as NSDictionary,
              "two clicks: one respond with undo's index (\(r.wire.count("respond")))")
        check(!r.m.buttonEnabled(undo, card: m, in: r.state), "and the button is off while it is on its way")
        r.feed(["kind": "session.task_respond", "session_id": CardStoreTests.sid, "seq": 4, "run_id": CardStoreTests.rid, "option": 1, "undo": true])
        r.m.click(undo); r.m.click(m.buttons.first { $0.role == .approve }!)
        check(r.wire.count("respond") == 1 && !r.m.buttonEnabled(undo, card: m, in: r.state), "undoing: nothing more is sent")
        check(ShellText.resultLine(r.state.task(CardStoreTests.rid)!, now: 0, lang: .zhHans) == L10n.zh["Undoing…"], "the line: undoing")
        // closed before a click (a new task elsewhere, the process gone, the deadline): nothing is sent
        for (what, line) in [("new_task", ["kind": "session.task_closed", "session_id": CardStoreTests.sid, "seq": 4, "run_id": CardStoreTests.rid, "why": "new_task"] as [String: Any]),
                             ("exit", ["kind": "helper.session_exit", "session_id": CardStoreTests.sid, "code": 0, "last_seq": 3]),
                             ("deadline", ["kind": "result_card_closed", "session_id": CardStoreTests.sid, "run_id": CardStoreTests.rid, "seq": 3, "why": "expired"])] {
            let c = rig()
            c.feed(line)
            let (cm, cu) = undoButton(c)
            c.m.click(cu)
            check(c.wire.count("respond") == 0 && !c.m.buttonEnabled(cu, card: cm, in: c.state), "\(what): the undo button is off and sends nothing")
        }
        // the session refuses our own answer (its req_id echoed) undo_expired: a hint — the button off, 「撤回已过期」 —
        // until the history's closure, whose reason then wins; the state itself stays the history's (open)
        let x = rig()
        let (xm, xu) = undoButton(x)
        x.m.click(xu)
        let xreq = x.wire.lines.last?.line["req_id"] as? String
        check(xreq != nil, "the respond carries a req_id: \(String(describing: x.wire.lines.last?.line))")
        x.m.client.feed(["kind": "session.error", "session_id": CardStoreTests.sid, "code": "undo_expired", "control": "respond", "run_id": CardStoreTests.rid, "req_id": xreq ?? "", "text": "expired"])
        check(!x.m.buttonEnabled(xu, card: xm, in: x.state) && x.state.task(CardStoreTests.rid)?.resultCardState.isOpen == true
              && ShellText.resultLine(x.state.task(CardStoreTests.rid)!, hint: x.m.cards.hint(CardStoreTests.rid), now: 0, lang: .zhHans) == "撤回已过期",
              "our own undo_expired: the button off, 「撤回已过期」 as a hint (the history still open)")
        x.feed(["kind": "session.task_closed", "session_id": CardStoreTests.sid, "seq": 4, "run_id": CardStoreTests.rid, "why": "new_task"])
        check(x.state.task(CardStoreTests.rid)?.resultCardState == .closed("new_task") && x.m.cards.hint(CardStoreTests.rid) == nil
              && ShellText.resultLine(x.state.task(CardStoreTests.rid)!, hint: x.m.cards.hint(CardStoreTests.rid), now: 0, lang: .zhHans) == "撤回已过期：开始了新任务",
              "then the history's closure: its reason wins")
        // (#114 review) busy / bad_control: not stored, the card still answerable — the button back, a retry hint, a
        // second click sends again
        for code in ["busy", "bad_control"] {
            let b = rig()
            let (bm, bu) = undoButton(b)
            b.m.click(bu)
            let req = b.wire.lines.last?.line["req_id"] as? String ?? ""
            b.m.client.feed(["kind": "session.error", "session_id": CardStoreTests.sid, "code": code, "control": "respond", "run_id": CardStoreTests.rid, "req_id": req, "text": "the answer could not be stored: ENOSPC"])
            let t = b.state.task(CardStoreTests.rid)!
            check(t.resultCardState.undoEnabled && b.m.buttonEnabled(bu, card: bm, in: b.state), "\(code): still open, the undo button back (\(t.resultCardState))")
            check(ShellText.resultLine(t, hint: b.m.cards.hint(CardStoreTests.rid), now: 2_000_000_000 - 120, lang: .zhHans) == "回答没有送到任务，请再试一次", "\(code): a retry hint, not 「撤回已过期」")
            b.m.click(bu)
            check(b.wire.count("respond") == 2, "\(code): the retry is sent (\(b.wire.count("respond")))")
            // a restart: the refusal is not in the history — the card is open, as the history says
            b.restart()
            check(b.state.task(CardStoreTests.rid)?.resultCardState.undoEnabled == true, "\(code): after a restart, open from the history alone")
        }
        // the clock never decides: undo_until long past, the state open: the button takes a click
        let p = CardStoreTests.Rig()
        p.emit("task_done", ["status": "succeeded", "reason": "", "summary": "s", "undo_until": 1,
                             "result_card": ["kind": "result", "text": "t", "blocking": false, "free_text": false,
                                             "options": [["kind": "approve", "text": "好的"], ["kind": "undo", "text": "撤回"]]]])
        let (pm, pu) = undoButton(p)
        check(p.m.buttonEnabled(pu, card: pm, in: p.state), "undo_until in the past but the state open: enabled (the session decides, not the clock)")
    }

    // MARK: - the lines, both languages

    static func lineTests() {
        func task(_ lines: [ProtocolLine]) -> TaskState { SessionReducer.reduce(SessionReducer.reduce(SessionState(), begin), lines).task("r1")! }
        func end(_ status: String, _ extra: String = "") -> ProtocolLine {
            se(2, #""kind":"session.task_end","run_id":"r1","status":"\#(status)","summary":"","undo":"none"\#(extra)"#)
        }
        let closedEnd = se(3, #""kind":"session.task_closed","run_id":"r1","why":"session_end""#)
        let cases: [(String, TaskState, String)] = [
            ("succeeded", task([end("succeeded")]), L10n.zh["Done"] ?? ""),
            ("unconfirmed", task([end("unconfirmed")]), "做了，没能确认，请你看一下"),
            ("failed", task([end("failed")]), "没做完"),
            ("cancelled", task([end("cancelled")]), L10n.zh["Cancelled"] ?? ""),
            ("stopped", task([end("stopped")]), "已停下"),
            // (why it stopped is task_end's own; how its card closed later never changes it — #114 review)
            ("stopped, its card closed later by the session's end", task([end("stopped"), closedEnd]), "已停下"),
            ("stopped by the user", task([end("stopped", #","reason":"stopped by the app","cause":"user_stopped""#)]), "已停下"),
            ("locked", task([end("environment", #","cause":"screen_locked""#)]), L10n.zh["Stopped: the screen is locked"] ?? ""),
            ("last step unknown", task([end("stopped", #","cause":"last_step_unknown""#)]), L10n.zh["Stopped. The last step may or may not have happened"] ?? ""),
            ("interrupted", task([end("interrupted")]), "中断了"),
            ("cut off by its process's end", task([L(#"{"kind":"helper.session_exit","session_id":"s","code":0,"last_seq":1}"#)]), "中断了"),
        ]
        for (name, t, want) in cases {
            let zh = ShellText.task(t, lang: .zhHans), en = ShellText.task(t, lang: .en)
            check(zh == want && en != zh && !en.isEmpty, "\(name): «\(zh)» (want «\(want)»), en «\(en)»")
        }
        // who started it
        check(ShellText.origin(task([]), lang: .zhHans) == "你用 /cua 开始的", "by /cua")
        // the result lines: every state, in both languages
        let done = ex(2, #""kind":"task_done","undo_until":2000000000,"status":"succeeded","reason":"","summary":"s","# + undoCard)
        let endOpen = se(2, #""kind":"session.task_end","run_id":"r1","status":"succeeded","summary":"s","undo":"open","undo_until":2000000000"#)
        let respond = se(3, #""kind":"session.task_respond","run_id":"r1","option":1,"undo":true"#)
        let results: [(String, TaskState, String?)] = [
            ("open", task([done, endOpen]), "还能撤回 5 分钟"),
            ("undoing", task([done, endOpen, respond]), L10n.zh["Undoing…"]),
            ("undone", task([done, endOpen, respond, se(4, #""kind":"session.task_undo","run_id":"r1","undone":2,"total":2,"refused":null"#)]), "已撤回 2/2"),
            ("in part", task([done, endOpen, respond, se(4, #""kind":"session.task_undo","run_id":"r1","undone":1,"total":2,"refused":"文件变了""#)]), "撤回了 1/2 步后停下：文件变了"),
            ("too late", task([done, endOpen, respond, se(4, #""kind":"session.task_undo","run_id":"r1","undone":0,"total":0,"refused":"expired""#)]), "撤回已过期：时间到了"),
            ("cut off", task([done, endOpen, respond, se(4, #""kind":"session.task_undo","run_id":"r1","undone":0,"total":0,"refused":"the undo was cut off","unknown":true"#)]),
             (L10n.zh["The undo was cut off: some of it may not have been undone. Please check"] ?? "") + " · the undo was cut off"),
            ("a new task", task([done, endOpen, se(3, #""kind":"session.task_closed","run_id":"r1","why":"new_task""#)]), "撤回已过期：开始了新任务"),
            ("its time", task([done, endOpen, ex(3, #""kind":"result_card_closed","why":"expired""#)]), "撤回已过期：时间到了"),
            ("the helper gone", task([done, endOpen, se(3, #""kind":"session.task_closed","run_id":"r1","why":"session_end""#)]), "撤回已过期：DeskMind 的后台助手退出了，撤回时间提前结束"),
            ("the process gone", task([done, endOpen, L(#"{"kind":"helper.session_exit","session_id":"s","code":0,"last_seq":2}"#)]), "撤回已过期：DeskMind 的后台助手退出了，撤回时间提前结束"),
            ("no undo offered (its card says why)", task([ex(2, #""kind":"task_done","status":"succeeded","reason":"","summary":"s","# + noUndoCard), end("succeeded")]), nil),
            // (undo never offered: no expiry line, whatever closed it — #114 review)
            ("stopped as the helper went (no undo offered; the card says it will not wait)",
             task([ex(2, #""kind":"task_done","status":"stopped","reason":"","summary":"s","# + noUndoCard), end("stopped"), closedEnd]), nil),
            ("no undo offered, the session ended", task([ex(2, #""kind":"task_done","status":"succeeded","reason":"","summary":"s","# + noUndoCard), end("succeeded"), closedEnd]), nil),
            ("no undo offered, the process gone", task([ex(2, #""kind":"task_done","status":"succeeded","reason":"","summary":"s","# + noUndoCard), end("succeeded"),
                                                         L(#"{"kind":"helper.session_exit","session_id":"s","code":0,"last_seq":2}"#)]), nil),
        ]
        let now = 2_000_000_000.0 - 4.5 * 60
        for (name, t, want) in results {
            let zh = ShellText.resultLine(t, now: now, lang: .zhHans), en = ShellText.resultLine(t, now: now, lang: .en)
            check(zh == want && (want == nil) == (en == nil) && (want == nil || en != zh), "\(name): «\(zh ?? "nil")» (want «\(want ?? "nil")»), en «\(en ?? "nil")»")
        }
        // the countdown is display only: past its time with the state still open, no line, and the button still decides
        check(ShellText.resultLine(results[0].1, now: 2_000_000_100, lang: .zhHans) == nil, "past undo_until: no countdown line")
    }

    // MARK: - contrast, the views

    static func contrastTests() {
        for a in ShellPalette.Appearance.allCases {
            for (fg, bg) in ShellPalette.textOn(a) {
                let r = ShellPalette.contrast(fg, bg)
                check(r >= 4.5, String(format: "\(a): text #%06X on #%06X: %.2f:1 (at least 4.5)", fg, bg, r))
            }
        }
        check(ShellPalette.contrast(ShellPalette.sage.light, ShellPalette.paper.light) < 4.5, "(sage on paper is under 4.5: not a text colour)")
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let brand = (try? String(contentsOf: dir.appendingPathComponent("Main/Brand.swift"), encoding: .utf8)) ?? ""
        check(brand.contains("static let ink = Color(ShellPalette.ink)") && brand.contains("static let paper = Color(ShellPalette.paper)") && brand.contains("static let card = Color(ShellPalette.card)"),
              "Brand's ink, paper and card are the palette's tokens")
        let main = (try? String(contentsOf: dir.appendingPathComponent("Main/MainSplitView.swift"), encoding: .utf8)) ?? ""
        check(main.contains("static let secondary = Color(ShellPalette.secondary)") && main.contains("static let orangeText = Color(ShellPalette.orangeText)"),
              "the window's text colours are the palette's tokens")
        let views = ShellTests.windowViewFiles().map(\.code).joined(separator: "\n")
        check(!views.contains("foregroundStyle(Brand.sage)") && !views.contains("foregroundStyle(Brand.dot)") && !views.contains("foregroundStyle(Brand.mist)"),
              "no text in the window's views in a colour under 4.5:1")
    }

    static func viewTests() {
        let files = ShellTests.windowViewFiles()
        check(files.contains { $0.name == "Main/TaskViews.swift" }, "the task views are in the focus check's files: \(files.map(\.name))")
        let task = files.first { $0.name == "Main/TaskViews.swift" }?.code ?? ""
        check(task.contains("struct TaskRow") && task.contains("struct ResultSection") && !(files.first { $0.name == "Main/MainSplitView.swift" }?.code ?? "").contains("struct TaskRow"),
              "the task's views in their own file")
        // every button in the task views says what it is and does
        let buttons = task.components(separatedBy: "Button(").count - 1
        check(buttons >= 1 && task.components(separatedBy: ".accessibilityHint(").count - 1 >= buttons && task.components(separatedBy: ".accessibilityLabel(").count - 1 >= buttons,
              "VoiceOver: a label and a hint on each of the \(buttons) buttons")
        check(task.contains("ShellText.resultLine(task, hint: shell.cards.hint(task.runId), now: shell.now()") && task.contains("CardView(shell: shell, card: m"), "the result line and the card's buttons from the one state")
    }

    // MARK: - a refusal is the respond's it answers (#114 Codex review at 7553637)

    static func refusalMatchTests() {
        let sid = CardStoreTests.sid, rid = CardStoreTests.rid
        func resultCard(_ r: CardStoreTests.Rig, run: String, seq: Int, endSeq: Int) {
            r.feed(["kind": "task_done", "session_id": sid, "run_id": run, "seq": seq, "status": "succeeded", "reason": "", "summary": "s", "undo_until": 2_000_000_000,
                    "result_card": ["kind": "result", "text": "t", "blocking": false, "free_text": false,
                                    "options": [["kind": "approve", "text": "好的"], ["kind": "undo", "text": "撤回"]]]])
            r.feed(["kind": "session.task_end", "session_id": sid, "seq": endSeq, "run_id": run, "status": "succeeded", "summary": "s", "undo": "open", "undo_until": 2_000_000_000])
        }
        func undo(_ r: CardStoreTests.Rig, _ run: String) -> CardModel.Button {
            CardModel(resultCard: r.state.task(run)!.resultCard!, runId: run).buttons.first { $0.role == .undo }!
        }
        func refusal(_ code: String, run: String?, req: String?) -> [String: Any] {
            var e: [String: Any] = ["kind": "session.error", "session_id": sid, "code": code, "control": "respond", "text": "x"]
            if let run { e["run_id"] = run }
            if let req { e["req_id"] = req }
            return e
        }
        // (Codex 1) another client's no_task for an old task A comes while our undo of B is in flight: B is untouched;
        // then B's own busy (its req_id) gives B the retry hint, the button back
        let a = CardStoreTests.Rig()
        resultCard(a, run: rid, seq: 2, endSeq: 3)
        a.feed(["kind": "session.task_closed", "session_id": sid, "seq": 4, "run_id": rid, "why": "new_task"])
        a.feed(["kind": "session.task", "session_id": sid, "seq": 5, "msg_id": "u2", "run_id": "r2", "raw": "b", "by": "slash"])
        resultCard(a, run: "r2", seq: 1, endSeq: 6)
        a.m.click(undo(a, "r2"))
        let breq = a.wire.lines.last?.line["req_id"] as? String ?? ""
        a.m.client.feed(refusal("no_task", run: rid, req: "rq_another_client"))
        check(a.state.task("r2")?.resultCardState.undoEnabled == true && a.m.cards.hint("r2") == nil && a.m.cards.issued[breq] != nil,
              "another client's refusal: B untouched, B's own answer still awaited")
        a.m.client.feed(refusal("busy", run: "r2", req: breq))
        check(a.m.cards.hint("r2") == "busy" && a.m.buttonEnabled(undo(a, "r2"), card: CardModel(resultCard: a.state.task("r2")!.resultCard!, runId: "r2"), in: a.state),
              "B's own busy: its retry hint, the button back")
        a.m.click(undo(a, "r2"))
        check(a.wire.count("respond") == 2 && a.m.cards.hint("r2") == nil, "and the retry goes (the hint goes with it)")
        // (Codex 2) the registration races a task switch: the req_id is recorded before the line is written, on the
        // UI queue, so whatever order the lines come in, B's own refusal finds B
        let b = CardStoreTests.Rig()
        resultCard(b, run: rid, seq: 2, endSeq: 3)
        var seenWrite: [String: Any]? = nil
        b.wire.onLine = { l in if l["type"] as? String == "respond" { seenWrite = l } }
        b.m.click(undo(b, rid))
        let req = seenWrite?["req_id"] as? String ?? ""
        check(!req.isEmpty && b.m.cards.issued[req]?.runId == rid, "the req_id is recorded before the write: \(req)")
        b.m.client.feed(refusal("busy", run: rid, req: req))
        check(b.m.cards.hint(rid) == "busy" && b.m.cards.issued[req] == nil && b.m.cards.sent.isEmpty, "its own refusal, matched by req_id: the answer let go, retry possible")
        // a foreign refusal (no req_id of ours) never changes a card, whatever its run or code
        for (run, req2) in [(rid, "rq_x"), (nil, "rq_y"), (rid, nil)] as [(String?, String?)] {
            let f = CardStoreTests.Rig()
            resultCard(f, run: rid, seq: 2, endSeq: 3)
            f.m.click(undo(f, rid))
            for code in ["no_task", "undo_expired", "busy", "bad_control"] { f.m.client.feed(refusal(code, run: run, req: req2)) }
            check(f.m.cards.hint(rid) == nil && f.m.cards.sent.count == 1 && f.state.task(rid)?.resultCardState.isOpen == true,
                  "a foreign refusal (run \(run ?? "-"), req \(req2 ?? "-")): nothing changes")
        }
        // an old harness (no echo): refusals are ignored; the card waits for the history
        let o = CardStoreTests.Rig()
        resultCard(o, run: rid, seq: 2, endSeq: 3)
        o.m.click(undo(o, rid))
        o.m.client.feed(refusal("undo_expired", run: nil, req: nil))
        check(o.m.cards.hint(rid) == nil && o.state.task(rid)?.resultCardState.isOpen == true, "an old harness's refusal: ignored")
        o.feed(["kind": "session.task_closed", "session_id": sid, "seq": 4, "run_id": rid, "why": "linger"])
        check(o.state.task(rid)?.resultCardState == .closed("linger") && o.m.cards.sent.isEmpty, "the history closes it")
        // (#114 review at b307da0) our busy, then 70 foreign refusals, all before the window's flush: ours is matched as it
        // comes — never evicted from a buffer — the retry hint shows and the answer is let go
        let mr = CardStoreTests.MainRig()
        mr.m.client.feed(["kind": "task_done", "session_id": sid, "run_id": rid, "seq": 2, "status": "succeeded", "reason": "", "summary": "s", "undo_until": 2_000_000_000,
                          "result_card": ["kind": "result", "text": "t", "blocking": false, "free_text": false,
                                          "options": [["kind": "approve", "text": "好的"], ["kind": "undo", "text": "撤回"]]]])
        mr.m.client.feed(["kind": "session.task_end", "session_id": sid, "seq": 3, "run_id": rid, "status": "succeeded", "summary": "s", "undo": "open", "undo_until": 2_000_000_000])
        mr.pump()
        let mu = CardModel(resultCard: mr.m.states[sid]!.task(rid)!.resultCard!, runId: rid).buttons.first { $0.role == .undo }!
        mr.m.click(mu)
        let mreq = mr.wire.lines.last?.line["req_id"] as? String ?? ""
        mr.m.client.feed(refusal("busy", run: rid, req: mreq))
        for k in 0..<70 { mr.m.client.feed(refusal("no_task", run: "r_other", req: "rq_foreign_\(k)")) }
        mr.pump()
        check(mr.m.cards.hint(rid) == "busy" && mr.m.cards.sent.isEmpty && mr.m.cards.issued.isEmpty,
              "our busy before 70 foreign refusals, one flush: the retry hint, the answer let go (\(String(describing: mr.m.cards.hint(rid))), sent \(mr.m.cards.sent.count))")
        mr.m.click(mu)
        check(mr.wire.count("respond") == 2, "and the retry goes")
        // our answer taken (task_respond echoing the req_id): nothing more awaited
        let t = CardStoreTests.Rig()
        resultCard(t, run: rid, seq: 2, endSeq: 3)
        t.m.click(undo(t, rid))
        let treq = t.wire.lines.last?.line["req_id"] as? String ?? ""
        t.feed(["kind": "session.task_respond", "session_id": sid, "seq": 4, "run_id": rid, "option": 1, "undo": true, "req_id": treq])
        check(t.m.cards.issued.isEmpty && t.state.task(rid)?.resultCardState == .undoing, "task_respond with our req_id: answered, nothing awaited")
    }

    // MARK: - one predicate per option: enabled == a click sends == its key sends

    static func canSendTableTests() {
        typealias Rig = CardStoreTests.Rig
        let sid = CardStoreTests.sid, rid = CardStoreTests.rid
        func resultRig(undoUntil: Bool, extra: [[String: Any]]) -> Rig {
            let r = Rig()
            var done: [String: Any] = ["status": "succeeded", "reason": "", "summary": "s",
                                       "result_card": ["kind": "result", "text": "t", "blocking": false, "free_text": false,
                                                       "options": [["kind": "approve", "text": "好的"], ["kind": "undo", "text": "撤回"]]]]
            if undoUntil { done["undo_until"] = 2_000_000_000 }
            r.emit("task_done", done)
            if undoUntil { r.feed(["kind": "session.task_end", "session_id": sid, "seq": 3, "run_id": rid, "status": "succeeded", "summary": "s", "undo": "open", "undo_until": 2_000_000_000]) }
            for l in extra { if l["kind"] as? String == "session.error" { r.m.client.feed(l) } else { r.feed(l) } }
            return r
        }
        let respond: [String: Any] = ["kind": "session.task_respond", "session_id": sid, "seq": 4, "run_id": rid, "option": 1, "undo": true]
        let closed: [String: Any] = ["kind": "session.task_closed", "session_id": sid, "seq": 4, "run_id": rid, "why": "linger"]
        let results: [(String, () -> Rig)] = [
            ("open, undo offered", { resultRig(undoUntil: true, extra: []) }),
            ("an undo option, no undo_until (not offered)", { resultRig(undoUntil: false, extra: []) }),
            ("undoing", { resultRig(undoUntil: true, extra: [respond]) }),
            ("closed", { resultRig(undoUntil: true, extra: [closed]) }),
        ]
        var rows = 0
        for (name, make) in results {
            let probe = make()
            let card = CardModel(resultCard: probe.state.task(rid)!.resultCard!, runId: rid)
            for b in card.buttons {
                let r = make()
                r.m.fit(card)
                let enabled = r.m.canSend(b), shown = r.m.buttonEnabled(b, card: card, in: r.state)
                let n = r.wire.count("respond")
                r.m.click(b)
                let sent = r.wire.count("respond") > n
                check(enabled == shown && enabled == sent, "result card, \(name), \(b.kind): enabled \(enabled), shown \(shown), click sent \(sent)")
                rows += 1
            }
        }
        // ask cards in each phase: the button, a click and its key (card mode on) agree
        let phases = ["open", "pending", "sent", "answered", "voided", "expired"]
        for phase in phases {
            for i in 0..<3 {
                for byKey in [false, true] {
                    let r = Rig()
                    r.ask("a1")
                    let m = r.model("a1")!
                    r.m.cardShown(m); r.m.fit(m)
                    r.timers.advance(2); r.m.enterCardMode(m)
                    switch phase {
                    case "pending": r.click("a1", .skipStep)
                    case "sent": r.click("a1", .skipStep); r.timers.advance(CardStore.takeBack)
                    case "answered": r.resumed("a1")
                    case "voided": r.void("a1", "steer")
                    case "expired": r.void("a1", CardState.timeout)
                    default: break
                    }
                    let b = m.buttons[i]
                    let enabled = r.m.canSend(b), shown = r.m.buttonEnabled(b, card: m, in: r.state)
                    let ctl = CardLayout(m).controls.first { $0.index == i }!
                    let label = r.m.keyWorks(m, ctl)
                    let before = (r.wire.count("answer"), r.m.cards.picks)
                    let acted: Bool
                    if byKey { acted = r.m.keyDown(characters: String(ctl.key!), commandLike: false, mainWindowIsKey: true, editingText: false, isRepeat: false) }
                    else { acted = r.m.click(b) }
                    let changed = r.wire.count("answer") > before.0 || r.m.cards.picks != before.1
                    check(enabled == shown && enabled == acted && acted == changed && (!byKey || label == enabled),
                          "ask card, \(phase), \(b.kind) by \(byKey ? "key" : "click"): enabled \(enabled), shown \(shown), acted \(acted), changed \(changed), label \(label)")
                    rows += 1
                }
            }
        }
        check(rows == 8 + phases.count * 6, "every state × option: \(rows)")
    }
}
