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
        let chrome = 24 + 30 + (userCollapsed ? 0 : 150 + 8 + 30)
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
        island.apply(IslandFeed.frame(task, pinned: pinned.map { ($0.card, $0.phase) }, lang: lang), title: task.raw, lang: lang,
                     onStop: { shell.stop(sessionId: sid, runId: task.runId) })
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
        let frame = NSRect(x: visible.maxX - size.width - 16, y: visible.minY + 16, width: size.width, height: size.height)
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

/// What the float draws: the task's line, its picture, and its card as placement says.
struct FloatView: View {
    @ObservedObject var shell: ShellModel
    @ObservedObject var float: FloatController
    @Environment(\.lang) private var lang

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let n = float.now {
                HStack(spacing: 8) {
                    XiaoFang(mood: AgentPanel.mood(n.status), size: 22).accessibilityHidden(true)
                    Text(ShellText.task(n.task, lang: lang)).font(.system(size: 12, weight: .medium)).foregroundStyle(Brand.ink).lineLimit(1)
                    Spacer()
                    Button(float.userCollapsed ? L("Larger", lang: lang) : L("Collapse", lang: lang)) { float.userCollapsed.toggle() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
                    Button(L("Stop", lang: lang)) { shell.stop(sessionId: n.sessionId, runId: n.task.runId) }
                        .buttonStyle(InkButtonStyle(prominent: false, small: true))
                }
                if !float.userCollapsed {
                    let last = n.task.steps.last
                    LiveDockView(dock: float.dock, stepWindow: LiveFeed.windowNumber(last?.object), target: last?.target?.rectNorm)
                    if let step = last { Text(step.displayText).font(.system(size: 11)).foregroundStyle(ShellColor.secondary).lineLimit(2) }
                }
                if let card = n.card, let phase = n.phase, let p = n.placement {
                    FloatCard(shell: shell, sessionId: n.sessionId, card: card, phase: phase, placement: p)
                }
            }
        }
        .padding(12)
        .frame(width: FloatController.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Brand.line))
    }
}

/// The card in the float, laid out from the same CardLayout the chat uses (#125 Codex review at 2f29d42): its title,
/// its text when nothing folds it, what goes beyond the request, every field of what an approval does -- the action,
/// what it acts on, the site, what goes out -- then its options, when placement says it is answerable here. Its whole
/// height is measured (a copy laid out unseen) and reported: a card that does not fit the float's room is the main
/// window's (CardPlacement.fitsFloat), and the float gives its title and 「去主窗口回答」. Held: its take-back row;
/// expired: 「已过期 · 现在回答」.
struct FloatCard: View {
    @ObservedObject var shell: ShellModel
    let sessionId: String
    let card: CardModel
    let phase: CardPhase
    let placement: CardPlacement
    @Environment(\.lang) private var lang

    var body: some View {
        let layout = CardLayout(card)
        VStack(alignment: .leading, spacing: 6) {
            switch placement.shown {
            case .floatCard where phase.isExpiredOffer:
                summaryTitle(layout)
                Text(L("Expired · Answer now", lang: lang)).font(.system(size: 11)).foregroundStyle(ShellColor.orangeText)
                if placement.takesAnswer, let ask = card.askId {
                    Button(L("Answer now", lang: lang)) { if FloatController.shared.answersNow() { shell.answerNow(card.runId, askId: ask, session: sessionId) } }
                        .buttonStyle(InkButtonStyle(prominent: true))
                }
            case .floatCard:
                whole(layout)
                if let held = phase.pending, case .pending(_, let until) = phase {
                    HStack {
                        // (the seconds left to take it back, as the chat's card shows them: display only)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(L("Picked: %@ · goes on in %d s", CardView.picked(held, card: card), max(0, Int((until - shell.now()).rounded(.up))), lang: lang))
                                .font(.system(size: 11)).foregroundStyle(ShellColor.orangeText)
                        }
                        Button(L("Take back", lang: lang)) { if FloatController.shared.answersNow() { shell.takeBack(card) } }.buttonStyle(InkButtonStyle(prominent: false, small: true))
                    }
                }
                options(layout)
            default:
                summaryTitle(layout)
                // (the card's own conversation selected first: the window shows it, not the one it showed -- #125 Codex)
                Button(action: Activation.onClick { g in shell.select(sessionId); MainWindow.comeBack(g) }) { Text(L("Answer in the main window", lang: lang)) }
                    .buttonStyle(InkButtonStyle(prominent: true))
                    .accessibilityHint(L("Brings DeskMind's window forward on the card", lang: lang))
            }
        }
        // the whole card's height, laid out unseen at the float's width: whether it fits
        .background(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6) { whole(layout); options(layout) }
                .frame(width: FloatController.width - 24, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .background(GeometryReader { g in Color.clear.preference(key: CardHeight.self, value: g.size.height) })
                .onPreferenceChange(CardHeight.self) { h in FloatController.shared.cardLaidOut(card, height: h) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The title where the card is not shown whole (its summary, an expired card): at most two lines, so that the
    /// button under it is always in the float -- with no headline the title is the card's whole text (#125 Codex
    /// re-review at d08465d).
    @ViewBuilder private func summaryTitle(_ layout: CardLayout) -> some View {
        Text(layout.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.ink)
            .lineLimit(FloatCard.summaryLines).truncationMode(.tail)
    }
    static let summaryLines = 2

    @ViewBuilder private func title(_ layout: CardLayout) -> some View {
        Text(layout.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
    }

    /// Everything an approval does, as the chat shows it (folded text and plan steps aside: with a headline, the
    /// beyond lines and the consent fields say it).
    @ViewBuilder private func whole(_ layout: CardLayout) -> some View {
        title(layout)
        if let t = layout.shownText { Text(t).font(.system(size: 11)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true) }
        if !layout.folds && !layout.plan.isEmpty { PlanSteps(rows: layout.plan, foreground: layout.foreground) }
        ForEach(Array(layout.beyond.enumerated()), id: \.offset) { _, line in
            Text(line).font(.system(size: 11)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
        }
        if let c = layout.consent { ConsentFields(consent: c) }
    }

    @ViewBuilder private func options(_ layout: CardLayout) -> some View {
        ForEach(layout.controls, id: \.index) { c in
            // (the window's state now, at the click: in front, the chat answers and this does not)
            Button(c.button.text) { if FloatController.shared.answersNow() { _ = shell.click(c.button, session: sessionId, place: .float) } }
                .buttonStyle(InkButtonStyle(prominent: c.prominent))
                .disabled(!placement.takesAnswer || !shell.canSend(c.button, session: sessionId))
        }
    }
}
