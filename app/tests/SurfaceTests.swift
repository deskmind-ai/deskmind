// Every surface that shows a finished computer task offers the same result card (m2-plan invariant 4; the rc.15
// manual run: GoalRunView never rendered task_done.result_card). One state (TaskState.resultCardState), one predicate
// (ShellModel.canSend), one respond path (CardStore → SessionClient → the session): no surface has its own.
//
// | surface                         | the result card                                                          |
// |---------------------------------|--------------------------------------------------------------------------|
// | the chat (0.5 window)           | ResultSection (Main/TaskViews.swift)                                     |
// | GoalRunView, the harness engine | the same: a session task (GoalRun → ShellModel.startTask), its own task  |
// |                                 |   shown with TaskRow → ResultSection                                     |
//
// And a goal from GoalRunView has one lifecycle, its own (Shared/GoalRun.swift, the table there; #118 review at
// 6554042): never read from the selected session's newest task.
// - lifecycleTableTests: GoalLifecycle.next, row by row, and that ended / failed take nothing more.
// - goalSessionTests: the goal through the real ShellModel (a mock helper): cua with its folder, its own task, the
//   result card and one undo, Stop to its own session whatever is selected, the record and the recording once.
// - goalFailureTests: the paths that never got a task, through the real startTask with a failing helper — open fails,
//   cua refused, the helper unavailable, cloud models off, no answer (70 s), no task (60 s), Stop before the task
//   (15 s, or the task then stopped), the session gone before and during the task — each ends, once.
// - goalScreenTests: what GoalRunView shows, from the state alone (GoalRunScreen); one goal at a time (GoalRuns).
// Run from DecisionTests.main (build.sh).

import Foundation

enum SurfaceTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "surface: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("surface.lifecycleTableTests"); lifecycleTableTests()
        DecisionTests.group("surface.goalSessionTests"); goalSessionTests()
        DecisionTests.group("surface.goalFailureTests"); goalFailureTests()
        DecisionTests.group("surface.goalScreenTests"); goalScreenTests()
    }

    typealias L = GoalLifecycle
    typealias Mock = SessionTests.MockTransport

    // MARK: the table

    static func lifecycleTableTests() {
        func row(_ s: L.State, _ e: L.Event, rec: Bool = true, _ want: L.State, _ fx: [L.Effect], _ what: String) {
            let (n, f) = L.next(s, e, recording: rec)
            check(n == want && f == fx, "\(what): \(s) × \(e) → \(n) \(f)")
        }
        let end: [L.Effect] = [.stopRecording, .writeRecord]
        let bound = SessionClient.openTimeout + SessionClient.sendTimeout + 5
        check(L.openingBound == bound && bound > SessionClient.openTimeout + SessionClient.sendTimeout,
              "the opening waits longer than the open and a send that reopens: \(L.openingBound)")
        let open: [L.Effect] = [.deadline(seconds: bound), .open]
        /// failed with its cua perhaps on its way to "s": stopped, retired, guarded 60 s
        let guarded: [L.Effect] = end + [.sendStop(sid: "s", run: nil), .retire(sid: "s"), .deadline(seconds: 60)]
        row(.idle, .start(record: true), .recordingStart, [.beginRecording], "recorded: the recording first")
        row(.idle, .start(record: false), .opening(sid: nil), open, "not recorded: open at once, its bound")
        row(.recordingStart, .recordingStarted, .opening(sid: nil), open, "the recording started (or could not): open")
        row(.opening(sid: nil), .opened(sid: "s"), .opening(sid: "s"), [], "opened: its session id")
        row(.opening(sid: nil), .cloudRefused, .failed(L.Why.cloudOff), end, "cloud off")
        row(.opening(sid: nil), .openFailed, .failed(L.Why.noHelper), end, "the open failed")
        row(.opening(sid: "s"), .refused("no_model"), .failed(L.Why.refused("no_model")), end + [.retire(sid: "s")], "cua refused by the send: retired")
        row(.opening(sid: "s"), .sessionRefused(code: "computer_busy", text: "另一个对话在用电脑"), .failed(L.Why.refused("computer_busy", text: "另一个对话在用电脑")),
            end + [.retire(sid: "s")], "cua refused by the session (before the send's ok)")
        row(.opening(sid: "s"), .unavailable, .failed(L.Why.noHelper, guarding: "s"), guarded, "the helper unavailable: the cua may be on its way")
        row(.opening(sid: nil), .deadline, .failed(L.Why.noAnswer), end, "no answer: nothing opened yet (the cua is never sent: GoalTicket)")
        row(.opening(sid: "s"), .deadline, .failed(L.Why.noAnswer, guarding: "s"), guarded, "opened, the send never answered: guarded")
        row(.opening(sid: nil), .deadline, rec: false, .failed(L.Why.noAnswer), [.writeRecord], "not recorded: no recording to stop")
        row(.opening(sid: "s"), .sent, .sent(sid: "s", stopAsked: false), [.deadline(seconds: 60)], "sent: 60 s for its task")
        row(.opening(sid: "s"), .taskStarted(run: "r"), .running(sid: "s", run: "r"), [], "its task's lines before the send's ok")
        row(.opening(sid: nil), .sent, .opening(sid: nil), [], "(sent with no session id: nothing)")
        row(.opening(sid: nil), .stop, .opening(sid: nil), [], "Stop while opening: hidden, nothing")
        row(.recordingStart, .stop, .recordingStart, [], "Stop while recording starts: hidden, nothing")
        row(.sent(sid: "s", stopAsked: false), .taskStarted(run: "r"), .running(sid: "s", run: "r"), [], "its task")
        row(.sent(sid: "s", stopAsked: false), .stop, .sent(sid: "s", stopAsked: true), [.sendStop(sid: "s", run: nil), .deadline(seconds: 15)],
            "Stop before the task: stop to its session, 15 s")
        row(.sent(sid: "s", stopAsked: true), .stop, .sent(sid: "s", stopAsked: true), [], "Stop again: nothing more")
        row(.sent(sid: "s", stopAsked: true), .taskStarted(run: "r"), .running(sid: "s", run: "r"), [.sendStop(sid: "s", run: "r")],
            "the task came after Stop: stopped by its run")
        row(.sent(sid: "s", stopAsked: false), .sessionRefused(code: "computer_busy", text: "t"), .failed(L.Why.refused("computer_busy", text: "t")),
            end + [.retire(sid: "s")], "its cua refused by the session: at once")
        row(.sent(sid: "s", stopAsked: true), .deadline, .failed(L.Why.stoppedBeforeStart, guarding: "s"), guarded, "stopped, nothing in 15 s")
        row(.sent(sid: "s", stopAsked: true), .exited, .failed(L.Why.stoppedBeforeStart, guarding: "s"), guarded, "stopped, the session went")
        row(.sent(sid: "s", stopAsked: false), .exited, .failed(L.Why.gone, guarding: "s"), guarded, "the session went before its task (perhaps a stale exit)")
        row(.sent(sid: "s", stopAsked: false), .deadline, .failed(L.Why.notStarted, guarding: "s"), guarded, "no task in 60 s")
        row(.running(sid: "s", run: "r"), .stop, .running(sid: "s", run: "r"), [.sendStop(sid: "s", run: "r")], "Stop: its run, its session")
        row(.running(sid: "s", run: "r"), .deadline, .running(sid: "s", run: "r"), [], "an older deadline: nothing")
        row(.running(sid: "s", run: "r"), .taskEnded(status: "succeeded"), .ended(sid: "s", run: "r", status: "succeeded"), end, "its end")
        row(.running(sid: "s", run: "r"), .exited, .ended(sid: "s", run: "r", status: "interrupted"), end, "the session went mid-task: interrupted")
        // failed, guarding: a task that still comes is stopped by its run, once; the rest lets the guard go
        row(.failed(L.Why.gone, guarding: "s"), .taskStarted(run: "r"), .failed(L.Why.gone), [.sendStop(sid: "s", run: "r")], "a late task: stopped")
        for e: L.Event in [.exited, .deadline, .refused("x"), .sessionRefused(code: "x", text: "")] {
            row(.failed(L.Why.gone, guarding: "s"), e, .failed(L.Why.gone), [], "guard over")
        }
        for e: L.Event in [.start(record: true), .recordingStarted, .opened(sid: "x"), .openFailed, .cloudRefused, .sent, .unavailable,
                           .taskEnded(status: "failed"), .stop] {
            row(.failed(L.Why.gone, guarding: "s"), e, .failed(L.Why.gone, guarding: "s"), [], "guarding: nothing else")
        }
        // over: nothing changes it, nothing is done again
        let events: [L.Event] = [.start(record: true), .recordingStarted, .opened(sid: "x"), .openFailed, .cloudRefused, .sent, .refused("x"),
                                 .sessionRefused(code: "x", text: ""), .unavailable, .taskStarted(run: "x"), .taskEnded(status: "failed"),
                                 .exited, .stop, .deadline]
        for s: L.State in [.ended(sid: "s", run: "r", status: "succeeded"), .failed(L.Why.noAnswer)] {
            for e in events { row(s, e, s, [], "over") }
        }
        // its own session's state as events: the first task, its end, the process gone, its own cua refused
        var ss = SessionState()
        check(L.observed(.sent(sid: "s", stopAsked: false), ss, cua: "c_1") == nil, "no task yet: nothing")
        ss.outbox = [Outgoing(id: "c_other", text: "x", control: "say", sending: false, refused: "busy")]
        ss.lastRefusal = SessionErrorEvent(code: "busy", text: "x", clientId: "c_other")
        check(L.observed(.sent(sid: "s", stopAsked: false), ss, cua: "c_1") == nil, "another refusal: not its own")
        ss.outbox.append(Outgoing(id: "c_1", text: "g", control: "cua", sending: false, refused: "exited"))
        check(L.observed(.sent(sid: "s", stopAsked: false), ss, cua: "c_1") == nil, "its process's end is not a refusal")
        ss.outbox[1].refused = "computer_busy"
        ss.lastRefusal = SessionErrorEvent(code: "computer_busy", text: "另一个对话在用电脑", clientId: "c_1")
        check(L.observed(.sent(sid: "s", stopAsked: false), ss, cua: "c_1") == .sessionRefused(code: "computer_busy", text: "另一个对话在用电脑"),
              "its own cua refused, with the session's words")
        ss = SessionState(); ss.exited = 0
        check(L.observed(.sent(sid: "s", stopAsked: false), ss, cua: "c_1") == .exited, "gone before the task")
        check(L.observed(.opening(sid: "s"), ss, cua: "c_1") == nil, "(opening: the send says what came of it)")
        check(L.observed(.failed(L.Why.gone, guarding: "s"), ss, cua: "c_1") == nil, "guarding: an exit (perhaps stale) does not end it")
        check(GoalRunScreen.why(L.Why.refused("computer_busy", text: "另一个对话在用电脑"), lang: .zhHans) == "另一个对话在用电脑"
              && GoalRunScreen.why(L.Why.refused("computer_busy"), lang: .en) == "Not sent: another conversation is using the Mac",
              "a refusal shown in the session's words, else what its code means")
    }

    // MARK: through the real model

    /// A goal on a ShellModel over `mock`, with counted effects and a test clock.
    final class Rig {
        let mock: Mock
        let m: ShellModel
        let timers = ShellTests.Timers()
        var records: [GoalRecord] = []
        var recordingStops = 0
        var recordingBegins = 0
        final class Held { var work: [() -> Void] = [] }
        /// The work queue's jobs while `holdWork` (an open or a send that has not answered yet).
        let held = Held()
        init(_ mock: Mock = Mock(), cloudOn: Bool = true, holdWork: Bool = false) {
            self.mock = mock
            let client = SessionClient(transport: mock)
            client.newClientId = { "c_1" }
            let held = held
            m = ShellModel(client: client, defaults: ShellTests.scratchDefaults(), config: { "openai:local|fake" }, lang: { .zhHans },
                           cloudOn: { cloudOn }, work: { f in if holdWork { held.work.append(f) } else { f() } }, deliver: { $0() })
        }
        /// The held jobs run, in order (and those they queue).
        func drain() { while !held.work.isEmpty { held.work.removeFirst()() } }
        /// The lines sent, in order, with their session.
        var linesSent: [(sid: String?, line: [String: Any])] {
            mock.requests.compactMap { r in (r["line"] as? [String: Any]).map { (r["session_id"] as? String, $0) } }
        }
        func goal(record: Bool = true, changed: @escaping (GoalRun) -> Void = { _ in }) -> GoalRun {
            GoalRun(goal: "把下载文件夹按类型整理", folder: "/tmp/dl", record: record, shell: m, effects: GoalRunEffects(
                beginRecording: { [unowned self] _, started in recordingBegins += 1; started() },
                stopRecording: { [unowned self] _, done in recordingStops += 1; done(nil) },
                writeRecord: { [unowned self] r in records.append(r) },
                after: { [unowned self] d, f in timers.after(d, f) },
                changed: changed))
        }
        var lines: [[String: Any]] { mock.requests.compactMap { $0["line"] as? [String: Any] } }
        func sent(_ type: String) -> [[String: Any]] { lines.filter { $0["type"] as? String == type } }
        var opens: Int { mock.requests.filter { $0["op"] as? String == SessionClient.Op.open }.count }
    }

    static let sid = "ses_goal", rid = "r_goal"
    static func openOK(_ mock: Mock) {
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": sid, "last_seq": 0], SessionClient.Op.send: ["ok": true]]
    }
    static let taskLines: [[String: Any]] = [
        ["kind": "session.task", "session_id": sid, "seq": 1, "msg_id": "u1", "run_id": rid, "raw": "把下载文件夹按类型整理", "by": "slash"],
        ["kind": "start", "session_id": sid, "run_id": rid, "seq": 1, "raw": "把下载文件夹按类型整理"],
    ]
    static let endLines: [[String: Any]] = [
        ["kind": "task_done", "session_id": sid, "run_id": rid, "seq": 2, "status": "succeeded", "reason": "", "summary": "s", "undo_until": 2_000_000_000,
         "result_card": ["kind": "result", "text": "做了：移动 3 个文件", "blocking": false, "free_text": false,
                         "options": [["kind": "approve", "text": "Fine"], ["kind": "undo", "text": "Undo"]]]],
        ["kind": "session.task_end", "session_id": sid, "seq": 2, "run_id": rid, "status": "succeeded", "summary": "s", "undo": "open", "undo_until": 2_000_000_000],
    ]
    static let exitLine: [String: Any] = ["kind": "helper.session_exit", "session_id": sid, "code": 0]

    /// A harness-engine goal through the model it uses: a new session, `cua` with the goal and its folder; its own
    /// task (another session selected meanwhile changes nothing); Stop to its own session and run; its result card from
    /// the session's one state, undo sent once by the chat's path; at its end the recording stopped and the record
    /// written, once — whatever comes later.
    static func goalSessionTests() {
        let r = Rig(); openOK(r.mock)
        let g = r.goal()
        g.start()
        check(r.recordingBegins == 1 && g.state == .sent(sid: sid, stopAsked: false), "recorded, opened, sent: \(g.state)")
        let cua = r.sent("cua").first
        check(cua?["text"] as? String == "把下载文件夹按类型整理" && cua?["scope"] as? String == "/tmp/dl", "a session task: cua with the goal and its folder: \(String(describing: cua))")
        check(r.m.selected == sid, "the new session is the one shown: \(String(describing: r.m.selected))")
        for l in taskLines { r.m.client.feed(l) }
        check(g.state == .running(sid: sid, run: rid), "its task: \(g.state)")
        // the chat moves elsewhere: the goal's task, its Stop, stay its own
        r.m.selected = nil
        r.m.client.feed(["kind": "session.task", "session_id": "ses_other", "seq": 1, "msg_id": "o1", "run_id": "r_other", "raw": "x", "by": "slash"])
        check(g.task?.task.runId == rid, "its own task, not the selected one's")
        g.stop()
        let stops = r.sent("stop")
        check(stops.count == 1 && stops.first?["run_id"] as? String == rid
              && r.mock.requests.last { ($0["line"] as? [String: Any])?["type"] as? String == "stop" }?["session_id"] as? String == sid,
              "Stop: its run, to its session, nothing selected: \(stops)")
        for l in endLines { r.m.client.feed(l) }
        check(g.state == .ended(sid: sid, run: rid, status: "succeeded"), "ended: \(g.state)")
        check(r.recordingStops == 1 && r.records.count == 1 && r.records.first?.task?.runId == rid && r.records.first?.sessionId == sid
              && r.records.first?.task?.status == "succeeded" && r.records.first?.task?.ended == true,
              "the recording stopped and the record written, once: \(r.recordingStops) \(r.records.map(\.sessionId))")
        guard let (s, t) = g.task else { check(false, "the goal's task is there"); return }
        check(t.resultCardState.undoEnabled, "its result card, from the session's state: \(t.resultCardState)")
        r.m.selected = sid
        let card = CardModel(resultCard: t.resultCard!, runId: rid)
        let undo = card.buttons.first { $0.role == .undo }!
        check(r.m.buttonEnabled(undo, card: card, in: s), "Undo takes a click (canSend)")
        r.m.click(undo); r.m.click(undo)
        let responds = r.sent("respond")
        check(responds.count == 1 && responds.first?["option"] as? Int == 1 && responds.first?["run_id"] as? String == rid, "one respond, by the chat's path: \(responds)")
        // later: the process goes, deadlines fire, Stop — nothing more
        r.m.client.feed(exitLine); r.timers.advance(3600); g.stop()
        check(r.recordingStops == 1 && r.records.count == 1 && g.state == .ended(sid: sid, run: rid, status: "succeeded"), "once, whatever comes later")
    }

    static func goalFailureTests() {
        /// Over as `want`: the record once, the recording stopped, Back and no Stop; later, nothing more — and once it
        /// guards nothing, its watch of the session gone.
        func ended(_ r: Rig, _ g: GoalRun, _ want: L.State, stops: Int = 1, _ what: String) {
            check(g.state == want, "\(what): \(g.state)")
            check(r.records.count == 1 && r.recordingStops == stops, "\(what): the record once, the recording stopped: \(r.records.count) \(r.recordingStops)")
            check(GoalRunScreen(g.state, lang: .en).afterwards && !GoalRunScreen(g.state, lang: .en).stopShown, "\(what): Back works, no Stop")
            r.timers.advance(3600); g.stop()
            var final = want
            if case .failed(let why, _) = want { final = .failed(why) }
            check(r.records.count == 1 && r.recordingStops == stops && g.state == final, "\(what): nothing more after: \(g.state)")
            check(!g.watching, "\(what): let go of its session")
        }
        let bound = L.openingBound
        do {    // the open fails (no helper)
            let r = Rig(); r.mock.replies = [:]
            let g = r.goal(); g.start()
            ended(r, g, .failed(L.Why.noHelper), "open fails")
            check(r.sent("cua").isEmpty, "open fails: nothing sent")
        }
        do {    // cua refused by the send (the helper holds cloud models off): its bubble retired
            let r = Rig(); r.mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": sid, "last_seq": 0], SessionClient.Op.send: ["ok": true, "code": "no_model"]]
            let g = r.goal(); g.start()
            ended(r, g, .failed(L.Why.refused("no_model")), "cua refused")
            check(r.m.client.state(sid).shownOutbox.isEmpty && r.m.client.state(sid).unsent.isEmpty, "cua refused: no bubble to resend")
        }
        do {    // the helper unavailable on the send: the cua may have gone — its session stopped, guarded
            let r = Rig(); r.mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": sid, "last_seq": 0], SessionClient.Op.send: ["ok": false]]
            let g = r.goal(); g.start()
            ended(r, g, .failed(L.Why.noHelper, guarding: sid), "unavailable")
        }
        do {    // cloud models off: refused before anything opens; not recorded: no recording to stop
            let r = Rig(cloudOn: false); openOK(r.mock)
            let g = r.goal(record: false); g.start()
            ended(r, g, .failed(L.Why.cloudOff), stops: 0, "cloud off")
            check(r.opens == 0 && r.sent("cua").isEmpty && r.recordingBegins == 0, "cloud off: nothing opened")
        }
        do {    // the open never answers in its bound; it answers after: the cua is never sent
            let r = Rig(holdWork: true); openOK(r.mock)
            let g = r.goal(); g.start()
            r.timers.advance(bound - 1)
            check(g.state == .opening(sid: nil), "opening until its bound: \(g.state)")
            r.timers.advance(1)
            check(g.state == .failed(L.Why.noAnswer), "no answer in its bound: \(g.state)")
            r.drain()
            check(r.sent("cua").isEmpty, "the open answered after the goal failed: its cua never sent: \(r.sent("cua"))")
            ended(r, g, .failed(L.Why.noAnswer), "no answer")
        }
        do {    // opened, the send in flight when the bound runs out (it answers after, the cua sent): stopped
            let r = Rig(holdWork: true); openOK(r.mock)
            let g = r.goal(); g.start()
            r.mock.onRequest = { op in if op == SessionClient.Op.send, r.sent("cua").count == 1, r.sent("stop").isEmpty { r.timers.advance(bound) } }
            r.drain()
            r.mock.onRequest = nil
            check(g.state == .failed(L.Why.noAnswer, guarding: sid), "the bound ran out while the send went: \(g.state)")
            let sent = r.linesSent
            let cua = sent.firstIndex { $0.line["type"] as? String == "cua" }, stop = sent.lastIndex { $0.line["type"] as? String == "stop" }
            check(cua != nil && stop != nil && stop! > cua! && sent[stop!].sid == sid, "the cua that went is followed by a stop to its session: \(sent.map { $0.line["type"] ?? "" })")
            check(!r.m.client.state(sid).shownOutbox.contains { $0.id == g.cua }, "its cua retired: not shown in the chat")
            for l in taskLines { r.m.client.feed(l) }
            r.drain()
            check(r.sent("stop").contains { $0["run_id"] as? String == rid }, "its task that still came: stopped by its run")
            ended(r, g, .failed(L.Why.noAnswer), "the send after the bound")
        }
        do {    // sent, no task: 60 s (the opening's bound replaced, never firing on top)
            let r = Rig(); openOK(r.mock)
            let g = r.goal(); g.start()
            r.timers.advance(59)
            check(g.state == .sent(sid: sid, stopAsked: false), "sent, 59 s: \(g.state)")
            r.timers.advance(1)
            ended(r, g, .failed(L.Why.notStarted, guarding: sid), "no task in 60 s")
        }
        do {    // its cua refused by the session after it was sent: failed at once, in the session's words; no bubble left
            let r = Rig(); openOK(r.mock)
            let g = r.goal(); g.start()
            r.m.client.feed(["kind": "session.error", "session_id": sid, "code": "computer_busy", "text": "另一个对话在用电脑", "control": "cua", "client_id": g.cua])
            ended(r, g, .failed(L.Why.refused("computer_busy", text: "另一个对话在用电脑")), "cua refused by the session")
            check(GoalRunScreen(g.state, lang: .zhHans).line == "另一个对话在用电脑", "the session's words shown")
            let st = r.m.client.state(sid)
            check(st.unsent.isEmpty && st.shownOutbox.isEmpty, "its refused cua: no bubble in the chat")
            check(r.m.client.resend(g.cua, in: sid) != .sent && r.sent("cua").count == 1, "and never resent")
        }
        do {    // another refusal in its session (not its cua): nothing
            let r = Rig(); openOK(r.mock)
            let g = r.goal(); g.start()
            r.m.client.feed(["kind": "session.error", "session_id": sid, "code": "busy", "text": "x", "control": "say", "client_id": "c_other"])
            check(g.state == .sent(sid: sid, stopAsked: false), "another refusal: still waiting for its task: \(g.state)")
        }
        do {    // Stop before the task, nothing after: 15 s
            let r = Rig(); openOK(r.mock)
            let g = r.goal(); g.start()
            g.stop()
            let stop = r.mock.requests.last { ($0["line"] as? [String: Any])?["type"] as? String == "stop" }
            check(stop?["session_id"] as? String == sid && (stop?["line"] as? [String: Any])?["run_id"] == nil, "Stop before the task: to its session, no run: \(String(describing: stop))")
            check(GoalRunScreen(g.state, lang: .en).stopShown && !GoalRunScreen(g.state, lang: .en).stopLive, "Stop asked: greyed")
            r.timers.advance(15)
            ended(r, g, .failed(L.Why.stoppedBeforeStart, guarding: sid), "stopped before it started")
        }
        do {    // Stop before the task, then the task comes: stopped by its run; its end ends the goal
            let r = Rig(); openOK(r.mock)
            let g = r.goal(); g.start(); g.stop()
            for l in taskLines { r.m.client.feed(l) }
            check(g.state == .running(sid: sid, run: rid) && r.sent("stop").last?["run_id"] as? String == rid, "the task came after Stop: stopped by its run")
            r.m.client.feed(["kind": "session.task_end", "session_id": sid, "seq": 2, "run_id": rid, "status": "stopped", "summary": "", "undo": "none"])
            ended(r, g, .ended(sid: sid, run: rid, status: "stopped"), "stopped task")
        }
        do {    // a (stale) exit before its task, the cua then run by the reopened process: stopped by its run
            let r = Rig(); openOK(r.mock)
            let g = r.goal(); g.start()
            r.m.client.feed(exitLine)
            // (its stop with no run reaches no process: the client keeps it — the guard is what stops a task that comes)
            check(g.state == .failed(L.Why.gone, guarding: sid), "gone before its task: guarded: \(g.state)")
            r.m.client.feed(["kind": "session.start", "session_id": sid, "resumed": true, "last_seq": 0])
            for l in taskLines { r.m.client.feed(l) }
            check(r.sent("stop").contains { $0["run_id"] as? String == rid } && g.state == .failed(L.Why.gone), "the task that came anyway: stopped by its run")
            check(!g.watching && r.records.count == 1, "then let go; the record once")
        }
        do {    // the session gone mid-task: interrupted, no undo
            let r = Rig(); openOK(r.mock)
            let g = r.goal(); g.start()
            for l in taskLines { r.m.client.feed(l) }
            r.m.client.feed(exitLine)
            ended(r, g, .ended(sid: sid, run: rid, status: "interrupted"), "the session went mid-task")
            check(r.records.first?.task?.ended == true, "interrupted: the record has the task as it ended")
            check(g.task.map { !$0.task.resultCardState.undoEnabled } ?? false, "interrupted: no undo")
        }
    }

    // MARK: what the view shows

    static func goalScreenTests() {
        typealias S = GoalRunScreen
        func see(_ s: L.State, running: Bool, stop: Bool, live: Bool, after: Bool, task: String?, line: String?) {
            let v = S(s, lang: .en)
            check(v == S(running: running, stopShown: stop, stopLive: live, afterwards: after, taskRun: task, line: line), "\(s): \(v)")
        }
        see(.recordingStart, running: true, stop: false, live: false, after: false, task: nil, line: "Starting the recording…")
        see(.opening(sid: nil), running: true, stop: false, live: false, after: false, task: nil, line: "Getting ready…")
        see(.opening(sid: "s"), running: true, stop: false, live: false, after: false, task: nil, line: "Getting ready…")
        see(.sent(sid: "s", stopAsked: false), running: true, stop: true, live: true, after: false, task: nil, line: "Getting ready…")
        see(.sent(sid: "s", stopAsked: true), running: true, stop: true, live: false, after: false, task: nil, line: "Stopping…")
        see(.running(sid: "s", run: "r"), running: true, stop: true, live: true, after: false, task: "r", line: nil)
        see(.ended(sid: "s", run: "r", status: "failed"), running: false, stop: false, live: false, after: true, task: "r", line: nil)
        see(.failed(L.Why.noAnswer), running: false, stop: false, live: false, after: true, task: nil, line: "DeskMind's helper didn't answer. Try again.")
        check(S(.failed(L.Why.stoppedBeforeStart), lang: .zhHans).line == "还没开始就停下了。", "the reason in the user's language")
        // one goal at a time: Run again (a new request) while one is not over starts nothing; the same request (its
        // view came back) is the same goal, not opened again
        let r = Rig(); openOK(r.mock)
        let runs = GoalRuns()
        let a = UUID(), b = UUID()
        let g = runs.start(a) { r.goal() }
        check(g?.state == .sent(sid: sid, stopAsked: false) && r.opens == 1, "started")
        check(runs.start(b) { r.goal() } == nil && r.opens == 1, "another while it runs: none, no second session")
        check(runs.start(a) { r.goal() } === g && r.opens == 1, "its view back: the same goal")
        r.timers.advance(60)
        check(g?.state == .failed(L.Why.notStarted, guarding: sid) && runs.run(a) != nil, "failed, guarding its session: still kept")
        let g2 = runs.start(b) { r.goal() }
        check(g2 != nil && g2 !== g && r.opens == 2, "once it is over: the next")
        // let go once done: its watch cancelled, nothing kept but its last state
        r.timers.advance(60)
        check(runs.run(a) == nil && g?.watching == false, "done (guard over): let go, its watch cancelled")
        do {
            let back = runs.start(a) { r.goal() }
            check(back?.state == .failed(L.Why.notStarted) && back?.watching == false && r.opens == 2, "its view back: its last state, never run again")
        }
        do {    // ended: nothing holds it once no view does
            let r2 = Rig(); openOK(r2.mock)
            let runs2 = GoalRuns(), id = UUID()
            weak var w: GoalRun?
            do {
                let g = runs2.start(id) { r2.goal() }
                w = g
                for l in taskLines + endLines { r2.m.client.feed(l) }
                check(g?.state == .ended(sid: sid, run: rid, status: "succeeded") && g?.watching == false, "ended: its watch cancelled")
                check(g?.task?.task.ended == true, "and its task still read, from the shell")
            }
            check(w == nil && runs2.run(id) == nil, "ended, no view: released")
        }
    }
}

extension GoalRunScreen {
    init(running: Bool, stopShown: Bool, stopLive: Bool, afterwards: Bool, taskRun: String?, line: String?) {
        self.init(.idle, lang: .en)
        self.running = running; self.stopShown = stopShown; self.stopLive = stopLive; self.afterwards = afterwards; self.taskRun = taskRun; self.line = line
    }
}
