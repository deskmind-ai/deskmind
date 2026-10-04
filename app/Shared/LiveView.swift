// What needs no screen for the live view, the small card in a corner that shows the window a run works in while
// it works there (often behind other windows, or on a display nobody looks at): which window to show, the card's
// size and place, and how large a picture to ask for. Foundation and CoreGraphics only, so tests/DecisionTests.swift
// checks it without a screen. The card itself is Helper/LiveCard.swift.

import CoreGraphics
import Foundation

enum LiveView {
    /// The setting (View menu), on by default: the run request carries it as "live_view".
    static let enabledKey = "liveView.enabled"

    /// The card's picture fits in this box, in points; the action line goes under it.
    static let maxPicture = CGSize(width: 360, height: 240)
    static let lineHeight: CGFloat = 34
    static let margin: CGFloat = 16

    /// A window on screen, as the card chooses among them.
    struct Candidate: Equatable {
        let id: Int
        let appName: String
        let bundle: String
        let layer: Int
        let onScreen: Bool
        let frame: CGRect
    }

    /// The id of the window hands observes and acts on: the `active` one in an observation's window list. Peekaboo's
    /// window ids are CGWindowIDs, written as strings.
    static func activeWindowID(_ windows: [[String: Any]]) -> Int? {
        for w in windows where w["active"] as? Bool == true {
            if let n = w["id"] as? Int { return n }
            if let s = w["id"] as? String, let n = Int(s) { return n }
        }
        return nil
    }

    /// The window to show: the one hands observes, while it is on screen; else the largest ordinary window of the app
    /// it works in, by the name the observation gives it ("TextEdit"); else of the task's apps, by bundle id -- the
    /// system names apps in its own language ("文本编辑"), which need not be the one hands read; else none.
    static func pick(_ windows: [Candidate], active: Int?, app: String, bundles: [String]) -> Int? {
        if let active, windows.contains(where: { $0.id == active && $0.onScreen }) { return active }
        // "TextEdit (no window open)": the app's name is what comes before the note.
        let name = app.components(separatedBy: " (").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let wanted = Set(bundles.map { $0.lowercased() })
        let ordinary = windows.filter { $0.layer == 0 && $0.onScreen && $0.frame.width >= 80 && $0.frame.height >= 60 }
        let named = name.isEmpty ? [] : ordinary.filter { $0.appName.lowercased() == name }
        let theirs = named.isEmpty ? ordinary.filter { wanted.contains($0.bundle.lowercased()) } : named
        return theirs.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?.id
    }

    /// The picture's size in the card: the window's shape, fitted into maxPicture, never larger than the window.
    static func pictureSize(window: CGSize) -> CGSize {
        guard window.width > 0, window.height > 0 else { return maxPicture }
        let k = min(maxPicture.width / window.width, maxPicture.height / window.height, 1)
        return CGSize(width: (window.width * k).rounded(), height: (window.height * k).rounded())
    }

    /// The whole card (picture and action line), in the bottom-right corner of `visible` (screen coordinates, origin
    /// bottom-left: a screen's visibleFrame, which leaves out the menu bar and the Dock).
    static func cardFrame(picture: CGSize, visible: CGRect) -> CGRect {
        let size = CGSize(width: picture.width, height: picture.height + lineHeight)
        return CGRect(x: visible.maxX - margin - size.width, y: visible.minY + margin, width: size.width, height: size.height)
    }

    /// The pixels to capture for a picture of `picture` points: twice that (a Retina card), never more than the
    /// window's own pixels. Even numbers, as video buffers want.
    static func capturePixels(picture: CGSize, window: CGSize, scale: CGFloat) -> (Int, Int) {
        let w = min(picture.width * 2, window.width * scale), h = min(picture.height * 2, window.height * scale)
        return (max(2, Int(w) / 2 * 2), max(2, Int(h) / 2 * 2))
    }

    /// A window's frame (global, origin top-left, as ScreenCaptureKit reports it) in the coordinates of the display
    /// it is captured from, clipped to that display: what a stream's sourceRect takes.
    static func sourceRect(window: CGRect, display: CGRect) -> CGRect {
        let r = window.intersection(display)
        guard !r.isNull else { return .zero }
        return r.offsetBy(dx: -display.minX, dy: -display.minY)
    }
}
