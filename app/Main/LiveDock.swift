// The right column's live view (A4): the pictures of the window the running task acts in (live.watch, the helper's:
// Helper/LiveWatch.swift), watched only while the column is on screen -- the main window not minimised, hidden or
// closed (FrontmostMonitor) -- and dropped the moment it is not (invariant 6). In memory only. The agent's cursor is
// drawn where the last step acted, only on a picture of that step's window (LiveFeed.cursor).

import AppKit
import SwiftUI

@MainActor
final class LiveDock: ObservableObject {
    struct Picture { let image: NSImage; let window: Int; let epoch: Int }
    @Published private(set) var picture: Picture?
    @Published private(set) var state: LiveFeed.State?
    private(set) var run: String?
    private var stop: Flag?

    final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var on = false
        var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
        func set() { lock.lock(); on = true; lock.unlock() }
    }

    /// Watch `run` (nil: watch nothing). The same run again: nothing changes.
    func watch(_ run: String?) {
        guard run != self.run else { return }
        stop?.set(); stop = nil
        self.run = run; picture = nil; state = nil
        guard let run else { return }
        let flag = Flag()
        stop = flag
        Thread.detachNewThread { [weak self] in
            _ = HelperSessionTransport().stream(["op": LiveFeed.op, "run_id": run], onLine: { o in
                guard !flag.value, let line = LiveFeed.read(o) else { return !flag.value }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.take(line, run: run, flag: flag) } }
                return true
            }, onIdle: { !flag.value })
        }
    }

    private func take(_ line: LiveFeed.Line, run: String, flag: Flag) {
        guard !flag.value, run == self.run else { return }       // (a watch given up since)
        switch line {
        case .frame(_, let w, let e, let jpeg, _, _):
            if let img = NSImage(data: jpeg) { picture = Picture(image: img, window: w, epoch: e); state = .streaming }
        case .state(_, let s):
            state = s
            if s == .ended { picture = nil }
        }
    }
}

/// The picture, the agent's cursor on it, or why there is none.
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
                        if let c = LiveFeed.cursor(pictureWindow: p.window, stepWindow: stepWindow, rectNorm: target, picture: size) {
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
