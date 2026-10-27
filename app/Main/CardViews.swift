// A card in the 0.5 window, by its kind (M2 A2): the plan card, the action card, the choice card (which one you
// mean), the missing-information card, and any other card the harness sends, all from CardLayout (Shared/CardLayout.swift):
// one control per option, sending that option's index with the card's ask_id — nothing is decided by the words on the
// card. The result card is TaskViews' (ResultSection).
//
// Focus (handoff §3.1): nothing here activates the app, brings a window forward or moves the keyboard focus (ShellTests
// checks the window's view files from build.sh). The 1–9 keys (CardKeyMonitor) act only in card mode — after the user
// moved into the card (a click on it, Esc / Tab) — never by timing alone; they pick through the same path as a click.

import AppKit
import SwiftUI

/// The cards' own colours (#133: P1Main, P1Waiting, P3States), from the tokens.
enum CardColor {
    static let body = Color(ShellPalette.cardBody)
    static let okText = Color(ShellPalette.okText)
    static let okTint = Color(ShellPalette.okTint)
    static let ended = Color(ShellPalette.endedCard)
    static let strip = Color(ShellPalette.voidStrip)
    static let rule = Color(ShellPalette.cardRule)
}

/// A card's button (P1Waiting, P3States): the primary one ink with paper text, bold; the others the card colour in a
/// 1 pt #C9C6BB edge. Its height, corner and size by where it is: 44 / 13 / 15 under a card's question, 40 / 12 / 14 for
/// the choice card's way out, 32 / 8 / 12 on a card that ended; as wide as it is given.
struct CardButtonStyle: ButtonStyle {
    var prominent = false
    var height: CGFloat = 44
    var radius: CGFloat = 13
    var size: CGFloat = 15
    var fill = true
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .font(.system(size: size, weight: prominent ? .bold : .regular))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .frame(maxWidth: fill ? .infinity : nil, minHeight: height)
            .foregroundStyle(prominent ? Brand.paper : Brand.ink)
            .background(shape.fill(prominent ? Brand.ink : Brand.card))
            .overlay(shape.strokeBorder(prominent ? Color.clear : ShellColor.buttonLine, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(shape)
            .pointerStyle(.link)
    }
}

/// A card: its state, its body, its buttons, the take-back or the expiry when it has one, and its own field when it
/// takes the user's words.
///
/// It never scrolls inside (A2, invariant 3): every option is on screen as the card is. Its body by its kind (#133):
/// a plan's steps and what they touch (P1Main), an action card's two lines of what goes out (CardBrief, P1Waiting) with
/// an earlier step that may already have gone out always shown in one line (#129 Codex), the rest under 「细节」; a
/// choice card's options with their numbers, its ways out and 「自己写」 (P3States). Its height as laid out goes to the
/// shell (cardLaidOut): a card taller than the pinned place stays in place in the chat, and there an approve-type option
/// takes no key (ShellModel.keyWorks).
///
/// It shows the card's one state (`phase`, CardStore): open, in the orange ring; an answer held for its take-back says
/// what was picked, with a countdown and 「撤回」; one sent waits greyed; one that ended (expired, voided) on the ended
/// card's grey with its why in a line -- an expired one offers 「现在回答」.
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
    /// It waits for the user: drawn in the orange ring with its shadow (P1Waiting), pinned or in place.
    private var waits: Bool { card.blocking && !card.isResult && phase == .open }
    /// It ended without an answer (expired, voided): the ended card (P3States 「过期或已停止」).
    private var ended: Bool { phase.ending == .expired || phase.ending == .voided }
    /// Asked again after the user changed the request (the card before it voided by a steer): the words of that change
    /// when the session has them, "" when not; nil when it was not.
    private var reasked: String? { Self.reasked(card, in: session, shell: shell) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let r = reasked { VoidStrip(words: r) }
            box
        }
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

    @ViewBuilder private var box: some View {
        let layout = self.layout
        let brief = CardBrief(layout, lang: lang)
        let shape = RoundedRectangle(cornerRadius: 16)
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(layout.title).font(.system(size: waits ? 17 : 15, weight: .bold)).lineSpacing(3)
                .foregroundStyle(ended ? CardColor.body : Brand.ink)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if ended {
                endedRow
            } else {
                if let t = layout.shownText {
                    Text(t).font(.system(size: 13)).lineSpacing(3).foregroundStyle(CardColor.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let t = textInline {
                    Text(t).font(.system(size: 13)).lineSpacing(3).foregroundStyle(CardColor.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(layout.beyond.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 13)).foregroundStyle(CardColor.body).fixedSize(horizontal: false, vertical: true)
                }
                if !layout.plan.isEmpty { PlanBody(layout: layout) }
                if let brief { BriefBlock(brief: brief) }
                // (what the two lines leave out -- the other fields, the window's text, where it acts, the card's whole
                // text -- under 「细节」: owner, #133; an earlier step that may have gone out stays above, in its line)
                if (brief?.folded ?? false) || (layout.hasDetails && textInline == nil) {
                    DisclosureGroup(isExpanded: detailsOpen) {
                        VStack(alignment: .leading, spacing: 8) {
                            if !layout.text.isEmpty && layout.text != layout.title {
                                Text(layout.text).font(.system(size: 13)).foregroundStyle(CardColor.body).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let c = layout.consent { ConsentFields(consent: c, showsAction: card.headline == nil) }
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
                if phase.ending == nil && (!layout.buttons.isEmpty || answersWithField) {
                    buttonRow(layout)
                }
                if layout.field && phase.ending == nil && !answersWithField { ownWords }
                if phase.ending == nil, let d = layout.buttons.first(where: { $0.button.role == .delegate }), layout.kind == .ambiguity || !layout.list.isEmpty {
                    Text(L("%@: it picks one itself and goes on.", d.button.text, lang: lang))
                        .font(.system(size: 12)).lineSpacing(2).foregroundStyle(ShellColor.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if phase.ending == nil, layout.consent != nil, let hint = CardLayout.consentHint(card, lang: lang) {
                    Text(hint).font(.system(size: 12)).lineSpacing(2).foregroundStyle(ShellColor.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let held = phase.pending, case .pending(_, let until) = phase { takeBackRow(held, until: until) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(ended ? CardColor.ended : Brand.card))
        // (waiting: the 2 pt orange ring outside its edge and its shadow, no grey edge -- P1Waiting; else the hairline)
        .overlay(shape.strokeBorder(waits ? Color.clear : Brand.line, lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(waits ? Brand.dot : Color.clear, lineWidth: 2).padding(-2))
        .shadow(color: waits ? Brand.ink.opacity(0.12) : Color.clear, radius: 15, y: 12)
    }

    /// A choice or missing-information card's text under its question, not folded (P3States: 「「下载」里有 [N] 个 9 月的
    /// 发票 PDF。」): it is what the question is about. nil for the others (a plan's text is its steps again).
    private var textInline: String? {
        guard layout.folds, layout.kind == .ambiguity || layout.kind == .missing, !layout.text.isEmpty, layout.text != layout.title else { return nil }
        return layout.text
    }

    /// The missing-information card answers by its own field: 「就用这个」 sends what is typed (P3States).
    private var answersWithField: Bool { layout.kind == .missing && layout.field }

    /// The card's top line (P1Waiting): while it waits, 小方 looking up and 「等你 · <种类>」 -- 「（改过，重新问）」 when it was
    /// asked again -- with 「等了 m:ss」 on the right; one that ended, 「已过期」 / 「已作废」 / 「已停止」 in grey; else its
    /// state and kind in grey; a card that does not block, its kind.
    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            if card.blocking && !card.isResult {
                if phase == .open {
                    XiaoFace(eyes: .up, size: 22)      // (P1Waiting: 小方 looking up at you, the card's fourth place)
                    let kind = Self.kindWord(card, lang: lang)
                    Text(L("Waiting for you · %@", reasked == nil ? kind : L("%@ (changed, asked again)", kind, lang: lang), lang: lang))
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(ShellColor.orangeText)
                } else if ended {
                    Text(Self.endedWord(phase, lang: lang)).font(.system(size: 13, weight: .bold)).foregroundStyle(ShellColor.secondary)
                } else {
                    Text(L("%@ · %@", ShellText.cardState(phase, lang: lang), Self.kindWord(card, lang: lang), lang: lang))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(ShellColor.secondary)
                }
            } else {
                Text(Self.kindWord(card, lang: lang)).font(.system(size: 12, weight: .semibold)).foregroundStyle(ShellColor.secondary)
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

    /// The card's buttons side by side: the primary wider (1.3 : 1 : 1, P1Waiting); a choice card's ways out equal, 40 pt
    /// (P3States); the missing-information card's 「就用这个」 first, sending its field.
    @ViewBuilder private func buttonRow(_ layout: CardLayout) -> some View {
        let choice = !layout.list.isEmpty
        if answersWithField {
            VStack(alignment: .leading, spacing: 5) {
                Text(L("Your answer", lang: lang)).font(.system(size: 12, weight: .semibold)).foregroundStyle(CardColor.body)
                TextField(L("Write your own answer", lang: lang), text: words, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Brand.card))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.ink, lineWidth: 1.5))
                    .onSubmit(sendWords)
                    .disabled(!wordsEnabled)
            }
        }
        WeightedRow(weights: (answersWithField ? [1.3] : []) + layout.buttons.map { choice ? 1 : ($0.prominent && !answersWithField ? 1.3 : 1) }) {
            if answersWithField {
                Button(L("Use this", lang: lang), action: sendWords)
                    .buttonStyle(CardButtonStyle(prominent: true))
                    .disabled(!wordsEnabled || words.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint(L("Sends what you typed as the answer", lang: lang))
            }
            ForEach(layout.buttons, id: \.index) { c in control(c) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 「自己写」 (P3States): its label, the field and an ink 「发送」.
    private var ownWords: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("Write your own", lang: lang)).font(.system(size: 12, weight: .semibold)).foregroundStyle(CardColor.body)
            HStack(spacing: 6) {
                TextField(L("Or answer in your own words", lang: lang), text: words, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Brand.card))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ShellColor.buttonLine, lineWidth: 1))
                    .onSubmit(sendWords)
                    .disabled(!wordsEnabled)
                Button(L("Send", lang: lang), action: sendWords)
                    .buttonStyle(CardButtonStyle(prominent: true, height: 40, radius: 10, size: 14, fill: false))
                    .disabled(!wordsEnabled || words.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint(L("Sends what you typed as the answer", lang: lang))
            }
        }
    }

    /// One option's control: a row of the list (a pick: its number on an ink disc, 14 px semibold, its second line), or a
    /// button; with its key (1–9) shown while the key works.
    @ViewBuilder private func control(_ c: CardLayout.Control) -> some View {
        let b = c.button
        let enabled = shell.buttonEnabled(b, card: card, in: session)
        let action = { _ = shell.click(b) }      // (the same action for a mouse click and VoiceOver's press)
        let choiceCard = !layout.list.isEmpty
        Group {
            switch c.slot {
            case .list:
                Button(action: action) {
                    HStack(alignment: .center, spacing: 10) {
                        if shell.keyWorks(card, c), let k = c.key { KeyCap(n: k) } else {
                            Circle().strokeBorder(ShellColor.buttonLine, lineWidth: 1.5).frame(width: 22, height: 22).accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.text).font(.system(size: 14, weight: .semibold)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
                            if let d = b.detail {
                                Text(d).font(.system(size: 12)).foregroundStyle(ShellColor.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Brand.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ShellColor.buttonLine, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            case .button:
                Button(action: action) {
                    HStack(spacing: 6) {
                        if shell.keyWorks(card, c), let k = c.key { KeyCap(n: k) }
                        Text(b.text)
                    }
                }
                .buttonStyle(choiceCard ? CardButtonStyle(prominent: false, height: 40, radius: 12, size: 14)
                                        : CardButtonStyle(prominent: c.prominent && !answersWithField))
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)    // (the style does not dim: the card's own)
        .focused($focusedOption, equals: c.index)
        .id(ShellModel.optionAnchor(card, c.index))
        .accessibilityLabel(b.detail.map { L("%@, %@", b.text, $0, lang: lang) } ?? b.text)
        .accessibilityHint(CardLayout.hint(c, keys: shell.keyWorks(card, c), lang: lang))
    }

    /// An ended card's line (P3States): why it no longer counts, in one line; an expired one's small 「现在回答」 while the
    /// task waits on it (it looks at the screen again and asks anew).
    @ViewBuilder private var endedRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.endedLine(phase, lang: lang)).font(.system(size: 13)).foregroundStyle(CardColor.body)
                .fixedSize(horizontal: false, vertical: true)
            if case .expired(_, let now) = phase, now == .offered || now == .asked, let ask = card.askId {
                Button(now == .asked ? L("Looking again…", lang: lang) : L("Answer now", lang: lang)) { shell.answerNow(card.runId, askId: ask) }
                    .buttonStyle(CardButtonStyle(prominent: false, height: 32, radius: 8, size: 12, fill: false))
                    .disabled(now == .asked)
                    .accessibilityHint(L("The task looks at the screen again and asks you anew", lang: lang))
            }
        }
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

    static func kindWord(_ card: CardModel, lang: ResolvedLang) -> String { card.kindWord(lang: lang) }

    /// An ended card's head (P3States): 已过期, 已作废 (the user changed the request, a newer card replaced it), 已停止.
    static func endedWord(_ phase: CardPhase, lang: ResolvedLang) -> String {
        switch phase {
        case .expired: return L("Expired", lang: lang)
        case .voided("steer"), .voided("replaced"): return L("Voided", lang: lang)
        default: return L("Task stopped", lang: lang)
        }
    }

    /// Why an ended card no longer counts, in a line: only what its phase says (never what was or wasn't done after).
    static func endedLine(_ phase: CardPhase, lang: ResolvedLang) -> String {
        switch phase {
        case .expired(_, .refused(let why)) where !why.isEmpty: return ShellText.cardState(phase, lang: lang)
        case .expired(true, _): return ShellText.cardState(phase, lang: lang)
        case .expired: return L("No answer in 10 minutes; it waits here, nothing was done", lang: lang)
        case .voided("steer"): return L("You changed the request; this card no longer counts", lang: lang)
        case .voided("replaced"): return L("A newer card replaced it", lang: lang)
        case .voided("stop"): return L("The task stopped; this card no longer counts", lang: lang)
        default: return ShellText.cardState(phase, lang: lang)
        }
    }

    /// The words of the change that voided the card before this one (P3States 「改主意后作废重问」): the card before it in
    /// its task was voided by a steer; the task's last steer, when the session has it ("" when not). nil otherwise.
    static func reasked(_ card: CardModel, in s: SessionState, shell: ShellModel) -> String? {
        guard let ask = card.askId, let t = s.task(card.runId), let i = t.cards.firstIndex(where: { $0.askId == ask }), i > 0,
              case .voided("steer") = shell.phase(card.runId, t.cards[i - 1], in: s) else { return nil }
        return t.steered.last ?? t.steersSent.last ?? ""
    }

    /// 「<状态>：<卡的种类>。<标题>。<n> 个选项」 (handoff §3.10): the title is H2's headline, else the text's first sentence.
    static func voiceOverLabel(_ card: CardModel, phase: CardPhase, lang: ResolvedLang) -> String {
        let state = ShellText.cardState(phase, lang: lang)
        let kind = kindWord(card, lang: lang)
        return L("%@: %@. %@. %d options", state, kind, card.headline ?? firstSentence(card.text), card.buttons.count, lang: lang)
    }

    /// The text up to its first sentence end (for VoiceOver; the whole card stays readable inside).
    static func firstSentence(_ text: String) -> String {
        let ends: Set<Character> = ["。", "！", "？", ".", "!", "?", "\n"]
        guard let i = text.firstIndex(where: { ends.contains($0) }) else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(text[..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Over a card asked again (P3States): 「已作废」 and the change that voided the one before, struck through.
struct VoidStrip: View {
    let words: String
    @Environment(\.lang) private var lang
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(L("Voided", lang: lang)).font(.system(size: 12, weight: .bold)).foregroundStyle(CardColor.body)
            if !words.isEmpty {
                Text(L("You said 「%@」", words, lang: lang)).font(.system(size: 12)).strikethrough().foregroundStyle(ShellColor.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(CardColor.strip))
        .accessibilityElement(children: .combine)
    }
}

/// An action card's two lines (P1Waiting 「要发出去的」, owner #133): what goes out and to whom, then the next field and
/// the site; under them, always, an earlier step that may already have gone out, in one line (#129 Codex).
struct BriefBlock: View {
    let brief: CardBrief
    @Environment(\.lang) private var lang
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if brief.lead != nil || !brief.context.isEmpty {
                Text(L("What goes out", lang: lang)).font(.system(size: 12, weight: .semibold)).foregroundStyle(ShellColor.secondary)
            }
            if let lead = brief.lead {
                HStack(alignment: .center, spacing: 10) {
                    Text(verbatim: "「" + lead + "」").font(.system(size: 15, weight: .bold)).foregroundStyle(Brand.ink).lineLimit(2)
                    if let to = brief.leadTo {
                        Arrow().stroke(Brand.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                            .frame(width: 18, height: 10).accessibilityHidden(true)
                        let (name, address) = Self.split(to.value)
                        Text(name).font(.system(size: 15, weight: .bold)).foregroundStyle(Brand.ink).lineLimit(1)
                        if let address { Text(address).font(.system(size: 13)).foregroundStyle(ShellColor.secondary).lineLimit(1) }
                    }
                }
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(brief.leadLine ?? lead)
            }
            if !brief.context.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    ForEach(Array(brief.context.enumerated()), id: \.offset) { _, p in
                        (Text(p.label).foregroundColor(ShellColor.secondary) + Text(" " + p.value).foregroundColor(CardColor.body))
                            .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    }
                }
                .textSelection(.enabled)
            }
            if let w = brief.warning {
                Text(w).font(.system(size: 12, weight: .semibold)).foregroundStyle(ShellColor.orangeText).lineLimit(1).truncationMode(.tail)
                    .help(w).accessibilityLabel(w)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.paper))
    }

    /// 「name <address>」 as the board draws it: the name strong, the address quiet (a mail field's own form, whatever
    /// app); anything else whole.
    static func split(_ v: String) -> (String, String?) {
        guard v.hasSuffix(">"), let lt = v.lastIndex(of: "<"), lt > v.startIndex else { return (v, nil) }
        let name = v[..<lt].trimmingCharacters(in: .whitespaces)
        let address = v[v.index(after: lt)..<v.index(before: v.endIndex)].trimmingCharacters(in: .whitespaces)
        return name.isEmpty || address.isEmpty ? (v, nil) : (name, address)
    }

    /// P1Waiting's arrow, 18 × 10.
    struct Arrow: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX + 1, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX - 1, y: r.midY))
            p.move(to: CGPoint(x: r.maxX - 5, y: r.minY + 1)); p.addLine(to: CGPoint(x: r.maxX - 1, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX - 5, y: r.maxY - 1))
            return p
        }
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
            // (P1Waiting: the card that waits for you draws its own orange ring and shadow)
            CardView(shell: shell, card: card, phase: phase, askedAt: askedAt, session: session)
                .id(ShellModel.cardKey(card))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else {
            HStack(spacing: 8) {
                Text(L("Waiting for you", lang: lang)).font(.system(size: 12, weight: .bold)).foregroundStyle(ShellColor.orangeText)
                Text(CardLayout(card).title).font(.system(size: 13)).foregroundStyle(Brand.ink).lineLimit(1)
                Spacer()
                Button(L("Go to the card", lang: lang)) { jump(TaskRow.cardAnchor(card)) }
                    .buttonStyle(InkButtonStyle(prominent: false, small: true))
                    .accessibilityHint(L("Scrolls the chat to the card", lang: lang))
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.dot, lineWidth: 1.5))
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

/// An option's key, beside it (P3States): its number on an ink disc, 22 pt (decorative: VoiceOver reads the key in the
/// control's hint).
struct KeyCap: View {
    let n: Int
    var body: some View {
        Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(Brand.paper)
            .frame(width: 22, height: 22).background(Circle().fill(Brand.ink))
            .accessibilityHidden(true)
    }
}

/// A card no longer pinned (U3, #133). While another card waits (P1Waiting): one line -- a green check, its kind, what was
/// picked, how and when it closed (ShellText.cardSummary) -- a plan's opening to its steps. Otherwise (P1Main): an
/// agreed plan whole, with 「✓ 你已同意 · 10:42」 and 「收起」; an answered choice card with its options, the picked one
/// outlined; any other answered card small -- its kind and 「✓ 你选了 …」 (P3States); one that ended, the ended card.
struct AnsweredRow: View {
    let card: CardState
    let runId: String
    let phase: CardPhase
    /// Another card waits in this conversation: the line.
    var compact = false
    @Environment(\.lang) private var lang
    @State private var open = false
    @State private var folded = false

    var body: some View {
        let s = ShellText.cardSummary(card, phase: phase, runId: runId, lang: lang)
        let model = CardModel(card: card.card, runId: runId, askId: card.askId)
        let layout = CardLayout(model)
        let agreedPlan = phase == .answered && model.kind == .plan && !layout.plan.isEmpty && picked(model)?.role == .approve
        let pickedChoice = phase == .answered && !layout.list.isEmpty ? picked(model) : nil
        Group {
            if compact || folded {
                line(s, plan: agreedPlan ? layout : nil)
            } else if agreedPlan {
                planCard(layout, tail: s.tail)
            } else if let p = pickedChoice, p.role == .choice {
                choiceCard(layout, picked: p, tail: s.tail)
            } else if phase.ending == .expired || phase.ending == .voided {
                endedCard(layout)
            } else {
                smallCard(s)
            }
        }
        .frame(maxWidth: 600, alignment: .leading)
    }

    /// The option the executor applied (CardState.answer), when it was one.
    private func picked(_ m: CardModel) -> CardModel.Button? {
        guard case .option(let i)? = card.answer else { return nil }
        return m.buttons.first { $0.index == i }
    }

    /// P1Waiting: 「✓ 回哪一封　10 月 20 日…　你选的」 on the card colour.
    private func line(_ s: ShellText.CardSummary, plan: CardLayout?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                mark
                (Text(s.kind).fontWeight(.semibold).foregroundColor(Brand.ink)
                 + Text(s.pick.map { "  " + $0 } ?? "").foregroundColor(CardColor.body))
                    .font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(s.tail).font(.system(size: 13)).foregroundStyle(ShellColor.secondary).lineLimit(1)
                if let plan {
                    Button(open ? L("Collapse", lang: lang) : L("Expand", lang: lang)) {
                        if folded { folded = false } else { open.toggle() }
                    }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(ShellColor.secondary)
                    .accessibilityLabel(open ? L("Collapse", lang: lang) : L("Expand", lang: lang))
                    .accessibilityHint(L("Shows the plan's steps", lang: lang))
                }
            }
            if open, let plan { PlanBody(layout: plan) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ShellColor.softLine))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.line)
    }

    /// The check of an answered card; a dash for one that ended without an answer.
    @ViewBuilder private var mark: some View {
        if phase == .answered {
            CheckMark().stroke(ShellColor.ok, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 14, height: 14).accessibilityHidden(true)
        } else {
            Capsule().fill(ShellColor.secondary).frame(width: 10, height: 2).frame(width: 14, height: 14).accessibilityHidden(true)
        }
    }

    /// P1Main's agreed plan: 「计划」, the green 「✓ 你已同意 · 10:42」 and 「收起」; its steps and what they touch.
    private func planCard(_ layout: CardLayout, tail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L("Plan", lang: lang)).font(.system(size: 14, weight: .bold)).foregroundStyle(Brand.ink)
                HStack(spacing: 5) {
                    CheckMark().stroke(CardColor.okText, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                        .frame(width: 11, height: 11).accessibilityHidden(true)
                    Text(tail)
                }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(CardColor.okText)
                .padding(.horizontal, 9).frame(height: 22)
                .background(Capsule().fill(CardColor.okTint))
                Spacer()
                Button(L("Collapse", lang: lang)) { folded = true; open = false }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(ShellColor.orangeText)
                    .accessibilityHint(L("Shows the plan in one line", lang: lang))
            }
            PlanBody(layout: layout)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    /// P1Main's answered choice card: its question and 「10:41 你选了」; the picked option outlined in ink with its check,
    /// the others quiet.
    private func choiceCard(_ layout: CardLayout, picked: CardModel.Button, tail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(layout.title).font(.system(size: 14, weight: .bold)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(tail).font(.system(size: 12)).foregroundStyle(ShellColor.secondary)
            }
            ForEach(layout.list, id: \.index) { c in
                let mine = c.index == picked.index
                HStack(spacing: 10) {
                    if mine {
                        CheckMark().stroke(Brand.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .frame(width: 14, height: 14).accessibilityHidden(true)
                    }
                    Text(c.button.text).font(.system(size: 13, weight: mine ? .semibold : .regular)).foregroundStyle(mine ? Brand.ink : ShellColor.secondary)
                    Spacer(minLength: 4)
                    if mine, let d = c.button.detail { Text(d).font(.system(size: 13)).foregroundStyle(ShellColor.secondary).lineLimit(1) }
                }
                .padding(.leading, mine ? 10 : 34).padding(.trailing, 10).padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(mine ? Brand.ink : CardColor.rule, lineWidth: mine ? 1.5 : 1))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    /// P3States' answered card: its kind, then 「✓ 你选了 … · 10:41」.
    private func smallCard(_ s: ShellText.CardSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(s.kind).font(.system(size: 12, weight: .bold)).foregroundStyle(CardColor.body).lineLimit(1)
            HStack(spacing: 6) {
                mark
                Text(s.pick.map { L("%@ · %@", $0, s.tail, lang: lang) } ?? s.tail).font(.system(size: 13, weight: .bold)).foregroundStyle(Brand.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(s.line)
    }

    /// P3States' ended card: 「已过期」 / 「已作废」 / 「已停止」, its question, why in a line.
    private func endedCard(_ layout: CardLayout) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(CardView.endedWord(phase, lang: lang)).font(.system(size: 12, weight: .bold)).foregroundStyle(ShellColor.secondary)
            Text(layout.title).font(.system(size: 13, weight: .bold)).foregroundStyle(CardColor.body).fixedSize(horizontal: false, vertical: true)
            Text(CardView.endedLine(phase, lang: lang)).font(.system(size: 12)).foregroundStyle(CardColor.body).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(CardColor.ended))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// The boards' check, 14 × 14 (「M3 7.5l2.6 2.6L11 4.5」).
struct CheckMark: Shape {
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height) / 14
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 3 * s, y: r.minY + 7.5 * s))
        p.addLine(to: CGPoint(x: r.minX + 5.6 * s, y: r.minY + 10.1 * s))
        p.addLine(to: CGPoint(x: r.minX + 11 * s, y: r.minY + 4.5 * s))
        return p
    }
}

/// A plan's steps as P1Main draws them: numbered, 13 px; under a rule, what they touch with words for what changes your
/// things and what goes out (never colour alone, handoff §3.10), the sites, what goes to them, and whether anything comes
/// to the front -- each under its 52 pt label.
struct PlanBody: View {
    let layout: CardLayout
    @Environment(\.lang) private var lang
    var body: some View {
        let rows = layout.plan
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(rows, id: \.n) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(r.n).").frame(minWidth: 14, alignment: .trailing)
                        Text(r.purpose).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 13)).lineSpacing(13 * 0.55 - 3).foregroundStyle(CardColor.body)
                    .accessibilityElement(children: .combine)
                }
            }
            let touched = rows.filter { !$0.objects.isEmpty || $0.changesYours || $0.sendsOut }
            let sites = Array(Set(rows.flatMap(\.sites).map(\.host))).sorted()
            let sends = rows.flatMap(\.sites).compactMap { s in s.sends.map { (s.host, $0) } }
            if !touched.isEmpty || !sites.isEmpty || !sends.isEmpty || layout.foregroundKnown {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(touched.enumerated()), id: \.offset) { i, r in
                        labelled(i == 0 ? L("Touches", lang: lang) : "") {
                            HStack(spacing: 8) {
                                Text(r.objects.isEmpty ? r.purpose : r.objects.joined(separator: "、")).fixedSize(horizontal: false, vertical: true)
                                if r.changesYours { tag(L("Changes your things", lang: lang), out: false) }
                                if r.sendsOut { tag(L("Sends out, confirmed then", lang: lang), out: true) }
                            }
                        }
                    }
                    if !sites.isEmpty { labelled(L("Site", lang: lang)) { Text(sites.joined(separator: "、")) } }
                    ForEach(Array(sends.enumerated()), id: \.offset) { i, s in
                        labelled(i == 0 ? L("Sends", lang: lang) : "") { Text(s.1).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true) }
                    }
                    if layout.foregroundKnown {
                        labelled(L("Front", lang: lang)) {
                            Text(layout.foreground.isEmpty ? L("All in background windows: nothing comes to the front, you can keep using the Mac", lang: lang)
                                                           : L("Comes to the front: %@", layout.foreground.joined(separator: "、"), lang: lang))
                                .foregroundStyle(CardColor.body)
                        }
                    }
                }
                .font(.system(size: 13)).foregroundStyle(Brand.ink)
                .padding(.top, 8)
                .overlay(alignment: .top) { Rectangle().fill(CardColor.rule).frame(height: 1) }
            }
        }
    }
    private func labelled(_ label: String, @ViewBuilder _ value: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(ShellColor.secondary).frame(width: 52, alignment: .leading)
            value()
        }
        .accessibilityElement(children: .combine)
    }
    /// P1Main's tags: 「改你的东西」 in an ink outline, 「往外发，到时再确认」 on the orange tint (words, never colour alone).
    private func tag(_ text: String, out: Bool) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(out ? ShellColor.orangeText : Brand.ink)
            .padding(.horizontal, 7).frame(height: 20)
            .background(Capsule().fill(out ? ShellColor.waitRow : Color.clear))
            .overlay(Capsule().strokeBorder(out ? Color.clear : Brand.ink, lineWidth: 1))
            .fixedSize()
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
                ForEach(Array(b.selected.enumerated()), id: \.offset) { _, o in pair(L("Selected", lang: lang), o.shown) }
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
