// DeskMind VI 1.0 in code: paper, ink, the orange dot, sage for secondary text, and 小方 for state. The colours are
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

    static func image(_ name: String) -> NSImage {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"), let img = NSImage(contentsOf: url) {
            return img
        }
        return NSImage(size: NSSize(width: 1, height: 1))
    }

    /// 小方, the logo come a little alive: idle while waiting, notice when something needs the user, done when set.
    enum Mood: String { case idle, notice, done, rest }
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

struct XiaoFang: View {
    let mood: Brand.Mood
    var size: CGFloat = 96
    @State private var bob = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(nsImage: Brand.image(mood.rawValue))
            .resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size)
            // (its images are dark ink: in Dark Mode they sit on a light badge, a little larger than they are)
            .background(Circle().fill(Color(ShellPalette.badge)).padding(-size * 0.06).opacity(scheme == .dark ? 1 : 0))
            .offset(y: bob ? -3 : 0)
            .animation(mood == .done ? .spring(response: 0.35, dampingFraction: 0.5)
                                     : .easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: bob)
            .onAppear { bob = true }
            .id(mood)   // a new mood restarts the animation
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
