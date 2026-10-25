// The live view's feed (A4, invariant 6: pictures only while someone watches; pixels never on disk), the part with no
// screen: who watches which run, when the helper captures, which window a picture is of, the lines that carry it, and
// where the agent's cursor goes. The helper's op is Helper/LiveWatch.swift; the main app's dock, Main/LiveDock.swift.
//
// A watch, from the helper's side:
//
// | state       | what it is                                          | captures | sends                            |
// |-------------|-----------------------------------------------------|----------|----------------------------------|
// | registered  | the op came, in the table before any capture        | (soon)   | live.state                       |
// | streaming   | ≥ 1 watcher, the run acts in a window               | ~5 / s   | live.frame (window, epoch)       |
// | no picture  | ≥ 1 watcher, the run has no window yet              | no       | live.state no_picture            |
// | no access   | no Screen Recording permission                      | no       | live.state no_permission         |
// | grace       | the last watcher left < `grace` ago                 | yes      | — (to a watcher that comes back) |
// | ended       | unwatched past the grace, the task ended, the       | no       | live.state ended (if anyone)     |
// |             |   helper restarting, the run unknown                |          |                                  |
//
// A capture still running when its run ends or its watch goes finds it so and drops its picture. A picture says the
// window and the epoch it was taken of (the epoch moves on when the run moves to another window), so the cursor of a
// step in one window is never drawn on a picture of another.

import CoreGraphics
import Foundation

struct LiveFeed: Equatable {
    /// The helper's op: live.watch {run_id}.
    static let op = "live.watch"
    /// How long a run is still captured after its last watcher left: a watcher that comes back at once (the chat and
    /// the float trading places as the window flips) finds it running, nothing stopped and started again.
    static let grace: Double = 0.5
    /// Pictures a second while watched.
    static let fps: Double = 5

    enum State: String, Equatable { case noPicture = "no_picture", noPermission = "no_permission", streaming, ended }

    private(set) var watchers: [String: Int] = [:]
    private var unwatchedSince: [String: Double] = [:]
    private var ended: Set<String> = []
    /// The window each run acts in, and its epoch (moves on with each new window).
    private(set) var windows: [String: (id: Int, epoch: Int)] = [:]

    static func == (a: LiveFeed, b: LiveFeed) -> Bool { a.watchers == b.watchers && a.ended == b.ended }

    mutating func watch(_ run: String) { watchers[run, default: 0] += 1; unwatchedSince[run] = nil }

    mutating func unwatch(_ run: String, now: Double) {
        let n = (watchers[run] ?? 0) - 1
        if n > 0 { watchers[run] = n } else { watchers[run] = nil; unwatchedSince[run] = now }
    }

    /// The run's task ended (or the helper is restarting): nothing more is captured for it.
    mutating func end(_ run: String) { ended.insert(run) }

    /// The run acted in `window` (a step's window:<bundle>#<number>): a new one moves the epoch on.
    mutating func acted(_ run: String, window: Int) {
        if windows[run]?.id == window { return }
        windows[run] = (window, (windows[run]?.epoch ?? 0) + 1)
    }

    /// Whether the run is captured now: watched (or left within the grace), not ended.
    func captures(_ run: String, now: Double) -> Bool {
        guard !ended.contains(run) else { return false }
        if (watchers[run] ?? 0) > 0 { return true }
        return unwatchedSince[run].map { now - $0 < Self.grace } ?? false
    }

    /// What a watcher of the run is told now (permission: the helper's Screen Recording).
    func state(_ run: String, permission: Bool) -> State {
        if ended.contains(run) { return .ended }
        if !permission { return .noPermission }
        return windows[run] == nil ? .noPicture : .streaming
    }

    // MARK: the lines

    /// `visible`: the part of the window the picture shows, as [x, y, w, h] of the window (0–1) -- all of it, unless
    /// the window is partly off its display (#125 review: the picture is of the visible part only, and the cursor's
    /// rect_norm is of the whole window).
    static func frameLine(run: String, window: Int, epoch: Int, jpeg: Data, width: Int, height: Int, visible: [Double] = [0, 0, 1, 1]) -> [String: Any] {
        ["kind": "live.frame", "run_id": run, "window": window, "epoch": epoch, "w": width, "h": height, "visible": visible, "jpeg": jpeg.base64EncodedString()]
    }
    static func stateLine(run: String, _ s: State) -> [String: Any] { ["kind": "live.state", "run_id": run, "state": s.rawValue] }

    /// A line as the main app reads it.
    enum Line: Equatable {
        case frame(run: String, window: Int, epoch: Int, jpeg: Data, width: Int, height: Int, visible: [Double])
        case state(run: String, State)
    }
    static func read(_ o: [String: Any]) -> Line? {
        guard let run = o["run_id"] as? String else { return nil }
        switch o["kind"] as? String {
        case "live.frame":
            guard let w = o["window"] as? Int, let e = o["epoch"] as? Int, let b = o["jpeg"] as? String, let d = Data(base64Encoded: b) else { return nil }
            let v = (o["visible"] as? [Double]).flatMap { $0.count == 4 && $0[2] > 0 && $0[3] > 0 ? $0 : nil } ?? [0, 0, 1, 1]
            return .frame(run: run, window: w, epoch: e, jpeg: d, width: o["w"] as? Int ?? 0, height: o["h"] as? Int ?? 0, visible: v)
        case "live.state":
            return (o["state"] as? String).flatMap(State.init(rawValue:)).map { .state(run: run, $0) }
        default: return nil
        }
    }

    // MARK: the cursor

    /// Where the agent's cursor goes on a picture (in its own points, top-left origin): the step's target, a rect in its
    /// window 0–1, only when the picture is of the step's window, mapped into the part of it the picture shows
    /// (`visible`); none when the target is outside that part.
    static func cursor(pictureWindow: Int, stepWindow: Int?, rectNorm: [Double]?, picture: CGSize, visible: [Double] = [0, 0, 1, 1]) -> CGPoint? {
        guard let s = stepWindow, s == pictureWindow, let r = rectNorm, r.count == 4, picture.width > 0, picture.height > 0,
              visible.count == 4, visible[2] > 0, visible[3] > 0 else { return nil }
        let x = (r[0] + r[2] / 2 - visible[0]) / visible[2], y = (r[1] + r[3] / 2 - visible[1]) / visible[3]
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x * picture.width, y: y * picture.height)
    }

    /// The part of `window` that `display` shows, as [x, y, w, h] of the window (0–1); nil when none.
    static func visiblePart(window: CGRect, display: CGRect) -> [Double]? {
        let v = window.intersection(display)
        guard !v.isNull, v.width > 0, v.height > 0, window.width > 0, window.height > 0 else { return nil }
        return [Double((v.minX - window.minX) / window.width), Double((v.minY - window.minY) / window.height),
                Double(v.width / window.width), Double(v.height / window.height)]
    }

    /// Of the displays, the one that shows most of the window.
    static func bestDisplay(window: CGRect, displays: [CGRect]) -> Int? {
        displays.indices.max { a, b in
            let x = window.intersection(displays[a]), y = window.intersection(displays[b])
            return (x.isNull ? 0 : x.width * x.height) < (y.isNull ? 0 : y.width * y.height)
        }.flatMap { window.intersects(displays[$0]) ? $0 : nil }
    }

    /// A step's window number (its object, window:<bundle>#<number>), if it acted in one.
    static func windowNumber(_ object: String?) -> Int? {
        guard let o = object, o.hasPrefix("window:"), let hash = o.lastIndex(of: "#") else { return nil }
        return Int(o[o.index(after: hash)...])
    }
}
