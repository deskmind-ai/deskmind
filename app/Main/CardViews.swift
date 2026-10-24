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
/// Its header and its buttons stay put; its body — which the harness does not cap (a send list can be long) — scrolls
/// inside `bodyCap`. An approve-type option (CardModel.Role.needsWholeBody) takes a click (or its key) only once the
/// body's end has been on screen (it fits, or it was scrolled to the end): never approve what was never shown
/// (ShellModel.cardBody, from the scroll geometry alone).
///
/// It shows the card's one state (`phase`, CardStore): an answer held for its take-back says what was picked, with a
/// countdown and 「撤回」; one sent waits greyed; an expired card keeps its text, drops its options and offers 「现在回答」.
struct CardView: View {
    @ObservedObject var shell: ShellModel
    let card: CardModel
    let phase: CardPhase
    let askedAt: Double?
    let session: SessionState
    let bodyCap: Double
    @Environment(\.lang) private var lang
    @State private var words = ""
    @State private var visible: Double = 0
    @State private var content: Double = 0
    @State private var offset: Double = 0

    private var layout: CardLayout { CardLayout(card) }
    private var wordsEnabled: Bool { shell.wordsEnabled(card, in: session) }
    private var seen: Bool { shell.bodySeen.contains(ShellModel.cardKey(card)) }

    var body: some View {
        let layout = self.layout
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if card.blocking && !card.isResult {
                    Text(phase == .open ? L("Waiting for you", lang: lang) : ShellText.cardState(phase, lang: lang))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(phase.ending == nil ? ShellColor.orangeText : ShellColor.secondary)
                }
                Text(ShellText.cardKind(card.kind.name, lang: lang)).font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(card.text).font(.system(size: 13)).foregroundStyle(Brand.ink).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !layout.plan.isEmpty { PlanSteps(rows: layout.plan, foreground: layout.foreground) }
                    if let c = layout.consent { ConsentFields(consent: c) }
                    if !layout.list.isEmpty && phase.ending == nil {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(layout.list, id: \.index) { c in control(c) }
                        }
                    }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: CardBodyGeometry.self,
                                           value: [g.size.height, -g.frame(in: .named(coordinateSpace)).minY])
                })
            }
            .coordinateSpace(name: coordinateSpace)
            .frame(minHeight: min(CardBody.minHeight, content), maxHeight: min(bodyCap, max(content, 1)))
            .background(GeometryReader { g in Color.clear.preference(key: CardBodyVisible.self, value: g.size.height) })
            .onPreferenceChange(CardBodyGeometry.self) { v in
                if v.count == 2 { content = v[0]; offset = v[1]; reportBody() }
            }
            .onPreferenceChange(CardBodyVisible.self) { h in visible = h; reportBody() }
            if phase.ending == nil {
                HStack(spacing: 8) {
                    ForEach(layout.buttons, id: \.index) { c in control(c) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let held = phase.pending, case .pending(_, let until) = phase { takeBackRow(held, until: until) }
            if case .expired(_, let now) = phase { expiredRow(now) }
            if phase.takesPick && !seen && card.buttons.contains(where: { $0.role.needsWholeBody }) {
                // (neutral: it holds the card's own field too, for someone who wants to type)
                Text(L("Read the whole card first: scroll to its end", lang: lang))
                    .font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
            }
            if layout.field && phase.ending == nil {
                HStack(spacing: 8) {
                    // (on a card with an approve-type option, words wait for the whole body as its approve does)
                    TextField(L("Or answer in your own words", lang: lang), text: $words, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendWords)
                        .disabled(!wordsEnabled)
                        .accessibilityHint(!wordsEnabled && ShellModel.wordsWaitForBody(card) && !seen
                                           ? L("Read the whole card first: scroll to its end", lang: lang) : "")
                    Button(L("Send", lang: lang), action: sendWords).buttonStyle(InkButtonStyle(prominent: false))
                        .disabled(!wordsEnabled || words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(card.blocking && (phase.ending == nil || phase.isExpiredOffer) ? Brand.dot : Brand.line, lineWidth: 1.2))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.voiceOverLabel(card, phase: phase, lang: lang))
        // (a click anywhere on it is a move into it: card mode, its keys on — CardKeys; when it came on screen)
        .simultaneousGesture(TapGesture().onEnded { shell.enterCardMode(card) })
        .onAppear { shell.cardShown(card) }
        .onDisappear { shell.cardHidden(card) }
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
                    HStack(spacing: 8) {
                        if shell.keyWorks(card, c), let k = c.key { KeyCap(n: k) }
                        Text(b.text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Brand.line))
            case .button:
                Button(action: action) {
                    HStack(spacing: 6) {
                        if shell.keyWorks(card, c), let k = c.key { KeyCap(n: k) }
                        Text(b.text)
                    }
                }
                .buttonStyle(InkButtonStyle(prominent: c.prominent))
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)    // (InkButtonStyle does not dim: the card's own)
        .accessibilityLabel(b.text)
        .accessibilityHint(b.role.needsWholeBody && !seen ? L("Read the whole card first: scroll to its end", lang: lang) : CardLayout.hint(c, keys: shell.keyWorks(card, c), lang: lang))
    }

    /// The answer held for its take-back: what was picked, the seconds left, and 「撤回」 (the words come back to the
    /// field). Picking another option starts over; 「先别做了」 and Stop are not held.
    @ViewBuilder private func takeBackRow(_ held: CardAnswer, until: Double) -> some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let left = max(0, Int((until - shell.now()).rounded(.up)))
                Text(L("Picked: %@ · sends in %d s", Self.picked(held, card: card), left, lang: lang))
                    .font(.system(size: 12)).foregroundStyle(ShellColor.orangeText)
            }
            Button(L("Take back", lang: lang)) {
                if case .text(_, _, let w) = held { words = w }
                shell.takeBack(card)
            }
            .buttonStyle(InkButtonStyle(prominent: false))
            .accessibilityHint(L("Your pick is not sent; the card waits again", lang: lang))
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

    private var coordinateSpace: String { "cardBody/" + ShellModel.cardKey(card) }

    private func reportBody() {
        shell.cardBody(card, contentHeight: content, visibleHeight: visible, offset: offset)
    }

    private func sendWords() {
        guard wordsEnabled else { return }
        shell.answer(card, text: words)
        words = ""
    }

    /// 「<状态>：<卡的种类>。<正文第一句>。<n> 个选项」 (handoff §3.10).
    static func voiceOverLabel(_ card: CardModel, phase: CardPhase, lang: ResolvedLang) -> String {
        let state = ShellText.cardState(phase, lang: lang)
        let kind = ShellText.cardKind(card.kind.name, lang: lang)
        return L("%@: %@. %@. %d options", state, kind, firstSentence(card.text), card.buttons.count, lang: lang)
    }

    /// The text up to its first sentence end (for VoiceOver; the whole card stays readable inside).
    static func firstSentence(_ text: String) -> String {
        let ends: Set<Character> = ["。", "！", "？", ".", "!", "?", "\n"]
        guard let i = text.firstIndex(where: { ends.contains($0) }) else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(text[..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
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

/// A plan card's steps (card.plan): what each does, what it touches, the sites it opens and what goes to them, with
/// words for what changes the user's things and what goes out (never colour alone, handoff §3.10).
struct PlanSteps: View {
    let rows: [CardLayout.PlanRow]
    let foreground: [String]
    @Environment(\.lang) private var lang
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.n) { r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(r.n).").font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.ink)
                        Text(r.purpose).font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if r.changesYours { tag("pencil", L("Changes your things", lang: lang)) }
                    if r.sendsOut { tag("paperplane", L("Sends something out", lang: lang)) }
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
    private func tag(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.system(size: 11)).foregroundStyle(ShellColor.orangeText)
    }
    private func line(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(ShellColor.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// An action card's fields (card.consent): the action, what it acts on, the site, and every line of what goes out.
struct ConsentFields: View {
    let consent: CardLayout.Consent
    @Environment(\.lang) private var lang
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !consent.action.isEmpty { row(L("Action", lang: lang), consent.action) }
            if !consent.object.isEmpty { row(L("On", lang: lang), consent.object) }
            if let site = consent.site, !site.isEmpty { row(L("Site", lang: lang), site) }
            if !consent.outgoing.isEmpty {
                Label(L("What goes out", lang: lang), systemImage: "paperplane").font(.system(size: 11)).foregroundStyle(ShellColor.orangeText)
                ForEach(Array(consent.outgoing.enumerated()), id: \.offset) { _, o in row(o.label, o.value) }
            }
        }
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
            Text(value).font(.system(size: 12)).foregroundStyle(Brand.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The 1–9 keys on the pinned card (handoff §3.7): a key-down in the window this view is in, while that window is the
/// key window and no field is being typed in, with no ⌘ ⌃ ⌥ (CardKeys); handed to `onKey`, and swallowed only when it
/// picked something. It never takes the focus and never brings anything forward.
struct CardKeyMonitor: NSViewRepresentable {
    /// Every key-down of this window, with what the gate needs; true: consumed (it picked).
    let onKey: (_ characters: String?, _ commandLike: Bool, _ mainWindowIsKey: Bool, _ editingText: Bool, _ isRepeat: Bool, _ composing: Bool) -> Bool
    /// The window stopped being the key one, closed, or the app went to the back: card mode ends.
    let onLeave: () -> Void

    func makeNSView(context: Context) -> NSView { Watcher(onKey: onKey, onLeave: onLeave) }
    func updateNSView(_ v: NSView, context: Context) { (v as? Watcher)?.onKey = onKey; (v as? Watcher)?.onLeave = onLeave }
    static func dismantleNSView(_ v: NSView, coordinator: ()) { (v as? Watcher)?.stop() }

    final class Watcher: NSView {
        var onKey: (String?, Bool, Bool, Bool, Bool, Bool) -> Bool
        var onLeave: () -> Void
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        init(onKey: @escaping (String?, Bool, Bool, Bool, Bool, Bool) -> Bool, onLeave: @escaping () -> Void) {
            self.onKey = onKey; self.onLeave = onLeave; super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let win = window else { return }
            // (observed, never acted on: nothing here moves the focus or a window)
            let c = NotificationCenter.default
            for (name, object) in [(NSWindow.didResignKeyNotification, win as AnyObject?), (NSWindow.willCloseNotification, win),
                                   (NSApplication.didResignActiveNotification, nil)] {
                observers.append(c.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in self?.onLeave() })
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                // (every key-down goes to the model, a digit or not: the typing guard counts them all)
                let composing = (w.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false     // (an input method's candidates up)
                let picked = self.onKey(e.charactersIgnoringModifiers, !e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                                        w.isKeyWindow, w.firstResponder is NSText, e.isARepeat, composing)
                return picked ? nil : e
            }
        }

        func stop() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers = []
        }
        deinit { stop() }
    }
}
