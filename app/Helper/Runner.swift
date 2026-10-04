// Runs a DeskMind Hands task set with the Python runtime inside this bundle and streams its steps back.
//
// The runtime (CPython + dependencies + the deskmind-hands tree) ships read-only in Contents/Resources/runtime.
// deskmind-hands writes its runs next to its own tree, so the tree is copied to a working directory in Application
// Support once per version, and runs from there. Steps are read from the trace files as they are written.

import AppKit
import Foundation

enum Runner {
    nonisolated(unsafe) static var current: Process?
    /// The user pressed Stop: the run ends as stopped, not as an error with "Exit code 15" and a stack of details.
    nonisolated(unsafe) static var stopRequested = false
    /// The running `hands do`'s stdin: where the user's answer to a HANDS_ASK question goes (see answer()).
    nonisolated(unsafe) static var answers: FileHandle?
    /// A question is waiting for its answer. One at a time: hands blocks on it until it gets one line back.
    nonisolated(unsafe) static var asking = false
    private static let answerLock = NSLock()
    /// A run has been accepted and not yet ended -- including the seconds before its process exists, while the
    /// vision model loads, when `current` is still nil and a second request must not slip in.
    nonisolated(unsafe) static var busy = false
    /// "Stop" arrived before the process started (during that same wait): it is not started at all.
    nonisolated(unsafe) static var cancelled = false

    static var runtime: URL { Bundle.main.resourceURL!.appendingPathComponent("runtime") }
    static var work: URL { DeskMindIPC.supportDir.appendingPathComponent("work/hands") }

    static func prepareWork() throws {
        let fm = FileManager.default
        let shipped = (try? String(contentsOf: runtime.appendingPathComponent("hands/.version"), encoding: .utf8)) ?? "?"
        let have = (try? String(contentsOf: work.appendingPathComponent(".version"), encoding: .utf8)) ?? ""
        guard shipped != have else { return }
        if fm.fileExists(atPath: work.path) { try fm.removeItem(at: work) }
        try fm.createDirectory(at: work.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: runtime.appendingPathComponent("hands"), to: work)
    }

    /// Pay the first-run costs before anyone is waiting: macOS verifies a newly installed 80 MB Peekaboo on its first
    /// launch, and Python compiles deskmind-hands on its first import. Run once when the helper starts.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            try? prepareWork()
            let peek = Process()
            peek.executableURL = runtime.appendingPathComponent("bin/peekaboo")
            peek.arguments = ["--version"]
            peek.standardOutput = FileHandle.nullDevice; peek.standardError = FileHandle.nullDevice
            try? peek.run(); peek.waitUntilExit()
            let py = Process()
            py.executableURL = runtime.appendingPathComponent("python/bin/python3.12")
            py.arguments = ["-c", "import deskmind_hands.cli, deskmind_hands.drivers.peekaboo, deskmind_hands.adapters.systemone"]
            py.currentDirectoryURL = work
            py.environment = ["HOME": NSHomeDirectory(), "PYTHONNOUSERSITE": "1",
                              "PYTHONPATH": "\(work.path):\(runtime.appendingPathComponent("site").path)",
                              "PYTHONPYCACHEPREFIX": DeskMindIPC.supportDir.appendingPathComponent("pycache").path]
            py.standardOutput = FileHandle.nullDevice; py.standardError = FileHandle.nullDevice
            try? py.run(); py.waitUntilExit()
        }
    }

    /// The folder of the run in progress or last run (hands' runs/do-*): a recording's steps are read from it.
    nonisolated(unsafe) static var lastRunDir: URL?
    nonisolated(unsafe) private static var warmedOCR = Date.distantPast
    nonisolated(unsafe) private static var warmedPython = Date.distantPast
    private static let warmLock = NSLock()

    /// The first text recognition after a while took 15 s (the system loads its model again), the next ones under
    /// one: the first look at a screen-only app waited for it. Recognising a small image loads it ahead of time.
    static func warmOCR() {
        warmLock.lock()
        let due = Date().timeIntervalSince(warmedOCR) > 120
        if due { warmedOCR = Date() }
        warmLock.unlock()
        guard due else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let img = DeskMindIPC.supportDir.appendingPathComponent("work/warm-ocr.png")
            if !FileManager.default.fileExists(atPath: img.path) {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32, bitsPerSample: 8,
                                           samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                try? rep?.representation(using: .png, properties: [:])?.write(to: img)
            }
            let ocr = Process()
            ocr.executableURL = runtime.appendingPathComponent("hands/tools/native/ocr")
            ocr.arguments = [img.path]
            ocr.standardOutput = FileHandle.nullDevice; ocr.standardError = FileHandle.nullDevice
            try? ocr.run(); ocr.waitUntilExit()
        }
    }

    /// Get ready for a request that is about to run (the confirmation sheet is up, or the instruction names its
    /// apps): the Brain, and for an app with no accessibility tree the vision model and text recognition, loaded
    /// while the user is still reading -- the first look at the screen took about 40 s when all of it waited for
    /// Start. Cheap to call again: each part is skipped when it is loaded or was just warmed.
    static func prewarm(bundles: [String]) {
        BrainServer.ensure()
        if bundles.contains(where: { !Spec.accessibleApps.contains($0) }) && DeskMindModels.eyesDir() != nil {
            EyesServer.ensure()
            EyesServer.touch()
            warmOCR()
        }
        warmLock.lock()
        let due = Date().timeIntervalSince(warmedPython) > 300
        if due { warmedPython = Date() }
        warmLock.unlock()
        // The interpreter and deskmind-hands' modules back in the page cache.
        if due { warmUp() }
    }

    /// Close what the run left open, through each app's own scripting and only for this app's sandbox folders:
    /// a TextEdit document saved in the background stayed on screen after the run, and its close button did not
    /// respond. Documents are closed without saving -- the task already saved what it was asked to.
    /// Until when the user has handed the screen over (epoch seconds in a file hands reads; see HANDS_TAKEOVER_FILE).
    static var takeoverFile: URL { DeskMindIPC.supportDir.appendingPathComponent("takeover-until") }

    /// Let the running task use the mouse and the front for `seconds`, or give them back (0).
    static func takeOver(seconds: Double) {
        let until = seconds > 0 ? Date().timeIntervalSince1970 + seconds : 0
        try? String(until).write(to: takeoverFile, atomically: true, encoding: .utf8)
    }

    static func cleanUp(quitTextEdit: Bool) {
        let runs = work.appendingPathComponent("runs").path.replacingOccurrences(of: "\"", with: "\\\"")
        // A script that names TextEdit launches it when it is compiled, `if application "TextEdit" is running`
        // notwithstanding; a bare launch opens TextEdit's Open panel, which then lingers hidden. So the TextEdit part
        // is only there when TextEdit already runs.
        let textEditRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty
        let textEdit = !textEditRunning ? "" : """
            tell application "TextEdit"
              close (every document whose path contains "\(runs)") saving no
              -- Started by this run and left with nothing of the user's: quit it, so its Dock dot goes too.
              -- Closing a document while TextEdit is in the background leaves its window behind with no
              -- document (a ghost), and a plain quit then fails with -128. With no document left there is nothing
              -- that "saving no" could discard, so that is when it may quit.
              if \(quitTextEdit ? "true" : "false") and (count of documents) = 0 then quit saving no
            end tell
        """
        let script = """
        with timeout of 8 seconds
        \(textEdit)
          tell application "Finder"
            repeat with i from (count of Finder windows) to 1 by -1
              try
                if (POSIX path of ((target of Finder window i) as alias)) contains "\(runs)" then close Finder window i
              end try
            end repeat
          end tell
        end timeout
        """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err { NSLog("DeskMind Hands: clean-up: \(err)") }
    }

    /// The sample folder: a first instruction can be tried on it without attaching any folder of the user's.
    static var playground: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("DeskMind Playground", isDirectory: true)
    }

    @discardableResult
    static func ensurePlayground() throws -> URL {
        let fm = FileManager.default
        let dir = playground
        let exists = fm.fileExists(atPath: dir.path)
        let empty = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.isEmpty
        if exists && !empty { return dir }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let zh = ResolvedLang.current == .zhHans
        let files: [(String, String)] = zh ? [
            ("会议纪要-0925.txt", "周会纪要\n1. 发布日期定在 10 月 15 日\n2. 张伟负责测试\n3. 下次会议：10 月 2 日\n"),
            ("待办.txt", "买牛奶\n回复邮件\n整理照片\n"),
            ("报销单.csv", "日期,项目,金额\n2026-09-20,打车,46\n2026-09-22,午餐,88\n2026-09-23,酒店,560\n"),
            ("草稿.txt", "这是一份草稿，可以让 DeskMind 帮你改写或者另存。\n"),
            ("截图-01.txt", "（示例文件：假装这是一张截图）\n"),
            ("截图-02.txt", "（示例文件：假装这是另一张截图）\n"),
        ] : [
            ("Meeting notes 0925.txt", "Weekly sync\n1. Release date: Oct 15\n2. Alex owns testing\n3. Next meeting: Oct 2\n"),
            ("todo.txt", "Buy milk\nReply to emails\nSort photos\n"),
            ("expenses.csv", "date,item,amount\n2026-09-20,taxi,46\n2026-09-22,lunch,88\n2026-09-23,hotel,560\n"),
            ("draft.txt", "A draft you can ask DeskMind to rewrite or save elsewhere.\n"),
            ("screenshot-01.txt", "(sample file: pretend this is a screenshot)\n"),
            ("screenshot-02.txt", "(sample file: pretend this is another screenshot)\n"),
        ]
        for (name, text) in files {
            try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    /// Put the playground back to its sample files. Only this folder is ever touched.
    static func resetPlayground() throws -> URL {
        let fm = FileManager.default
        let dir = playground
        guard dir.lastPathComponent == "DeskMind Playground", dir.deletingLastPathComponent().path == NSHomeDirectory()
        else { throw NSError(domain: "DeskMind", code: 1) }
        if fm.fileExists(atPath: dir.path) {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        return try ensurePlayground()
    }

    /// Screenshots add up (a window capture per step): keep only the most recent runs.
    /// Delete what runs left on this Mac: every run folder (step screenshots, traces, the run's log) and the 👍/👎
    /// verdicts. Not while a run is going (its folder is in use). Recordings in Movies › DeskMind are the user's
    /// files and stay; routing.jsonl holds no screen content (who answered each step, and why) and stays for the
    /// developer tools. Returns how many run folders were removed, or nil when a run is going.
    static func clearRunData() -> Int? {
        if busy { return nil }
        let fm = FileManager.default
        let runs = work.appendingPathComponent("runs")
        let dirs = (try? fm.contentsOfDirectory(atPath: runs.path)) ?? []
        for d in dirs { try? fm.removeItem(at: runs.appendingPathComponent(d)) }
        try? fm.removeItem(at: DeskMindIPC.supportDir.appendingPathComponent("feedback.jsonl"))
        return dirs.count
    }

    static func pruneRuns(keep: Int) {
        let runs = work.appendingPathComponent("runs")
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(atPath: runs.path)) ?? []).sorted()
        for d in dirs.dropLast(keep) { try? fm.removeItem(at: runs.appendingPathComponent(d)) }
    }

    /// One step in words a person reads: "Type “archive” into “New folder name”", not "type_text #syn:... 'archive'".
    static func humanize(_ e: [String: Any]) -> String {
        let lang = ResolvedLang.current
        let action = e["action"] as? [String: Any] ?? [:]
        let kind = (action["kind"] as? String) ?? (e["kind"] as? String) ?? ""
        let label = (e["target_label"] as? String).map { L("“%@”", String($0.prefix(24)), lang: lang) } ?? ""
        let text = (action["text"] as? String).map { "“\(String($0.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(30)))”" } ?? ""
        // Controls the projection layer adds (syn:*) carry Chinese labels the model was trained on; say what they
        // do in the user's language instead of quoting the label.
        if let target = (e["describe"] as? String)?.split(separator: " ").dropFirst().first, target.hasPrefix("#syn:") {
            let parts = target.dropFirst(5).split(separator: ":", maxSplits: 1).map(String.init)
            let raw = (action["text"] as? String) ?? ""
            let quoted = "“\(String(raw.prefix(30)))”"
            switch (parts[0], parts.count > 1 ? parts[1] : "") {
            case ("newfolder", "name"): return L("Name the new folder %@", quoted, lang: lang)
            case ("newfolder", _): return L("Create the folder", lang: lang)
            case ("move", let file) where !file.isEmpty:
                // Destinations read "子文件夹 X" / "上级文件夹 X" / "工作目录顶层 X": the folder name is the last word.
                let dest = raw.split(separator: " ").last.map(String.init) ?? raw
                return L("Move %1$@ into %2$@", "“\(file)”", "“\(dest)”", lang: lang)
            case ("save", _): return L("Save", lang: lang)
            case ("undo", _): return L("Undo the last change", lang: lang)
            case ("saveas", "name"): return L("Name the file %@", quoted, lang: lang)
            case ("saveas", "folder"): return L("Choose where to save it", lang: lang)
            case ("saveas", _): return L("Save it as a new file", lang: lang)
            case ("newdoc", _): return L("Start a new document", lang: lang)
            case ("view", _): return L("Change the Finder view", lang: lang)
            default: break
            }
        }
        let line: String = switch kind {
        case "type_text": L("Type %2$@ into %1$@", label, text, lang: lang)
        case "append_text": L("Add %2$@ to the end of %1$@", label, text, lang: lang)
        case "replace_text": L("Change the text in %1$@ to %2$@", label, text, lang: lang)
        case "click": L("Click %@", label, lang: lang)
        case "double_click": L("Open %@", label, lang: lang)
        case "select": L("Choose %2$@ in %1$@", label, text, lang: lang)
        case "scroll": L("Scroll %@", label, lang: lang)
        case "key": L("Press %@", (action["text"] as? String) ?? (action["chord"] as? String) ?? L("a key", lang: lang),
                      lang: lang)
        case "focus_window": L("Switch to another window", lang: lang)
        case "focus_app": L("Switch to another app", lang: lang)
        // A question's answer ends the run as a DONE whose text is "answer: …" (hands' ANSWER operation).
        case "done": ((e["text"] as? String)?.hasPrefix("answer: ") == true ? L("Give the answer", lang: lang)
                                                                             : L("Finish the task", lang: lang))
        case "give_up", "blocked": L("Stuck, so it stopped", lang: lang)
        case "ask", "ask_user": L("Asked you a question", lang: lang)
        case "request_approval": L("Asked for your approval", lang: lang)
        case "answer": L("Give the answer", lang: lang)
        default: (e["describe"] as? String) ?? kind
        }
        // An English step with no label or text ("Click ") must not end in a space.
        return line.trimmingCharacters(in: .whitespaces)
    }

    static func title(of taskID: String, set: String) -> String {
        let yaml = work.appendingPathComponent("tasks/\(set)/\(taskID).yaml")
        guard let text = try? String(contentsOf: yaml, encoding: .utf8) else { return taskID }
        for line in text.split(separator: "\n") where line.hasPrefix("title:") {
            return line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        }
        return taskID
    }

    /// What to run. The mock desktop needs no model; a real task drives Finder/TextEdit through Peekaboo with a
    /// local planner behind /v1/systemone; a goal is the user's own instruction, run with `hands do`.
    struct Spec {
        var set = "smoke"
        var task: String? = nil
        /// The user's own instruction: `hands do`, no fixture and no grader.
        var goal: String? = nil
        /// The folder attached to it, if any. Without one the run operates apps only and changes no files.
        var folder: String? = nil
        /// The apps the instruction names, as it names them, in the order it names them: the first is where the run
        /// starts, and the planner may switch among them (and only them). Empty: Finder, for a folder task.
        var apps: [(name: String, bundle: String)] = []
        /// The user agreed (on the confirmation sheet) that these apps may be brought to the front for a moment when
        /// they ignore background input.
        var foregroundOK = false
        /// Show the window the run works in, live, in a corner card (LiveCard; the View menu's setting).
        var liveView = false
        var real = false
        var planner = BrainServer.url
        var model = BrainServer.modelName

        init(_ req: [String: Any]) {
            set = req["set"] as? String ?? set
            task = req["task"] as? String
            goal = (req["goal"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            folder = (req["folder"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            apps = (req["apps"] as? [[String: Any]] ?? []).compactMap { a in
                guard let n = a["name"] as? String, let b = a["bundle"] as? String, !b.isEmpty else { return nil }
                // hands reads --apps as "Name=bundle,Name=bundle": neither may appear inside a name.
                let name = n.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "=", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                return (name.isEmpty ? b : name, b)
            }
            foregroundOK = req["foreground_ok"] as? Bool ?? false
            liveView = req["live_view"] as? Bool ?? false
            real = (req["real"] as? Bool ?? false) || goal != nil
            planner = req["planner"] as? String ?? planner
            model = req["model"] as? String ?? model
        }

        /// Apps whose windows hands reads through accessibility, well enough that no run of theirs needs vision.
        static let accessibleApps: Set<String> = ["com.apple.finder", "com.apple.TextEdit"]
        /// Whether the vision model may be needed: any app beyond Finder and TextEdit. Kept that simple on purpose --
        /// hands decides per window whether to look with vision, and a server that loads for nothing costs seconds.
        var mayNeedVision: Bool { goal != nil && apps.contains { !Self.accessibleApps.contains($0.bundle) } }
    }

    /// Bring back the window of each named app that runs with none (see AppWindow), without bringing it forward,
    /// and wait a moment for it to appear.
    static func reopenWindowless(_ bundles: [String]) {
        for b in bundles {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: b).first else { continue }
            func windows() -> Int {
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                    as? [[String: Any]] ?? []
                return list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier
                    && ($0[kCGWindowLayer as String] as? Int ?? -1) == 0 }.count
            }
            let info = app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary }
            guard AppWindow.shouldReopen(bundle: b, running: true, ordinaryWindows: windows(),
                                         documentBased: AppWindow.documentBased(info: info)) else { continue }
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", "-b", b]
            try? open.run(); open.waitUntilExit()
            for _ in 0..<30 where windows() == 0 { Thread.sleep(forTimeInterval: 0.1) }
            NSLog("DeskMind Hands: \(b) ran with no window; reopened it (\(windows()) now)")
        }
    }

    /// Stop the run: the main app's Stop, or the live view's.
    static func requestStop() {
        if busy { cancelled = true }
        stopRequested = true
        current?.terminate()
    }

    /// Hand the user's answer to the question the running `hands do` asked. One JSON line on its stdin, which is
    /// what it blocks on: {"reply": "...", "approve": true}.
    static func answer(reply: String, approve: Bool) -> Bool {
        answerLock.lock(); defer { answerLock.unlock() }
        guard asking, let h = answers,
              var line = try? JSONSerialization.data(withJSONObject: ["reply": reply, "approve": approve]) else { return false }
        line.append(0x0A)
        do { try h.write(contentsOf: line) } catch { return false }
        asking = false
        return true
    }

    static func run(_ spec: Spec, emit unlocked: @escaping ([String: Any]) -> Bool) {
        // Two threads emit during a run -- the trace poller and the stdout reader that sees questions -- and their
        // lines must not interleave on the one socket.
        let emitLock = NSLock()
        let emit: ([String: Any]) -> Bool = { e in emitLock.lock(); defer { emitLock.unlock() }; return unlocked(e) }
        busy = true; cancelled = false
        defer { busy = false }
        let set = spec.set
        if spec.real && spec.planner == BrainServer.url && BrainServer.status()["state"] as? String != "ready" {
            BrainServer.ensure()
            // Loading (the first run after a restart): wait for it, and say so, rather than send the user back to
            // try again in a moment. Missing or failed models are said at once, as before.
            if BrainServer.status()["state"] as? String == "loading" {
                _ = emit(["event": "preparing", "what": "brain"])
                let until = Date().addingTimeInterval(180)
                while BrainServer.status()["state"] as? String == "loading" && Date() < until && !cancelled {
                    Thread.sleep(forTimeInterval: 0.5)
                }
                if cancelled {
                    _ = emit(["event": "done", "exit": 0, "reason": "cancelled", "passed": 0, "total": 0, "stderr_tail": ""])
                    return
                }
            }
        }
        if spec.real && spec.planner == BrainServer.url && BrainServer.status()["state"] as? String != "ready" {
            // "code" lets the main app show this one as it is, whatever the language.
            _ = emit(["event": "error", "code": "brain_not_ready",
                      "error": L("The local model isn't ready yet (%@). Please try again in a moment.",
                                 "\(BrainServer.status()["state"] ?? "?")", lang: ResolvedLang.current)])
            return
        }
        do { try prepareWork() } catch {
            _ = emit(["event": "error", "error": "prepare: \(error.localizedDescription)"]); return
        }
        let runs = work.appendingPathComponent("runs")
        let fm = FileManager.default
        let before = Set((try? fm.contentsOfDirectory(atPath: runs.path)) ?? [])
        lastRunDir = nil
        let textEditWasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").isEmpty

        let p = Process()
        p.executableURL = runtime.appendingPathComponent("python/bin/python3.12")
        // Screenshots kept: each step shows what the agent was looking at. They are window captures of the sandbox
        // window only, stay on this Mac, and only the last few runs are kept (see pruneRuns).
        var args = ["-m", "deskmind_hands.cli", "run", "--set", set, "--repeats", "1"]
        if let t = spec.task { args += ["--task", t] }
        if let goal = spec.goal {
            // The user's own instruction. File work only inside the attached folder, if any (hands also refuses a
            // home or system root); apps only the ones the instruction named and the user confirmed.
            args = ["-m", "deskmind_hands.cli", "do", goal]
            if let folder = spec.folder { args += ["--in", folder] }
            args += ["--app", spec.apps.first?.bundle ?? "com.apple.finder"]
            if !spec.apps.isEmpty { args += ["--apps", spec.apps.map { "\($0.name)=\($0.bundle)" }.joined(separator: ",")] }
            if spec.foregroundOK { args += ["--foreground-ok"] }
            // Questions and approvals come to the user through the app, never a terminal prompt (see answer()).
            args += ["--ask", "stdin",
                     "--adapter", "systemone", "--systemone-url", spec.planner, "--model", spec.model,
                     "--max-actions", "40", "--minutes", "30", "--yes"]   // 30: time spent waiting for the user counts
        } else if spec.real {
            args += ["--driver", "peekaboo", "--adapter", "systemone", "--systemone-url", spec.planner,
                     "--model", spec.model]
        } else {
            args += ["--adapter", "oracle"]
        }
        // The vision model, when it is downloaded and the run may drive an app with no accessibility tree. Loaded
        // before the run starts (a few seconds from disk), so the first vision step does not find it still loading.
        var eyesURL: String? = nil
        if spec.mayNeedVision && DeskMindModels.eyesDir() != nil {
            warmOCR()   // alongside the vision model's loading, not after it
            EyesServer.ensure()
            _ = emit(["event": "preparing", "what": "eyes"])
            _ = EyesServer.waitReady(timeout: 90)
            eyesURL = EyesServer.url
            if cancelled {
                _ = emit(["event": "done", "exit": 0, "reason": "cancelled", "passed": 0, "total": 0, "stderr_tail": ""])
                return
            }
        }
        if spec.goal != nil { reopenWindowless(spec.apps.map(\.bundle)) }
        p.arguments = args
        p.currentDirectoryURL = work
        var env = [
            "HOME": NSHomeDirectory(),
            // Peekaboo from this bundle, and nothing from the user's PATH.
            "PATH": "\(runtime.appendingPathComponent("bin").path):/usr/bin:/bin",
            "HANDS_PEEKABOO_TRANSPORT": "mcp", "HANDS_PROJECTION": "1", "HANDS_TRACK_GOAL": "1",
            // This helper checked Screen Recording itself (Peekaboo runs as its child, same TCC identity).
            "HANDS_PERMISSIONS_VERIFIED": CGPreflightScreenCaptureAccess() ? "1" : "0",
            "PYTHONPATH": "\(work.path):\(runtime.appendingPathComponent("site").path)",
            // Bytecode cached outside the signed bundle: without it every run recompiled deskmind-hands.
            "PYTHONNOUSERSITE": "1", "PYTHONUNBUFFERED": "1",
            "PYTHONPYCACHEPREFIX": DeskMindIPC.supportDir.appendingPathComponent("pycache").path,
        ]
        if let eyesURL { env["HANDS_GROUNDER_URL"] = eyesURL; env["HANDS_GROUNDER_TOKEN"] = ServerAuth.token }
        // The app's own Brain answers only with its token (ServerAuth); a planner configured elsewhere never gets it.
        if spec.planner == BrainServer.url { env["SYSTEMONE_API_KEY"] = ServerAuth.token }
        // A person using their Mac is not a failure: a step that needs the front waits for them (up to 30 min,
        // within the run's own time limit) instead of giving up after a minute, and the app says it is paused.
        env["HANDS_FLASH_WAIT_S"] = "1800"
        // Someone looking at DeskMind's own window is watching the run, not working: no long wait for them.
        // The helper's live view never takes the front, but a click on it would make the helper the front app.
        env["HANDS_SPECTATOR_APPS"] = "ai.deskmind.app,ai.deskmind.hands"
        // "Let DeskMind use it for a while" writes the end time here (see takeOver()); hands then does not wait.
        env["HANDS_TAKEOVER_FILE"] = Runner.takeoverFile.path
        // Before a run may finish, the goal's own words are checked against what the run did (hands done_check.py): a
        // file written and not saved, rows the goal asks for not all written, a window it says to close still open.
        // G18b said DONE on D1en with parts.csv still open 5 times of 5 (10-01); with the check it closed it 3 of 3.
        env["HANDS_DONE_CHECK"] = "1"
        p.environment = env
        // stdout is read line by line for HANDS_ASK questions (a pipe, drained continuously, so it never fills) and
        // kept in a file for the details; stdin stays open for the answers.
        let outPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardInput = inPipe
        let outURL = DeskMindIPC.supportDir.appendingPathComponent("work/last-run.stdout")
        fm.createFile(atPath: outURL.path, contents: nil)
        let outLog = try? FileHandle(forWritingTo: outURL)
        // stderr to a file, not a pipe: a chatty run must never block on a full pipe buffer.
        let errURL = DeskMindIPC.supportDir.appendingPathComponent("work/last-run.stderr")
        fm.createFile(atPath: errURL.path, contents: nil)
        p.standardError = try? FileHandle(forWritingTo: errURL)
        do { try p.run() } catch {
            _ = emit(["event": "error", "error": "launch: \(error.localizedDescription)"]); return
        }
        current = p; Runner.stopRequested = false
        answerLock.lock(); answers = inPipe.fileHandleForWriting; asking = false; answerLock.unlock()
        _ = emit(["event": "start", "set": set, "real": spec.real, "pid": Int(p.processIdentifier)])
        // The live view, for the user's own instructions: until the run ends, however it ends.
        if spec.liveView && spec.goal != nil {
            LiveCard.start(bundles: spec.apps.isEmpty ? ["com.apple.finder"] : spec.apps.map(\.bundle),
                           goal: spec.goal ?? "", onStop: Runner.requestStop)
        }
        defer { LiveCard.finish(nil) }

        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async {
            defer { reader.leave() }
            let h = outPipe.fileHandleForReading
            var pending = Data()
            while true {
                let chunk = h.availableData
                if chunk.isEmpty { break }   // EOF: the child exited
                try? outLog?.write(contentsOf: chunk)
                pending.append(chunk)
                while let nl = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...nl)
                    if line.hasPrefix("HANDS_WAIT") {
                        // {"reason", "app", "what"}: what the paused step will do, so the app can say it.
                        let info = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(11).utf8))) as? [String: Any]
                        _ = emit(["event": "waiting", "what": info?["what"] as? String ?? "",
                                  "app": info?["app"] as? String ?? ""])
                        LiveCard.status(.paused, words: L("Paused while you use your Mac", lang: ResolvedLang.current))
                        continue
                    }
                    if line.hasPrefix("HANDS_RESUME") { _ = emit(["event": "resumed"]); LiveCard.status(.working); continue }
                    guard line.hasPrefix("HANDS_ASK "),
                          let q = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(10).utf8))) as? [String: Any]
                    else { continue }
                    answerLock.lock(); asking = true; answerLock.unlock()
                    LiveCard.status(.waitingForUser, words: q["approval"] as? Bool == true
                                    ? L("Waiting for your approval in DeskMind", lang: ResolvedLang.current)
                                    : L("Waiting for your answer in DeskMind", lang: ResolvedLang.current))
                    // "options": the alternatives the question lists (hands' ambiguity), answers the user can click.
                    _ = emit(["event": "ask", "question": q["question"] as? String ?? "",
                              "approval": q["approval"] as? Bool ?? false, "options": q["options"] as? [String] ?? []])
                }
            }
        }

        var offsets: [String: UInt64] = [:]
        var currentApp = ""
        var announced = Set<String>()
        var passed = 0, total = 0
        var freeState = ""   // how a free-form run ended, from its summary
        var freeFailure = "" // and why, when it did not finish (hands' failure class)
        var answer = ""      // a question's answer: the DONE that ended the run, "answer: …"
        var listening = true

        func poll() {
            guard let dir = ((try? fm.contentsOfDirectory(atPath: runs.path)) ?? []).filter({ !before.contains($0) })
                .sorted().last else { return }
            let runDir = runs.appendingPathComponent(dir)
            if lastRunDir != runDir {
                // deskmind-hands has started and made its run folder: from here it is looking at the screen and
                // choosing its first step. The trace's first line comes only once that step is taken, so waiting for
                // it left the whole first look under "starting".
                listening = listening && emit(["event": "preparing", "what": "looking"])
            }
            lastRunDir = runDir
            // A set run keeps one folder per task; a `do` run keeps its one trace in the run folder itself.
            let taskDirs = fm.fileExists(atPath: runDir.appendingPathComponent("trace.jsonl").path) ? [""]
                : ((try? fm.contentsOfDirectory(atPath: runDir.path)) ?? []).sorted()
            for td in taskDirs {
                let trace = runDir.appendingPathComponent(td).appendingPathComponent("trace.jsonl")
                guard let h = try? FileHandle(forReadingFrom: trace) else { continue }
                defer { try? h.close() }
                let off = offsets[td] ?? 0
                try? h.seek(toOffset: off)
                let data = h.readDataToEndOfFile()
                // Only whole lines: the writer may be mid-line.
                guard let lastNL = data.lastIndex(of: 0x0A) else { continue }
                offsets[td] = off + UInt64(lastNL - data.startIndex + 1)
                for line in data[data.startIndex...lastNL].split(separator: 0x0A) {
                    guard let e = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                          let t = e["t"] as? String else { continue }
                    let taskID = td.isEmpty ? "do" : td.replacingOccurrences(of: #"-r\d+$"#, with: "", options: .regularExpression)
                    if !announced.contains(td) {
                        announced.insert(td)
                        listening = listening && emit(["event": "task", "task": taskID,
                                                       "title": spec.goal ?? title(of: taskID, set: set)])
                    }
                    if t == "obs", let app = e["focused_app"] as? String, !app.isEmpty {
                        currentApp = app
                    }
                    if t == "obs" {
                        LiveCard.observed(windows: e["windows"] as? [[String: Any]] ?? [], app: e["focused_app"] as? String ?? "")
                    }
                    if t == "step" {
                        let kind = (e["kind"] as? String) ?? ""
                        if kind == "done", let text = e["text"] as? String, text.hasPrefix("answer: ") {
                            answer = String(text.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        // A question and its reply: said in the step itself, since the trace has no "detail" for it.
                        let dialogue = ["ask_user", "request_approval"].contains(kind)
                            ? [e["question"] as? String, (e["reply"] as? String).map { "→ \($0)" }].compactMap { $0 }
                                .joined(separator: " ")
                            : nil
                        let acted = (e["action"] as? [String: Any])?["kind"] as? String ?? kind
                        LiveCard.stepped(n: e["n"] as? Int ?? 0, words: humanize(e), target: e["target_rect"],
                                         click: ["click", "double_click", "select"].contains(acted))
                        listening = listening && emit([
                            "event": "step", "task": taskID, "n": e["n"] ?? 0,
                            "describe": e["describe"] ?? (kind.isEmpty ? "step" : kind),
                            "human": humanize(e), "app": currentApp,
                            "shot": (e["obs"] as? String).map {
                                runDir.appendingPathComponent(td).appendingPathComponent("obs/\($0).png").path
                            } ?? "",
                            "detail": dialogue ?? e["detail"] ?? "", "ok": e["ok"] ?? true,
                            // For the decision panel: hands' decision record (top operations, routing) and target.
                            "decision": e["decision"] ?? "", "target": e["target_label"] ?? "",
                            "latency": e["latency_s"] ?? 0,
                        ])
                    } else if t == "summary" {
                        let grade = e["grade"] as? [String: Any] ?? [:]
                        let strict = grade["strict"] as? Bool ?? false
                        total += 1; if strict { passed += 1 }
                        // A free-form run has no grader: what it did is its change list (with a folder) or its
                        // answer (a question), and the user judges.
                        if spec.goal != nil {
                            let ch = e["changes"] as? [String: Any] ?? [:]
                            freeState = (e["state"] as? String) ?? ""
                            freeFailure = ((e["failure"] as? [String: Any])?["class"] as? String) ?? ""
                            let done = freeState == "completed"
                            total = 1; passed = done ? 1 : 0
                            listening = listening && emit(["event": "task_done", "task": taskID, "strict": done,
                                                           "state": e["state"] ?? "", "free": true,
                                                           "reason": freeFailure, "answer": answer,
                                                           "has_folder": spec.folder != nil,
                                                           "created": ch["created"] ?? [], "modified": ch["modified"] ?? [],
                                                           "deleted": ch["deleted"] ?? []])
                            continue
                        }
                        listening = listening && emit(["event": "task_done", "task": taskID, "strict": strict,
                                                       "state": e["state"] ?? ""])
                    }
                }
            }
        }

        while p.isRunning {
            poll()
            Thread.sleep(forTimeInterval: 0.25)
        }
        poll()
        // Bounded: a grandchild that inherited stdout (Peekaboo's server) could hold the pipe open past hands' exit.
        _ = reader.wait(timeout: .now() + 3)
        try? outLog?.close()
        answerLock.lock(); answers = nil; asking = false; answerLock.unlock()
        try? inPipe.fileHandleForWriting.close()
        if eyesURL != nil { EyesServer.touch() }   // the idle clock starts when the run ends
        // Before the clean-up closes the run's windows: how it ended, for a moment, on its last picture.
        LiveCard.finish(Runner.stopRequested ? .stopped : freeState == "completed" ? .done : .failed)
        cleanUp(quitTextEdit: !textEditWasRunning)
        pruneRuns(keep: 10)
        current = nil
        // hands says some refusals on stdout ("refused: … is your home directory"): its tail too, when stderr is quiet.
        let errTail = String(decoding: ((try? Data(contentsOf: errURL)) ?? Data()).suffix(600), as: UTF8.self)
        let tail = errTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(decoding: ((try? Data(contentsOf: outURL)) ?? Data()).suffix(600), as: UTF8.self) : errTail
        // `hands do` exits 1 whenever the run did not complete. For a free-form run that stopped on its own (gave
        // up, ran out of steps) that is a result, not an error: the change list is what the user needs to see. A run
        // that errored (Finder never opened, the planner was unreachable) is an error, with its details.
        // Stuck (the same step failing again and again) ends as "errored" in hands, but it is the model giving up
        // on the task, not the run breaking: the user needs "it got stuck", not "send us the details".
        let ranToAnEnd = ["completed", "gave_up", "budget_exhausted", "cancelled"].contains(freeState)
            || (freeState == "errored" && freeFailure == "no_progress_loop")
        if Runner.stopRequested { freeState = "cancelled" }
        Runner.stopRequested = false
        let exitCode = spec.goal != nil && (ranToAnEnd || freeState == "cancelled") ? 0 : Int(p.terminationStatus)
        _ = emit(["event": "done", "exit": exitCode, "reason": freeFailure, "passed": passed, "total": total,
                  "answer": answer,
                  "stderr_tail": p.terminationStatus == 0 ? "" : tail])
    }
}
