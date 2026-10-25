// Recording a run: the whole screen is recorded to a movie while the task runs, with a small decision panel on
// screen that says what the agent chose at each step and how sure it was -- so the recording shows what it did and
// why.
//
// The helper records (Helper/ScreenRecorder.swift): it holds the Screen Recording permission, which this app does
// not. The system's content-sharing picker, which needs no permission, asked "this window or the whole screen?"
// before every recorded run, over a lilac-tinted screen that read as broken. Movies go to ~/Movies/DeskMind.

import AppKit
import SwiftUI

@MainActor
final class RunRecorder {
    static let shared = RunRecorder()

    /// The View menu's two recording settings: DeskMind's own window in the recording (off: the island and panels
    /// only), and the whole screen instead of the task's apps (off: other apps are left out).
    static let includeMainKey = "record.includeMainWindow"
    static let wholeScreenKey = "record.wholeScreen"
    /// 30 fps from a capture stream, for footage where motion matters; it slows decisions (ScreenRecorder).
    static let smoothKey = "record.smooth"

    /// Where a run's recording goes: ~/Movies/DeskMind/<date time> <start of the instruction>/ (see ScreenRecorder).
    static func folderURL(goal: String) -> URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskMind", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(MovieName.folder(goal: goal, date: Date()), isDirectory: true)
    }

    /// The run the helper was asked to record, until its task is over or the app cancels it (the app's quit tells the
    /// helper to stop it).
    private(set) var run: String?
    var busy: Bool { run != nil }

    /// Ask the helper to record `run`'s task (of `session`): the apps it works in (its steps add them), into
    /// Movies › DeskMind. The helper owns it from here (RecordingOwner): it stops when that run ends. `started(false)`:
    /// it said no (no Screen Recording); no answer at all is taken as recording -- the run's end stops it anyway.
    func begin(goal: String, run: String, session: String, started: @escaping (Bool) -> Void) {
        self.run = run
        let url = Self.folderURL(goal: goal)
        let body: [String: Any] = ["op": "record_start", "path": url.path, "bundles": [String](), "goal": goal,
                                   "for_run": run, "session_id": session,
                                   "include_main": UserDefaults.standard.bool(forKey: Self.includeMainKey),
                                   "whole_screen": UserDefaults.standard.bool(forKey: Self.wholeScreenKey),
                                   "smooth": UserDefaults.standard.bool(forKey: Self.smoothKey)]
        DispatchQueue.global().async {
            let reply = DeskMindIPC.request(body, timeout: 25)
            let refused = reply != nil && reply?["ok"] as? Bool != true
            DispatchQueue.main.async {
                if refused, self.run == run { self.run = nil }
                started(!refused)
            }
        }
    }

    /// Ask the helper to stop recording `run`: asked again, waiting longer each time, until it answers (it stops at
    /// once and answers at once; asking when nothing records is harmless).
    func cancel(_ run: String) {
        if self.run == run { self.run = nil }
        DispatchQueue.global().async {
            var wait = 1.0
            for _ in 0..<8 {
                if DeskMindIPC.request(["op": "record_stop", "for_run": run], timeout: 5) != nil { return }
                Thread.sleep(forTimeInterval: wait); wait = min(wait * 2, 30)
            }
        }
    }

    /// The task is over (the helper stopped its recording): the movie, once the helper has made it, from the run's
    /// folder (recording.json) -- looked for every few seconds, for as long as a long movie takes.
    func awaitMovie(run: String, session: String, saved: @escaping (URL) -> Void) {
        if self.run == run { self.run = nil }
        guard let folder = RunDir.folder(session: session, run: run) else { return }
        let file = folder.appendingPathComponent(RecordingOwner.savedFile)
        DispatchQueue.global(qos: .utility).async {
            for _ in 0..<(3 * 3600 / 3) {
                if let d = try? Data(contentsOf: file), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                   let path = o["path"] as? String {
                    DispatchQueue.main.async { saved(URL(fileURLWithPath: path)) }
                    return
                }
                Thread.sleep(forTimeInterval: 3)
            }
        }
    }
}

/// A chat task's recording (Shared/TaskRecording.swift): RunRecorder through the helper, with the decision panel
/// on screen while it records (non-activating, as it always was: it is what a demo shows).
final class AppTaskRecorder: TaskRecorder {
    func start(goal: String, run: String, session: String, started: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            DecisionPanel.shared.show()
            RunRecorder.shared.begin(goal: goal, run: run, session: session) { ok in
                if !ok { DecisionPanel.shared.hide() }
                started(ok)
            }
        }
    }
    func cancel(run: String) { MainActor.assumeIsolated { RunRecorder.shared.cancel(run) } }
    func ended(run: String, session: String, saved: @escaping (URL) -> Void) {
        MainActor.assumeIsolated {
            DecisionPanel.shared.hide(after: 2)
            RunRecorder.shared.awaitMovie(run: run, session: session, saved: saved)
        }
    }
    func step(_ n: Int, _ words: String) { MainActor.assumeIsolated { DecisionPanel.shared.update(n: n, words: words) } }
}

// MARK: - The decision panel

/// One step as the planner decided it: the operation and target, its three likeliest operations, which model
/// answered (the 0.8B, or the 4B and why it was asked), and how long the step took end to end.
@MainActor
final class DecisionModel: ObservableObject {
    @Published var n = 0
    @Published var headline = ""
    @Published var top: [(String, Double)] = []
    @Published var tier = ""
    @Published var ms = 0
    @Published var question = ""
    @Published var answer = ""
}

@MainActor
final class DecisionPanel {
    static let shared = DecisionPanel()
    let model = DecisionModel()
    private var panel: NSPanel?
    /// Which run the panel is showing: a hide scheduled at the end of one run leaves the next one's panel alone.
    private(set) var generation = 0

    /// Shown only when the user asked for it (View › Show Decisions While Running); not in recordings by default.
    static let alwaysKey = "decisions.always"
    static var always: Bool {
        get { UserDefaults.standard.bool(forKey: alwaysKey) }
        set { UserDefaults.standard.set(newValue, forKey: alwaysKey) }
    }

    func show() {
        model.n = 0; model.headline = L("Getting ready…", lang: ResolvedLang.current); model.top = []
        model.tier = ""; model.ms = 0; model.question = ""; model.answer = ""
        generation += 1
        if panel == nil {
            let host = NSHostingView(rootView: LocalizedRoot { DecisionView(model: model) })
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 150)
            let p = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.contentView = host
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.isMovableByWindowBackground = true
            panel = p
        }
        if let p = panel, let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - p.frame.width - 16, y: f.maxY - p.frame.height - 80))
            Activation.showPanel(p)
        }
    }

    func hide() { panel?.orderOut(nil) }

    /// Hide in a moment, unless another run has shown the panel since.
    func hide(after seconds: Double) {
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.generation == g else { return }
            self.hide()
        }
    }

    /// A chat task's step: its number and its words (the protocol says no model's scores for it).
    func update(n: Int, words: String) {
        guard panel?.isVisible == true else { return }
        model.n = n; model.headline = words; model.top = []; model.tier = ""; model.ms = 0; model.question = ""; model.answer = ""
    }

    /// A step event from the helper: its "decision" record (hands' JSON: top, operation, routing), its target.
    func update(step e: [String: Any]) {
        guard panel?.isVisible == true else { return }
        let d = DecisionStep.parse(e, lang: ResolvedLang.current, previous: model.n)
        model.n = d.n; model.headline = d.headline; model.top = d.top.map { ($0.name, $0.p) }
        model.tier = d.tier; model.ms = d.ms; model.question = d.question; model.answer = d.answer
    }
}

struct DecisionView: View {
    @ObservedObject var model: DecisionModel
    @Environment(\.lang) private var lang

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                Text(L("Step %d", model.n, lang: lang)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if model.ms > 0 {
                    Text(L("decided in %d ms", model.ms, lang: lang)).font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(model.headline).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(2)
            ForEach(Array(model.top.enumerated()), id: \.offset) { i, item in
                HStack(spacing: 6) {
                    Text(item.0).font(.system(size: 11)).frame(width: 46, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(i == 0 ? Brand.dot : Color.primary.opacity(0.28))
                                .frame(width: max(3, g.size.width * item.1))
                        }
                    }
                    .frame(height: 6)
                    Text(String(format: "%.0f%%", item.1 * 100)).font(.system(size: 10).monospacedDigit())
                        .frame(width: 34, alignment: .trailing).foregroundStyle(.secondary)
                }
            }
            if !model.tier.isEmpty {
                Text(model.tier).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            if !model.question.isEmpty {
                Text("? " + model.question).font(.system(size: 11)).lineLimit(2)
                if !model.answer.isEmpty { Text("→ " + model.answer).font(.system(size: 11, weight: .medium)).lineLimit(1) }
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
    }
}
