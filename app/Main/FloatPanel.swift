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
        /// When the card was asked (its 「等了 0:12」).
        var askedAt: Double? = nil
    }
    @Published private(set) var now: Now?
    /// For the offscreen render only (tests/snapshot): this state, as `update` would set it.
    func preview(_ n: Now?) { now = n }
    @Published var userCollapsed = false
    /// The picture at 720 wide (CardStates 「放大」), while no card is shown.
    @Published var zoomed = false
    /// The task this float followed that just ended, shown so for a moment (CardStates 完成 / 没做完): until then.
    private var endedShown: (sessionId: String, runId: String, until: Double)?
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
    /// The orange ring round a waiting card, outside it (P1Float: box-shadow 0 0 0 2px): the panel's room for it.
    static let ring: CGFloat = 2
    /// The float's width now: 304, or 720 zoomed with no card in it.
    var panelWidth: CGFloat { zoomed && now?.card == nil && now?.task.ended == false ? 720 : Self.width }
    /// How long an ended task's float stays: done, a moment (CardStates: 2.5 s, then it fades); stopped by the user,
    /// the same; didn't finish, as long as the island's (its why is to be read).
    static let doneSeconds: Double = 2.5

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
        for (key, s) in shell.states {
            for task in s.tasks where task.ended && !ended.contains(task.runId) {
                ended.insert(task.runId)
                // (only a task this float followed: its island finishes, its end is said when nobody looked)
                if let a = islands.removeValue(forKey: task.runId) {
                    let failed = !(task.status == "succeeded" || task.status == "cancelled" || task.status == "stopped")
                    endedShown = (key, task.runId, t + (failed ? Island.resultLingerSeconds : Self.doneSeconds))
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
            dock.watch(nil)
            notices.card(nil, placement: nil, title: "", body: "", now: t)
            // (the task it followed just ended: 完成 / 没做完 a moment, while the window is not in front)
            if let e = endedShown, t < e.until, window != .front, let st = shell.states[e.sessionId], let done = st.tasks.first(where: { $0.runId == e.runId }) {
                now = Now(sessionId: e.sessionId, status: st.status, task: done, card: nil, phase: nil, placement: nil)
                show(.open)
                return
            }
            endedShown = nil
            now = nil; show(.hidden)
            return
        }
        endedShown = nil
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
        now = Now(sessionId: sid, status: s.status, task: task, card: card, phase: pinned?.phase, placement: placement, askedAt: pinned?.card.askedAt)
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
        // (its ring's room round it: the card itself 18 in from the screen's corner)
        let w = panelWidth + 2 * Self.ring
        let size = (p.contentView?.fittingSize).map { NSSize(width: w, height: min($0.height, visible.height * 0.7)) } ?? NSSize(width: w, height: 240)
        let frame = NSRect(x: visible.maxX - size.width - 18 + Self.ring, y: visible.minY + 18 - Self.ring, width: size.width, height: size.height)
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

/// What the float draws, on the ink surface, 304 wide (P1Float; QuestionCard and CardStates where P1Float draws no
/// such state -- the owner's #133 rule: the P1 boards win where boards disagree). With no card (CardStates): a 30 tall
/// bar -- 小方 looking at the cursor, 「<应用> · 第 n 步」, hovered its 放大 / 收起 / Stop -- the window's picture, and
/// the step in a line; its window gone from the screen, the last picture dimmed with 「窗口不可见」; the task ended,
/// 「完成 · n 步 · 时间」 (a moment) or 「没做完 · 原因」. With a card: the 36 tall bar -- 小方, 「等你」 (已回答,
/// 已暂停), 「· 应用 · 任务」, how long it waited, Stop -- then the card as placement says (FloatCard). A card that waits
/// is ringed in orange, outside the card. Collapsed by the user: a 260 × 36 capsule; a click on it opens it again.
struct FloatView: View {
    @ObservedObject var shell: ShellModel
    @ObservedObject var float: FloatController
    /// For the offscreen render only (tests/snapshot): this picture, nothing watched; and whether its window is off
    /// the screen (the picture kept, dimmed).
    var still: LiveDock.Picture? = nil
    var stillHidden = false
    /// For the offscreen render only: drawn as hovered.
    var stillHover = false
    @Environment(\.lang) private var lang
    @State private var hovering = false
    private var hover: Bool { hovering || stillHover }

    var body: some View {
        if let n = float.now {
            if FloatPolicy.collapsed(user: float.userCollapsed, cardWaiting: waits(n)) { capsule(n) } else { panel(n) }
        }
    }

    private func waits(_ n: FloatController.Now) -> Bool {
        guard !n.task.ended, let p = n.phase else { return false }
        return p.ending == nil || p.isExpiredOffer
    }

    /// What the float shows: the task (no card), its end, or its card -- open, held for its take-back, expired, or
    /// as its summary (the whole card is the main window's).
    enum Mode: Equatable { case working, ended, open, held, paused, summary }
    static func mode(_ n: FloatController.Now) -> Mode {
        if n.task.ended { return .ended }
        guard n.card != nil, let p = n.phase, let pl = n.placement else { return .working }
        switch pl.shown {
        case .floatCard where p.isExpiredOffer: return .paused
        case .floatCard where p.pending != nil: return .held
        case .floatCard: return .open
        default: return .summary
        }
    }

    private func panel(_ n: FloatController.Now) -> some View {
        let m = Self.mode(n)
        let ring = waits(n) && (m == .open || m == .summary)
        return VStack(alignment: .leading, spacing: 0) {
            if m == .working || m == .ended { liveBar(n, m) } else { cardBar(n, m) }
            if m == .working || m == .ended || m == .open { picture(n, m) }
            if m == .working || m == .ended {
                Text(stepLine(n)).font(.system(size: 11)).foregroundStyle(Color(ShellPalette.onInkBright)).lineLimit(1)
                    .padding(.horizontal, 10).frame(height: 30, alignment: .leading)
            } else if let card = n.card, let phase = n.phase, let p = n.placement {
                FloatCard(shell: shell, sessionId: n.sessionId, card: card, phase: phase, placement: p, mode: m)
            }
        }
        .frame(width: float.panelWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(ShellPalette.inkSurface)))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        // (P1Float: box-shadow 0 0 0 2px -- the ring outside the card, the card whole inside it)
        .padding(FloatController.ring)
        .overlay(RoundedRectangle(cornerRadius: 16 + FloatController.ring).strokeBorder(ring ? Color(ShellPalette.floatRing) : .clear, lineWidth: FloatController.ring))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }

    /// The window's picture (P1Float: 110 tall, 6 in, filled and kept on what it acts on); off the screen, the last one
    /// dimmed with 「窗口不可见」; ended, the last one without the cursor.
    private func picture(_ n: FloatController.Now, _ m: Mode) -> some View {
        let last = n.task.steps.last
        let hidden = Self.windowHidden(n, still: still, stillHidden: stillHidden, dock: float.dock)
        let pic = still ?? (hidden || m == .ended ? float.dock.last : float.dock.picture)
        return FloatPicture(picture: pic, state: still != nil || hidden || m == .ended ? .streaming : float.dock.state,
                            about: Self.aboutToAct(n), stepWindow: LiveFeed.windowNumber(last?.object),
                            target: m == .ended || hidden ? nil : last?.target?.rectNorm,
                            boxRect: LiveFeed.boxRect(cardWaitsOnButton: Self.waitingClick(n) != nil, card: Self.waitingClick(n)?.targetBox?.rectNorm),
                            boxWindow: LiveFeed.windowNumber(Self.waitingClick(n)?.object),
                            height: float.zoomed && float.now?.card == nil ? 260 : 110,
                            dimNote: hidden ? L("Window not visible", lang: lang) : nil)
    }

    /// The window can no longer be taken (no_picture after a picture of it: hidden, minimised, another desktop).
    static func windowHidden(_ n: FloatController.Now, still: LiveDock.Picture?, stillHidden: Bool, dock: LiveDock) -> Bool {
        guard !n.task.ended else { return false }
        if still != nil { return stillHidden }
        return dock.state == .noPicture && dock.last != nil
    }

    /// CardStates' bar: 30 tall, 小方 (looking at the cursor; ^ ^ done; – – ended otherwise or the window gone),
    /// 「<应用> · 第 n 步」 or how it ended, and -- hovered, while it runs -- 放大, 收起 and Stop.
    private func liveBar(_ n: FloatController.Now, _ m: Mode) -> some View {
        let done = n.task.ended && n.task.status == "succeeded"
        let hidden = Self.windowHidden(n, still: still, stillHidden: stillHidden, dock: float.dock)
        let eyes: XiaoEyes = done ? .happy : (m == .ended || hidden) ? .flat : .look
        let title = Self.liveTitle(n, lang: lang)
        return HStack(spacing: 7) {
            XiaoFace(eyes: eyes, size: 17, onInk: true, dot: m == .ended && !done ? .mist : .lit)
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(ShellPalette.onInk)).lineLimit(1)
            Spacer(minLength: 4)
            if m == .working {
                HStack(spacing: 8) {
                    hoverIcon(float.zoomed ? L("Make the live view smaller", lang: lang) : L("Enlarge the live view", lang: lang)) {
                        FloatGlyph.zoom.stroke(Color(ShellPalette.onInkIcon), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    } action: { float.zoomed.toggle() }
                    hoverIcon(L("Collapse", lang: lang)) {
                        FloatGlyph.down.stroke(Color(ShellPalette.onInkIcon), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    } action: { float.userCollapsed = true }
                    hoverIcon(L("Stop", lang: lang)) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(ShellPalette.onInkIcon)).frame(width: 9, height: 9)
                    } action: { shell.stop(sessionId: n.sessionId, runId: n.task.runId) }
                }
                .opacity(hover ? 1 : 0)
                .allowsHitTesting(hover)
            }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func hoverIcon(_ label: String, @ViewBuilder _ glyph: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) { glyph().frame(width: 12, height: 12).frame(width: 18, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    /// 「<应用> · 第 n 步」; ended, 「完成 · n 步 · 57 秒」, 「已停下 · n 步」 or 「没做完 · 为什么」.
    static func liveTitle(_ n: FloatController.Now, lang: ResolvedLang) -> String {
        let t = n.task, steps = t.steps.count
        guard t.ended else {
            let app = AgentPanel.appName(t.steps.last?.object) ?? shortName(t, lang: lang)
            return L("%@ · Step %d", app, steps, lang: lang)
        }
        switch t.status {
        case "succeeded":
            let secs = max(0, Int((t.endedAt ?? 0) - (t.startedAt ?? t.endedAt ?? 0)))
            let time = secs < 60 ? L("%d s", secs, lang: lang) : String(format: "%d:%02d", secs / 60, secs % 60)
            return L("Done · %@", L("%d steps · %@", steps, time, lang: lang), lang: lang)
        case "cancelled", "stopped":
            return L("Stopped · %@", L("%d steps", steps, lang: lang), lang: lang)
        default:
            // (why: the task's own end in words, when it says more than 「没做完」)
            let why = ShellText.task(t, lang: lang)
            return why == L("Didn't finish", lang: lang) || why.isEmpty ? why : L("Didn't finish · %@", why, lang: lang)
        }
    }

    /// The line under the picture: the step (its own words); ended, what it came to (the answer, else the summary).
    private func stepLine(_ n: FloatController.Now) -> String {
        if n.task.ended {
            let d = n.task.done
            return [d?.answer, d?.summary, d?.reason].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        }
        return n.task.steps.last?.displayText ?? ""
    }

    /// P1Float's bar over a card: 36 tall, 小方 (up while it waits; ^ ^ held; – – expired), the state word, 「· 应用 ·
    /// 任务」, how long the card has waited (QuestionCard), Stop.
    private func cardBar(_ n: FloatController.Now, _ m: Mode) -> some View {
        let word = m == .held ? L("Answered", lang: lang) : m == .paused ? L("Paused", lang: lang) : L("Waiting", lang: lang)
        let eyes: XiaoEyes = m == .held ? .happy : m == .paused ? .flat : .up
        let detail = [AgentPanel.appName(n.task.steps.last?.object), Self.shortName(n.task, lang: lang)].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 8) {
            XiaoFace(eyes: eyes, size: 17, onInk: true, dot: m == .paused ? .mist : .lit)
            Text(word).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(m == .open || m == .summary ? Color(ShellPalette.onInkOrange) : Color(ShellPalette.onInk))
            Text(verbatim: "· " + detail).font(.system(size: 12)).foregroundStyle(Color(ShellPalette.onInkMuted)).lineLimit(1)
            Spacer(minLength: 4)
            // (QuestionCard: while it asks or waits expired, and on the typed-answer summary; not P1Float's plan summary)
            if m == .open || m == .paused || (m == .summary && n.card?.allowsFreeText == true && n.card?.kind != .plan), let at = n.askedAt {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Self.waited(shell.now() - at, lang: lang)).font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Color(ShellPalette.onInkFaint)).lineLimit(1).fixedSize()
                }
            }
            stopButton(n, size: 26, mark: 8)
        }
        .padding(.leading, 12).padding(.trailing, 6).frame(height: 36)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(word + " · " + detail)
    }

    /// 「等了 0:12」
    static func waited(_ secs: Double, lang: ResolvedLang) -> String {
        let s = max(0, Int(secs))
        return L("Waited %@", String(format: "%d:%02d", s / 60, s % 60), lang: lang)
    }

    /// The capsule (CardStates 「胶囊」): the dot, 「<应用> · 第 n 步」, Stop; a click on it opens the float again.
    private func capsule(_ n: FloatController.Now) -> some View {
        let app = AgentPanel.appName(n.task.steps.last?.object) ?? Self.shortName(n.task, lang: lang)
        return HStack(spacing: 8) {
            Button { float.userCollapsed = false } label: {
                HStack(spacing: 8) {
                    Circle().fill(Brand.dot).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(L("%@ · Step %d", app, n.task.steps.count, lang: lang)).font(.system(size: 12)).foregroundStyle(Color(ShellPalette.onInk)).lineLimit(1)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(L("Opens the float again", lang: lang))
            stopButton(n, size: 22, mark: 7)
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(width: 260, height: 36)
        .background(Capsule().fill(Color(ShellPalette.inkSurface)))
        .padding(FloatController.ring)
        .frame(width: FloatController.width + 2 * FloatController.ring, alignment: .trailing)
    }

    private func stopButton(_ n: FloatController.Now, size: CGFloat, mark: CGFloat) -> some View {
        Button { shell.stop(sessionId: n.sessionId, runId: n.task.runId) } label: {
            RoundedRectangle(cornerRadius: 2).fill(Color(ShellPalette.onInk)).frame(width: mark, height: mark)
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

    /// The task in a few words: its goal (else what was asked) up to its first colon -- 「回复许诺：我看一下再说」 is
    /// 「回复许诺」 -- then at most 10 characters in Chinese, 24 in English.
    static func shortName(_ t: TaskState, lang: ResolvedLang) -> String {
        var s = (t.goal?.isEmpty == false ? t.goal! : t.raw)
        if let r = s.range(of: "：") ?? s.range(of: ": "), r.lowerBound > s.startIndex { s = String(s[..<r.lowerBound]) }
        let cap = lang == .zhHans ? 10 : 24
        return s.count > cap ? String(s.prefix(cap - 1)) + "…" : s
    }
}

/// The float's picture of the task's window (P1Float, CardStates): in a white well 6 in from the sides, radius 8,
/// filling it (cut, never stretched) and kept on what the card waits on -- its dashed box 6 out, 「准备点」 small
/// beside it -- else on the step's cursor; the window off the screen, the last picture dimmed with 「窗口不可见」.
struct FloatPicture: View {
    let picture: LiveDock.Picture?
    let state: LiveFeed.State?
    let about: String?
    let stepWindow: Int?
    let target: [Double]?
    let boxRect: [Double]?
    let boxWindow: Int?
    var height: CGFloat = 110
    var dimNote: String? = nil
    @Environment(\.lang) private var lang

    var body: some View {
        ZStack {
            Rectangle().fill(Color(ShellPalette.shotWell))
            if let p = picture {
                GeometryReader { g in
                    let (size, shift) = Self.fillLayout(p.image.size, in: g.size, focus: focus(p))
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: p.image).resizable().frame(width: size.width, height: size.height)
                        let box = LiveFeed.box(pictureWindow: p.window, stepWindow: boxWindow ?? stepWindow, rectNorm: boxRect, picture: size, visible: p.visible)
                        if let b = box {
                            RoundedRectangle(cornerRadius: 5).strokeBorder(Brand.dot, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                                .frame(width: b.width + 12, height: b.height + 12).offset(x: b.minX - 6, y: b.minY - 6)
                                .accessibilityHidden(true)
                            if let about {
                                let o = Self.sideTag(box: b, well: g.size, shift: shift)
                                tag(about).offset(x: o.x, y: o.y)
                            }
                        } else if let c = LiveFeed.cursor(pictureWindow: p.window, stepWindow: stepWindow, rectNorm: target, picture: size, visible: p.visible) {
                            Circle().fill(Brand.dot).frame(width: 11, height: 11)
                                .overlay(Circle().strokeBorder(Color(ShellPalette.shotWell), lineWidth: 2))
                                .offset(x: c.x - 5.5, y: c.y - 5.5).accessibilityHidden(true)
                        }
                    }
                    .offset(x: shift.x, y: shift.y)
                    .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                    .clipped()
                }
                .overlay(alignment: .topLeading) {
                    // (no box of the card's own on this picture: the tag in the corner, never on a step's box)
                    if let about, LiveFeed.box(pictureWindow: p.window, stepWindow: boxWindow ?? stepWindow, rectNorm: boxRect,
                                               picture: CGSize(width: 1, height: 1), visible: p.visible) == nil {
                        tag(about).padding(8)
                    }
                }
                .accessibilityLabel(L("Live view of the task's window", lang: lang))
            } else {
                Text(LiveDockView.note(state, lang: lang)).font(.system(size: 11)).foregroundStyle(Color(ShellPalette.inkSurface))
                    .multilineTextAlignment(.center).padding(14)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // (CardStates: the whole well dimmed over the ink, the word on it)
        .opacity(dimNote == nil ? 1 : 0.4)
        .overlay {
            if let dimNote { Text(dimNote).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(ShellPalette.inkSurface)) }
        }
        .padding(.horizontal, 6)
    }

    /// 「准备点：…」: 9 / 700, 16 tall (P1Float).
    private func tag(_ about: String) -> some View {
        Text(L("About to click: %@", about, lang: lang)).font(.system(size: 9, weight: .bold)).foregroundStyle(Color(ShellPalette.shotWell))
            .padding(.horizontal, 6).frame(height: Self.tagHeight)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(ShellPalette.floatShotTag)))
            .fixedSize()
    }

    /// What the picture is kept on: the card's box, else the step's cursor (0–1 of the picture), else its middle.
    private func focus(_ p: LiveDock.Picture) -> CGPoint {
        let unit = CGSize(width: 1, height: 1)
        if let b = LiveFeed.box(pictureWindow: p.window, stepWindow: boxWindow ?? stepWindow, rectNorm: boxRect, picture: unit, visible: p.visible) {
            return CGPoint(x: b.midX, y: b.midY)
        }
        return LiveFeed.cursor(pictureWindow: p.window, stepWindow: stepWindow, rectNorm: target, picture: unit, visible: p.visible) ?? CGPoint(x: 0.5, y: 0.5)
    }

    /// 「准备点」 4 right of the dashed frame, level with it; where the well has no room on its right, on its left
    /// (about 90 pt for 「准备点：发送」 and a word or two).
    static let tagHeight: CGFloat = 16
    static func sideTag(box b: CGRect, well: CGSize, shift: CGPoint) -> CGPoint {
        let right = b.maxX + 6 + 4
        return CGPoint(x: right + shift.x + 90 <= well.width ? right : max(0, b.minX - 6 - 4 - 90), y: b.midY - tagHeight / 2)
    }

    /// The picture filling `well` (scaled to cover it, never stretched) and how far it moves so that `focus` (0–1 of
    /// the picture) is in view, as near the middle as the picture's edges allow.
    static func fillLayout(_ image: CGSize, in well: CGSize, focus: CGPoint) -> (CGSize, CGPoint) {
        guard image.width > 0, image.height > 0, well.width > 0, well.height > 0 else { return (well, .zero) }
        let k = max(well.width / image.width, well.height / image.height)
        let size = CGSize(width: image.width * k, height: image.height * k)
        func shift(_ f: CGFloat, _ s: CGFloat, _ w: CGFloat) -> CGFloat { min(0, max(w - s, w / 2 - f * s)) }
        return (size, CGPoint(x: shift(focus.x, size.width, well.width), y: shift(focus.y, size.height, well.height)))
    }
}

/// The float's line glyphs (CardStates' hover icons, P1Float's arrow), drawn in a 12 × 12 box.
enum FloatGlyph: Shape {
    case zoom, down, chevron
    func path(in r: CGRect) -> Path {
        let k = r.width / 12
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * k, y: r.minY + y * k) }
        var path = Path()
        switch self {
        case .zoom:          // M7 1h4v4 M5 11H1V7 M11 1L7 5 M1 11l4-4
            path.move(to: p(7, 1)); path.addLine(to: p(11, 1)); path.addLine(to: p(11, 5))
            path.move(to: p(5, 11)); path.addLine(to: p(1, 11)); path.addLine(to: p(1, 7))
            path.move(to: p(11, 1)); path.addLine(to: p(7, 5))
            path.move(to: p(1, 11)); path.addLine(to: p(5, 7))
        case .down:          // M2 4l4 4 4-4
            path.move(to: p(2, 4)); path.addLine(to: p(6, 8)); path.addLine(to: p(10, 4))
        case .chevron:       // M4 2l4 4-4 4
            path.move(to: p(4, 2)); path.addLine(to: p(8, 6)); path.addLine(to: p(4, 10))
        }
        return path
    }
}

/// The float's buttons (P1Float): 44 tall, radius 12 -- the primary the paper colour with ink words, the others a
/// darker ink with a hairline.
struct FloatButtonStyle: ButtonStyle {
    var prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let size: CGFloat = prominent ? 14 : 13, weight: Font.Weight = prominent ? .bold : .regular
        // (one line if it fits, then one line a size smaller -- 「Stop for now」 in three -- and only then two)
        ViewThatFits(in: .horizontal) {
            configuration.label.font(.system(size: size, weight: weight)).lineLimit(1)
            configuration.label.font(.system(size: size - 1.5, weight: weight)).lineLimit(1)
            configuration.label.font(.system(size: size, weight: weight)).multilineTextAlignment(.center).lineLimit(2)
        }
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

/// The card in the float, from the same CardLayout the chat uses, as short as the boards draw it (owner, #133):
///
/// | mode    | board            | what                                                                              |
/// |---------|------------------|-----------------------------------------------------------------------------------|
/// | open    | P1Float a        | an action card: its question, what goes out in a line (CardBrief), the line on    |
/// |         |                  |   earlier steps that may have gone out (never folded: #129), its buttons; a card   |
/// |         |                  |   with picks: its question, the picks (QuestionCard), its buttons, 「停下这个任务」 |
/// |         |                  |   -- then 「点按钮不抢键盘」 and 「去主窗口回答」                                      |
/// | held    | QuestionCard     | 「已选：…」, 「n 秒后继续」, 「撤回」, the countdown's bar                            |
/// | paused  | QuestionCard     | it expired: 「没有及时回答…」, 「现在回答」 and 「停止任务」                            |
/// | summary | P1Float b / free | its title in two lines at most and 「去主窗口回答 ›」; a card that takes words:       |
/// |         |   QuestionCard   |   「要打字回答」 · 「在 DeskMind 里回答 ›」                                           |
///
/// What the brief leaves out is the main window's 「细节」: the way there is under every card. Its height is measured
/// (a copy laid out unseen) and reported: a card that does not fit the float's room is the main window's.
struct FloatCard: View {
    @ObservedObject var shell: ShellModel
    let sessionId: String
    let card: CardModel
    let phase: CardPhase
    let placement: CardPlacement
    let mode: FloatView.Mode
    @Environment(\.lang) private var lang

    var body: some View {
        let layout = CardLayout(card)
        VStack(alignment: .leading, spacing: 0) {
            switch mode {
            case .held:
                held(layout)
            case .paused:
                Text(L("No answer in time, so the task is paused. It won't guess for you.", lang: lang))
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(ShellPalette.onInk)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 4)
                HStack(spacing: 8) {
                    if placement.takesAnswer, let ask = card.askId {
                        Button(L("Answer now", lang: lang)) { if FloatController.shared.answersNow() { shell.answerNow(card.runId, askId: ask, session: sessionId) } }
                            .buttonStyle(FloatButtonStyle(prominent: true))
                    }
                    Button(L("Stop task", lang: lang)) { shell.stop(sessionId: sessionId, runId: card.runId) }
                        .buttonStyle(FloatButtonStyle(prominent: false))
                }
                .padding(.horizontal, 14).padding(.top, 12)
                foot(L("Nothing is touched while paused; the island keeps reminding you.", lang: lang), rule: true)
            case .open:
                content(layout)
                    // the whole card's height, laid out unseen at the float's width: whether it fits
                    .background(alignment: .topLeading) {
                        content(layout)
                            .frame(width: FloatController.width, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .background(GeometryReader { g in Color.clear.preference(key: CardHeight.self, value: g.size.height) })
                            .onPreferenceChange(CardHeight.self) { h in FloatController.shared.cardLaidOut(card, height: h) }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                footer
            default:
                summary(layout)
            }
        }
    }

    /// The open card: its words (an action card's brief, else its title and what goes beyond the request), its picks,
    /// its buttons.
    @ViewBuilder private func content(_ layout: CardLayout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            words(layout).padding(.horizontal, 14).padding(.top, 10)
            options(layout).padding(.horizontal, 10).padding(.top, 10)
            // (QuestionCard: under the picks, the way to stop the whole task)
            if !layout.list.isEmpty {
                HStack {
                    Spacer(minLength: 0)
                    Button(L("Stop this task", lang: lang)) { shell.stop(sessionId: sessionId, runId: card.runId) }
                        .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color(ShellPalette.onInkMuted))
                }
                .padding(.horizontal, 18).padding(.top, 12)
            }
        }
    }

    /// The question (P1Float: 14 / 600), what goes out in a line, the line that is never folded, what goes beyond.
    @ViewBuilder private func words(_ layout: CardLayout) -> some View {
        let brief = CardBrief(layout, lang: lang)
        VStack(alignment: .leading, spacing: 4) {
            Text(brief?.question ?? layout.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(ShellPalette.onInk))
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            if let l = brief?.leadLine {
                Text(verbatim: l).font(.system(size: 12)).foregroundStyle(Color(ShellPalette.onInkMuted)).lineLimit(1).truncationMode(.middle)
                    .accessibilityLabel(L("What goes out", lang: lang) + " " + l)
            }
            if let w = brief?.warning {
                Text(w).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(ShellPalette.onInkOrange)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // (what goes beyond the request: always shown, A2)
            ForEach(Array(layout.beyond.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 12)).foregroundStyle(Color(ShellPalette.onInkOrange)).fixedSize(horizontal: false, vertical: true)
            }
            // (a card with no consent fields and text its title does not say: the text, A2 -- #124)
            if brief == nil, let t = layout.shownText {
                Text(t).font(.system(size: 12)).foregroundStyle(Color(ShellPalette.onInkMuted)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 「点按钮不抢键盘」 and 「去主窗口回答」, under every card the float answers (P1Float).
    private var footer: some View {
        HStack(spacing: 8) {
            Text(L("Won't steal focus", lang: lang)).font(.system(size: 12)).foregroundStyle(Color(ShellPalette.onInkMuted))
                .lineLimit(1).minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            Button(action: Activation.onClick { g in shell.select(sessionId); MainWindow.comeBack(g) }) { Text(L("Answer in the main window", lang: lang)).lineLimit(1).minimumScaleFactor(0.85) }
                .buttonStyle(.plain).font(.system(size: 12)).layoutPriority(1).foregroundStyle(Color(ShellPalette.onInkLink))
                .accessibilityHint(L("Brings DeskMind's window forward on the card", lang: lang))
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
    }

    /// QuestionCard's foot: a hairline, then a sentence.
    private func foot(_ s: String, rule: Bool) -> some View {
        VStack(spacing: 0) {
            if rule { Rectangle().fill(Color(ShellPalette.inkRule)).frame(height: 1) }
            Text(s).font(.system(size: 12)).foregroundStyle(Color(ShellPalette.onInkFaint)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.top, 11).padding(.bottom, 13)
        }
        .padding(.top, rule ? 12 : 0)
    }

    /// Held for its take-back (QuestionCard 「已回答」): what was picked, the seconds left, 「撤回」, the countdown.
    @ViewBuilder private func held(_ layout: CardLayout) -> some View {
        if let picked = phase.pending, case .pending(_, let until) = phase {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let left = max(0, until - shell.now())
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Circle().fill(Color(ShellPalette.onInk)).frame(width: 26, height: 26)
                            .overlay(Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Color(ShellPalette.inkSurface)))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Picked: %@", CardView.picked(picked, card: card), lang: lang)).font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color(ShellPalette.onInk)).fixedSize(horizontal: false, vertical: true)
                            Text(L("Goes on in %d s", Int(left.rounded(.up)), lang: lang)).font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(Color(ShellPalette.onInkMuted))
                        }
                        Spacer(minLength: 4)
                        Button(L("Take back", lang: lang)) { if FloatController.shared.answersNow() { shell.takeBack(card) } }
                            .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color(ShellPalette.onInkLink))
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 13).fill(Color(ShellPalette.inkButton)))
                    .padding(.horizontal, 14)
                    // (the take-back's seconds as a bar, filling as they run out)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(ShellPalette.inkStop))
                            Capsule().fill(Color(ShellPalette.floatRing)).frame(width: g.size.width * (1 - left / CardStore.takeBack))
                        }
                    }
                    .frame(height: 3).padding(.horizontal, 14).padding(.top, 12)
                    .accessibilityHidden(true)
                }
                .padding(.top, 4)
            }
            foot(L("Picked the wrong one? Take it back before the countdown ends.", lang: lang), rule: false)
        }
    }

    /// Not answered here: its title (at most two lines, so the button under it is always in the float -- #125 Codex
    /// re-review at d08465d) and the way to the main window (P1Float b); a card that takes words, QuestionCard's
    /// 「要打字回答」 field that opens the window.
    @ViewBuilder private func summary(_ layout: CardLayout) -> some View {
        if card.allowsFreeText && card.kind != .plan {
            Text(Self.summary(card, layout: layout, lang: lang)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(ShellPalette.onInk))
                .lineLimit(FloatCard.summaryLines).truncationMode(.tail)
                .padding(.horizontal, 14).padding(.top, 10)
            // (the card's conversation selected first: the window shows it, not the one it showed -- #125 Codex)
            Button(action: Activation.onClick { g in shell.select(sessionId); MainWindow.comeBack(g) }) {
                HStack(spacing: 10) {
                    Text(L("Needs a typed answer", lang: lang)).font(.system(size: 14)).foregroundStyle(Color(ShellPalette.onInkMuted))
                    Spacer(minLength: 4)
                    Text(L("Answer in DeskMind", lang: lang)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(ShellPalette.onInk))
                    FloatGlyph.chevron.stroke(Color(ShellPalette.onInk), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .frame(width: 12, height: 12)
                }
                .padding(.horizontal, 14).frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(ShellPalette.inkButton)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(ShellPalette.inkButtonLine)))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityHint(L("Brings DeskMind's window forward on the card", lang: lang))
            .padding(.horizontal, 10).padding(.top, 12)
            foot(L("Typing needs the DeskMind window; you open it, it never jumps in front of you.", lang: lang), rule: true)
        } else {
            Text(Self.summary(card, layout: layout, lang: lang)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(ShellPalette.onInk))
                .lineLimit(FloatCard.summaryLines).truncationMode(.tail)
                .padding(.horizontal, 14).padding(.top, 4)
            Button(action: Activation.onClick { g in shell.select(sessionId); MainWindow.comeBack(g) }) {
                HStack(spacing: 8) {
                    Text(L("Answer in the main window", lang: lang))
                    FloatGlyph.chevron.stroke(Color(ShellPalette.inkSurface), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .frame(width: 12, height: 12)
                }
            }
            .buttonStyle(FloatButtonStyle(prominent: true))
            .accessibilityHint(L("Brings DeskMind's window forward on the card", lang: lang))
            .padding(.horizontal, 10).padding(.vertical, 12)
        }
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

    /// The picks one under another (QuestionCard: 52 tall, its number in an orange disc, its words, its second line on
    /// the right); the buttons side by side (P1Float: 可以 1 : 这一步不要 1.25 : 先别做了 1.15).
    // (in typed pieces: CI's older compiler gives up on long view expressions, rc.21)
    private func options(_ layout: CardLayout) -> some View {
        let picks: [CardLayout.Control] = layout.list, buttons: [CardLayout.Control] = layout.buttons
        let rows: [[CardLayout.Control]] = stride(from: 0, to: buttons.count, by: 3).map { Array(buttons[$0..<min($0 + 3, buttons.count)]) }
        return VStack(spacing: 8) {
            ForEach(picks, id: \.index) { c in pick(c) }
            ForEach(rows.indices, id: \.self) { i in buttonRow(rows[i]) }
        }
    }

    private func sendable(_ c: CardLayout.Control) -> Bool {
        placement.takesAnswer && shell.canSend(c.button, session: sessionId)
    }

    private func answer(_ c: CardLayout.Control) {
        // (the window's state now, at the click: in front, the chat answers and this does not)
        if FloatController.shared.answersNow() { _ = shell.click(c.button, session: sessionId, place: .float) }
    }

    private func pick(_ c: CardLayout.Control) -> some View {
        let on: Bool = sendable(c)
        let shape = RoundedRectangle(cornerRadius: 13)
        let spoken: String = c.button.detail.map { L("%@, %@", c.button.text, $0, lang: lang) } ?? c.button.text
        return Button { answer(c) } label: {
            HStack(spacing: 12) {
                if let k = c.key {
                    Text("\(k)").font(.system(size: 12, weight: .bold)).foregroundStyle(Color(ShellPalette.onInk))
                        .frame(width: 22, height: 22).background(Circle().fill(Brand.dot)).accessibilityHidden(true)
                }
                Text(c.button.text).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(ShellPalette.onInk))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let d = c.button.detail {
                    Text(d).font(.system(size: 13)).foregroundStyle(Color(ShellPalette.onInkMuted)).lineLimit(1)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 52)
            .background(shape.fill(Color(ShellPalette.inkButton)))
            .overlay(shape.strokeBorder(Color(ShellPalette.inkButtonLine)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!on).opacity(on ? 1 : 0.5)
        .accessibilityLabel(spoken)
    }

    private func buttonRow(_ row: [CardLayout.Control]) -> some View {
        let weights: [Double] = row.map { Self.weight($0.button.role) }
        return WeightedRow(weights: weights, spacing: 6) {
            ForEach(row, id: \.index) { c in
                let on: Bool = sendable(c)
                Button(c.button.text) { answer(c) }
                    .buttonStyle(FloatButtonStyle(prominent: c.prominent))
                    .disabled(!on).opacity(on ? 1 : 0.5)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// P1Float's widths by what the button does (its words are the harness's): the yes the narrowest.
    static func weight(_ r: CardModel.Role) -> Double {
        switch r {
        case .approve: 1
        case .skipStep: 1.25
        default: 1.15
        }
    }
}
