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
        DecisionTests.group("island.shownTests"); shownTests()
        DecisionTests.group("island.savedMovieTests"); savedMovieTests()
        DecisionTests.group("island.ackBeforeHistoryTests"); ackBeforeHistoryTests()
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
    /// The recent runs as a test holds them: kept records by id, their movie set when the recording is saved; the
    /// recording's stop answers when the test says (`finishRecording`), as RunRecorder's does — later.
    final class FakeServices: GoalRunServices {
        var kept: [(GoalRecord, UUID)] = []
        var saved: [UUID: SavedRun] = [:]
        var pendingStop: ((URL?) -> Void)?
        func beginRecording(goal: String, started: @escaping () -> Void) { started() }
        func stopRecording(done: @escaping (URL?) -> Void) { pendingStop = done }
        func finishRecording(_ path: String?) { let d = pendingStop; pendingStop = nil; d?(path.map { URL(fileURLWithPath: $0) }) }
        func keep(_ r: GoalRecord, id: UUID, lang: ResolvedLang) {
            kept.append((r, id))
            saved[id] = SavedRun(sessionId: r.runId == nil ? nil : r.sessionId, runId: r.runId, ended: r.ended, folder: r.folder, movie: nil)
        }
        func setMovie(_ path: String, for id: UUID) { saved[id]?.movie = path }
    }

    /// The app's applier and effects (IslandApplier, GoalRunEffects.app) on a goal over the real ShellModel.
    static func rig(holdDeliver: Bool = false, record: Bool = false, folder: String? = nil) -> (SurfaceTests.Rig, FakeSurface, FakeServices, GoalRun) {
        let r = SurfaceTests.Rig(holdDeliver: holdDeliver); SurfaceTests.openOK(r.mock)
        let surface = FakeSurface(), services = FakeServices()
        let g = GoalRun(goal: "整理下载", folder: folder, record: record, shell: r.m,
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
        do {    // the same goal's record: "Interrupted" from the goal, not "Working · step N" from its task; opened later,
                // its task is shown ended so (not running), though the session still says it runs
            let (r, _, services, g) = rig()
            g.start()
            for l in T.taskLines { r.m.client.feed(l) }
            r.m.client.feed(["kind": "step", "session_id": T.sid, "run_id": T.rid, "seq": 2, "text": "click", "step_id": "s1", "human": "点「发送」"])
            r.m.client.feed(["kind": "helper.session_exit", "session_id": T.sid, "code": 0, "last_seq": 1])
            guard let kept = services.kept.first?.0 else { check(false, "a record kept"); return }
            check(kept.ended == "interrupted" && kept.task?.ended == false, "the goal ended interrupted, its task not marked yet")
            let o = GoalOutcome.record(kept, lang: .en)
            check(o.summary == "Interrupted" && !o.finished && o.errored && o.task?.ended == true, "the record: Interrupted: \(o.summary)")
            let opened = PastRun.task(sessionId: T.sid, runId: T.rid, endedAs: kept.ended, in: r.m.states)
            check(r.m.states[T.sid]?.task(T.rid)?.running == true, "(the session still says it runs)")
            check(opened?.task.running == false && opened.map { ShellText.task($0.task, lang: .en) } == "Interrupted"
                  && opened?.task.resultCardState.undoEnabled == false, "opened later: ended, Interrupted, no undo")
        }
        do {    // a recent run whose session (or task) is gone: its record's own content
            var states: [String: SessionState] = [:]
            check(PastRun.task(sessionId: T.sid, runId: T.rid, endedAs: nil, in: states) == nil, "session deleted: none (the record's own steps and summary)")
            states[T.sid] = SessionState(sessionId: T.sid)
            check(PastRun.task(sessionId: T.sid, runId: T.rid, endedAs: nil, in: states) == nil, "its task gone: none")
            states[T.sid] = SessionReducer.reduce(SessionState(sessionId: T.sid), [SessionTests.taskR1, SessionTests.ex(1, #""kind":"start","raw":"x""#)])
            check(PastRun.task(sessionId: T.sid, runId: "r1", endedAs: nil, in: states)?.task.runId == "r1", "there: shown as the session has it")
        }
        routeTests()
    }

    /// What a goal's screen shows (GoalShown.of), route × field — Codex review at a8cec0f: an older run showed a newer
    /// task's card; a saved run lost its folder and its recording.
    static func shownTests() {
        typealias T = SurfaceTests
        // the goal's task ended; then a newer task of the user's in the same session waits on a card
        let r = T.Rig(); T.openOK(r.mock)
        let g = r.goal(); g.start()
        for l in T.taskLines + T.endLines { r.m.client.feed(l) }
        let newer: [[String: Any]] = [
            ["kind": "session.message", "session_id": T.sid, "seq": 4, "msg_id": "m_new", "role": "user", "text": "发给小王", "client_id": "c_new"],
            ["kind": "session.task", "session_id": T.sid, "seq": 5, "msg_id": "t_new", "run_id": "r_new", "raw": "发给小王", "by": "model", "reply_to": "a_new"],
            ["kind": "start", "session_id": T.sid, "run_id": "r_new", "seq": 1, "raw": "发给小王"],
            ["kind": "ask", "session_id": T.sid, "run_id": "r_new", "seq": 2, "ask_id": "ask_new",
             "card": ["kind": "action", "text": "要点「发送」吗？", "free_text": false, "blocking": true,
                      "options": [["kind": "approve", "text": "可以"], ["kind": "cancel", "text": "先别做了"]]]],
        ]
        for l in newer { r.m.client.feed(l) }
        r.m.selected = T.sid
        check(r.m.states[T.sid].flatMap { r.m.pinned($0) }?.runId == "r_new", "(the session's pinned card is the newer task's)")
        let movie = "/tmp/rec/run.mov"
        let recA = UUID(), recGone = UUID()
        let records: [UUID: SavedRun] = [
            recA: SavedRun(sessionId: T.sid, runId: T.rid, ended: "succeeded", folder: "/tmp/dl", movie: movie),
            recGone: SavedRun(sessionId: "ses_deleted", runId: T.rid, ended: "succeeded", folder: "/tmp/dl", movie: movie),
        ]
        func shown(_ route: GoalScreenRoute) -> GoalShown {
            GoalShown.of(route, states: r.m.states, selected: r.m.selected, pinned: { r.m.pinned($0) }, saved: { records[$0] }, lang: .en)
        }
        let saved = shown(.saved(recA))
        // saved record, its session there
        check(saved.sessionShown && saved.task?.runId == T.rid, "saved, session there: its own task")
        check(saved.pinned == nil, "saved: a newer task's card is not shown under the older run (Codex 1)")
        check(saved.folder == "/tmp/dl", "saved: the record's folder (Codex 2)")
        check(saved.movie == URL(fileURLWithPath: movie), "saved: the record's recording (Codex 3)")
        check(saved.screen.afterwards && !saved.screen.stopShown, "saved: ended (Back, no Stop)")
        // saved record, session gone
        let gone = shown(.saved(recGone))
        check(!gone.sessionShown && gone.task == nil && gone.pinned == nil, "session gone: the record's own content")
        check(gone.folder == "/tmp/dl" && gone.movie == URL(fileURLWithPath: movie), "session gone: still its folder and recording")
        // live goal: its own task; the newer task's card not its own
        let live = shown(.live(state: g.state, task: g.task, sessionId: g.sessionId, folder: "/tmp/dl", movie: URL(fileURLWithPath: movie)))
        check(live.sessionShown && live.task?.runId == T.rid && live.pinned == nil, "live, ended: its own task, not the newer card")
        check(live.folder == "/tmp/dl" && live.movie == URL(fileURLWithPath: movie), "live: its folder and recording")
        // a live goal's own card: shown while its session is selected, not otherwise
        let r2 = T.Rig(); T.openOK(r2.mock)
        let g2 = r2.goal(); g2.start()
        for l in T.taskLines { r2.m.client.feed(l) }
        r2.m.client.feed(["kind": "ask", "session_id": T.sid, "run_id": T.rid, "seq": 2, "ask_id": "ask_g",
                          "card": ["kind": "missing", "text": "发给谁？", "free_text": false, "blocking": true,
                                   "options": [["kind": "value", "text": "小王"], ["kind": "cancel", "text": "先别做了"]]]])
        func shown2(selected: String?) -> GoalShown {
            GoalShown.of(.live(state: g2.state, task: g2.task, sessionId: g2.sessionId, folder: nil, movie: nil), states: r2.m.states,
                         selected: selected, pinned: { r2.m.pinned($0) }, lang: .en)
        }
        check(shown2(selected: T.sid).pinned?.card.askId == "ask_g", "live: its own card while its session is selected")
        check(shown2(selected: nil).pinned == nil, "another session selected: no card (a click goes to the selected one)")
        check(shown2(selected: T.sid).screen.stopShown && shown2(selected: T.sid).screen.running, "live, running: Stop")
        // no goal (another not over)
        let busy = shown(.busy)
        check(busy.task == nil && busy.screen.afterwards && busy.screen.line == GoalRunScreen.why(GoalLifecycle.Why.busy, lang: .en), "busy: said, Back works")
    }

    /// One route for Show Details and a reopened window (IslandFeed.route) — delta review at 3e59da9: goal A's island
    /// lingered with Show Details while goal B ran; the click pulled the window off B to A's record.
    static func routeTests() {
        let a = UUID(), b = UUID(), recA = UUID()
        typealias R = IslandFeed
        check(R.route(active: b, details: recA, showingGoal: b, showingRecord: nil) == nil, "B active and shown: Show Details of A stays on B")
        check(R.route(active: b, details: recA, showingGoal: nil, showingRecord: recA) == .goal(b), "B active, A's record shown: to B")
        check(R.route(active: b, details: nil, showingGoal: nil, showingRecord: nil) == .goal(b), "reopened while B is active: to B")
        check(R.route(active: nil, details: recA, showingGoal: nil, showingRecord: nil) == .record(recA), "none active: Show Details opens the record")
        check(R.route(active: nil, details: recA, showingGoal: a, showingRecord: nil) == .record(recA), "(from an ended goal's screen too)")
        check(R.route(active: nil, details: recA, showingGoal: nil, showingRecord: recA) == nil, "shown already: as it is")
        check(R.route(active: nil, details: nil, showingGoal: nil, showingRecord: nil) == nil, "nothing: as it is")
        // a goal that starts clears the island's link to an earlier goal's record (before its own first frame)
        let (r, surface, _, g) = rig()
        surface.detailsRecord = recA
        g.start()
        check(surface.detailsRecord == nil && surface.calls.isEmpty, "B starts (no frame yet): A's link gone")
        _ = r
    }

    /// Codex review at 600f34d: Show Details after the task ended but before its recording was saved showed a record
    /// with no movie, for good. A saved run is read through by its id: the movie appears as it lands.
    static func savedMovieTests() {
        typealias T = SurfaceTests
        let (r, _, services, g) = rig(record: true, folder: "/tmp/dl")
        g.start()
        for l in T.taskLines + T.endLines { r.m.client.feed(l) }
        guard let id = services.kept.first?.1 else { check(false, "the record kept"); return }
        check(services.pendingStop != nil && services.saved[id]?.movie == nil, "ended: the record kept, its recording still being saved")
        func shown() -> GoalShown {
            GoalShown.of(.saved(id), states: r.m.states, selected: r.m.selected, pinned: { r.m.pinned($0) }, saved: { services.saved[$0] }, lang: .en)
        }
        let before = shown()                        // Show Details now: opened before the movie
        check(before.movie == nil && before.folder == "/tmp/dl" && before.task?.runId == T.rid, "opened before the movie: none yet")
        services.finishRecording("/tmp/rec/goal.mov")
        check(shown().movie == URL(fileURLWithPath: "/tmp/rec/goal.mov"), "the recording saved: shown, without reopening")
        check(g.movie == URL(fileURLWithPath: "/tmp/rec/goal.mov"), "(and the goal's own)")
    }

    /// Codex review at c03c9e5: a stop's ack ended the goal before the history brought its task; the record then had
    /// no session or run, no details link, and the saved run never showed the result card. Both come from the goal's
    /// ending now.
    static func ackBeforeHistoryTests() {
        typealias T = SurfaceTests
        let (r, surface, services, g) = rig()
        g.start(); g.stop()
        r.ack("stopped", run: T.rid, status: "stopped")      // before any session.task
        check(g.state == .ended(sid: T.sid, run: T.rid, status: "stopped") && g.task == nil, "ended by the ack, no task yet: \(g.state)")
        guard let (rec, id) = services.kept.first else { check(false, "the record kept"); return }
        check(rec.sessionId == T.sid && rec.runId == T.rid, "the record: its session and run from the start")
        check(services.saved[id]?.sessionId == T.sid && services.saved[id]?.runId == T.rid, "kept with its session and run")
        check(surface.detailsRecord == id, "the details link set: \(String(describing: surface.detailsRecord))")
        func shown() -> GoalShown {
            GoalShown.of(.saved(id), states: r.m.states, selected: r.m.selected, pinned: { r.m.pinned($0) }, saved: { services.saved[$0] }, lang: .en)
        }
        check(shown().task == nil, "opened now: no task yet")
        for l in T.taskLines + T.endLines { r.m.client.feed(l) }   // the history lands
        let v = shown()
        check(v.sessionShown && v.task?.runId == T.rid && v.task?.resultCard != nil, "the history landed: its task with its result card")
    }
}
