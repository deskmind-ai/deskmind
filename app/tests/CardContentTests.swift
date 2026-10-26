// U3: what a card and the right column say from the events (fable's ui-u3-spec.md; harness#80's fields): the answer
// the executor applied (resumed{ask_id, answer} live, session.task_answer on a replay) named on the card's line; the
// consent's new target_box and the step's object_label read leniently; the changes as rows.
// Run from DecisionTests.main (build.sh).

import Foundation

enum CardContentTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "card content: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("content.decode"); decodeTests()
        DecisionTests.group("content.answer"); answerTests()
        DecisionTests.group("content.summary"); summaryTests()
        DecisionTests.group("content.rows"); rowTests()
    }

    typealias S = SessionTests
    static let choice = #""card":{"kind":"ambiguity","text":"回哪一封？","options":[{"kind":"reading","text":"10 月 20 日","detail":"「下周的方案评审」"},{"kind":"reading","text":"10 月 18 日"},{"kind":"delegate","text":"由你决定"},{"kind":"cancel","text":"先别做了"}],"free_text":true,"blocking":true}"#

    static func reduce(_ lines: [ProtocolLine]) -> SessionState { SessionReducer.reduce(SessionState(), [S.taskR1, S.ex(1, #""kind":"start","raw":"x""#)] + lines) }

    /// The new fields, read leniently: a wrong shape is none, never a lost line (#124 review).
    static func decodeTests() {
        func resumed(_ body: String) -> ResumedEvent? { if case .resumed(let r) = S.ex(9, body).event { return r }; return nil }
        check(resumed(#""kind":"resumed","ask_id":"a","answer":{"option":1}"#)?.answer == .option(1), "resumed: an option's index")
        check(resumed(#""kind":"resumed","ask_id":"a","answer":{"text":"都行"}"#)?.answer == .text("都行"), "resumed: the user's words")
        check(resumed(#""kind":"resumed","ask_id":"a","answer":"x""#).map { $0.answer == nil && $0.askId == "a" } == true, "a malformed answer: none, the line kept")
        check(resumed(#""kind":"resumed","ask_id":"a""#)?.answer == nil, "no answer (an older harness): none")
        let ta = S.se(4, #""kind":"session.task_answer","run_id":"r1","ask_id":"a1","option":2"#)
        check(ta.event == .taskAnswer(SessionTaskAnswer(runId: "r1", askId: "a1", option: 2)) && ta.event.isSessionEvent, "session.task_answer: \(ta.event)")
        func consent(_ box: String) -> ConsentFacts? {
            let line = S.ex(3, #""kind":"ask","ask_id":"a","card":{"kind":"action","text":"t","options":[],"blocking":true,"consent":{"action":"click","action_text":"点","target":"发送","object":"window:x#4","object_label":"x","consequence":"external","outgoing":[],"site":null"# + box + "}}")
            if case .ask(let a) = line.event { return a.card.consent }
            return nil
        }
        check(consent(#","target_box":{"rect_norm":[0.1,0.2,0.3,0.04],"frame":[1,2,3,4]}"#)?.targetBox?.rectNorm == [0.1, 0.2, 0.3, 0.04], "consent.target_box read")
        let bad = consent(#","target_box":"nope""#)
        check(bad != nil && bad?.targetBox == nil && bad?.target == "发送", "a malformed target_box: none, the card and its consent kept")
        check(consent("")?.targetBox == nil, "no target_box (an older harness): none")
        if case .step(let st) = S.ex(5, #""kind":"step","text":"click","step_id":"s1","object_label":"Safari 窗口「Re: 评审」""#).event {
            check(st.objectLabel == "Safari 窗口「Re: 评审」", "step.object_label read")
        } else { check(false, "the step decodes") }
        if case .step(let st) = S.ex(5, #""kind":"step","text":"click","step_id":"s1","object_label":7"#).event { check(st.objectLabel.isEmpty, "a malformed object_label: none") }
        else { check(false, "a step with a malformed object_label still decodes") }
    }

    /// The applied answer: live from resumed, on a replay from session.task_answer -- whichever comes first, never
    /// overwritten; a voided card never takes one; an older log has none.
    static func answerTests() {
        let ask = S.ex(2, #""kind":"ask","ask_id":"a1","# + choice)
        func card(_ s: SessionState) -> CardState? { s.task("r1")?.cards.first { $0.askId == "a1" } }
        let live = reduce([ask, S.ex(3, #""kind":"resumed","ask_id":"a1","answer":{"option":0}"#)])
        check(card(live)?.answer == .option(0) && card(live)?.outcome == .answered, "live: the applied option")
        // the session's stored copy first (it is stored before the resumed is passed on), then the resumed
        let replay = reduce([ask, S.se(2, #""kind":"session.task_answer","run_id":"r1","ask_id":"a1","option":0"#),
                             S.ex(3, #""kind":"resumed","ask_id":"a1","answer":{"option":0}"#)])
        check(card(replay)?.answer == .option(0), "a replay: the stored answer, the same once")
        let onlyStored = reduce([ask, S.ex(3, #""kind":"resumed","ask_id":"a1""#), S.se(2, #""kind":"session.task_answer","run_id":"r1","ask_id":"a1","text":"随便""#)])
        check(card(onlyStored)?.answer == .text("随便"), "the stored copy fills an answer the resumed did not carry")
        let first = reduce([ask, S.ex(3, #""kind":"resumed","ask_id":"a1","answer":{"option":1}"#), S.se(2, #""kind":"session.task_answer","run_id":"r1","ask_id":"a1","option":0"#)])
        check(card(first)?.answer == .option(1), "never overwritten by a later record")
        let voided = reduce([ask, S.ex(3, #""kind":"resumed","ask_id":"a1","voided":"steer""#), S.se(2, #""kind":"session.task_answer","run_id":"r1","ask_id":"a1","option":0"#)])
        check(card(voided)?.answer == nil, "a voided card takes no answer")
        let old = reduce([ask, S.ex(3, #""kind":"resumed","ask_id":"a1""#)])
        check(card(old)?.answer == nil && card(old)?.outcome == .answered, "an older log: answered, nothing named")
        check(card(reduce([ask, S.se(2, #""kind":"session.task_answer","run_id":"r1","ask_id":"zz","option":0"#)]))?.answer == nil, "another card's record: not this one's")
    }

    /// The answered line, by kind × answer × outcome, in both languages.
    static func summaryTests() {
        func st(_ cardJSON: String, _ answer: AppliedAnswer?, at: Double? = nil) -> CardState {
            let line = S.ex(2, #""kind":"ask","ask_id":"a","# + cardJSON)
            guard case .ask(let a) = line.event else { fatalError() }
            return CardState(askId: "a", card: a.card, askedAt: nil, explicitAt: at, outcome: .answered, explicit: .answered, picked: nil, answer: answer)
        }
        let plan = #""card":{"kind":"plan","text":"我打算这样做","options":[{"kind":"approve","text":"可以，就这样做"},{"kind":"cancel","text":"先别做了"}],"blocking":true,"plan":{"steps":[{"purpose":"找到邮件","class":"read","objects":[],"sites":[]},{"purpose":"写回复","class":"modify_user","objects":[],"sites":[]},{"purpose":"发给许诺的邮件","class":"external","objects":[],"sites":[]}],"foreground":null}}"#
        let action = #""card":{"kind":"action","text":"要点发送吗","options":[{"kind":"approve","text":"可以"},{"kind":"skip_step","text":"这一步不要"},{"kind":"cancel","text":"先别做了"}],"blocking":true,"consent":{"action":"click","action_text":"点「发送」","target":"发送","object":"x","object_label":"x","consequence":"external","outgoing":[]}}"#
        let headline = #""card":{"kind":"ambiguity","text":"t","headline":"回哪一封","options":[{"kind":"reading","text":"10 月 20 日","detail":"「评审」"}],"blocking":true}"#
        let rows: [(String, CardState, CardPhase, ResolvedLang, String)] = [
            ("choice, an option", st(choice, .option(0)), .answered, .zhHans, "哪一个 · 10 月 20 日 · 「下周的方案评审」 · 你选的"),
            ("choice, delegate", st(choice, .option(2)), .answered, .zhHans, "哪一个 · 由你决定 · 你让它定"),
            ("choice, the user's words", st(choice, .text("都不是，是 10 月 15 日那封")), .answered, .zhHans, "哪一个 · 你说：都不是，是 10 月 15 日那封 · 已回答"),
            ("choice, an index out of range", st(choice, .option(9)), .answered, .zhHans, "哪一个 · 已回答"),
            ("headline is the kind", st(headline, .option(0)), .answered, .zhHans, "回哪一封 · 10 月 20 日 · 「评审」 · 你选的"),
            ("plan, agreed: its steps and the one that sends", st(plan, .option(0)), .answered, .zhHans, "计划 · 3 步 · 发给许诺的邮件，到时再确认 · 你已同意"),
            ("action, agreed", st(action, .option(0)), .answered, .zhHans, "点「发送」 · 可以 · 你已同意"),
            ("action, skipped", st(action, .option(1)), .answered, .zhHans, "点「发送」 · 这一步不要 · 没做这步"),
            ("action, stopped here", st(action, .option(2)), .answered, .zhHans, "点「发送」 · 先别做了 · 先别做了"),
            ("no record (an older log)", st(choice, nil), .answered, .zhHans, "哪一个 · 已回答"),
            ("voided by a steer", st(choice, nil), .voided("steer"), .zhHans, "哪一个 · 你改了要求"),
            ("voided by stop", st(choice, nil), .voided("stop"), .zhHans, "哪一个 · 已停止"),
            ("replaced", st(choice, nil), .voided("replaced"), .zhHans, "哪一个 · 换了一张"),
            ("expired", st(choice, nil), .expired(late: false, answerNow: .gone), .zhHans, "哪一个 · 已过期"),
            ("en: choice", st(choice, .option(0)), .answered, .en, "Which one · 10 月 20 日 · 「下周的方案评审」 · your pick"),
            ("en: plan", st(plan, .option(0)), .answered, .en, "Plan · 3 steps · 发给许诺的邮件, confirmed then · you agreed"),
        ]
        for (name, c, phase, lang, want) in rows {
            let got = ShellText.cardSummary(c, phase: phase, runId: "r1", lang: lang).line
            check(got == want, "\(name): «\(got)» (want «\(want)»)")
        }
        let timed = ShellText.cardSummary(st(choice, .option(0), at: 1_000), phase: .answered, runId: "r1", lang: .zhHans)
        check(timed.tail == "你选的 · " + ShellText.time(1_000), "with when it closed: \(timed.tail)")
    }

    /// 改动和产出 in the right column (the session's state) and in 过程 (the run's own record, RunDir): from the same
    /// run lines, the same rows -- one function over one input (#131 review: no second list that can drift).
    static func oneSourceTests(_ lines: [ProtocolLine]) {
        func runFolder(_ ls: [ProtocolLine]) -> RunDir.Model {
            // (the run's events.jsonl: its own lines, as the harness writes them -- no session ids)
            let events = ls.filter { $0.runId == "r1" }.map { l -> String in
                var o = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(l))) as? [String: Any] ?? [:]
                o.removeValue(forKey: "session_id"); o.removeValue(forKey: "run_id")
                return String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
            }
            return RunDir.model(RunDir.Files(events: ([#"{"seq":1,"kind":"start","raw":"x"}"#] + events).joined(separator: "\n") + "\n"))
        }
        let card = #""result_card":{"kind":"result","text":"做了","options":[{"kind":"approve","text":"好的"},{"kind":"undo","text":"撤回"}],"free_text":false,"blocking":false}"#
        let done = S.ex(12, #""kind":"task_done","status":"succeeded","reason":"","summary":"s","# + card + #","changes":{"created":["/Users/u/Desktop/新的.txt"],"modified":["/Users/u/Notes/笔记.txt"],"deleted":[],"external":["/Users/u/Notes/别人改的.txt"],"unconfirmed":[],"created_windows":["TextEdit 窗口"]}"#)
        let respond = S.se(2, #""kind":"session.task_respond","run_id":"r1","option":1,"undo":true"#)
        // (the undo's answer, as a run writes it -- result_response -- and as the session stores it -- session.task_undo)
        func undo(_ undone: Int, _ total: Int, refused: String?) -> [ProtocolLine] {
            let r = #","refused":"# + (refused.map { "\"" + $0 + "\"" } ?? "null")
            return [S.ex(13, #""kind":"result_response","picked":"undo","effect":"undone","undone":"# + "\(undone)" + #","total":"# + "\(total)" + r),
                    S.se(3, #""kind":"session.task_undo","run_id":"r1","undone":"# + "\(undone)" + #","total":"# + "\(total)" + r)]
        }
        // (a harness before M0: no step_id, the result on the step itself -- named and settled the same in both)
        let oldLog = [S.ex(2, #""kind":"step","text":"x","consequence":"modify_user","object":"window:o#1","human":"在 TextEdit 窗口「笔记」，写入「好」","status":"ok""#),
                      S.ex(3, #""kind":"step","text":"x","consequence":"external","object":"window:o#2","human":"点「发送」","status":"unverified""#),
                      S.ex(4, #""kind":"step","text":"x","consequence":"modify_user","object":"window:o#3","human":"被拒的","status":"refused""#)]
        let cases: [(String, [ProtocolLine], Bool?)] = [
            ("running", lines, nil), ("ended", lines + [done], nil),
            ("undone", lines + [done, respond] + undo(2, 2, refused: nil), true),
            ("undo refused part way", lines + [done, respond] + undo(1, 2, refused: "笔记.txt 被改过"), false),
            ("undo partial", lines + [done, respond] + undo(1, 2, refused: nil), false),
            ("an older harness's steps", oldLog, nil),
        ]
        for (name, ls, undone) in cases {
            let task = RightColumn.ChangeInput.of(reduce(ls).task("r1")!), run = RightColumn.ChangeInput.of(runFolder(ls))
            check(RightColumn.rows(task) == RightColumn.rows(run), "\(name): the right column's rows and 过程's are the same: \(RightColumn.rows(task)) vs \(RightColumn.rows(run))")
            check(!RightColumn.rows(run).isEmpty, "\(name): rows from the run's record")
            if let undone { check(task.undone == undone && run.undone == undone, "\(name): undone \(undone) in both (session \(task.undone), run \(run.undone))") }
        }
        check(RightColumn.rows(.of(runFolder(oldLog))).map(\.what) == [.sent, .changedYours] && RightColumn.rows(.of(runFolder(oldLog)))[0].unverified,
              "an older harness's steps: their results from the step itself (refused: no row)")
        // both views draw them through the one row view
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func read(_ f: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) ?? "" }
        let pane = read("Main/ProcessPane.swift"), panel = read("Main/MainSplitView.swift")
        check(pane.contains("RightColumn.rows(.of(m))") && pane.contains("ChangeRowView(row:") && panel.contains("ChangeRowView(row:")
              && !pane.contains("list(L(\"Created\"") && !pane.contains("list(L(\"Sent out\""),
              "过程 and the right column draw the same rows with the same view; 过程's own lists are gone")
    }

    /// The changes as rows: each from an event field; merged by thing; ordered; struck when undone; the sent line.
    static func rowTests() {
        typealias R = RightColumn.ChangeRow
        let ask = S.ex(5, #""kind":"ask","ask_id":"a9","# + #""card":{"kind":"action","text":"t","options":[{"kind":"approve","text":"ok"}],"blocking":true}"#)
        func step(_ seq: Int, _ id: String, _ consequence: String, object: String, human: String, label: String? = nil, result: String) -> [ProtocolLine] {
            [S.ex(seq, #""kind":"step","text":"x","step_id":""# + id + #"","consequence":""# + consequence + #"","object":""# + object + #"","human":""# + human + "\"" + (label.map { #","object_label":""# + $0 + "\"" } ?? "")),
             S.ex(seq + 1, #""kind":"step_result","step_id":""# + id + #"","status":""# + result + "\"")]
        }
        let changes = S.ex(11, #""kind":"changes","created":["/Users/u/Desktop/新的.txt"],"modified":["/Users/u/Notes/笔记.txt"],"deleted":["/tmp/a/旧.txt"],"external":["/Users/u/Notes/别人改的.txt"],"unconfirmed":["/Users/u/Downloads/x.zip"],"created_windows":["TextEdit 窗口"]"#)
        let lines = [S.ex(2, #""kind":"plan","steps":[{"purpose":"写","objects":[],"consequence":"modify_user"},{"purpose":"发","objects":[],"consequence":"external"}]"#)]
            + step(3, "s1", "modify_user", object: "window:mail#4", human: "在 Safari 窗口「Re: 评审」，写入「好」", result: "ok")
            + step(5, "s2", "modify_user", object: "window:mail#4", human: "在 Safari 窗口「Re: 评审」，再写一句", label: "Safari 窗口「Re: 评审」", result: "unverified")
            + step(7, "s3", "external", object: "window:mail#4b", human: "点「发送」", label: "Safari 窗口「回复」", result: "ok")
            + step(9, "s4", "modify_user", object: "window:x#9", human: "这一步被拒了", result: "refused")
            + [changes]
        let t = reduce(lines).task("r1")!
        let rows = RightColumn.rows(.of(t))
        check(rows.map(\.what) == [.sent, .changedYours, .modified, .created, .deleted, .byAnother, .unsure, .openedWindow],
              "one row per thing, sent first, then changed, created, deleted, another program's, unsure, opened windows: \(rows.map(\.what))")
        guard rows.count == 8 else { check(false, "rows: \(rows)"); return }
        check(rows[0] == R(icon: .send, name: "Safari 窗口「回复」", detail: "点「发送」", what: .sent), "a step that sent: its window by name, its words: \(rows[0])")
        check(rows[1].name == "Safari 窗口「Re: 评审」" && rows[1].detail == "在 Safari 窗口「Re: 评审」，再写一句" && rows[1].unverified,
              "two steps on one window: one row, the last step's words, not read back: \(rows[1])")
        check(rows[2] == R(icon: .file, name: "笔记.txt", detail: "Notes", what: .modified) && rows[5].name == "别人改的.txt" && rows[6].icon == .unknown,
              "files: the name, its folder; another program's; unsure")
        check(!rows.contains { $0.detail == "这一步被拒了" }, "a refused step changed nothing: no row")
        var noLabel = RightColumn.ChangeInput.Step(id: "s", object: "window:mail#4", objectLabel: nil, human: "在 Safari 窗口「Re: 评审」，写入「好」", consequence: nil, result: "ok")
        check(RightColumn.thingName(noLabel) == "在 Safari 窗口「Re: 评审」", "no object_label (an older harness): its words up to the first comma")
        noLabel.human = nil
        check(RightColumn.thingName(noLabel) == "window:mail#4", "no words either: its ref")
        var allUndone = RightColumn.ChangeInput.of(t); allUndone.undone = true
        let undoneRows = RightColumn.rows(allUndone)
        check(undoneRows.filter(\.struck).map(\.what) == [.modified, .created, .deleted],
              "all undone: the files' rows struck; what went out, a window's change, another program's, unsure: not: \(undoneRows.filter(\.struck).map(\.what))")
        let both = reduce(step(2, "s1", "modify_user", object: "window:m#1", human: "写", label: "邮件", result: "ok")
                          + step(4, "s2", "external", object: "window:m#1", human: "发", label: "邮件", result: "ok")).task("r1")!
        check(RightColumn.rows(.of(both)).map(\.what) == [.sent, .changedYours], "one window changed, then sent from: two rows, neither hidden")
        oneSourceTests(lines)
        let col = RightColumn.model(reduce(lines), otherRunning: nil, now: 0)
        check(col.sentLine == .count(1), "the sent line: how many went out: \(String(describing: col.sentLine))")
        let waiting = RightColumn.model(reduce([lines[0]] + step(3, "s1", "modify_user", object: "w", human: "写", result: "ok") + [ask]), otherRunning: nil, now: 0)
        check(waiting.sentLine == .noneYetWaiting, "nothing out yet, a card waits and the plan has a step that sends: 「还没有，等你确认」: \(String(describing: waiting.sentLine))")
        let quiet = RightColumn.model(reduce(step(2, "s1", "modify_user", object: "w", human: "写", result: "ok")), otherRunning: nil, now: 0)
        check(quiet.changeRows.count == 1 && quiet.sentLine == nil, "a change, nothing out, no card waiting: no sent line")
    }
}
