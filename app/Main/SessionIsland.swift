// A session task's island and notifications (M2, PR B): the frames of IslandFeed (Shared/IslandFeed.swift), from the
// task's one state, applied to RunOverlay — show once, then step / line / asking as they change, finish once at the
// end. Its "Show Details" opens GoalRunView on that task (RunOverlay.onDetailsRecord: its recent-runs record, which
// keeps the session and run).

import AppKit

@MainActor
final class SessionIsland {
    private var last: IslandFrame?
    private var shown = false
    private var finished = false

    /// The task's new frame: what changed goes to the island (and a notification for a card that newly waits).
    func apply(_ f: IslandFrame, title: String, onStop: @escaping () -> Void) {
        let o = RunOverlay.shared
        if !shown {
            shown = true
            RunOverlay.requestNotificationPermission()
            o.onStop = { o.model.stoppedByUser = true; onStop() }
            o.show(title: title.count > 40 ? String(title.prefix(39)) + "…" : title, line: f.line)
        }
        if let n = IslandFeed.cardNotification(from: last, to: f, appActive: NSApp.isActive, userTyping: MainWindow.userTypedRecently(), lang: ResolvedLang.current) {
            RunOverlay.notify(title: n.title, body: n.body)
        }
        switch f.phase {
        case .running:
            if f.step != last?.step || f.line != last?.line { o.update(app: "", step: f.step, line: f.line) }
            if f.asking != last?.asking { o.setAsking(f.asking) }
        case .ended(let passed, let stopped):
            guard !finished else { break }
            finished = true
            o.setAsking(false)
            if stopped { o.model.stoppedByUser = true }
            o.finish(passed: passed, summary: f.line)
        }
        last = f
    }
}
