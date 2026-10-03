// Recording a run, in the helper, with ScreenCaptureKit. The helper holds the Screen Recording permission (it reads
// the screen for every step), so nothing is asked when a recording starts -- the main app, which does not hold it,
// had to put up the system's picker before every recorded run.
//
// Only what the run works in is recorded: the task's apps, DeskMind's own island and panels, and the wallpaper.
// Every other app's windows, menu-bar extras and notifications are left out -- a recording is made to be shown, and
// what else was open on the Mac is nobody's business. An app the run opens later is added once it is there. The
// whole screen is an explicit setting.
//
// A recording is a folder: master.mov (native resolution, HEVC), delivery.mp4 (1920 wide, H.264, for sharing),
// steps.json (every step's times relative to the first frame, where it acted and what the planner weighed) and
// meta.json (models, versions, machine, what was checked and what was recorded) -- what a video is edited from, and
// the proof that it was not.
//
// Requests from the main app: record_start {path, bundles, include_main, whole_screen, goal} and record_stop. Handled
// on a connection thread, so both wait here for ScreenCaptureKit's callbacks.

import AppKit
import AVFoundation
import ScreenCaptureKit

final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    private static let lock = NSLock()
    private static var active: ScreenRecorder?
    static let mainAppBundle = "ai.deskmind.app"
    /// Draws the desktop picture and nothing else: included, so the recording is not windows on black.
    static let wallpaperBundle = "com.apple.WindowManager"

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private let folder: URL
    private let bundles: Set<String>
    private let includeMain: Bool
    private let wholeScreen: Bool
    /// record_start's "display": record that display (a virtual one a run was put on), not the one found.
    var requestedDisplay: CGDirectDisplayID?
    /// The displays recorded, in order: the one it started on, then any the task moved it to.
    private var displaysUsed: [CGDirectDisplayID] = []
    private let goal: String
    private var display: SCDisplay?
    private var included: Set<Int> = []
    private var watching = true
    private var size = (0, 0)
    private var preflight: [String: Any] = [:]
    /// The first frame, epoch seconds: every time in steps.json is counted from here.
    private var t0: Double?
    private let finished = DispatchSemaphore(value: 0)

    var master: URL { folder.appendingPathComponent("master.mov") }
    var delivery: URL { folder.appendingPathComponent("delivery.mp4") }

    private init(folder: URL, bundles: Set<String>, includeMain: Bool, wholeScreen: Bool, goal: String) {
        self.folder = folder; self.bundles = bundles; self.includeMain = includeMain
        self.wholeScreen = wholeScreen; self.goal = goal
    }

    static func start(_ req: [String: Any]) -> [String: Any] {
        // A recording nobody stopped (the app quit mid-run): finished now, its files written for the run it filmed,
        // and this one starts. Refused instead, every later run went unrecorded while that one grew for half an hour.
        lock.lock()
        let stale = active
        active = nil
        lock.unlock()
        if let stale {
            stale.end()
            let run = Runner.lastRunDir
            DispatchQueue.global(qos: .utility).async {
                guard FileManager.default.fileExists(atPath: stale.master.path) else { return }
                stale.writeSidecars(delivered: stale.exportDelivery(), run: run)
            }
        }
        lock.lock(); defer { lock.unlock() }
        guard CGPreflightScreenCaptureAccess() else { return ["ok": false, "error": "no_screen_recording"] }
        let folder = URL(fileURLWithPath: req["path"] as? String ?? "")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rec = ScreenRecorder(folder: folder, bundles: Set(req["bundles"] as? [String] ?? []),
                                 includeMain: req["include_main"] as? Bool ?? false,
                                 wholeScreen: req["whole_screen"] as? Bool ?? false, goal: req["goal"] as? String ?? "")
        rec.requestedDisplay = (req["display"] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
        rec.preflight = Self.preflight(bundles: rec.bundles)
        if let error = rec.begin() { return ["ok": false, "error": error] }
        active = rec
        return ["ok": true, "path": folder.path, "preflight": rec.preflight]
    }

    /// Stop, finish the movie, make the delivery copy and the step and meta files. The movie to show: the delivery
    /// copy, or the master if it could not be made.
    static func stop() -> [String: Any] {
        lock.lock()
        let rec = active
        active = nil
        lock.unlock()
        guard let rec else { return ["ok": true, "path": NSNull()] }
        rec.end()
        let fm = FileManager.default
        guard fm.fileExists(atPath: rec.master.path) else { return ["ok": true, "path": NSNull()] }
        let exported = rec.exportDelivery()
        rec.writeSidecars(delivered: exported, run: Runner.lastRunDir)
        return ["ok": true, "path": (exported ? rec.delivery : rec.master).path, "folder": rec.folder.path]
    }

    // MARK: what is recorded

    /// The task's apps and DeskMind's panels (its window only when asked for, or while the run asks the user
    /// something), over the wallpaper; or the whole screen.
    ///
    /// Built by leaving windows out, never by naming what to keep: on macOS 26 and later a stream whose filter names
    /// its apps or windows (`including:`, `desktopIndependentWindow:`) puts a purple "being shared" badge in place of
    /// those windows' traffic lights, and every recorded run showed it (checked 10-03, macOS 27.2). Excluding
    /// applications instead kept the menu bar with every app's status items (they belong to no app it can exclude),
    /// so the windows are excluded one by one: everything that is not the task's apps, the wallpaper or DeskMind's
    /// own panels, menu bar included. The signature is the set of windows, so a window that opens later is left out
    /// at the next check (every 0.5 s).
    private func filter(_ content: SCShareableContent, display: SCDisplay) -> (SCContentFilter, Set<Int>) {
        let mine = content.windows.filter { $0.owningApplication?.bundleIdentifier == Self.mainAppBundle }
        // DeskMind's document window sits at the normal level; the island and the decision panel float above it.
        // A question is asked in that window: the moment the recording is for, and it was left out of the picture.
        let mainWindows = includeMain || Runner.asking ? [] : mine.filter { $0.windowLayer == 0 }
        if wholeScreen {
            return (SCContentFilter(display: display, excludingWindows: mainWindows), [])
        }
        let wanted = bundles.union([Self.mainAppBundle, Self.wallpaperBundle])
        let hidden = Set(mainWindows.map(\.windowID))
        let drop = content.windows.filter {
            !wanted.contains($0.owningApplication?.bundleIdentifier ?? "") || hidden.contains($0.windowID)
        }
        return (SCContentFilter(display: display, excludingWindows: drop), Set(content.windows.map { Int($0.windowID) }))
    }

    private func begin() -> String? {
        guard let content = Self.content() else { return "no shareable content" }
        guard let display = displayForTask(content) else { return "no display" }
        self.display = display
        displaysUsed = [display.displayID]
        let (filter, pids) = self.filter(content, display: display)
        included = pids
        let cfg = SCStreamConfiguration()
        // The master at the screen's own resolution: the delivery copy is made from it, and edits start from it.
        (cfg.width, cfg.height) = RecordingSize.pixels(
            width: filter.contentRect.width, height: filter.contentRect.height,
            scale: Double(filter.pointPixelScale), maxLong: nil)
        size = (cfg.width, cfg.height)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.showsCursor = true
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        let oc = SCRecordingOutputConfiguration()
        oc.outputURL = master
        oc.outputFileType = .mov
        oc.videoCodecType = .hevc
        let out = SCRecordingOutput(configuration: oc, delegate: self)
        do { try s.addRecordingOutput(out) } catch { return error.localizedDescription }
        let started = DispatchSemaphore(value: 0)
        var failure: String?
        s.startCapture { err in failure = err?.localizedDescription; started.signal() }
        guard started.wait(timeout: .now() + 10) == .success else { return "capture did not start" }
        if let failure { return failure }
        stream = s; output = out
        if t0 == nil { t0 = Date().timeIntervalSince1970 }   // until the output says when its first frame was
        watchApps()   // also for the whole screen: DeskMind's window comes into it while a question is asked
        return nil
    }

    /// An app the run opens (the task starts it) or reopens is added to what is recorded once it is running.
    /// And DeskMind's window joins while the run is asking the user something (see filter).
    /// And the recording follows the task to the display its windows are on (see displayForTask).
    private func watchApps() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var asking = Runner.asking
            while let self, self.watching {
                Thread.sleep(forTimeInterval: 0.5)
                guard self.watching, let s = self.stream, var display = self.display,
                      let content = Self.content() else { continue }
                var moved = false
                let areas = Dictionary(uniqueKeysWithValues: content.displays.map {
                    ($0.displayID, Double(self.taskWindowArea(content, on: $0))) })
                if let there = self.displayForTask(content),
                   RecordingDisplay.shouldMove(current: display.displayID, candidate: there.displayID, taskArea: areas) {
                    // The task opened on another display (a virtual one, for a run that leaves the user's screen
                    // alone): the picture goes with it, at that display's size.
                    display = there; self.display = there; moved = true
                    self.displaysUsed.append(there.displayID)
                    let (fw, fh) = RecordingSize.pixels(width: Double(there.width), height: Double(there.height),
                                                        scale: Double(self.scale(of: there)), maxLong: nil)
                    let cfg = SCStreamConfiguration()
                    cfg.width = fw; cfg.height = fh
                    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                    cfg.showsCursor = true
                    s.updateConfiguration(cfg) { _ in }
                }
                let (filter, pids) = self.filter(content, display: display)
                if moved || pids != self.included || Runner.asking != asking {
                    self.included = pids; asking = Runner.asking
                    s.updateContentFilter(filter) { _ in }
                }
            }
        }
    }

    /// The display to record: the one requested, else the one holding most of the task's windows (a run on a
    /// virtual display is recorded there, not on the user's screen), else the main display.
    private func displayForTask(_ content: SCShareableContent) -> SCDisplay? {
        let areas = Dictionary(uniqueKeysWithValues: content.displays.map {
            ($0.displayID, Double(taskWindowArea(content, on: $0))) })
        let id = RecordingDisplay.pick(displays: content.displays.map(\.displayID), taskArea: areas,
                                       requested: requestedDisplay, main: CGMainDisplayID(), wholeScreen: wholeScreen)
        return content.displays.first { $0.displayID == id }
    }

    /// How much of the task apps' ordinary windows lies on `display`.
    private func taskWindowArea(_ content: SCShareableContent, on display: SCDisplay) -> CGFloat {
        content.windows.filter { w in
            w.windowLayer == 0 && w.isOnScreen && bundles.contains(w.owningApplication?.bundleIdentifier ?? "")
        }.reduce(0) { sum, w in
            let r = w.frame.intersection(display.frame)
            return sum + (r.isNull ? 0 : r.width * r.height)
        }
    }

    private func scale(of display: SCDisplay) -> CGFloat {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }?.backingScaleFactor ?? 1
    }

    private static func content() -> SCShareableContent? {
        let got = DispatchSemaphore(value: 0)
        var content: SCShareableContent?
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, _ in
            content = c; got.signal()
        }
        return got.wait(timeout: .now() + 10) == .success ? content : nil
    }

    private func end() {
        watching = false
        guard let s = stream else { return }
        stream = nil
        let stopped = DispatchSemaphore(value: 0)
        s.stopCapture { _ in stopped.signal() }
        _ = stopped.wait(timeout: .now() + 10)
        // The file is complete once the recording output says so; a stream stopped before any frame never does.
        _ = finished.wait(timeout: .now() + 10)
        output = nil
    }

    // The system stopped the stream (the display went away): what was written stays, handed over at stop.
    func stream(_ stream: SCStream, didStopWithError error: any Error) { finished.signal() }
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) { t0 = Date().timeIntervalSince1970 }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { finished.signal() }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) { finished.signal() }

    // MARK: the folder

    /// 1920 wide (the 1080p preset keeps the aspect), H.264 in .mp4: plays anywhere.
    private func exportDelivery() -> Bool {
        let asset = AVURLAsset(url: master)
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else { return false }
        try? FileManager.default.removeItem(at: delivery)
        ex.outputURL = delivery
        ex.outputFileType = .mp4
        let done = DispatchSemaphore(value: 0)
        ex.exportAsynchronously { done.signal() }
        _ = done.wait(timeout: .now() + 600)
        return ex.status == .completed
    }

    /// `run`: the run this recording filmed, taken when it stopped (a later run's folder is the last one by the time
    /// a stale recording's export is done).
    private func writeSidecars(delivered: Bool, run: URL?) {
        let t0 = self.t0 ?? 0
        var steps: [[String: Any]] = []
        var state = ""
        if let run, let text = try? String(contentsOf: run.appendingPathComponent("trace.jsonl"), encoding: .utf8) {
            (steps, state) = RecordingSteps.from(trace: text, t0: t0)
        }
        let doc: [String: Any] = [
            "run_id": run?.lastPathComponent ?? NSNull(), "goal": goal, "result": state,
            "t0_epoch": t0, "first_step_ms": steps.first?["t_obs_ms"] ?? NSNull(),
            "probabilities": "raw model probabilities (not calibrated)",
            "coordinates": "screen points, top-left origin; the master is \(size.0)x\(size.1) px",
            "steps": steps,
        ]
        write(doc, to: folder.appendingPathComponent("steps.json"))

        let iso = ISO8601DateFormatter()
        var models: [String: Any] = [:]
        if let m = DeskMindModels.manifest() { models = ["name": m.name, "version": m.version] }
        // What was served, which a development override (models.local.json) makes different from the manifest: footage
        // of G18b runs was labelled with the bundled manifest's G17 (10-01).
        if let dirs = DeskMindModels.readyDirs() {
            models["served"] = ["fast": dirs[.fast]?.lastPathComponent ?? "", "strong": dirs[.strong]?.lastPathComponent ?? "",
                                "threshold": DeskMindModels.routingThreshold()] as [String: Any]
        }
        let handsVersion = (try? String(contentsOf: Runner.runtime.appendingPathComponent("hands/.version"),
                                        encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let meta: [String: Any] = [
            "run_id": run?.lastPathComponent ?? NSNull(), "goal": goal,
            "started": iso.string(from: Date(timeIntervalSince1970: t0)),
            "models": models, "hands": handsVersion, "machine": Self.sysctl("hw.model"),
            "macos": ProcessInfo.processInfo.operatingSystemVersionString,
            "recorded": wholeScreen ? ["whole_screen": true] as [String: Any]
                : ["apps": Array(bundles.union([Self.mainAppBundle, Self.wallpaperBundle])).sorted(),
                   "deskmind_window": includeMain],
            // CGDisplayIsMain 0 and not built in: a virtual display a run was put on.
            "displays": displaysUsed.map { ["id": $0, "main": CGDisplayIsMain($0) != 0, "builtin": CGDisplayIsBuiltin($0) != 0] },
            "master": ["file": "master.mov", "width": size.0, "height": size.1, "fps": 30, "codec": "hevc"],
            "delivery": delivered ? ["file": "delivery.mp4", "max": "1920x1080", "fps": 30, "codec": "h264"]
                : NSNull(),
            "preflight": preflight,
        ]
        write(meta, to: folder.appendingPathComponent("meta.json"))
    }

    private func write(_ obj: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: url)
    }

    // MARK: preflight -- read only: what is wrong is said, nothing is changed for the user

    static func preflight(bundles: Set<String>) -> [String: Any] {
        var out: [String: Any] = [:]
        out["do_not_disturb"] = doNotDisturb()
        out["output_muted"] = osascript("output muted of (get volume settings)")
        out["apps_running"] = Dictionary(uniqueKeysWithValues: bundles.sorted().map {
            ($0, !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty)
        })
        if let s = NSScreen.main {
            out["display"] = ["points": [Int(s.frame.width), Int(s.frame.height)],
                              "scale": Double(s.backingScaleFactor)]
        }
        return out
    }

    /// "on", "off" or "unknown": a Focus is on when the assertions file holds a record (best effort, no API).
    private static func doNotDisturb() -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = (obj["data"] as? [[String: Any]])?.first else { return "unknown" }
        return ((d["storeAssertionRecords"] as? [Any])?.isEmpty ?? true) ? "off" : "on"
    }

    private static func osascript(_ script: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "unknown" }
        p.waitUntilExit()
        let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "unknown" : s
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
