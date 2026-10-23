// A waiting card laid out by its kind (M2 A2; plan §1 卡片 ①–④, handoff §1.3, §1.4, §3.7, §3.10): what its body shows
// (the harness's words, and the plan's / the consent's fields when the card carries them) and its controls. The
// invariant: each option has exactly one control, which sends that option's own index with the card's ask_id; 「可以」
// (an approve-type option: approve, delegate) takes a click only once the whole card has been on screen.
//
// The controls come from the options' kinds alone, never their words (CardModel): the picks (readings, values,
// proposals) as a list, the rest as buttons in the harness's order, the approve one prominent. Keys 1–9 number them in
// the order they are shown — the list first, then the buttons — and pick through the same path as a click (the
// take-back, the whole-card gate).
//
// | kind      | body                                                  | list               | buttons                         | own field |
// |-----------|-------------------------------------------------------|--------------------|---------------------------------|-----------|
// | plan      | text; per step: purpose, what it touches, sites, tags | —                  | 可以，就这样做 · 先别做了          | free_text |
// | action    | text; the action, its object, the site, what goes out | —                  | 可以 · 这一步不要 · 先别做了        | free_text |
// | ambiguity | text                                                  | readings           | 由你决定 · 先别做了                | free_text |
// | missing   | text                                                  | values             | 由你决定 · 先别做了                | free_text |
// | any other | text                                                  | choice-role ones   | the rest                        | free_text |
//
// The text is always shown whole: the fields add to it, they never stand in for it (what is approved is what was shown).

import Foundation

struct CardLayout: Equatable {
    /// A plan step as the card shows it.
    struct PlanRow: Equatable {
        var n: Int
        var purpose: String
        /// What it touches (labels), and the sites it opens with what goes to each.
        var objects: [String]
        var sites: [Site]
        /// It changes the user's things (class modify_user) / sends something out (class external).
        var changesYours: Bool
        var sendsOut: Bool
    }
    struct Site: Equatable { var host: String; var sends: String?; var asksEach: Bool }
    /// One line of what goes out (a consent card's outgoing).
    struct Outgoing: Equatable { var label: String; var value: String }
    /// A consent card's fields.
    struct Consent: Equatable {
        var action: String
        var object: String
        var site: String?
        var outgoing: [Outgoing]
    }

    /// One option's control.
    struct Control: Equatable {
        enum Slot: Equatable { case list, button }
        var button: CardModel.Button
        var slot: Slot
        /// 1–9 in the order shown, nil past nine.
        var key: Int?
        var index: Int { button.index }
        var prominent: Bool { button.role == .approve }
    }

    var kind: CardModel.Kind
    var text: String
    var plan: [PlanRow]
    var foreground: [String]
    var consent: Consent?
    /// In the order shown: the list, then the buttons.
    var controls: [Control]
    /// The card takes the user's own words, in its own field (main window only).
    var field: Bool

    var list: [Control] { controls.filter { $0.slot == .list } }
    var buttons: [Control] { controls.filter { $0.slot == .button } }

    static let maxKeys = 9

    init(_ card: CardModel) {
        kind = card.kind
        text = card.text
        field = card.allowsFreeText
        let listed = card.buttons.filter { $0.role == .choice }
        let rest = card.buttons.filter { $0.role != .choice }
        controls = (listed.map { Control(button: $0, slot: .list) } + rest.map { Control(button: $0, slot: .button) })
            .enumerated().map { i, c in var c = c; c.key = i < Self.maxKeys ? i + 1 : nil; return c }
        plan = (card.plan?.steps ?? []).enumerated().map { i, s in
            PlanRow(n: i + 1, purpose: s.purpose, objects: s.objects.map { $0.label.isEmpty ? $0.ref : $0.label },
                    sites: s.sites.map { Site(host: $0.host, sends: $0.sends, asksEach: $0.asksEach) },
                    changesYours: s.class == "modify_user", sendsOut: s.class == "external" || s.sites.contains { ($0.sends ?? "").isEmpty == false })
        }
        foreground = card.plan?.foreground?.apps ?? []
        consent = card.consent.map { c in
            Consent(action: c.actionText.isEmpty ? c.action : c.actionText, object: c.objectLabel.isEmpty ? c.object : c.objectLabel,
                    site: c.site, outgoing: c.outgoing.map { Outgoing(label: $0.label.isEmpty ? $0.kind : $0.label, value: $0.value) })
        }
    }

    /// The control key `n` (1–9) picks, if the card has one.
    func control(forKey n: Int) -> Control? { controls.first { $0.key == n } }

    /// VoiceOver's hint for a control, by its option's kind (handoff §3.10), with its key.
    static func hint(_ c: Control, lang: ResolvedLang) -> String {
        let base: String
        switch c.button.role {
        case .approve: base = L("Agrees; the task goes on", lang: lang)
        case .choice: base = L("Picks this one", lang: lang)
        case .skipStep: base = L("Skips this step; the task goes on", lang: lang)
        case .delegate: base = L("Lets DeskMind decide", lang: lang)
        case .cancel: base = L("Answers no; the task ends cancelled", lang: lang)
        case .undo: base = L("Undoes what the task changed", lang: lang)
        case .other: base = L("Answers with this option", lang: lang)
        }
        guard let k = c.key else { return base }
        return L("%@. Key %d", base, k, lang: lang)
    }
}

/// The 1–9 keys on a waiting card (handoff §3.7): only in the main window while it is the key window, with no modifier
/// (⇧ aside), not an auto-repeat, and not while the user types in a field (the card's own field, the composer). Whether
/// the user was typing a moment ago is not read from the focus (SwiftUI may drop it when the composer is disabled as a
/// card arrives): ShellModel.keyDown adds the time guards (`cardOnScreen`, `quiet`).
enum CardKeys {
    /// The card must have been on screen this long before a key picks on it (seconds): reading a new card and deciding
    /// takes longer than this, while a keystroke that was already on its way when it appeared comes sooner.
    static let cardOnScreen: Double = 1.0
    /// And no key-down (any key, wherever it went) for this long before the digit: typing runs at roughly 0.1–0.3 s
    /// between keys (40–100 words a minute), and even a slow typist rarely pauses a second inside a burst; a deliberate
    /// answer key comes after a pause. A digit inside a burst is part of the burst — it never reaches the card, and it
    /// renews the guard.
    static let quiet: Double = 1.0

    static func number(characters: String?, commandLike: Bool, mainWindowIsKey: Bool, editingText: Bool, isRepeat: Bool = false) -> Int? {
        guard mainWindowIsKey, !editingText, !commandLike, !isRepeat, let c = characters, c.count == 1,
              let n = Int(c), (1...CardLayout.maxKeys).contains(n) else { return nil }
        return n
    }
}
