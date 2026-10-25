// The 0.5 window's right column (A6, handoff §1.2 「右栏」): what it shows is only what the events said -- the task's
// state, this Mac's part in it, the plan's steps, what it changed -- worked out here, pure, from the session's state;
// Main/MainSplitView.swift's AgentPanel draws it as it is. Nothing here guesses: a step counts towards a plan step only
// by its own plan_step, a file is the task's only when its changes say so (unconfirmed ones are a group of their own,
// not the task's, never undone), and a plan the model gave again (a steer, an answer) replaces the old one whole.
//
// | block                      | from                                                                             |
// |----------------------------|----------------------------------------------------------------------------------|
// | 小方 and the status line    | SessionStatus; 「第 n 步 · m:ss」: the steps, the task's start                     |
// | this Mac                   | waiting (you're using it: paused), the end's cause (the screen locked)          |
// | the plan's steps           | the latest plan; done: a step of it with a result ok / unverified; current: the  |
// |                            |   running step's; the rest still to do; 「发前问你」: consequence external          |
// | changes and outputs        | running: the running total (changes); ended: task_done's / task_end's; undone    |
// |                            |   all: said so; unconfirmed: their own group                                     |
// | 「电脑正被『X』使用」          | another conversation's task runs while this one is shown                         |

import Foundation

struct RightColumn: Equatable {
    struct PlanRow: Equatable {
        enum Mark: Equatable { case done, current, todo }
        var n: Int
        var purpose: String
        var mark: Mark
        /// The step sends something out: the task asks before it does (plan.steps[i].consequence == external).
        var asksFirst: Bool
    }
    struct ChangeList: Equatable {
        var created: [String] = []
        var modified: [String] = []
        var deleted: [String] = []
        var external: [String] = []
        /// Files that appeared or changed while the task worked in apps: not known to be its own (not undone).
        var unconfirmed: [String] = []
        /// All of it was undone (the result card's undo).
        var undone = false
        var isEmpty: Bool { created.isEmpty && modified.isEmpty && deleted.isEmpty && external.isEmpty && unconfirmed.isEmpty }
    }

    var status: SessionStatus
    /// 「第 n 步 · m:ss」 while a task runs (nil otherwise).
    var progress: (step: Int, seconds: Int)?
    /// The task waits for the user to stop using the Mac.
    var youAreUsingIt: Bool
    /// The task stopped because the screen is locked.
    var screenLocked: Bool
    var plan: [PlanRow]
    var changes: ChangeList
    /// Another conversation's task is using the computer (its title, and its id: a click switches to it), while this
    /// one is shown.
    var computerUsedBy: String?
    var computerUsedById: String? = nil

    static func == (a: RightColumn, b: RightColumn) -> Bool {
        a.status == b.status && a.progress?.step == b.progress?.step && a.progress?.seconds == b.progress?.seconds
            && a.youAreUsingIt == b.youAreUsingIt && a.screenLocked == b.screenLocked && a.plan == b.plan && a.changes == b.changes
            && a.computerUsedBy == b.computerUsedBy
    }

    /// The column for `s` (the shown session; nil: none), its latest task's, at `now` (seconds since 1970);
    /// `otherRunning`: the title of another conversation whose task runs now, if any.
    static func model(_ s: SessionState?, otherRunning: String?, otherId: String? = nil, now: Double) -> RightColumn {
        var c = modelOf(s, otherRunning: otherRunning, now: now)
        if c.computerUsedBy != nil { c.computerUsedById = otherId }
        return c
    }

    private static func modelOf(_ s: SessionState?, otherRunning: String?, now: Double) -> RightColumn {
        let status = s?.status ?? .idle
        guard let s, let t = s.tasks.last else {
            return RightColumn(status: status, progress: nil, youAreUsingIt: false, screenLocked: false, plan: [], changes: ChangeList(),
                               computerUsedBy: otherRunning)
        }
        let progress: (Int, Int)? = t.running ? (t.steps.count, max(0, Int(now - (t.startedAt ?? now)))) : nil
        // the latest plan's steps only: a step taken before it was the old plan's
        let mine = t.steps.dropFirst(min(t.planSince, t.steps.count))
        let current = t.running ? mine.last(where: { $0.result == nil })?.planStep : nil
        let plan = t.plan.enumerated().map { i, p -> PlanRow in
            let n = i + 1
            let done = mine.contains { $0.planStep == n && ($0.result == .ok || $0.result == .unverified) }
            let mark: PlanRow.Mark = current == n ? .current : done ? .done : .todo
            return PlanRow(n: n, purpose: p.purpose, mark: mark, asksFirst: p.consequence == "external")
        }
        let c = t.changes
        var changes = ChangeList(created: c.created, modified: c.modified, deleted: c.deleted, external: c.external, unconfirmed: c.unconfirmed)
        changes.undone = ShellText.fullyUndone(t) != nil
        return RightColumn(status: status, progress: progress, youAreUsingIt: t.running && t.userActive,
                           screenLocked: t.ended && t.cause == .screenLocked, plan: plan, changes: changes,
                           computerUsedBy: s.runningTask == nil ? otherRunning : nil)
    }
}
