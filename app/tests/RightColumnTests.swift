// The right column (Shared/RightColumn.swift, A6): event sequences → what each block shows, and nothing the events
// did not say.
import Foundation

enum RightColumnTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "right-column: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("right-column.table"); tableTests()
    }

    static func ex(_ seq: Int, _ body: String) -> ProtocolLine { SessionTests.ex(seq, body) }
    static func se(_ seq: Int, _ body: String) -> ProtocolLine { SessionTests.se(seq, body) }
    static let start = ex(1, #""kind":"start","raw":"x""#)
    static func plan(_ seq: Int, _ purposes: [String], external: Int? = nil) -> ProtocolLine {
        let steps = purposes.enumerated().map { i, p in #"{"purpose":"\#(p)","consequence":"\#(i + 1 == external ? "external" : "create")"}"# }
        return ex(seq, #""kind":"plan","steps":[\#(steps.joined(separator: ","))]"#)
    }
    static func step(_ seq: Int, _ id: String, planStep: Int?) -> ProtocolLine {
        ex(seq, #""kind":"step","step_id":"\#(id)","text":"t"\#(planStep.map { #","plan_step":\#($0)"# } ?? "")"#)
    }
    static func result(_ seq: Int, _ id: String, _ status: String = "ok") -> ProtocolLine {
        ex(seq, #""kind":"step_result","step_id":"\#(id)","status":"\#(status)""#)
    }
    static func col(_ lines: [ProtocolLine], other: String? = nil, now: Double = 0) -> RightColumn {
        RightColumn.model(SessionReducer.reduce(SessionState(), [SessionTests.taskR1] + lines), otherRunning: other, now: now)
    }
    static func marks(_ c: RightColumn) -> [RightColumn.PlanRow.Mark] { c.plan.map(\.mark) }

    static func tableTests() {
        // the plan, then its steps: done by a step's own result, current the running one's, the rest still to do
        var c = col([start, plan(2, ["打开", "改标题", "发出去"], external: 3), step(3, "s1", planStep: 1), result(4, "s1"), step(5, "s2", planStep: 2)])
        check(marks(c) == [.done, .current, .todo] && c.plan.map(\.asksFirst) == [false, false, true], "plan then steps: \(marks(c))")
        check(c.progress?.step == 2, "the status line counts the steps: \(String(describing: c.progress?.step))")
        // a step refused: its plan step not done
        c = col([start, plan(2, ["打开", "改标题"]), step(3, "s1", planStep: 1), result(4, "s1", "refused"), step(5, "s2", planStep: 2), result(6, "s2")])
        check(marks(c) == [.todo, .done], "a refused step does not count: \(marks(c))")
        // steps with no plan, or no plan_step: no rows, nothing guessed
        c = col([start, step(2, "s1", planStep: nil), result(3, "s1")])
        check(c.plan.isEmpty && c.progress?.step == 1, "steps without a plan: no plan rows")
        c = col([start, plan(2, ["打开", "改标题"]), step(3, "s1", planStep: nil), result(4, "s1")])
        check(marks(c) == [.todo, .todo], "a step with no plan_step marks nothing: \(marks(c))")
        // a steer: the model gives a new plan -- it replaces the old one whole; the old plan's steps count for nothing
        c = col([start, plan(2, ["打开", "改标题"]), step(3, "s1", planStep: 1), result(4, "s1"), se(2, #""kind":"session.steer","run_id":"r1","text":"改成发给小李""#),
                 plan(5, ["打开邮件", "写给小李"])])
        check(c.plan.map(\.purpose) == ["打开邮件", "写给小李"] && marks(c) == [.todo, .todo], "a new plan: its rows, none done by the old plan's steps: \(marks(c))")
        c = col([start, plan(2, ["打开", "改标题"]), step(3, "s1", planStep: 1), result(4, "s1"), plan(5, ["打开邮件", "写给小李"]), step(6, "s2", planStep: 1)])
        check(marks(c) == [.current, .todo], "then its own first step: current")
        // changes while running, then the end's
        c = col([start, ex(2, #""kind":"changes","created":["a.txt"]"#)])
        check(c.changes.created == ["a.txt"] && !c.changes.undone, "running: the running total")
        let done = ex(3, #""kind":"task_done","status":"succeeded","reason":"","summary":"s","undo_until":2000000000,"changes":{"created":["a.txt","b.txt"],"unconfirmed":["c.csv"]},"result_card":{"kind":"result","text":"r","options":[{"kind":"approve","text":"好的"},{"kind":"undo","text":"撤回"}]}"#)
        c = col([start, ex(2, #""kind":"changes","created":["a.txt"]"#), done])
        check(c.changes.created == ["a.txt", "b.txt"] && c.changes.unconfirmed == ["c.csv"] && c.progress == nil, "ended: the end's changes, unconfirmed apart")
        // undone, all of it
        c = col([start, ex(2, #""kind":"changes","created":["a.txt"]"#), done, se(2, #""kind":"session.task_end","run_id":"r1","status":"succeeded","summary":"s","undo":"open""#),
                 se(3, #""kind":"session.task_respond","run_id":"r1","option":1,"undo":true"#),
                 se(4, #""kind":"session.task_undo","run_id":"r1","undone":2,"total":2"#)])
        check(c.changes.undone, "undone, all of it: said so")
        // unconfirmed only
        c = col([start, ex(2, #""kind":"task_done","status":"unconfirmed","reason":"","summary":"s","changes":{"unconfirmed":["x.csv"]}"#)])
        check(c.changes.created.isEmpty && c.changes.unconfirmed == ["x.csv"] && !c.changes.isEmpty, "only unconfirmed files: their own group, nothing the task's")
        // cut off, then its end recorded again after a reopen (补记): the later end's changes
        c = col([start, se(2, #""kind":"session.task_end","run_id":"r1","status":"stopped","summary":"","undo":"none","cause":"last_step_unknown""#),
                 se(3, #""kind":"session.exit","code":0,"last_seq":2"#),
                 se(4, #""kind":"session.task_end","run_id":"r1","status":"succeeded","summary":"补记","undo":"none","changes":{"created":["d.txt"]}"#)])
        check(c.changes.created == ["d.txt"], "recorded again after a reopen: the later end's changes: \(c.changes.created)")
        // this Mac: you're using it (paused), the screen locked
        c = col([start, step(2, "s1", planStep: nil), ex(3, #""kind":"waiting""#)])
        check(c.youAreUsingIt, "waiting for you to stop using the Mac")
        c = col([start, ex(2, #""kind":"task_done","status":"environment","reason":"timed out","summary":"","cause":"screen_locked""#)])
        check(c.screenLocked && !c.youAreUsingIt, "stopped: the screen is locked (from the cause, never the words)")
        c = col([start, ex(2, #""kind":"task_done","status":"environment","reason":"the screen is locked","summary":"""#)])
        check(!c.screenLocked, "the reason's words alone say nothing")
        // the computer used by another conversation, while this one has no task running
        c = col([start, ex(2, #""kind":"task_done","status":"succeeded","reason":"","summary":"s""#)], other: "整理周报")
        check(c.computerUsedBy == "整理周报", "another conversation's task runs: said, by its title")
        check(RightColumn.model(SessionReducer.reduce(SessionState(), [SessionTests.taskR1, start, ex(2, #""kind":"task_done","status":"succeeded","reason":"","summary":"s""#)]),
                                otherRunning: "整理周报", otherId: "ses_o", now: 0).computerUsedById == "ses_o", "and its id: a click switches to it")
        c = col([start], other: "整理周报")
        check(c.computerUsedBy == nil, "this one's own task runs: not")
        check(RightColumn.model(nil, otherRunning: "整理周报", now: 0).computerUsedBy == "整理周报", "nothing shown here: said too")
        // the elapsed time from the task's start
        let s = SessionReducer.reduce(SessionState(), [SessionTests.se(1, #""kind":"session.task","msg_id":"m","run_id":"r1","raw":"x","by":"slash","t":0"#)].map { $0 } + [start])
        let started = s.task("r1")?.startedAt ?? 0
        check(RightColumn.model(s, otherRunning: nil, now: started + 38).progress?.seconds == 38, "0:38 from the task's start")
    }
}
