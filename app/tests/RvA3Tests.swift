// The #114 review's repros at d670a3b (adopted): a busy refusal leaves the card answerable; a card that never offered
// undo never reads as expired; the user's own stop is not later shown as the helper's going. Each fails on d670a3b.
import Foundation

enum RvA3Tests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "rv-a3: " + what, file: file, line: line)
    }
    static func ex(_ seq: Int, _ body: String) -> ProtocolLine { SessionTests.ex(seq, body) }
    static func se(_ seq: Int?, _ body: String) -> ProtocolLine { SessionTests.se(seq, body) }
    static let begin = TaskResultTests.begin

    static func run() {
        DecisionTests.group("rv-a3.busyRefusal"); busyRefusal()
        DecisionTests.group("rv-a3.noUndoCardSessionEnd"); noUndoCardSessionEnd()
        DecisionTests.group("rv-a3.userStopThenSessionEnd"); userStopThenSessionEnd()
    }

    // Bug 1: host.ts respond() refuses `busy` when the answer could not be stored or the lock file errored, and says the
    // card can still be answered (protocol.md §respond: 「写不进去就不转，锁改回 lingering，回 busy（带原因），结果卡还能答」).
    // The app closes the card for good on ANY respond refusal and shows 「撤回已过期」.
    static func busyRefusal() {
        let r = CardStoreTests.Rig()
        r.emit("task_done", ["status": "succeeded", "reason": "", "summary": "s", "undo_until": 2_000_000_000,
                             "result_card": ["kind": "result", "text": "做了：新建 a.txt", "blocking": false, "free_text": false,
                                             "options": [["kind": "approve", "text": "好的"], ["kind": "undo", "text": "撤回"]]]])
        r.feed(["kind": "session.task_end", "session_id": CardStoreTests.sid, "seq": 3, "run_id": CardStoreTests.rid, "status": "succeeded",
                "summary": "s", "undo": "open", "undo_until": 2_000_000_000])
        let m = CardModel(resultCard: r.state.task(CardStoreTests.rid)!.resultCard!, runId: CardStoreTests.rid)
        let undo = m.buttons.first { $0.role == .undo }!
        r.m.click(undo)
        r.m.client.feed(["kind": "session.error", "session_id": CardStoreTests.sid, "code": "busy", "control": "respond",
                         "text": "the answer could not be stored: ENOSPC"])
        let t = r.state.task(CardStoreTests.rid)!
        check(t.resultCardState.undoEnabled, "busy (not stored, card still answerable in harness): state stays open with undo — got \(t.resultCardState)")
        let line = ShellText.resultLine(t, now: 2_000_000_000 - 120, lang: .zhHans)
        check(line != "撤回已过期", "busy must not read 「撤回已过期」 — got «\(line ?? "nil")»")
    }

    // Bug 2: an irreversible result card (no undo option, harness end undo:"none", the card text already says why) whose
    // linger is ended by session_end / the process's exit reads 「撤回已过期：DeskMind 的后台助手退出了…」 — undo was never offered.
    static func noUndoCardSessionEnd() {
        let s = SessionReducer.reduce(SessionReducer.reduce(SessionState(), begin), [
            ex(2, #""kind":"task_done","status":"succeeded","reason":"","summary":"s","# + TaskResultTests.noUndoCard),
            se(2, #""kind":"session.task_end","run_id":"r1","status":"succeeded","summary":"s","undo":"none""#),
            se(3, #""kind":"session.task_closed","run_id":"r1","why":"session_end""#)])
        let line = ShellText.resultLine(s.task("r1")!, now: 0, lang: .zhHans)
        check(line == nil, "no undo was ever offered: no 'undo expired' line — got «\(line ?? "nil")»")
        // same via the process going (no task_closed stored)
        let s2 = SessionReducer.reduce(SessionReducer.reduce(SessionState(), begin), [
            ex(2, #""kind":"task_done","status":"succeeded","reason":"","summary":"s","# + TaskResultTests.noUndoCard),
            se(2, #""kind":"session.task_end","run_id":"r1","status":"succeeded","summary":"s","undo":"none""#),
            SessionTests.L(#"{"kind":"helper.session_exit","session_id":"s","code":0,"last_seq":2}"#)])
        let line2 = ShellText.resultLine(s2.task("r1")!, now: 0, lang: .zhHans)
        check(line2 == nil, "process gone, no undo offered: no 'undo expired' line — got «\(line2 ?? "nil")»")
    }

    // Bug 3: the user pressed Stop (reason "stopped by the app"); the task lingers with its result card; the session then
    // ends (the user closes the conversation / quits) → task_closed session_end. The task's status line changes to
    // 「已停下：DeskMind 的后台助手退出了」, though the helper had nothing to do with the stop.
    static func userStopThenSessionEnd() {
        let s = SessionReducer.reduce(SessionReducer.reduce(SessionState(), begin), [
            ex(2, #""kind":"task_done","status":"stopped","reason":"stopped by the app","summary":"","undo_until":2000000000,"# + TaskResultTests.undoCard),
            se(2, #""kind":"session.task_end","run_id":"r1","status":"stopped","reason":"stopped by the app","summary":"","undo":"open","undo_until":2000000000"#),
            se(3, #""kind":"session.task_closed","run_id":"r1","why":"session_end""#)])
        let zh = ShellText.task(s.task("r1")!, lang: .zhHans)
        check(zh == "已停下", "stopped by the user, card closed later by session_end: «\(zh)» (want «已停下»)")
    }
}
