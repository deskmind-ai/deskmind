// End-to-end tests of three helper paths on a real Mac, without starting the helper or any model:
// - recording (Helper/ScreenRecorder.swift): the whole screen for a few seconds in each mode, then the folder it
//   leaves -- the master's frames and size, the delivery copy, meta.json -- and a recording started over a stale one;
// - "Save Full Log…" (Runner.saveLog): what the zip holds, and what it refuses;
// - SIGTERM (Helper/Lifecycle.swift): an app quitting while it is sent SIGTERM, again and again, must exit cleanly
//   and take its child "server" with it (the crash of 10-04 was this race).
// Needs Screen Recording for the terminal it runs from. It shows nothing, presses no key, and records only into the
// output folder, which tests/e2e/helper.sh deletes unless asked to keep it.
//
//   app/tests/e2e/helper.sh            (builds this with the helper's sources and runs it)
//
// Each check prints PASS or FAIL; the exit status is the number of failures.

import AppKit
import AVFoundation

@main
enum HelperE2E {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var out = URL(fileURLWithPath: "/tmp")

    static func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL") \(what)")
        if !ok { failures += 1 }
    }

    static func main() {
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "term-child" { termChild(pidFile: args[2]) }
        guard args.count >= 2 else { print("usage: HelperE2E <out dir> [recording|savelog|sigterm ...]"); exit(2) }
        out = URL(fileURLWithPath: args[1])
        // Sections to run (default all): sigterm, savelog, recording. Recording goes last: capturing the screen
        // registers this process with LaunchServices, and every process it starts afterwards (the 120 SIGTERM
        // children, unzip) would leave a Dock tile for the terminal that macOS never removes.
        let only = Set(args.dropFirst(2))
        if only.isEmpty || only.contains("sigterm") { sigterm() }
        if only.isEmpty || only.contains("savelog") { saveLog() }
        if only.isEmpty || only.contains("recording") { recording() }
        print(failures == 0 ? "HelperE2E: all passed" : "HelperE2E: \(failures) failed")
        exit(Int32(min(failures, 100)))
    }

    // MARK: recording

    static func frames(_ url: URL) -> (count: Int, width: Int, height: Int, seconds: Double) {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return (0, 0, 0, 0) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var n = 0
        while output.copyNextSampleBuffer() != nil { n += 1 }
        return (n, Int(track.naturalSize.width), Int(track.naturalSize.height), asset.duration.seconds)
    }

    static func meta(_ folder: URL) -> [String: Any] {
        (try? Data(contentsOf: folder.appendingPathComponent("meta.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    static func record(_ name: String, smooth: Bool, seconds: Double) -> URL {
        let folder = out.appendingPathComponent(name)
        let started = ScreenRecorder.start(["path": folder.path, "bundles": [String](), "whole_screen": true,
                                            "smooth": smooth, "goal": "e2e \(name)"])
        check(started["ok"] as? Bool == true, "\(name): recording starts (\(started["error"] ?? "ok"))")
        Thread.sleep(forTimeInterval: seconds)
        let stopped = ScreenRecorder.stop()
        check((stopped["path"] as? String)?.hasSuffix("delivery.mp4") == true, "\(name): stop hands over the delivery copy")
        return folder
    }

    static func recording() {
        let display = CGMainDisplayID()
        let mode = CGDisplayCopyDisplayMode(display)
        let (pw, ph) = (mode?.pixelWidth ?? 0, mode?.pixelHeight ?? 0)

        let def = record("default", smooth: false, seconds: 3)
        let m = frames(def.appendingPathComponent("master.mov"))
        // Over the movie's own length: a few more are taken while stop() finishes it.
        let rate = Double(m.count) / max(m.seconds, 0.001)
        check(rate >= 8 && rate <= 12, "default: about 10 pictures a second (\(m.count) in \(String(format: "%.2f", m.seconds)) s)")
        check(m.width == pw && m.height == ph, "default: the master at the display's pixels (\(m.width)x\(m.height), display \(pw)x\(ph))")
        let d = frames(def.appendingPathComponent("delivery.mp4"))
        check(abs(d.count - m.count) <= 1 && d.width <= 1920, "default: the delivery copy has the same pictures, at most 1920 wide (\(d.count), \(d.width))")
        let dm = meta(def)["master"] as? [String: Any] ?? [:]
        check(dm["fps"] as? Double == 10 && dm["capture"] as? String == "one-shot screenshots", "default: meta.json says 10 fps, one-shot (\(dm))")
        check(FileManager.default.fileExists(atPath: def.appendingPathComponent("steps.json").path), "default: steps.json is written")

        let smooth = record("smooth", smooth: true, seconds: 3)
        let s = frames(smooth.appendingPathComponent("master.mov"))
        check(Double(s.count) / max(s.seconds, 0.001) >= 20, "smooth: the stream gives far more pictures (\(s.count) in \(String(format: "%.2f", s.seconds)) s)")
        let sm = meta(smooth)["master"] as? [String: Any] ?? [:]
        check(sm["fps"] as? Double == 30 && sm["capture"] as? String == "stream", "smooth: meta.json says 30 fps, stream (\(sm))")

        let none = ScreenRecorder.stop()
        check(none["ok"] as? Bool == true && none["path"] is NSNull, "stop with nothing recording: no path")

        // A recording nobody stopped is finished when the next starts, and both folders end whole.
        let first = out.appendingPathComponent("stale")
        _ = ScreenRecorder.start(["path": first.path, "bundles": [String](), "whole_screen": true, "goal": "stale"])
        Thread.sleep(forTimeInterval: 1.5)
        let second = record("after-stale", smooth: false, seconds: 1.5)
        var waited = 0.0
        while !FileManager.default.fileExists(atPath: first.appendingPathComponent("meta.json").path) && waited < 15 {
            Thread.sleep(forTimeInterval: 0.5); waited += 0.5
        }
        check(frames(first.appendingPathComponent("master.mov")).count >= 10, "a stale recording is finished when the next starts")
        check(frames(second.appendingPathComponent("master.mov")).count >= 10, "and the next one records")
    }

    // MARK: Save Full Log

    static func entries(_ zip: URL) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-Z1", zip.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
    }

    static func saveLog() {
        let run = out.appendingPathComponent("fake-run")
        try? FileManager.default.createDirectory(at: run.appendingPathComponent("obs"), withIntermediateDirectories: true)
        try? "{\"event\": \"step\"}\n".write(to: run.appendingPathComponent("trace.jsonl"), atomically: true, encoding: .utf8)
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: run.appendingPathComponent("obs/1.png"))
        Runner.lastRunDir = run
        let zip = out.appendingPathComponent("log.zip")
        let r = Runner.saveLog(to: zip.path, details: "HTTP Error 400", diagnostics: "<details>d</details>")
        check(r["ok"] as? Bool == true && r["run"] as? Bool == true, "save log: a zip with the run (\(r))")
        let names = entries(zip)
        for want in ["DeskMind log/run/trace.jsonl", "DeskMind log/run/obs/1.png", "DeskMind log/README.txt",
                     "DeskMind log/error.txt", "DeskMind log/diagnostics.md"] {
            check(names.contains(want), "save log: holds \(want)")
        }
        check(!names.contains { $0.split(separator: "/").last?.hasPrefix("._") == true }, "save log: no AppleDouble files")
        Runner.lastRunDir = nil
        let bare = out.appendingPathComponent("bare.zip")
        let b = Runner.saveLog(to: bare.path, details: "", diagnostics: "")
        check(b["ok"] as? Bool == true && b["run"] as? Bool == false && !entries(bare).contains { $0.contains("/run/") },
              "save log: before any run, the logs and README only")
        check(Runner.saveLog(to: out.appendingPathComponent("log.txt").path, details: "", diagnostics: "")["ok"] as? Bool == false,
              "save log: a path that isn't .zip is refused")
    }

    // MARK: SIGTERM

    nonisolated(unsafe) static var server: Process?

    /// The child: an app with a "server" it must stop at exit. Its main thread keeps the Objective-C runtime busy
    /// (method lookups that miss the cache take the runtime's lock), then quits -- the state the 10-04 crash needed: a
    /// SIGTERM handler sending a message while that lock was held aborted the process.
    static func termChild(pidFile: String) -> Never {
        // The server before AppKit: a process started after this one is registered with LaunchServices leaves a Dock
        // tile for the terminal that ran the test (hands 66aec7b, hands#7).
        let s = Process()
        s.executableURL = URL(fileURLWithPath: "/bin/sleep"); s.arguments = ["600"]
        try? s.run(); server = s
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // as the helper
        atexit { HelperE2E.server?.terminate() }
        Lifecycle.exitOnSIGTERM()
        // Ready: the parent times its SIGTERM from here, so it never lands before the handling is set up.
        try? "\(s.processIdentifier)".write(toFile: pidFile, atomically: true, encoding: .utf8)
        DispatchQueue.main.async {
            let end = Date().addingTimeInterval(0.6)
            var i = 0
            while Date() < end {
                _ = NSObject().responds(to: NSSelectorFromString("helperE2EMissing\(i)")); i += 1
            }
            app.terminate(nil)
        }
        app.run()
        exit(0)
    }

    static func sigterm() {
        var clean = 0, orphans = 0
        var other: [String] = []
        // From the child's "ready", SIGTERM is swept across 0-0.46 s: inside its busy runtime (0.6 s), then its quit.
        let rounds = 120
        for i in 0..<rounds {
            let pidFile = out.appendingPathComponent("server.pid").path
            try? FileManager.default.removeItem(atPath: pidFile)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            p.arguments = ["term-child", pidFile]
            try? p.run()
            var waited = 0.0
            while !FileManager.default.fileExists(atPath: pidFile) && waited < 5 { Thread.sleep(forTimeInterval: 0.005); waited += 0.005 }
            Thread.sleep(forTimeInterval: Double(i % 24) * 0.02)
            kill(p.processIdentifier, SIGTERM)
            p.waitUntilExit()
            if p.terminationReason == .exit && p.terminationStatus == 0 { clean += 1 } else {
                other.append("at \(i % 24 * 20) ms: \(p.terminationReason == .exit ? "exit" : "signal") \(p.terminationStatus)")
            }
            if let pid = (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap({ Int32($0) }) {
                Thread.sleep(forTimeInterval: 0.05)
                if kill(pid, 0) == 0 { orphans += 1; kill(pid, SIGKILL) }
            }
        }
        check(clean == rounds, "SIGTERM while quitting: \(clean)/\(rounds) exits clean\(other.isEmpty ? "" : " -- " + other.joined(separator: "; "))")
        check(orphans == 0, "SIGTERM while quitting: no server left running (\(orphans))")
    }
}
