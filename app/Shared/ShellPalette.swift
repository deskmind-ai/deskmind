// The 0.5 window's text colours, as numbers (handoff §3.10): the views make their colours from these, and the tests
// check every text colour against the backgrounds it is drawn on (contrast at least 4.5:1, WCAG 2 AA body text).

import Foundation

enum ShellPalette {
    static let ink: UInt32 = 0x262B28          // Brand.ink: body text
    static let paper: UInt32 = 0xF4F1EA        // Brand.paper: the window
    static let card: UInt32 = 0xFFFEFA         // Brand.card: a card
    static let secondary: UInt32 = 0x5E675F    // secondary text (Brand.sage #69736A is 4.37 on paper: not for text)
    static let orangeText: UInt32 = 0xA3402A   // orange text (Brand.dot #C95536 is 3.85: graphics only)
    static let dot: UInt32 = 0xC95536          // Brand.dot
    static let mist: UInt32 = 0xB2BBAF         // Brand.mist

    // The tinted backgrounds text sits on, as solid colours: a translucent fill would take the colour of whatever is
    // under it -- the sidebar's material is dark in Dark Mode, and the wallpaper shows through it -- so the contrast
    // checked here would not be the one on screen. The window is light in both appearances (MainSplitView).
    /// The sidebar and the agent's column: the card at 60 % over the paper.
    static let panel = blend(card, 0.6, over: paper)
    /// The sidebar's 「新对话」 row while no conversation is selected: mist at 25 % over the panel.
    static let panelSelected = blend(mist, 0.25, over: panel)
    /// A banner in the chat (cloud models off, a notice): the orange at 10 % over the paper.
    static let banner = blend(dot, 0.10, over: paper)
    /// A problem row: the orange at 7 % over the paper.
    static let problem = blend(dot, 0.07, over: paper)

    /// Text colours and the backgrounds each is drawn on.
    static let textOn: [(text: UInt32, background: UInt32)] = [
        (ink, paper), (ink, card), (secondary, paper), (secondary, card), (orangeText, paper), (orangeText, card),
        (ink, panel), (secondary, panel), (ink, panelSelected), (ink, banner), (orangeText, problem), (secondary, problem)]

    /// `top` at `alpha` over `bottom`, each channel rounded: the colour on screen.
    static func blend(_ top: UInt32, _ alpha: Double, over bottom: UInt32) -> UInt32 {
        func ch(_ c: UInt32, _ shift: UInt32) -> Double { Double((c >> shift) & 0xFF) }
        var out: UInt32 = 0
        for shift in [UInt32(16), 8, 0] {
            let v = (alpha * ch(top, shift) + (1 - alpha) * ch(bottom, shift)).rounded()
            out |= UInt32(min(max(v, 0), 255)) << shift
        }
        return out
    }

    /// WCAG 2 contrast ratio of two sRGB colours.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func lum(_ c: UInt32) -> Double {
            func ch(_ v: UInt32) -> Double {
                let x = Double(v) / 255
                return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * ch((c >> 16) & 0xFF) + 0.7152 * ch((c >> 8) & 0xFF) + 0.0722 * ch(c & 0xFF)
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
