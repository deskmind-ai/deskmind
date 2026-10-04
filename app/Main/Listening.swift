// 小方 listening on the home screen, and its dot flying off to work when a task starts.
//
// 小方 sits behind the top edge of the instruction box. Every movement reports a state, never decoration:
// - the box is empty: only the top of its head and two sleepy eyes show;
// - you type: it pops its head up onto the edge (a spring), its eyes follow where you are in the sentence; each burst
//   of typing begins with one small sway (3°), none while you keep typing;
// - a 1.2 s pause: one blink; 8 s without a key: it slowly sinks back;
// - an app name recognised: it stands up with a small hop, eyes lit and looking down at the line below;
// - a file named with no folder attached: its head tilts and a hand points down at Attach folder;
// - Start: the orange dot at its foot flies in an arc into the notch, where the island lights up.
// All of it is off with Reduce Motion. The figure is drawn from the brand mark (brand/xiaofang/*.svg, 200 × 216).

import AppKit
import SwiftUI

struct ListeningXiaoFang: View {
    let text: String
    /// An app was recognised in the instruction; it is ready to start.
    let understood: Bool
    /// A file is named and no folder is attached.
    let unsure: Bool
    /// The dot has flown off (a task just started): 小方 stands without it for a moment.
    var dotAway = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var typing = false
    @State private var dozing = true
    @State private var sway = 0.0
    @State private var hop = false
    @State private var blink = false
    @State private var pauseWork: DispatchWorkItem?
    @State private var dozeWork: DispatchWorkItem?

    static let size = CGSize(width: 76, height: 82)

    private var rise: CGFloat { understood ? 0 : (dozing && text.isEmpty ? 46 : (dozing ? 46 : 18)) }
    private var gaze: CGSize {
        if dozing { return .zero }
        if understood { return CGSize(width: -2, height: 7) }
        if unsure { return CGSize(width: -6, height: 4) }
        return CGSize(width: -5 + min(Double(text.count) / 28, 1) * 10, height: 4)
    }

    var body: some View {
        Canvas { ctx, size in
            let k = size.width / 200
            ctx.scaleBy(x: k, y: k)
            let ink = GraphicsContext.Shading.color(Brand.ink)
            ctx.fill(Self.path("M45 28H153Q166 28 166 41V127H147V65H53V104H34V41Q34 28 45 28Z"), with: ink)
            ctx.fill(Self.path("M34 112H53V148H124V168H46Q34 168 34 156Z"), with: ink)
            ctx.fill(Self.path("M65 168H76V181H79Q82 181 82 185V188H61V185Q61 181 65 181Z"), with: ink)
            ctx.fill(Self.path("M112 168H123V181H127Q131 181 131 185V188H111V185Q111 181 112 181Z"), with: ink)
            // Arms: at its sides; the right one points down at the folder button when it is unsure.
            var left = ctx, right = ctx
            if unsure {
                left.translateBy(x: 25, y: 108); left.rotate(by: .degrees(24)); left.translateBy(x: -25, y: -108)
                right.translateBy(x: 179, y: 108); right.rotate(by: .degrees(-40)); right.translateBy(x: -179, y: -108)
            }
            left.fill(Path(roundedRect: CGRect(x: 23, y: 100, width: 6.5, height: 19), cornerRadius: 3), with: ink)
            right.fill(Path(roundedRect: CGRect(x: 173, y: 100, width: 6.5, height: 19), cornerRadius: 3), with: ink)
            // Eyes: dots that follow your words, wider when it understood, a line when dozing or blinking.
            let paper = GraphicsContext.Shading.color(Brand.paper)
            for cx in [91.0, 119.0] {
                let x = cx + gaze.width, y = 47 + gaze.height
                if dozing || blink {
                    ctx.fill(Path(roundedRect: CGRect(x: x - 3.6, y: y - 0.9, width: 7.2, height: 1.8), cornerRadius: 0.9), with: paper)
                } else {
                    let r = understood ? 3.4 : 2.6
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: paper)
                }
            }
            if !dotAway {
                ctx.fill(Path(ellipseIn: CGRect(x: 139, y: 138, width: 34, height: 34)), with: .color(Brand.dot))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .rotationEffect(.degrees(unsure ? -6 : sway), anchor: UnitPoint(x: 0.5, y: 0.92))
        .offset(y: rise + (hop ? -10 : 0))
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.62), value: rise)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.55), value: hop)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: unsure)
        .accessibilityHidden(true)
        .onChange(of: text) { old, new in typed(old: old, new: new) }
        .onChange(of: understood) { _, now in
            guard now, !reduceMotion else { return }
            hop = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { hop = false }
        }
    }

    private func typed(old: String, new: String) {
        if new.isEmpty { typing = false; dozing = true; return }
        let burstBegins = !typing
        typing = true; dozing = false
        if burstBegins && !reduceMotion {
            // One sway as a burst of typing begins: like a nod, never during the burst.
            let steps: [(Double, Double)] = [(-3, 0.19), (2, 0.2), (-0.6, 0.15), (0, 0.1)]
            var t = 0.0
            for (angle, d) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { withAnimation(.easeOut(duration: d)) { sway = angle } }
                t += d
            }
        }
        pauseWork?.cancel(); dozeWork?.cancel()
        let pause = DispatchWorkItem {
            typing = false
            guard !reduceMotion else { return }
            blink = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { blink = false }
        }
        let doze = DispatchWorkItem { if !understood { dozing = true } }
        pauseWork = pause; dozeWork = doze
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: pause)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: doze)
    }

    /// The few SVG path commands the brand mark uses (M, H, V, Q, Z), absolute.
    static func path(_ d: String) -> Path {
        var p = Path()
        let scanner = Scanner(string: d)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,")
        var cur = CGPoint.zero
        func num() -> CGFloat { CGFloat(scanner.scanDouble() ?? 0) }
        while !scanner.isAtEnd {
            guard let c = scanner.scanCharacter() else { break }
            switch c {
            case "M": cur = CGPoint(x: num(), y: num()); p.move(to: cur)
            case "H": cur = CGPoint(x: num(), y: cur.y); p.addLine(to: cur)
            case "V": cur = CGPoint(x: cur.x, y: num()); p.addLine(to: cur)
            case "Q": let c1 = CGPoint(x: num(), y: num()); cur = CGPoint(x: num(), y: num()); p.addQuadCurve(to: cur, control: c1)
            case "Z": p.closeSubpath()
            default: break
            }
        }
        return p
    }
}

/// The orange dot flying from 小方 into the notch when a task starts (about 450 ms, over everything, taking no clicks).
@MainActor
enum DotFlight {
    private static var panel: NSPanel?

    /// `from`: the dot's centre on screen (AppKit coordinates).
    static func launch(from: CGPoint) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(from) }) ?? NSScreen.main else { return }
        panel?.orderOut(nil)
        let f = screen.frame
        let p = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        p.isOpaque = false; p.backgroundColor = .clear; p.ignoresMouseEvents = true; p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let v = NSView(frame: NSRect(origin: .zero, size: f.size)); v.wantsLayer = true
        p.contentView = v
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: 13, height: 13)
        dot.cornerRadius = 6.5
        dot.backgroundColor = NSColor(srgbRed: 0xC9 / 255.0, green: 0x55 / 255.0, blue: 0x36 / 255.0, alpha: 1).cgColor
        let start = CGPoint(x: from.x - f.minX, y: from.y - f.minY)
        let end = CGPoint(x: f.width / 2, y: f.height - 16)   // the notch (or the top centre without one)
        dot.position = end
        v.layer?.addSublayer(dot)
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: CGPoint(x: start.x + (end.x - start.x) * 0.25, y: end.y + 40))
        let move = CAKeyframeAnimation(keyPath: "position"); move.path = path
        let shrink = CABasicAnimation(keyPath: "transform.scale"); shrink.fromValue = 1; shrink.toValue = 0.55
        let fade = CAKeyframeAnimation(keyPath: "opacity"); fade.values = [1, 1, 0.2]; fade.keyTimes = [0, 0.8, 1]
        let g = CAAnimationGroup(); g.animations = [move, shrink, fade]; g.duration = 0.45
        g.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.6, 0.4, 1)
        g.fillMode = .forwards; g.isRemovedOnCompletion = false
        p.orderFrontRegardless()
        dot.add(g, forKey: "fly")
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { p.orderOut(nil); if panel === p { panel = nil } }
    }
}
