// What needs no screen for the run's status at the top of the screen: where the notch is, the island's bar (the Island
// board: one strip at the notch, as tall as it, 380 wide -- 460 while it needs you; on a screen with no notch the same
// bar as a capsule under the menu bar), and the line that says which stage a starting run is in and for how long.
// Foundation and CoreGraphics only, so tests/DecisionTests.swift checks it without a screen.

import CoreGraphics
import Foundation

enum Island {
    /// The notch, in screen coordinates (origin bottom-left), or nil on a screen without one: the gap between the
    /// menu bar's two usable areas (NSScreen.auxiliaryTopLeftArea / auxiliaryTopRightArea), as tall as the top
    /// safe-area inset.
    static func notch(screen: CGRect, safeTop: CGFloat, left: CGRect?, right: CGRect?) -> CGRect? {
        guard safeTop > 0, let left, let right, right.minX > left.maxX else { return nil }
        return CGRect(x: left.maxX, y: screen.maxY - safeTop, width: right.minX - left.maxX, height: safeTop)
    }

    /// The bar's widths: as it works, and while it needs you (the Island board); its height with no notch.
    static let barWidth: CGFloat = 380
    static let barWideWidth: CGFloat = 460
    static let barHeight: CGFloat = 34

    /// How wide the bar is: at a notch always the wide one, whatever the state -- it never grows or shrinks around
    /// the notch (fable, #130); with no notch 380, and 460 while it needs you.
    static func width(notched: Bool, needsYou: Bool) -> CGFloat { notched || needsYou ? barWideWidth : barWidth }

    /// The bar: centred on the notch and as tall as it, hanging from the top of the screen; with no notch, a capsule
    /// 10 pt under the menu bar, centred on the visible area.
    static func barFrame(notch: CGRect?, screen: CGRect, visible: CGRect, needsYou: Bool) -> CGRect {
        let w = width(notched: notch != nil, needsYou: needsYou)
        if let n = notch { return CGRect(x: n.midX - w / 2, y: screen.maxY - n.height, width: w, height: n.height) }
        return CGRect(x: visible.midX - w / 2, y: visible.maxY - barHeight - 10, width: w, height: barHeight)
    }

    /// The bar's inset from its ends, and the room it keeps clear on each side of the notch.
    static let barInset: CGFloat = 16
    static let notchGap: CGFloat = 8

    /// How wide each side of the bar is at a notch `notchWidth` wide (the bar centred on it): what is left of the bar
    /// outside the notch, its inset and a gap -- the words on each side are cut to it, never under the notch (#130
    /// Codex review: an 84 pt spacer let a 200 pt notch hide the paused line). nil: no notch, the sides share the bar.
    static func sideWidth(bar: CGFloat, notchWidth: CGFloat?) -> CGFloat? {
        guard let n = notchWidth, n > 0 else { return nil }
        return max(0, (bar - n) / 2 - barInset - notchGap)
    }

    /// How a run ended, in the collapsed island's word beside ✓ or !.
    enum Ending: Equatable { case done, failed, stopped }

    /// "Done" / "Didn't finish" / "Stopped": the key, for L().
    static func endWord(_ e: Ending) -> String {
        switch e {
        case .done: "Done"
        case .failed: "Didn't finish"
        case .stopped: "Stopped"
        }
    }

    /// A run that was done shows so this long, then the bar goes...
    static let resultOpenSeconds: Double = 6
    /// ...one that didn't finish or was stopped stays until clicked, or this long (its why is to be read).
    static let resultLingerSeconds: Double = 120
}

/// What a run is doing before its first step: each takes from a second to a minute, and a bare "starting…" for that
/// long read as frozen.
enum RunStage: String, CaseIterable {
    /// The request is on its way to the helper.
    case starting
    /// The helper is loading the planner's models (the first run after a restart).
    case brain
    /// The vision model, for an app with no accessibility tree.
    case eyes
    /// The helper started deskmind-hands.
    case hands
    /// deskmind-hands is looking at the apps and deciding its first step.
    case looking

    var key: String {
        switch self {
        case .starting: "Connecting to the helper…"
        case .brain: "Loading the local model…"
        case .eyes: "Loading the vision model…"
        case .hands: "Starting Hands…"
        case .looking: "Looking at the screen and choosing the first step…"
        }
    }

    /// The stage in a word or two, for the island's collapsed wing beside the notch: "Vision 12s". The wing said only
    /// "Starting" through a 20-30 s start, and what it was waiting for showed only on hover.
    var shortKey: String {
        switch self {
        case .starting: "Connecting"
        case .brain: "Model"
        case .eyes: "Vision"
        case .hands: "Starting"
        case .looking: "Looking"
        }
    }

    func wing(seconds: Int, lang: ResolvedLang) -> String {
        seconds >= 1 ? L(shortKey, lang: lang) + " " + L("%ds", seconds, lang: lang) : L(shortKey, lang: lang)
    }

    /// "Loading the vision model… 12 s (usually about 20 s)": the seconds once there is one to count, the usual
    /// time when this stage has been timed before and this one is not far past it.
    func line(seconds: Int, typical: Int? = nil, lang: ResolvedLang) -> String {
        var s = L(key, lang: lang)
        if seconds >= 1 { s += " " + L("%d s", seconds, lang: lang) }
        if let t = typical, t >= 3, seconds < t * 3 { s += " " + L("(usually about %d s)", t, lang: lang) }
        return s
    }
}
