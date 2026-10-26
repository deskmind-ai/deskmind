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
//
// A2 (plan §1.3, invariant 3): a card never scrolls inside; its options are all on screen as it is. With H2's headline
// the card is: the headline (its title), what goes beyond the request (one line each) and an action card's fields --
// what goes out, whole, before 「可以」 -- always shown; the text and the plan's steps folded under 「细节 ▸」. Without
// one (an older harness) there is nothing to fold: the text is the card's title and body, the steps shown, as before.
//
// | headline | always shown                                         | folded under 细节       |
// |----------|------------------------------------------------------|-------------------------|
// | yes      | headline · beyond · consent fields · picks (+detail) | text · plan steps       |
// | no       | text · plan steps · consent fields · picks (+detail) | —                       |

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
    /// One line of what goes out (a consent card's outgoing): its kind as the executor gave it (field, selected, typed,
    /// text), its label (the kind when it has none), its value.
    struct Outgoing: Equatable {
        var label: String
        var value: String
        var kind: String = ""
        init(label: String, value: String, kind: String = "") { self.label = label; self.value = value; self.kind = kind }
        /// Its words on the card: its value, else (a selected element: its name is its label, its value empty --
        /// harness executor.ts outgoingItems) its label.
        var shown: String { value.isEmpty && label != kind ? label : value }
    }
    /// A consent card's fields.
    struct Consent: Equatable {
        var action: String
        var object: String
        var site: String?
        var outgoing: [Outgoing]
        /// What it does to the user's things (the card text's own clause): it sends out, it changes them.
        var effect: Effect? = nil
        /// What is selected in the window it acts in.
        var selected: [String] = []
        /// The earlier steps whose result is unknown -- they may already have gone out -- each with what it sent, and
        /// how many more there are than listed.
        var uncertain: [Uncertain] = []
        var uncertainMore: Int = 0
        /// What the model says of the situation now: its words, not checked.
        var modelSays: String? = nil
        /// What a yes covers (the harness signs it: harness service.ts consentFor).
        var scope: Scope = .once(target: nil)
        /// The action is said in the block: the card's title does not say it (a headline names it as a question).
        var actionRow = false
        /// The consent keys with a value the block does not show (a newer harness's field, a class it does not know,
        /// an element its action does not name): while there is one, the card's whole text stays under 「细节」.
        var unshown: [String] = []

        /// 「要发出去的」 as the P1Waiting board lays it out, by the executor's kinds and order only (never by what a label
        /// says, U3 §2.2): the lead line -- the first of what the task typed, else the first filled field -- the other
        /// fields, the picked items, the window's other text, and any line of a kind not known. Every line of
        /// `outgoing` is in exactly one of them (none lost: A2).
        var block: Block {
            var b = Block()
            let leadAt = outgoing.firstIndex { $0.kind == "typed" } ?? outgoing.firstIndex { $0.kind == "field" }
            for (i, o) in outgoing.enumerated() {
                if i == leadAt { b.lead = o; continue }
                switch o.kind {
                case "field", "typed": b.fields.append(o)
                case "selected": b.selected.append(o)
                case "text": b.text.append(o)
                default: b.other.append(o)
                }
            }
            return b
        }
    }
    struct Block: Equatable {
        var lead: Outgoing?
        var fields: [Outgoing] = []
        var selected: [Outgoing] = []
        var text: [Outgoing] = []
        var other: [Outgoing] = []
        var count: Int { (lead == nil ? 0 : 1) + fields.count + selected.count + text.count + other.count }
        /// The lead line's own label (none when it is only its kind's name).
        var leadLabel: String? { lead.flatMap { $0.label.isEmpty || $0.label == $0.kind ? nil : $0.label } }
    }
    enum Effect: Equatable { case sends, changes }
    struct Uncertain: Equatable { var text: String; var outgoing: [Outgoing] }
    /// What a yes on an action card covers. A site asked about with no uncertain step: that site, for the rest of the
    /// task (a site token); anything else: this one action (an action token). Unknown: a field the app does not know
    /// came with it -- the card claims neither.
    enum Scope: Equatable { case once(target: String?), site(String), unknown }

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
    /// The card's title: H2's headline, else its text (which is then the whole card's words).
    var title: String
    /// What goes beyond the request, one per line (H2); always shown.
    var beyond: [String]
    /// The text and the plan's steps are folded under 「细节」: only with a headline (else they are the card).
    var folds: Bool
    /// 「细节」 is there: the card folds, and it is not an action card whose block shows every consent field.
    var hasDetails: Bool { folds && (consent?.unshown.isEmpty != true) }
    /// The text, shown whole under the title, when the card has a headline and folds nothing (an action card with no
    /// consent fields: its text is the only account of what it does). nil: the text is the title, or it is folded.
    /// #124 Codex review at 80c339e: such a card showed its headline only, and its 「可以」 took a click.
    var shownText: String? { folds || title == text || text.isEmpty ? nil : text }
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
        title = card.headline ?? card.text
        beyond = card.headline == nil ? [] : card.beyond
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
        // (an action card with no consent fields: its text is the only account of what it does -- never folded; #124 review)
        folds = card.headline != nil && (!card.text.isEmpty || !plan.isEmpty) && !(card.kind == .action && card.consent == nil)
        consent = card.consent.map { Self.consent($0, title: card.headline ?? card.text) }
    }

    static func consent(_ c: ConsentFacts, title: String) -> Consent {
        let out = { (o: [ConsentFacts.Outgoing]) in o.map { Outgoing(label: $0.label.isEmpty ? $0.kind : $0.label, value: $0.value, kind: $0.kind) } }
        var k = Consent(action: c.actionText.isEmpty ? c.action : c.actionText, object: c.objectLabel.isEmpty ? c.object : c.objectLabel,
                        site: c.site, outgoing: out(c.outgoing))
        k.actionRow = !k.action.isEmpty && !title.contains(k.action)
        k.effect = ["external": .sends, "modify_user": .changes][c.consequence]
        k.selected = c.selected.filter { !$0.isEmpty }
        k.uncertain = c.uncertain.map { Uncertain(text: $0.text, outgoing: out($0.outgoing)) }
        let total = Int(exactly: c.uncertainTotal.rounded(.down)) ?? 0
        k.uncertainMore = max(0, total - k.uncertain.count)
        k.modelSays = c.modelSaysUnchecked.isEmpty ? nil : c.modelSaysUnchecked
        let uncertain = !c.uncertain.isEmpty || total > 0
        if !c.unknownKeys.isEmpty { k.scope = .unknown }
        else if let s = c.site, !s.isEmpty, !uncertain { k.scope = .site(s) }
        else { k.scope = .once(target: c.target.flatMap { $0.isEmpty ? nil : $0 }) }
        // (the machine forms -- action, object, an uncertain step's object and class -- are shown by their words)
        var unshown = c.unknownKeys.sorted()
        if !c.consequence.isEmpty && k.effect == nil { unshown.append(ConsentFacts.CodingKeys.consequence.rawValue) }
        if let t = c.target, !t.isEmpty, !k.action.contains(t), !title.contains(t) { unshown.append(ConsentFacts.CodingKeys.target.rawValue) }
        k.unshown = unshown
        return k
    }

    /// The line under an action card's buttons (P1Waiting): what 「可以」 covers, by the scope the yes is signed for --
    /// this once (the card's own target), or the site for the rest of the task; nothing claimed when it is unknown
    /// -- and what its 「这一步不要」 and 「先别做了」 do, each by the button's own words.
    static func consentHint(_ card: CardModel, lang: ResolvedLang) -> String? {
        guard let c = card.consent else { return nil }
        var parts: [String] = []
        switch consent(c, title: card.headline ?? card.text).scope {
        case .once(let t?): parts.append(L("Only for this one 「%@」.", t, lang: lang))
        case .once(nil): parts.append(L("Only for this once.", lang: lang))
        case .site(let s): parts.append(L("Once you agree, this task opens 「%@」 again without asking you.", s, lang: lang))
        case .unknown: break
        }
        for b in card.buttons {
            switch b.role {
            case .skipStep: parts.append(L("%@: this step is not done; the task goes on.", b.text, lang: lang))
            case .cancel: parts.append(L("%@: the whole task stops here.", b.text, lang: lang))
            default: break
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: lang == .zhHans ? "" : " ")
    }

    /// The control key `n` (1–9) picks, if the card has one.
    func control(forKey n: Int) -> Control? { controls.first { $0.key == n } }

    /// VoiceOver's hint for a control, by its option's kind (handoff §3.10), with its key.
    /// `keys`: the card's keys act now (ShellModel.keysActive) — the key is said only then.
    static func hint(_ c: Control, keys: Bool = false, lang: ResolvedLang) -> String {
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
        guard keys, let k = c.key else { return base }
        return L("%@. Key %d", base, k, lang: lang)
    }
}

/// The 1–9 keys on a waiting card (handoff §3.7): only in the main window while it is the key window, with no modifier
/// (⇧ aside), not an auto-repeat, and not while the user types in a field (the card's own field, the composer); and
/// only in card mode (ShellModel.keyDown: the user moved into the card explicitly).
enum CardKeys {
    /// A move into a card (ShellModel.enterCardMode) counts only once it has been on screen this long (seconds): a click
    /// or an Esc made as the card appeared was not about it. Time alone never turns the keys on.
    static let cardOnScreen: Double = 1.0

    static func number(characters: String?, commandLike: Bool, mainWindowIsKey: Bool, editingText: Bool, isRepeat: Bool = false) -> Int? {
        guard mainWindowIsKey, !editingText else { return nil }
        return digit(characters: characters, commandLike: commandLike, isRepeat: isRepeat)
    }

    /// What a key does to the pinned card (plan §1.5, with #111's rule kept: fable 10-25 -- only an explicit move puts
    /// the keys on a card, never time on screen). ⌘⌃⌥ and auto-repeats do nothing here; a field being typed in or a
    /// composition owns every key -- Return in the chat field steers the task and voids an open card (decision 3, A9 with H5).
    ///
    /// | state \ key                  | 1–9                 | Tab / ⇧Tab      | Esc                 | Return              |
    /// |------------------------------|---------------------|-----------------|---------------------|---------------------|
    /// | not in the card              | nothing (the chat's)| into the card   | into the card       | nothing (never yes) |
    /// | in the card                  | picks n → held      | (focus moves)   | out of the card     | nothing             |
    /// | held (take-back running)     | picks m: starts over| (focus moves)   | takes it back       | sends it now        |
    /// | typing in a field / composing| text                | text / focus    | the field's         | the field's         |
    ///
    /// Space presses the focused control (AppKit's own). Held, 「先别做了」 and Stop act at once, as always.
    enum KeyAction: Equatable { case none, enterCard, leaveCard, digit(Int), takeBack, sendNow }
    struct Context: Equatable { var inCard: Bool; var held: Bool; var editing: Bool; var composing: Bool }

    static func action(characters: String?, commandLike: Bool, isRepeat: Bool, _ c: Context) -> KeyAction {
        guard !commandLike, !isRepeat, !c.editing, !c.composing, let ch = characters else { return .none }
        switch ch {
        case "\u{1b}": return c.held ? .takeBack : c.inCard ? .leaveCard : .enterCard
        case "\t", "\u{19}": return c.inCard ? .none : .enterCard
        case "\r", "\u{3}": return c.held ? .sendNow : .none
        default:
            guard let n = digit(characters: ch, commandLike: false, isRepeat: false) else { return .none }
            return c.inCard || c.held ? .digit(n) : .none
        }
    }

    /// The event alone: a digit 1–9, no ⌘⌃⌥, not an auto-repeat (where the typing is and the card's state are
    /// ShellModel.keyWorks's).
    static func digit(characters: String?, commandLike: Bool, isRepeat: Bool) -> Int? {
        guard !commandLike, !isRepeat, let c = characters, c.count == 1, let n = Int(c), (1...CardLayout.maxKeys).contains(n) else { return nil }
        return n
    }
}
