// A goal's island, notifications and recent-runs record, as the app applies them (M2, PR B) — here, with what only
// the app has (RunOverlay, RunRecorder, RunHistory) behind two small protocols, so the tests run the same applier and
// the same GoalRunEffects closures the app does (#119 review at 3795dcf).
//
// - IslandApplier: a goal's frames (IslandFeed.frame(goal)) to an IslandSurface — show once, then step / line /
//   asking as they change, finish once; the record "Show Details" opens is part of the frame and is set after `show`
//   (which clears the last one), so a task that starts and ends in one update keeps its link.
// - GoalRunEffects.app: the recording, the record (once), the deadlines, the island — kept with the goal.

import Foundation

/// The island and notifications (the app: RunOverlay; a test: its own).
protocol IslandSurface: AnyObject {
    /// The goal whose frames it takes: the active one, else the one that ended last (Codex review at 2b46101: an
    /// ended goal's late frame set the link back to it while the island showed the next one).
    var owner: ObjectIdentifier? { get set }
    func requestNotifications()
    /// Shown for a new task: the last task's details link goes.
    func show(title: String, line: String, onStop: @escaping () -> Void)
    func update(step: Int, line: String)
    func setAsking(_ on: Bool)
    func finish(passed: Bool, stopped: Bool, summary: String)
    func notify(title: String, body: String)
    /// The recent-runs record its "Show Details" opens.
    var detailsRecord: UUID? { get set }
    var appActive: Bool { get }
    var userTyping: Bool { get }
}

/// A goal's frames applied to the surface: what changed, once each.
final class IslandApplier {
    private let surface: IslandSurface
    private var last: IslandFrame?
    private var shown = false
    private var finished = false

    init(_ surface: IslandSurface) { self.surface = surface }

    func apply(_ f: IslandFrame, title: String, lang: ResolvedLang, onStop: @escaping () -> Void) {
        let o = surface
        if !shown {
            shown = true
            o.requestNotifications()
            o.show(title: title.count > 40 ? String(title.prefix(39)) + "…" : title, line: f.line, onStop: onStop)
        }
        // (after `show`, which clears it: the frame's own link, whatever order its record and its first frame came in)
        if let r = f.detailsRecord, o.detailsRecord != r { o.detailsRecord = r }
        if let n = IslandFeed.cardNotification(from: last, to: f, appActive: o.appActive, userTyping: o.userTyping, lang: lang) {
            o.notify(title: n.title, body: n.body)
        }
        switch f.phase {
        case .running:
            if f.step != last?.step || f.line != last?.line { o.update(step: f.step, line: f.line) }
            if f.asking != last?.asking { o.setAsking(f.asking) }
        case .ended(let passed, let stopped):
            guard !finished else { break }
            finished = true
            o.setAsking(false)
            o.finish(passed: passed, stopped: stopped, summary: f.line)
        }
        last = f
    }
}

/// What the app keeps of a goal (the app: RunRecorder and RunHistory; a test: its own).
