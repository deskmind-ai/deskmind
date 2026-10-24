// Every surface that shows a finished computer task offers the same result card (m2-plan invariant 4; the rc.15
// manual run: GoalRunView never rendered task_done.result_card). One state (TaskState.resultCardState), one predicate
// (ShellModel.canSend), one respond path (CardStore → SessionClient → the session): no surface has its own.
//
// | surface                         | the result card                                                         |
// |---------------------------------|--------------------------------------------------------------------------|
// | the chat (0.5 window)           | ResultSection (Main/TaskViews.swift)                                     |
// | GoalRunView, the harness engine | the same: a session task (ShellModel.startTask), TaskRow → ResultSection |
// | the island's "Show Details"     | opens the main window, where GoalRunView shows it (the link only)        |
// | the live card, the notification,| no card, by design                                                       |
// |   the recent runs (history)     |                                                                          |
// Run from DecisionTests.main (build.sh).

import Foundation

enum SurfaceTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "surface: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("surface.goalSessionTests"); goalSessionTests()
        DecisionTests.group("surface.tableTests"); tableTests()
    }

    /// GoalRunView's harness-engine goal through the model it uses: a new session, `cua` with the goal and its folder,
    /// the session selected; the task's result card read from the session's one state; undo sent once, by the chat's path.
    static func goalSessionTests() {
        let mock = SessionTests.MockTransport()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_goal", "last_seq": 0], SessionClient.Op.send: ["ok": true]]
        let m = ShellTests.model(mock)
        m.startTask("把下载文件夹按类型整理", scope: "/tmp/dl")
        let cua = mock.requests.compactMap { $0["line"] as? [String: Any] }.first { $0["type"] as? String == "cua" }
        check(cua?["text"] as? String == "把下载文件夹按类型整理" && cua?["scope"] as? String == "/tmp/dl", "a session task: cua with the goal and its folder: \(String(describing: cua))")
        check(m.selected == "ses_goal", "the new session is the one shown: \(String(describing: m.selected))")
        let sid = "ses_goal", run = "r_goal"
        for l: [String: Any] in [
            ["kind": "session.task", "session_id": sid, "seq": 1, "msg_id": "u1", "run_id": run, "raw": "把下载文件夹按类型整理", "by": "slash"],
            ["kind": "start", "session_id": sid, "run_id": run, "seq": 1, "raw": "把下载文件夹按类型整理"],
            ["kind": "task_done", "session_id": sid, "run_id": run, "seq": 2, "status": "succeeded", "reason": "", "summary": "s", "undo_until": 2_000_000_000,
             "result_card": ["kind": "result", "text": "做了：移动 3 个文件", "blocking": false, "free_text": false,
                             "options": [["kind": "approve", "text": "Fine"], ["kind": "undo", "text": "Undo"]]]],
            ["kind": "session.task_end", "session_id": sid, "seq": 2, "run_id": run, "status": "succeeded", "summary": "s", "undo": "open", "undo_until": 2_000_000_000],
        ] { m.client.feed(l) }
        guard let (s, t) = m.goalTask else { check(false, "the goal's task is there"); return }
        check(t.runId == run && t.resultCardState.undoEnabled, "its result card, from the session's state: \(t.resultCardState)")
        let card = CardModel(resultCard: t.resultCard!, runId: run)
        let undo = card.buttons.first { $0.role == .undo }!
        check(m.buttonEnabled(undo, card: card, in: s), "Undo takes a click (canSend)")
        m.click(undo); m.click(undo)
        let responds = mock.requests.compactMap { $0["line"] as? [String: Any] }.filter { $0["type"] as? String == "respond" }
        check(responds.count == 1 && responds.first?["option"] as? Int == 1 && responds.first?["run_id"] as? String == run, "one respond, by the chat's path: \(responds)")
        check(ShellText.resultLine(t, now: 2_000_000_000 - 9 * 60, lang: .en) == "Undo available for 9 more min", "and its line")
    }

    static func tableTests() {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func code(_ f: String) -> String {
            let t = (try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) ?? ""
            return t.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        }
        // the chat: the result section reads the one state and sends through the card view
        let chat = code("Main/TaskViews.swift")
        check(chat.contains("struct ResultSection") && chat.contains("CardView(shell: shell, card: m") && chat.contains("ShellText.resultLine(task"),
              "the chat: ResultSection")
        // GoalRunView: a harness-engine goal is a session task, shown with the chat's row (and so its result section);
        // no result card of its own
        let goal = code("Main/GoalRunView.swift")
        check(goal.contains("if r.harness {") && goal.contains("shell.startTask(r.goal, scope: r.folder)"), "GoalRunView: a harness goal runs as a session task")
        check(goal.contains("TaskRow(shell: shell, task: t, session: s)") && goal.contains("CardView(shell: shell, card: m, phase: p.phase"),
              "GoalRunView: the chat's TaskRow (with its ResultSection) and the pinned card")
        check(!goal.contains("result_card") && !goal.contains("resultCardState") && !goal.contains("func respond"), "GoalRunView: no result card of its own")
        let row = code("Main/TaskViews.swift").components(separatedBy: "struct TaskRow").dropFirst().first?.components(separatedBy: "struct ResultSection").first ?? ""
        check(row.contains("ResultSection(shell: shell, task: task, session: session)"), "TaskRow renders the result section")
        // the island's "Show Details": the main window (where GoalRunView is) — the link only
        let overlay = code("Main/RunOverlay.swift")
        let details = overlay.components(separatedBy: "func showDetails(").dropFirst().first?.components(separatedBy: "\n    }").first ?? ""
        check(details.contains("MainWindow.comeBack(gesture)"), "the island's Show Details opens the main window: \(details)")
        // no card by design: the live card, the notification, the recent runs
        for (f, what) in [("Helper/LiveCard.swift", "the live card"), ("Main/RunOverlay.swift", "the notification"), ("Main/History.swift", "the recent runs")] {
            let c = code(f)
            check(!c.contains("ResultSection") && !c.contains("resultCardState"), "\(what): no result card (by design)")
        }
    }
}
