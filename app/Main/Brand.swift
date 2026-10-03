// DeskMind VI 1.0 in code: paper, ink, the orange dot, sage for secondary text, and 小方 for state.

import AppKit
import SwiftUI

enum Brand {
    static let ink = Color(hex: 0x262B28)
    static let paper = Color(hex: 0xF4F1EA)
    static let card = Color(hex: 0xFFFEFA)
    static let dot = Color(hex: 0xC95536)
    static let sage = Color(hex: 0x69736A)
    static let mist = Color(hex: 0xB2BBAF)
    static let line = Color(hex: 0xD5D3C9)

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
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

struct XiaoFang: View {
    let mood: Brand.Mood
    var size: CGFloat = 96
    @State private var bob = false

    var body: some View {
        Image(nsImage: Brand.image(mood.rawValue))
            .resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size)
            .offset(y: bob ? -3 : 0)
            .animation(mood == .done ? .spring(response: 0.35, dampingFraction: 0.5)
                                     : .easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: bob)
            .onAppear { bob = true }
            .id(mood)   // a new mood restarts the animation
    }
}

/// The primary button: ink capsule, paper text. The secondary one is outlined in ink.
struct InkButtonStyle: ButtonStyle {
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 16).padding(.vertical, 7)
            .foregroundStyle(prominent ? Brand.paper : Brand.ink)
            .background(Capsule().fill(prominent ? Brand.ink : Color.clear))
            .overlay(Capsule().strokeBorder(Brand.ink, lineWidth: prominent ? 0 : 1.2))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
            .pointerStyle(.link)   // a hand over every button, as a click target should show
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
