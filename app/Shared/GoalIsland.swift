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
protocol GoalRunServices: AnyObject {
    func beginRecording(goal: String, started: @escaping () -> Void)
    func stopRecording(done: @escaping (URL?) -> Void)
    /// The recent-runs record, kept as `id`.
    func keep(_ r: GoalRecord, id: UUID, lang: ResolvedLang)
    func setMovie(_ path: String, for id: UUID)
}

extension GoalRunEffects {
    /// The app's effects for one goal: its recording, its record (once, as `id`), its deadlines, its island.
    static func app(lang: ResolvedLang, services: GoalRunServices, surface: IslandSurface,
                    after: @escaping (Double, @escaping () -> Void) -> Void) -> GoalRunEffects {
        let id = UUID()
        final class Kept { var record: UUID? }
        let kept = Kept()
        let island = IslandApplier(surface)
        return GoalRunEffects(
            beginRecording: { goal, started in services.beginRecording(goal: goal, started: started) },
            stopRecording: { _, done in
                services.stopRecording { url in
                    if let url { services.setMovie(url.path, for: id) }
                    done(url)
                }
            },
            writeRecord: { g in
                services.keep(g, id: id, lang: lang)
                // the island's Show Details opens this task's GoalRunView (its record keeps the session and the run)
                if g.task != nil { kept.record = id }
            },
            after: after,
            changed: { g in
                guard let f = IslandFeed.frame(g, record: kept.record, lang: lang) else { return }
                island.apply(f, title: g.goal, lang: lang, onStop: { [weak g] in g?.stop() })
            })
    }
}

/// A past session task opened from the recent runs: its task as its session has it, or nil — the session or the task
/// gone (deleted) — and then the record's own content is shown.
enum PastRun {
    static func task(sessionId: String, runId: String?, in states: [String: SessionState]) -> (session: SessionState, task: TaskState)? {
        guard let s = states[sessionId] else { return nil }
        if let r = runId { return s.task(r).map { (s, $0) } }
        return s.tasks.last.map { (s, $0) }
    }
}
