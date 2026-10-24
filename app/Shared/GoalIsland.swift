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
        final class Kept { var record: UUID?; var started = false }
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
                // a goal that starts: the island's link to an earlier goal's record goes (Show Details never opens it
                // over this one)
                if !kept.started, g.state != .idle { kept.started = true; surface.detailsRecord = nil }
                guard let f = IslandFeed.frame(g, record: kept.record, lang: lang) else { return }
                island.apply(f, title: g.goal, lang: lang, onStop: { [weak g] in g?.stop() })
            })
    }
}

/// A past session task opened from the recent runs: its task as its session has it, or nil — the session or the task
/// gone (deleted) — and then the record's own content is shown.
/// `endedAs`: how its goal ended (the record's), which wins over a task that does not say so yet.
enum PastRun {
    static func task(sessionId: String, runId: String?, endedAs: String?, in states: [String: SessionState]) -> (session: SessionState, task: TaskState)? {
        guard let s = states[sessionId] else { return nil }
        let t = runId.flatMap { s.task($0) } ?? (runId == nil ? s.tasks.last : nil)
        return t.map { (s, GoalOutcome.task($0, endedAs: endedAs)) }
    }
}

/// A goal's outcome, from its lifecycle (the island and the screen read the same state, GoalRunScreen /
/// IslandFeed.frame(goal)): the record and a shown task follow it too (#119 delta review at 49f1a36: a goal ended
/// on its session's exit while its task did not say so yet; its record said "Working · step N").
enum GoalOutcome {
    /// The task as its goal ended: one the goal ended (`endedAs`) that does not say so yet is shown ended with that
    /// status (no undo: its executor is not known to linger); one that says so, as it says.
    static func task(_ t: TaskState, endedAs status: String?) -> TaskState {
        guard let status, !t.ended else { return t }
        var t = t
        var e = SessionTaskEnd()
        e.runId = t.runId; e.status = status; e.undo = "none"
        t.end = e
        return t
    }

    /// The record's summary and outcome: an ended goal's from its status (its task's own words when it says it
    /// ended), a failed one's from why.
    static func record(_ r: GoalRecord, lang: ResolvedLang) -> (summary: String, finished: Bool, errored: Bool, task: TaskState?) {
        let t = r.task.map { task($0, endedAs: r.ended) }
        guard let status = r.ended else {
            return (t.map { ShellText.task($0, lang: lang) } ?? GoalRunScreen.why(r.failed ?? "", lang: lang), false, true, t)
        }
        return (t.map { ShellText.task($0, lang: lang) } ?? ShellText.ending(status, lang: lang),
                status == "succeeded", status == "interrupted" || status == "failed", t)
    }
}

/// Where a goal's screen comes from: a goal started here (live), a saved record of a session task, or no goal (another
/// one is not over).
enum GoalScreenRoute {
    case live(state: GoalLifecycle.State, task: (session: SessionState, task: TaskState)?, sessionId: String?, folder: String?, movie: URL?)
    case saved(sessionId: String, runId: String?, ended: String?, folder: String?, movie: String?)
    case busy
}

/// What a goal's screen shows — one value for every route, every field from it (Codex review at a8cec0f: the task,
/// the pinned card, the folder and the recording each came from a different source by route; an older run showed a
/// newer task's card, a saved run lost its folder and its recording).
struct GoalShown {
    /// The task shown (its session's), ended as its goal ended (GoalOutcome); nil: none yet, or gone.
    var session: SessionState?
    var task: TaskState?
    /// The pinned card shown under it: only the shown task's own (its run), and only while its session is the
    /// selected one (a card's click goes to the selected session).
    var pinned: (runId: String, card: CardState, phase: CardPhase)?
    var folder: String?
    var movie: URL?
    /// Stop, Back, the line, the ending: from the goal's lifecycle (a saved one: ended).
    var screen: GoalRunScreen
    /// The session task is shown; false: a saved run whose session or task is gone — its record's own content.
    var sessionShown: Bool

    static func of(_ route: GoalScreenRoute, states: [String: SessionState], selected: String?,
                   pinned: (SessionState) -> (runId: String, card: CardState, phase: CardPhase)?, lang: ResolvedLang) -> GoalShown {
        var v: GoalShown
        var sid: String?
        switch route {
        case .live(let state, let t, let id, let folder, let movie):
            var task = t
            if let (s, tk) = t, case .ended(_, _, let status) = state { task = (s, GoalOutcome.task(tk, endedAs: status)) }
            v = GoalShown(session: task?.session, task: task?.task, pinned: nil, folder: folder, movie: movie,
                          screen: GoalRunScreen(state, lang: lang), sessionShown: true)
            sid = id
        case .saved(let id, let run, let ended, let folder, let movie):
            let t = PastRun.task(sessionId: id, runId: run, endedAs: ended, in: states)
            v = GoalShown(session: t?.session, task: t?.task, pinned: nil, folder: folder, movie: movie.map { URL(fileURLWithPath: $0) },
                          screen: GoalRunScreen(.ended(sid: id, run: run ?? "", status: ended ?? ""), lang: lang), sessionShown: t != nil)
            sid = id
        case .busy:
            var s = GoalRunScreen(.failed(GoalLifecycle.Why.busy), lang: lang)
            s.line = GoalRunScreen.why(GoalLifecycle.Why.busy, lang: lang)
            return GoalShown(session: nil, task: nil, pinned: nil, folder: nil, movie: nil, screen: s, sessionShown: true)
        }
        if let s = v.session, let t = v.task, selected == sid, let p = pinned(s), p.runId == t.runId { v.pinned = p }
        return v
    }
}
