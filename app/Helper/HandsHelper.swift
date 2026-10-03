// DeskMind Hands: the helper that holds the dangerous permissions (Accessibility, Screen Recording, Automation).
//
// It is its own app bundle, started by launchd from the LaunchAgent that DeskMind.app registers with SMAppService,
// so TCC attributes its permissions to "DeskMind Hands" and not to the main app. Restarting it (after a permission
// is granted) does not touch the main app's window.
//
// Prototype scope: status, permission prompts, a capture test that reports only the image size, restart, and runs
// (with the answers to a run's questions).

import AppKit
import Carbon
import ApplicationServices
import ScreenCaptureKit

let started = Date()

func axTrusted(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
}

func automationStatus(prompt: Bool) -> String {
    // Ask Finder for something harmless; the first call shows the Automation prompt.
    guard prompt else { return "unknown" }
    var err: NSDictionary?
    let script = NSAppleScript(source: "tell application \"Finder\" to get name of startup disk")
    _ = script?.executeAndReturnError(&err)
    if let code = err?[NSAppleScript.errorNumber] as? Int { return code == -1743 ? "denied" : "error \(code)" }
    return "granted"
}

/// Capture the main display once and report its pixel size. The image is never written or sent anywhere.
func captureTest() -> [String: Any] {
    let sem = DispatchSemaphore(value: 0)
    var result: [String: Any] = [:]
    Task {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                result = ["ok": false, "error": "no display"]; sem.signal(); return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = display.width
            cfg.height = display.height
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            result = ["ok": true, "width": image.width, "height": image.height]
        } catch {
            result = ["ok": false, "error": String(describing: error)]
        }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 15)
    return result.isEmpty ? ["ok": false, "error": "timeout"] : result
}

/// Screen Recording as a new process would see it. This process only sees the grant after a restart, so a
/// short-lived child of ours -- same bundle, same TCC identity -- is asked instead.
func probeScreen() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.arguments = ["--probe-screen"]
    let out = Pipe()
    p.standardOutput = out
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.hasPrefix("1") == true
}

/// Automation for Finder, checked without a prompt: true granted, false denied, nil not decided yet.
func automationGranted() -> Bool? {
    var target = AEAddressDesc()
    let bundle = "com.apple.finder"
    let created = bundle.withCString { AECreateDesc(typeApplicationBundleID, $0, bundle.utf8.count, &target) }
    guard created == noErr else { return nil }
    defer { AEDisposeDesc(&target) }
    let st = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
    switch st {
    case noErr: return true
    case OSStatus(errAEEventNotPermitted): return false
    default: return nil   // -1744: would ask; procNotFound: Finder not running
    }
}

func status(probe: Bool) -> [String: Any] {
    let live = CGPreflightScreenCaptureAccess()
    var s: [String: Any] = [
        "ok": true,
        "pid": Int(ProcessInfo.processInfo.processIdentifier),
        "bundle": Bundle.main.bundleIdentifier ?? "?",
        "uptime_s": Int(Date().timeIntervalSince(started)),
        "accessibility": axTrusted(prompt: false),
        "screen_recording": live,
        "screen_recording_granted": live || (probe && probeScreen()),
        "brain": BrainServer.status()["state"] ?? "stopped",
        "brain_uptime_s": BrainServer.status()["uptime_s"] ?? 0,
        "brain_hint": BrainServer.status()["hint"] ?? "",
        "brain_action": BrainServer.status()["action"] ?? "",
        "eyes": EyesServer.status()["state"] ?? "stopped",
    ]
    if let a = automationGranted() { s["automation"] = a }
    return s
}

func handle(_ req: [String: Any]) -> [String: Any] {
    switch req["op"] as? String {
    case "status":
        return status(probe: req["probe"] as? Bool ?? false)
    case "request_permission":
        switch req["which"] as? String {
        case "accessibility":
            return ["ok": true, "accessibility": axTrusted(prompt: true)]
        case "screen":
            let granted = CGRequestScreenCaptureAccess()
            return ["ok": true, "screen_recording": granted,
                    "note": granted ? "" : L("Allow it in System Settings, then restart the helper",
                                                   lang: ResolvedLang.current)]
        case "automation":
            return ["ok": true, "automation": automationStatus(prompt: true)]
        default:
            return ["ok": false, "error": "unknown permission"]
        }
    case "prewarm":
        // A request is about to run (see Runner.prewarm): the apps it names, by bundle id.
        Runner.prewarm(bundles: req["bundles"] as? [String] ?? [])
        return ["ok": true]
    case "record_start":
        // The task's apps (or the whole screen), recorded by the helper, which holds Screen Recording: ScreenRecorder.
        return ScreenRecorder.start(req)
    case "record_stop":
        return ScreenRecorder.stop()
    case "takeover":
        // The user lets the task use the mouse and the front for a while (0 ends it early).
        Runner.takeOver(seconds: req["seconds"] as? Double ?? 0)
        return ["ok": true]
    case "clear_runs":
        // "Clear all" in Recent: the list, and with it what the runs left on disk.
        guard let n = Runner.clearRunData() else { return ["ok": false, "error": "a task is running"] }
        return ["ok": true, "removed": n]
    case "capture_test":
        return captureTest()
    case "playground":
        do {
            let dir = req["reset"] as? Bool == true ? try Runner.resetPlayground() : try Runner.ensurePlayground()
            // Folders end in "/", so a folder a run made reads as one.
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
                .sorted().map { name -> String in
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir)
                    return isDir.boolValue ? name + "/" : name
                }
            return ["ok": true, "path": dir.path, "files": names]
        } catch { return ["ok": false, "error": error.localizedDescription] }
    case "brain_status":
        if req["start"] as? Bool == true { BrainServer.ensure() }
        return ["ok": true].merging(BrainServer.status()) { a, _ in a }
    case "answer":
        // The user's reply to the question the running task asked (a HANDS_ASK line), or their approval.
        let ok = Runner.answer(reply: req["reply"] as? String ?? "", approve: req["approve"] as? Bool ?? false)
        return ["ok": ok] as [String: Any]
    case "stop":
        if Runner.busy { Runner.cancelled = true }
        Runner.stopRequested = true
        Runner.current?.terminate()
        return ["ok": true, "stopped": Runner.current != nil]
    case "restart":
        // launchd's KeepAlive starts us again; the main app just reconnects.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exit(0) }
        return ["ok": true, "restarting": true]
    default:
        return ["ok": false, "error": "unknown op"]
    }
}

func serve() {
    try? FileManager.default.createDirectory(at: DeskMindIPC.supportDir, withIntermediateDirectories: true)
    let path = DeskMindIPC.socketPath
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
    }
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
    guard bound, listen(fd, 8) == 0 else {
        NSLog("DeskMind Hands: cannot listen on \(path)")
        exit(1)
    }
    chmod(path, 0o600)  // only this user
    NSLog("DeskMind Hands: listening on \(path)")
    while true {
        let c = accept(fd, nil, nil)
        if c < 0 { continue }
        DispatchQueue.global().async {
            defer { close(c) }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(c, &buf, buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
                if buf[..<n].contains(0x0A) { break }
            }
            let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            // The main app's language, sent with every request (status polls included): steps, hints and errors
            // follow a switch within a second. English until the first request says otherwise.
            if let lang = (req["lang"] as? String).flatMap(ResolvedLang.init(rawValue:)) { ResolvedLang.current = lang }
            if req["op"] as? String == "run" {
                // A run streams: one line per event until it ends, on this connection.
                guard Runner.current == nil && !Runner.busy else {
                    var busy = (try? JSONSerialization.data(withJSONObject: ["event": "error", "error": "a run is already in progress"])) ?? Data()
                    busy.append(0x0A)
                    _ = busy.withUnsafeBytes { write(c, $0.baseAddress, busy.count) }
                    return
                }
                Runner.run(Runner.Spec(req)) { event in
                    guard var line = try? JSONSerialization.data(withJSONObject: event) else { return true }
                    line.append(0x0A)
                    return line.withUnsafeBytes { write(c, $0.baseAddress, line.count) } == line.count
                }
                return
            }
            var out = (try? JSONSerialization.data(withJSONObject: handle(req))) ?? Data("{}".utf8)
            out.append(0x0A)
            _ = out.withUnsafeBytes { write(c, $0.baseAddress, out.count) }
        }
    }
}

@main
struct HandsHelper {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--probe-ax-to"), i + 1 < CommandLine.arguments.count {
            // Diagnostic: an instance started by LaunchServices reports what TCC grants *it*.
            try? "\(AXIsProcessTrusted() ? 1 : 0) \(CGPreflightScreenCaptureAccess() ? 1 : 0)"
                .write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
            exit(0)
        }
        if CommandLine.arguments.contains("--probe-screen") {
            print(CGPreflightScreenCaptureAccess() ? "1" : "0")
            exit(0)
        }
        signal(SIGPIPE, SIG_IGN)   // a client that goes away mid-stream must not take the helper with it
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar
        Thread.detachNewThread { serve() }
        Runner.warmUp()
        BrainServer.ensure()
        atexit { BrainServer.stop(); EyesServer.stop() }
        // A replaced or terminated helper must take its model servers with it: left running, the next helper would
        // adopt a server still loaded with the old models.
        signal(SIGTERM) { _ in BrainServer.stop(); EyesServer.stop(); exit(0) }
        app.run()
    }
}
