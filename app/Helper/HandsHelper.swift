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

/// Exit and come back: the same copy is started again a moment after this process has gone, whether or not the app is
/// open (the LaunchAgent with KeepAlive that used to do this is no longer registered).
func restartSelf() {
    HelperInstaller.launch(Bundle.main.bundlePath, after: 1.0)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exit(0) }
}

/// Set once a restart for a Screen Recording grant is scheduled (see status).
nonisolated(unsafe) var restartingForGrant = false

/// The permission reads, kept for a few seconds: the app asks for status every second, and each read is a request to
/// TCC (accessibility, screen recording, Automation of Finder) -- one log line a second for as long as the app was
/// open (rc.9, 10-20). A probe (a grant panel open, Screen Recording not yet seen) always reads afresh, so a switch
/// the user just turned on still shows within a second; otherwise a change shows within `PermissionCache.ttl`.
enum PermissionCache {
    static let ttl: TimeInterval = 10
    private static var at = Date.distantPast
    private static var value: (ax: Bool, screen: Bool, automation: Bool?) = (false, false, nil)
    private static let lock = NSLock()

    static func read(fresh: Bool) -> (ax: Bool, screen: Bool, automation: Bool?) {
        lock.lock(); defer { lock.unlock() }
        if fresh || Date().timeIntervalSince(at) > ttl || !(value.ax && value.screen) {
            value = (axTrusted(prompt: false), CGPreflightScreenCaptureAccess(), automationGranted())
            at = Date()
        }
        return value
    }
}

func status(probe: Bool) -> [String: Any] {
    let perms = PermissionCache.read(fresh: probe)
    let live = perms.screen
    let probed = !live && probe && probeScreen()
    // Granted, but this process will not see it until it restarts: restart now, between tasks, rather than leave the
    // setup saying "not granted" (the app starts the installed copy again within seconds).
    // a task running, or a finished one whose undo can still be asked for (its process would go with this one)
    let busy = Runner.current != nil || SessionHost.taskRunning || HarnessRun.undoWaiting || ComputerLock.acting
    if HelperLocation.restartForGrant(live: live, probe: probed, taskRunning: busy, alreadyScheduled: restartingForGrant) {
        restartingForGrant = true
        restartSelf()
    }
    var s: [String: Any] = [
        "ok": true,
        "pid": Int(ProcessInfo.processInfo.processIdentifier),
        "bundle": Bundle.main.bundleIdentifier ?? "?",
        "path": Bundle.main.bundlePath,
        "uptime_s": Int(Date().timeIntervalSince(started)),
        "accessibility": perms.ax,
        "screen_recording": live,
        "screen_recording_granted": live || probed,
        "brain": BrainServer.status()["state"] ?? "stopped",
        "brain_uptime_s": BrainServer.status()["uptime_s"] ?? 0,
        "brain_hint": BrainServer.status()["hint"] ?? "",
        "brain_action": BrainServer.status()["action"] ?? "",
        "eyes": EyesServer.status()["state"] ?? "stopped",
    ]
    if let a = perms.automation { s["automation"] = a }
    s["models_off"] = SessionHost.modelsOffNow      // (the app asserts its switch when this is not it)
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
        // Not while another task acts on this Mac: the run it is for would be refused (computer_busy), and nothing of a
        // refused request may start on the desktop.
        if ComputerLock.acting { return ["ok": false, "code": "computer_busy", "error": "another task is using this Mac"] }
        return ScreenRecorder.start(req)
    case "record_stop":
        return ScreenRecorder.stop()
    case "takeover":
        // The user lets the task use the mouse and the front for a while (0 ends it early).
        Runner.takeOver(seconds: req["seconds"] as? Double ?? 0)
        return ["ok": true]
    case "clear_runs":
        // "Clear all" in Recent: the list, and with it what the runs left on disk.
        // refused while a task runs, or while the last one's process would not end: the app keeps its list then
        guard let n = Runner.clearRunData() else {
            return ["ok": false, "error": Runner.busy ? "a task is running" : "the last task's process has not ended"]
        }
        return ["ok": true, "removed": n]
    case "save_log":
        // "Save Full Log…" after a failed run: the run's folder and the model servers' logs, zipped where the user chose.
        return Runner.saveLog(to: req["path"] as? String ?? "", details: req["details"] as? String ?? "",
                              diagnostics: req["diagnostics"] as? String ?? "")
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
    case "eyes":
        // hands' executor, the first time a window has to be read from its pixels (deskmind_hands.grounding
        // .ensure_grounder): start the vision model if it is downloaded; with `wait` > 0, wait for it that long. The
        // executor asks with wait 0 and waits itself, in slices it can stop (hands #54 review).
        guard DeskMindModels.eyesDir() != nil else {
            return ["ok": false, "starting": false, "ready": false, "error": "the vision model is not downloaded"]
        }
        EyesServer.ensure()
        let wait = min(req["wait"] as? Double ?? 0, 90)
        let ready = wait > 0 ? EyesServer.waitReady(timeout: wait) : EyesServer.status()["state"] as? String == "ready"
        EyesServer.touch()
        return ["ok": true, "starting": true, "ready": ready]
    case "brain_status":
        if req["start"] as? Bool == true { BrainServer.ensure() }
        return ["ok": true].merging(BrainServer.status()) { a, _ in a }
    case "model_check":
        // The settings sheet's "Test": one tiny question to a cloud model. `env` carries what is typed in the sheet
        // (key, URL, model) for this check only — nothing is written until the user saves.
        return HarnessRun.modelCheck(config: req["config"] as? String ?? "ds-flash", extra: req["env"] as? [String: String] ?? [:])
    case "answer":
        // The user's reply to the question the running task asked (a HANDS_ASK line), or their approval.
        // {ask_id, reply, approve, option?}: `option` is the clicked option button's place among the options shown;
        // `ask_id` the card the window showed (a harness run refuses an answer to a card that is no longer open).
        if HarnessRun.input != nil { return HarnessRun.answer(req) }
        return ["ok": Runner.answer(req)] as [String: Any]
    case "respond":
        // The answer to a finished harness run's result card (e.g. undo), while its process lingers:
        // {run_id, option, wait?} → {ok, run_id, result?} (result: the harness's result_response, if it came in `wait` s).
        guard let option = req["option"] as? Int else { return ["ok": false, "error": "respond needs an option"] }
        return HarnessRun.respond(runID: req["run_id"] as? String ?? "", option: option, wait: (req["wait"] as? NSNumber)?.doubleValue ?? 0)
    case "stop":
        let running = Runner.current != nil
        Runner.requestStop()
        return ["ok": true, "stopped": running]
    case "restart":
        // Our successor is started before we go (HelperInstaller.launch); the main app, if open, just reconnects.
        restartSelf()
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
            if let lang = ResolvedLang.fromRequest(req["lang"] as? String) { ResolvedLang.current = lang }
            // The live view's pictures, while the main app watches a run (live.watch): LiveWatch.
            if LiveWatch.serve(req, fd: c) { return }
            // Chat sessions (session.open / send / end, sessions.list / watch): SessionHost.
            if SessionHost.serve(req, fd: c) { return }
            if req["op"] as? String == "run" {
                // cloud models off (the helper's bit): a run with the cloud engine is refused before anything starts
                if let refusal = SessionHost.refusesRun(req) {
                    var line = (try? JSONSerialization.data(withJSONObject: refusal)) ?? Data()
                    line.append(0x0A)
                    _ = line.withUnsafeBytes { write(c, $0.baseAddress, line.count) }
                    return
                }
                // A run streams: one line per event until it ends, on this connection.
                // taken (busy, the last stop flags cleared) in one step with the check: a stop from now on is this run's
                guard Runner.accept() else {
                    var busy = (try? JSONSerialization.data(withJSONObject: ["event": "error", "error": "a run is already in progress"])) ?? Data()
                    busy.append(0x0A)
                    _ = busy.withUnsafeBytes { write(c, $0.baseAddress, busy.count) }
                    return
                }
                // One computer task at a time on this Mac, whoever starts it: the run takes the machine lock as it
                // starts (ComputerLock.acquire, in HarnessRun.run / Runner.run) and is refused there.
                var spec = Runner.Spec(req)
                spec.runID = "run_" + UUID().uuidString.lowercased().prefix(8)
                let run = spec.engine == "harness" && spec.goal != nil ? HarnessRun.run : Runner.run
                run(spec) { event in
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
        // cloud models turned off (models.off): a harness op run going stops by its normal stop path
        SessionHost.onModelsOff = { HarnessRun.stopForModelsOff() }
        // The live view's pictures (live.watch): ScreenCaptureKit, one picture at a time.
        LiveWatch.source = ScreenLiveSource()
        // The helper's own UI event log (Shared/UIEvents.swift), next to the main app's.
        UIEvents.log = UIEventLog(dir: DeskMindIPC.supportDir, file: UIEventLog.helperFile)
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
        // Started from inside DeskMind.app (by bundle id, e.g. macOS's "Quit & Reopen" after Screen Recording is turned
        // on): that copy's permissions count as DeskMind's, so the installed copy is started instead (HelperLocation).
        let installed = HelperLocation.installedPath(supportDir: DeskMindIPC.supportDir.path)
        if let target = HelperLocation.handOverTarget(bundlePath: Bundle.main.bundlePath, installedPath: installed) {
            // The installed copy as this DeskMind.app shipped it (HelperInstaller): an older one still running is let go
            // when it is replaced, and the installed copy is started unless it is already running.
            if (try? HelperInstaller.ensureInstalled(shipped: Bundle.main.bundlePath, installed: target)) == true {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: "ai.deskmind.hands")
                where app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    app.terminate()
                }
            }
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: "ai.deskmind.hands").contains {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
                    && ($0.bundleURL?.standardizedFileURL.path ?? "") == URL(fileURLWithPath: target).standardizedFileURL.path
            }
            if !running { HelperInstaller.launch(target, after: 0.5) }
            exit(0)
        }
        // One helper at a time (HelperLock): wait for one that is going, leave one that stays.
        try? FileManager.default.createDirectory(at: DeskMindIPC.supportDir, withIntermediateDirectories: true)
        guard HelperLock.acquire(DeskMindIPC.supportDir.appendingPathComponent(HelperLock.fileName).path, wait: 15) != nil
        else { exit(0) }
        signal(SIGPIPE, SIG_IGN)   // a client that goes away mid-stream must not take the helper with it
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar
        Thread.detachNewThread { serve() }
        Runner.warmUp()
        BrainServer.ensure()
        atexit { BrainServer.stop(); EyesServer.stop() }
        // A replaced or terminated helper must take its model servers with it: left running, the next helper would
        // adopt a server still loaded with the old models. exit runs the atexit above (Lifecycle).
        Lifecycle.exitOnSIGTERM()
        app.run()
    }
}
