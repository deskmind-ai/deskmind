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
    private(set) var fileURL: URL?

    var isRecording: Bool { fileURL != nil }
    /// Recording, or a start or a stop not confirmed (the app's quit sends record_stop for any of them).
    var busy: Bool { gate.busy }

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

    /// The start / stop across the helper's slow answers (RecorderGate: a stop while the start is on its way is owed;
    /// a start whose answer was lost keeps the stop owed until the helper confirms).
    private var gate = RecorderGate()
    private var owedDone: ((URL?) -> Void)?

    /// Start recording the task's apps (`bundles`; the session's steps add theirs). `forRun`: the task it is for (the
    /// helper takes it while that task holds the computer). `started(true)` once recording; false if it could not
    /// start (no Screen Recording for the helper, the helper away, a stop came first) -- the task goes ahead either way.
    func begin(goal: String, bundles: [String], forRun: String? = nil, started: @escaping (Bool) -> Void) {
        guard gate.apply(.begin) == [.start] else { started(gate.state == .recording); return }
        let url = Self.folderURL(goal: goal)
        var body: [String: Any] = ["op": "record_start", "path": url.path, "bundles": bundles, "goal": goal,
                                   "include_main": UserDefaults.standard.bool(forKey: Self.includeMainKey),
                                   "whole_screen": UserDefaults.standard.bool(forKey: Self.wholeScreenKey),
                                   "smooth": UserDefaults.standard.bool(forKey: Self.smoothKey)]
        if let forRun { body["for_run"] = forRun }
        DispatchQueue.global().async {
            let reply = DeskMindIPC.request(body, timeout: 25)
            // ok, refused (the helper said no), or unknown (no answer: it may be recording -- the stop stays owed)
            let answer: RecorderGate.Answer = reply == nil ? .unknown : reply?["ok"] as? Bool == true ? .ok : .refused
            DispatchQueue.main.async {
                let sends = self.gate.apply(.answered(answer))
                if sends == [.stop] {
                    // (a stop came while the start was on its way: stopped at once, its movie to whoever stopped)
                    let done = self.owedDone; self.owedDone = nil
                    self.sendStop(done ?? { _ in })
                } else if self.gate.state == .recording {
                    self.fileURL = url
                } else if let done = self.owedDone {
                    self.owedDone = nil; done(nil)
                }
                // (unknown: taken as recording -- the task's end still stops it)
                started(self.gate.state == .recording)
            }
        }
    }

    /// Stop and finish the recording; `done` gets the movie to show (nil if nothing was recorded). A start still on its
    /// way: owed -- stopped as soon as it answers. A stop not yet confirmed: asked again. The helper makes the delivery
    /// copy and the step file first, which takes a while for a long run.
    func stop(done: @escaping (URL?) -> Void) {
        let wasStarting = { if case .starting = gate.state { return true }; return false }()
        let sends = gate.apply(.stop)
        if sends == [.stop] { fileURL = nil; sendStop(done); return }    // (handed over: never taken for the next run's)
        if wasStarting { owedDone = done; return }
        done(nil)
    }

    /// record_stop; its answer (any answer: the helper says what it stopped, or that nothing recorded) confirms it.
    private func sendStop(_ done: @escaping (URL?) -> Void) {
        DispatchQueue.global().async {
            let reply = DeskMindIPC.request(["op": "record_stop"], timeout: 900)
            let url = (reply?["path"] as? String).map { URL(fileURLWithPath: $0) }
            DispatchQueue.main.async {
                _ = self.gate.apply(.stopAnswered(confirmed: reply != nil))
                done(url)
            }
        }
    }
}

/// A chat task's recording (Shared/TaskRecording.swift): RunRecorder through the helper, with the decision panel
/// on screen while it records (non-activating, as it always was: it is what a demo shows).
final class AppTaskRecorder: TaskRecorder {
    func start(goal: String, run: String, started: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            DecisionPanel.shared.show()
            RunRecorder.shared.begin(goal: goal, bundles: [], forRun: run) { ok in
                if !ok { DecisionPanel.shared.hide() }
                started(ok)
            }
        }
    }
    func stop(done: @escaping (URL?) -> Void) {
        MainActor.assumeIsolated {
            RunRecorder.shared.stop { url in DecisionPanel.shared.hide(after: 2); done(url) }
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
