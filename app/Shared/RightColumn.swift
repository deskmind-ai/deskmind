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
//
// The changes as rows (U3 §3, P1Main): one per thing, each from an event field --
//
// | from                                   | icon    | name                          | what                        |
// |----------------------------------------|---------|-------------------------------|-----------------------------|
// | a step, consequence external, ok /     | send    | its window (step.object_label,| sent (· not read back)      |
// |   unverified                           |         |   else its words up to the    |                             |
// | a step, consequence modify_user, …     | window  |   first comma, else the ref)  | changed yours (· not read…) |
// | changes.created / modified / deleted   | file    | the path's last part          | created / changed / deleted |
// | changes.external                       | file    |   (its folder beside it)      | changed by another program  |
// | changes.unconfirmed                    | unknown |                               | can't tell if it happened   |
// | changes.created_windows                | window  | as given                      | opened window               |
//
// A thing acted on by several steps is one row per kind of change -- changed, sent -- with its last step's words. Sent first, then changed, created, deleted,
// another program's, unsure, opened windows. All undone: the files' rows struck (an undo takes back only those). The sent line: how many went out; none
// yet while a card waits on a step of the plan that sends.

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

    struct ChangeRow: Equatable {
        enum Icon: Equatable { case file, window, send, unknown }
        enum What: Equatable { case sent, changedYours, created, modified, deleted, byAnother, unsure, openedWindow }
        var icon: Icon
        var name: String
        /// Where it is (a file's folder) or what was done (a step's words); nil: none.
        var detail: String?
        var what: What
        var unverified = false
        var struck = false
    }
    enum SentLine: Equatable { case count(Int), noneYetWaiting }

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
    /// The changes as rows (the table above), and the line under them.
    var changeRows: [ChangeRow] = []
    var sentLine: SentLine? = nil

    static func == (a: RightColumn, b: RightColumn) -> Bool {
        a.status == b.status && a.progress?.step == b.progress?.step && a.progress?.seconds == b.progress?.seconds
            && a.youAreUsingIt == b.youAreUsingIt && a.screenLocked == b.screenLocked && a.plan == b.plan && a.changes == b.changes
            && a.computerUsedBy == b.computerUsedBy && a.changeRows == b.changeRows && a.sentLine == b.sentLine
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
        var col = RightColumn(status: status, progress: progress, youAreUsingIt: t.running && t.userActive,
                              screenLocked: t.ended && t.cause == .screenLocked, plan: plan, changes: changes,
                              computerUsedBy: s.runningTask == nil ? otherRunning : nil)
        col.changeRows = rows(ChangeInput.of(t))
        let sent = col.changeRows.filter { $0.what == .sent }.count
        let waitsToSend: Bool = { if case .waitingForYou = status { return plan.contains { $0.asksFirst && $0.mark != .done } }; return false }()
        col.sentLine = sent > 0 ? .count(sent) : waitsToSend ? .noneYetWaiting : nil
        return col
    }

    /// What the rows are made from: the steps and the changes, from the session's state (the right column) or from the
    /// run's own record (过程: RunDir) -- one input, one function, the same rows in both places.
    struct ChangeInput: Equatable {
        struct Step: Equatable {
            var id: String
            var object: String?
            var objectLabel: String?
            var human: String?
            var consequence: String?
            /// step_result's status (ok, unverified, refused, …; nil: none yet).
            var result: String?
        }
        var steps: [Step] = []
        var created: [String] = [], modified: [String] = [], deleted: [String] = [], external: [String] = [], unconfirmed: [String] = []
        var createdWindows: [String] = []
        var undone = false

        static func of(_ t: TaskState) -> ChangeInput {
            let c = t.changes
            return ChangeInput(steps: t.steps.map { Step(id: $0.id, object: $0.object, objectLabel: $0.objectLabel, human: $0.human,
                                                         consequence: $0.consequence, result: $0.result?.rawValue) },
                               created: c.created, modified: c.modified, deleted: c.deleted, external: c.external, unconfirmed: c.unconfirmed,
                               createdWindows: c.createdWindows ?? [], undone: ShellText.fullyUndone(t) != nil)
        }
        static func of(_ m: RunDir.Model) -> ChangeInput {
            let c = m.changes ?? RunDir.Changes()
            return ChangeInput(steps: m.steps.map { Step(id: $0.stepId, object: $0.object, objectLabel: $0.objectLabel, human: $0.human,
                                                         consequence: $0.consequence, result: $0.status) },
                               created: c.created, modified: c.modified, deleted: c.deleted, external: c.external, unconfirmed: c.unconfirmed,
                               createdWindows: c.createdWindows, undone: c.fullyUndone)
        }
    }

    /// The changes as rows (the second table).
    static func rows(_ input: ChangeInput) -> [ChangeRow] {
        var byObject: [String: ChangeRow] = [:], order: [String] = []
        let undone = input.undone
        for st in input.steps where st.result == "ok" || st.result == "unverified" {
            let what: ChangeRow.What
            switch st.consequence {
            case "external": what = .sent
            // (a window row only for a step on a window: a file step is its file's row -- changes.modified -- and never
            // also a window row, which an undo would leave unstruck beside the struck file: #131 Codex review)
            case "modify_user" where st.object?.hasPrefix("window:") == true: what = .changedYours
            default: continue
            }
            let key = (st.object ?? st.id) + "/" + (what == .sent ? "sent" : "changed")
            if byObject[key] == nil { order.append(key) }
            byObject[key] = ChangeRow(icon: what == .sent ? .send : .window, name: thingName(st), detail: st.human, what: what,
                                      unverified: st.result == "unverified")
        }
        let steps = order.compactMap { byObject[$0] }
        func files(_ paths: [String], _ what: ChangeRow.What, icon: ChangeRow.Icon = .file) -> [ChangeRow] {
            paths.map { p in
                let u = URL(fileURLWithPath: p)
                let folder = u.deletingLastPathComponent().lastPathComponent
                return ChangeRow(icon: icon, name: u.lastPathComponent, detail: folder.isEmpty || folder == "/" ? nil : folder, what: what)
            }
        }
        let c = input
        var all = steps.filter { $0.what == .sent } + steps.filter { $0.what == .changedYours }
        all += files(c.modified, .modified) + files(c.created, .created) + files(c.deleted, .deleted)
        all += files(c.external, .byAnother) + files(c.unconfirmed, .unsure, icon: .unknown)
        all += c.createdWindows.map { ChangeRow(icon: .window, name: $0, detail: nil, what: .openedWindow) }
        // (an undo takes back this Mac's files -- what the task created, changed, deleted -- never what went out, what
        // it did in an app's window, another program's change or an unsure one: those stay as they were)
        if undone { for i in all.indices where [.created, .modified, .deleted].contains(all[i].what) { all[i].struck = true } }
        return all
    }

    /// What a step acted on, by name: its window's (step.object_label, harness U3), else its words up to the first
    /// comma (they name the window: an older harness), else its object's ref.
    static func thingName(_ st: ChangeInput.Step) -> String {
        if let l = st.objectLabel, !l.isEmpty { return l }
        if let h = st.human, !h.isEmpty {
            let cut = h.split(whereSeparator: { $0 == "，" || $0 == "," }).first.map(String.init) ?? h
            return cut.trimmingCharacters(in: .whitespaces)
        }
        return st.object ?? ""
    }
}
