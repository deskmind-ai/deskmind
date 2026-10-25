// The right column's two tabs, 「现在」 and 「过程」 (M5, plan §11.4), per conversation: which one shows and which run 过程
// shows, from what happened -- pure. Switching sends nothing anywhere (the pane is read only).
//
// | what happened                                  | tab                                                         |
// |------------------------------------------------|-------------------------------------------------------------|
// | 过程 shows a run                                 | it is being read: no task's start or end changes the tab    |
// |                                                |   or the run (#126 delta check)                             |
// | a task starts, 现在 shown                         | 现在; 过程's run the new task's                                |
// | task_done, 现在 shown                             | 过程 for that run -- unless the user picked 现在 in this      |
// |                                                |   conversation (until they pick 过程 again: §11.4)           |
// | the user picks 现在                               | 现在; no switch to 过程 from now                                |
// | the user picks 过程                               | 过程 on the run it would show (the latest, if none): kept     |
// | the user clicks a task message in the chat     | 过程 for that run                                            |
// | ui05.trace off                                 | no 过程 tab: always 现在 (ProcessTabs.shown)                   |

import Foundation

struct ProcessTabs: Equatable {
    enum Tab: Equatable { case now, process }
    enum Event: Equatable {
        case taskStarted(String)
        case taskDone(String)
        /// `latest`: the conversation's latest run, the one 过程 would show when it shows none yet.
        case picked(Tab, latest: String?)
        case clickedTask(String)
    }

    var tab: Tab = .now
    /// The run 过程 shows (nil: the conversation's latest).
    var run: String?
    /// The user picked 现在: no switch to 过程 until they pick 过程 (or open a task's).
    var stayNow = false

    mutating func apply(_ e: Event) {
        switch e {
        case .taskStarted(let r):
            guard tab == .now else { return }       // (过程 shows a run: being read)
            run = r
        case .taskDone(let r):
            guard tab == .now, !stayNow else { return }
            tab = .process; run = r
        case .picked(let t, let latest):
            tab = t
            stayNow = t == .now
            if t == .process, run == nil { run = latest }
        case .clickedTask(let r):
            tab = .process; run = r; stayNow = false
        }
    }

    /// The tab drawn: 过程 only while the switch is on.
    func shown(traceOn: Bool) -> Tab { traceOn ? tab : .now }

    /// The switch for the 过程 tab (a developer switch until 0.5.0).
    static let key = "ui05.trace"
}
