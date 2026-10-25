// The right column's two tabs, 「现在」 and 「过程」 (M5, plan §11.4), per conversation: which one shows and which run 过程
// shows, from what happened -- pure. Switching sends nothing anywhere (the pane is read only).
//
// | what happened                                  | tab                                                         |
// |------------------------------------------------|-------------------------------------------------------------|
// | a task starts                                  | the tab as it is; 过程's run the new task's -- unless the     |
// |                                                |   user opened another run's 过程 (not yanked off it)          |
// | task_done                                      | 过程 for that run -- unless the user picked 现在 in this      |
// |                                                |   conversation (until they pick 过程 again), or reads       |
// |                                                |   another run's 过程 they opened                              |
// | the user picks a tab                           | that tab (现在: no switch to 过程 from now; 过程: switches      |
// |                                                |   again)                                                    |
// | the user clicks a task message in the chat     | 过程 for that run (theirs: kept until they move)              |
// | ui05.trace off                                 | no 过程 tab: always 现在 (ProcessTabs.shown)                   |
//
// (§11.4's wording, #126 review: once the user picks 现在, no switch to 过程 in that conversation until they pick it.)

import Foundation

struct ProcessTabs: Equatable {
    enum Tab: Equatable { case now, process }
    enum Event: Equatable {
        case taskStarted(String)
        case taskDone(String)
        case picked(Tab)
        case clickedTask(String)
    }

    var tab: Tab = .now
    /// The run 过程 shows (nil: the conversation's latest).
    var run: String?
    /// The user opened `run`'s 过程 themselves (a task message): a task's start or end does not move it.
    var opened = false
    /// The user picked 现在: no switch to 过程 until they pick 过程 (or open a task's).
    var stayNow = false

    mutating func apply(_ e: Event) {
        switch e {
        case .taskStarted(let r):
            guard !opened else { return }
            run = r
        case .taskDone(let r):
            guard !stayNow, !(opened && run != r) else { return }
            tab = .process; run = r; opened = false
        case .picked(let t):
            tab = t
            stayNow = t == .now
            if t == .now { opened = false }
        case .clickedTask(let r):
            tab = .process; run = r; opened = true; stayNow = false
        }
    }

    /// The tab drawn: 过程 only while the switch is on.
    func shown(traceOn: Bool) -> Tab { traceOn ? tab : .now }

    /// The switch for the 过程 tab (a developer switch until 0.5.0).
    static let key = "ui05.trace"
}
