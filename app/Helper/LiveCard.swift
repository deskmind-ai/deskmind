// The live view: a card in a corner of the screen that shows the window a run is working in, live, with what it is
// doing. A run works in the background -- its windows are often behind the user's, or on a display nobody is
// looking at -- and the island at the top says what it does, not what it looks like.
//
// It lives in the helper, which holds Screen Recording: the picture never crosses the socket. The window is
// captured from its display with every other window left out and the capture cropped to the window (sourceRect),
// so a window covered by others still shows whole. Built by leaving windows out, like the recorder (ScreenRecorder.
// filter): a filter that names the window puts the purple "being shared" badge on it (macOS 26 and later).
//
// One picture at a time (SCScreenshotManager), about five a second, not a stream: while any SCStream runs, the
// models' GPU work on this Mac took about 20 % longer (a fixed MLX load: 102 ms a round without, 121-125 ms with a
// stream at 2 or 10 fps, at 1x or 2x; 102 ms with one-shot captures, even ten a second; macOS 27.2, M4 Pro) --
// every step of the run would have waited for the card.
//
// The card:
// - header: 小方 (its eyes on the agent's cursor, up at you when it needs you, ^ ^ when done; the orange dot at its foot
//   is the status light), the app, the step or the status; on hover, Larger/Smaller, Collapse and Stop;
// - the picture, with the agent's cursor where the last step acted (the run never moves the real pointer);
// - the step being taken, in words.
// Dragged, it snaps to the nearest corner and stays there for later runs; double-clicked, it grows. Collapsed, it
// is a capsule with the status and the step (and the capture pauses). When the run needs the user (a question, an
// approval) the card says so, and a click on it opens DeskMind. When the run ends it says how, then fades.
//
// It keeps out of the way of the window being worked in: a corner where the card would cover that window is
// skipped. When every corner would (a window filling the screen, as most people keep their apps), the card stays
// over the window in the corner farthest from where the run has acted, and lets clicks through -- a click the run
// makes in the foreground lands on the app -- until the user rests the pointer on it for half a second (a run's click
// is instant); then its buttons work. It never becomes the active window.
//
// It is an ordinary shareable window: the user's own screenshots and screen sharing show it. hands' screenshots are
// window captures (deskmind_hands/drivers/capture.py), so it is never in what the models see; a task recording
// leaves out every window that is not the task's (ScreenRecorder.filter), and recording the whole screen keeps it.
//
// Which window: the one hands observes (the `active` window of the trace's latest observation), else the largest
// window of the app it works in. Checked every 0.5 s, so a window that moves, resizes or changes display is
// followed; a window that is minimized, closed or on another Space leaves its last picture, dimmed, with a note.
// Started by Runner when a run starts with "live_view", finished when the run ends.

import AppKit
import CoreMedia
import QuartzCore
import ScreenCaptureKit

final class LiveCard: NSObject {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var shared: LiveCard?
    private static let cornerKey = "liveView.corner", largeKey = "liveView.large"

    // MARK: state shared by the trace poller, the watch thread and the main thread (under `state`)

    private let state = NSLock()
    private var activeWindow: Int?
    private var appName = ""
    /// hands has looked at the screen at least once (see LiveView.pick).
    private var observedOnce = false
    /// A question the run is waiting on, answered in the card (main thread).
    struct Ask { var question: String; var options: [String]; var kind: LiveView.AskKind
        var picked: (reply: String, approve: Bool, label: String)?; var token = 0; var deadline: Date? }
    fileprivate var asking: Ask?
    /// The pick counting down to the run (main thread): cancelled by Undo, a new question, Stop, the end of the run
    /// and the card closing, so a pick reaches only the run and the question it was made for.
    private var pendingAnswer: DispatchWorkItem?
    /// The last pick's token (main thread). One counter for every question, card and run: a countdown that outlived
    /// its question can never match a newer pick.
    nonisolated(unsafe) private static var lastToken = 0
    private let bundles: [String]
    /// What to capture now (nil: nothing -- collapsed, no window, or the run has ended), and what it was made from.
    private var target: (filter: SCContentFilter, config: SCStreamConfiguration)?
    private var shown: (window: Int, frame: CGRect, display: CGDirectDisplayID, drop: Set<Int>, pixels: CGSize)?
    private var watching = true
    /// Collapsed to the capsule (by the user): no capture.
    private var collapsed = false
    private var large = UserDefaults.standard.bool(forKey: largeKey)
    /// The run's own status (working, needs the user, paused, ended); `hidden` is the window's, layered on top.
    private var runStatus: LiveView.Status = .starting
    /// Why the run didn't finish, once it has ended (an L() key).
    private var endNote: String?
    private var windowHidden = false
    private var step = 0
    private var hadPicture = false
    /// How often the window is looked for (s), the pause between two pictures (s), and pixels per point of the
    /// picture. Tunable without a rebuild (`defaults write ai.deskmind.hands liveView.interval 0.5`).
    private let poll = max(0.2, UserDefaults.standard.object(forKey: "liveView.poll") as? Double ?? 0.5)
    private let interval = max(0.05, UserDefaults.standard.object(forKey: "liveView.interval") as? Double ?? 0.2)
    private let pixelScale = max(1, UserDefaults.standard.object(forKey: "liveView.scale") as? Double ?? 2)

    // MARK: main thread only

    private var panel: NSPanel?
    private var view: CardView?
    private var corner = LiveView.Corner(rawValue: UserDefaults.standard.string(forKey: cornerKey) ?? "") ?? .bottomRight
    private var lastWindow: CGRect?          // top-left global, the window's frame as last seen
    private var lastTarget: CGPoint?         // top-left global, where the last step acted
    private var recentTargets: [CGPoint] = []   // the last few, for keeping the card away from them
    private var covers = false               // the card is over the window being worked in
    private var pointerSince: Date?          // the pointer has been on the card since
    private var hoverTimer: Timer?

    /// What Stop on the card does (Runner.requestStop in the helper; a test's own in tests/e2e).
    private let onStop: () -> Void
    /// Hands an answer to the run (Runner.answer, which also tells the app); and asks the app to show its window for a
    /// typed answer. A test's own in tests/e2e.
    private let onAnswer: (String, Bool) -> Bool
    private let onOpenWindow: () -> Void

    /// The instruction: the action line until the first step.
    private let goal: String

    private init(bundles: [String], goal: String, onStop: @escaping () -> Void,
                 onAnswer: @escaping (String, Bool) -> Bool, onOpenWindow: @escaping () -> Void) {
        self.bundles = bundles; self.goal = goal; self.onStop = onStop; self.onAnswer = onAnswer; self.onOpenWindow = onOpenWindow
    }

    // MARK: from Runner

    static func start(bundles: [String], goal: String = "", onStop: @escaping () -> Void,
                      onAnswer: @escaping (String, Bool) -> Bool = { _, _ in false }, onOpenWindow: @escaping () -> Void = {}) {
        let card = LiveCard(bundles: bundles, goal: goal, onStop: onStop, onAnswer: onAnswer, onOpenWindow: onOpenWindow)
        lock.lock(); let old = shared; shared = card; lock.unlock()
        // A card still saying how the last run ended goes now, not over the new one.
        if let old { old.set { $0.watching = false }; old.stopCapture(); DispatchQueue.main.async { old.close() } }
        DispatchQueue.main.async { card.makePanel() }
        card.watch()
        card.capture()
    }

    /// The run has ended. With how it ended, the card says so for a moment, its last picture frozen, then goes; with
    /// nil it goes at once (unless it is already saying how the run ended).
    /// `why`: why it didn't finish (an L() key, see LiveView.endingNote), written over the dimmed last picture, which
    /// then stays a little longer to be read.
    static func finish(_ ending: LiveView.Status?, why: String? = nil) {
        lock.lock(); let card = shared; if ending == nil || card?.runStatus.isEnding == true { shared = nil }; lock.unlock()
        guard let card else { return }
        if let ending, !card.runStatus.isEnding {
            card.stopCapture()
            DispatchQueue.main.async { card.dropQuestion() }
            card.set { $0.runStatus = ending; $0.endNote = ending == .failed ? why : nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + (ending == .failed && why != nil ? 4 : 2.5)) {
                lock.lock(); if shared === card { shared = nil }; lock.unlock()
                card.close()
            }
        } else if ending == nil, !card.runStatus.isEnding {
            card.stopCapture()
            DispatchQueue.main.async { card.close() }
        }
    }

    /// An observation: the window hands is looking at, and its app.
    static func observed(windows: [[String: Any]], app: String) {
        current?.set { c in
            c.observedOnce = true
            if let id = LiveView.activeWindowID(windows) { c.activeWindow = id }
            if !app.isEmpty { c.appName = app }
        }
    }

    /// A step was taken: its number, its words and where it acted (hands' target_rect).
    static func stepped(n: Int, words: String, target: Any?, click: Bool) {
        guard let card = current else { return }
        card.set { c in
            c.step = n
            if c.runStatus != .working && !c.runStatus.isEnding { c.runStatus = .working }
        }
        questionClosed()   // a step after a question: it was answered
        let p = LiveView.targetCenter(target)
        DispatchQueue.main.async {
            card.view?.line.stringValue = words
            if let p {
                card.lastTarget = p; card.recentTargets = Array((card.recentTargets + [p]).suffix(6))
                card.placeCursor(ripple: click)
            }
            card.refresh()
        }
    }

    /// The run is waiting for the user (a question or an approval), or paused while they use the Mac, with the
    /// line to show; or back at work.
    static func status(_ s: LiveView.Status, words: String? = nil) {
        guard let card = current else { return }
        card.set { c in if !c.runStatus.isEnding { c.runStatus = s } }
        DispatchQueue.main.async {
            if let words { card.view?.line.stringValue = words }
            card.refresh()
        }
    }

    /// The run asks the user something: the card shows the question (opening up if it was collapsed) and its
    /// options, and is answered there. Returns whether a card is showing it (so the app need not bring its window).
    @discardableResult
    static func ask(question: String, options: [String], approval: Bool) -> Bool {
        guard let card = current else { return false }
        let kind = LiveView.askKind(options: options, approval: approval)
        card.set { c in c.runStatus = .waitingForUser; c.collapsed = false }
        DispatchQueue.main.async {
            card.cancelPending()
            card.asking = Ask(question: question, options: LiveView.askOptions(options), kind: kind, picked: nil)
            card.refresh()
        }
        return true
    }

    /// The question is over (answered in DeskMind's window, or the run went on): the card goes back to the picture.
    static func questionClosed() {
        guard let card = current else { return }
        card.set { c in if c.runStatus == .waitingForUser { c.runStatus = .working } }
        DispatchQueue.main.async { card.dropQuestion() }
    }

    private static var current: LiveCard? { lock.lock(); defer { lock.unlock() }; return shared }

    private func set(_ f: (LiveCard) -> Void) {
        state.lock(); f(self); state.unlock()
        DispatchQueue.main.async { self.refresh() }
    }

    private func read<T>(_ f: (LiveCard) -> T) -> T { state.lock(); defer { state.unlock() }; return f(self) }

    // MARK: the panel

    private func makePanel() {
        guard read({ $0.watching }) else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        let v = CardView(frame: .zero)
        v.card = self
        v.line.stringValue = goal.replacingOccurrences(of: "\n", with: " ")
        p.contentView = v
        p.setAccessibilityLabel(L("DeskMind live view", lang: ResolvedLang.current))
        panel = p; view = v
        refresh()
        // Over the window being worked in the card lets clicks through, so it cannot see the pointer itself: where the
        // pointer is gets checked here (its position only, no events), and resting on the card makes it clickable.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.trackPointer() }
    }

    private func trackPointer() {
        guard let p = panel else { return }
        let on = p.frame.contains(NSEvent.mouseLocation)
        if on { if pointerSince == nil { pointerSince = Date() } } else { pointerSince = nil }
        let take = LiveView.interactive(covers: covers, pointerOnCardFor: pointerSince.map { Date().timeIntervalSince($0) })
        if p.ignoresMouseEvents == take { p.ignoresMouseEvents = !take; view?.hoverChanged(on && take) }
    }

    /// Size, place, show what the state says. Main thread.
    fileprivate func refresh() {
        guard let p = panel, let v = view else { return }
        let (status, userCollapsed, large, step, app, hadPicture, endNote) = read { c -> (LiveView.Status, Bool, Bool, Int, String, Bool, String?) in
            let s: LiveView.Status = c.runStatus.isEnding || c.runStatus == .waitingForUser ? c.runStatus
                : (c.windowHidden && c.hadPicture ? .hidden : c.runStatus)
            return (s, c.collapsed, c.large, c.step, c.appName, c.hadPicture, c.endNote)
        }
        let lang = ResolvedLang.current
        let shownApp = v.appTitle.isEmpty ? app.components(separatedBy: " (").first ?? app : v.appTitle
        let detail = status == .working && step > 0 ? L("Step %d", step, lang: lang) : L(LiveView.word(status), lang: lang)
        v.title.stringValue = shownApp.isEmpty ? detail : "\(shownApp) · \(detail)"
        v.setStatus(status)
        v.toolTip = status == .waitingForUser ? L("Click to answer in DeskMind", lang: lang) : nil

        let screen = targetScreen()
        let visible = screen.visibleFrame
        let mainHeight = NSScreen.screens.first?.frame.height ?? visible.maxY
        let avoid = lastWindow.map { LiveView.toAppKit($0, mainHeight: mainHeight) }.flatMap { $0.intersects(screen.frame) ? $0 : nil }
        let pic = LiveView.pictureSize(window: lastWindow?.size ?? .zero, box: large ? LiveView.maxPictureLarge : LiveView.maxPicture)
        let cardSize = LiveView.cardSize(picture: pic)
        // A window filling the screen (most people keep their apps that way) leaves no clear corner: the card stays,
        // over the window, in the corner farthest from where the run has acted, letting clicks through until the
        // user rests the pointer on it. (It used to become the capsule, and a maximized app never had a picture.)
        let collapsed = userCollapsed && asking == nil
        var size = collapsed ? LiveView.pill : cardSize
        if let a = asking, !collapsed {
            v.showAsk(a, lang: lang)
            size = CGSize(width: LiveView.askWidth, height: LiveView.headerHeight + LiveView.askPictureHeight + v.askHeight(width: LiveView.askWidth))
        } else {
            v.hideAsk()
        }
        let recent = recentTargets.map { LiveView.toAppKit(CGRect(origin: $0, size: .zero), mainHeight: mainHeight).origin }
        let placed = LiveView.place(size: size, preferred: corner, visible: visible, avoid: avoid, recent: recent)
        let frame = LiveView.frame(size: size, corner: placed.corner, visible: visible)
        // While the run waits on the user nothing it does can land under the card: the card takes clicks then.
        covers = placed.covers && asking == nil
        p.ignoresMouseEvents = !LiveView.interactive(covers: covers, pointerOnCardFor: pointerSince.map { Date().timeIntervalSince($0) })
        let note: String? = if let endNote, status == .failed { L(endNote, lang: lang) }
            else if status == .hidden || !hadPicture { L(LiveView.word(status == .hidden ? .hidden : .starting), lang: lang) }
            else { nil }
        v.layoutCard(collapsed: collapsed, large: large, size: size, asking: asking != nil,
                     dimmed: status == .hidden || (endNote != nil && status == .failed), note: note)
        if p.frame != frame {
            if p.isVisible && !v.dragging && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.2; p.animator().setFrame(frame, display: true) }
            } else if !v.dragging {
                p.setFrame(frame, display: true)
            }
        }
        if !p.isVisible { p.alphaValue = 1; p.orderFrontRegardless() }
        placeCursor(ripple: false)
    }

    /// The screen the card is on: the one it was put on, else the one with the pointer (where the user is).
    private func targetScreen() -> NSScreen {
        if let p = panel, p.isVisible, let s = p.screen { return s }
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func placeCursor(ripple: Bool) {
        guard let v = view, let w = lastWindow else { return }
        let pt = lastTarget.flatMap { LiveView.cursor(at: $0, window: w, picture: v.picture.bounds.size) }
        v.moveCursor(to: pt, ripple: ripple)
    }

    private func close() {
        cancelPending(); asking = nil
        hoverTimer?.invalidate(); hoverTimer = nil
        guard let p = panel else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            p.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
        }
        panel = nil; view = nil
    }

    // MARK: what the card's controls do (main thread)

    fileprivate func toggleLarge() {
        set { c in c.large.toggle(); UserDefaults.standard.set(c.large, forKey: Self.largeKey); c.shown = nil }
    }

    fileprivate func toggleCollapsed() {
        let nowCollapsed = read { !$0.collapsed }
        set { $0.collapsed = nowCollapsed }
        if nowCollapsed { stopCapture() }   // started again by the next check
    }

    fileprivate func stopRun() {
        dropQuestion()
        set { c in if c.runStatus == .waitingForUser { c.runStatus = .working } }
        onStop()
    }

    /// A click on the card: a question waiting opens DeskMind, a capsule opens up.
    fileprivate func clicked() {
        if asking != nil { return }   // its buttons answer it
        if read({ $0.runStatus == .waitingForUser }) {
            onOpenWindow()
        } else if read({ $0.collapsed }) {
            toggleCollapsed()
        }
    }

    // MARK: answering in the card (main thread)

    /// An option or an approval picked: shown as picked, with a few seconds to undo, then handed to the run.
    fileprivate func pick(reply: String, approve: Bool, label: String) {
        guard var a = asking, a.picked == nil else { return }
        Self.lastToken += 1
        a.token = Self.lastToken
        a.picked = (reply, approve, label)
        a.deadline = Date().addingTimeInterval(LiveView.undoSeconds)
        asking = a
        refresh()
        let token = a.token
        cancelPending()
        // Handed on only if, when the countdown ends, this is still the run's card (not replaced by a new run's),
        // the run has not ended, and the same pick of the same question is still showing, its deadline passed.
        let work = DispatchWorkItem { [weak self] in
            guard let self, Self.current === self, !self.read({ $0.runStatus.isEnding }),
                  let now = self.asking, now.token == token, let p = now.picked,
                  let deadline = now.deadline, Date() >= deadline.addingTimeInterval(-0.05) else { return }
            self.pendingAnswer = nil
            self.asking = nil
            self.set { $0.runStatus = .working }
            if !self.onAnswer(p.reply, p.approve) { NSLog("DeskMind Hands: live view: the run took no answer") }
        }
        pendingAnswer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LiveView.undoSeconds, execute: work)
    }

    fileprivate func undo() {
        guard var a = asking, a.picked != nil else { return }
        cancelPending()
        Self.lastToken += 1
        a.token = Self.lastToken; a.picked = nil; a.deadline = nil
        asking = a
        refresh()
    }

    private func cancelPending() { pendingAnswer?.cancel(); pendingAnswer = nil }

    /// The question is over, whatever was picked: nothing more goes to the run from it.
    fileprivate func dropQuestion() {
        cancelPending()
        guard asking != nil else { return }
        asking = nil
        refresh()
    }

    /// "Neither — let me type it…" and a question that needs typing: DeskMind's window, where typing belongs.
    fileprivate func answerInWindow() { onOpenWindow() }

    /// Let go after a drag: the nearest corner of the screen it was dropped on, kept for later runs.
    fileprivate func dropped() {
        guard let p = panel, let s = p.screen ?? NSScreen.main else { return }
        corner = LiveView.nearestCorner(center: CGPoint(x: p.frame.midX, y: p.frame.midY), visible: s.visibleFrame)
        UserDefaults.standard.set(corner.rawValue, forKey: Self.cornerKey)
        refresh()
    }

    // MARK: following the window (its own thread)

    private func watch() {
        Thread.detachNewThread { [weak self] in
            while let self, self.read({ $0.watching }) {
                self.update()
                Thread.sleep(forTimeInterval: self.poll)
            }
        }
    }

    private func update() {
        guard let content = Self.content() else { return }
        let candidates = content.windows.map { w in
            LiveView.Candidate(id: Int(w.windowID), appName: w.owningApplication?.applicationName ?? "",
                               bundle: w.owningApplication?.bundleIdentifier ?? "", layer: w.windowLayer,
                               onScreen: w.isOnScreen, frame: w.frame)
        }
        state.lock()
        guard watching, !runStatus.isEnding else { state.unlock(); return }
        let (active, app, isCollapsed, isLarge, observed) = (activeWindow, appName, collapsed, large, observedOnce)
        state.unlock()
        guard let id = LiveView.pick(candidates, active: active, app: app, bundles: bundles, observed: observed),
              let window = content.windows.first(where: { Int($0.windowID) == id }),
              let display = content.displays.first(where: { !$0.frame.intersection(window.frame).isNull })
                ?? content.displays.first else {
            // Minimized, closed, hidden or on another Space: the last picture stays, dimmed.
            set { $0.windowHidden = true }
            return
        }
        let title = window.owningApplication?.applicationName ?? ""
        let frame = window.frame
        set { $0.windowHidden = false }
        DispatchQueue.main.async {
            let moved = self.lastWindow != frame
            self.lastWindow = frame
            if self.view?.appTitle != title { self.view?.appTitle = title; self.view?.crossfade() }
            if moved { self.refresh() }
        }
        guard !isCollapsed else { return }

        // Everything but the window's own app (its sheets and popovers belong to it), the card included.
        let pid = window.owningApplication?.processID
        let drop = content.windows.filter { $0.owningApplication?.processID != pid }
        let dropIDs = Set(drop.map { Int($0.windowID) })
        let pic = LiveView.pictureSize(window: frame.size, box: isLarge ? LiveView.maxPictureLarge : LiveView.maxPicture)
        let filter = SCContentFilter(display: display, excludingWindows: drop)
        let px = LiveView.capturePixels(picture: pic, window: frame.size, scale: CGFloat(filter.pointPixelScale),
                                        perPoint: CGFloat(pixelScale))
        let pixels = CGSize(width: px.0, height: px.1)
        state.lock(); defer { state.unlock() }
        guard watching, !collapsed else { return }
        if let s = shown, s.window == id, s.frame == frame, s.display == display.displayID, s.drop == dropIDs,
           s.pixels == pixels, target != nil { return }
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = LiveView.sourceRect(window: frame, display: display.frame)
        (cfg.width, cfg.height) = px
        cfg.showsCursor = false      // the run never moves the pointer; the card draws where it acted
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        shown = (id, frame, display.displayID, dropIDs, pixels)
        target = (filter, cfg)
    }

    /// The pictures: one capture of the current target, then a pause, while the card lives (its own thread).
    private func capture() {
        Thread.detachNewThread { [weak self] in
            var loggedFailure: SCContentFilter?
            while let self, self.read({ $0.watching }) {
                if let t = self.read({ $0.target }) {
                    let done = DispatchSemaphore(value: 0)
                    var image: CGImage?
                    var failure: String?
                    SCScreenshotManager.captureImage(contentFilter: t.filter, configuration: t.config) { img, err in
                        image = img; failure = err?.localizedDescription
                        done.signal()
                    }
                    _ = done.wait(timeout: .now() + 3)
                    // A window that just left the screen fails until the next check retargets: said once, not five
                    // times a second.
                    if let failure, loggedFailure !== t.filter { loggedFailure = t.filter; NSLog("DeskMind Hands: live view: \(failure)") }
                    // Still wanted (not stopped, collapsed or retargeted while it was taken)?
                    if let image, self.read({ $0.target?.filter === t.filter && $0.watching }) {
                        let first = self.read { c -> Bool in let f = !c.hadPicture; c.hadPicture = true; return f }
                        DispatchQueue.main.async { [weak self] in
                            self?.view?.show(image)
                            if first { self?.refresh() }
                        }
                    }
                }
                Thread.sleep(forTimeInterval: self.interval)
            }
        }
    }

    private func stopCapture() {
        state.lock()
        target = nil; shown = nil
        if runStatus.isEnding { watching = false }
        state.unlock()
    }

    private static func content() -> SCShareableContent? {
        let got = DispatchSemaphore(value: 0)
        var content: SCShareableContent?
        // Desktop windows listed too, so the wallpaper is among what is left out.
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, _ in
            content = c; got.signal()
        }
        return got.wait(timeout: .now() + 5) == .success ? content : nil
    }
}

// MARK: - for tests/e2e/LiveViewE2E.swift (main thread)

extension LiveCard {
    /// What the card shows and does now, for an end-to-end test to check.
    static func snapshot() -> [String: Any] {
        guard let card = current else { return ["card": false] }
        let (status, collapsed, large, streaming, watching, hidden) = card.read {
            ($0.runStatus, $0.collapsed, $0.large, $0.target != nil, $0.watching, $0.windowHidden)
        }
        var out: [String: Any] = ["card": true, "status": LiveView.word(status), "collapsed": collapsed, "large": large,
                                  "covers": card.covers,
                                  "streaming": streaming, "watching": watching, "window_hidden": hidden,
                                  "corner": card.corner.rawValue]
        if let p = card.panel {
            out["visible"] = p.isVisible
            out["frame"] = NSStringFromRect(p.frame)
            out["window_number"] = p.windowNumber
            out["click_through"] = p.ignoresMouseEvents
            out["screen_visible"] = NSStringFromRect((p.screen ?? NSScreen.main)?.visibleFrame ?? .zero)
        }
        if let v = card.view {
            out["title"] = v.title.stringValue
            out["line"] = v.line.stringValue
            out["cursor"] = v.cursorShown ? NSStringFromPoint(v.cursorPosition) : NSNull()
            out["picture"] = NSStringFromRect(v.picture.frame)
            out["note"] = v.noteText
            out["hint"] = v.hintText
            out["face"] = v.faceName
            out["asking"] = card.asking != nil
            out["ask_options"] = v.ask.optionCount
            out["ask_picked"] = card.asking?.picked?.label ?? NSNull()
            out["ask_countdowns"] = v.ask.countdownRuns
        }
        return out
    }

    /// Press one of the card's controls, or drop it at a point (AppKit coordinates), as a person would.
    static func press(_ control: String, at point: NSPoint? = nil) {
        guard let card = current else { return }
        switch control {
        case "larger": card.toggleLarge()
        case "collapse": card.toggleCollapsed()
        case "stop": card.stopRun()
        case "click": card.clicked()
        case "option0", "option1", "option2", "option3": card.view?.ask.press(option: Int(String(control.last!))!)
        case "undo": card.view?.ask.pressUndo()
        case "hover": card.view?.hoverChanged(true)
        case "unhover": card.view?.hoverChanged(false)
        case "drop":
            if let p = card.panel, let point { p.setFrameOrigin(NSPoint(x: point.x - p.frame.width / 2, y: point.y - p.frame.height / 2)) }
            card.dropped()
        default: break
        }
    }
}

// MARK: - the card's view

/// Header (小方 and its status dot, title, buttons on hover), picture with the agent's cursor, the action line; or the
/// capsule.
final class CardView: NSView {
    weak var card: LiveCard?
    let picture = CALayer()
    let line = NSTextField(labelWithString: "")
    let title = NSTextField(labelWithString: "")
    var appTitle = ""
    private let note = NSTextField(labelWithString: "")
    /// 小方 in the title bar: its frame, its eyes, and the orange dot at its foot (the status light).
    private let face = CALayer()
    private let faceFrame = CAShapeLayer()
    private let eyes = CAShapeLayer()
    private let dot = CALayer()
    private var faceKind: LiveView.Face = .look
    private var gaze = CGPoint(x: 0, y: 0.6)
    var faceName: String { faceKind.rawValue }
    /// The question, while the run waits on the user: under the (smaller) picture, in place of the action line.
    let ask = AskView(frame: .zero)
    private let cursor = CALayer()
    var cursorShown: Bool { cursor.opacity > 0 && !cursor.isHidden }
    var cursorPosition: CGPoint { cursor.position }
    var noteText: String { note.isHidden ? "" : note.stringValue }
    /// The one-time hint the first time the pointer rests on a card: what double-click and drag do.
    private let hint = NSTextField(labelWithString: "")
    static let hintKey = "liveView.hintSeen"
    var hintText: String { hint.isHidden || hint.alphaValue == 0 ? "" : hint.stringValue }
    private let ripple = CALayer()
    private var buttons: [NSButton] = []
    private var largeButton: NSButton!
    private var hovering = false
    private var collapsed = false
    private var downAt: NSPoint?
    private(set) var dragging = false

    // DeskMind's colours (Main/Brand.swift): ink for the chrome, the orange dot for the agent, mist for quiet states.
    static let orange = NSColor(srgbRed: 0xC9 / 255.0, green: 0x55 / 255.0, blue: 0x36 / 255.0, alpha: 1)
    static let mist = NSColor(srgbRed: 0xB2 / 255.0, green: 0xBB / 255.0, blue: 0xAF / 255.0, alpha: 1)
    static let paper = NSColor(srgbRed: 0xF4 / 255.0, green: 0xF1 / 255.0, blue: 0xEA / 255.0, alpha: 1)
    private static let chrome = NSColor(srgbRed: 0x26 / 255.0, green: 0x2B / 255.0, blue: 0x28 / 255.0, alpha: 0.96)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.backgroundColor = Self.chrome.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.08).cgColor

        picture.contentsGravity = .resizeAspect
        picture.backgroundColor = NSColor(calibratedWhite: 0.93, alpha: 1).cgColor
        picture.cornerRadius = 6
        picture.masksToBounds = true
        layer?.addSublayer(picture)

        ripple.bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
        ripple.cornerRadius = 11
        ripple.borderWidth = 2
        ripple.borderColor = Self.orange.cgColor
        ripple.opacity = 0
        picture.addSublayer(ripple)
        cursor.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        cursor.cornerRadius = 6
        cursor.backgroundColor = Self.orange.cgColor
        cursor.borderWidth = 2
        cursor.borderColor = NSColor.white.cgColor
        cursor.shadowOpacity = 0.35
        cursor.shadowRadius = 2
        cursor.shadowOffset = .zero
        cursor.opacity = 0
        picture.addSublayer(cursor)

        face.bounds = CGRect(x: 0, y: 0, width: 20, height: 17)
        face.isGeometryFlipped = true   // drawn top-left, like the brand mark
        faceFrame.path = CGPath(roundedRect: CGRect(x: 1, y: 1, width: 15, height: 13), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
        faceFrame.fillColor = nil
        faceFrame.strokeColor = Self.paper.cgColor
        faceFrame.lineWidth = 2
        face.addSublayer(faceFrame)
        eyes.lineCap = .round
        face.addSublayer(eyes)
        dot.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
        dot.cornerRadius = 3.5
        dot.position = CGPoint(x: 16.5, y: 13.5)
        face.addSublayer(dot)
        layer?.addSublayer(face)
        drawEyes(animated: false)

        for t in [title, line, note] {
            t.lineBreakMode = .byTruncatingTail
            t.maximumNumberOfLines = 1
            addSubview(t)
        }
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = NSColor(calibratedWhite: 1, alpha: 0.9)
        line.font = .systemFont(ofSize: 12, weight: .regular)
        line.textColor = NSColor(calibratedWhite: 1, alpha: 0.85)
        note.font = .systemFont(ofSize: 12, weight: .medium)
        note.textColor = NSColor(calibratedWhite: 0.2, alpha: 1)
        note.alignment = .center
        note.maximumNumberOfLines = 2
        note.lineBreakMode = .byWordWrapping
        note.cell?.truncatesLastVisibleLine = true
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = NSColor(calibratedWhite: 1, alpha: 0.95)
        hint.alignment = .center
        hint.wantsLayer = true
        hint.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.62).cgColor
        hint.layer?.cornerRadius = 9
        hint.isHidden = true
        addSubview(hint)

        let lang = ResolvedLang.current
        largeButton = button("arrow.up.left.and.arrow.down.right", L("Larger", lang: lang)) { $0.toggleLarge() }
        buttons = [largeButton,
                   button("chevron.down", L("Collapse", lang: lang)) { $0.toggleCollapsed() },
                   button("stop.fill", L("Stop the task", lang: lang)) { $0.stopRun() }]
        for b in buttons { b.alphaValue = 0; addSubview(b) }
        ask.isHidden = true
        addSubview(ask)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var actions: [ObjectIdentifier: (LiveCard) -> Void] = [:]
    private func button(_ symbol: String, _ tip: String, _ act: @escaping (LiveCard) -> Void) -> NSButton {
        let b = FirstMouseButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                                 target: nil, action: nil)
        b.isBordered = false
        b.contentTintColor = NSColor(calibratedWhite: 1, alpha: 0.85)
        b.toolTip = tip
        b.target = self
        b.action = #selector(pressed(_:))
        actions[ObjectIdentifier(b)] = act
        return b
    }

    @objc private func pressed(_ b: NSButton) {
        if let card, let act = actions[ObjectIdentifier(b)] { act(card) }
    }

    func showAsk(_ a: LiveCard.Ask, lang: ResolvedLang) {
        ask.card = card
        ask.configure(a, lang: lang)
        ask.isHidden = false
    }

    func hideAsk() { ask.isHidden = true }

    func askHeight(width: CGFloat) -> CGFloat { ask.height(width: width) }

    func layoutCard(collapsed: Bool, large big: Bool, size: CGSize, asking: Bool = false, dimmed: Bool, note text: String?) {
        self.collapsed = collapsed
        let h = LiveView.headerHeight, lh = LiveView.lineHeight
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if collapsed {
            layer?.cornerRadius = size.height / 2
            picture.isHidden = true
            face.position = CGPoint(x: 22, y: size.height / 2)
            title.frame = NSRect(x: 38, y: (size.height - 16) / 2, width: size.width - 38 - 40, height: 16)
            line.isHidden = true
            buttons[2].frame = NSRect(x: size.width - 32, y: (size.height - 20) / 2, width: 20, height: 20)
            for (i, b) in buttons.enumerated() { b.isHidden = i != 2 }
        } else {
            layer?.cornerRadius = 14
            picture.isHidden = false
            let below = asking ? ask.height(width: size.width) : lh
            picture.frame = CGRect(x: 0, y: below, width: size.width, height: size.height - h - below)
            if asking { ask.frame = NSRect(x: 0, y: 0, width: size.width, height: below) }
            picture.opacity = dimmed ? 0.35 : 1
            face.position = CGPoint(x: 21, y: size.height - h / 2)
            title.frame = NSRect(x: 37, y: size.height - h + (h - 16) / 2, width: size.width - 37 - 92, height: 16)
            line.isHidden = asking
            line.frame = NSRect(x: 12, y: (lh - 16) / 2, width: size.width - 24, height: 16)
            for (i, b) in buttons.enumerated() {
                b.isHidden = false
                b.frame = NSRect(x: size.width - CGFloat(3 - i) * 28 - 4, y: size.height - h + (h - 20) / 2, width: 24, height: 20)
            }
            let lang = ResolvedLang.current
            largeButton.image = NSImage(systemSymbolName: big ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                        accessibilityDescription: nil)
            largeButton.toolTip = big ? L("Smaller", lang: lang) : L("Larger", lang: lang)
        }
        note.isHidden = collapsed || text == nil
        note.stringValue = text ?? ""
        let wraps = text != nil && note.attributedStringValue.boundingRect(with: NSSize(width: size.width - 24, height: 40),
                                                                            options: [.usesLineFragmentOrigin]).height > 18
        let noteHeight: CGFloat = wraps ? 32 : 16
        note.frame = NSRect(x: 12, y: picture.frame.minY + (picture.frame.height - noteHeight) / 2, width: size.width - 24, height: noteHeight)
        let hw = min(size.width - 24, hint.intrinsicContentSize.width + 20)
        hint.frame = NSRect(x: (size.width - hw) / 2, y: picture.frame.minY + 8, width: hw, height: 18)
        if collapsed || asking { hint.isHidden = true }
        CATransaction.commit()
        for b in buttons where !b.isHidden { b.alphaValue = hovering || collapsed ? 1 : 0 }
        resetTracking()
        setAccessibilityLabel("\(title.stringValue). \(line.stringValue)")
    }

    func setStatus(_ s: LiveView.Status) {
        // Orange is the agent at work and the run needing the user (it pulses faster); an ending is quiet.
        let color: NSColor = switch s {
        case .working, .starting, .waitingForUser: Self.orange
        case .done: Self.paper
        case .failed, .paused, .hidden, .stopped: Self.mist
        }
        dot.backgroundColor = color.cgColor
        dot.removeAnimation(forKey: "pulse")
        if (s == .working || s == .waitingForUser) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1; a.toValue = 0.35; a.duration = s == .waitingForUser ? 0.6 : 1.0
            a.autoreverses = true; a.repeatCount = .infinity
            dot.add(a, forKey: "pulse")
        }
        if s.isEnding { cursor.opacity = 0 }
        let kind = LiveView.face(s)
        if kind != faceKind { faceKind = kind; drawEyes(animated: true) }
    }

    /// The eyes for the current face and gaze (face coordinates, top-left; resting centres 6 and 10.5, height 6).
    private func drawEyes(animated: Bool) {
        let path = CGMutablePath()
        let y: CGFloat = faceKind == .up ? 4.6 : 6 + gaze.y
        let dx: CGFloat = faceKind == .look ? gaze.x : 0
        for cx in [CGFloat(6), 10.5] {
            let x = cx + dx
            switch faceKind {
            case .look: path.addEllipse(in: CGRect(x: x - 1.2, y: y - 1.2, width: 2.4, height: 2.4))
            case .up: path.addEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
            case .happy:
                path.move(to: CGPoint(x: x - 1.6, y: 6.8)); path.addQuadCurve(to: CGPoint(x: x + 1.6, y: 6.8), control: CGPoint(x: x, y: 4.4))
            case .flat:
                path.move(to: CGPoint(x: x - 1.6, y: 6.2)); path.addLine(to: CGPoint(x: x + 1.6, y: 6.2))
            }
        }
        let filled = faceKind == .look || faceKind == .up
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        CATransaction.setAnimationDuration(0.25)
        eyes.path = path
        eyes.fillColor = filled ? Self.paper.cgColor : nil
        eyes.strokeColor = filled ? nil : Self.paper.cgColor
        eyes.lineWidth = filled ? 0 : 1.4
        CATransaction.commit()
    }

    func show(_ image: CGImage) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.contents = image
        CATransaction.commit()
    }

    /// Another app's window: a short fade from the old picture.
    func crossfade() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let t = CATransition(); t.type = .fade; t.duration = 0.25
        picture.add(t, forKey: "app")
        cursor.opacity = 0
    }

    /// The agent's cursor glides to where the step acted; a click leaves a ring.
    func moveCursor(to p: CGPoint?, ripple click: Bool) {
        // 小方 looks where the agent acts.
        let look = LiveView.gaze(cursor: collapsed ? nil : p, picture: picture.bounds.size)
        if look != gaze { gaze = look; if faceKind == .look { drawEyes(animated: true) } }
        guard let p, !collapsed else { cursor.opacity = 0; return }
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(still || cursor.opacity == 0)
        CATransaction.setAnimationDuration(0.35)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        cursor.position = p
        cursor.opacity = 1
        CATransaction.commit()
        guard click, !still else { return }
        ripple.position = p
        let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 0.6; scale.toValue = 2.2
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.9; fade.toValue = 0
        let g = CAAnimationGroup(); g.animations = [scale, fade]; g.duration = 0.55
        g.beginTime = CACurrentMediaTime() + 0.3   // when the cursor arrives
        g.fillMode = .backwards
        ripple.add(g, forKey: "ripple")
    }

    // Hover: the buttons fade in.
    private var tracking: NSTrackingArea?
    private func resetTracking() {
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }
    /// Made clickable while the pointer rests on it (over the window being worked in): the buttons show then, as
    /// tracking areas see no entry in a window that was letting clicks through.
    func hoverChanged(_ on: Bool) { if on != hovering { hover(on) } }
    override func mouseEntered(with event: NSEvent) { hover(true) }
    override func mouseExited(with event: NSEvent) { hover(false) }
    private func hover(_ on: Bool) {
        hovering = on
        if on, !collapsed, ask.isHidden, !UserDefaults.standard.bool(forKey: Self.hintKey) { showHint() }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            for b in buttons where !b.isHidden { b.animator().alphaValue = on || collapsed ? 1 : 0 }
        }
    }

    /// Once ever: what the card does beyond its buttons, over the bottom of the picture for 3 s.
    private func showHint() {
        UserDefaults.standard.set(true, forKey: Self.hintKey)
        hint.stringValue = L("Double-click to enlarge · drag to a corner", lang: ResolvedLang.current)
        let hw = min(bounds.width - 24, hint.intrinsicContentSize.width + 20)
        hint.frame = NSRect(x: (bounds.width - hw) / 2, y: picture.frame.minY + 8, width: hw, height: 18)
        hint.alphaValue = 1; hint.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.3; self.hint.animator().alphaValue = 0 },
                                                 completionHandler: { self.hint.isHidden = true })
        }
    }

    // Drag to move (it snaps to a corner when let go), click, double-click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        downAt = NSEvent.mouseLocation; dragging = false
        if event.clickCount == 2, !collapsed { card?.toggleLarge() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let w = window, let start = downAt else { return }
        let now = NSEvent.mouseLocation
        if !dragging && hypot(now.x - start.x, now.y - start.y) < 4 { return }
        dragging = true
        w.setFrameOrigin(NSPoint(x: w.frame.minX + now.x - start.x, y: w.frame.minY + now.y - start.y))
        downAt = now
    }
    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil; dragging = false }
        if dragging { card?.dropped() } else if event.clickCount == 1 { card?.clicked() }
    }
}

/// A button that works on the first click in a panel that never becomes active.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - the question in the card

/// A question the run waits on: the question in words, then its options as buttons (or Allow / Don't for an
/// approval, or a way to DeskMind's window for one that needs typing), "Neither" and "Stop", and a line that says the
/// keyboard stays the user's. After a pick: what was picked, a countdown and Undo. The card never takes keyboard focus.
final class AskView: NSView {
    weak var card: LiveCard?
    private var current: LiveCard.Ask?
    private let question = NSTextField(wrappingLabelWithString: "")
    private var options: [NSButton] = []
    private let other = FirstMouseButton(title: "", target: nil, action: nil)
    private let stop = FirstMouseButton(title: "", target: nil, action: nil)
    private let foot = NSTextField(wrappingLabelWithString: "")
    private let picked = NSTextField(labelWithString: "")
    private let undo = FirstMouseButton(title: "", target: nil, action: nil)
    private let progressTrack = NSView()
    private let progress = CALayer()
    /// The pick the countdown is running for: started once, not again on every refresh.
    private var countdownToken = -1
    /// How many countdowns have started (each pick has its own).
    private(set) var countdownRuns = 0
    private static let pad: CGFloat = 14, optionHeight: CGFloat = 44, gap: CGFloat = 8
    /// The height the question took: kept after a pick, so the card does not jump while the countdown runs.
    private var questionHeight: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        question.font = .systemFont(ofSize: 15, weight: .semibold)
        question.textColor = CardView.paper
        question.maximumNumberOfLines = 4
        foot.font = .systemFont(ofSize: 11.5)
        foot.textColor = NSColor(srgbRed: 0x8C / 255.0, green: 0x95 / 255.0, blue: 0x8C / 255.0, alpha: 1)
        foot.maximumNumberOfLines = 2
        picked.font = .systemFont(ofSize: 14, weight: .semibold)
        picked.textColor = CardView.paper
        picked.lineBreakMode = .byTruncatingTail
        for (b, sel) in [(other, #selector(otherPressed)), (stop, #selector(stopPressed)), (undo, #selector(undoPressed))] {
            b.isBordered = false; b.target = self; b.action = sel
        }
        progressTrack.wantsLayer = true
        progressTrack.layer?.backgroundColor = NSColor(srgbRed: 0x3A / 255.0, green: 0x3F / 255.0, blue: 0x3B / 255.0, alpha: 1).cgColor
        progressTrack.layer?.cornerRadius = 1.5
        progress.backgroundColor = CardView.orange.cgColor
        progress.cornerRadius = 1.5
        progress.anchorPoint = CGPoint(x: 0, y: 0)
        progressTrack.layer?.addSublayer(progress)
        addSubview(progressTrack)
        for v in [question, other, stop, foot, picked, undo] as [NSView] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func linkTitle(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: color])
    }

    func configure(_ a: LiveCard.Ask, lang: ResolvedLang) {
        let changed = current?.question != a.question || current?.options != a.options || current?.kind != a.kind
        current = a
        question.stringValue = a.question
        if changed {
            options.forEach { $0.removeFromSuperview() }
            options = []
            switch a.kind {
            case .choose:
                for (i, o) in a.options.enumerated() { options.append(optionButton(index: i, text: o)) }
            case .approve:
                options = [plainButton(L("Allow this once", lang: lang), primary: true, tag: 100),
                           plainButton(L("Don't", lang: lang), primary: false, tag: 101)]
            case .free:
                options = [plainButton(L("Answer in DeskMind", lang: lang), primary: true, tag: 200)]
            }
            options.forEach { addSubview($0) }
        }
        other.attributedTitle = linkTitle(L("Neither — let me type it…", lang: lang), color: NSColor(srgbRed: 0xF2 / 255.0, green: 0xC9 / 255.0, blue: 0xBC / 255.0, alpha: 1))
        stop.attributedTitle = linkTitle(L("Stop this task", lang: lang), color: NSColor(srgbRed: 0xB9 / 255.0, green: 0xC1 / 255.0, blue: 0xB8 / 255.0, alpha: 1))
        undo.attributedTitle = linkTitle(L("Undo", lang: lang), color: NSColor(srgbRed: 0xF2 / 255.0, green: 0xC9 / 255.0, blue: 0xBC / 255.0, alpha: 1))
        foot.stringValue = a.picked != nil ? L("It goes to DeskMind when the line runs out — Undo to change it.", lang: lang)
            : a.kind == .approve ? L("Covers this one step — it asks again next time.", lang: lang)
            : L("Pick one and it carries on — your keyboard stays yours.", lang: lang)
        if let p = a.picked { picked.stringValue = L("Picked: %@", p.label, lang: lang) }
        let isPicked = a.picked != nil
        question.isHidden = isPicked
        options.forEach { $0.isHidden = isPicked }
        other.isHidden = isPicked || a.kind != .choose
        stop.isHidden = isPicked
        picked.isHidden = !isPicked
        undo.isHidden = !isPicked
        progressTrack.isHidden = !isPicked
        needsLayout = true
        layoutSubtreeIfNeeded()
        if isPicked && countdownToken != a.token { countdownToken = a.token; runCountdown(until: a.deadline) }
        setAccessibilityLabel(isPicked ? picked.stringValue : a.question)
    }

    private func optionButton(index i: Int, text: String) -> NSButton {
        let b = FirstMouseButton(title: "", target: self, action: #selector(optionPressed(_:)))
        b.tag = i
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 12
        b.layer?.borderWidth = 1
        b.layer?.borderColor = NSColor(srgbRed: 0x4A / 255.0, green: 0x52 / 255.0, blue: 0x4B / 255.0, alpha: 1).cgColor
        b.layer?.backgroundColor = NSColor(srgbRed: 0x31 / 255.0, green: 0x36 / 255.0, blue: 0x32 / 255.0, alpha: 1).cgColor
        let title = NSMutableAttributedString(string: "   \(i + 1)   ", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: CardView.orange])
        title.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: CardView.paper]))
        b.attributedTitle = title
        b.alignment = .left
        (b.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        b.toolTip = text
        b.setAccessibilityLabel(text)
        return b
    }

    private func plainButton(_ text: String, primary: Bool, tag: Int) -> NSButton {
        let b = FirstMouseButton(title: "", target: self, action: #selector(optionPressed(_:)))
        b.tag = tag
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 12
        b.layer?.backgroundColor = (primary ? CardView.paper : NSColor(srgbRed: 0x31 / 255.0, green: 0x36 / 255.0, blue: 0x32 / 255.0, alpha: 1)).cgColor
        if !primary { b.layer?.borderWidth = 1; b.layer?.borderColor = NSColor(srgbRed: 0x4A / 255.0, green: 0x52 / 255.0, blue: 0x4B / 255.0, alpha: 1).cgColor }
        b.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: primary ? .bold : .regular),
                                                                         .foregroundColor: primary ? NSColor(srgbRed: 0x26 / 255.0, green: 0x2B / 255.0, blue: 0x28 / 255.0, alpha: 1) : CardView.paper])
        return b
    }

    /// The height this needs at `width` (top-left layout).
    func height(width: CGFloat) -> CGFloat {
        guard let a = current else { return LiveView.lineHeight }
        let w = width - 2 * Self.pad
        if a.picked != nil { return max(questionHeight, Self.pad + 26 + 10 + 3 + Self.pad) }
        let q = ceil(question.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 200)).height ?? 20)
        let rows: CGFloat = a.kind == .approve ? 1 : CGFloat(max(options.count, 1))
        let f = ceil(foot.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 60)).height ?? 16)
        questionHeight = Self.pad + q + 10 + rows * Self.optionHeight + (rows - 1) * Self.gap + 10 + 20 + 8 + f + Self.pad
        return questionHeight
    }

    override func layout() {
        super.layout()
        guard let a = current else { return }
        let w = bounds.width - 2 * Self.pad
        var y = Self.pad
        if a.picked != nil {
            y = max(Self.pad, (bounds.height - (26 + 10 + 3)) / 2)   // centred where the question was
            picked.frame = NSRect(x: Self.pad, y: y + 3, width: w - 70, height: 20)
            undo.frame = NSRect(x: bounds.width - Self.pad - 60, y: y, width: 60, height: 26)
            y += 26 + 10
            progressTrack.frame = NSRect(x: Self.pad, y: y, width: w, height: 3)
            let f = ceil(foot.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 60)).height ?? 16)
            foot.frame = NSRect(x: Self.pad, y: bounds.height - Self.pad - f, width: w, height: f)
            return
        }
        let q = ceil(question.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 200)).height ?? 20)
        question.frame = NSRect(x: Self.pad, y: y, width: w, height: q)
        y += q + 10
        if a.kind == .approve, options.count == 2 {
            let half = (w - Self.gap) / 2
            options[0].frame = NSRect(x: Self.pad, y: y, width: half, height: Self.optionHeight)
            options[1].frame = NSRect(x: Self.pad + half + Self.gap, y: y, width: half, height: Self.optionHeight)
            y += Self.optionHeight
        } else {
            for (i, b) in options.enumerated() {
                b.frame = NSRect(x: Self.pad, y: y, width: w, height: Self.optionHeight)
                y += Self.optionHeight + (i < options.count - 1 ? Self.gap : 0)
            }
        }
        y += 10
        other.sizeToFit(); stop.sizeToFit()
        other.frame.origin = NSPoint(x: Self.pad, y: y)
        stop.frame.origin = NSPoint(x: bounds.width - Self.pad - stop.frame.width, y: y)
        y += 20 + 8
        let f = ceil(foot.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 60)).height ?? 16)
        foot.frame = NSRect(x: Self.pad, y: y, width: w, height: f)
    }

    /// The line under the pick shrinks to nothing as the undo time runs out.
    private func runCountdown(until deadline: Date?) {
        guard let deadline else { return }
        countdownRuns += 1
        let left = max(0, deadline.timeIntervalSinceNow)
        let full = progressTrack.bounds.width
        CATransaction.begin(); CATransaction.setDisableActions(true)
        progress.bounds = CGRect(x: 0, y: 0, width: full, height: 3)
        progress.position = .zero
        CATransaction.commit()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let a = CABasicAnimation(keyPath: "bounds.size.width")
        a.fromValue = full * CGFloat(left / LiveView.undoSeconds); a.toValue = 0; a.duration = left
        a.fillMode = .forwards; a.isRemovedOnCompletion = false
        progress.add(a, forKey: "countdown")
    }

    @objc private func optionPressed(_ b: NSButton) {
        guard let card, let a = current else { return }
        switch b.tag {
        case 100: card.pick(reply: "", approve: true, label: L("Allow this once", lang: ResolvedLang.current))
        case 101: card.pick(reply: "", approve: false, label: L("Don't", lang: ResolvedLang.current))
        case 200: card.answerInWindow()
        default: if b.tag < a.options.count { card.pick(reply: a.options[b.tag], approve: true, label: a.options[b.tag]) }
        }
    }
    @objc private func otherPressed() { card?.answerInWindow() }
    @objc private func stopPressed() { card?.stopRun() }
    @objc private func undoPressed() { card?.undo() }

    /// For the e2e test: press an option by its index (or "allow" / "dont"), or Undo.
    func press(option i: Int) { if i < options.count { optionPressed(options[i]) } }
    func pressUndo() { undoPressed() }
    var optionCount: Int { options.count }
}
