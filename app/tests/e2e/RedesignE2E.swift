// End-to-end test of the home screen's 小方 and the GIF export on a real desktop (Main/Listening.swift,
// Main/ReplayGIF.swift):
// - GIFs exported from real PNG frames: frame count, size, timing, names that never overwrite;
// - 小方 in a real window: how far it rises as the text and the state change (measured where it is drawn), its dot
//   where the drawn orange pixels are, the take-off point on screen, the flying dot's panel.
// Needs Screen Recording for the terminal it runs from (to read the window's pixels). Shows one small window of its
// own for a few seconds; never sends a keystroke and never brings an app to the front.
//
//   app/tests/e2e/redesign.sh            (builds this with its sources and runs it)
//
// Each check prints PASS or FAIL; the exit status is the number of failures.

import AppKit
import ImageIO
import SwiftUI

final class Typing: ObservableObject {
    @Published var text = ""
    @Published var understood = false
    @Published var unsure = false
    @Published var dotAway = false
    var frame: CGRect = .zero
}

struct Host: View {
    @ObservedObject var m: Typing
    var body: some View {
        ListeningXiaoFang(text: m.text, understood: m.understood, unsure: m.unsure, dotAway: m.dotAway,
                          onFrame: { m.frame = $0 })
            .padding(.leading, 120).padding(.top, 90)
            .frame(width: 360, height: 240, alignment: .topLeading)
            .background(Color.white)
    }
}

@main
enum RedesignE2E {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var out = URL(fileURLWithPath: "/tmp")

    static func main() {
        guard CommandLine.arguments.count >= 2 else { print("usage: RedesignE2E <out dir>"); exit(2) }
        out = URL(fileURLWithPath: CommandLine.arguments[1])
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Thread.detachNewThread {
            gif()
            xiaofang()
            print(failures == 0 ? "RedesignE2E: all passed" : "RedesignE2E: \(failures) failed")
            exit(Int32(min(failures, 100)))
        }
        app.run()
    }

    static func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL") \(what)")
        if !ok { failures += 1 }
    }

    static func onMain<T>(_ f: @escaping () -> T) -> T {
        var r: T?
        DispatchQueue.main.sync { r = f() }
        return r!
    }

    // MARK: the GIF

    /// A screenshot-like PNG: a window-sized picture with a coloured band and its number.
    static func frame(_ i: Int, in dir: URL) -> String {
        let size = NSSize(width: 1280, height: 800)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        NSColor(calibratedHue: CGFloat(i) / 20, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
        NSRect(x: 0, y: 600, width: 1280, height: 200).fill()
        ("Step \(i)" as NSString).draw(at: NSPoint(x: 60, y: 300), withAttributes: [.font: NSFont.systemFont(ofSize: 96)])
        img.unlockFocus()
        let path = dir.appendingPathComponent("frame-\(i).png").path
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        return path
    }

    static func gifFrames(_ url: URL) -> (count: Int, width: Int, delays: [Double]) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return (0, 0, []) }
        let n = CGImageSourceGetCount(src)
        var delays: [Double] = []
        for i in 0..<n {
            let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let g = p?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            delays.append((g?[kCGImagePropertyGIFDelayTime] as? Double) ?? -1)
        }
        let w = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int ?? 0
        return (n, w, delays)
    }

    static func gif() {
        let frames = out.appendingPathComponent("frames"), dir = out.appendingPathComponent("gif")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let all = (1...18).map { ReplayFrame(n: $0, image: frame($0, in: frames), words: "Click “Play” on row \($0)") }
        let title = "Open Music / play: the live version"

        // 1. Three exports of the same run within the minute: three files, none over another.
        let urls = (0..<3).compactMap { _ in ReplayGIF.exportGIF(title: title, frames: all, lang: .en, dir: dir) }   // off the main thread, as the app does
        check(urls.count == 3, "three exports made: \(urls.count)")
        check(Set(urls.map(\.path)).count == 3, "three different files")
        // (The exact " 2", " 3" are checked in DecisionTests with a fixed stamp: here the minute may turn.)
        let names = urls.map(\.lastPathComponent)
        check(names.allSatisfy { !$0.contains("/") && !$0.contains(":") && $0.hasSuffix(".gif") && $0.contains("Open Music play") },
              "names: \(names)")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        check(files.filter { $0.hasSuffix(".gif") }.count == 3, "all three are on disk")

        // 2. Each is the run: a cover and the last 16 steps, 720 px wide, timed, under 5 MB.
        for u in urls {
            let g = gifFrames(u)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
            check(g.count == 17 && g.width == 720, "\(u.lastPathComponent): \(g.count) frames, \(g.width) px")
            check(g.delays.first == 1.6 && g.delays.last == 2.6 && g.delays.dropFirst().dropLast().allSatisfy { $0 == 1.3 },
                  "cover 1.6 s, steps 1.3 s, last 2.6 s")
            check(bytes > 0 && bytes <= 5_000_000, "under 5 MB: \(bytes) bytes")
        }

        // 2b. Three exports at once, from three threads (two result windows): three files, each whole.
        let group = DispatchGroup(), lock = NSLock()
        var together: [URL] = []
        for _ in 0..<3 {
            group.enter()
            DispatchQueue.global().async {
                if let u = ReplayGIF.exportGIF(title: "at once", frames: Array(all.prefix(4)), lang: .en, dir: dir) {
                    lock.lock(); together.append(u); lock.unlock()
                }
                group.leave()
            }
        }
        group.wait()
        check(Set(together.map(\.path)).count == 3, "three exports at once: three files (\(together.map(\.lastPathComponent)))")
        check(together.allSatisfy { gifFrames($0).count == 5 }, "each one whole: cover + 4")

        // 3. A step whose screenshot is gone is left out; no step with a screenshot: no GIF.
        var some = Array(all.prefix(3))
        some.append(ReplayFrame(n: 4, image: frames.appendingPathComponent("gone.png").path, words: "gone"))
        let partial = ReplayGIF.exportGIF(title: "partial", frames: some, lang: .en, dir: dir)
        check(partial.map { gifFrames($0).count } == 4, "a missing last screenshot is skipped: cover + 3")
        check(partial.map { gifFrames($0).delays.last } == 2.6, "and the last step that has one gets the long pause")
        var gap = Array(all.prefix(3))
        gap.insert(ReplayFrame(n: 99, image: frames.appendingPathComponent("gone.png").path, words: "gone"), at: 1)
        let middle = ReplayGIF.exportGIF(title: "gap", frames: gap, lang: .en, dir: dir)
        check(middle.map { gifFrames($0).count } == 4 && middle.map { gifFrames($0).delays } == [1.6, 1.3, 1.3, 2.6],
              "a missing screenshot mid-way: cover + 3, timed")
        let late = Array(all.suffix(17)) + [ReplayFrame(n: 40, image: frames.appendingPathComponent("gone.png").path, words: "gone")]
        check(ReplayGIF.exportGIF(title: "late", frames: late, lang: .en, dir: dir).map { gifFrames($0).count } == 17,
              "the last 16 steps that have screenshots (a gone one does not take a place)")
        check(ReplayGIF.exportGIF(title: "none", frames: [], lang: .en, dir: dir) == nil, "no frames: no GIF")
    }

    // MARK: 小方

    static func capture(_ window: NSWindow) -> NSBitmapImageRep? {
        let path = out.appendingPathComponent("xiaofang-\(Int(Date().timeIntervalSince1970 * 1000)).png").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(onMain { window.windowNumber })", path]
        try? p.run(); p.waitUntilExit()
        return FileManager.default.contents(atPath: path).flatMap { NSBitmapImageRep(data: $0) }
    }

    /// Whether the pixel at `p` (window points, top-left) is the brand's orange.
    static func orange(_ img: NSBitmapImageRep, at p: CGPoint, windowWidth: CGFloat) -> Bool {
        let k = CGFloat(img.pixelsWide) / windowWidth
        guard let c = img.colorAt(x: Int(p.x * k), y: Int(p.y * k))?.usingColorSpace(.sRGB) else { return false }
        return abs(c.redComponent - 0xC9 / 255.0) < 0.12 && abs(c.greenComponent - 0x55 / 255.0) < 0.12
            && abs(c.blueComponent - 0x36 / 255.0) < 0.12
    }

    static func settle(_ m: Typing, _ seconds: Double = 1.0) -> CGRect {
        Thread.sleep(forTimeInterval: seconds)
        return onMain { m.frame }
    }

    static func xiaofang() {
        let m = onMain { Typing() }
        let window = onMain { () -> NSWindow in
            let w = NSWindow(contentRect: NSRect(x: 220, y: 260, width: 360, height: 240),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
            w.contentView = NSHostingView(rootView: Host(m: m))
            w.orderFrontRegardless()
            return w
        }
        defer { onMain { window.orderOut(nil) } }

        // 4. How far it rises, measured where it is drawn (inside its rise): standing is the baseline.
        onMain { m.understood = true; m.text = "Open Music and play it" }
        let standing = settle(m, 1.2)
        check(standing.width == XiaoFangMotion.size.width, "measured at its drawn size: \(standing.size)")
        onMain { m.understood = false; m.text = "" }
        check(abs(settle(m).minY - standing.minY - 46) < 0.5, "empty box: sunk 46 pt, only its head shows")
        onMain { m.text = "Open" }
        let typing = settle(m)
        check(abs(typing.minY - standing.minY - 18) < 0.5, "typing: head up on the edge (18 pt): \(typing.minY - standing.minY)")
        onMain { m.understood = true }
        check(abs(settle(m).minY - standing.minY) < 0.5, "an app recognised: stands up")
        onMain { m.understood = false; m.text = "Open Mu" }
        _ = settle(m, 0.3)
        let dozed = settle(m, XiaoFangMotion.dozeAfter + 0.6)
        check(abs(dozed.minY - standing.minY - 46) < 0.5, "8 s without a key: sinks back")

        // 5. The dot: drawn where XiaoFangMotion says, at any rise; the take-off point on screen matches the window.
        onMain { m.understood = true; m.text = "Open Music and play it" }
        let f = settle(m, 1.2)
        let width = onMain { window.frame.width }
        if let img = capture(window) {
            let d = XiaoFangMotion.dot(in: f)
            check(orange(img, at: d, windowWidth: width), "the dot is drawn at \(d) (window points)")
            check(!orange(img, at: CGPoint(x: d.x - 30, y: d.y), windowWidth: width), "and not beside it")
        } else { check(false, "the window can be captured (Screen Recording for this terminal)") }
        onMain { m.understood = false }
        let low = settle(m)
        if let img = capture(window) {
            check(orange(img, at: XiaoFangMotion.dot(in: low), windowWidth: width), "typing (risen 18 pt): the dot is still where it says")
        }
        let (screen, expected) = onMain { () -> (CGPoint, CGPoint) in
            let d = XiaoFangMotion.dot(in: low)
            let h = window.contentView?.bounds.height ?? 0
            let s = window.convertPoint(toScreen: XiaoFangMotion.windowBase(d, contentHeight: h))
            return (s, CGPoint(x: window.frame.minX + d.x, y: window.frame.maxY - d.y))
        }
        check(abs(screen.x - expected.x) < 0.5 && abs(screen.y - expected.y) < 0.5,
              "take-off point on screen \(screen) = window origin + dot (\(expected))")
        onMain { m.dotAway = true }
        if let img = capture(window) {
            check(!orange(img, at: XiaoFangMotion.dot(in: settle(m, 0.3)), windowWidth: width), "dot away: not drawn at its foot")
        }
        onMain { m.dotAway = false }

        // 6. The flying dot: a click-through panel over everything for about half a second, then gone.
        let reduce = onMain { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        let level = Int(NSWindow.Level.statusBar.rawValue) + 2
        func flights() -> Int {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            return list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int) == level }.count
        }
        onMain { MainActor.assumeIsolated { DotFlight.launch(from: screen) } }
        Thread.sleep(forTimeInterval: 0.15)
        if reduce {
            check(flights() == 0, "Reduce Motion: no flight")
        } else {
            check(flights() == 1, "the dot flies, in a panel over everything")
        }
        Thread.sleep(forTimeInterval: 0.8)
        check(flights() == 0, "the panel is gone after the flight")
    }
}
