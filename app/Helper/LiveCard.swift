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
// - header: a status dot, the app, the step or the status; on hover, Larger/Smaller, Collapse and Stop;
// - the picture, with the agent's cursor where the last step acted (the run never moves the real pointer);
// - the step being taken, in words.
// Dragged, it snaps to the nearest corner and stays there for later runs; double-clicked, it grows. Collapsed, it
// is a capsule with the status and the step (and the capture pauses). When the run needs the user (a question, an
// approval) the card says so, and a click on it opens DeskMind. When the run ends it says how, then fades.
//
// It keeps out of the way of the window being worked in: a corner where the card would cover that window is
// skipped. When every corner would (a window filling the screen), the card lets clicks through, so a click the run
// makes in the foreground lands on the app. It never becomes the active window.
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
    private let bundles: [String]
    /// What to capture now (nil: nothing -- collapsed, no window, or the run has ended), and what it was made from.
    private var target: (filter: SCContentFilter, config: SCStreamConfiguration)?
    private var shown: (window: Int, frame: CGRect, display: CGDirectDisplayID, drop: Set<Int>, pixels: CGSize)?
    private var watching = true
    /// Collapsed to the capsule: no capture. `autoCollapsed`: by the card itself, because the card would cover the
    /// window being worked in from every corner (a window filling the screen); it opens again when that is over.
    private var collapsed = false
    private var autoCollapsed = false
    private var large = UserDefaults.standard.bool(forKey: largeKey)
    /// The run's own status (working, needs the user, paused, ended); `hidden` is the window's, layered on top.
    private var runStatus: LiveView.Status = .starting
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

    /// What Stop on the card does (Runner.requestStop in the helper; a test's own in tests/e2e).
    private let onStop: () -> Void

    /// The instruction: the action line until the first step.
    private let goal: String

    private init(bundles: [String], goal: String, onStop: @escaping () -> Void) {
        self.bundles = bundles; self.goal = goal; self.onStop = onStop
    }

    // MARK: from Runner

    static func start(bundles: [String], goal: String = "", onStop: @escaping () -> Void) {
        let card = LiveCard(bundles: bundles, goal: goal, onStop: onStop)
        lock.lock(); let old = shared; shared = card; lock.unlock()
        // A card still saying how the last run ended goes now, not over the new one.
        if let old { old.set { $0.watching = false }; old.stopCapture(); DispatchQueue.main.async { old.close() } }
        DispatchQueue.main.async { card.makePanel() }
        card.watch()
        card.capture()
    }

    /// The run has ended. With how it ended, the card says so for a moment, its last picture frozen, then goes; with
    /// nil it goes at once (unless it is already saying how the run ended).
    static func finish(_ ending: LiveView.Status?) {
        lock.lock(); let card = shared; if ending == nil || card?.runStatus.isEnding == true { shared = nil }; lock.unlock()
        guard let card else { return }
        if let ending, !card.runStatus.isEnding {
            card.stopCapture()
            card.set { $0.runStatus = ending }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
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
        let p = LiveView.targetCenter(target)
        DispatchQueue.main.async {
            card.view?.line.stringValue = words
            if let p { card.lastTarget = p; card.placeCursor(ripple: click) }
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
    }

    /// Size, place, show what the state says. Main thread.
    fileprivate func refresh() {
        guard let p = panel, let v = view else { return }
        let (status, userCollapsed, large, step, app, hadPicture) = read { c -> (LiveView.Status, Bool, Bool, Int, String, Bool) in
            let s: LiveView.Status = c.runStatus.isEnding || c.runStatus == .waitingForUser ? c.runStatus
                : (c.windowHidden && c.hadPicture ? .hidden : c.runStatus)
            return (s, c.collapsed, c.large, c.step, c.appName, c.hadPicture)
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
        // A card that would cover the window being worked in from every corner becomes the capsule, which covers
        // little; the card comes back when the window leaves room for it.
        let cardPlaced = LiveView.place(size: cardSize, preferred: corner, visible: visible, avoid: avoid)
        let auto = !userCollapsed && cardPlaced.covers
        if auto != read({ $0.autoCollapsed }) {
            state.lock(); autoCollapsed = auto; state.unlock()
            if auto { DispatchQueue.global().async { self.stopCapture() } }   // the capsule shows no picture
        }
        let collapsed = userCollapsed || auto
        let size = collapsed ? LiveView.pill : cardSize
        let placed = collapsed ? LiveView.place(size: size, preferred: corner, visible: visible, avoid: avoid) : cardPlaced
        let frame = LiveView.frame(size: size, corner: placed.corner, visible: visible)
        // Even the capsule would cover the window: it lets clicks through, so a click the run makes there reaches the
        // app (its Stop is then out of reach; the island's is not).
        p.ignoresMouseEvents = placed.covers
        v.layoutCard(collapsed: collapsed, large: large, size: size, dimmed: status == .hidden, note: status == .hidden || !hadPicture
                     ? L(LiveView.word(status == .hidden ? .hidden : .starting), lang: lang) : nil)
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

    fileprivate func stopRun() { onStop() }

    /// A click on the card: a question waiting opens DeskMind, a capsule opens up.
    fileprivate func clicked() {
        if read({ $0.runStatus == .waitingForUser }) {
            let helper = Bundle.main.bundleURL   // …/DeskMind.app/Contents/Library/LoginItems/DeskMind Hands.app
            let main = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            let url = main.pathExtension == "app" ? main
                : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "ai.deskmind.app")
            if let url { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
        } else if read({ $0.collapsed }) {
            toggleCollapsed()
        }
    }

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
        let (active, app, isCollapsed, isLarge, observed) = (activeWindow, appName, collapsed || autoCollapsed, large, observedOnce)
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
        guard watching, !collapsed, !autoCollapsed else { return }
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
        let (status, collapsed, large, streaming, watching, hidden, auto) = card.read {
            ($0.runStatus, $0.collapsed, $0.large, $0.target != nil, $0.watching, $0.windowHidden, $0.autoCollapsed)
        }
        var out: [String: Any] = ["card": true, "status": LiveView.word(status), "collapsed": collapsed, "large": large,
                                  "auto_collapsed": auto,
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
        case "drop":
            if let p = card.panel, let point { p.setFrameOrigin(NSPoint(x: point.x - p.frame.width / 2, y: point.y - p.frame.height / 2)) }
            card.dropped()
        default: break
        }
    }
}

// MARK: - the card's view

/// Header (status dot, title, buttons on hover), picture with the agent's cursor, the action line; or the capsule.
private final class CardView: NSView {
    weak var card: LiveCard?
    let picture = CALayer()
    let line = NSTextField(labelWithString: "")
    let title = NSTextField(labelWithString: "")
    var appTitle = ""
    private let note = NSTextField(labelWithString: "")
    private let dot = CALayer()
    private let cursor = CALayer()
    var cursorShown: Bool { cursor.opacity > 0 && !cursor.isHidden }
    var cursorPosition: CGPoint { cursor.position }
    var noteText: String { note.isHidden ? "" : note.stringValue }
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

        dot.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        dot.cornerRadius = 4
        layer?.addSublayer(dot)

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

        let lang = ResolvedLang.current
        largeButton = button("arrow.up.left.and.arrow.down.right", L("Larger", lang: lang)) { $0.toggleLarge() }
        buttons = [largeButton,
                   button("chevron.down", L("Collapse", lang: lang)) { $0.toggleCollapsed() },
                   button("stop.fill", L("Stop the task", lang: lang)) { $0.stopRun() }]
        for b in buttons { b.alphaValue = 0; addSubview(b) }
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

    func layoutCard(collapsed: Bool, large big: Bool, size: CGSize, dimmed: Bool, note text: String?) {
        self.collapsed = collapsed
        let h = LiveView.headerHeight, lh = LiveView.lineHeight
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if collapsed {
            layer?.cornerRadius = size.height / 2
            picture.isHidden = true
            dot.position = CGPoint(x: 18, y: size.height / 2)
            title.frame = NSRect(x: 30, y: (size.height - 16) / 2, width: size.width - 30 - 40, height: 16)
            line.isHidden = true
            buttons[2].frame = NSRect(x: size.width - 32, y: (size.height - 20) / 2, width: 20, height: 20)
            for (i, b) in buttons.enumerated() { b.isHidden = i != 2 }
        } else {
            layer?.cornerRadius = 14
            picture.isHidden = false
            picture.frame = CGRect(x: 0, y: lh, width: size.width, height: size.height - h - lh)
            picture.opacity = dimmed ? 0.35 : 1
            dot.position = CGPoint(x: 16, y: size.height - h / 2)
            title.frame = NSRect(x: 28, y: size.height - h + (h - 16) / 2, width: size.width - 28 - 92, height: 16)
            line.isHidden = false
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
        note.frame = NSRect(x: 12, y: lh + (size.height - h - lh - 16) / 2, width: size.width - 24, height: 16)
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
    override func mouseEntered(with event: NSEvent) { hover(true) }
    override func mouseExited(with event: NSEvent) { hover(false) }
    private func hover(_ on: Bool) {
        hovering = on
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            for b in buttons where !b.isHidden { b.animator().alphaValue = on || collapsed ? 1 : 0 }
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
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
