// The right column's live view (A4): the pictures of the window the running task acts in (live.watch, the helper's:
// Helper/LiveWatch.swift), watched only while the column is on screen -- the main window not minimised, hidden or
// closed (FrontmostMonitor) -- and dropped the moment it is not (invariant 6). In memory only. The agent's cursor is
// drawn where the last step acted, only on a picture of that step's window (LiveFeed.cursor).

import AppKit
import ImageIO
import SwiftUI

@MainActor
final class LiveDock: ObservableObject {
    struct Picture { let image: NSImage; let window: Int; let epoch: Int; let visible: [Double] }
    @Published private(set) var picture: Picture?
    @Published private(set) var state: LiveFeed.State?
    /// The run's last picture, kept when its window can no longer be taken (no_picture after one: hidden, minimised,
    /// on another desktop) and after the watch ends: the float dims it (CardStates 「窗口不可见」) or shows it as the
    /// task ended. Another run's watch drops it.
    @Published private(set) var last: Picture?
    private var lastRun: String?
    private(set) var run: String?
    private var stop: Flag?

    /// The watch's own: whether it was given up, and the newest picture waiting for the main thread (#125 review: one
    /// in flight at most -- a newer one replaces it; decoded off the main thread).
    final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var on = false
        private var newest: (Picture, Bool)?
        var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
        func set() { lock.lock(); on = true; lock.unlock() }
        /// Keeps `p`; true when a hand-over to the main thread is to be scheduled (none waiting already).
        func offer(_ p: Picture) -> Bool { lock.lock(); defer { lock.unlock() }; let first = newest == nil; newest = (p, true); return first }
        func take() -> Picture? { lock.lock(); defer { lock.unlock() }; let p = newest?.0; newest = nil; return p }
    }

    deinit { stop?.set() }

    /// Watch `run` (nil: watch nothing). The same run again: nothing changes. A watch whose stream ended (the helper
    /// went, a write to it timed out) while still wanted shows no picture and connects again, backing off.
    func watch(_ run: String?) {
        guard run != self.run else { return }
        stop?.set(); stop = nil
        self.run = run; picture = nil; state = nil
        guard let run else { return }
        if run != lastRun { last = nil; lastRun = run }
        let flag = Flag()
        stop = flag
        Thread.detachNewThread { [weak self] in
            var backoff = 1.0
            while !flag.value {
                var heard = false
                _ = HelperSessionTransport().stream(["op": LiveFeed.op, "run_id": run], onLine: { o in
                    guard !flag.value, let line = LiveFeed.read(o) else { return !flag.value }
                    heard = true
                    switch line {
                    case .frame(_, let w, let e, let jpeg, _, _, let v):
                        guard let img = Self.decode(jpeg) else { return true }
                        if flag.offer(Picture(image: img, window: w, epoch: e, visible: v)) {
                            DispatchQueue.main.async { MainActor.assumeIsolated { self?.takePicture(run: run, flag: flag) } }
                        }
                    case .state(_, let s):
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.take(s, run: run, flag: flag) } }
                    }
                    return true
                }, onIdle: { !flag.value })
                guard !flag.value else { break }
                // (the stream ended while still wanted: no picture shown as live, and again after a while)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.lost(run: run, flag: flag) } }
                if heard { backoff = 1 }
                let until = Date().addingTimeInterval(backoff)
                while Date() < until && !flag.value { Thread.sleep(forTimeInterval: 0.1) }
                backoff = min(backoff * 2, 10)
            }
        }
    }

    /// A picture, decoded here (off the main thread), whole (CGImageSource, cached at once).
    nonisolated static func decode(_ jpeg: Data) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
    }

    private func takePicture(run: String, flag: Flag) {
        guard !flag.value, run == self.run, let p = flag.take(), state != .ended else { return }      // (given up since; or ended)
        picture = p; state = .streaming; last = p
    }

    private func take(_ s: LiveFeed.State, run: String, flag: Flag) {
        guard !flag.value, run == self.run else { return }
        state = s
        if s == .ended || s == .noPermission || s == .noPicture { picture = nil }
        if s == .noPermission { last = nil }
    }

    private func lost(run: String, flag: Flag) {
        guard !flag.value, run == self.run else { return }
        picture = nil; state = nil
    }
}

/// The live view in its ink frame (P1Main, CardStates): a title bar -- the orange dot, the app and the window's state,
/// 「放大」 and 「弹出成浮窗」 -- the picture with the agent's cursor and a dashed box round what the step acts on (its
/// target's rect_norm; 「准备点：…」 on the picture while an action card naming its target waits), and the step in a line under it (its human words).
struct LiveFrame: View {
    let picture: LiveDock.Picture?
    let state: LiveFeed.State?
    let app: String?
    let waiting: Bool
    /// The element the open card says it is about to act on (its own consent.target), shown over the picture.
    let about: String?
    let step: String?
    let stepWindow: Int?
    let target: StepTarget?
    /// The rect the dashed box marks (LiveFeed.boxRect): nil, no box; and the window it is in (the card's own, where it
    /// names one; else the step's).
    let boxRect: [Double]?
    var boxWindow: Int? = nil
    @Binding var zoomed: Bool
    let popOut: () -> Void
    /// The frame's own title bar and step line (the right column); false: the picture alone, 110 tall -- the float
    /// draws its own title and line around it (U2).
    var chrome = true
    @Environment(\.lang) private var lang

    var body: some View {
        if chrome { framed } else { picture(height: 110).padding(.horizontal, 6) }
    }

    private var framed: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Brand.dot).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(ShellColor.frameText).lineLimit(1)
                Spacer(minLength: 4)
                barIcon(AnyShape(ZoomPath(inward: zoomed)), zoomed ? L("Make the live view smaller", lang: lang) : L("Enlarge the live view", lang: lang)) { zoomed.toggle() }
                barIcon(AnyShape(PopOutPath()), L("Pop out as a float", lang: lang), popOut)
            }
            .padding(.leading, 12).padding(.trailing, 6).frame(height: 34)
            picture(height: zoomed ? 380 : 214)
                .padding(.horizontal, 6)
            Text(step ?? " ").font(.system(size: 13)).foregroundStyle(Color(ShellPalette.frameStep)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).frame(height: 34)
                .accessibilityLabel(step.map { L("Current step: %@", $0, lang: lang) } ?? "")
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(ShellColor.frame))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: Brand.ink.opacity(0.18), radius: 14, y: 10)
        .accessibilityElement(children: .contain)
    }

    /// The picture, its cursor, the card's box and 「准备点」, or why there is none.
    private func picture(height: CGFloat) -> some View {
            ZStack {
                // (the well white in both appearances, as the boards draw it: a dark card colour round a light
                // window's picture read as the picture not filling it)
                Rectangle().fill(Color(ShellPalette.shotWell))
                if let p = picture {
                    GeometryReader { g in
                        // (in the right column the picture fills its 214 (P1Main), cut to keep the cursor -- else the
                        // box -- in view; the float's small well shows it whole)
                        let size = chrome ? Self.fill(p.image.size, in: g.size) : LiveDockView.fit(p.image.size, in: g.size)
                        let focus = LiveFeed.cursor(pictureWindow: p.window, stepWindow: stepWindow, rectNorm: target?.rectNorm, picture: size, visible: p.visible)
                            ?? LiveFeed.box(pictureWindow: p.window, stepWindow: boxWindow ?? stepWindow, rectNorm: boxRect, picture: size, visible: p.visible).map { CGPoint(x: $0.midX, y: $0.midY) }
                        let shift = chrome ? Self.shift(size, in: g.size, keeping: focus) : .zero
                        ZStack(alignment: .topLeading) {
                            Image(nsImage: p.image).resizable().frame(width: size.width, height: size.height)
                            let box = LiveFeed.box(pictureWindow: p.window, stepWindow: boxWindow ?? stepWindow, rectNorm: boxRect, picture: size, visible: p.visible)
                            if let b = box {
                                RoundedRectangle(cornerRadius: 6).strokeBorder(Brand.dot, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                                    .frame(width: b.width + 8, height: b.height + 8).offset(x: b.minX - 4, y: b.minY - 4)
                                    .accessibilityHidden(true)
                                // 「准备点」 anchored on its box (U3 §2.4)
                                // (on the box's edge, as P1Waiting draws it: no gap between them)
                                if let about {
                                    let o = LiveFeed.tagOrigin(box: b, tagHeight: 18)
                                    tag(about).offset(x: o.x, y: o.y + (o.y < b.minY ? 4 : -4))
                                }
                            }
                            if let c = LiveFeed.cursor(pictureWindow: p.window, stepWindow: stepWindow, rectNorm: target?.rectNorm, picture: size, visible: p.visible) {
                                Circle().fill(Brand.dot).frame(width: 12, height: 12)
                                    .overlay(Circle().strokeBorder(Brand.card, lineWidth: 2))
                                    .offset(x: c.x - 6, y: c.y - 6).accessibilityHidden(true)
                            }
                        }
                        .offset(x: shift.x, y: shift.y)
                        .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                    }
                    .overlay(alignment: .topLeading) {
                        // (no box of the card's own: the tag in the corner, never on a step's box)
                        if let about, LiveFeed.box(pictureWindow: p.window, stepWindow: boxWindow ?? stepWindow, rectNorm: boxRect,
                                                   picture: CGSize(width: 1, height: 1), visible: p.visible) == nil {     // (whether it lands on this picture at all)
                            tag(about).padding(8)
                        }
                    }
                    .accessibilityLabel(L("Live view of the task's window", lang: lang))
                } else {
                    Text(LiveDockView.note(state, lang: lang)).font(.system(size: chrome ? 12 : 11))
                        .foregroundStyle(chrome ? ShellColor.secondary : Color(ShellPalette.inkSurface))
                        .multilineTextAlignment(.center).padding(14)
                }
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func tag(_ about: String) -> some View {
        Text(L("About to click: %@", about, lang: lang)).font(.system(size: 10, weight: .bold)).foregroundStyle(Color(ShellPalette.waitTagText))
            .padding(.horizontal, 6).frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(ShellPalette.waitTag)))
            .fixedSize()
    }

    /// 「<应用> · <窗口的状态>」 (P1Main, P1Waiting): whose window, and that it works in the background -- stopped before
    /// the button the card names while it waits for you -- or has no picture.
    private var title: String {
        let what: String
        if waiting { what = about.map { L("Background window · stopped before %@", $0, lang: lang) } ?? L("Background window · waiting for you", lang: lang) }
        else {
            switch state {
            case .streaming: what = L("Background window", lang: lang)
            case .noPermission, .noPicture: what = L("No picture", lang: lang)
            case .ended: what = L("Ended", lang: lang)
            case nil: what = L("Connecting…", lang: lang)
            }
        }
        return app.map { L("%@ · %@", $0, what, lang: lang) } ?? what
    }

    /// The picture as large as it must be to fill `box`, its ratio kept.
    static func fill(_ image: CGSize, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return box }
        let k = max(box.width / image.width, box.height / image.height)
        return CGSize(width: image.width * k, height: image.height * k)
    }

    /// Where a picture of `size`, bigger than `box`, goes so that `focus` (in its own points) is in view: centred on
    /// it, never past the picture's edges; centred when there is none.
    static func shift(_ size: CGSize, in box: CGSize, keeping focus: CGPoint?) -> CGPoint {
        func one(_ len: CGFloat, _ room: CGFloat, _ f: CGFloat?) -> CGFloat {
            guard len > room else { return (room - len) / 2 }
            let want = f.map { room / 2 - $0 } ?? (room - len) / 2
            return min(0, max(room - len, want))
        }
        return CGPoint(x: one(size.width, box.width, focus?.x), y: one(size.height, box.height, focus?.y))
    }

    private func barIcon(_ icon: AnyShape, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon.stroke(ShellColor.frameQuiet, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)).frame(width: 12, height: 12)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// 「放大」's mark (P1Main: a 12 box, arrows out to ↗ and ↙; `inward`, back in).
struct ZoomPath: Shape {
    var inward = false
    func path(in r: CGRect) -> Path {
        let k = min(r.width, r.height) / 12
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: r.minX + x * k, y: r.minY + y * k) }
        var p = Path()
        if inward {
            p.move(to: pt(11, 5)); p.addLine(to: pt(7, 5)); p.addLine(to: pt(7, 1)); p.move(to: pt(7, 5)); p.addLine(to: pt(11, 1))
            p.move(to: pt(1, 7)); p.addLine(to: pt(5, 7)); p.addLine(to: pt(5, 11)); p.move(to: pt(5, 7)); p.addLine(to: pt(1, 11))
        } else {
            p.move(to: pt(7, 1)); p.addLine(to: pt(11, 1)); p.addLine(to: pt(11, 5)); p.move(to: pt(11, 1)); p.addLine(to: pt(7, 5))
            p.move(to: pt(5, 11)); p.addLine(to: pt(1, 11)); p.addLine(to: pt(1, 7)); p.move(to: pt(1, 11)); p.addLine(to: pt(5, 7))
        }
        return p
    }
}

/// 「弹出成浮窗」's mark (P1Main: a 12 box, a square with a small one in its lower right).
struct PopOutPath: Shape {
    func path(in r: CGRect) -> Path {
        let k = min(r.width, r.height) / 12
        var p = Path(CGRect(x: r.minX + 1.5 * k, y: r.minY + 1.5 * k, width: 9 * k, height: 9 * k))
        p.addRect(CGRect(x: r.minX + 6 * k, y: r.minY + 6 * k, width: 4.5 * k, height: 4.5 * k))
        return p
    }
}

/// The picture, the agent's cursor on it, or why there is none (the float's; the window's is LiveFrame).
struct LiveDockView: View {
    @ObservedObject var dock: LiveDock
    /// The last step's window and target (rect_norm), for the cursor.
    let stepWindow: Int?
    let target: [Double]?
    @Environment(\.lang) private var lang

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Brand.card)
            if let p = dock.picture {
                GeometryReader { g in
                    let size = Self.fit(p.image.size, in: g.size)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: p.image).resizable().frame(width: size.width, height: size.height)
                        if let c = LiveFeed.cursor(pictureWindow: p.window, stepWindow: stepWindow, rectNorm: target, picture: size, visible: p.visible) {
                            Circle().fill(Brand.dot).frame(width: 10, height: 10).offset(x: c.x - 5, y: c.y - 5).accessibilityHidden(true)
                        }
                    }
                    .frame(width: g.size.width, height: g.size.height)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(L("Live view of the task's window", lang: lang))
            } else {
                Text(Self.note(dock.state, lang: lang)).font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
                    .multilineTextAlignment(.center).padding(14)
            }
        }
        .frame(height: 150)
    }

    static func note(_ s: LiveFeed.State?, lang: ResolvedLang) -> String {
        switch s {
        case .noPermission: return L("DeskMind Hands needs Screen Recording to show the window", lang: lang)
        case .ended: return L("The task ended", lang: lang)
        default: return L("No picture of the window yet", lang: lang)
        }
    }

    static func fit(_ image: CGSize, in box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return box }
        let k = min(box.width / image.width, box.height / image.height)
        return CGSize(width: image.width * k, height: image.height * k)
    }
}
