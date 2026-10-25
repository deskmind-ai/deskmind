// A chat task's island and notifications, as the app applies them: its frames (IslandFeed.frame) to an IslandSurface
// (the app: RunOverlay; a test: its own), so the tests run the same applier the app does.
//
// - IslandApplier: a task's frames to an IslandSurface -- show once, then step / line / asking as they change, finish
//   once.

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

