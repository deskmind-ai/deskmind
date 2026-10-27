// The main window as a real window (U4 §3; tests/e2e/real_window.sh builds the app under its own bundle id and runs
// this). Two launches of that build, each in the background (open -g): fresh -- its defaults empty but the first run
// done -- then from a saved frame of 900 × 500 written into every window frame key the first launch saved. Each time:
// the window's frame (CGWindowList) is at least the three columns' 1098 × 600 and on its screen; the columns' places by
// their accessibility ids -- 「新对话」 in the 256 sidebar, 小方's state line and 这台 Mac in the right column (400, or
// down to 300 at the least width), inside the window; and its picture (screencapture -l: real pixels, the window as it
// is, not brought forward). Nothing is activated and no other app is touched; the app is quit at the end.
//
//   RealWindowE2E <app> <bundle id> <out dir> <support dir>

import AppKit
import ApplicationServices

let args = CommandLine.arguments
guard args.count == 5 else { print("usage: RealWindowE2E <app> <bundle id> <out dir> <support dir>"); exit(2) }
let app = args[1], bundleId = args[2], out = URL(fileURLWithPath: args[3]), support = args[4]
let least = CGSize(width: 1098, height: 600)
var failures = 0

func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok   " : "FAIL ") + what)
    if !ok { failures += 1 }
}

func wait(_ seconds: Double, until: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if until() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    return until()
}

func running() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first { !$0.isTerminated }
}

/// The app's main window: its id and its frame (global, top-left origin), the largest of its normal windows on screen.
func mainWindow(pid: pid_t) -> (id: CGWindowID, frame: CGRect)? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w -> (CGWindowID, CGRect)? in
        guard w[kCGWindowOwnerPID as String] as? pid_t == pid, w[kCGWindowLayer as String] as? Int == 0,
              let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
              let id = w[kCGWindowNumber as String] as? CGWindowID else { return nil }
        return (id, r)
    }.max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
}

/// The screen the window is on, in the same coordinates (global, top-left origin; the visible part).
func visibleScreen(of r: CGRect) -> CGRect? {
    guard let primary = NSScreen.screens.first else { return nil }
    let screens = NSScreen.screens.map { s -> CGRect in
        let v = s.visibleFrame
        return CGRect(x: v.minX, y: primary.frame.maxY - v.maxY, width: v.width, height: v.height)
    }
    return screens.max { $0.intersection(r).width * $0.intersection(r).height < $1.intersection(r).width * $1.intersection(r).height }
}

/// An element of the app by its accessibility id: its frame (global, top-left origin).
func element(_ pid: pid_t, _ identifier: String) -> CGRect? {
    func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point); AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
    var queue: [(AXUIElement, Int)] = [(AXUIElementCreateApplication(pid), 0)]
    while !queue.isEmpty {
        let (e, depth) = queue.removeFirst()
        if attr(e, "AXIdentifier") as? String == identifier { return frame(e) }
        guard depth < 40, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { continue }
        queue += kids.map { ($0, depth + 1) }
    }
    return nil
}

func near(_ a: CGFloat, _ b: CGFloat, _ by: CGFloat = 2) -> Bool { abs(a - b) <= by }

/// One launch: started in the background, its window found and checked, its picture taken, quit.
func launch(_ name: String) {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    // -g: in the background, nothing brought forward; -n: this build, its own process
    open.arguments = ["-g", "-n", "--env", "DESKMIND_E2E_WINDOW_ONLY_SUPPORT=\(support)", app]
    try! open.run(); open.waitUntilExit()
    guard wait(15, until: { running() != nil }), let proc = running() else { check(false, "\(name): the app started"); return }
    let pid = proc.processIdentifier
    guard wait(15, until: { mainWindow(pid: pid) != nil }) else { check(false, "\(name): its window is on screen"); quit(); return }
    RunLoop.current.run(until: Date().addingTimeInterval(3))       // (its frame fitted, its first layout settled)
    guard let (wid, f) = mainWindow(pid: pid) else { check(false, "\(name): its window is on screen"); quit(); return }
    print("\(name): window \(wid) at \(f)")
    check(f.width >= least.width && f.height >= least.height, "\(name): the window is at least 1098 × 600: \(f.size)")
    if let screen = visibleScreen(of: f) {
        check(screen.insetBy(dx: -1, dy: -1).contains(f), "\(name): the window is on its screen \(screen): \(f)")
    }
    check(!proc.isActive, "\(name): it did not take the front")
    if AXIsProcessTrusted() {
        let new = element(pid, "sidebar.new"), state = element(pid, "panel.state"), mac = element(pid, "panel.mac")
        print("\(name): 新对话 \(String(describing: new)), 小方 \(String(describing: state)), 这台 Mac \(String(describing: mac))")
        if let n = new {
            check(near(n.minX, f.minX + 12) && near(n.maxX, f.minX + 256 - 12), "\(name): 「新对话」 in the 256 sidebar (12 in from each side): \(n)")
        } else { check(false, "\(name): 「新对话」 found by its id") }
        // (the right column: the window's last 400, giving way down to 300 so the chat keeps 540 -- ColumnWidths; its
        // blocks 18 in from each side)
        let width = min(400, max(300, f.width - 256 - 2 - 540))
        let column = CGRect(x: f.maxX - width, y: f.minY, width: width, height: f.height)
        for (what, r) in [("小方's state line", state), ("这台 Mac", mac)] {
            if let r {
                check(column.insetBy(dx: -1, dy: -1).contains(r) && f.contains(r), "\(name): \(what) inside the right column, inside the window: \(r)")
            } else { check(false, "\(name): \(what) found by its id") }
        }
        if let m = mac { check(near(m.minX, column.minX + 18) && near(m.maxX, f.maxX - 18), "\(name): 这台 Mac spans the \(Int(width)) column (18 in): \(m)") }
    } else {
        check(false, "\(name): the columns' places need this process to have Accessibility permission")
    }
    let shot = Process()
    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    shot.arguments = ["-x", "-o", "-l", String(wid), out.appendingPathComponent("real-\(name).png").path]
    try? shot.run(); shot.waitUntilExit()
    check(shot.terminationStatus == 0 && FileManager.default.fileExists(atPath: out.appendingPathComponent("real-\(name).png").path),
          "\(name): its picture taken (real-\(name).png)")
    quit()
}

func quit() {
    guard let p = running() else { return }
    p.terminate()
    if !wait(10, until: { running() == nil }) { p.forceTerminate(); _ = wait(5, until: { running() == nil }) }
}

/// `defaults` on the check's own domain (the build's bundle id; never ai.deskmind.app): what it prints.
@discardableResult func defaults(_ a: [String]) -> Data {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    p.arguments = a; p.standardOutput = pipe
    try! p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return data
}

// 1. fresh: the first run done (its own defaults), nothing else
defaults(["write", bundleId, "firstRun.done", "-bool", "true"])
launch("fresh")

// 2. from a saved frame of 900 × 500: every window frame key the first launch saved (whichever the next one restores)
let exported = (try? PropertyListSerialization.propertyList(from: defaults(["export", bundleId, "-"]), format: nil)) as? [String: Any] ?? [:]
let keys = exported.keys.filter { $0.hasPrefix("NSWindow Frame") }
print("saved frame keys: \(keys)")
check(!keys.isEmpty, "the first launch saved its window's frame")
if let main = NSScreen.screens.first {
    let s = main.visibleFrame
    let small = "100 300 900 500 \(Int(s.minX)) \(Int(s.minY)) \(Int(s.width)) \(Int(s.height)) "
    for k in keys { defaults(["write", bundleId, k, small]) }
    // (read back: the next launch restores this)
    let back = (try? PropertyListSerialization.propertyList(from: defaults(["export", bundleId, "-"]), format: nil)) as? [String: Any] ?? [:]
    check(keys.allSatisfy { back[$0] as? String == small }, "the saved frames are 900 × 500 now")
}
launch("from-900x500")

print(failures == 0 ? "RealWindowE2E: all passed" : "RealWindowE2E: \(failures) failed")
exit(failures == 0 ? 0 : 1)
