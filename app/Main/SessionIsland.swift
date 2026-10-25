// The app's side of the chat island (Shared/GoalIsland.swift's IslandSurface): RunOverlay, which the float's
// ChatIslandSurface drives (Main/FloatPanel.swift).

import AppKit

/// RunOverlay, as the island a goal's frames are applied to. (Called on the main queue: GoalRun runs there.)
final class RunOverlaySurface: IslandSurface {
    static let shared = RunOverlaySurface()
    var owner: ObjectIdentifier?

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
