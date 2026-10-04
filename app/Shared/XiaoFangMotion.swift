// 小方 listening on the home screen (Main/Listening.swift): how far it rises, where its eyes look, and where its dot
// is when it flies off. What needs no screen, so tests/DecisionTests.swift checks it.

import CoreGraphics
import Foundation

enum XiaoFangMotion {
    /// The figure as drawn, in points (the brand mark is 200 × 216).
    static let size = CGSize(width: 76, height: 82)
    /// How far it sits below the box's top edge: hidden but for its head while dozing (the box empty, or 8 s without
    /// a key), its head up on the edge while you type, standing once it has understood (an app recognised).
    static func rise(understood: Bool, dozing: Bool) -> CGFloat { understood ? 0 : (dozing ? 46 : 18) }
    /// A pause in typing this long: one blink. This long without a key: it sinks back.
    static let blinkAfter: Double = 1.2, dozeAfter: Double = 8
    /// The sway as a burst of typing begins (degrees, seconds): once a burst, never during one.
    static let sway: [(angle: Double, seconds: Double)] = [(-3, 0.19), (2, 0.2), (-0.6, 0.15), (0, 0.1)]

    /// Whether a change to the text is typing, not text put in at once (an example picked, a long paste, the box
    /// cleared after Start). An input method commits a few characters at a time (拼音 often 2-6), so up to 8 is typing.
    static let typingChunk = 8
    static func typed(old: String, new: String) -> Bool { !new.isEmpty && abs(new.count - old.count) <= typingChunk }

    /// Where the eyes look, from their resting place (brand-mark units): down at the line below once it understood,
    /// down-left at Attach folder when unsure, else along your sentence as it grows.
    static func gaze(dozing: Bool, understood: Bool, unsure: Bool, characters: Int) -> CGSize {
        if dozing { return .zero }
        if understood { return CGSize(width: -2, height: 7) }
        if unsure { return CGSize(width: -6, height: 4) }
        return CGSize(width: -5 + min(Double(characters) / 28, 1) * 10, height: 4)
    }

    /// The dot's centre, given where the figure is drawn (any coordinates with the origin top-left): the brand
    /// mark's dot is at 156, 155, and the mark is scaled by its width.
    static func dot(in frame: CGRect) -> CGPoint {
        let k = frame.width / 200
        return CGPoint(x: frame.minX + 156 * k, y: frame.minY + 155 * k)
    }

    /// A point in SwiftUI's global space (on macOS: the window's, origin top-left -- not the screen's) in the
    /// window's base coordinates (origin bottom-left), which NSWindow.convertPoint(toScreen:) takes.
    static func windowBase(_ p: CGPoint, contentHeight: CGFloat) -> CGPoint { CGPoint(x: p.x, y: contentHeight - p.y) }
}
