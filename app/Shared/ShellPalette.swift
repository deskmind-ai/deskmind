// The 0.5 window's text colours, as numbers (handoff §3.10): the views make their colours from these, and the tests
// check every text colour against the backgrounds it is drawn on (contrast at least 4.5:1, WCAG 2 AA body text).

import Foundation

enum ShellPalette {
    static let ink: UInt32 = 0x262B28          // Brand.ink: body text
    static let paper: UInt32 = 0xF4F1EA        // Brand.paper: the window
    static let card: UInt32 = 0xFFFEFA         // Brand.card: a card
    static let secondary: UInt32 = 0x5E675F    // secondary text (Brand.sage #69736A is 4.37 on paper: not for text)
    static let orangeText: UInt32 = 0xA3402A   // orange text (Brand.dot #C95536 is 3.85: graphics only)

    /// Text colours and the backgrounds each is drawn on.
    static let textOn: [(text: UInt32, background: UInt32)] = [
        (ink, paper), (ink, card), (secondary, paper), (secondary, card), (orangeText, paper), (orangeText, card)]

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
