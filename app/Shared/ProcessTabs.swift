// The right column's two tabs, 「现在」 and 「过程」 (M5, plan §11.4), per conversation: which one shows and which run 过程
// shows, from what happened -- pure. Switching sends nothing anywhere (the pane is read only).
//
// | what happened                                         | tab                                                  |
// |-------------------------------------------------------|------------------------------------------------------|
// | a task starts                                         | 现在, and 过程 is that task's                          |
// | task_done for a run the pane is not on another run of | 过程 for it, once per run                              |
// | task_done while 过程 shows an older run                 | stays (never yanked from what the user reads)        |
// | the user picks a tab                                  | that tab; a run auto-switched once is never again    |
// | the user clicks a task message in the chat            | 过程 for that run                                     |
// | ui05.trace off                                        | no 过程 tab: always 现在 (ProcessTabs.shown)            |

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
    /// Runs whose end switched to 过程 already, or passed while the user read another run: not switched for again.
    var switched: Set<String> = []

    mutating func apply(_ e: Event) {
        switch e {
        case .taskStarted(let r):
            tab = .now; run = r
        case .taskDone(let r):
            guard switched.insert(r).inserted else { return }
            // (过程 on an older run: the user reads it -- not yanked)
            if tab == .process, let shown = run, shown != r { return }
            tab = .process; run = r
        case .picked(let t):
            tab = t
        case .clickedTask(let r):
            tab = .process; run = r
        }
    }

    /// The tab drawn: 过程 only while the switch is on.
    func shown(traceOn: Bool) -> Tab { traceOn ? tab : .now }

    /// The switch for the 过程 tab (a developer switch until 0.5.0).
    static let key = "ui05.trace"
}
