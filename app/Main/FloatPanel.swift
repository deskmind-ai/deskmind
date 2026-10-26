// The float (A5) and a chat task's island and notifications (A7), drawn by the main app: while the main window is not
// in front, the running task's picture, its line and its card in a panel in the corner -- answerable there when it
// fits (CardPlacement), else its title and 「去主窗口回答」. It never becomes the key window and never activates the app
// (a nonactivating panel, shown through Activation.showPanel; its buttons act without taking the focus); the one way
// it brings DeskMind forward is the user's own click on 「去主窗口回答」 (Activation.onClick). What it shows is the
// same card state the chat reads (CardStore, through ShellModel). Whether it is up is FloatPolicy's; whether it can
// be seen is the panel's own fact, which placement takes and which never comes back to the policy.

import AppKit
import SwiftUI
import UserNotifications

/// The notification center, for CardNotices (ids by card and run; no actions on them: a click opens DeskMind).
final class SystemNotifier: CardNotifier {
    func post(id: String, title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
    func remove(ids: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
    func delivered(_ done: @escaping ([String]) -> Void) {
        UNUserNotificationCenter.current().getDeliveredNotifications { ns in
            let ids = ns.map(\.request.identifier)
            DispatchQueue.main.async { done(ids) }
        }
    }
}

/// The island for a chat task: the goals' surface, with its notifications CardNotices' (ids that can be taken away).
final class ChatIslandSurface: IslandSurface {
    var owner: ObjectIdentifier?
    private let base = RunOverlaySurface.shared
    /// "Show Details": the window on this task's conversation (its task message, the right column).
    private let details: () -> Void
    init(details: @escaping () -> Void) { self.details = details }
    func requestNotifications() { base.requestNotifications() }
    func show(title: String, line: String, onStop: @escaping () -> Void) {
        base.show(title: title, line: line, onStop: onStop)
        MainActor.assumeIsolated { RunOverlay.shared.onDetails = details }
    }
    func update(step: Int, line: String) { base.update(step: step, line: line) }
    func apply(_ frame: IslandFrame) { base.apply(frame) }
    func setAsking(_ on: Bool) { base.setAsking(on) }
    func finish(passed: Bool, stopped: Bool, summary: String) {
        // (its end's notification is CardNotices', by run: none of the island's own, never removed -- #125 review)
        MainActor.assumeIsolated {
            let o = RunOverlay.shared
            if stopped { o.model.stoppedByUser = true }
            o.finish(passed: passed, summary: summary, notify: false)
        }
    }
    func notify(title: String, body: String) {}       // (CardNotices posts them, by id)
    var appActive: Bool { base.appActive }
    var userTyping: Bool { base.userTyping }
}

/// A click on the running task's bar (the Island board's 「点一下」): the window in front, its conversation shown; the
/// float collapsed by the user, opened again (the window left where it is); else the window, on the task, in front.
@MainActor
func islandTapped(_ g: UserGesture, sessionId: String, shell: ShellModel?) {
    let f = FloatController.shared
    if f.monitor.window == .front { shell?.select(sessionId); return }
    if f.userCollapsed { f.userCollapsed = false; return }
    shell?.select(sessionId)
    MainWindow.comeBack(g)
}

/// A panel that never becomes the key or the main window.
final class FloatNSPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One per app, whatever happens to the main window (#125 review at 31cb375: owned by the window's view, ⌘W -- the
/// case the float is for -- froze it on screen and stopped its notifications, and a reopened window made a second): it
/// drives itself, every half second and on every change of the window seen, from `start`, once.
@MainActor
final class FloatController: ObservableObject {
    static let shared = FloatController()
    private weak var shell: ShellModel?
    /// The app's one view of the main window's state (the right column's dock reads it too).
    let monitor = FrontmostMonitor()
    private var timer: Timer?

    /// Installs the float and starts driving it, once (later calls do nothing).
    func start(_ shell: ShellModel) {
        guard self.shell == nil else { return }
        self.shell = shell
        install(shell)
        monitor.onRaw = { [weak self] in self?.drive() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.drive() } }
        drive()
    }

    private func drive() {
        guard let shell else { return }
        update(shell, window: monitor.window, frontNow: FrontmostMonitor.observe() == .front, lang: AppLanguage.current())
    }

    /// Whether the float takes an answer this moment: the window's state now, not the last tick's (#125 review: after
    /// the window came forward the float answered for up to 0.75 s while the chat did too).
    func answersNow() -> Bool {
        guard let n = now, let card = n.card, let phase = n.phase else { return false }
        let p = CardPlacement.place(phase, fitsFloat: fits(card), window: monitor.window,
                                    frontNow: FrontmostMonitor.observe() == .front, float: visibility())
        return p.takesAnswer && p.shown == .floatCard
    }
    /// What the float shows now (FloatView reads it).
    struct Now {
        var sessionId: String
        var status: SessionStatus
        var task: TaskState
        var card: CardModel?
        var phase: CardPhase?
        var placement: CardPlacement?
    }
    @Published private(set) var now: Now?
    /// For the offscreen render only (tests/snapshot): this state, as `update` would set it.
    func preview(_ n: Now?) { now = n }
    @Published var userCollapsed = false
    let dock = LiveDock()
    private let notices = CardNotices(SystemNotifier())
    private var islands: [String: IslandApplier] = [:]
    private var ended: Set<String> = []
    private var panel: FloatNSPanel?
    private var cleaned = false
    private var lastCard: String?
    /// When the panel was put up: its occlusion is not known at once, and no notification is posted until it is.
    private var shownAt: Date?
    /// Each card's whole content's height as the float lays it out (FloatCard measures it): whether it fits the float.
    private var cardHeights: [String: Double] = [:]
    func cardLaidOut(_ card: CardModel, height: Double) {
        let k = ShellModel.cardKey(card)
        guard cardHeights[k] != height else { return }
        cardHeights[k] = height
        // (laid out anew: placed and sized now, not on the next tick -- #125 delta check)
        if let shell { update(shell, window: monitor.window, frontNow: FrontmostMonitor.observe() == .front, lang: AppLanguage.current()) }
    }
    /// The float's room for its card now: its share of the screen it is on, less its header, picture and step line
    /// (when they show) -- judged against what the panel has, not a constant (#125 delta check: a short screen).
    private var cardRoom: Double {
        let screen = (panel?.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 600
        // (its title bar 36, the picture 116, its foot 36 and a row of buttons 54: P1Float -- a card is always drawn in
        // the whole float, never the capsule: FloatPolicy.collapsed)
        let chrome = 36 + 116 + 36 + 54
        return max(0, Double(screen) * 0.7 - Double(chrome))
    }
    private func fits(_ card: CardModel) -> Bool {
        CardPlacement.fitsFloat(structure: card.answerableInFloat, height: cardHeights[ShellModel.cardKey(card)], room: cardRoom)
    }
    static let width: CGFloat = 304

    /// The state of the window and the sessions changed (or a second went by): the float, the island, the notifications.
    func update(_ shell: ShellModel, window: MainWindowState, frontNow: Bool, lang: ResolvedLang) {
        let t = Date().timeIntervalSince1970
        // the running task, whichever conversation the window shows (one computer task at a time)
        let running = shell.states.first { $0.value.runningTask != nil }
        if !cleaned {
            cleaned = true
            let waiting = Set(shell.states.values.compactMap { shell.pinned($0)?.card.askId })
            notices.cleanUp(waiting: waiting)
        }
        // tasks that ended: their island finishes; their end is said when nobody looked
        for s in shell.states.values {
            for task in s.tasks where task.ended && !ended.contains(task.runId) {
                ended.insert(task.runId)
                // (only a task this float followed: its island finishes, its end is said when nobody looked)
                if let a = islands.removeValue(forKey: task.runId) {
                    a.apply(IslandFeed.frame(task, pinned: nil, lang: lang), title: task.raw, lang: lang, onStop: {})
                    notices.ended(task.runId, title: L("DeskMind", lang: lang), body: ShellText.task(task, lang: lang), seen: window == .front)
                }
            }
        }
        if window == .front { for r in ended { notices.ended(r, title: "", body: "", seen: true) } }
        // (forgotten once their runs are gone from every session)
        let known = Set(shell.states.values.flatMap { $0.tasks.map(\.runId) })
        ended = ended.filter(known.contains)
        islands = islands.filter { known.contains($0.key) }
        guard let (sid, s) = running, let task = s.runningTask else {
            now = nil; dock.watch(nil); show(.hidden)
            notices.card(nil, placement: nil, title: "", body: "", now: t)
            return
        }
        let pinned = shell.pinned(s)
        let island = islands[task.runId] ?? {
            let a = IslandApplier(ChatIslandSurface(details: { [weak shell] in shell?.select(sid) }))
            islands[task.runId] = a; return a
        }()
        let card = pinned.map { CardModel(card: $0.card.card, runId: $0.runId, askId: $0.card.askId) }
        let waiting = pinned.map { $0.phase.ending == nil || $0.phase.isExpiredOffer } ?? false
        // a new card opens a float the user collapsed (§1.4)
        if let a = pinned?.card.askId, a != lastCard, waiting { userCollapsed = false }
        lastCard = pinned?.card.askId
        let policy = FloatPolicy.shown(window: window, taskActive: true, cardWaiting: waiting, userCollapsed: userCollapsed,
                                       poppedOut: shell.poppedOut.contains(sid))
        show(policy)
        let fact = visibility()
        var placement: CardPlacement?
        if let p = pinned, let card {
            let pl = CardPlacement.place(p.phase, fitsFloat: fits(card), window: window, frontNow: frontNow, float: fact,
                                         notified: notices.notified(p.card.askId, now: t))
            placement = pl
            // (logged once it can be seen: the panel on screen and not covered)
            switch fact == .visible ? pl.shown : .ended {
            case .floatCard: shell.cardPlaced(card, place: .float, in: s)
            case .floatSummary: shell.cardPlaced(card, place: .floatSummary, in: s)
            default: break
            }
            // (just put up: whether it can be seen is not known yet -- no notification until it is)
            let settling = shownAt.map { Date().timeIntervalSince($0) < 0.3 } ?? false
            if !settling {
                notices.card(p.card.askId, placement: pl, title: L("DeskMind", lang: lang),
                             body: p.phase.isExpiredOffer ? "" : CardLayout(card).title, now: t)
            }
        } else {
            notices.card(nil, placement: nil, title: "", body: "", now: t)
        }
        // the bar: the task's app, and whether the float shows its card (the bar then names the card's kind only)
        let floatShows = fact == .visible && (placement?.shown == .floatCard || placement?.shown == .floatSummary)
        island.apply(IslandFeed.frame(task, pinned: pinned.map { ($0.card, $0.phase) }, app: AgentPanel.appName(task.steps.last?.object),
                                      floatShows: floatShows, lang: lang), title: task.raw, lang: lang,
                     onStop: { shell.stop(sessionId: sid, runId: task.runId) })
        RunOverlay.shared.onTap = { [weak shell] g in islandTapped(g, sessionId: sid, shell: shell) }
        now = Now(sessionId: sid, status: s.status, task: task, card: card, phase: pinned?.phase, placement: placement)
        // (only the card in view keeps its height)
        let keep = card.map(ShellModel.cardKey)
        if cardHeights.keys.contains(where: { $0 != keep }) { cardHeights = cardHeights.filter { $0.key == keep } }
        // (sized to what it shows now)
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.show(policy) } }
        // the float's own picture: a second watcher while it can be seen (the helper takes one picture for both)
        dock.watch(policy == .open && fact == .visible ? task.runId : nil)
    }

    /// The panel's own fact: on screen and not covered (a full-screen app, another Space, another display asleep:
    /// not seen). Not up: hidden.
    private func visibility() -> CardPlacement.Float {
        guard let p = panel, p.isVisible else { return .hidden }
        guard p.screen != nil else { return .unknown }
        return p.occlusionState.contains(.visible) && p.isOnActiveSpace ? .visible : .hidden
    }

    private func show(_ s: FloatPolicy.Shown) {
        guard s != .hidden else { panel?.orderOut(nil); shownAt = nil; return }
        let p = panel ?? makePanel()
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
        let size = (p.contentView?.fittingSize).map { NSSize(width: Self.width, height: min($0.height, visible.height * 0.7)) } ?? NSSize(width: Self.width, height: 240)
        let frame = NSRect(x: visible.maxX - size.width - 18, y: visible.minY + 18, width: size.width, height: size.height)
        if p.frame != frame { p.setFrame(frame, display: true) }
        if !p.isVisible { Activation.showPanel(p); shownAt = Date() }
    }

    private func makePanel() -> FloatNSPanel {
        let p = FloatNSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 240),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        panel = p
        return p
    }

    private var installed = false
    /// The panel's content (the window installs it once, with the shell), in the app's language.
    func install(_ shell: ShellModel) {
        guard !installed else { return }
        installed = true
        let p = panel ?? makePanel()
        p.contentView = NSHostingView(rootView: LocalizedRoot { FloatView(shell: shell, float: self) })
    }
}

/// What the float draws (P1Float, QuestionCard, CardStates), on the ink surface, 304 wide: its title bar (小方, the
/// state, the app and the task, Stop), the task's window (U1's frame, without its own bar), the step in a line -- or,
/// with a card, the card as placement says, and under an answerable one 「点按钮不抢键盘」 and 「去主窗口回答」. A card
/// that waits rings it in orange. Collapsed by the user: a 260 × 36 capsule.
struct FloatView: View {
    @ObservedObject var shell: ShellModel
    @ObservedObject var float: FloatController
    /// For the offscreen render only (tests/snapshot): this picture, nothing watched.
    var still: LiveDock.Picture? = nil
    @Environment(\.lang) private var lang
    @State private var hover = false
    @State private var zoomed = false

    var body: some View {
        if let n = float.now {
            if FloatPolicy.collapsed(user: float.userCollapsed, cardWaiting: waits(n)) { capsule(n) } else { panel(n) }
        }
    }

    private func waits(_ n: FloatController.Now) -> Bool {
        guard let p = n.phase else { return false }
        return p.ending == nil || p.isExpiredOffer
    }

    private func panel(_ n: FloatController.Now) -> some View {
        let last = n.task.steps.last
        return VStack(alignment: .leading, spacing: 0) {
            titleBar(n)
            // (「准备点」 and the box by the right column's rule: the open click card's own target, the card's own rect)
            LiveFrame(picture: still ?? float.dock.picture, state: still == nil ? float.dock.state : .streaming,
                      app: nil, waiting: waits(n), about: Self.aboutToAct(n), step: nil, stepWindow: LiveFeed.windowNumber(last?.object),
                      target: last?.target, boxRect: LiveFeed.boxRect(cardWaitsOnButton: Self.waitingClick(n) != nil, card: Self.waitingClick(n)?.targetBox?.rectNorm),
                      boxWindow: LiveFeed.windowNumber(Self.waitingClick(n)?.object),
                      zoomed: $zoomed, popOut: {}, chrome: false)
            if let card = n.card, let phase = n.phase, let p = n.placement {
                FloatCard(shell: shell, sessionId: n.sessionId, card: card, phase: phase, placement: p)
            } else if let step = last {
                Text(step.displayText).font(.system(size: 11)).foregroundStyle(Color(ShellPalette.onInkMuted)).lineLimit(2)
                    .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
            } else {
                Color.clear.frame(height: 10)
            }
        }
        .frame(width: FloatController.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(ShellPalette.inkSurface)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(waits(n) ? Brand.dot : Color.clear, lineWidth: 2))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }

    /// 36 tall: 小方 (up while a card waits), the state, 「· 应用 · 任务」, then -- hovered -- 「收起」, and Stop.
    private func titleBar(_ n: FloatController.Now) -> some View {
        let word = stateWord(n)
        let detail = [AgentPanel.appName(n.task.steps.last?.object), Self.shortName(n.task, lang: lang)].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 8) {
            XiaoFace(eyes: waits(n) ? .up : XiaoEyes.of(n.status), size: 20, onInk: true)
            Text(word).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(waits(n) ? Color(ShellPalette.onInkOrange) : Color(ShellPalette.onInk))
            Text(verbatim: "· " + detail).font(.system(size: 12)).foregroundStyle(Color(ShellPalette.onInkMuted)).lineLimit(1)
            Spacer(minLength: 4)
            // (none while a card waits: the float stays whole until it is answered)
            if !waits(n) {
                Button(L("Collapse", lang: lang)) { float.userCollapsed = true }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color(ShellPalette.onInkMuted))
                    .opacity(hover ? 1 : 0)
            }
            stopButton(n, size: 26)
        }
        .padding(.leading, 12).padding(.trailing, 6).frame(height: 36)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(word + " · " + detail)
    }

    /// The capsule (CardStates 「胶囊」): the dot, 「<应用> · 第 n 步」, Stop; hovered, 「放大」.
    private func capsule(_ n: FloatController.Now) -> some View {
        let app = AgentPanel.appName(n.task.steps.last?.object) ?? Self.shortName(n.task, lang: lang)
        return HStack(spacing: 8) {
            Circle().fill(Brand.dot).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(L("%@ · Step %d", app, n.task.steps.count, lang: lang)).font(.system(size: 12)).foregroundStyle(Color(ShellPalette.onInk)).lineLimit(1)
            Spacer(minLength: 4)
            Button(L("Larger", lang: lang)) { float.userCollapsed = false }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color(ShellPalette.onInkMuted))
                .opacity(hover ? 1 : 0)
            stopButton(n, size: 22)
        }
        .padding(.leading, 14).padding(.trailing, 7)
        .frame(width: 260, height: 36)
        .background(Capsule().fill(Color(ShellPalette.inkSurface)))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .frame(width: FloatController.width, alignment: .trailing)
    }

    private func stopButton(_ n: FloatController.Now, size: CGFloat) -> some View {
        Button { shell.stop(sessionId: n.sessionId, runId: n.task.runId) } label: {
            RoundedRectangle(cornerRadius: 2).fill(Color(ShellPalette.onInk)).frame(width: size * 0.32, height: size * 0.32)
                .frame(width: size, height: size).background(Circle().fill(Color(ShellPalette.inkStop)))
        }
        .buttonStyle(.plain)
        .help(L("Stop", lang: lang))
        .accessibilityLabel(L("Stop", lang: lang))
    }

    /// The button the open action card names (its consent: a click on its target) -- the right column's rule.
    static func aboutToAct(_ n: FloatController.Now) -> String? {
        guard let t = waitingClick(n)?.target, !t.isEmpty else { return nil }
        return t
    }
    static func waitingClick(_ n: FloatController.Now) -> ConsentFacts? {
        guard n.phase == .open, let c = n.card?.consent, c.action == "click" else { return nil }
        return c
    }

    private func stateWord(_ n: FloatController.Now) -> String {
        if waits(n) { return L("Waiting", lang: lang) }
        switch n.status {
        case .paused: return L("Paused", lang: lang)
        default: return L("Working", lang: lang)
        }
    }

    /// The task in a few words (its goal, else what was asked): 10 characters in Chinese, 24 in English.
    static func shortName(_ t: TaskState, lang: ResolvedLang) -> String {
        let s = (t.goal?.isEmpty == false ? t.goal! : t.raw)
        let cap = lang == .zhHans ? 10 : 24
        return s.count > cap ? String(s.prefix(cap - 1)) + "…" : s
    }
}

/// The float's buttons (P1Float): 44 tall, radius 12 -- the primary the paper colour with ink words, the others a
/// darker ink with a hairline.
struct FloatButtonStyle: ButtonStyle {
    var prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        configuration.label
            .font(.system(size: prominent ? 14 : 13, weight: prominent ? .bold : .regular))
            .multilineTextAlignment(.center).lineLimit(2)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(prominent ? Color(ShellPalette.inkSurface) : Color(ShellPalette.onInk))
            .background(shape.fill(prominent ? Color(ShellPalette.onInk) : Color(ShellPalette.inkButton)))
            .overlay(shape.strokeBorder(prominent ? Color.clear : Color(ShellPalette.inkButtonLine), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(shape)
            .pointerStyle(.link)
    }
}

/// The card in the float, laid out from the same CardLayout the chat uses (#125 Codex review at 2f29d42): its title,
/// its text when nothing folds it, what goes beyond the request, every field of what an approval does -- the action,
/// what it acts on, the site, what goes out -- then its options, when placement says it is answerable here. Its whole
/// height is measured (a copy laid out unseen) and reported: a card that does not fit the float's room is the main
/// window's (CardPlacement.fitsFloat), and the float gives its title and 「去主窗口回答」. Held: its take-back row;
/// expired: 「已过期 · 现在回答」. Under every answerable one: 「点按钮不抢键盘」 and 「去主窗口回答」 (handoff §3.3).
struct FloatCard: View {
    @ObservedObject var shell: ShellModel
    let sessionId: String
    let card: CardModel
    let phase: CardPhase
    let placement: CardPlacement
    @Environment(\.lang) private var lang

    var body: some View {
        let layout = CardLayout(card)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                switch placement.shown {
                case .floatCard where phase.isExpiredOffer:
                    summaryTitle(layout)
                    Text(L("Expired · Answer now", lang: lang)).font(.system(size: 11)).foregroundStyle(Color(ShellPalette.onInkOrange))
                    if placement.takesAnswer, let ask = card.askId {
                        Button(L("Answer now", lang: lang)) { if FloatController.shared.answersNow() { shell.answerNow(card.runId, askId: ask, session: sessionId) } }
                            .buttonStyle(FloatButtonStyle(prominent: true))
                    }
                case .floatCard:
                    whole(layout)
                    if let held = phase.pending, case .pending(_, let until) = phase {
                        HStack(spacing: 8) {
                            // (the seconds left to take it back, from the same deadline the chat's card counts to)
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(L("Picked: %@ · goes on in %d s", CardView.picked(held, card: card), max(0, Int((until - shell.now()).rounded(.up))), lang: lang))
                                    .font(.system(size: 12)).foregroundStyle(Color(ShellPalette.onInkOrange)).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Button(L("Take back", lang: lang)) { if FloatController.shared.answersNow() { shell.takeBack(card) } }
                                .buttonStyle(FloatButtonStyle(prominent: false)).frame(width: 72)
                        }
                    } else {
                        options(layout)
                    }
                default:
                    summaryTitle(layout)
                    // (the card's own conversation selected first: the window shows it, not the one it showed -- #125 Codex)
                    Button(action: Activation.onClick { g in shell.select(sessionId); MainWindow.comeBack(g) }) { Text(L("Answer in the main window ›", lang: lang)) }
                        .buttonStyle(FloatButtonStyle(prominent: true))
                        .accessibilityHint(L("Brings DeskMind's window forward on the card", lang: lang))
                }
            }
            .padding(.horizontal, 12).padding(.top, 10)
            if placement.shown == .floatCard { footer } else { Color.clear.frame(height: 12) }
        }
        // the whole card's height, laid out unseen at the float's width: whether it fits
        .background(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) { whole(layout); options(layout) }
                .frame(width: FloatController.width - 24, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .background(GeometryReader { g in Color.clear.preference(key: CardHeight.self, value: g.size.height) })
                .onPreferenceChange(CardHeight.self) { h in FloatController.shared.cardLaidOut(card, height: h) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// 「点按钮不抢键盘」 and 「去主窗口回答」, under every card the float answers.
    private var footer: some View {
        HStack(spacing: 8) {
            Text(L("Buttons here don't take your keyboard", lang: lang)).font(.system(size: 12)).foregroundStyle(Color(ShellPalette.onInkMuted))
            Spacer(minLength: 4)
            Button(action: Activation.onClick { g in shell.select(sessionId); MainWindow.comeBack(g) }) { Text(L("Answer in the main window", lang: lang)) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Color(ShellPalette.onInkLink))
                .accessibilityHint(L("Brings DeskMind's window forward on the card", lang: lang))
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 12)
    }

    /// The title where the card is not shown whole (its summary, an expired card): at most two lines, so that the
    /// button under it is always in the float -- with no headline the title is the card's whole text (#125 Codex
    /// re-review at d08465d). A plan card says its steps and how many go out.
    @ViewBuilder private func summaryTitle(_ layout: CardLayout) -> some View {
        Text(Self.summary(card, layout: layout, lang: lang)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(ShellPalette.onInk))
            .lineLimit(FloatCard.summaryLines).truncationMode(.tail)
    }
    static let summaryLines = 2

    /// 「计划 · 4 步，1 步往外发，到时再确认」 for a plan card (its steps, the ones that send out), else its title.
    static func summary(_ card: CardModel, layout: CardLayout, lang: ResolvedLang) -> String {
        guard card.kind == .plan else { return layout.title }
        // (a plan card always says it is the plan; with no steps in fields, its title after it)
        guard !layout.plan.isEmpty else { return L("Plan · %@", layout.title, lang: lang) }
        let out = layout.plan.filter(\.sendsOut).count
        return out > 0 ? L("Plan · %d steps, %d go out and are confirmed then", layout.plan.count, out, lang: lang)
                       : L("Plan · %d steps", layout.plan.count, lang: lang)
    }

    /// Everything an approval does, as the chat shows it (folded text and plan steps aside: with a headline, the
    /// beyond lines and the consent fields say it).
    @ViewBuilder private func whole(_ layout: CardLayout) -> some View {
        Text(layout.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(ShellPalette.onInk)).fixedSize(horizontal: false, vertical: true)
        if let t = layout.shownText { Text(t).font(.system(size: 11)).foregroundStyle(Color(ShellPalette.onInkMuted)).fixedSize(horizontal: false, vertical: true) }
        if !layout.folds && !layout.plan.isEmpty {
            ForEach(layout.plan, id: \.n) { r in
                Text("\(r.n). \(r.purpose)").font(.system(size: 11)).foregroundStyle(Color(ShellPalette.onInkMuted)).fixedSize(horizontal: false, vertical: true)
            }
        }
        ForEach(Array(layout.beyond.enumerated()), id: \.offset) { _, line in
            Text(line).font(.system(size: 11)).foregroundStyle(Color(ShellPalette.onInkMuted)).fixedSize(horizontal: false, vertical: true)
        }
        if let c = layout.consent { ConsentFields(consent: c, onInk: true) }
        // (an action card whose words do not say all of its text: the float has no 「细节」, so the whole text is here --
        // #129 Codex review)
        if layout.shownText == nil, let t = layout.wholeText, t != layout.title {
            Text(t).font(.system(size: 11)).foregroundStyle(Color(ShellPalette.onInkMuted)).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The picks one under another (QuestionCard: its number, its words, its second line); the buttons side by side
    /// (P1Float), three to a row, the primary a little narrower than the others (1 : 1.2).
    @ViewBuilder private func options(_ layout: CardLayout) -> some View {
        let picks = layout.list, buttons = layout.buttons
        let rows = stride(from: 0, to: buttons.count, by: 3).map { Array(buttons[$0..<min($0 + 3, buttons.count)]) }
        VStack(spacing: 6) {
            ForEach(picks, id: \.index) { c in
                let on = placement.takesAnswer && shell.canSend(c.button, session: sessionId)
                Button { if FloatController.shared.answersNow() { _ = shell.click(c.button, session: sessionId, place: .float) } } label: {
                    HStack(spacing: 10) {
                        if let k = c.key {
                            Text("\(k)").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(ShellPalette.onInk))
                                .frame(width: 20, height: 20).background(Circle().fill(Brand.dot)).accessibilityHidden(true)
                        }
                        Text(c.button.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(ShellPalette.onInk))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if let d = c.button.detail {
                            Text(d).font(.system(size: 11)).foregroundStyle(Color(ShellPalette.onInkMuted)).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(ShellPalette.inkButton)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(ShellPalette.inkButtonLine)))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(!on).opacity(on ? 1 : 0.5)
                .accessibilityLabel(c.button.detail.map { L("%@, %@", c.button.text, $0, lang: lang) } ?? c.button.text)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                WeightedRow(weights: row.map { $0.prominent ? 1 : 1.2 }, spacing: 6) {
                    ForEach(row, id: \.index) { c in
                        // (the window's state now, at the click: in front, the chat answers and this does not)
                        Button(c.button.text) { if FloatController.shared.answersNow() { _ = shell.click(c.button, session: sessionId, place: .float) } }
                            .buttonStyle(FloatButtonStyle(prominent: c.prominent))
                            .disabled(!placement.takesAnswer || !shell.canSend(c.button, session: sessionId))
                            .opacity(placement.takesAnswer && shell.canSend(c.button, session: sessionId) ? 1 : 0.5)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
