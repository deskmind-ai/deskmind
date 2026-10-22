// End-to-end tests of three helper paths on a real Mac, without starting the helper or any model:
// - recording (Helper/ScreenRecorder.swift): the whole screen for a few seconds in each mode, then the folder it
//   leaves -- the master's frames and size, the delivery copy, meta.json -- and a recording started over a stale one;
// - "Save Full Log…" (Runner.saveLog): what the zip holds, and what it refuses;
// - SIGTERM (Helper/Lifecycle.swift): an app quitting while it is sent SIGTERM, again and again, must exit cleanly
//   and take its child "server" with it (the crash of 10-04 was this race);
// - the finished run that lingers for its result card's answer (Helper/HarnessRun.swift), with fake processes: let go
//   for certain before a new run (or refused), answerable the moment task_done is passed on, closed by 「清除全部」,
//   which also takes the per-run logs. Needs no permission (`helper.sh "" linger`).
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
        if only.isEmpty || only.contains("linger") { linger() }
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

    // MARK: lingering run (deskmind #103 review)

    /// A fake harness: /bin/sh running `script` (a process group of its own), its stdin a pipe (the run's answers),
    /// started on the machine lock as run `id` and registered as the lingering run at its task_done (HarnessRun.pass).
    static func fakeLingering(_ id: String, _ script: String, onDone: @escaping ([String: Any]) -> Void = { _ in }) -> HarnessRun.Lingering? {
        let p = Process(), input = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard case .ok(let h?) = ComputerLock.acquire(runID: id, by: "helper", spawn: { try? p.run(); return p.processIdentifier }) else {
            check(false, "linger: \(id) starts on the lock"); return nil
        }
        let l = HarnessRun.Lingering(process: p, input: input.fileHandleForWriting)
        l.runID = id
        l.holder = h
        HarnessRun.pass(["event": "task_done", "run_id": id], linger: l) { ev in onDone(ev); return true }
        Thread.detachNewThread { HarnessRun.watchLingering(l) }
        return l
    }

    static func linger() {
        // the machine lock an answer and a run touch (ComputerLock): a scratch folder, never the real Application Support
        let lockDir = FileManager.default.temporaryDirectory.appendingPathComponent("dm-linger-\(getpid())")
        SessionHost.setup.dir = lockDir
        defer { try? FileManager.default.removeItem(at: lockDir) }
        func until(_ f: () -> Bool, _ s: Double = 5) -> Bool {
            let t = Date().addingTimeInterval(s)
            while Date() < t { if f() { return true }; Thread.sleep(forTimeInterval: 0.02) }
            return f()
        }
        func next(_ run: String, signal: @escaping (Int32, Int32) -> Int32 = { kill($0, $1) }) -> ComputerLock.Acquired {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            let r = ComputerLock.acquire(runID: run, by: "helper", term: 0.3, kill: 0.5, signal: signal, spawn: { try? p.run(); return p.processIdentifier })
            if case .ok(_?) = r { p.waitUntilExit(); ComputerLock.free(runID: run, pgid: p.processIdentifier) }   // over at once
            return r
        }
        // P1: an old run that ignores both its stdin closing and SIGTERM (a slow undo) is killed before the next starts
        guard let deaf = fakeLingering("run_deaf", #"trap "" TERM; while :; do sleep 0.1; done"#) else { return }
        if case .ok = next("run_next") { check(!deaf.process.isRunning, "linger: an old run deaf to SIGTERM is killed before the next run") }
        else { check(false, "linger: an old run deaf to SIGTERM is killed before the next run") }
        check(until { HarnessRun.lingering == nil }, "linger: and no longer lingers")
        // ...and when it cannot be confirmed gone, the next run is refused (previous_run_alive) and it stays the holder
        guard let stuck = fakeLingering("run_stuck", "exec sleep 30") else { return }
        if case .alive(let h) = next("run_next2", signal: { _, _ in 0 }) {
            check(h.runID == "run_stuck" && stuck.process.isRunning && ComputerLock.read()?.runID == "run_stuck"
                  && HarnessRun.stillRunning["code"] as? String == "previous_run_alive",
                  "linger: a process not confirmed gone refuses the next run (previous_run_alive) and still holds the Mac")
        } else { check(false, "linger: a process not confirmed gone refuses the next run") }
        if case .ok = next("run_next3") { check(!stuck.process.isRunning, "linger: the next attempt ends it") } else { check(false, "linger: the next attempt ends it") }

        // P2: an undo sent the moment task_done reaches the app is let through (the lock said lingering first)
        let got = out.appendingPathComponent("respond.txt")
        var answered: [String: Any] = [:]
        var overWhileSent = true
        var fresh: HarnessRun.Lingering?
        fresh = fakeLingering("run_e2e", "read line; printf '%s' \"$line\" > '\(got.path)'; sleep 30") { ev in
            answered = HarnessRun.respond(runID: ev["run_id"] as? String ?? "", option: 1)
            overWhileSent = fresh?.over ?? false
        }
        guard let fresh else { return }
        check(answered["ok"] as? Bool == true && answered["run_id"] as? String == "run_e2e", "linger: respond right after task_done: \(answered)")
        check(!overWhileSent && fresh.over, "linger: the run is over (and `done` may follow) only once task_done is sent")
        let until3 = Date().addingTimeInterval(3)
        while (try? String(contentsOf: got, encoding: .utf8)) == nil && Date() < until3 { Thread.sleep(forTimeInterval: 0.05) }
        let line = (try? Data(contentsOf: got)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        check(line["type"] as? String == "respond" && line["option"] as? Int == 1, "linger: the respond line reached the run's stdin: \(line)")
        // an undo going acts: a new task is refused meanwhile, not run beside it
        if case .busy = next("run_beside") { check(fresh.process.isRunning, "linger: an undo going: the next run is refused (computer_busy), the undo left alone") }
        else { check(false, "linger: an undo going: the next run is refused") }
        HarnessRun.settle(fresh)   // its result_response came: it acts no more

        // 「清除全部」 takes the per-run logs too, and lets the lingering run (which writes them) go first
        let support = out.appendingPathComponent("support")
        let fm = FileManager.default
        let made = ["work/hands/runs/do-1/trace.jsonl", "work/harness-runs/run_e2e/events.jsonl",
                    "work/harness-logs/run_e2e.stdout", "work/harness-logs/run_e2e.stderr", "feedback.jsonl"]
        func make() {
            for f in made {
                let u = support.appendingPathComponent(f)
                try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: u.path, contents: Data("the task's words".utf8))
            }
        }
        make()
        check(Runner.clearRunData(support: support, endLast: { false }) == nil
              && made.allSatisfy { fm.fileExists(atPath: support.appendingPathComponent($0).path) },
              "linger: a lingering run that would not end: nothing cleared")
        let removed = Runner.clearRunData(support: support)
        let left = made.filter { fm.fileExists(atPath: support.appendingPathComponent($0).path) }
        check(removed == 2 && left.isEmpty && !fresh.process.isRunning && HarnessRun.lingering == nil,
              "linger: clear all: the lingering run ended, run folders and per-run logs gone (removed \(removed ?? -1), left \(left))")
        Runner.busy = true
        make()
        check(Runner.clearRunData(support: support, endLast: { true }) == nil
              && made.allSatisfy { fm.fileExists(atPath: support.appendingPathComponent($0).path) }, "linger: nothing cleared while a run is going")
        Runner.busy = false
        check(Runner.clearRunData(support: support, endLast: { Runner.busy = true; return true }) == nil
              && made.allSatisfy { fm.fileExists(atPath: support.appendingPathComponent($0).path) }, "linger: nothing cleared when a run starts meanwhile")
        Runner.busy = false
        // a session's lingering run is not this helper's to end for 「清除全部」
        let ses = Process(); ses.executableURL = URL(fileURLWithPath: "/bin/sleep"); ses.arguments = ["30"]
        if case .ok(let hs?) = ComputerLock.acquire(runID: "run_ses", by: "session", spawn: { try? ses.run(); return ses.processIdentifier }) {
            ComputerLock.linger(hs)
        }
        check(ComputerLock.endOwnLingering() && ses.isRunning, "linger: clear all leaves a session's lingering run alone")
        kill(-ses.processIdentifier, SIGKILL)
        lingerFullRun()
    }

    /// The whole HarnessRun.run, with a fake harness (runtime/node/bin/node beside this binary, a shell script) and
    /// Application Support moved into the output folder. The first run says task_done and exits, leaving a child in its
    /// group that ignores SIGTERM and writes on: it is lingering; the next run ends it before it starts. A run that
    /// exits without task_done leaving a child: that child acts -- the next run is refused (computer_busy) until it is
    /// gone. (A process that leaves its group, setsid, is outside the lock: docs/protocol.md 「电脑锁」.)
    static func lingerFullRun() {
        let fm = FileManager.default
        let d = out.appendingPathComponent("fullrun")
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        let runtime = Runner.runtime
        guard runtime.path.hasPrefix(out.path) else { check(false, "linger: the fake runtime is beside this binary (\(runtime.path))"); return }
        DeskMindIPC.supportOverride = out.appendingPathComponent("support-run")
        defer { DeskMindIPC.supportOverride = nil }
        try? fm.removeItem(at: ComputerLock.file)
        let node = runtime.appendingPathComponent("node/bin/node")
        for dir in [node.deletingLastPathComponent(), runtime.appendingPathComponent("harness"), runtime.appendingPathComponent("hands")] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        fm.createFile(atPath: runtime.appendingPathComponent("harness/harness.mjs").path, contents: Data())
        fm.createFile(atPath: runtime.appendingPathComponent("hands/.version").path, contents: Data("e2e".utf8))
        let done = #"{"kind":"task_done","status":"succeeded","reason":"verified","summary":"ok","result_card":null}"#
        let script = """
            #!/bin/sh
            D='\(d.path)'
            echo x >> "$D/launched"
            read req
            if [ -f "$D/second" ]; then
              kill -0 "$(cat "$D/same.pid")" 2>/dev/null && echo same >> "$D/alive-at-start"
              rm -f "$D/second"
              if [ -f "$D/undo" ]; then
                echo '{"kind":"task_done","status":"succeeded","reason":"verified","summary":"ok","result_card":{"kind":"result","text":"done","options":[{"kind":"approve","text":"ok"},{"kind":"undo","text":"undo"}],"free_text":false,"blocking":false}}'
                read answer
                ( trap "" TERM; exec sleep 30 ) </dev/null >/dev/null 2>&1 &
                echo $! > "$D/undochild.pid"
                exit 0
              fi
              if [ -f "$D/nodone" ]; then
                ( trap "" TERM; exec sleep 30 ) </dev/null >/dev/null 2>&1 &
                echo $! > "$D/orphan.pid"
                exit 1
              fi
              echo '\(done)'
              exit 0
            fi
            ( trap "" TERM; while :; do echo x >> "$D/same.txt"; sleep 0.1; done ) </dev/null >/dev/null 2>&1 &
            echo $! > "$D/same.pid"
            sleep 0.8
            echo '\(done)'
            exit 0

            """
        fm.createFile(atPath: node.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
        func run() -> [[String: Any]] {
            var events: [[String: Any]] = []
            guard Runner.accept() else { return [["event": "error", "error": "not accepted"]] }
            HarnessRun.run(Runner.Spec(["op": "run", "engine": "harness", "goal": "e2e"])) { events.append($0); return true }
            return events
        }
        func pid(_ f: String) -> pid_t { pid_t((try? String(contentsOf: d.appendingPathComponent(f), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 }
        func size(_ f: String) -> Int { (try? fm.attributesOfItem(atPath: d.appendingPathComponent(f).path)[.size] as? Int) ?? 0 }
        func up(_ p: pid_t) -> Bool { ComputerLock.startOf(p) != nil }

        let first = run()
        let same = pid("same.pid")
        check(first.contains { $0["event"] as? String == "task_done" } && first.last?["event"] as? String == "done",
              "linger (full run): the first run ends at task_done: \(first.map { $0["event"] as? String ?? "?" })")
        Thread.sleep(forTimeInterval: 0.5)
        let s0 = size("same.txt")
        Thread.sleep(forTimeInterval: 0.5)
        check(HarnessRun.lingering == nil && same > 0 && up(same) && size("same.txt") > s0 && ComputerLock.read()?.state == "lingering",
              "linger (full run): its harness gone, its child still up and writing; the lock: lingering")

        fm.createFile(atPath: d.appendingPathComponent("second").path, contents: Data())
        let second = run()
        check(!fm.fileExists(atPath: d.appendingPathComponent("alive-at-start").path),
              "linger (full run): the next run starts only once that child is gone")
        let s1 = size("same.txt")
        Thread.sleep(forTimeInterval: 0.5)
        check(!up(same) && size("same.txt") == s1, "linger (full run): the child writes no more after the next run started")
        check(!second.contains { $0["event"] as? String == "error" } && second.contains { $0["event"] as? String == "task_done" },
              "linger (full run): the next run itself ran: \(second.map { $0["event"] as? String ?? "?" })")

        // a run that exits without task_done, leaving a child that may still act: the next run is refused until it is gone
        fm.createFile(atPath: d.appendingPathComponent("second").path, contents: Data())
        fm.createFile(atPath: d.appendingPathComponent("nodone").path, contents: Data())
        _ = run()
        try? fm.removeItem(at: d.appendingPathComponent("nodone"))
        let orphan = pid("orphan.pid")
        check(orphan > 0 && up(orphan) && ComputerLock.read()?.acting == true, "linger (full run): a run gone without task_done, its child up: the lock says acting")
        let refused = run()
        check(refused.contains { $0["code"] as? String == "computer_busy" } && up(orphan),
              "linger (full run): the next run is refused (computer_busy), the child left alone: \(refused.map { $0["code"] as? String ?? $0["event"] as? String ?? "?" })")
        kill(orphan, SIGKILL)
        Thread.sleep(forTimeInterval: 0.3)
        fm.createFile(atPath: d.appendingPathComponent("second").path, contents: Data())
        let after = run()
        check(after.contains { $0["event"] as? String == "task_done" }, "linger (full run): the child gone, the next run runs")

        // deskmind#105 P2: an undo sent at once at task_done acts (the lock: acting); the harness exits before the run
        // thread is done, leaving the undo's child. The run's own end must not write lingering over the undo's acting:
        // the child keeps the Mac (the next task is refused), not ended by it.
        fm.createFile(atPath: d.appendingPathComponent("second").path, contents: Data())
        fm.createFile(atPath: d.appendingPathComponent("undo").path, contents: Data())
        var undoEvents: [[String: Any]] = []
        var answered: [String: Any] = [:]
        var harnessGoneFirst = false
        guard Runner.accept() else { check(false, "linger (undo exit): accepted"); return }
        HarnessRun.run(Runner.Spec(["op": "run", "engine": "harness", "goal": "e2e"])) { ev in
            undoEvents.append(ev)
            if ev["event"] as? String == "task_done" {
                let harness = HarnessRun.lingering?.process
                answered = HarnessRun.respond(runID: ev["run_id"] as? String ?? "", option: 1)
                // the harness reads it, starts the child and exits -- before the run thread goes on (its end is the
                // path under test): waited for, not assumed
                let until = Date().addingTimeInterval(5)
                while harness?.isRunning == true && Date() < until { Thread.sleep(forTimeInterval: 0.02) }
                harnessGoneFirst = harness != nil && harness?.isRunning == false
            }
            return true
        }
        try? fm.removeItem(at: d.appendingPathComponent("undo"))
        let undoChild = pid("undochild.pid")
        check(answered["ok"] as? Bool == true && undoChild > 0 && up(undoChild) && harnessGoneFirst,
              "linger (undo exit): the undo answered at task_done, its child up after the harness exited (\(answered))")
        check(ComputerLock.read()?.acting == true, "linger (undo exit): the lock still says acting (\(String(describing: ComputerLock.read())))")
        let beside = Process(); beside.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        if case .busy = ComputerLock.acquire(runID: "run_beside", by: "session", spawn: { try? beside.run(); return beside.processIdentifier }) {
            check(up(undoChild), "linger (undo exit): the next task is refused, the undo's child left alone")
        } else { check(false, "linger (undo exit): the next task is refused, the undo's child left alone") }
        kill(undoChild, SIGKILL)

        // deskmind#105 P1: nothing of a refused request touches the desktop -- `hands do` reopens its apps' windows
        // only once it holds the machine lock (a recorder here, never real apps)
        var reopened: [([String], String)] = []
        Runner.reopenWindows = { bundles in reopened.append((bundles, ComputerLock.read().map { "\($0.by) \($0.state) \($0.pgid)" } ?? "none")) }
        defer { Runner.reopenWindows = { Runner.reopenWindowless($0) } }
        let holder = Process(); holder.executableURL = URL(fileURLWithPath: "/bin/sleep"); holder.arguments = ["30"]
        _ = ComputerLock.acquire(runID: "run_session_task", by: "session", spawn: { try? holder.run(); return holder.processIdentifier })
        let handsDo = ["op": "run", "goal": "整理一下", "planner": "http://127.0.0.1:9",
                       "apps": [["name": "TextEdit", "bundle": "com.apple.TextEdit"]]] as [String: Any]
        var refusedDo: [[String: Any]] = []
        guard Runner.accept() else { check(false, "hands do: accepted"); return }
        Runner.run(Runner.Spec(handsDo)) { refusedDo.append($0); return true }
        check(refusedDo.contains { $0["code"] as? String == "computer_busy" } && reopened.isEmpty && !Runner.busy,
              "hands do while a session's task acts: computer_busy, and no window reopened, no app launched (\(reopened.count))")
        kill(-holder.processIdentifier, SIGKILL); holder.waitUntilExit()
        // the Mac free: the windows are reopened only under this run's own reservation
        guard Runner.accept() else { check(false, "hands do: accepted again"); return }
        var freeDo: [[String: Any]] = []
        Runner.run(Runner.Spec(handsDo)) { freeDo.append($0); return true }
        check(reopened.count == 1 && reopened.first?.0 == ["com.apple.TextEdit"] && reopened.first?.1 == "hands acting 0",
              "hands do: its windows reopened while it holds the Mac (\(reopened.map(\.1)))")
        check(ComputerLock.read() == nil && !Runner.busy,
              "and its reservation let go when its process could not start (\(freeDo.map { $0["event"] as? String ?? "?" }))")

        for p in [same, orphan] where up(p) { kill(p, SIGKILL) }

        // Stop while the next run's machine lock ends the last one's process (a harness deaf to SIGTERM: SIGKILL after
        // 1.5 s): the run is cancelled, and its harness is never started (deskmind #103 external review, P2)
        let launched = { (try? String(contentsOf: d.appendingPathComponent("launched"), encoding: .utf8))?.count ?? 0 }
        let before = launched()
        guard let deaf = fakeLingering("run_deaf_stop", #"trap "" TERM; sleep 30"#) else { return }
        Thread.detachNewThread { Thread.sleep(forTimeInterval: 0.5); Runner.requestStop() }
        let stopped = run()
        // ended (SIGKILL) inside the next run's acquire; Foundation reaps it a moment later
        let reaped = Date().addingTimeInterval(2)
        while deaf.process.isRunning && Date() < reaped { Thread.sleep(forTimeInterval: 0.02) }
        check(stopped.last?["reason"] as? String == "cancelled" && !stopped.contains { $0["event"] as? String == "task_done" }
              && launched() == before && !deaf.process.isRunning,
              "linger (stop): a stop while the last run's process is ended: no launch (\(stopped.map { $0["event"] as? String ?? "?" }))")
        check(!Runner.stopRequested && !Runner.busy && Runner.current == nil, "linger (stop): nothing of it left for the next run")

        // A stop the moment the request is taken, before the run function has begun: honoured (the run function no
        // longer clears the flags), and a second request meanwhile is refused
        let before2 = launched()
        check(Runner.accept() && !Runner.accept(), "linger (stop): one request taken at a time")
        Runner.requestStop()
        var early: [[String: Any]] = []
        HarnessRun.run(Runner.Spec(["op": "run", "engine": "harness", "goal": "e2e"])) { early.append($0); return true }
        check(early.last?["reason"] as? String == "cancelled" && launched() == before2 && !Runner.busy && !Runner.stopRequested,
              "linger (stop): a stop right after the request is taken: no launch (\(early.map { $0["event"] as? String ?? "?" }))")

        // A stop between the start and `current` (the launch's own moment, held open here): it waits for the
        // launch, then stops the process it started -- not lost
        check(Runner.accept(), "linger (stop): taken")
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["30"]
        let started = (try? Runner.launch(sleeper, started: {
            Thread.detachNewThread { Runner.requestStop() }
            Thread.sleep(forTimeInterval: 0.3)
        })) ?? false
        let until = Date().addingTimeInterval(3)
        while sleeper.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.05) }
        check(started && !sleeper.isRunning && Runner.stopRequested, "linger (stop): a stop during the launch stops the process started")
        // ...and one before it: nothing started
        let never = Process()
        never.executableURL = URL(fileURLWithPath: "/bin/sleep"); never.arguments = ["30"]
        check((try? Runner.launch(never)) == false && !never.isRunning, "linger (stop): a stop before the launch: nothing started")
        _ = Runner.release(); Runner.busy = false; Runner.cancelled = false
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
