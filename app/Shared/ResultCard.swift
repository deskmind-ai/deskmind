// The result card's state as the app shows it (M2 A3): one derivation from the session's record
// (TaskState.resultCardState), read by the task's message, the card's buttons and their enabling, VoiceOver and the
// dot alike. Invariant (plan §3.4, as harness H2 landed): the undo button takes a click if and only if the state is
// `open` with undo offered — which already means its session process is alive and its executor still lingers
// (session_exit, task_closed, result_card_closed and a refusal all close it). The clock never enables or disables it:
// `until` is for the countdown only.

import Foundation

enum ResultCardState: Equatable {
    case none
    /// It can be answered; `undo`: the harness offers undo; `until`: when it ends by itself (display only).
    case open(undo: Bool, until: Double?)
    /// The undo was asked for and taken (task_respond); its outcome has not been recorded.
    case undoing
    /// The harness's record of the undo (task_undo): `refused` is where it stopped (nil: all of it).
    case undone(undone: Int, total: Int, refused: String?)
    /// The undo was asked for too late: nothing was undone (task_undo refused "expired").
    case undoExpired
    /// The undo began and was cut off: how much of it was done is not known.
    case undoUnknown(String?)
    /// Another option was picked (「好的」).
    case answered
    /// Closed before an answer: linger (its time ran out), new_task, session_end / session_exit (its process went),
    /// deadline (result_card_closed), or the session's refusal code (undo_expired, no_task).
    case closed(String)

    var isOpen: Bool { if case .open = self { return true }; return false }
    /// The undo button takes a click.
    var undoEnabled: Bool { if case .open(true, _) = self { return true }; return false }
}
