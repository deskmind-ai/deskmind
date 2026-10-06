// What DeskMind's window and island do when the run asks the user something, and when it is answered
// (Main/RunView.swift RunModel). The effects are decided here, without a screen, so tests/DecisionTests.swift checks
// every path: asked in the live view or in the window, answered in either, the next step.

import Foundation

enum AskFlow {
    struct Effects: Equatable {
        /// The island's "Needs you": turned on or off (nil: left as it is).
        var needsYou: Bool?
        /// DeskMind's window comes back; `activate`: as the key window.
        var comeBack = false
        var activate = false
        /// A system notification now.
        var notify = false
        /// A reminder notification if still unanswered after `reminderAfter` seconds (a question in the live view: the
        /// user may be away, or in a full-screen app).
        var remind = false
        /// Cancel a pending reminder.
        var cancelReminder = false
        /// What the island says (an L() key), if anything.
        var say: String?
    }

    static let reminderAfter: Double = 20

    /// The run asks. In the live view: answered there, so the window stays put and the island says where; a reminder
    /// follows if it waits. In the window: it comes back, but not as the key window while the user types elsewhere
    /// (their next keys, Return included, would land in the answer and send it); a notification when DeskMind is not
    /// in front or the user is typing.
    static func asked(inCard: Bool, approval: Bool, appActive: Bool, userTyping: Bool) -> Effects {
        if inCard { return Effects(needsYou: true, remind: true, say: "Needs you — answer in the card") }
        return Effects(needsYou: true, comeBack: true, activate: !userTyping, notify: !appActive || userTyping,
                       say: approval ? "Waiting for your approval in DeskMind" : "Waiting for your answer in DeskMind")
    }

    /// Answered in DeskMind's window.
    static let answeredInWindow = Effects(needsYou: false, cancelReminder: true, say: "Got your answer. Carrying on…")
    /// Answered in the live view (the helper's `answered` event).
    static let answeredInCard = Effects(needsYou: false, cancelReminder: true, say: "Answered — carrying on")
    /// "Neither — let me type it…" in the card: the window, active (the user asked for it). Still waiting, but in the
    /// window now: no reminder to answer in the card.
    static let typeInWindow = Effects(comeBack: true, activate: true, cancelReminder: true)

    /// Whether an answer's acknowledgement is for the question waiting: the same id (or no id to compare, from an
    /// older helper). A late acknowledgement must never clear a newer question.
    static func answerApplies(answered: Int?, waiting: Int?) -> Bool {
        guard let answered, let waiting else { return true }
        return answered == waiting
    }
    /// A step after a question: it was answered, or timed out.
    static let stepped = Effects(needsYou: false, cancelReminder: true)
}
