// The live view's pictures (LiveWatch's source): one picture of a window at a time (SCScreenshotManager, not a stream:
// a running SCStream slowed the models' GPU work ~20 %, Helper/LiveCard.swift's header), taken from the display that
// shows most of it, with every other app's windows left out and cropped to the part of the window that display shows
// (a filter that names the window would put the purple "being shared" badge on it), as JPEG in memory. The picture is
// sized from that visible part and says which part it is, so the cursor maps onto it (#125 review). The window list
// and the filter are kept for a second, not made again for every picture (the 5 % gate). Nothing is written to disk.

import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

final class ScreenLiveSource: LiveFrameSource {
    /// The longest side of a picture sent, in pixels (the dock and the float draw at most ~720 pt wide).
    static let maxPixels: CGFloat = 1080
    /// How long a window's filter and place are reused before the window list is read again.
    static let reuse: TimeInterval = 1.0

    private struct Target { let filter: SCContentFilter; let window: CGRect; let display: CGRect; let at: Date }
    private let lock = NSLock()
    private var cache: [Int: Target] = [:]

    var permission: Bool { CGPreflightScreenCaptureAccess() }

    func capture(window id: Int) -> (jpeg: Data, width: Int, height: Int, visible: [Double])? {
        guard permission, let t = target(id), let visible = LiveFeed.visiblePart(window: t.window, display: t.display) else { return nil }
        let shown = t.window.intersection(t.display)
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = CGRect(x: shown.minX - t.display.minX, y: shown.minY - t.display.minY, width: shown.width, height: shown.height)
        let k = min(1, Self.maxPixels / max(shown.width, shown.height)) * CGFloat(t.filter.pointPixelScale)
        cfg.width = max(1, Int(shown.width * k)); cfg.height = max(1, Int(shown.height * k))
        cfg.showsCursor = false
        // (the completion may come after the wait gave up: what it brings is kept under a lock, and dropped then)
        let box = Box()
        SCScreenshotManager.captureImage(contentFilter: t.filter, configuration: cfg) { img, _ in box.put(img) }
        guard box.wait(2), let img = box.take(), let jpeg = Self.jpeg(img) else {
            lock.lock(); cache[id] = nil; lock.unlock()       // (moved, gone: read again next time)
            return nil
        }
        return (jpeg, img.width, img.height, visible)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock(), done = DispatchSemaphore(value: 0)
        private var image: CGImage?, given = false, open = true
        func put(_ img: CGImage?) {
            lock.lock(); defer { lock.unlock() }
            guard open, !given else { return }
            given = true; image = img; done.signal()
        }
        func wait(_ s: Double) -> Bool {
            let ok = done.wait(timeout: .now() + s) == .success
            lock.lock(); open = false; lock.unlock()
            return ok
        }
        func take() -> CGImage? { lock.lock(); defer { lock.unlock() }; return image }
    }

    /// The window's filter and place: kept for `reuse`, else read from the window list.
    private func target(_ id: Int) -> Target? {
        lock.lock()
        if let t = cache[id], Date().timeIntervalSince(t.at) < Self.reuse { lock.unlock(); return t }
        lock.unlock()
        guard let content = Self.content(), let w = content.windows.first(where: { Int($0.windowID) == id }), w.isOnScreen,
              let i = LiveFeed.bestDisplay(window: w.frame, displays: content.displays.map(\.frame)) else { return nil }
        let display = content.displays[i]
        let pid = w.owningApplication?.processID
        let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.owningApplication?.processID != pid })
        let t = Target(filter: filter, window: w.frame, display: display.frame, at: Date())
        lock.lock(); cache = cache.filter { Date().timeIntervalSince($0.value.at) < 10 }; cache[id] = t; lock.unlock()
        return t
    }

    private static func content() -> SCShareableContent? {
        let got = DispatchSemaphore(value: 0)
        let box = ContentBox()
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, _ in box.content = c; got.signal() }
        return got.wait(timeout: .now() + 3) == .success ? box.content : nil
    }
    private final class ContentBox: @unchecked Sendable { var content: SCShareableContent? }

    private static func jpeg(_ img: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
