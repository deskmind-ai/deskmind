// A card as the app shows it, built from the card's kind and its options' kinds — never from their words (handoff §1.4,
// owner 10-21): which buttons, their role and style, whether the card takes the user's own words, whether it can be
// answered in the float, and what a click sends: the option's index plus the card's ask_id (deskmind#102, #103).
//
// The result card (task_done.result_card) is a card too: its buttons send `respond` with the option's index.

import Foundation

/// What an answer sends, as a session control line (docs/protocol.md 「会话（第 1 版）」: answer / respond with run_id).
enum CardAnswer: Equatable {
    case option(runId: String, askId: String, option: Int)
    case text(runId: String, askId: String, text: String)
    case respond(runId: String, option: Int)

    var runId: String {
        switch self { case .option(let r, _, _), .text(let r, _, _), .respond(let r, _): return r }
    }
    /// The card this answers (nil for the result card, which has none).
    var askId: String? {
        switch self { case .option(_, let a, _), .text(_, let a, _): return a; case .respond: return nil }
    }

    var control: [String: Any] {
        switch self {
        case .option(let r, let a, let i): return ["type": "answer", "run_id": r, "ask_id": a, "option": i]
        case .text(let r, let a, let w): return ["type": "answer", "run_id": r, "ask_id": a, "text": w]
        case .respond(let r, let i): return ["type": "respond", "run_id": r, "option": i]
        }
    }
}

struct CardModel: Equatable {
    enum Kind: Equatable {
        case plan, action, ambiguity, missing, resultCheck, cannot, result
        case other(String)
        init(_ s: String) {
            switch s {
            case "plan": self = .plan
            case "action": self = .action
            case "ambiguity": self = .ambiguity
            case "missing": self = .missing
            case "result_check": self = .resultCheck
            case "cannot": self = .cannot
            case "result": self = .result
            default: self = .other(s)
            }
        }
    }

    /// What a button means, from its option's kind.
    enum Role: Equatable {
        case approve                // the main yes
        case choice                 // one of several readings / values / proposals: a pick list
        case skipStep               // not this step, go on with the rest
        case delegate               // "you decide"
        case cancel                 // the way out (an answer to this card: the task ends cancelled; not a stop)
        case undo                   // take back what the task did
        case other                  // a kind this app does not know (or `other`, `never_ask_this`): shown and sent as clicked
    }

    enum Style: Equatable { case prominent, radio, bordered, destructive }

    struct Button: Equatable {
        /// The card it belongs to: its run, and its ask_id (nil on the result card). A click answers that card and no
        /// other, whatever the words: two cards may well offer the same 「可以／先别做了」.
        var runId: String
        var askId: String?
        /// The option's place in the card's options: what the click sends.
        var index: Int
        var kind: String
        var text: String
        var role: Role
        var style: Style
    }

    var runId: String
    /// nil: the result card (answered with respond, no ask_id).
    var askId: String?
    var kind: Kind
    var text: String
    var buttons: [Button]
    /// The card takes the user's own words, in its own field (never the composer).
    var allowsFreeText: Bool
    var blocking: Bool
    var plan: PlanFacts?
    var consent: ConsentFacts?

    var isResult: Bool { askId == nil }

    init(ask: AskEvent, runId: String) {
        self.init(card: ask.card, runId: runId, askId: ask.askId)
    }

    init(resultCard: CardEvent, runId: String) {
        self.init(card: resultCard, runId: runId, askId: nil)
    }

    init(card: CardEvent, runId: String, askId: String?) {
        self.runId = runId
        self.askId = askId
        kind = askId == nil ? .result : Kind(card.kind)
        text = card.text
        // an option with no words cannot be shown, so it gets no button (its index stays the card's own)
        buttons = card.options.enumerated().compactMap { i, o in
            o.text.isEmpty ? nil : Button(runId: runId, askId: askId, index: i, kind: o.kind, text: o.text, role: Self.role(o.kind), style: Self.style(o.kind))
        }
        allowsFreeText = askId != nil && card.freeText
        blocking = card.blocking
        plan = card.plan
        consent = card.consent
    }

    static func role(_ kind: String) -> Role {
        switch kind {
        case "approve": return .approve
        case "reading", "value", "proposal", "undo_and_reading": return .choice
        case "skip_step": return .skipStep
        case "delegate": return .delegate
        case "cancel": return .cancel
        case "undo": return .undo
        default: return .other
        }
    }

    static func style(_ kind: String) -> Style {
        switch role(kind) {
        case .approve: return .prominent
        case .choice: return .radio
        case .undo: return .destructive
        case .skipStep, .delegate, .cancel, .other: return .bordered
        }
    }

    // MARK: answers

    /// What a click on `button` sends; nil when the button is not one of this card's: another card's (its run or its
    /// ask_id differ, even with the same words), or one it does not have.
    func answer(_ button: Button) -> CardAnswer? {
        guard button.runId == runId, button.askId == askId, buttons.contains(button) else { return nil }
        return Self.answer(button)
    }

    /// What a click on `button` sends, from the button's own card (its run_id and ask_id): never another card's.
    static func answer(_ button: Button) -> CardAnswer {
        if let a = button.askId { return .option(runId: button.runId, askId: a, option: button.index) }
        return .respond(runId: button.runId, option: button.index)
    }

    /// What picking the card's option `index` sends; nil when the card has no such option.
    func answer(option index: Int) -> CardAnswer? {
        guard buttons.contains(where: { $0.index == index }) else { return nil }
        if let a = askId { return .option(runId: runId, askId: a, option: index) }
        return .respond(runId: runId, option: index)
    }

    /// The user's own words on the card; nil when the card takes none or the words are empty. Words are words: never
    /// matched against the options' texts.
    func answer(text: String) -> CardAnswer? {
        let w = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowsFreeText, let a = askId, !w.isEmpty else { return nil }
        return .text(runId: runId, askId: a, text: w)
    }

    // MARK: where it can be answered (handoff §3.3, owner 10-21)

    /// Most picks a float card shows (not counting "you decide" and the way out).
    static let floatMaxChoices = 3
    /// Most lines of what goes out a float card shows.
    static let floatMaxOutgoing = 3

    /// The options that count towards the float's limit: everything but delegate and cancel.
    var choiceCount: Int { buttons.filter { $0.role != .delegate && $0.role != .cancel }.count }

    /// Whether the card can be answered in the float, by its structure alone: a plan, a long list (more picks or more
    /// outgoing lines than the float holds) and any card that takes the user's words (free_text) go to the main window,
    /// the whole card with its options (owner 10-22): the float shows a summary and 「去主窗口回答」 for those. Every
    /// float card also links to the main window.
    /// The view must still check that the text and the buttons fit unclipped in the float's width (handoff §3.3), which
    /// is a matter of layout, not of the card.
    var answerableInFloat: Bool {
        if kind == .plan { return false }
        if buttons.isEmpty { return false }
        if choiceCount > Self.floatMaxChoices { return false }
        if (consent?.outgoing.count ?? 0) > Self.floatMaxOutgoing { return false }
        if allowsFreeText { return false }                       // it takes words: the whole card in the main window (owner 10-22)
        return true
    }

    var freeTextInFloat: Bool { false }
}
