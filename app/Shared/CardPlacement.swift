// Where a card is answered (plan §1.4, §4.1; invariant 4): one card can be answered where the user can see it, and
// nowhere that would take the focus. Worked out here from facts alone -- the card's phase (CardStore, the one state
// every view reads), its structure (CardModel.answerableInFloat), the main window's state and whether the float can
// be seen -- and drawn elsewhere (the chat now; the float, the island and the notification read the same answer).
// Nothing here talks to the harness: a card moving between the chat and the float sends nothing, and its take-back
// keeps counting (the countdown is the phase's, not the place's).
//
// | card \ main window | front                  | behind, visible / minimised / hidden / closed     | float not visible  |
// |--------------------|------------------------|---------------------------------------------------|--------------------|
// | waiting (open)     | chat (pinned), keys    | float: the card if it fits it, else its summary +  | island 「需要你」,  |
// |                    |                        |   「去主窗口回答」; island 「需要你」               |   a notification   |
// | held (take-back)   | chat: its line         | float: the same line, 「撤回」                     | as before          |
// | sent               | chat, greyed           | float, greyed                                     | as before          |
// | expired (action)   | chat: 「现在回答」       | float and island: 「已过期 · 现在回答」             | no new notification|
// | answered / voided  | one line in the chat   | float back to the picture; island back to work    | notification gone  |
//
// Held → sent is CardStore's timer, not this: it fires when the take-back runs out wherever the card is, the float hidden
// or the window minimised included (nothing here can answer it then, and nothing needs to).
//
// The main window's state counts once it has held for `FrontmostDebounce.settle` (250 ms) -- for the float appearing
// only: a flicker while windows change order does not bring it up. Whether the chat takes an answer is the window's
// state now (`frontNow`): the window in front, the chat answers and the float does not, at once; just left the front,
// the chat is still shown and answers nothing until the float has settled in (#124 review at 64547f9: never two places
// at once, and none the user cannot use). A card that arrives is placed at once by the state that counts then (the settle is for
// flips, never for a card's first placement). One blocking card waits at a time (M2): there is no second card here.

import Foundation

/// The main window as the user sees it.
enum MainWindowState: Equatable {
    /// DeskMind is the active app and the window is its key window: the chat takes the keyboard.
    case front
    /// On screen, behind another app's window.
    case behindVisible
    /// Minimised, hidden (with the app) or closed.
    case away
}

struct CardPlacement: Equatable {
    /// Where the card is shown.
    enum Shown: Equatable {
        case chat              // pinned above the composer (or in place in the chat when it is too tall)
        case floatCard         // the whole card, its options, in the float
        case floatSummary      // its title and 「去主窗口回答」 in the float
        case islandOnly        // the float cannot be seen: the island says so, and a notification
        case ended             // answered or voided: a line in the chat; the float and the island go back to the task
    }
    enum Island: Equatable { case none, needsYou, expired }
    /// What to do with the card's notification now (identifier: the card's own; A7 posts and withdraws): post it,
    /// post it once more (the reminder), leave the one shown, or take it away.
    enum Notification: Equatable { case post, remind, keep, withdrawn }
    /// Whether the float can be seen; `unknown` (another display, a full-screen app, the screen locked: the monitor
    /// cannot tell) counts as not seen -- the side that tells the user.
    enum Float: Equatable { case visible, hidden, unknown }

    var shown: Shown
    /// Whether the place it is shown takes an answer now (a pick, 撤回 on a held one, 现在回答 on an expired one).
    var takesAnswer: Bool
    var island: Island
    var notification: Notification

    /// A notification not answered in this long is shown once more (plan §1.4).
    static let remindAfter: Double = 20

    /// `phase`: the card's (CardStore.phase); `window`: the settled state; `frontNow`: the window is in front now
    /// (unsettled); `fitsFloat`: CardModel.answerableInFloat, and its words fit the float's
    /// width unclipped (a layout fact the float's view gives); `float`: whether the float is on a screen the user sees;
    /// `notified`: the card's notifications so far and the seconds since the last (nil: none) -- times are inputs, so
    /// the reminder is decided without a timer here.
    static func place(_ phase: CardPhase, fitsFloat: Bool, window: MainWindowState, frontNow: Bool, float: Float,
                      notified: (count: Int, since: Double)? = nil) -> CardPlacement {
        let floatVisible = float == .visible
        let waiting = phase.ending == nil
        let expiredOffer = phase.isExpiredOffer
        guard waiting || expiredOffer else {
            return CardPlacement(shown: .ended, takesAnswer: false, island: .none, notification: .withdrawn)
        }
        // what the card takes now: a pick or 撤回 while it waits (not once it is sent), 现在回答 while expired
        let acts: Bool
        switch phase {
        case .open, .pending: acts = true
        case .sent: acts = false
        case .expired(_, let now): acts = now == .offered
        default: acts = false
        }
        if frontNow {
            return CardPlacement(shown: .chat, takesAnswer: acts, island: .none, notification: .withdrawn)
        }
        if window == .front {
            // (left the front, not settled yet: the chat stays shown, answering nothing; the float comes after the settle)
            return CardPlacement(shown: .chat, takesAnswer: false, island: .none, notification: .withdrawn)
        }
        let island: Island = expiredOffer ? .expired : .needsYou
        guard floatVisible else {
            // (an expiry is never notified, and an older notification of the card goes)
            let note: Notification
            if expiredOffer { note = .withdrawn }
            else if let n = notified { note = n.count == 1 && n.since >= remindAfter ? .remind : .keep }
            else { note = .post }
            return CardPlacement(shown: .islandOnly, takesAnswer: false, island: island, notification: note)
        }
        // the float is in sight: no notification; the card itself when it fits there, else its title and the way in
        if fitsFloat || expiredOffer {
            return CardPlacement(shown: .floatCard, takesAnswer: acts, island: island, notification: .withdrawn)
        }
        return CardPlacement(shown: .floatSummary, takesAnswer: false, island: island, notification: .withdrawn)
    }
}

/// The main window's state as it settles: a change counts once it has held for `settle` seconds (plan §1.4: windows
/// change order in steps; a card must not hop between the chat and the float on the way).
struct FrontmostDebounce: Equatable {
    static let settle: Double = 0.25

    private(set) var stable: MainWindowState
    private var candidate: (state: MainWindowState, since: Double)?

    init(_ initial: MainWindowState) { stable = initial }

    /// The window was seen in `state` at `now`: the state that counts now.
    @discardableResult
    mutating func saw(_ state: MainWindowState, at now: Double) -> MainWindowState {
        if state == stable { candidate = nil; return stable }
        if let c = candidate, c.state == state {
            if now - c.since >= Self.settle { stable = state; candidate = nil }
        } else {
            candidate = (state, now)
        }
        return stable
    }

    /// The clock moved on with nothing new seen (a timer's tick): a candidate that held long enough counts.
    @discardableResult
    mutating func tick(_ now: Double) -> MainWindowState {
        if let c = candidate, now - c.since >= Self.settle { stable = c.state; candidate = nil }
        return stable
    }

    static func == (a: FrontmostDebounce, b: FrontmostDebounce) -> Bool {
        a.stable == b.stable && a.candidate?.state == b.candidate?.state && a.candidate?.since == b.candidate?.since
    }
}

/// Whether the float is up (A5, plan §1.4, §4.2): a pure function of the main window's settled state, the task and the
/// card -- never of what placement made of the float (whether it is seen is a measured fact of the panel, given to
/// CardPlacement.place; its output never comes back here, or the float would show and hide by itself).
///
/// | window \ task                 | none       | running, no card    | a card waits          |
/// |-------------------------------|------------|---------------------|-----------------------|
/// | front                         | hidden     | hidden              | hidden (the chat)     |
/// | behind / away                 | hidden     | up (collapsed if    | up, open -- even if   |
/// |                               |            |   the user said so) |   the user collapsed it|
enum FloatPolicy {
    enum Shown: Equatable { case hidden, collapsed, open }

    /// `poppedOut`: the user moved the live view into the float (⌘⇧P): up while the task runs, the window in front or not
    /// (its card is still answered where placement says: the chat, with the window in front).
    static func shown(window: MainWindowState, taskActive: Bool, cardWaiting: Bool, userCollapsed: Bool, poppedOut: Bool = false) -> Shown {
        if poppedOut && window == .front { return taskActive ? (userCollapsed ? .collapsed : .open) : .hidden }
        guard window != .front, taskActive || cardWaiting else { return .hidden }
        if cardWaiting { return .open }
        return userCollapsed ? .collapsed : .open
    }
}
