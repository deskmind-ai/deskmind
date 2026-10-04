// The live view: a small card in the bottom-right corner that shows the window a run is working in, live, with the
// step it is taking underneath. A run works in the background -- its windows are often behind the user's, or on a
// display nobody is looking at -- and the island at the top says what it does, not what it looks like.
//
// It lives in the helper, which holds Screen Recording: the picture never crosses the socket. The window is
// captured from its display with every other window left out and the stream cropped to the window (sourceRect), so
// a window covered by others still shows whole. Built by leaving windows out, like the recorder (ScreenRecorder.
// filter): a filter that names the window puts the purple "being shared" badge on it (macOS 26 and later).
//
// The card takes no clicks (a click the run makes in the foreground lands on the app under it) and never becomes the
// active window. It is an ordinary shareable window: the user's own screenshots and screen sharing show it. hands'
// screenshots are window captures (deskmind_hands/drivers/capture.py), so it is never in what the models see, and a
// task recording leaves out every window that is not the task's (ScreenRecorder.filter); recording the whole
// screen keeps it.
//
// Which window: the one hands observes (the `active` window of the trace's latest observation), else the largest
// window of the app it works in. Checked every 0.5 s, so a window that moves, resizes or changes display is
// followed. Started by Runner when a run starts with "live_view", stopped when the run ends.

import AppKit
import CoreMedia
import QuartzCore
import ScreenCaptureKit

final class LiveCard: NSObject, SCStreamOutput, SCStreamDelegate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var shared: LiveCard?

    // What the run says, from Runner's trace poller.
    private var activeWindow: Int?
    private var appName = ""
    private let bundles: [String]

    private var panel: NSPanel?
    private var picture: CALayer?
    private var line: NSTextField?
    private var stream: SCStream?
    private var shown: (window: Int, frame: CGRect, display: CGDirectDisplayID, drop: Set<Int>)?
    private var watching = true
    /// activeWindow, appName, stream and shown: set from the trace poller, the watch loop and stop.
    private let state = NSLock()
    /// Frames arrive here; the watch loop runs on its own thread.
    private let frames = DispatchQueue(label: "ai.deskmind.livecard.frames", qos: .userInitiated)

    private init(bundles: [String]) { self.bundles = bundles }

    // MARK: from Runner

    static func start(bundles: [String]) {
        stop()
        let card = LiveCard(bundles: bundles)
        lock.lock(); shared = card; lock.unlock()
        DispatchQueue.main.async { card.makePanel() }
        card.watch()
    }

    /// The run has ended (finished, stopped or failed): the stream stops and the card goes.
    static func stop() {
        lock.lock(); let card = shared; shared = nil; lock.unlock()
        card?.end()
    }

    /// An observation: the window hands is looking at, and its app.
    static func observed(windows: [[String: Any]], app: String) {
        lock.lock(); let card = shared; lock.unlock()
        guard let card else { return }
        card.state.lock(); defer { card.state.unlock() }
        if let id = LiveView.activeWindowID(windows) { card.activeWindow = id }
        if !app.isEmpty { card.appName = app }
    }

    /// The line under the picture: the step being taken, or that the run is waiting for the user.
    static func say(_ text: String) {
        lock.lock(); let card = shared; lock.unlock()
        DispatchQueue.main.async { card?.line?.stringValue = text }
    }

    // MARK: the card

    private func makePanel() {
        guard watching else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false

        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.149, green: 0.169, blue: 0.157, alpha: 0.94).cgColor
        let pic = CALayer()
        pic.contentsGravity = .resizeAspect
        pic.backgroundColor = NSColor(calibratedWhite: 0.94, alpha: 1).cgColor
        root.layer?.addSublayer(pic)
        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 12, weight: .medium)
        text.textColor = NSColor(calibratedWhite: 1, alpha: 0.92)
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        root.addSubview(text)
        p.contentView = root
        panel = p; picture = pic; line = text
    }

    /// Size and place the card for a window of `size` points, in the corner of the screen it is on.
    private func layout(window size: CGSize) {
        guard let p = panel, let pic = picture, let text = line,
              let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let ps = LiveView.pictureSize(window: size)
        let frame = LiveView.cardFrame(picture: ps, visible: screen.visibleFrame)
        p.setFrame(frame, display: true)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pic.frame = CGRect(x: 0, y: LiveView.lineHeight, width: ps.width, height: ps.height)
        CATransaction.commit()
        text.frame = NSRect(x: 12, y: (LiveView.lineHeight - 16) / 2, width: ps.width - 24, height: 16)
        if !p.isVisible { p.orderFrontRegardless() }
    }

    // MARK: following the window

    private func watch() {
        Thread.detachNewThread { [weak self] in
            while let self, self.watching {
                self.update()
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    private func update() {
        guard let content = Self.content() else { return }
        state.lock(); defer { state.unlock() }
        guard watching else { return }
        let candidates = content.windows.map { w in
            LiveView.Candidate(id: Int(w.windowID), appName: w.owningApplication?.applicationName ?? "",
                               bundle: w.owningApplication?.bundleIdentifier ?? "", layer: w.windowLayer,
                               onScreen: w.isOnScreen, frame: w.frame)
        }
        guard let id = LiveView.pick(candidates, active: activeWindow, app: appName, bundles: bundles),
              let window = content.windows.first(where: { Int($0.windowID) == id }),
              let display = content.displays.first(where: { !$0.frame.intersection(window.frame).isNull })
                ?? content.displays.first else { return }
        // Everything but the window's own app (its sheets and popovers belong to it), the card included.
        let pid = window.owningApplication?.processID
        let drop = content.windows.filter { $0.owningApplication?.processID != pid }
        let dropIDs = Set(drop.map { Int($0.windowID) })
        let frame = window.frame
        if let s = shown, s.window == id, s.frame == frame, s.display == display.displayID, s.drop == dropIDs { return }
        let filter = SCContentFilter(display: display, excludingWindows: drop)
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = LiveView.sourceRect(window: frame, display: display.frame)
        let ps = LiveView.pictureSize(window: frame.size)
        (cfg.width, cfg.height) = LiveView.capturePixels(picture: ps, window: frame.size,
                                                         scale: CGFloat(filter.pointPixelScale))
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 10)   // a glance, not a movie
        cfg.showsCursor = false
        cfg.queueDepth = 3
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        let first = shown == nil
        let resized = shown.map { $0.frame.size != frame.size } ?? true
        shown = (id, frame, display.displayID, dropIDs)
        if resized { DispatchQueue.main.async { self.layout(window: frame.size) } }
        if first || stream == nil {
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            do { try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: frames) } catch { return }
            stream = s
            s.startCapture { err in if let err { NSLog("DeskMind Hands: live view: \(err.localizedDescription)") } }
        } else if let s = stream {
            s.updateContentFilter(filter) { _ in }
            s.updateConfiguration(cfg) { _ in }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, watching, let buf = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(buf)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [weak self] in
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self?.picture?.contents = surface
            CATransaction.commit()
        }
    }

    /// The system stopped the stream (the display went away): started again at the next check.
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        state.lock(); defer { state.unlock() }
        if self.stream === stream { self.stream = nil; self.shown = nil }
    }

    private func end() {
        state.lock()
        watching = false
        let s = stream
        stream = nil; shown = nil
        state.unlock()
        if let s {
            let stopped = DispatchSemaphore(value: 0)
            s.stopCapture { _ in stopped.signal() }
            _ = stopped.wait(timeout: .now() + 5)
        }
        DispatchQueue.main.async { [self] in
            panel?.orderOut(nil)
            panel = nil; picture = nil; line = nil
        }
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
