// What needs no screen for the live view, the small card in a corner that shows the window a run works in while
// it works there (often behind other windows, or on a display nobody looks at): which window to show, the card's
// size and place (a corner, out of the window's way), where the agent's cursor goes in the picture, and how large a
// picture to ask for. Foundation and CoreGraphics only, so tests/DecisionTests.swift checks it without a screen. The
// card itself is Helper/LiveCard.swift.
//
// Two coordinate systems meet here. ScreenCaptureKit and hands give window frames and action targets in global
// points with the origin at the top-left of the main display; AppKit places windows with the origin at its
// bottom-left. `toAppKit` converts.

import CoreGraphics
import Foundation

enum LiveView {
    /// The setting (View menu), on by default: the run request carries it as "live_view".
    static let enabledKey = "liveView.enabled"
    /// Set once the card's one-time hint (double-click, drag) has been shown.
    static let hintKey = "liveView.hintSeen"

    /// The picture fits in this box, in points: the usual card, and the larger one (expand, or a double click).
    static let maxPicture = CGSize(width: 360, height: 240)
    static let maxPictureLarge = CGSize(width: 720, height: 480)
    /// The header (status, app, step, the buttons) and the action line under the picture.
    static let headerHeight: CGFloat = 30
    static let lineHeight: CGFloat = 32
    static let margin: CGFloat = 16
    /// Collapsed: a capsule with the status and the step.
    static let pill = CGSize(width: 260, height: 36)

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

    /// The window to show. Once hands has said which window it works in, that one and no other: while it is
    /// minimized, closed or on another Space there is none (the card says so) -- another window of the same app may
    /// be the user's own document, and the card must not show it. Before hands has said (the run is starting, or the
    /// app is read from its pixels with no window list), the largest ordinary window of the app it works in, by the
    /// name the observation gives it ("TextEdit"); else of the task's apps, by bundle id -- the system names apps in
    /// its own language ("文本编辑"), which need not be the one hands read; else none.
    ///
    /// `observed`: hands has looked at the screen at least once. Until then nothing is shown -- the largest window of
    /// the app could be one of the user's own, and a card is easily screenshotted and shared.
    static func pick(_ windows: [Candidate], active: Int?, app: String, bundles: [String], observed: Bool = true) -> Int? {
        if let active { return windows.contains(where: { $0.id == active && $0.onScreen }) ? active : nil }
        guard observed else { return nil }
        // "TextEdit (no window open)": the app's name is what comes before the note.
        let name = app.components(separatedBy: " (").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let wanted = Set(bundles.map { $0.lowercased() })
        let ordinary = windows.filter { $0.layer == 0 && $0.onScreen && $0.frame.width >= 80 && $0.frame.height >= 60 }
        let named = name.isEmpty ? [] : ordinary.filter { $0.appName.lowercased() == name }
        let theirs = named.isEmpty ? ordinary.filter { wanted.contains($0.bundle.lowercased()) } : named
        return theirs.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?.id
    }

    /// The picture's size in the card: the window's shape, fitted into `box`, never larger than the window.
    static func pictureSize(window: CGSize, box: CGSize = maxPicture) -> CGSize {
        guard window.width > 0, window.height > 0 else { return CGSize(width: box.width, height: (box.width * 0.625).rounded()) }
        let k = min(box.width / window.width, box.height / window.height, 1)
        // Not narrower than the header needs for its buttons.
        let w = max((window.width * k).rounded(), 220)
        return CGSize(width: w, height: (window.height * k).rounded())
    }

    /// The whole card for a picture: header, picture, action line.
    static func cardSize(picture: CGSize) -> CGSize {
        CGSize(width: picture.width, height: headerHeight + picture.height + lineHeight)
    }

    enum Corner: String, CaseIterable { case bottomRight, bottomLeft, topRight, topLeft }

    /// The card in `corner` of `visible` (a screen's visibleFrame, AppKit coordinates: it leaves out the menu bar and
    /// the Dock).
    static func frame(size: CGSize, corner: Corner, visible: CGRect) -> CGRect {
        let x = corner == .bottomRight || corner == .topRight ? visible.maxX - margin - size.width : visible.minX + margin
        let y = corner == .bottomRight || corner == .bottomLeft ? visible.minY + margin : visible.maxY - margin - size.height
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Where a card let go at `center` goes: the nearest corner.
    static func nearestCorner(center: CGPoint, visible: CGRect) -> Corner {
        let right = center.x >= visible.midX, top = center.y >= visible.midY
        return top ? (right ? .topRight : .topLeft) : (right ? .bottomRight : .bottomLeft)
    }

    /// The corner for the card: the user's, unless the card there would cover the window being worked in; then the
    /// first corner that does not, in the order nearest the user's first. `covers`: no corner is clear (a window
    /// filling the screen, as most people keep their apps) -- the card stays, over the window, in the corner farthest
    /// from where the run has been acting (`recent`, AppKit coordinates; the user's corner when there is none), and
    /// lets clicks through until the user rests the pointer on it (see interactive).
    static func place(size: CGSize, preferred: Corner, visible: CGRect, avoid window: CGRect?,
                      recent: [CGPoint] = []) -> (corner: Corner, covers: Bool) {
        guard let window, !window.isEmpty else { return (preferred, false) }
        let order = [preferred] + neighbours(preferred)
        for c in order where !frame(size: size, corner: c, visible: visible).intersects(window) { return (c, false) }
        guard !recent.isEmpty else { return (preferred, true) }
        func distance(_ c: Corner) -> CGFloat {   // to the nearest recent action
            let f = frame(size: size, corner: c, visible: visible)
            return recent.map { p in hypot(min(max(p.x, f.minX), f.maxX) - p.x, min(max(p.y, f.minY), f.maxY) - p.y) }.min() ?? 0
        }
        let best = order.max { distance($0) < distance($1) } ?? preferred
        return (distance(best) > distance(preferred) ? best : preferred, true)
    }

    /// Whether the card takes clicks: always when it covers nothing of the window being worked in; over that window
    /// only once the pointer has rested on it for `dwell` seconds. A run's click lands in a blink (the pointer moved
    /// and clicked at once), so it passes through to the app; a person who stops on the card gets its buttons.
    static let dwell: Double = 0.5
    static func interactive(covers: Bool, pointerOnCardFor seconds: Double?) -> Bool {
        !covers || (seconds ?? 0) >= dwell
    }

    /// The other corners, nearest first: across the same edge, up or down the same side, then opposite.
    static func neighbours(_ c: Corner) -> [Corner] {
        switch c {
        case .bottomRight: [.bottomLeft, .topRight, .topLeft]
        case .bottomLeft: [.bottomRight, .topLeft, .topRight]
        case .topRight: [.topLeft, .bottomRight, .bottomLeft]
        case .topLeft: [.topRight, .bottomLeft, .bottomRight]
        }
    }

    /// A rect in global top-left coordinates (ScreenCaptureKit, hands) in AppKit's, given the main display's height.
    static func toAppKit(_ r: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Where a point on the screen (top-left coordinates) is in the picture of `window` drawn in `picture` (the
    /// picture's own coordinates, origin bottom-left as a layer's), or nil when it is outside the window.
    static func cursor(at p: CGPoint, window: CGRect, picture: CGSize) -> CGPoint? {
        guard window.width > 0, window.height > 0, window.contains(p) else { return nil }
        let x = (p.x - window.minX) / window.width * picture.width
        let y = (1 - (p.y - window.minY) / window.height) * picture.height
        return CGPoint(x: x, y: y)
    }

    /// The centre of a hands target_rect ([x, y, w, h], screen points, top-left), when it has one.
    static func targetCenter(_ v: Any?) -> CGPoint? {
        guard let a = v as? [Any], a.count == 4 else { return nil }
        let n = a.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard n.count == 4, n[2] >= 0, n[3] >= 0 else { return nil }
        return CGPoint(x: n[0] + n[2] / 2, y: n[1] + n[3] / 2)
    }

    /// The pixels to capture for a picture of `picture` points: twice that (a Retina card), never more than the
    /// window's own pixels. Even numbers, as video buffers want.
    static func capturePixels(picture: CGSize, window: CGSize, scale: CGFloat, perPoint: CGFloat = 2) -> (Int, Int) {
        let w = min(picture.width * perPoint, window.width * scale), h = min(picture.height * perPoint, window.height * scale)
        return (max(2, Int(w) / 2 * 2), max(2, Int(h) / 2 * 2))
    }

    /// A window's frame (global, origin top-left, as ScreenCaptureKit reports it) in the coordinates of the display
    /// it is captured from, clipped to that display: what a stream's sourceRect takes.
    static func sourceRect(window: CGRect, display: CGRect) -> CGRect {
        let r = window.intersection(display)
        guard !r.isNull else { return .zero }
        return r.offsetBy(dx: -display.minX, dy: -display.minY)
    }

    /// What the card says it is doing, beside its status dot.
    enum Status: Equatable {
        case starting, working, waitingForUser, paused, hidden, done, failed, stopped
        /// The run is over: the card says how it ended for a moment, then goes.
        var isEnding: Bool { self == .done || self == .failed || self == .stopped }
    }

    /// 小方's eyes in the card's title bar (its frame and the orange dot at its foot are the card's status light):
    /// looking at the agent's cursor while it works, up at you when it needs you, ^ ^ when done, – – when paused,
    /// stopped, unfinished or the window is out of sight.
    enum Face: String { case look, up, happy, flat }

    static func face(_ s: Status) -> Face {
        switch s {
        case .starting, .working: .look
        case .waitingForUser: .up
        case .done: .happy
        case .paused, .hidden, .failed, .stopped: .flat
        }
    }

    /// Where the eyes look, in points from their resting place: toward the agent's cursor in the picture
    /// (left-right across the picture, and down), straight ahead and a little down when there is none.
    static func gaze(cursor: CGPoint?, picture: CGSize) -> CGPoint {
        guard let c = cursor, picture.width > 0, picture.height > 0 else { return CGPoint(x: 0, y: 0.6) }
        let x = (min(max(c.x / picture.width, 0), 1) - 0.5) * 2.4
        let y = 0.4 + (1 - min(max(c.y / picture.height, 0), 1)) * 0.8   // a layer counts y up; lower = more down
        return CGPoint(x: (x * 10).rounded() / 10, y: (y * 10).rounded() / 10)
    }

    // MARK: a question in the card

    /// What kind of question the card shows: options to pick, an approval (yes / no), or one that needs typing (the
    /// card sends the user to DeskMind's window for it).
    enum AskKind: Equatable { case choose, approve, free }

    static func askKind(options: [String], approval: Bool) -> AskKind {
        approval ? .approve : (askOptions(options).isEmpty ? .free : .choose)
    }

    /// The options as buttons: trimmed, empty and repeated ones dropped, four at most (more go under "Neither").
    static func askOptions(_ options: [String]) -> [String] {
        var out: [String] = []
        for o in options {
            let t = o.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && !out.contains(t) { out.append(t) }
        }
        return Array(out.prefix(4))
    }

    /// After a pick, this long to undo it before the answer goes to the run.
    static let undoSeconds: Double = 3
    /// The card while it asks: wider, so a question and its options read without cramping.
    static let askWidth: CGFloat = 420
    /// The picture above a question: smaller, the question is what matters now.
    static let askPictureHeight: CGFloat = 112

    /// Why a run didn't finish, from the summary hands writes (its state and failure class), said on the card's
    /// last picture: the key, for L(); nil when it finished, was stopped, or there is nothing more to say than
    /// "Didn't finish".
    static func endingNote(state: String, failure: String) -> String? {
        switch state {
        case "completed", "cancelled": nil
        case "gave_up": "It couldn't find a way to do this"
        case "budget_exhausted": "It ran out of steps before finishing"
        case "errored": failure == "no_progress_loop" ? "Got stuck: the same step kept failing" : "It stopped on an error"
        default: nil
        }
    }

    /// The header's word for a status: the key, for L().
    static func word(_ s: Status) -> String {
        switch s {
        case .starting: "Starting"
        case .working: "Working"
        case .waitingForUser: "Needs you"
        case .paused: "Paused"
        case .hidden: "Window not visible"
        case .done: "Done"
        case .failed: "Didn't finish"
        case .stopped: "Stopped"
        }
    }
}
