// M2 PR B: a session task's island and notifications come from its one state through IslandFeed — a table, session
// state → island frame and notification — and a goal's island follows its own task (GoalRun's `changed`), Show
// Details opens its record (IslandFeed.detailsRoute).
// Run from DecisionTests.main (build.sh).

import Foundation

enum IslandFeedTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "island: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("island.tableTests"); tableTests()
        DecisionTests.group("island.notifyTests"); notifyTests()
        DecisionTests.group("island.wiringTests"); wiringTests()
    }

    static let action = #""card":{"kind":"action","text":"要点「发送」吗？","options":[{"kind":"approve","text":"可以"},{"kind":"cancel","text":"先别做了"}],"free_text":false,"blocking":true}"#
    static let missing = #""card":{"kind":"missing","text":"发给谁？","options":[{"kind":"value","text":"小王"},{"kind":"cancel","text":"先别做了"}],"free_text":true,"blocking":true}"#

    static func task(_ body: [String]) -> (SessionState, TaskState) {
        var lines = [SessionTests.taskR1, SessionTests.ex(1, #""kind":"start","raw":"x""#)]
        for (i, b) in body.enumerated() { lines.append(SessionTests.ex(i + 2, b)) }
        let s = SessionReducer.reduce(SessionState(), lines)
        return (s, s.task("r1")!)
    }

    static func frame(_ body: [String], phase: CardPhase? = nil) -> IslandFrame {
        let (s, t) = task(body)
        let pinned: (card: CardState, phase: CardPhase)? = (s.openCard?.card ?? t.expiredCard).map { c in (c, phase ?? CardStore().phase(c, of: t)) }
        return IslandFeed.frame(t, pinned: pinned, lang: .zhHans)
    }

    static func tableTests() {
        let step = #""kind":"step","text":"click","step_id":"s1","human":"点「发送」""#
        let rows: [(String, IslandFrame, IslandFrame.Phase, Bool, String)] = [
            ("preparing", frame([]), .running, false, L10n.zh["Getting ready…"] ?? ""),
            ("working", frame([#""kind":"plan","steps":[]"#, step]), .running, false, "点「发送」"),
            ("paused", frame([step, #""kind":"waiting""#]), .running, false, L10n.zh["You're using the Mac, paused"] ?? ""),
            ("an action card", frame([#""kind":"ask","ask_id":"a1","# + action]), .running, true, L10n.zh["Waiting for your approval in DeskMind"] ?? ""),
            ("a card held (take-back)", frame([#""kind":"ask","ask_id":"a1","# + action], phase: .pending(.option(runId: "r1", askId: "a1", option: 0), until: 0)), .running, true, L10n.zh["Waiting for your approval in DeskMind"] ?? ""),
            ("a question card", frame([#""kind":"ask","ask_id":"a1","# + missing]), .running, true, L10n.zh["Waiting for your answer in DeskMind"] ?? ""),
            ("the card expired", frame([#""kind":"ask","ask_id":"a1","# + action, #""kind":"ask_void","ask_id":"a1","why":"timeout""#]), .running, true, L10n.zh["The card expired; the task waits where it was"] ?? ""),
            ("checking", frame([step, #""kind":"verify","verdict":"unknown","reason":"r","missing_kind":"evidence""#]), .running, false, L10n.zh["Checking the result (looking only)"] ?? ""),
            ("stopping", frame([step, #""kind":"refused","what":"the task","why":"stopped","by":"user""#]), .running, false, L10n.zh["Stopping…"] ?? ""),
            ("succeeded", frame([#""kind":"task_done","status":"succeeded","reason":"","summary":"s""#]), .ended(passed: true, stopped: false), false, L10n.zh["Done"] ?? ""),
            ("failed", frame([#""kind":"task_done","status":"failed","reason":"","summary":"s""#]), .ended(passed: false, stopped: false), false, L10n.zh["Didn't finish"] ?? ""),
            ("cancelled", frame([#""kind":"task_done","status":"cancelled","reason":"","summary":"s""#]), .ended(passed: false, stopped: true), false, L10n.zh["Cancelled"] ?? ""),
            ("stopped", frame([#""kind":"task_done","status":"stopped","reason":"","summary":"s""#]), .ended(passed: false, stopped: true), false, L10n.zh["Stopped"] ?? ""),
            ("locked", frame([#""kind":"task_done","status":"environment","reason":"","summary":"s","cause":"screen_locked""#]), .ended(passed: false, stopped: false), false, L10n.zh["Stopped: the screen is locked"] ?? ""),
            ("not confirmed", frame([#""kind":"task_done","status":"unconfirmed","reason":"","summary":"s""#]), .ended(passed: false, stopped: false), false, L10n.zh["Done, but not confirmed. Please check"] ?? ""),
        ]
        for (name, f, phase, asking, line) in rows {
            check(f.phase == phase && f.asking == asking && f.line == line, "\(name): \(f.phase) asking \(f.asking) «\(f.line)» (want \(phase), \(asking), «\(line)»)")
        }
        check(frame([#""kind":"ask","ask_id":"a1","# + action]).cardId == "a1" && frame([#""kind":"ask","ask_id":"a1","# + action, #""kind":"resumed","ask_id":"a1""#]).cardId == nil,
              "the card waits: its id; answered: none")
    }

    static func notifyTests() {
        let asked = frame([#""kind":"ask","ask_id":"a1","# + action]), again = asked
        let working = frame([])
        check(IslandFeed.cardNotification(from: working, to: asked, appActive: false, userTyping: false, lang: .zhHans)?.title == L10n.zh["DeskMind needs your approval"],
              "a card arrives, DeskMind not active: a notification")
        check(IslandFeed.cardNotification(from: working, to: asked, appActive: true, userTyping: true, lang: .zhHans) != nil, "active but typing elsewhere: a notification")
        check(IslandFeed.cardNotification(from: working, to: asked, appActive: true, userTyping: false, lang: .zhHans) == nil, "DeskMind active, not typing: none")
        check(IslandFeed.cardNotification(from: asked, to: again, appActive: false, userTyping: false, lang: .zhHans) == nil, "the same card again: none (once per card)")
        let q = frame([#""kind":"ask","ask_id":"a2","# + missing])
        check(IslandFeed.cardNotification(from: asked, to: q, appActive: false, userTyping: false, lang: .zhHans).map { ($0.title, $0.body) } ?? ("", "") == (L10n.zh["DeskMind has a question"] ?? "", "发给谁？"),
              "a new card: its own notification, its text")
        check(IslandFeed.cardNotification(from: working, to: frame([#""kind":"task_done","status":"succeeded","reason":"","summary":"s""#]), appActive: false, userTyping: false, lang: .zhHans) == nil,
              "the end: not this one (RunOverlay.finish says it)")
    }

    /// The island as a test sees it: every call, in order, and the details link.
    final class FakeSurface: IslandSurface {
        var calls: [String] = []
        var detailsRecord: UUID? = nil
        var appActive = true
        var userTyping = false
        func requestNotifications() {}
        func show(title: String, line: String, onStop: @escaping () -> Void) { calls.append("show"); detailsRecord = nil }   // (as RunOverlay.show)
        func update(step: Int, line: String) { calls.append("update") }
        func setAsking(_ on: Bool) { calls.append("asking:\(on)") }
        func finish(passed: Bool, stopped: Bool, summary: String) { calls.append("finish:\(passed):\(summary)") }
        func notify(title: String, body: String) { calls.append("notify") }
    }
    final class FakeServices: GoalRunServices {
        var kept: [(GoalRecord, UUID)] = []
        func beginRecording(goal: String, started: @escaping () -> Void) { started() }
        func stopRecording(done: @escaping (URL?) -> Void) { done(nil) }
        func keep(_ r: GoalRecord, id: UUID, lang: ResolvedLang) { kept.append((r, id)) }
        func setMovie(_ path: String, for id: UUID) {}
    }

    /// The app's applier and effects (IslandApplier, GoalRunEffects.app) on a goal over the real ShellModel.
    static func rig(holdDeliver: Bool = false) -> (SurfaceTests.Rig, FakeSurface, FakeServices, GoalRun) {
        let r = SurfaceTests.Rig(holdDeliver: holdDeliver); SurfaceTests.openOK(r.mock)
        let surface = FakeSurface(), services = FakeServices()
        let g = GoalRun(goal: "整理下载", folder: nil, record: false, shell: r.m,
                        effects: .app(lang: .en, services: services, surface: surface, after: { d, f in r.timers.after(d, f) }))
        return (r, surface, services, g)
    }

    /// The island follows the goal's own task (never the selected session's) through the app's own applier, kept
    /// with the goal; it ends with the goal; Show Details opens the kept record.
    static func wiringTests() {
        typealias T = SurfaceTests
        do {
            let (r, surface, services, g) = rig()
            g.start()
            check(surface.calls.isEmpty, "no task yet: no island")
            for l in T.taskLines { r.m.client.feed(l) }
            check(surface.calls.first == "show", "its task: the island shows it: \(surface.calls)")
            r.m.selected = nil
            r.m.client.feed(["kind": "session.task", "session_id": "ses_other", "seq": 1, "msg_id": "o1", "run_id": "r_other", "raw": "x", "by": "slash"])
            check(!surface.calls.contains { $0.hasPrefix("finish") }, "another session selected: still its own task")
            for l in T.endLines { r.m.client.feed(l) }
            check(surface.calls.last == "finish:true:Done", "its end reaches the island: \(surface.calls)")
            check(services.kept.count == 1 && surface.detailsRecord == services.kept.first?.1, "Show Details: its kept record")
            check(services.kept.first?.0.sessionId == T.sid && services.kept.first?.0.task?.runId == T.rid, "the record keeps its session and run")
        }
        do {    // its start and end in one update: the record is kept before the island's first frame, whose `show` clears
                // the last link — the frame's link is set after it
            let (r, surface, services, g) = rig(holdDeliver: true)
            g.start(); r.drainDeliver()
            for l in T.taskLines + T.endLines { r.m.client.feed(l) }
            r.drainDeliver()
            check(g.state == .ended(sid: T.sid, run: T.rid, status: "succeeded"), "ended in one update: \(g.state)")
            check(surface.calls.first == "show" && surface.calls.last == "finish:true:Done", "shown, then finished: \(surface.calls)")
            check(services.kept.count == 1 && surface.detailsRecord == services.kept.first?.1, "Show Details keeps its record: \(String(describing: surface.detailsRecord))")
        }
        do {    // the session gone mid-task, its task not marked ended (the exit's last_seq before it): the goal's
                // `interrupted` ends the island; nothing after the goal is let go
            let (r, surface, _, g) = rig()
            g.start()
            for l in T.taskLines { r.m.client.feed(l) }
            r.m.client.feed(["kind": "helper.session_exit", "session_id": T.sid, "code": 0, "last_seq": 1])
            check(g.state == .ended(sid: T.sid, run: T.rid, status: "interrupted") && g.task?.task.ended == false,
                  "the goal ended (interrupted), its task not marked ended: \(g.state)")
            check(surface.calls.last == "finish:false:Interrupted", "the island ends with the goal: \(surface.calls)")
            let n = surface.calls.count
            r.m.client.feed(["kind": "step", "session_id": T.sid, "run_id": T.rid, "seq": 2, "text": "click", "step_id": "s1"])
            r.timers.advance(3600)
            check(surface.calls.count == n && !g.watching, "let go: no frame after: \(surface.calls.suffix(2))")
        }
        do {    // a recent run whose session (or task) is gone: its record's own content
            var states: [String: SessionState] = [:]
            check(PastRun.task(sessionId: T.sid, runId: T.rid, in: states) == nil, "session deleted: none (the record's own steps and summary)")
            states[T.sid] = SessionState(sessionId: T.sid)
            check(PastRun.task(sessionId: T.sid, runId: T.rid, in: states) == nil, "its task gone: none")
            states[T.sid] = SessionReducer.reduce(SessionState(sessionId: T.sid), [SessionTests.taskR1, SessionTests.ex(1, #""kind":"start","raw":"x""#)])
            check(PastRun.task(sessionId: T.sid, runId: "r1", in: states)?.task.runId == "r1", "there: shown as the session has it")
        }
        let id = UUID(), other = UUID()
        check(IslandFeed.detailsRoute(record: id, showing: nil) == id && IslandFeed.detailsRoute(record: id, showing: other) == id,
              "Show Details: the task's record")
        check(IslandFeed.detailsRoute(record: id, showing: id) == nil && IslandFeed.detailsRoute(record: nil, showing: nil) == nil,
              "already shown, or none kept: the window as it is")
    }
}
