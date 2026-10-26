// Every colour the app draws, as tokens (handoff §3.10; owner 10-25 on dark mode): each a light and a dark value, as
// numbers. Main/Brand.swift makes the views' colours from these -- resolved by the appearance the view is drawn in --
// and nothing else in the 0.5 window and its sheets names a colour (L10nTests: the static check). The tests check every
// text colour against every background it is drawn on, in both appearances (contrast at least 4.5:1, WCAG 2 AA body
// text). The dark values pass that; their look is a first pass, to be polished.
//
// The tints text sits on are solid colours worked out here per appearance, never a translucent fill: one would take
// the colour of whatever is under it (the sidebar's material, the wallpaper through it), and the contrast checked
// would not be the one on screen.

import Foundation

enum ShellPalette {
    enum Appearance: CaseIterable { case light, dark }

    /// A colour in both appearances.
    struct Tone: Equatable {
        let light: UInt32
        let dark: UInt32
        func value(_ a: Appearance) -> UInt32 { a == .dark ? dark : light }
    }

    // MARK: the tokens

    static let ink = Tone(light: 0x262B28, dark: 0xE7E9E4)          // body text; the prominent button's fill
    static let paper = Tone(light: 0xF4F1EA, dark: 0x1C1F1D)        // the window; the prominent button's text
    static let card = Tone(light: 0xFFFEFA, dark: 0x262A27)         // a card
    static let secondary = Tone(light: 0x5E675F, dark: 0xA7B0A8)    // secondary text (sage is 4.37 on paper: not for text)
    static let orangeText = Tone(light: 0xA3402A, dark: 0xF0907A)   // orange text (dot is 3.85: graphics only)
    static let error = Tone(light: 0xB42318, dark: 0xFF8A80)        // a field's error line
    static let dot = Tone(light: 0xC95536, dark: 0xE06B4C)          // the orange dot: graphics only
    static let sage = Tone(light: 0x69736A, dark: 0x8E988F)         // graphics only
    static let mist = Tone(light: 0xB2BBAF, dark: 0x4C554E)         // graphics, and the selected row's tint
    static let line = Tone(light: 0xD5D3C9, dark: 0x3B413D)         // hairlines
    static let softLine = Tone(light: 0xE2DFD6, dark: 0x323834)     // a section card's edge (the right column), a fold's rule
    static let buttonLine = Tone(light: 0xC9C6BB, dark: 0x4A524B)   // a secondary button's edge
    static let ok = Tone(light: 0x3F6B41, dark: 0x7FB283)           // all is well (a dot, a check): graphics only
    /// The sidebar: a step darker than the paper (P1Main #EAE6DC).
    static let sidebar = Tone(light: 0xEAE6DC, dark: 0x151816)
    /// The user's bubble (#E6E3DA).
    static let bubble = Tone(light: 0xE6E3DA, dark: 0x2F3430)
    /// A conversation waiting for you, in the sidebar (#FBE7E1); its 「等你」 pill is card-coloured text on orangeText.
    static let waitRow = Tone(light: 0xFBE7E1, dark: 0x3A2822)
    /// The live view's frame (the ink one, dark in both appearances), its text and its quieter text and icons.
    static let frame = Tone(light: 0x262B28, dark: 0x0F1110)
    static let frameText = Tone(light: 0xF4F1EA, dark: 0xF4F1EA)
    static let frameQuiet = Tone(light: 0xD3D8D2, dark: 0xD3D8D2)

    /// The sidebar and the agent's column: the card at 60 % over the paper.
    static let panel = tint(card, 0.6, over: paper)
    /// The sidebar's 「新对话」 row while no conversation is selected: mist at 25 % over the panel.
    static let panelSelected = tint(mist, 0.25, over: panel)
    /// A banner in the chat (cloud models off, a notice): the orange at 10 % over the paper.
    static let banner = tint(dot, 0.10, over: paper)
    /// A problem row: the orange at 7 % over the paper.
    static let problem = tint(dot, 0.07, over: paper)

    /// The ink surfaces (the float, the first run's left column; P1Float, P1Setup): the same in both appearances.
    static let inkSurface = Tone(light: 0x262B28, dark: 0x262B28)
    static let onInk = Tone(light: 0xF4F1EA, dark: 0xF4F1EA)            // text on it; its primary button's fill
    static let onInkMuted = Tone(light: 0xB9C1B8, dark: 0xB9C1B8)       // its secondary text
    static let onInkOrange = Tone(light: 0xF2B3A1, dark: 0xF2B3A1)      // 「等你」「需要你」 on it
    static let onInkLink = Tone(light: 0xF2C9BC, dark: 0xF2C9BC)        // 「去主窗口回答」 on it
    static let onInkPromise = Tone(light: 0xE58A6E, dark: 0xE58A6E)     // the first run's promise marks
    static let inkButton = Tone(light: 0x313632, dark: 0x313632)        // its secondary button's fill
    static let inkButtonLine = Tone(light: 0x4A524B, dark: 0x4A524B)    // that button's edge
    static let inkStop = Tone(light: 0x3A3F3B, dark: 0x3A3F3B)          // its round Stop's fill

    /// The island (one bar at the notch, the same in both appearances, as the hardware is): its fill, its left text,
    /// its right text, and its grey dot (preparing, paused, didn't finish). Working and needing you are the orange dot,
    /// done is the text's colour (Island board: no colour outside the palette).
    static let islandFill = Tone(light: 0x0E0F0E, dark: 0x0E0F0E)
    static let islandText = Tone(light: 0xF4F1EA, dark: 0xF4F1EA)
    static let islandMuted = Tone(light: 0xB2BBAF, dark: 0xB2BBAF)
    static let islandGrey = Tone(light: 0x8C958C, dark: 0x8C958C)

    /// Text colours and the backgrounds each is drawn on (both appearances: `textOn(_:)`).
    static let textPairs: [(text: Tone, background: Tone)] = [
        (ink, paper), (ink, card), (ink, panel), (ink, panelSelected), (ink, banner), (ink, sidebar), (ink, bubble), (ink, waitRow),
        (secondary, paper), (secondary, card), (secondary, panel), (secondary, problem), (secondary, banner), (secondary, sidebar),
        (secondary, bubble), (secondary, waitRow),
        (orangeText, paper), (orangeText, card), (orangeText, problem), (orangeText, banner), (orangeText, sidebar), (orangeText, waitRow),
        (card, orangeText),                 // the sidebar's 「等你」 pill
        (frameText, frame), (frameQuiet, frame),
        (error, card), (error, paper),
        (paper, ink),                       // the prominent button: paper text on an ink capsule
        (islandText, islandFill), (islandMuted, islandFill), (onInkOrange, islandFill),
        (onInk, inkSurface), (onInkMuted, inkSurface), (onInkOrange, inkSurface), (onInkLink, inkSurface), (onInkPromise, inkSurface),
        (inkSurface, onInk),                // the float's primary button: ink text on its light fill
        (onInk, inkButton), (onInkMuted, inkButton),
    ]
    static func textOn(_ a: Appearance) -> [(text: UInt32, background: UInt32)] {
        textPairs.map { ($0.text.value(a), $0.background.value(a)) }
    }

    // MARK: arithmetic

    /// `top` at `alpha` over `bottom`, in each appearance.
    static func tint(_ top: Tone, _ alpha: Double, over bottom: Tone) -> Tone {
        Tone(light: blend(top.light, alpha, over: bottom.light), dark: blend(top.dark, alpha, over: bottom.dark))
    }

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
