// The UI event log (Shared/UIEvents.swift, plan §5, invariant 9: no user content in it). Its types carry no String;
// one file opens the log; the cap and rotation; the switch and Clear; what the cards and undo of a session add; what
// an activation is put down to; and the recorded sample tools/ui_events_summary.py is checked against (build.sh).
import Foundation

enum UIEventsTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "ui-events: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("ui-events.ids"); idTests()
        DecisionTests.group("ui-events.types"); typeTests()
        DecisionTests.group("ui-events.oneEntry"); oneEntryTests()
        DecisionTests.group("ui-events.rotation"); rotationTests()
        DecisionTests.group("ui-events.cards"); cardTests()
        DecisionTests.group("ui-events.undo"); undoTests()
        DecisionTests.group("ui-events.activation"); activationTests()
        DecisionTests.group("ui-events.sample"); sampleTests()
    }

    static var appDir: URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath) }
    static func source(_ f: String) -> String { (try? String(contentsOf: appDir.appendingPathComponent(f), encoding: .utf8)) ?? "" }

    static func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ui-events-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func lines(_ u: URL) -> [String] {
        ((try? String(contentsOf: u, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    // MARK: ids: only the harness's random ones

    static func idTests() {
        let table: [(String, Bool)] = [
            ("run_041c0f37", true), ("ask_7852a538", true), ("run_0123456789abcdef0123456789abcdef", true),
            ("run_", false), ("run_abc", false), ("run_041C0F37", false), ("run_041c0f37x", false), ("task_041c0f37", false),
            ("周报.txt", false), ("hello world", false), ("run_ 041c", false), ("ask_7852a538\n", false), ("", false),
            ("run_0123456789abcdef0123456789abcdef0", false), ("Report.docx", false), ("ask__7852a538", false),
            // #123 review at 20e66ab: what rides on an allowed Character (each spells or hides text)
            ("run_041c0f37\u{301}", false), ("run_a\u{E0068}\u{E0069}\u{E007F}bcd", false), ("run_041c\u{200D}0f37", false),
            ("run_041c0f37\u{FE0F}", false), ("run_041c0f37\u{E0100}", false), ("run_０４１ｃ0f37", false), ("ask_7852a538\u{0}", false),
            ("rün_041c0f37", false), ("run_041c0f3７", false),
        ]
        for (s, ok) in table { check((UIEvent.ID(s) != nil) == ok, "id \(s.debugDescription): \(ok ? "kept" : "not an id")") }
    }

    // MARK: no String in what an event carries (the declaration, as compiled)

    static func typeTests() {
        let src = source("Shared/UIEvents.swift")
        guard let start = src.range(of: "enum UIEvent: Equatable {"), let end = src.range(of: "\n    var name: String {", range: start.upperBound..<src.endIndex)
        else { check(false, "UIEvent's declaration found"); return }
        let body = String(src[start.upperBound..<end.lowerBound])
        let code = body.split(separator: "\n").map { $0.components(separatedBy: "//").first ?? "" }
        // every case's associated values: enums of this file, Int, Bool, ID — nothing else
        let allowed: Set<String> = ["ID?", "ID", "CardKind", "Place", "Window", "Option", "Pick", "Ending", "Activation", "Input", "Undo", "Int", "Int?", "Bool"]
        var cases = 0, bad: [String] = []
        for l in code where l.trimmingCharacters(in: .whitespaces).hasPrefix("case ") && l.contains("(") && !l.contains("enum ") {
            guard let open = l.firstIndex(of: "("), let close = l.lastIndex(of: ")") else { continue }
            cases += 1
            for p in l[l.index(after: open)..<close].split(separator: ",") {
                let type = p.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if !allowed.contains(type) { bad.append(String(p)) }
            }
        }
        check(cases >= 8 && bad.isEmpty, "every event's values are enums, integers, booleans or ids (\(cases) cases): \(bad)")
        // the nested enums: raw values only (developer words), never an associated String
        let nested = code.filter { $0.contains("enum ") }
        check(nested.count >= 8 && nested.allSatisfy { $0.contains(": String {") && !$0.contains("(") }, "nested enums are plain String-raw cases: \(nested.count)")
        // ID: one stored String, set only by the failable init that checks it
        let joined = code.joined(separator: "\n")
        check(joined.components(separatedBy: ": String").count - 1 == nested.count + 2 && joined.components(separatedBy: "let raw: String").count == 2
              && joined.components(separatedBy: "init").count == 2 && joined.contains("init?(_ s: String)"), "ID: its one String, through its checking init only")
    }

    // MARK: one file opens the log

    static func oneEntryTests() {
        let build = source("build.sh").components(separatedBy: "\n")
        var files: Set<String> = []
        for marker in ["-o \"$MAIN/Contents/MacOS/DeskMind\"", "-o \"$HELPER/Contents/MacOS/DeskMindHands\"", "-o \"$OUT/decision-tests\""] {
            guard let at = build.firstIndex(where: { $0.contains(marker) }), at + 1 < build.count else { check(false, "build.sh: \(marker)"); continue }
            files.formUnion(build[at + 1].split(separator: " ").map(String.init).filter { $0.hasSuffix(".swift") })
        }
        check(files.contains("Shared/UIEvents.swift") && files.count > 40, "both apps and the tests build the log: \(files.count) files")
        var found: [String] = []
        for f in files.sorted() where f != "Shared/UIEvents.swift" && !f.hasPrefix("tests/") {
            let ls = source(f).components(separatedBy: "\n")
            for (i, l) in ls.enumerated() {
                let code = l.components(separatedBy: "//").first ?? ""
                if code.contains("ui-events") { found.append("\(f):\(i + 1) names a log file") }
                // the log is made at launch only: the app's init, the helper's main
                if code.contains("UIEventLog(") && !["Main/DeskMindApp.swift", "Helper/HandsHelper.swift"].contains(f) { found.append("\(f):\(i + 1) makes a log") }
            }
        }
        check(found.isEmpty, "only Shared/UIEvents.swift names the files; the log is made only at launch: \(found)")
        let tests = source("tests/DecisionTests.swift") + source("tests/ShellTests.swift") + source("tests/CardStoreTests.swift")
        check(!tests.contains("UIEvents.log ="), "no test sets the process's log (it stays nil: nothing goes to the real support directory)")
        check(UIEvents.log == nil, "in the tests the process has no log")
    }

    // MARK: cap, rotation, switch, Clear

    static func rotationTests() {
        // one line: {"by":"button","e":"activation","input":"none","t":1000} and a newline = 57 bytes; a cap of 120 holds two
        let probe = tempDir(), p = UIEventLog(dir: probe, file: UIEventLog.mainFile, maxBytes: 120)
        p.now = { 1000 }
        p.record(.activation(by: .button, input: .none)); p.flush()
        let one = (try? Data(contentsOf: p.url).count) ?? 0
        check(one == 57, "a line is 57 bytes: \(one)")
        // events written → lines in the file, lines in .1 (no .2 ever)
        let table: [(n: Int, main: Int, rotated: Int?)] = [(0, 0, nil), (1, 1, nil), (2, 2, nil), (3, 1, 2), (4, 2, 2), (5, 1, 2), (9, 1, 2)]
        for row in table {
            let d = tempDir(), log = UIEventLog(dir: d, file: UIEventLog.mainFile, maxBytes: 120)
            var t = 1000
            log.now = { t += 1; return t }
            for _ in 0..<row.n { log.record(.activation(by: .button, input: .none)) }
            log.flush()
            let main = lines(log.url), rot = FileManager.default.fileExists(atPath: log.rotated.path) ? lines(log.rotated) : nil
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.contains("jsonl") }
            check(main.count == row.main && rot?.count == row.rotated && files.count <= 2,
                  "\(row.n) events: \(main.count) in the file, \(rot?.count ?? -1) in .1 (files \(files.sorted()))")
            // the newest lines are kept, in order
            if row.n > 0 { check(main.last?.contains("\"t\":\(1000 + row.n)") == true, "\(row.n) events: the last is the newest") }
            let sizes = [log.url, log.rotated].compactMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int }
            check(sizes.allSatisfy { $0 <= 120 }, "\(row.n) events: no file over the cap: \(sizes)")
            check(log.failures == 0, "\(row.n) events: no failed write")
        }
        // the switch: off writes nothing, on again writes; both processes read the same file
        let d = tempDir(), log = UIEventLog(dir: d, file: UIEventLog.mainFile), helper = UIEventLog(dir: d, file: UIEventLog.helperFile)
        check(log.enabled && helper.enabled, "on by default")
        log.setEnabled(false)
        check(!log.enabled && !helper.enabled, "off: for the helper's log too")
        log.record(.activation(by: .none, input: .none)); helper.record(.activation(by: .none, input: .none)); log.flush(); helper.flush()
        check(lines(log.url).isEmpty && lines(helper.url).isEmpty, "off: nothing written")
        log.setEnabled(true)
        log.record(.activation(by: .none, input: .none)); helper.record(.activation(by: .none, input: .none)); log.flush(); helper.flush()
        check(lines(log.url).count == 1 && lines(helper.url).count == 1, "on again: written, each to its own file")
        // Clear: every log file, both processes', rotated ones too; the switch stays
        try? Data("x\n".utf8).write(to: log.rotated)
        log.clear()
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.contains("jsonl") }
        check(left.isEmpty && log.enabled, "Clear: no log file left (\(left)), still on")
        log.setEnabled(false); log.clear()
        check(!log.enabled, "Clear keeps the switch off")
        // #123 Codex review at 19236f0: Clear while the other process's queue is behind -- an event the helper recorded
        // before the Clear and writes after it is dropped, not written into the cleared file; one recorded after goes in
        do {
            let d = tempDir(), app = UIEventLog(dir: d, file: UIEventLog.mainFile), helper = UIEventLog(dir: d, file: UIEventLog.helperFile)
            helper.record(.liveCardOpen); helper.flush()
            check(lines(helper.url).count == 1, "the helper's line written")
            helper.hold()
            helper.record(.liveCardOpen)          // recorded now, written when the queue goes on
            app.clear()
            helper.release(); helper.flush()
            check(!FileManager.default.fileExists(atPath: helper.url.path), "recorded before Clear, written after: dropped (the file stays cleared)")
            helper.record(.liveCardOpen); helper.flush()
            check(lines(helper.url).count == 1 && app.generation() == 1, "recorded after Clear: written")
            app.record(.reopenAsked); app.flush()
            check(lines(app.url).count == 1, "the app's own after Clear: written")
        }
        // a write that fails is counted, never thrown or retried
        let blocked = tempDir().appendingPathComponent("not-a-dir")
        try? Data("x".utf8).write(to: blocked)
        let broken = UIEventLog(dir: blocked, file: UIEventLog.mainFile)
        broken.record(.activation(by: .none, input: .none)); broken.record(.activation(by: .none, input: .none)); broken.flush()
        check(broken.failures == 2, "failed writes counted: \(broken.failures)")
    }

    // MARK: a session's cards, through the 0.5 window's model

    static func cardTests() {
        typealias R = CardStoreTests
        func rig() -> (R.Rig, () -> [UIEvent]) {
            let r = R.Rig()
            var got: [UIEvent] = []
            r.m.uiRecord = { got.append($0) }
            r.m.uiWindow = { .behind }
            return (r, { defer { got = [] }; return got })
        }
        // shown → picked by a click 2 s later → taken back → picked by a key → held 3 s → sent → answered
        do {
            let (r, take) = rig()
            r.ask("a1", "plan")
            check(take() == [.cardShown(run: nil, ask: nil, kind: .plan, place: .chat, window: .behind, options: 2, details: false)], "a plan card: shown, in the chat, the window behind")
            r.timers.advance(2)
            r.click("a1", .approve)
            let p1 = take()
            check(p1 == [.cardPick(run: nil, ask: nil, kind: .plan, option: .approve, by: .click, place: .chat, ms: 2000)], "picked by a click, 2 s after it came: \(p1)")
            r.takeBack("a1")
            check(take() == [.cardTakeBack(run: nil, ask: nil, kind: .plan)], "taken back")
            r.takeBack("a1")
            check(take().isEmpty, "a second take-back with nothing held: nothing")
            r.timers.advance(1)
            r.click("a1", .approve)
            _ = take()
            r.timers.advance(3)
            check(take() == [.cardSent(run: nil, ask: nil, kind: .plan, heldMs: 3000)], "sent when the take-back ran out: held 3 s")
            r.resumed("a1")
            check(take() == [.cardEnded(run: nil, ask: nil, kind: .plan, why: .answered)], "answered")
        }
        // the way out: sent at once, held 0
        do {
            let (r, take) = rig()
            r.ask("a1", "ambiguity"); _ = take()
            r.click("a1", .cancel)
            let p2 = take()
            check(p2 == [.cardPick(run: nil, ask: nil, kind: .ambiguity, option: .cancel, by: .click, place: .chat, ms: 0),
                             .cardSent(run: nil, ask: nil, kind: .ambiguity, heldMs: 0)], "先别做了: picked and sent at once: \(p2)")
        }
        // the user's own words
        do {
            let (r, take) = rig()
            r.ask("a1", "missing"); _ = take()
            r.words("a1", "发给小李")
            let e = take()
            check(e.count == 1 && { if case .cardPick(_, _, .missing, _, .typed, .chat, _) = e[0] { return true }; return false }(), "typed on the card: \(e)")
            check(!"\(e)".contains("小李"), "the words are not in the event")
        }
        // the run's word on a card, each ending
        let endings: [(String, UIEvent.Ending)] = [("steer", .steer), ("stop", .stop), ("ended", .ended), (CardState.timeout, .expired)]
        for (why, want) in endings {
            let (r, take) = rig()
            r.ask("a1"); _ = take()
            r.void("a1", why)
            check(take() == [.cardEnded(run: nil, ask: nil, kind: .action, why: want)], "ask_void \(why): \(want)")
        }
        do {
            let (r, take) = rig()
            r.ask("a1"); r.ask("a2")
            let e = take()
            check(e.contains(.cardEnded(run: nil, ask: nil, kind: .action, why: .replaced)) && e.filter { if case .cardShown = $0 { return true }; return false }.count == 2,
                  "a newer card: the older replaced, both shown: \(e)")
            r.done()
            check(take() == [.cardEnded(run: nil, ask: nil, kind: .action, why: .ended)], "the task's end: the open card ended")
        }
        // expired, then 「现在回答」
        do {
            let (r, take) = rig()
            r.ask("a1"); r.void("a1", CardState.timeout); _ = take()
            r.answerNow("a1")
            check(take() == [.cardReask(run: nil, ask: nil, kind: .action)], "现在回答: reask")
        }
        // the result card: shown, answered (好的) / undone / its time ran out
        do {
            let (r, take) = rig()
            r.emit("task_done", ["status": "succeeded", "reason": "", "summary": "s", "undo_until": 2_000_000_000,
                                 "result_card": ["kind": "result", "text": "做了：新建 a.txt", "blocking": false, "free_text": false,
                                                 "options": [["kind": "approve", "text": "好的"], ["kind": "undo", "text": "撤回"]]]])
            check(take() == [.cardShown(run: nil, ask: nil, kind: .result, place: .chat, window: .behind, options: 2, details: false)], "the result card shown")
            r.feed(["kind": "session.task_closed", "session_id": R.sid, "seq": 3, "run_id": R.rid, "why": "linger"])
            check(take() == [.cardEnded(run: nil, ask: nil, kind: .result, why: .expired), .undo(run: nil, outcome: .expiredTime)],
                  "its time ran out: ended (expired), the undo it offered expired")
        }
        // the session's first state here (the app opened, its history replayed): an ended card is not put down again
        do {
            let r = R.Rig()
            r.ask("a1"); r.resumed("a1"); r.ask("a2")
            let e = UIEvents.changes(from: nil, to: r.state, window: .front)
            check(e == [.cardShown(run: nil, ask: nil, kind: .action, place: .chat, window: .front, options: 3, details: false)],
                  "a first state: the open card shown, the answered one not ended again: \(e)")
        }
        // #123 review at 20e66ab: history replayed is not put down again -- a relaunch with the stored log of a task that
        // was undone (task-undo), whether its lines come in the first state or into a session known already. The same
        // lines live (written after the model began watching): each transition once.
        for (replayed, label) in [(true, "replayed"), (false, "live")] {
            let t = ShellTests.Timers()
            t.now = replayed ? 1_900_000_000 : 1_700_000_000      // (the fixture's lines are at 1_792_655_287)
            let m = ShellModel(client: SessionClient(transport: R.Wire()), defaults: ShellTests.scratchDefaults(), config: { "openai:local|fake" },
                               lang: { .zhHans }, takeBackAfter: t.after, now: { t.now }, work: { $0() }, deliver: { $0() })
            var got: [UIEvent] = []
            m.uiRecord = { got.append($0) }
            ShellTests.feed(m, "task-undo")
            ShellTests.feed(m, "task-undo")      // (replayed twice, as a watch and a history read can)
            let names = got.map(\.name)
            if replayed {
                check(got.isEmpty, "\(label): nothing logged from the stored log: \(names)")
            } else {
                let undos = got.filter { if case .undo = $0 { return true }; return false }
                check(undos == [.undo(run: UIEvent.ID("run_9ace806b"), outcome: .undone)], "\(label): the undo once: \(undos)")
                check(names.filter { $0 == "card_shown" }.count == 1 && names.filter { $0 == "card_ended" }.count == 1, "\(label): the result card shown and ended once: \(names)")
            }
        }
        // #123 Codex review at 19236f0: a history read of a session long gone (no process: the client infers its exit)
        // logs nothing -- the inferred exit is as old as the history it was inferred from
        do {
            let stored = SessionTests.raw("task-card").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
                .filter { ($0["kind"] as? String) != "session.start" }
            let upToAsk = Array(stored.prefix { ($0["kind"] as? String) != "resumed" })
            let mock = SessionTests.MockTransport()
            mock.replies = [SessionClient.Op.history: ["ok": true, "open": false, "last_seq": upToAsk.compactMap { $0["seq"] as? Int }.max() ?? 0, "lines": upToAsk]]
            let t = ShellTests.Timers()
            t.now = 1_900_000_000
            let m = ShellModel(client: SessionClient(transport: mock), defaults: ShellTests.scratchDefaults(), config: { "openai:local|fake" },
                               lang: { .zhHans }, takeBackAfter: t.after, now: { t.now }, work: { $0() }, deliver: { $0() })
            var got: [String] = []
            m.uiRecord = { got.append($0.name) }
            let ok = m.client.history("ses_t")
            let sid = m.states.keys.first ?? ""
            check(ok && m.states[sid]?.exited != nil, "the history read, its exit inferred: \(ok) \(sid)")
            check(got.isEmpty, "an old session's history and its inferred exit: nothing logged: \(got)")
        }
        // a relaunch while a card is still open: not shown again (its show time is not reset); its live ending is
        do {
            let (r, take) = rig()
            r.emit("ask", ["ask_id": "a1", "card": R.cardJSON("action"), "t": 999_000.0])   // before the model began
            check(take().isEmpty, "a card asked before the app watched: not shown again")
            r.resumed("a1")
            check(take() == [.cardEnded(run: nil, ask: nil, kind: .action, why: .answered)], "its ending, live: logged")
        }
        // a pick on a card shown before the relaunch: its time since shown is not known -- left out, never 0
        do {
            let (r, take) = rig()
            r.emit("ask", ["ask_id": "a1", "card": R.cardJSON("action"), "t": 999_000.0]); _ = take()
            r.timers.advance(60)
            r.click("a1", .skipStep)
            let e = take()
            check(e == [.cardPick(run: nil, ask: nil, kind: .action, option: .skipStep, by: .click, place: .chat, ms: nil)], "no ms when the show is unknown: \(e)")
            check(e.first.map { $0.fields["ms"] == nil } == true, "and none in the line")
        }
        // #123 review probe: the whole stored history of each recorded session, in any order, after the app began
        // watching: nothing is logged
        do {
            struct RNG { var s: UInt64; mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 } }
            var logged: [String] = []
            for name in SessionTests.names {
                let ls = SessionTests.lines(name)
                for seed in 1...12 {
                    var r = RNG(s: UInt64(seed)), order = ls
                    for i in stride(from: order.count - 1, to: 0, by: -1) { order.swapAt(i, Int(r.next() % UInt64(i + 1))) }
                    let t = ShellTests.Timers()
                    t.now = 1_900_000_000
                    let m = ShellModel(client: SessionClient(transport: R.Wire()), defaults: ShellTests.scratchDefaults(), config: { "openai:local|fake" },
                                       lang: { .zhHans }, takeBackAfter: t.after, now: { t.now }, work: { $0() }, deliver: { $0() })
                    m.uiRecord = { logged.append("\(name) seed \(seed): \($0.name)") }
                    for l in order { m.client.feed(l) }
                }
            }
            check(logged.isEmpty, "all history, any order (\(SessionTests.names.count) sessions × 12): nothing logged: \(logged.prefix(3))")
        }
        // the real ids, when the run's are the harness's
        let s0 = SessionState()
        var s1 = SessionState()
        let card = CardEvent(kind: "action", text: "发送给 小王", options: [CardOption(kind: "approve", text: "可以")], freeText: false, blocking: true)
        var t = TaskState(runId: "run_041c0f37")
        t.cards = [CardState(askId: "ask_7852a538", card: card)]
        s1.tasks = [t]
        let e = UIEvents.changes(from: s0, to: s1, window: .front)
        check(e == [.cardShown(run: UIEvent.ID("run_041c0f37"), ask: UIEvent.ID("ask_7852a538"), kind: .action, place: .chat, window: .front, options: 1, details: false)],
              "the harness's ids are kept: \(e)")
        check(!"\(e.map(\.fields))".contains("小王"), "no word of the card in its fields")
    }

    // MARK: undo outcomes

    static func undoTests() {
        let open = ResultCardState.open(undo: true, until: 2_000_000_000), noUndo = ResultCardState.open(undo: false, until: nil)
        let table: [(ResultCardState, ResultCardState, UIEvent.Undo?)] = [
            (.undoing, .undone(undone: 3, total: 3, refused: nil), .undone),
            (.undoing, .undone(undone: 2, total: 3, refused: "a.txt changed"), .partial),
            (.undoing, .undone(undone: 3, total: 3, refused: "x"), .partial),
            (.undoing, .undoUnknown(nil), .unknown),
            (open, .undoExpired, .expiredLate),
            (open, .closed("linger"), .expiredTime), (open, .closed("deadline"), .expiredTime),
            (open, .closed("new_task"), .expiredNewTask), (open, .closed("session_exit"), .expiredHelperQuit),
            (open, .closed("session_end"), .expiredHelperQuit), (open, .closed("no_task"), .expiredOther),
            (noUndo, .closed("linger"), nil), (open, .answered, nil), (.none, open, nil), (open, .undoing, nil),
            // first seen already undone, or from no undo: nothing (#123 review)
            (.none, .undone(undone: 3, total: 3, refused: nil), nil), (.none, .undoUnknown(nil), nil), (.answered, .undoExpired, nil),
            (noUndo, .undoExpired, nil), (.undoing, .closed("linger"), nil),
        ]
        for (a, b, want) in table { check(UIEvents.undo(from: a, to: b) == want, "\(a) → \(b): \(String(describing: want))") }
    }

    // MARK: what an activation is put down to

    static func activationTests() {
        let table: [((UIEvent.Activation, Double)?, Double, UIEvent.Activation)] = [
            ((.button, 100), 100.2, .button), ((.reopen, 100), 100.9, .reopen), ((.button, 100), 102, .none),
            (nil, 100, .none), ((.button, 101), 100, .none),   // a funnel call after the activation does not explain it
        ]
        for (funnel, now, want) in table {
            check(UIEvents.activation(funnel: funnel.map { (by: $0.0, at: $0.1) }, now: now) == want, "funnel \(String(describing: funnel)), now \(now): \(want)")
        }
        let recorder = source("Main/IslandView.swift")
        check(!recorder.contains("secondsSinceLastEventType(.hidSystemState"), "no guess from the input's idle time (a task's posted events count there too)")
        check(recorder.contains("input: input(NSApp.currentEvent)"), "each activation with the event AppKit was handling then")
        check(recorder.contains("UIEvents.record(.reopenAsked)") && source("Helper/LiveCard.swift").contains("UIEvents.record(.liveCardOpen)"),
              "the reopen and the live card's open are put down by their owners")
        // the funnel tells the recorder before it activates
        let src = source("Shared/Activation.swift")
        if let r = src.range(of: "static func bringForward") {
            let body = src[r.upperBound...].prefix(200)
            let hook = body.range(of: "onBringForward?(gesture.source)"), act = body.range(of: "NSApp.activate()")
            check(hook != nil && act != nil && hook!.lowerBound < act!.lowerBound, "bringForward tells the log first")
        } else { check(false, "bringForward found") }
    }

    // MARK: the recorded sample tools/ui_events_summary.py is checked against

    /// Two tasks and the activations of an acceptance-like session, through the log's own writer, at fixed times.
    static func sample(into dir: URL) {
        let log = UIEventLog(dir: dir, file: UIEventLog.mainFile)
        var t = 1_793_000_000_000
        log.now = { t }
        func at(_ ms: Int, _ e: UIEvent) { t += ms; log.record(e) }
        let r1 = UIEvent.ID("run_041c0f37"), r2 = UIEvent.ID("run_6f6acb41")
        let a1 = UIEvent.ID("ask_7852a538"), a2 = UIEvent.ID("ask_963b12dc"), a3 = UIEvent.ID("ask_ac15291e"), a4 = UIEvent.ID("ask_f71bfc1d")
        at(0, .reopenAsked)
        at(40, .activation(by: .none, input: .none))
        at(1_200, .cardShown(run: r1, ask: a1, kind: .plan, place: .chat, window: .front, options: 2, details: true))
        at(4_100, .cardPick(run: r1, ask: a1, kind: .plan, option: .approve, by: .click, place: .chat, ms: 4_100))
        at(3_000, .cardSent(run: r1, ask: a1, kind: .plan, heldMs: 3_000))
        at(150, .cardEnded(run: r1, ask: a1, kind: .plan, why: .answered))
        at(9_000, .cardShown(run: r1, ask: a2, kind: .action, place: .chat, window: .behind, options: 3, details: true))
        at(12_500, .activation(by: .button, input: .none))
        at(800, .cardPick(run: r1, ask: a2, kind: .action, option: .approve, by: .digit, place: .chat, ms: 13_300))
        at(1_100, .cardTakeBack(run: r1, ask: a2, kind: .action))
        at(2_000, .cardPick(run: r1, ask: a2, kind: .action, option: .skipStep, by: .digit, place: .chat, ms: 16_400))
        at(3_000, .cardSent(run: r1, ask: a2, kind: .action, heldMs: 3_000))
        at(200, .cardEnded(run: r1, ask: a2, kind: .action, why: .answered))
        at(20_000, .cardShown(run: r1, ask: nil, kind: .result, place: .chat, window: .front, options: 2, details: false))
        at(6_000, .cardPick(run: r1, ask: nil, kind: .result, option: .undo, by: .click, place: .chat, ms: 6_000))
        at(0, .cardSent(run: r1, ask: nil, kind: .result, heldMs: 0))
        at(1_500, .undo(run: r1, outcome: .undone))
        at(30_000, .activation(by: .none, input: .none))
        at(8_000, .activation(by: .none, input: .keyDown))           // a key the user pressed
        at(4_000, .activation(by: .none, input: .appKitDefined))     // ⌘Tab: the system's
        at(9_000, .activation(by: .none, input: .mouseDownInWindow)) // a click on the window
        at(2_000, .cardShown(run: r2, ask: a3, kind: .action, place: .chat, window: .minimized, options: 3, details: true))
        at(5_000, .cardPick(run: r2, ask: a3, kind: .action, option: .approve, by: .click, place: .chat, ms: 5_000))   // held, then dropped: no answer
        at(595_000, .cardEnded(run: r2, ask: a3, kind: .action, why: .expired))
        at(45_000, .activation(by: .reopen, input: .none))
        at(3_000, .liveCardOpen)
        at(120, .activation(by: .none, input: .none))
        at(1_000, .cardReask(run: r2, ask: a3, kind: .action))
        // a card shown before a relaunch, answered after it: no card_shown, no ms -- left out of the times
        let a5 = UIEvent.ID("ask_0b1c2d3e")
        at(1_000, .cardPick(run: r2, ask: a5, kind: .missing, option: .choice, by: .click, place: .chat, ms: nil))
        at(3_000, .cardSent(run: r2, ask: a5, kind: .missing, heldMs: 3_000))
        at(4_000, .cardShown(run: r2, ask: a4, kind: .ambiguity, place: .chat, window: .front, options: 4, details: false))
        at(7_000, .cardPick(run: r2, ask: a4, kind: .ambiguity, option: .choice, by: .click, place: .chat, ms: 7_000))
        at(3_000, .cardSent(run: r2, ask: a4, kind: .ambiguity, heldMs: 3_000))
        at(100, .cardEnded(run: r2, ask: a4, kind: .ambiguity, why: .answered))
        at(25_000, .cardShown(run: r2, ask: nil, kind: .result, place: .chat, window: .behind, options: 2, details: false))
        at(600_000, .undo(run: r2, outcome: .expiredTime))
        log.flush()
    }

    static let sampleDir = "tests/fixtures/ui-events"

    static func sampleTests() {
        let d = tempDir()
        sample(into: d)
        let made = (try? Data(contentsOf: d.appendingPathComponent(UIEventLog.mainFile))) ?? Data()
        // (DESKMIND_WRITE_UI_SAMPLE=1 writes it anew, after a change to what an event says)
        let fixture = appDir.appendingPathComponent(sampleDir).appendingPathComponent(UIEventLog.mainFile)
        if ProcessInfo.processInfo.environment["DESKMIND_WRITE_UI_SAMPLE"] == "1" { try? made.write(to: fixture) }
        let stored = (try? Data(contentsOf: fixture)) ?? Data()
        check(!made.isEmpty && made == stored, "the sample is what the writer writes now (\(made.count) bytes; stored \(stored.count))")
        for l in lines(fixture) {
            let o = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any] ?? [:]
            let strings = o.filter { $0.value is String }.map(\.key).filter { !["e", "kind", "place", "window", "option", "by", "why", "outcome", "run_id", "ask_id", "input"].contains($0) }
            check(o["t"] is Int && o["e"] is String && strings.isEmpty, "a line: time, name, known fields only: \(l)")
        }
    }
}
