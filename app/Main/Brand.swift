// DeskMind VI 1.0 in code: paper, ink, the orange dot, sage for secondary text, and 小方 (XiaoFace) for state. The colours are
// Shared/ShellPalette.swift's tokens, each resolved by the appearance it is drawn in (light or dark): this file is the
// one place a colour is made (`Color(_ tone:)`; L10nTests checks the 0.5 window and its sheets name none of their own).

import AppKit
import SwiftUI

enum Brand {
    static let ink = Color(ShellPalette.ink)
    static let paper = Color(ShellPalette.paper)
    static let card = Color(ShellPalette.card)
    static let dot = Color(ShellPalette.dot)
    static let sage = Color(ShellPalette.sage)
    static let mist = Color(ShellPalette.mist)
    static let line = Color(ShellPalette.line)

    /// A picture for the appearance it is drawn in: `<name>-dark` in dark when there is one (Resources/brand/dark.swift
    /// makes it from the light one), else `<name>`.
    static func image(_ name: String, scheme: ColorScheme) -> NSImage {
        if scheme == .dark, Bundle.main.url(forResource: name + "-dark", withExtension: "png") != nil { return image(name + "-dark") }
        return image(name)
    }

    static func image(_ name: String) -> NSImage {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"), let img = NSImage(contentsOf: url) {
            return img
        }
        return NSImage(size: NSSize(width: 1, height: 1))
    }

}

extension Color {
    /// A token as a colour: its light value in a light appearance, its dark one in a dark appearance (resolved where it
    /// is drawn, so a window, a sheet and a panel each follow their own).
    init(_ tone: ShellPalette.Tone) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
            let v = tone.value(dark ? .dark : .light)
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }
}

/// 小方's dot: lit (the orange one), or mist (idle, no task).
enum XiaoDot: Equatable { case lit, mist }

/// 小方, drawn (the boards' face): a rounded square in ink -- in the paper colour on an ink surface -- two eyes in it,
/// and the orange dot pressed on its lower right corner. `size` is the square's width (the boards: 28 in the right
/// column, 20 in the float and the island). The eyes (XiaoEyes) move between their shapes in 150 ms; not with Reduce
/// Motion.
struct XiaoFace: View {
    let eyes: XiaoEyes
    var size: CGFloat = 28
    var onInk = false
    /// Its dot: lit, the orange, while a task is about (the island's and the float's always), mist while the column is idle with
    /// no task (P3States 「还没有任务」), with no halo.
    var dot: XiaoDot = .lit
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        let w = size, h = (size * 25 / 28).rounded()
        let stroke: Color = onInk ? Color(ShellPalette.onInk) : Brand.ink
        let dot = (size * 0.38).rounded()
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: size * 0.21, style: .continuous)
                .strokeBorder(stroke, lineWidth: max(2, size * 0.107))
                .frame(width: w, height: h)
            Eye(eyes: eyes, left: true, w: w, h: h).fill(stroke)
            Eye(eyes: eyes, left: false, w: w, h: h).fill(stroke)
            Circle().fill(self.dot == .mist ? Brand.mist : Brand.dot)
                .overlay(Circle().stroke(Brand.dot.opacity(eyes == .up && self.dot == .lit ? 0.3 : 0), lineWidth: dot * 0.3))
                .frame(width: dot, height: dot)
                .offset(x: w - dot * 0.6, y: h - dot * 0.6)
        }
        .frame(width: w + dot * 0.4, height: h + dot * 0.4, alignment: .topLeading)
        .animation(reduce ? nil : .easeOut(duration: 0.15), value: eyes)
        .accessibilityHidden(true)
    }

    /// One eye, as one shape whose numbers move between the four looks (a dot, a dot up, an arc, a line): its centre,
    /// its width and height, and how much of an arc it is.
    struct Eye: Shape {
        var cx: CGFloat, cy: CGFloat, ew: CGFloat, eh: CGFloat, arc: CGFloat

        init(eyes: XiaoEyes, left: Bool, w: CGFloat, h: CGFloat) {
            let dot = w * 0.125
            switch eyes {
            case .look: cx = w * (left ? 0.455 : 0.67); cy = h * 0.47; ew = dot * 0.85; eh = dot * 0.85; arc = 0
            case .up: cx = w * (left ? 0.36 : 0.64); cy = h * 0.31; ew = dot; eh = dot; arc = 0
            case .happy: cx = w * (left ? 0.36 : 0.64); cy = h * 0.36; ew = w * 0.2; eh = h * 0.16; arc = 1
            case .flat: cx = w * (left ? 0.36 : 0.64); cy = h * 0.4; ew = w * 0.2; eh = max(1.5, w * 0.07); arc = 0
            }
        }

        var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>> {
            get { AnimatablePair(AnimatablePair(cx, cy), AnimatablePair(AnimatablePair(ew, eh), arc)) }
            set { cx = newValue.first.first; cy = newValue.first.second; ew = newValue.second.first.first; eh = newValue.second.first.second; arc = newValue.second.second }
        }

        func path(in rect: CGRect) -> Path {
            let r = CGRect(x: cx - ew / 2, y: cy - eh / 2, width: ew, height: eh)
            guard arc > 0.01 else { return Path(roundedRect: r, cornerRadius: min(ew, eh) / 2) }
            // ^ : an arc's band, as thick as a dot's quarter of the width
            var p = Path()
            let t = max(1.4, ew * 0.32) * arc
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - eh * 0.6))
            p.addLine(to: CGPoint(x: r.maxX - t * 0.5, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX + t * 0.5, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - eh * 0.6 + t * 1.6))
            p.closeSubpath()
            return p
        }
    }
}

/// A button (P1Waiting): 44 pt tall, radius 13, 15 px -- the primary one ink with paper text, the secondary one the card
/// colour in a 1 pt #C9C6BB edge. `small`: a pill in a bar or a line (the header's Stop, the composer's): 32 pt, 13 px,
/// the hairline edge. `fill`: as wide as it is given (buttons side by side share a row: WeightedRow).
struct InkButtonStyle: ButtonStyle {
    var prominent = true
    var small = false
    var fill = false
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: small ? 16 : 13, style: .continuous)
        configuration.label
            .font(.system(size: small ? 13 : 15, weight: prominent ? .semibold : .regular))
            .multilineTextAlignment(.center)
            .padding(.horizontal, small ? 14 : 16).padding(.vertical, small ? 6 : 10)
            .frame(maxWidth: fill ? .infinity : nil, minHeight: small ? 32 : 44)
            .foregroundStyle(prominent ? Brand.paper : Brand.ink)
            .background(shape.fill(prominent ? Brand.ink : Brand.card))
            .overlay(shape.strokeBorder(prominent ? Color.clear : small ? Brand.line : Color(ShellPalette.buttonLine), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(shape)
            .pointerStyle(.link)   // a hand over every button, as a click target should show
    }
}

/// Buttons side by side in one row, sharing its width by weight (P1Waiting: the primary 1.3, each other 1), as tall as
/// the tallest.
struct WeightedRow: Layout {
    var weights: [Double]
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = split(proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width } + spacing * CGFloat(max(0, subviews.count - 1)), subviews.count)
        let h = zip(subviews, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: proposal.width ?? widths.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)), height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (v, w) in zip(subviews, split(bounds.width, subviews.count)) {
            v.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + spacing
        }
    }

    private func split(_ total: CGFloat, _ n: Int) -> [CGFloat] {
        guard n > 0 else { return [] }
        let ws = (0..<n).map { $0 < weights.count ? weights[$0] : 1 }
        let room = max(0, total - spacing * CGFloat(n - 1))
        let sum = ws.reduce(0, +)
        return ws.map { CGFloat($0 / sum) * room }
    }
}

/// The brand's square-with-a-dot, drawn: the checkmark of this app is the dot landing in the corner.
struct DotMark: View {
    let on: Bool
    var size: CGFloat = 30
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 3).strokeBorder(on ? Brand.ink : Brand.mist, lineWidth: 2.2)
                .frame(width: size, height: size)
            Circle().fill(on ? Brand.dot : Brand.mist.opacity(0.0))
                .frame(width: size * 0.42, height: size * 0.42)
                .offset(x: size * 0.12, y: size * 0.12)
                .scaleEffect(on ? 1 : 0.2)
                .animation(.spring(response: 0.4, dampingFraction: 0.55), value: on)
        }
        .frame(width: size + 6, height: size + 6)
    }
}
