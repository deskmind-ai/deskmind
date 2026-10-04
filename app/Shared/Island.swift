// What needs no screen for the run's status at the top of the screen: where the notch is and the frames of the
// "island" around it (collapsed: the notch with a wing either side; expanded: a panel dropping from it), the plain
// capsule's frame on a screen with no notch, and the line that says which stage a starting run is in and for how long.
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

    /// Room either side of the notch for the status dot and the step, collapsed.
    static let wing: CGFloat = 96
    /// The expanded panel: wide enough for a step's line and the buttons, tall enough for three lines of text.
    static let expanded = CGSize(width: 520, height: 132)

    static func collapsedFrame(notch: CGRect) -> CGRect {
        CGRect(x: notch.minX - wing, y: notch.minY, width: notch.width + 2 * wing, height: notch.height)
    }

    /// Hanging from the top of the screen, centred on the notch; never narrower than the collapsed island.
    static func expandedFrame(notch: CGRect, screen: CGRect) -> CGRect {
        let w = max(expanded.width, notch.width + 2 * wing)
        return CGRect(x: notch.midX - w / 2, y: screen.maxY - expanded.height, width: w, height: expanded.height)
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

    /// A finished run's island stays open this long with its result, then collapses to the notch...
    static let resultOpenSeconds: Double = 6
    /// ...and goes away after this long, unless dismissed first or a new run starts.
    static let resultLingerSeconds: Double = 120

    /// No notch: the capsule under the menu bar, centred, as before.
    static func pillFrame(visible: CGRect, size: CGSize) -> CGRect {
        CGRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 10, width: size.width, height: size.height)
    }
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
        case .hands: "Starting DeskMind Hands…"
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
