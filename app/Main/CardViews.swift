// A card in the 0.5 window, by its kind (M2 A2): the plan card, the action card, the choice card (which one you
// mean), the missing-information card, and any other card the harness sends, all from CardLayout (Shared/CardLayout.swift):
// one control per option, sending that option's index with the card's ask_id — nothing is decided by the words on the
// card. The result card uses the same view (its own phase is A3's).
//
// Focus (handoff §3.1): nothing here activates the app, brings a window forward or moves the keyboard focus (ShellTests
// checks the window's view files from build.sh). The 1–9 keys (CardKeyMonitor) act only in card mode — after the user
// moved into the card (a click on it, Esc / Tab) — never by timing alone; they pick through the same path as a click.

import AppKit
import SwiftUI

/// A card: its state, its body (the text whole, then the plan's or the consent's fields, then the list of picks), its
/// buttons, the take-back or the expiry when it has one, and its own field when it takes the user's words.
///
/// It never scrolls inside (A2, invariant 3): every option is on screen as the card is, and what goes out is laid out
/// before 「可以」. Its title (H2's headline, else its text), what goes beyond the request and an action card's fields
/// are always shown; with a headline, the text and the plan's steps fold under 「细节」 (CardLayout). Its height as laid
/// out goes to the shell (cardLaidOut): a card taller than the pinned place stays in place in the chat, and there an
/// approve-type option takes no key (ShellModel.keyWorks).
///
/// It shows the card's one state (`phase`, CardStore): an answer held for its take-back says what was picked, with a
/// countdown and 「撤回」; one sent waits greyed; an expired card keeps its text, drops its options and offers 「现在回答」.
struct CardView: View {
    @ObservedObject var shell: ShellModel
    let card: CardModel
    let phase: CardPhase
    let askedAt: Double?
    let session: SessionState
    @Environment(\.lang) private var lang
    /// The words typed in its own field: the shell's, by card key (they survive the card moving: #124 Codex review).
    private var words: Binding<String> { Binding(get: { shell.cardDraft(card) }, set: { shell.setCardDraft(card, $0) }) }
    /// Which option has the keyboard focus -- observed, never set (the user's Tab moves it): on a card in place in the
    /// chat, the focused option is scrolled into view (ShellModel.requestScroll), so a keyboard or VoiceOver user can
    /// answer a card too tall to pin (lead 10-25).
    @FocusState private var focusedOption: Int?

    /// 「细节」 open or not: the shell's, by card key (it survives the card moving between the pinned place and the chat).
    private var detailsOpen: Binding<Bool> {
        Binding(get: { shell.detailsOpen(card) }, set: { shell.setDetails(card, open: $0) })
    }

    private var layout: CardLayout { CardLayout(card) }
    private var wordsEnabled: Bool { shell.wordsEnabled(card, in: session) }

    var body: some View {
        let layout = self.layout
        let asking = card.blocking && !card.isResult && phase == .open
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(layout.title).font(.system(size: asking ? 17 : 14, weight: .bold)).lineSpacing(2).foregroundStyle(Brand.ink)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let t = layout.shownText {
                Text(t).font(.system(size: 13)).lineSpacing(2).foregroundStyle(Brand.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(layout.beyond.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 13)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
            }
            if !layout.folds && !layout.plan.isEmpty { PlanSteps(rows: layout.plan, foreground: layout.foreground) }
            if let c = layout.consent { ConsentFields(consent: c, showsAction: card.headline == nil) }
            // (an action card is its headline and its fields: the board has no 「细节」 on it -- protocol.md: the
            // consent is the text split, no more and no less -- unless a field came that the block does not show:
            // then the whole text stays reachable, #129 Codex review)
            if layout.hasDetails {
                DisclosureGroup(isExpanded: detailsOpen) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !layout.text.isEmpty {
                            Text(layout.text).font(.system(size: 13)).foregroundStyle(Brand.ink).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !layout.plan.isEmpty { PlanSteps(rows: layout.plan, foreground: layout.foreground) }
                    }
                    .padding(.top, 4)
                } label: {
                    Text(L("Card details", lang: lang)).font(.system(size: 12)).foregroundStyle(ShellColor.secondary)
                }
            }
            if !layout.list.isEmpty && phase.ending == nil {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(layout.list, id: \.index) { c in control(c) }
                }
            }
            if phase.ending == nil && !layout.buttons.isEmpty {
                // (side by side, the primary wider: 1.3 : 1 : 1)
                WeightedRow(weights: layout.buttons.map { $0.prominent ? 1.3 : 1 }) {
                    ForEach(layout.buttons, id: \.index) { c in control(c) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if phase.ending == nil, layout.consent != nil, let hint = CardLayout.consentHint(card, lang: lang) {
                Text(hint).font(.system(size: 12)).lineSpacing(2).foregroundStyle(ShellColor.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let held = phase.pending, case .pending(_, let until) = phase { takeBackRow(held, until: until) }
            if case .expired(_, let now) = phase { expiredRow(now) }
            if layout.field && phase.ending == nil {
                HStack(spacing: 8) {
                    TextField(L("Or answer in your own words", lang: lang), text: words, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendWords)
                        .disabled(!wordsEnabled)
                    Button(L("Send", lang: lang), action: sendWords).buttonStyle(InkButtonStyle(prominent: false))
                        .disabled(!wordsEnabled || words.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.voiceOverLabel(card, phase: phase, lang: lang))
        // (its height as laid out: whether it fits the pinned place -- ShellModel.cardFits)
        .background(GeometryReader { g in Color.clear.preference(key: CardHeight.self, value: g.size.height) })
        .onPreferenceChange(CardHeight.self) { h in shell.cardLaidOut(card, height: h) }
        .onChange(of: focusedOption) { _, i in
            if let i, !shell.cardPinnedWhole(card) { shell.requestScroll(to: ShellModel.optionAnchor(card, i)) }
        }
        // (a click anywhere on it is a move into it: card mode, its keys on — CardKeys; when it came on screen)
        .simultaneousGesture(TapGesture().onEnded { shell.enterCardMode(card) })
        .onAppear { shell.cardShown(card) }
        .onDisappear { shell.cardHidden(card) }
    }

    /// The card's top line (P1Waiting): while it waits, the orange dot and 「等你 · <种类>」 with 「等了 m:ss」 on the right;
    /// after, its state in grey; a card that does not block, its kind.
    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            if card.blocking && !card.isResult {
                if phase == .open {
                    XiaoFace(eyes: .up, size: 22)      // (P1Waiting: 小方 looking up at you, the card's fourth place)
                    Text(L("Waiting for you · %@", ShellText.cardKind(card.kind.name, lang: lang), lang: lang))
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(ShellColor.orangeText)
                } else {
                    Text(L("%@ · %@", ShellText.cardState(phase, lang: lang), ShellText.cardKind(card.kind.name, lang: lang), lang: lang))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(ShellColor.secondary)
                }
            } else {
                Text(ShellText.cardKind(card.kind.name, lang: lang)).font(.system(size: 12, weight: .semibold)).foregroundStyle(ShellColor.secondary)
            }
            Spacer(minLength: 4)
            if phase == .open, card.blocking, let askedAt {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let w = max(0, Int(shell.now() - askedAt))
                    Text(L("Waited %d:%02d", w / 60, w % 60, lang: lang)).font(.system(size: 12).monospacedDigit()).foregroundStyle(ShellColor.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// One option's control: a row of the list (a pick), or a button; with its key (1–9) shown.
    @ViewBuilder private func control(_ c: CardLayout.Control) -> some View {
        let b = c.button
        let enabled = shell.buttonEnabled(b, card: card, in: session)
        let action = { _ = shell.click(b) }      // (the same action for a mouse click and VoiceOver's press)
        Group {
            switch c.slot {
            case .list:
                Button(action: action) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if shell.keyWorks(card, c), let k = c.key { KeyCap(n: k) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
                            if let d = b.detail {
                                Text(d).font(.system(size: 12)).foregroundStyle(ShellColor.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Brand.card))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(ShellPalette.buttonLine), lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            case .button:
                Button(action: action) {
                    HStack(spacing: 6) {
                        if shell.keyWorks(card, c), let k = c.key { KeyCap(n: k) }
                        Text(b.text)
                    }
                }
                .buttonStyle(InkButtonStyle(prominent: c.prominent, fill: true))
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)    // (InkButtonStyle does not dim: the card's own)
        .focused($focusedOption, equals: c.index)
        .id(ShellModel.optionAnchor(card, c.index))
        .accessibilityLabel(b.detail.map { L("%@, %@", b.text, $0, lang: lang) } ?? b.text)
        .accessibilityHint(CardLayout.hint(c, keys: shell.keyWorks(card, c), lang: lang))
    }

    /// The answer held for its take-back: what was picked, the seconds left, and 「撤回」 (the words come back to the
    /// field). Picking another option starts over; 「先别做了」 and Stop are not held.
    @ViewBuilder private func takeBackRow(_ held: CardAnswer, until: Double) -> some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let left = max(0, until - shell.now())
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Brand.paper)
                        .frame(width: 26, height: 26).background(Circle().fill(Brand.ink)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Picked: %@", Self.picked(held, card: card), lang: lang)).font(.system(size: 15, weight: .semibold)).foregroundStyle(Brand.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(L("Goes on in %d s", Int(left.rounded(.up)), lang: lang)).font(.system(size: 12).monospacedDigit()).foregroundStyle(ShellColor.secondary)
                    }
                    Spacer(minLength: 4)
                    Button(L("Take back", lang: lang)) {
                        if case .text(_, _, let w) = held { words.wrappedValue = w }
                        shell.takeBack(card)
                    }
                    .buttonStyle(InkButtonStyle(prominent: false, small: true))
                    .accessibilityHint(L("Your pick is not sent; the card waits again", lang: lang))
                }
                // (the time left to take it back, as a bar: display only -- CardStore holds the answer)
                GeometryReader { g in
                    Capsule().fill(ShellColor.softLine)
                        .overlay(alignment: .leading) { Capsule().fill(Brand.dot).frame(width: g.size.width * min(1, left / CardStore.takeBack)) }
                }
                .frame(height: 3)
                .accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// An expired card: why, and 「现在回答」 while the task waits on it (it looks at the screen again and asks anew).
    @ViewBuilder private func expiredRow(_ now: CardPhase.AnswerNow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Nobody answered in 10 minutes, so this card expired. The task waits where it was; nothing was done.", lang: lang))
                .font(.system(size: 12)).foregroundStyle(ShellColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if now == .offered || now == .asked, let ask = card.askId {
                Button(now == .asked ? L("Looking again…", lang: lang) : L("Answer now", lang: lang)) { shell.answerNow(card.runId, askId: ask) }
                    .buttonStyle(InkButtonStyle(prominent: true))
                    .disabled(now == .asked)
                    .accessibilityHint(L("The task looks at the screen again and asks you anew", lang: lang))
            }
        }
    }

    /// What a held answer picked, in the card's own words.
    static func picked(_ a: CardAnswer, card: CardModel) -> String {
        switch a {
        case .option(_, _, let i), .respond(_, let i): return card.buttons.first { $0.index == i }?.text ?? ""
        case .text(_, _, let w): return "「\(w)」"
        }
    }

    private func sendWords() {
        guard wordsEnabled else { return }
        shell.answer(card, text: words.wrappedValue)
        words.wrappedValue = ""
    }

    /// 「<状态>：<卡的种类>。<标题>。<n> 个选项」 (handoff §3.10): the title is H2's headline, else the text's first sentence.
    static func voiceOverLabel(_ card: CardModel, phase: CardPhase, lang: ResolvedLang) -> String {
        let state = ShellText.cardState(phase, lang: lang)
        let kind = ShellText.cardKind(card.kind.name, lang: lang)
        return L("%@: %@. %@. %d options", state, kind, card.headline ?? firstSentence(card.text), card.buttons.count, lang: lang)
    }

    /// The text up to its first sentence end (for VoiceOver; the whole card stays readable inside).
    static func firstSentence(_ text: String) -> String {
        let ends: Set<Character> = ["。", "！", "？", ".", "!", "?", "\n"]
        guard let i = text.firstIndex(where: { ends.contains($0) }) else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(text[..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A window's open card where it pins it (A2): whole when it fits the pinned place (ShellModel.cardPinnedWhole), else
/// one line -- its title and 「跳到卡片」 -- while TaskRow draws it whole in place in the window's scroll. Both windows (the
/// chat, a goal's screen) pin their card through this and say their room (ShellModel.pinRoom), and TaskRow reads the
/// same predicate: one answerable copy per window (#124 review at 64547f9).
struct PinnedCard: View {
    @ObservedObject var shell: ShellModel
    let card: CardModel
    let phase: CardPhase
    let askedAt: Double?
    let session: SessionState
    /// 「跳到卡片」: scroll the window to the card's place (TaskRow.cardAnchor).
    let jump: (String) -> Void
    @Environment(\.lang) private var lang

    var body: some View {
        if shell.cardPinnedWhole(card) {
            CardView(shell: shell, card: card, phase: phase, askedAt: askedAt, session: session)
                // (P1Waiting: the pinned card that waits for you, and only it, in a 2 pt orange ring)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(phase == .open && card.blocking ? Brand.dot : Color.clear, lineWidth: 2))
                .id(ShellModel.cardKey(card))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else {
            HStack(spacing: 8) {
                Text(L("Waiting for you", lang: lang)).font(.system(size: 11, weight: .semibold)).foregroundStyle(ShellColor.orangeText)
                Text(CardLayout(card).title).font(.system(size: 12)).foregroundStyle(Brand.ink).lineLimit(1)
                Spacer()
                Button(L("Go to the card", lang: lang)) { jump(TaskRow.cardAnchor(card)) }
                    .buttonStyle(InkButtonStyle(prominent: false))
                    .accessibilityHint(L("Scrolls the chat to the card", lang: lang))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Brand.card))
        }
    }
}

/// The room a window gives its pinned card, said to the shell as the window's height changes (ShellModel.pinRoom).
struct PinRoomReporter: View {
    @ObservedObject var shell: ShellModel
    var body: some View {
        GeometryReader { g in
            Color.clear.onChange(of: g.size.height, initial: true) { _, h in shell.pinRoom(columnHeight: h) }
        }
    }
}

/// An option's key, beside it (decorative: VoiceOver reads the key in the control's hint).
struct KeyCap: View {
    let n: Int
    var body: some View {
        Text("\(n)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(ShellColor.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).strokeBorder(Brand.line))
            .accessibilityHidden(true)
    }
}

/// A card no longer pinned, in one line (U3, P1Main): its kind in bold, what was picked, how and when it closed
/// (ShellText.cardSummary); a plan's opens to its steps.
struct AnsweredRow: View {
    let card: CardState
    let runId: String
    let phase: CardPhase
    @Environment(\.lang) private var lang
    @State private var open = false

    var body: some View {
        let s = ShellText.cardSummary(card, phase: phase, runId: runId, lang: lang)
        let layout = CardLayout(CardModel(card: card.card, runId: runId, askId: card.askId))
        let plan = layout.plan.isEmpty ? nil : layout
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(ShellColor.secondary).accessibilityHidden(true)
                (Text(s.kind).fontWeight(.semibold).foregroundColor(Brand.ink)
                 + Text(s.pick.map { " · " + $0 } ?? "").foregroundColor(Brand.ink)
                 + Text(" · " + s.tail).foregroundColor(ShellColor.secondary))
                    .font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if plan != nil {
                    Button(open ? L("Collapse", lang: lang) : L("Expand", lang: lang)) { open.toggle() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(ShellColor.orangeText)
                        .accessibilityLabel(open ? L("Collapse", lang: lang) : L("Expand", lang: lang))
                        .accessibilityHint(L("Shows the plan's steps", lang: lang))
                }
            }
            if open, let plan { PlanSteps(rows: plan.plan, foreground: plan.foreground) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 600, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ShellColor.softLine))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.line)
    }

    private var icon: String {
        switch CardModel.Kind(card.card.kind) {
        case .ambiguity, .missing: "list.bullet"
        case .plan: "list.number"
        case .action: "checkmark.seal"
        default: "questionmark.circle"
        }
    }
}

/// A plan card's steps (card.plan): what each does, what it touches, the sites it opens and what goes to them, with
/// words for what changes the user's things and what goes out (never colour alone, handoff §3.10).
struct PlanSteps: View {
    let rows: [CardLayout.PlanRow]
    let foreground: [String]
    @Environment(\.lang) private var lang
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.n) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(r.n).").font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.ink)
                        Text(r.purpose).font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if r.changesYours || r.sendsOut {
                        HStack(spacing: 6) {
                            if r.changesYours { tag(L("Changes your things", lang: lang), out: false) }
                            if r.sendsOut { tag(L("Sends something out", lang: lang), out: true) }
                        }
                    }
                    if !r.objects.isEmpty { line(L("Touches: %@", r.objects.joined(separator: "、"), lang: lang)) }
                    ForEach(Array(r.sites.enumerated()), id: \.offset) { _, site in
                        line(site.sends.map { L("Site: %@ · sends: %@", site.host, $0, lang: lang) } ?? L("Site: %@", site.host, lang: lang))
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !foreground.isEmpty { line(L("Comes to the front: %@", foreground.joined(separator: "、"), lang: lang)) }
        }
    }
    /// P1Main's tags: 「改你的东西」 in an ink outline, 「往外发」 on the orange tint (words, never colour alone).
    private func tag(_ text: String, out: Bool) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(out ? ShellColor.orangeText : Brand.ink)
            .padding(.horizontal, 7).frame(height: 20)
            .background(Capsule().fill(out ? ShellColor.waitRow : Color.clear))
            .overlay(Capsule().strokeBorder(out ? Color.clear : Brand.ink, lineWidth: 1))
    }
    private func line(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(ShellColor.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// An action card's fields (card.consent), on the paper in a block (P1Waiting 「要发出去的」): the action, what it acts
/// on, the site, and every line of what goes out.
struct ConsentFields: View {
    let consent: CardLayout.Consent
    /// On an ink surface (the float): a darker block, its words in the ink surface's colours.
    var onInk = false
    /// The card has no headline (an older harness): the action in the block's first line, else it is the title's.
    var showsAction = false
    @Environment(\.lang) private var lang

    /// P1Waiting: 「要发出去的」, then what the task typed (or the first field) large, the other fields as label and
    /// value, what is picked, the window's other text quietly -- every line (CardLayout.Block: none lost) -- and the
    /// site and the window it acts in.
    var body: some View {
        let b = consent.block
        VStack(alignment: .leading, spacing: 6) {
            if (showsAction || consent.actionRow) && !consent.action.isEmpty { pair(L("Action", lang: lang), consent.action) }
            if b.count == 0 {
                Text(L("Nothing to send shows in the window", lang: lang)).font(.system(size: 12)).foregroundStyle(quiet)
            } else {
                // (the lead line's label beside the heading: every outgoing label is on the card -- #129 Codex review)
                Text(b.leadLabel.map { L("%@ · %@", L("What goes out", lang: lang), $0, lang: lang) } ?? L("What goes out", lang: lang))
                    .font(.system(size: onInk ? 11 : 12, weight: .semibold)).foregroundStyle(quiet)
                if let l = b.lead {
                    Text(verbatim: "「" + l.value + "」").font(.system(size: onInk ? 13 : 15, weight: .bold)).foregroundStyle(strong)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array((b.fields + b.other).enumerated()), id: \.offset) { _, o in pair(o.label, o.value) }
                ForEach(Array(b.selected.enumerated()), id: \.offset) { _, o in pair(L("Selected", lang: lang), o.value) }
                if !b.text.isEmpty {
                    Text(L("Also in the window:", lang: lang)).font(.system(size: onInk ? 11 : 12)).foregroundStyle(quiet).padding(.top, 2)
                    ForEach(Array(b.text.enumerated()), id: \.offset) { _, o in
                        Text(o.value).font(.system(size: onInk ? 11 : 12)).foregroundStyle(quiet).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(Array(consent.selected.enumerated()), id: \.offset) { _, v in pair(L("Selected", lang: lang), v) }
            if let site = consent.site, !site.isEmpty { pair(L("Site", lang: lang), site) }
            if !consent.object.isEmpty {
                Text(L("In %@", consent.object, lang: lang)).font(.system(size: onInk ? 11 : 13)).foregroundStyle(quiet).fixedSize(horizontal: false, vertical: true)
            }
            if let e = consent.effect { note(e == .sends ? L("This sends something out", lang: lang) : L("This changes your things", lang: lang)) }
            if !consent.uncertain.isEmpty || consent.uncertainMore > 0 { UncertainSteps(consent: consent, onInk: onInk) }
            if let m = consent.modelSays { note(L("What the model says (not checked): %@", m, lang: lang)) }
        }
        .padding(.horizontal, onInk ? 12 : 14).padding(.vertical, onInk ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: onInk ? 10 : 12).fill(onInk ? Color(ShellPalette.inkButton) : Brand.paper))
    }
    private var quiet: Color { onInk ? Color(ShellPalette.onInkMuted) : ShellColor.secondary }
    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: onInk ? 11 : 12)).foregroundStyle(quiet).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
    private var strong: Color { onInk ? Color(ShellPalette.onInk) : Brand.ink }
    private func pair(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: onInk ? 11 : 13)).foregroundStyle(quiet)
            Text(value).font(.system(size: onInk ? 11 : 13)).foregroundStyle(strong)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 「之前不确定是否已发出的」: each earlier step whose result is unknown, in its own words, with what it sent -- so a yes
/// to this send is given knowing which earlier one may already have gone out -- and how many more there are.
struct UncertainSteps: View {
    let consent: CardLayout.Consent
    var onInk = false
    @Environment(\.lang) private var lang
    private var quiet: Color { onInk ? Color(ShellPalette.onInkMuted) : ShellColor.secondary }
    private var strong: Color { onInk ? Color(ShellPalette.onInk) : Brand.ink }
    private var size: CGFloat { onInk ? 11 : 12 }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Earlier steps that may already have gone out", lang: lang)).font(.system(size: size, weight: .semibold)).foregroundStyle(quiet)
            ForEach(Array(consent.uncertain.enumerated()), id: \.offset) { _, u in
                VStack(alignment: .leading, spacing: 2) {
                    Text(u.text).font(.system(size: size)).foregroundStyle(strong).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(u.outgoing.enumerated()), id: \.offset) { _, o in
                        Text(L("%@: %@", o.label, o.value, lang: lang)).font(.system(size: size)).foregroundStyle(quiet)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if consent.uncertainMore > 0 {
                Text(L("%d more steps with an unknown result", consent.uncertainMore, lang: lang)).font(.system(size: size)).foregroundStyle(quiet)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The 1–9 keys on the pinned card (handoff §3.7): a key-down in the window this view is in, while that window is the
/// key window and no field is being typed in, with no ⌘ ⌃ ⌥ (CardKeys); handed to `onKey`, and swallowed only when it
/// picked something. It never takes the focus and never brings anything forward.
struct CardKeyMonitor: NSViewRepresentable {
    /// Every key-down of this window, with what the gate needs; true: consumed (it picked).
    let onKey: (_ characters: String?, _ commandLike: Bool, _ mainWindowIsKey: Bool, _ editingText: Bool, _ isRepeat: Bool, _ composing: Bool) -> Bool
    /// The window stopped being the key window of the active app (resigned key, closed, minimised, the app went back).
    let onLeave: () -> Void
    /// It is the key window of the active app again (became key, the app active, restored).
    let onReturn: () -> Void
    /// Where the typing is now (a field being edited, an input-method composition), on every window update.
    let onFocus: (_ editing: Bool, _ composing: Bool) -> Void

    /// The one wiring (ShellModel.cardKeyHandlers): the chat and a goal's screen install the same.
    init(_ h: CardKeyHandlers) { self.init(onKey: h.onKey, onLeave: h.onLeave, onReturn: h.onReturn, onFocus: h.onFocus) }
    init(onKey: @escaping (_ characters: String?, _ commandLike: Bool, _ mainWindowIsKey: Bool, _ editingText: Bool, _ isRepeat: Bool, _ composing: Bool) -> Bool,
         onLeave: @escaping () -> Void, onReturn: @escaping () -> Void, onFocus: @escaping (_ editing: Bool, _ composing: Bool) -> Void) {
        self.onKey = onKey; self.onLeave = onLeave; self.onReturn = onReturn; self.onFocus = onFocus
    }

    func makeNSView(context: Context) -> NSView { Watcher(self) }
    func updateNSView(_ v: NSView, context: Context) { (v as? Watcher)?.monitor = self }
    static func dismantleNSView(_ v: NSView, coordinator: ()) { (v as? Watcher)?.stop() }

    final class Watcher: NSView {
        var monitor: CardKeyMonitor
        private var events: Any?
        private var observers: [NSObjectProtocol] = []
        init(_ m: CardKeyMonitor) { monitor = m; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        /// The window's typing state: a field being edited, a composition under way.
        private static func typing(_ w: NSWindow) -> (editing: Bool, composing: Bool) {
            (w.firstResponder is NSText, (w.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let win = window else { return }
            // (observed, never acted on: nothing here moves the focus or a window)
            let c = NotificationCenter.default
            let leave: [(Notification.Name, AnyObject?)] = [(NSWindow.didResignKeyNotification, win), (NSWindow.willCloseNotification, win),
                                                             (NSWindow.didMiniaturizeNotification, win), (NSApplication.didResignActiveNotification, nil)]
            for (name, object) in leave {
                observers.append(c.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.monitor.onLeave() })
            }
            let back: [(Notification.Name, AnyObject?)] = [(NSWindow.didBecomeKeyNotification, win), (NSWindow.didDeminiaturizeNotification, win),
                                                            (NSApplication.didBecomeActiveNotification, nil)]
            for (name, object) in back {
                observers.append(c.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.returned() })
            }
            observers.append(c.addObserver(forName: NSWindow.didUpdateNotification, object: win, queue: .main) { [weak self] _ in
                guard let self, let w = self.window else { return }
                let t = Self.typing(w)
                self.monitor.onFocus(t.editing, t.composing)
            })
            returned()
            events = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                let t = Self.typing(w)
                let picked = self.monitor.onKey(e.charactersIgnoringModifiers, !e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                                                w.isKeyWindow && NSApp.isActive, t.editing, e.isARepeat, t.composing)
                return picked ? nil : e
            }
        }

        /// Back as the key window of the active app — or, when it is not (yet), still away.
        private func returned() {
            guard let w = window else { return }
            if w.isKeyWindow && NSApp.isActive && !w.isMiniaturized { monitor.onReturn() } else { monitor.onLeave() }
        }

        func stop() {
            if let m = events { NSEvent.removeMonitor(m); events = nil }
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers = []
        }
        deinit { stop() }
    }
}
