// The live view's pictures (LiveWatch's source): one picture of a window at a time (SCScreenshotManager, not a stream:
// a running SCStream slowed the models' GPU work ~20 %, Helper/LiveCard.swift's header), taken from its display with
// every other app's windows left out and cropped to the window (a filter that names the window would put the purple
// "being shared" badge on it), as JPEG in memory. Nothing is written to disk.

import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

final class ScreenLiveSource: LiveFrameSource {
    /// The longest side of a picture sent, in pixels (the dock and the float draw at most ~720 pt wide).
    static let maxPixels: CGFloat = 1080

    var permission: Bool { CGPreflightScreenCaptureAccess() }

    func capture(window id: Int) -> (jpeg: Data, width: Int, height: Int)? {
        guard permission, let content = Self.content(),
              let w = content.windows.first(where: { Int($0.windowID) == id }), w.isOnScreen,
              let display = content.displays.first(where: { !$0.frame.intersection(w.frame).isNull }) ?? content.displays.first else { return nil }
        let pid = w.owningApplication?.processID
        let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.owningApplication?.processID != pid })
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = LiveView.sourceRect(window: w.frame, display: display.frame)
        let k = min(1, Self.maxPixels / max(w.frame.width, w.frame.height)) * CGFloat(filter.pointPixelScale)
        cfg.width = max(1, Int(w.frame.width * k)); cfg.height = max(1, Int(w.frame.height * k))
        cfg.showsCursor = false
        let done = DispatchSemaphore(value: 0)
        var image: CGImage?
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { img, _ in image = img; done.signal() }
        guard done.wait(timeout: .now() + 2) == .success, let img = image, let jpeg = Self.jpeg(img) else { return nil }
        return (jpeg, img.width, img.height)
    }

    private static func content() -> SCShareableContent? {
        let got = DispatchSemaphore(value: 0)
        var content: SCShareableContent?
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, _ in content = c; got.signal() }
        return got.wait(timeout: .now() + 3) == .success ? content : nil
    }

    private static func jpeg(_ img: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
