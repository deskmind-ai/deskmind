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
    func requestNotifications() { base.requestNotifications() }
    func show(title: String, line: String, onStop: @escaping () -> Void) { base.show(title: title, line: line, onStop: onStop) }
    func update(step: Int, line: String) { base.update(step: step, line: line) }
    func setAsking(_ on: Bool) { base.setAsking(on) }
    func finish(passed: Bool, stopped: Bool, summary: String) { base.finish(passed: passed, stopped: stopped, summary: summary) }
    func notify(title: String, body: String) {}       // (CardNotices posts them, by id)
    var detailsRecord: UUID? { get { nil } set {} }
    var appActive: Bool { base.appActive }
    var userTyping: Bool { base.userTyping }
}

/// A panel that never becomes the key or the main window.
final class FloatNSPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatController: ObservableObject {
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
        guard let (sid, s) = running, let task = s.runningTask else {
            now = nil; dock.watch(nil); show(.hidden)
            notices.card(nil, placement: nil, title: "", body: "", now: t)
            return
        }
        let pinned = shell.pinned(s)
        let island = islands[task.runId] ?? { let a = IslandApplier(ChatIslandSurface()); islands[task.runId] = a; return a }()
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
            let pl = CardPlacement.place(p.phase, fitsFloat: card.answerableInFloat, window: window, frontNow: frontNow, float: fact,
                                         notified: notices.notified(p.card.askId, now: t))
            placement = pl
            notices.card(p.card.askId, placement: pl, title: L("DeskMind", lang: lang),
                         body: p.phase.isExpiredOffer ? "" : CardLayout(card).title, now: t)
        } else {
            notices.card(nil, placement: nil, title: "", body: "", now: t)
        }
        now = Now(sessionId: sid, status: s.status, task: task, card: card, phase: pinned?.phase, placement: placement)
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
        guard s != .hidden else { panel?.orderOut(nil); return }
        let p = panel ?? makePanel()
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
        let size = (p.contentView?.fittingSize).map { NSSize(width: Self.width, height: min($0.height, visible.height * 0.7)) } ?? NSSize(width: Self.width, height: 240)
        let frame = NSRect(x: visible.maxX - size.width - 16, y: visible.minY + 16, width: size.width, height: size.height)
        if p.frame != frame { p.setFrame(frame, display: true) }
        if !p.isVisible { Activation.showPanel(p) }
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
                        .buttonStyle(InkButtonStyle(prominent: false))
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

/// The card in the float: its options when placement says it is answerable here, else its title and the way to the
/// main window; held for its take-back as in the chat; expired: 「已过期 · 现在回答」.
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
            Text(layout.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
            if let t = layout.shownText { Text(t).font(.system(size: 11)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true) }
            if let c = layout.consent {
                ForEach(Array(c.outgoing.enumerated()), id: \.offset) { _, o in
                    Text(L("%@: %@", o.label, o.value, lang: lang)).font(.system(size: 11)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
            switch placement.shown {
            case .floatCard where phase.isExpiredOffer:
                Text(L("Expired · Answer now", lang: lang)).font(.system(size: 11)).foregroundStyle(ShellColor.orangeText)
                if placement.takesAnswer, let ask = card.askId {
                    Button(L("Answer now", lang: lang)) { shell.answerNow(card.runId, askId: ask, session: sessionId) }.buttonStyle(InkButtonStyle(prominent: true))
                }
            case .floatCard:
                if let held = phase.pending {
                    HStack {
                        Text(L("Picked: %@", CardView.picked(held, card: card), lang: lang)).font(.system(size: 11)).foregroundStyle(ShellColor.orangeText)
                        Button(L("Take back", lang: lang)) { shell.takeBack(card) }.buttonStyle(InkButtonStyle(prominent: false))
                    }
                }
                ForEach(layout.controls, id: \.index) { c in
                    Button(c.button.text) { _ = shell.click(c.button, session: sessionId) }
                        .buttonStyle(InkButtonStyle(prominent: c.prominent))
                        .disabled(!placement.takesAnswer || !shell.canSend(c.button, session: sessionId))
                }
            default:
                Button(action: Activation.onClick { MainWindow.comeBack($0) }) { Text(L("Answer in the main window", lang: lang)) }
                    .buttonStyle(InkButtonStyle(prominent: true))
                    .accessibilityHint(L("Brings DeskMind's window forward on the card", lang: lang))
            }
        }
    }
}
