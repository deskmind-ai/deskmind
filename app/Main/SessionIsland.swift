// The app's side of a goal's island and record (Shared/GoalIsland.swift): RunOverlay as the IslandSurface, and
// RunRecorder / RunHistory as the GoalRunServices. Its "Show Details" opens GoalRunView on that task
// (RunOverlay.detailsRecord: its recent-runs record, which keeps the session and run).

import AppKit

/// RunOverlay, as the island a goal's frames are applied to. (Called on the main queue: GoalRun runs there.)
final class RunOverlaySurface: IslandSurface {
    static let shared = RunOverlaySurface()

    func requestNotifications() { MainActor.assumeIsolated { RunOverlay.requestNotificationPermission() } }
    func show(title: String, line: String, onStop: @escaping () -> Void) {
        MainActor.assumeIsolated {
            let o = RunOverlay.shared
            o.onStop = { o.model.stoppedByUser = true; onStop() }
            o.show(title: title, line: line)
        }
    }
    func update(step: Int, line: String) { MainActor.assumeIsolated { RunOverlay.shared.update(app: "", step: step, line: line) } }
    func setAsking(_ on: Bool) { MainActor.assumeIsolated { RunOverlay.shared.setAsking(on) } }
    func finish(passed: Bool, stopped: Bool, summary: String) {
        MainActor.assumeIsolated {
            let o = RunOverlay.shared
            if stopped { o.model.stoppedByUser = true }
            o.finish(passed: passed, summary: summary)
        }
    }
    func notify(title: String, body: String) { MainActor.assumeIsolated { RunOverlay.notify(title: title, body: body) } }
    var detailsRecord: UUID? {
        get { MainActor.assumeIsolated { RunOverlay.shared.detailsRecord } }
        set { MainActor.assumeIsolated { RunOverlay.shared.detailsRecord = newValue } }
    }
    var appActive: Bool { MainActor.assumeIsolated { NSApp.isActive } }
    var userTyping: Bool { MainActor.assumeIsolated { MainWindow.userTypedRecently() } }
}

/// RunRecorder records (its begin's own 25 s bound); RunHistory keeps the record.
final class AppGoalServices: GoalRunServices {
    static let shared = AppGoalServices()

    func beginRecording(goal: String, started: @escaping () -> Void) {
        MainActor.assumeIsolated { RunRecorder.shared.begin(goal: goal, bundles: []) { _ in started() } }
    }
    func stopRecording(done: @escaping (URL?) -> Void) { MainActor.assumeIsolated { RunRecorder.shared.stop(done: done) } }
    func setMovie(_ path: String, for id: UUID) { MainActor.assumeIsolated { RunHistory.shared.setMovie(path, for: id) } }
    func keep(_ g: GoalRecord, id: UUID, lang: ResolvedLang) {
        MainActor.assumeIsolated {
            // (its outcome from the goal's lifecycle, as the island and the screen: GoalOutcome)
            let o = GoalOutcome.record(g, lang: lang)
            let t = o.task
            var r = RunRecord(
                id: id, date: Date(), goal: g.goal, folder: g.folder, apps: [],
                finished: o.finished, errored: o.errored,
                summary: o.summary,
                answer: t?.answer ?? "",
                steps: (t?.steps ?? []).map { RunRecord.Step(n: $0.n, human: $0.displayText, app: "", shot: $0.shot ?? "", describe: $0.text, detail: $0.why ?? "", ok: $0.status == .ok) },
                created: t?.changes.created ?? [], modified: t?.changes.modified ?? [], deleted: t?.changes.deleted ?? [],
                // (its session and run from the goal's ending, not from whether the task's lines have come: the saved
                // run reads its session by id and shows the task once its history lands)
                sessionId: g.runId == nil ? nil : g.sessionId, runId: g.runId)
            r.ended = g.ended
            RunHistory.shared.add(r)
        }
    }
}
