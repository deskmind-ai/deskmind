// End-to-end test of the live view (Helper/LiveCard.swift) on a real desktop: a TextEdit document is the window a
// "run" works in, and the card is driven the way Runner drives it (observations, steps, statuses, the end). Needs
// Screen Recording and Automation for TextEdit (granted to the terminal it runs from), and a TextEdit window it may
// move -- tests/e2e/live_view.sh opens one in a scratch folder and closes it after. It never sends a keystroke and
// never brings an app to the front.
//
//   app/tests/e2e/live_view.sh            (builds this with the card's sources and runs it)
//
// Each scenario prints PASS or FAIL; the exit status is the number of failures. Pictures of the card are written to
// the output folder for a person to look at.

import AppKit
import ScreenCaptureKit

@main
enum LiveViewE2E {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var out = URL(fileURLWithPath: "/tmp")
    nonisolated(unsafe) static var doc = ""

    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("usage: LiveViewE2E <doc name> <out dir>"); exit(2) }
        doc = args[1]; out = URL(fileURLWithPath: args[2])
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Thread.detachNewThread {
            run()
            print(failures == 0 ? "LiveViewE2E: all passed" : "LiveViewE2E: \(failures) failed")
            exit(Int32(min(failures, 100)))
        }
        app.run()
    }

    // MARK: helpers

    static func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL") \(what)")
        if !ok { failures += 1 }
    }

    static func onMain<T>(_ f: @escaping () -> T) -> T {
        var r: T?
        DispatchQueue.main.sync { r = f() }
        return r!
    }

    static func snap() -> [String: Any] { onMain { LiveCard.snapshot() } }

    @discardableResult
    static func waitFor(_ timeout: Double = 4, _ ok: ([String: Any]) -> Bool) -> [String: Any] {
        let until = Date().addingTimeInterval(timeout)
        var s = snap()
        while !ok(s) && Date() < until { Thread.sleep(forTimeInterval: 0.1); s = snap() }
        return s
    }

    static func rect(_ s: [String: Any], _ key: String) -> NSRect { NSRectFromString(s[key] as? String ?? "") }

    @discardableResult
    static func osa(_ script: String) -> String {
        var err: NSDictionary?
        let r = NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err { print("  applescript: \(err[NSAppleScript.errorMessage] ?? err)") }
        return r?.stringValue ?? ""
    }

    /// The test document's TextEdit window: (CGWindowID, frame in top-left global points).
    static func docWindow() -> (Int, CGRect)? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowName as String] as? String ?? "").contains(doc) {
            guard let id = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            return (id, CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0))
        }
        return nil
    }

    /// Move the document's window (top-left global points), through TextEdit's scripting.
    static func setBounds(_ r: CGRect) {
        osa("tell application \"TextEdit\" to set bounds of (first window whose name contains \"\(doc)\") to {\(Int(r.minX)), \(Int(r.minY)), \(Int(r.maxX)), \(Int(r.maxY))}")
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// A window's pixels, as hands takes them (`screencapture -l`, a window capture).
    static func capture(window id: Int, name: String) -> NSBitmapImageRep? {
        let path = out.appendingPathComponent("\(name).png").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(id)", path]
        try? p.run(); p.waitUntilExit()
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return NSBitmapImageRep(data: data)
    }

    /// The share of pixels in `r` (the image's own pixel coordinates, top-left) that `match`.
    static func share(_ img: NSBitmapImageRep, in r: CGRect, _ match: (Int, Int, Int) -> Bool) -> Double {
        var hit = 0, all = 0
        let x0 = max(0, Int(r.minX)), x1 = min(img.pixelsWide, Int(r.maxX))
        let y0 = max(0, Int(r.minY)), y1 = min(img.pixelsHigh, Int(r.maxY))
        guard x1 > x0, y1 > y0 else { return 0 }
        for y in stride(from: y0, to: y1, by: 2) {
            for x in stride(from: x0, to: x1, by: 2) {
                guard let c = img.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                all += 1
                if match(Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)) { hit += 1 }
            }
        }
        return all == 0 ? 0 : Double(hit) / Double(all)
    }

    /// The card's picture area in a capture of the card window (pixels, top-left).
    static func pictureArea(_ s: [String: Any], _ img: NSBitmapImageRep) -> CGRect {
        let frame = rect(s, "frame"), pic = rect(s, "picture")
        let k = CGFloat(img.pixelsWide) / max(frame.width, 1)
        return CGRect(x: pic.minX * k, y: (frame.height - pic.maxY) * k, width: pic.width * k, height: pic.height * k)
    }

    static func cardWindows() -> Int {
        let me = ProcessInfo.processInfo.processIdentifier
        return (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == me && ($0[kCGWindowName as String] as? String) != "e2e-cover"
                && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0
        }.count
    }

    static func cpu() -> Double {
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "%cpu=,rss=", "-p", "\(ProcessInfo.processInfo.processIdentifier)"]
        p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let f = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ")
        return Double(f.first ?? "0") ?? 0
    }

    // MARK: the scenarios

    static func run() {
        guard let (wid, start) = docWindow() else { check(false, "the test document's TextEdit window is on screen"); return }
        let screen = onMain { NSScreen.screens[0].frame }   // the main display: top-left global = its own
        // The card's remembered corner and size start from the defaults (this test's own defaults domain).
        UserDefaults.standard.removeObject(forKey: "liveView.corner"); UserDefaults.standard.removeObject(forKey: "liveView.large")
        let home = CGRect(x: 160, y: 120, width: 640, height: 420)
        setBounds(home)
        var stopped = false
        let goal = "Add Lisa Wong's order to the ledger and save it"
        onMain { LiveCard.start(bundles: ["com.apple.TextEdit"], goal: goal, onStop: { stopped = true }) }
        LiveCard.observed(windows: [["id": "\(wid)", "active": true]], app: "TextEdit")

        // 1. It appears, in its corner, with the window's picture.
        var s = waitFor(6) { ($0["visible"] as? Bool) == true && ($0["note"] as? String ?? "x").isEmpty && ($0["streaming"] as? Bool) == true }
        check(s["visible"] as? Bool == true, "the card appears")
        check((s["note"] as? String ?? "x").isEmpty, "with a picture (no placeholder note)")
        check(s["streaming"] as? Bool == true, "the capture runs")
        let vis = rect(s, "screen_visible"), f1 = rect(s, "frame")
        check(abs(f1.maxX - (vis.maxX - LiveView.margin)) < 1 && abs(f1.minY - (vis.minY + LiveView.margin)) < 1,
              "bottom-right of the visible frame: \(f1)")
        check(s["click_through"] as? Bool == false, "takes clicks where it covers nothing of the window")
        check(s["line"] as? String == goal, "before the first step, the line is the instruction")
        let card = s["window_number"] as? Int ?? 0
        if let img = capture(window: card, name: "1-card") {
            let area = pictureArea(s, img)
            check(share(img, in: area) { r, g, b in r > 230 && g > 230 && b > 230 } > 0.5, "the picture is the white document")
            check(share(img, in: area) { r, g, b in r < 90 && g < 90 && b < 90 } > 0.001, "with its text")
        } else { check(false, "the card can be captured (it is shareable)") }

        // 2. Covered by another window: the picture is still the document.
        let cover = onMain { () -> NSWindow in
            let w = NSWindow(contentRect: LiveView.toAppKit(home.insetBy(dx: -20, dy: -20), mainHeight: screen.height),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.title = "e2e-cover"; w.backgroundColor = .systemRed; w.level = .normal; w.orderFrontRegardless(); return w
        }
        Thread.sleep(forTimeInterval: 1.5)
        s = snap()
        if let img = capture(window: card, name: "2-covered") {
            check(share(img, in: pictureArea(s, img)) { r, g, b in r > 200 && g < 80 && b < 80 } < 0.01,
                  "a window on top is not in the picture")
            check(share(img, in: pictureArea(s, img)) { r, g, b in r > 230 && g > 230 && b > 230 } > 0.5, "the covered document still shows")
        }
        onMain { cover.orderOut(nil) }

        // 3. It follows the window's shape.
        setBounds(CGRect(x: 160, y: 120, width: 400, height: 600))
        s = waitFor { rect($0, "picture").height == 240 && rect($0, "picture").width == 220 }
        check(rect(s, "picture").size == CGSize(width: 220, height: 240), "a tall window: \(rect(s, "picture").size)")
        setBounds(CGRect(x: 160, y: 120, width: 900, height: 400))
        s = waitFor { rect($0, "picture").size == CGSize(width: 360, height: 160) }
        check(rect(s, "picture").size == CGSize(width: 360, height: 160), "a wide window: \(rect(s, "picture").size)")

        // 4. Out of the window's way: a window in the bottom-right corner sends the card across.
        let vtl = CGRect(x: vis.minX, y: screen.height - vis.maxY, width: vis.width, height: vis.height)   // visible, top-left
        setBounds(CGRect(x: vtl.maxX - 700, y: vtl.maxY - 500, width: 700, height: 500))
        s = waitFor { rect($0, "frame").minX < vis.midX }
        check(rect(s, "frame").minX < vis.midX && rect(s, "frame").minY < vis.midY, "moved to bottom-left: \(rect(s, "frame"))")
        check(s["click_through"] as? Bool == false, "still takes clicks there")

        // 5. A window filling the screen (a maximized app): the card stays, with its picture, over the window and lets
        // clicks through (a run's click reaches the app); hands' window capture under it has no card.
        setBounds(vtl)
        s = waitFor { ($0["click_through"] as? Bool) == true }
        check(s["covers"] as? Bool == true && rect(s, "frame").height > 200, "over a full-screen window: still the card, \(rect(s, "frame").size)")
        check(s["click_through"] as? Bool == true, "letting clicks through (the pointer is not resting on it)")
        check(s["streaming"] as? Bool == true, "with its picture")
        Thread.sleep(forTimeInterval: 0.5)
        s = snap()
        if let (id, wf) = docWindow(), let shot = capture(window: id, name: "5-hands-capture") {
            let cf = LiveView.toAppKit(rect(s, "frame"), mainHeight: screen.height)   // the card, top-left global
            let k = CGFloat(shot.pixelsWide) / wf.width
            let under = CGRect(x: (cf.minX - wf.minX) * k, y: (cf.minY - wf.minY) * k, width: cf.width * k, height: cf.height * k)
            check(share(shot, in: under) { r, g, b in abs(r - 38) < 8 && abs(g - 43) < 8 && abs(b - 40) < 8 } < 0.02,
                  "hands' capture of the window under the card has no card in it")
        } else { check(false, "the document window can be captured") }

        // 6. Steps: the words, the number, the agent's cursor where it acted.
        setBounds(home)
        s = waitFor(6) { ($0["click_through"] as? Bool) == false && ($0["covers"] as? Bool) == false }
        check(s["covers"] as? Bool == false && s["click_through"] as? Bool == false, "room again: clickable in a clear corner")
        LiveCard.stepped(n: 3, words: "Click “Save”", target: [home.midX - 10, home.midY - 10, 20, 20], click: true)
        s = waitFor { ($0["cursor"] as? String) != nil }
        check((s["title"] as? String ?? "").contains("3"), "the step's number: \(s["title"] ?? "")")
        check(s["line"] as? String == "Click “Save”", "the step's words")
        let pic = rect(s, "picture"), cur = NSPointFromString(s["cursor"] as? String ?? "{-1,-1}")
        check(abs(cur.x - pic.width / 2) < 4 && abs(cur.y - pic.height / 2) < 4, "the cursor where it acted: \(cur) in \(pic.size)")
        check(s["face"] as? String == "look", "小方 looks at the cursor while it works")
        LiveCard.stepped(n: 4, words: "Scroll", target: [5, 5, 2, 2], click: false)
        s = waitFor { $0["cursor"] is NSNull }
        check(s["cursor"] is NSNull, "a target outside the window: no cursor")

        // 7. Needs the user; paused; back at work.
        LiveCard.status(.waitingForUser, words: "Waiting for your answer in DeskMind")
        s = waitFor { ($0["status"] as? String) == "Needs you" }
        check(s["status"] as? String == "Needs you" && s["line"] as? String == "Waiting for your answer in DeskMind", "needs you")
        check(s["face"] as? String == "up", "小方 looks up at you")
        LiveCard.status(.paused, words: "Paused while you use your Mac")
        s = waitFor { ($0["status"] as? String) == "Paused" }
        check(s["status"] as? String == "Paused", "paused")
        LiveCard.stepped(n: 5, words: "Type “hello”", target: nil, click: false)
        s = waitFor { ($0["status"] as? String) == "Working" }
        check(s["status"] as? String == "Working", "a step: working again")

        // 8. The window minimized: the last picture, dimmed, with a note; back when it is.
        osa("tell application \"TextEdit\" to set miniaturized of (first window whose name contains \"\(doc)\") to true")
        s = waitFor(6) { ($0["window_hidden"] as? Bool) == true && !($0["note"] as? String ?? "").isEmpty }
        check(s["window_hidden"] as? Bool == true && !(s["note"] as? String ?? "").isEmpty, "minimized: \(s["note"] ?? "")")
        check(s["face"] as? String == "flat", "小方's eyes – – while the window is out of sight")
        check(s["visible"] as? Bool == true, "the card stays")
        osa("tell application \"TextEdit\" to set miniaturized of (first window whose name contains \"\(doc)\") to false")
        s = waitFor(6) { ($0["window_hidden"] as? Bool) == false }
        check(s["window_hidden"] as? Bool == false && (s["note"] as? String ?? "x").isEmpty, "back from the Dock")

        // 9. Larger and back (once the window is back where it was: it grows out of the Dock).
        Thread.sleep(forTimeInterval: 1.0)
        let normal = rect(snap(), "picture").size
        onMain { LiveCard.press("larger") }
        s = waitFor { rect($0, "picture").width > normal.width }
        check(rect(s, "picture").width > normal.width && s["large"] as? Bool == true, "larger: \(rect(s, "picture").size)")
        Thread.sleep(forTimeInterval: 1.0)
        if let img = capture(window: s["window_number"] as? Int ?? 0, name: "9-large") {
            check(img.pixelsWide >= Int(rect(s, "frame").width * 2) - 2, "the larger card is drawn at full resolution")
        }
        onMain { LiveCard.press("larger") }
        s = waitFor { rect($0, "picture").size == normal }
        check(rect(s, "picture").size == normal && s["large"] as? Bool == false, "smaller again: \(rect(s, "picture").size) vs \(normal)")

        // 10. Collapsed: a capsule, no capture; a click opens it.
        onMain { LiveCard.press("collapse") }
        s = waitFor { ($0["streaming"] as? Bool) == false && rect($0, "frame").size == LiveView.pill }
        check(s["collapsed"] as? Bool == true && rect(s, "frame").size == LiveView.pill, "collapsed to the capsule: \(rect(s, "frame").size)")
        check(s["streaming"] as? Bool == false, "the capture pauses while collapsed")
        onMain { LiveCard.press("click") }
        s = waitFor { ($0["streaming"] as? Bool) == true && ($0["collapsed"] as? Bool) == false && rect($0, "frame").height > 200 }
        check(s["collapsed"] as? Bool == false && s["streaming"] as? Bool == true, "a click opens it, the capture runs again")

        // 11. Dragged and let go: the nearest corner, kept.
        onMain { LiveCard.press("drop", at: NSPoint(x: vis.minX + 100, y: vis.maxY - 100)) }
        s = waitFor { ($0["corner"] as? String) == "topLeft" }
        check(s["corner"] as? String == "topLeft" && rect(s, "frame").maxY > vis.midY && rect(s, "frame").minX < vis.midX,
              "dropped near the top-left: \(rect(s, "frame"))")
        check(UserDefaults.standard.string(forKey: "liveView.corner") == "topLeft", "the corner is kept for later runs")
        onMain { LiveCard.press("drop", at: NSPoint(x: vis.maxX - 100, y: vis.minY + 100)) }
        waitFor { ($0["corner"] as? String) == "bottomRight" }

        // 12. Stop on the card stops the run.
        onMain { LiveCard.press("stop") }
        check(stopped, "Stop on the card stops the run")

        // 13. Cost, with the picture changing four times a second.
        var samples: [Double] = []
        for i in 0..<16 {
            osa("tell application \"TextEdit\" to set text of (first document whose name contains \"\(doc)\") to \"line \(i)\\n\" & (text of (first document whose name contains \"\(doc)\"))")
            Thread.sleep(forTimeInterval: 0.25)
            if i % 2 == 1 { samples.append(cpu()) }
        }
        let avg = samples.reduce(0, +) / Double(max(samples.count, 1))
        print(String(format: "  cpu while the picture changes: %.1f %% (samples %@)", avg, samples.map { String(format: "%.1f", $0) }.joined(separator: " ")))
        check(avg < 15, "the card costs little CPU")

        // 14. The end: how it ended, the capture stopped at once, then gone.
        onMain { LiveCard.finish(.done) }
        s = snap()
        check(s["status"] as? String == "Done" && s["streaming"] as? Bool == false, "done: says so, capture stopped")
        check(waitFor { ($0["face"] as? String) == "happy" }["face"] as? String == "happy", "小方 ^ ^ when done")
        Thread.sleep(forTimeInterval: 1.0)
        check(snap()["visible"] as? Bool == true, "still there a moment later")
        Thread.sleep(forTimeInterval: 2.5)
        check(snap()["card"] as? Bool == false && cardWindows() == 0, "gone after it said so")

        // 15. A new run while the last one's card is still saying how it ended: one card, the new one.
        onMain { LiveCard.start(bundles: ["com.apple.TextEdit"], onStop: {}) }
        LiveCard.observed(windows: [["id": "\(wid)", "active": true]], app: "TextEdit")
        waitFor(6) { ($0["streaming"] as? Bool) == true }
        onMain { LiveCard.finish(.failed) }
        onMain { LiveCard.start(bundles: ["com.apple.TextEdit"], onStop: {}) }
        Thread.sleep(forTimeInterval: 1.0)
        check(cardWindows() == 1, "one card, not two: \(cardWindows())")
        s = waitFor(6) { ($0["visible"] as? Bool) == true }
        check(s["status"] as? String != "Didn't finish", "the new run's card")

        // 16. Ended with no word (the run's process went away): gone at once.
        onMain { LiveCard.finish(nil) }
        Thread.sleep(forTimeInterval: 0.8)
        check(snap()["card"] as? Bool == false && cardWindows() == 0, "finish(nil): gone at once")

        setBounds(start)
    }
}
