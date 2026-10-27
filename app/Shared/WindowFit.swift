// The main window's frame at launch (U4 §2.1): SwiftUI restores the frame an earlier version saved, whatever the
// window's least size is now, so a window saved at 1000 × 580 came back narrower than the three columns (the right one
// cut off by the window's edge). Once, when the window appears, its frame is fitted here: big enough already, as it
// is; too small, grown to the least size and kept on its screen. Pure; the app's window and the tests use the same.

import CoreGraphics

enum WindowFit {
    /// `restored`: the window's frame as restored; `min`: its least size; `screen`: the visible part of its screen.
    /// Big enough: unchanged. Too small in either direction: that side grown to the least size (no more than the
    /// screen), its top-left corner kept where it can be, then moved in so the whole window is on the screen.
    static func fit(restored: CGRect, min: CGSize, screen: CGRect) -> CGRect {
        guard restored.width < min.width || restored.height < min.height else { return restored }
        let w = Swift.min(Swift.max(restored.width, min.width), screen.width)
        let h = Swift.min(Swift.max(restored.height, min.height), screen.height)
        // (AppKit's y goes up: the top edge is maxY, kept as it was)
        var x = restored.minX, y = restored.maxY - h
        x = Swift.min(Swift.max(x, screen.minX), screen.maxX - w)
        y = Swift.min(Swift.max(y, screen.minY), screen.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// The three columns' widths (owner, rc.20): the sidebar 256 always; the right column 400 when there is room, giving way
/// first down to 300 so the chat keeps 540 -- at the least window, 1098, the chat 540 and the right column 300. Past
/// 1198 the chat takes the rest. Two 1 pt hairlines between them.
enum ColumnWidths {
    static let sidebar: CGFloat = 256
    static let right: CGFloat = 400
    static let rightMin: CGFloat = 300
    static let chatMin: CGFloat = 540
    static var windowMin: CGFloat { sidebar + chatMin + rightMin + 2 }

    /// The right column's width in a window `total` wide.
    static func right(in total: CGFloat) -> CGFloat {
        Swift.min(right, Swift.max(rightMin, total - sidebar - 2 - chatMin))
    }
}
