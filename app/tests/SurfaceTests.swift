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
        DecisionTests.group("surface.goalReopenTests"); goalReopenTests()
        DecisionTests.group("surface.goalClosableTests"); goalClosableTests()
        DecisionTests.group("surface.goalStopTests"); goalStopTests()
        DecisionTests.group("surface.goalCardKeysTests"); goalCardKeysTests()
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
        check(L.openingBound == bound, "the opening waits longer than the open and a send that reopens: \(L.openingBound)")
        let open: [L.Effect] = [.deadline(seconds: bound), .open]
        /// stop {client_id} to "s", sent again every 15 s until answered
        let stopCua: [L.Effect] = [.resend(seconds: 15), .sendStopCua(sid: "s")]
        row(.idle, .start(record: true), .recordingStart, [.beginRecording], "recorded: the recording first")
        row(.idle, .start(record: false), .opening(sid: nil), open, "not recorded: open at once, its bound")
        row(.recordingStart, .recordingStarted, .opening(sid: nil), open, "the recording started (or could not): open")
        row(.recordingStart, .stop, .recordingStart, [], "Stop while recording starts: hidden, nothing")
        // opening, no session yet
        row(.opening(sid: nil), .opened(sid: "s"), .opening(sid: "s"), [], "opened: its session id")
        row(.opening(sid: nil), .stop, .opening(sid: nil, stopAsked: true), [], "Stop before the session: asked (its cua held)")
        row(.opening(sid: nil, stopAsked: true), .opened(sid: "s"), .stopping(sid: "s"), stopCua, "then opened: stop {client_id}")
        for e: L.Event in [.openFailed, .unavailable, .deadline, .cloudRefused] {
            row(.opening(sid: nil, stopAsked: true), e, .failed(L.Why.stoppedBeforeStart), end, "Stop asked, never opened: no cua went")
        }
        row(.opening(sid: nil), .cloudRefused, .failed(L.Why.cloudOff), end, "cloud off")
        row(.opening(sid: nil), .openFailed, .failed(L.Why.noHelper), end, "the open failed")
        row(.opening(sid: nil), .deadline, .failed(L.Why.noAnswer), end, "no answer, nothing opened (the cua is never sent: GoalTicket)")
        row(.opening(sid: nil), .deadline, rec: false, .failed(L.Why.noAnswer), [.writeRecord], "not recorded: no recording to stop")
        // opening, its session open
        row(.opening(sid: "s"), .stop, .stopping(sid: "s"), stopCua, "Stop while the cua goes: stop {client_id}")
        row(.opening(sid: "s"), .unavailable, .failing(L.Why.noHelper, sid: "s"), stopCua, "the helper unavailable: the cua may be on its way — stopped, confirmed")
        row(.opening(sid: "s"), .deadline, .failing(L.Why.noAnswer, sid: "s"), stopCua, "the send never answered: stopped, confirmed")
        row(.opening(sid: "s"), .refused("no_model"), .failed(L.Why.refused("no_model")), end + [.retire(sid: "s")], "cua refused by the send: retired")
        row(.opening(sid: "s"), .sessionRefused(code: "computer_busy", text: "另一个对话在用电脑"), .failed(L.Why.refused("computer_busy", text: "另一个对话在用电脑")),
            end + [.retire(sid: "s")], "cua refused by the session (before the send's ok)")
        row(.opening(sid: "s"), .sent, .sent(sid: "s"), [.deadline(seconds: 60)], "sent: 60 s for its task")
        row(.opening(sid: "s"), .taskStarted(run: "r"), .running(sid: "s", run: "r"), [], "its task's lines before the send's ok")
        row(.opening(sid: nil), .sent, .opening(sid: nil), [], "(sent with no session id: nothing)")
        // sent
        row(.sent(sid: "s"), .taskStarted(run: "r"), .running(sid: "s", run: "r"), [], "its task")
        row(.sent(sid: "s"), .stop, .stopping(sid: "s"), stopCua, "Stop before the task: stop {client_id}, never a local ending")
        row(.sent(sid: "s"), .sessionRefused(code: "computer_busy", text: "t"), .failed(L.Why.refused("computer_busy", text: "t")),
            end + [.retire(sid: "s")], "its cua refused by the session: at once")
        row(.sent(sid: "s"), .sessionRefused(code: "cancelled", text: ""), .failed(L.Why.stoppedBeforeStart), end + [.retire(sid: "s")],
            "its cua refused `cancelled` (a stop came first): stopped before it started")
        row(.sent(sid: "s"), .exited, .failing(L.Why.gone, sid: "s"), stopCua, "the session went (perhaps a stale exit): stopped, confirmed")
        row(.sent(sid: "s"), .deadline, .failing(L.Why.notStarted, sid: "s"), stopCua, "no task in 60 s: stopped, confirmed")
        // running
        row(.running(sid: "s", run: "r"), .stop, .running(sid: "s", run: "r"), [.sendStop(sid: "s", run: "r")], "Stop: its run, its session")
        row(.running(sid: "s", run: "r"), .deadline, .running(sid: "s", run: "r"), [], "an older deadline: nothing")
        row(.running(sid: "s", run: "r"), .taskEnded(status: "succeeded"), .ended(sid: "s", run: "r", status: "succeeded"), end, "its end")
        row(.running(sid: "s", run: "r"), .exited, .ended(sid: "s", run: "r", status: "interrupted"), end, "the session went mid-task: interrupted")
        // stopping: only the session's answer ends it
        row(.stopping(sid: "s"), .taskStarted(run: "r"), .stopping(sid: "s", run: "r"), [], "its task came: the stop covers it")
        row(.stopping(sid: "s", run: "r"), .taskEnded(status: "stopped"), .ended(sid: "s", run: "r", status: "stopped"), end, "its task ended")
        row(.stopping(sid: "s"), .stopAck(result: "stopped", run: "r", status: "stopped"), .ended(sid: "s", run: "r", status: "stopped"), end, "ack stopped: ended, its run")
        row(.stopping(sid: "s"), .stopAck(result: "already_ended", run: "r", status: "succeeded"), .ended(sid: "s", run: "r", status: "succeeded"), end,
            "ack already_ended: ended as it ended")
        row(.stopping(sid: "s"), .stopAck(result: "none", run: nil, status: nil), .failed(L.Why.stoppedBeforeStart), end + [.retire(sid: "s")],
            "ack none: stopped before it started (its cua cancelled)")
        row(.stopping(sid: "s"), .sessionRefused(code: "cancelled", text: ""), .failed(L.Why.stoppedBeforeStart), end + [.retire(sid: "s")], "its cua refused: stopped before it started")
        for e: L.Event in [.deadline, .exited, .stop, .stopSent] {
            row(.stopping(sid: "s"), e, .stopping(sid: "s"), [], "stopping: no local ending (\(e))")
        }
        row(.stopping(sid: "s"), .resend, .stopping(sid: "s"), stopCua, "no answer yet: sent again (a reconnect, a reopen)")
        row(.stopping(sid: "s"), .stopUnsent, .stopping(sid: "s", misses: 1), [.resend(seconds: 2)], "the helper did not take it: retried")
        row(.stopping(sid: "s", misses: 1), .stopUnsent, .stopping(sid: "s", misses: 2), [.resend(seconds: 4)], "the retry failed too: backoff")
        row(.stopping(sid: "s", misses: 5), .stopUnsent, .stopping(sid: "s", misses: 6), [.resend(seconds: 30)], "backoff capped at 30 s")
        row(.stopping(sid: "s", misses: 3), .stopSent, .stopping(sid: "s"), [], "the helper took it: not unanswered any more")
        // failing: the session's answer ends it as failed
        for e: L.Event in [.stopAck(result: "none", run: nil, status: nil), .stopAck(result: "stopped", run: "r", status: "stopped"),
                           .stopAck(result: "already_ended", run: "r", status: "failed"), .sessionRefused(code: "cancelled", text: "")] {
            row(.failing(L.Why.notStarted, sid: "s"), e, .failed(L.Why.notStarted), end + [.retire(sid: "s")], "failing, answered: failed")
        }
        for e: L.Event in [.deadline, .exited, .stop, .taskStarted(run: "r")] {
            row(.failing(L.Why.notStarted, sid: "s"), e, .failing(L.Why.notStarted, sid: "s"), [], "failing: no local ending (\(e))")
        }
        row(.failing(L.Why.gone, sid: "s"), .resend, .failing(L.Why.gone, sid: "s"), stopCua, "failing: sent again")
        row(.failing(L.Why.gone, sid: "s"), .stopUnsent, .failing(L.Why.gone, sid: "s", misses: 1), [.resend(seconds: 2)], "failing: retried")
        // over: nothing changes it, nothing is done again
        let events: [L.Event] = [.start(record: true), .recordingStarted, .opened(sid: "x"), .openFailed, .cloudRefused, .sent, .refused("x"),
                                 .sessionRefused(code: "x", text: ""), .unavailable, .taskStarted(run: "x"), .taskEnded(status: "failed"),
                                 .exited, .stop, .deadline, .stopAck(result: "none", run: nil, status: nil), .stopSent, .stopUnsent, .resend]
        for s: L.State in [.ended(sid: "s", run: "r", status: "succeeded"), .failed(L.Why.noAnswer)] {
            for e in events { row(s, e, s, [], "over") }
        }
        // never a run-less stop: every stop a transition calls for names a run or the goal's cua
        let states: [L.State] = [.idle, .recordingStart, .opening(sid: nil), .opening(sid: "s"), .opening(sid: nil, stopAsked: true), .sent(sid: "s"),
                                 .running(sid: "s", run: "r"), .stopping(sid: "s"), .stopping(sid: "s", run: "r"), .failing(L.Why.gone, sid: "s")]
        for s in states { for e in events { _ = L.next(s, e, recording: true) } }   // (sendStop's run is not optional: by type)
        // its own session's state as events
        var ss = SessionState()
        check(L.observed(.sent(sid: "s"), ss, cua: "c_1") == nil, "no task yet: nothing")
        ss.outbox = [Outgoing(id: "c_other", text: "x", control: "say", sending: false, refused: "busy")]
        ss.lastRefusal = SessionErrorEvent(code: "busy", text: "x", clientId: "c_other")
        check(L.observed(.sent(sid: "s"), ss, cua: "c_1") == nil, "another refusal: not its own")
        ss.outbox.append(Outgoing(id: "c_1", text: "g", control: "cua", sending: false, refused: "exited"))
        check(L.observed(.sent(sid: "s"), ss, cua: "c_1") == nil, "its process's end is not a refusal")
        ss.outbox[1].refused = "computer_busy"
        ss.lastRefusal = SessionErrorEvent(code: "computer_busy", text: "另一个对话在用电脑", clientId: "c_1")
        check(L.observed(.sent(sid: "s"), ss, cua: "c_1") == .sessionRefused(code: "computer_busy", text: "另一个对话在用电脑"),
              "its own cua refused, with the session's words")
        ss = SessionState(); ss.exited = 0
        check(L.observed(.sent(sid: "s"), ss, cua: "c_1") == .exited, "gone before the task")
        check(L.observed(.opening(sid: "s"), ss, cua: "c_1") == nil, "(opening: the send says what came of it)")
        check(L.observed(.stopping(sid: "s"), ss, cua: "c_1") == nil && L.observed(.failing(L.Why.gone, sid: "s"), ss, cua: "c_1") == nil,
              "stopping / failing: an exit ends nothing (the stop is sent again; the send reopens)")
        ss.stopAcks["c_other"] = SessionStopAck(clientId: "c_other", result: "none")
        check(L.observed(.stopping(sid: "s"), ss, cua: "c_1") == nil, "another cua's ack: not its own")
        ss.stopAcks["c_1"] = SessionStopAck(clientId: "c_1", result: "stopped", runId: "r", status: "stopped")
        check(L.observed(.stopping(sid: "s"), ss, cua: "c_1") == .stopAck(result: "stopped", run: "r", status: "stopped"), "its own ack")
        ss = SessionState(); ss.cancelledCuas = ["c_1"]
        check(L.observed(.failing(L.Why.gone, sid: "s"), ss, cua: "c_1") == .stopAck(result: "none", run: nil, status: nil),
              "its cua cancelled (stored): as an ack of none")
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
        final class Held { var work: [() -> Void] = []; var deliver: [() -> Void] = [] }
        /// The work queue's jobs while `holdWork` (an open or a send that has not answered yet).
        let held = Held()
        init(_ mock: Mock = Mock(), cloudOn: Bool = true, holdWork: Bool = false, holdDeliver: Bool = false) {
            self.mock = mock
            let client = SessionClient(transport: mock)
            client.newClientId = { "c_1" }
            let held = held
            m = ShellModel(client: client, defaults: ShellTests.scratchDefaults(), config: { "openai:local|fake" }, lang: { .zhHans },
                           cloudOn: { cloudOn }, takeBackAfter: timers.after, now: { [timers] in timers.now },
                           work: { f in if holdWork { held.work.append(f) } else { f() } },
                           deliver: { f in if holdDeliver { held.deliver.append(f) } else { f() } })
        }
        /// The held jobs run, in order (and those they queue).
        func drain() { while !held.work.isEmpty { held.work.removeFirst()() } }
        /// The held hand-overs to the UI queue run (one flush takes every session that changed meanwhile: one update).
        func drainDeliver() { while !held.deliver.isEmpty { held.deliver.removeFirst()() } }
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
        /// Stops that name neither a run nor a cua: a goal never sends one (Codex review at 84d72f3).
        var runlessStops: Int { sent("stop").filter { $0["run_id"] == nil && $0["client_id"] == nil }.count }
        /// `stop {client_id}` lines sent.
        var cuaStops: [[String: Any]] { sent("stop").filter { $0["client_id"] != nil } }
        /// The session answers a stop {client_id} (session.stop_ack, not stored).
        func ack(_ result: String, run: String? = nil, status: String? = nil) {
            var l: [String: Any] = ["kind": "session.stop_ack", "session_id": SurfaceTests.sid, "client_id": "c_1", "result": result]
            if let run { l["run_id"] = run }
            if let status { l["status"] = status }
            m.client.feed(l)
        }
    }

    static let sid = "ses_goal", rid = "r_goal"
    static func openOK(_ mock: Mock) {
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": sid, "last_seq": 0], SessionClient.Op.send: ["ok": true]]
    }
    static let taskLines: [[String: Any]] = [
        // (as the harness stores a /cua: its words, with the cua's client_id, then the task replying to them)
        ["kind": "session.message", "session_id": sid, "seq": 1, "msg_id": "u1", "role": "user", "text": "把下载文件夹按类型整理", "via": "cua", "client_id": "c_1"],
        ["kind": "session.task", "session_id": sid, "seq": 2, "msg_id": "t1", "run_id": rid, "raw": "把下载文件夹按类型整理", "by": "slash", "reply_to": "u1", "client_id": "c_1"],
        ["kind": "start", "session_id": sid, "run_id": rid, "seq": 1, "raw": "把下载文件夹按类型整理"],
    ]
    static let endLines: [[String: Any]] = [
        ["kind": "task_done", "session_id": sid, "run_id": rid, "seq": 2, "status": "succeeded", "reason": "", "summary": "s", "undo_until": 2_000_000_000,
         "result_card": ["kind": "result", "text": "做了：移动 3 个文件", "blocking": false, "free_text": false,
                         "options": [["kind": "approve", "text": "Fine"], ["kind": "undo", "text": "Undo"]]]],
        ["kind": "session.task_end", "session_id": sid, "seq": 3, "run_id": rid, "status": "succeeded", "summary": "s", "undo": "open", "undo_until": 2_000_000_000],
    ]
    /// The user's own task in the goal's session (they typed there): not from the goal's cua.
    static let userTaskLines: [[String: Any]] = [
        ["kind": "session.message", "session_id": sid, "seq": 1, "msg_id": "m_user", "role": "user", "text": "顺便查下天气", "client_id": "c_user"],
        ["kind": "session.task", "session_id": sid, "seq": 2, "msg_id": "t_user", "run_id": "r_user", "raw": "查天气", "by": "model", "reply_to": "a_user"],
        ["kind": "start", "session_id": sid, "run_id": "r_user", "seq": 1, "raw": "查天气"],
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
        check(r.recordingBegins == 1 && g.state == .sent(sid: sid), "recorded, opened, sent: \(g.state)")
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
        /// Over as `want`: the record once, the recording stopped, Back and no Stop; later, nothing more — its watch of
        /// the session gone, no run-less stop.
        func ended(_ r: Rig, _ g: GoalRun, _ want: L.State, stops: Int = 1, _ what: String) {
            check(g.state == want, "\(what): \(g.state)")
            check(r.records.count == 1 && r.recordingStops == stops, "\(what): the record once, the recording stopped: \(r.records.count) \(r.recordingStops)")
            check(GoalRunScreen(g.state, lang: .en).afterwards && !GoalRunScreen(g.state, lang: .en).stopShown, "\(what): Back works, no Stop")
            let cuaStops = r.cuaStops.count
            r.timers.advance(3600); g.stop()
            check(r.records.count == 1 && r.recordingStops == stops && g.state == want, "\(what): nothing more after: \(g.state)")
            check(r.cuaStops.count == cuaStops, "\(what): no stop sent again once answered")
            check(!g.watching, "\(what): let go of its session")
            check(r.runlessStops == 0, "\(what): no run-less stop")
        }
        /// Waiting for the session's answer: not over, nothing written, no local ending however long.
        func waiting(_ r: Rig, _ g: GoalRun, _ what: String) {
            check(!L.over(g.state) && r.records.isEmpty && r.recordingStops == 0, "\(what): not over, nothing written: \(g.state)")
            let n = r.cuaStops.count
            r.timers.advance(600)
            check(!L.over(g.state) && r.records.isEmpty, "\(what): no local ending in 10 min: \(g.state)")
            check(r.cuaStops.count > n, "\(what): the stop sent again while unanswered (\(r.cuaStops.count - n) times)")
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
        do {    // the helper unavailable on the send: the cua may have gone — stop {client_id}, failed once answered
            let r = Rig(); r.mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": sid, "last_seq": 0], SessionClient.Op.send: ["ok": false]]
            let g = r.goal(); g.start()
            check(g.state == .failing(L.Why.noHelper, sid: sid, misses: 1), "unavailable: failing, its stop not taken either: \(g.state)")
            r.mock.replies[SessionClient.Op.send] = ["ok": true]
            r.timers.advance(2)
            check(g.state == .failing(L.Why.noHelper, sid: sid) && r.cuaStops.last?["client_id"] as? String == g.cua, "the helper back: its stop {client_id} taken")
            r.ack("none")
            ended(r, g, .failed(L.Why.noHelper), "unavailable")
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
        do {    // opened, the send in flight when the bound runs out (it answers after, the cua sent): stop {client_id}
            let r = Rig(holdWork: true); openOK(r.mock)
            let g = r.goal(); g.start()
            r.mock.onRequest = { op in if op == SessionClient.Op.send, r.sent("cua").count == 1, r.cuaStops.isEmpty { r.timers.advance(bound) } }
            r.drain()
            r.mock.onRequest = nil
            check(g.state == .failing(L.Why.noAnswer, sid: sid), "the bound ran out while the send went: failing: \(g.state)")
            check(r.cuaStops.first?["client_id"] as? String == g.cua, "its stop {client_id} sent")
            check(!r.m.client.state(sid).shownOutbox.contains { $0.id == g.cua } || true, "(its cua retired once answered)")
            for l in taskLines { r.m.client.feed(l) }
            check(g.state == .failing(L.Why.noAnswer, sid: sid), "its task came: the stop covers it, still waiting for the answer")
            r.m.client.feed(["kind": "session.task_end", "session_id": sid, "seq": 3, "run_id": rid, "status": "stopped", "summary": "", "undo": "none"])
            r.ack("stopped", run: rid, status: "stopped")
            ended(r, g, .failed(L.Why.noAnswer), "the send after the bound")
            check(!r.m.client.state(sid).shownOutbox.contains { $0.id == g.cua }, "its cua retired: not shown in the chat")
        }
        do {    // sent, no task in 60 s: stop {client_id}; failed only once the session answers
            let r = Rig(); openOK(r.mock)
            let g = r.goal(); g.start()
            r.timers.advance(59)
            check(g.state == .sent(sid: sid), "sent, 59 s: \(g.state)")
            r.timers.advance(1)
            check(g.state == .failing(L.Why.notStarted, sid: sid), "60 s: failing: \(g.state)")
            waiting(r, g, "no task in 60 s")
            r.ack("none")
            ended(r, g, .failed(L.Why.notStarted), "no task in 60 s")
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
            check(g.state == .sent(sid: sid), "another refusal: still waiting for its task: \(g.state)")
        }
        do {    // Codex (b767ca7): Stop before its task, the task's session.task delayed — no local ending; the session's
                // answer `stopped` ends it with that run and status
            let r = Rig(); openOK(r.mock)
            let g = r.goal(); g.start()
            g.stop()
            check(g.state == .stopping(sid: sid) && r.cuaStops.count == 1 && r.cuaStops.first?["client_id"] as? String == g.cua
                  && r.cuaStops.first?["run_id"] == nil, "Stop before the task: stop {client_id}: \(r.sent("stop"))")
            check(GoalRunScreen(g.state, lang: .en).stopShown && !GoalRunScreen(g.state, lang: .en).stopLive
                  && GoalRunScreen(g.state, lang: .en).line == "Stopping…", "stopping: Stop greyed, said")
            waiting(r, g, "stopped, its session.task late")
            r.ack("stopped", run: rid, status: "stopped")
            ended(r, g, .ended(sid: sid, run: rid, status: "stopped"), "stopped by the session")
        }
        do {    // Stop before the task, none came of it: the session cancels the cua — stopped before it started
            let r = Rig(); openOK(r.mock)
            let g = r.goal(); g.start(); g.stop()
            r.m.client.feed(["kind": "session.cua_cancelled", "session_id": sid, "seq": 1, "client_id": g.cua])
            r.ack("none")
            ended(r, g, .failed(L.Why.stoppedBeforeStart), "stopped before it started")
            check(!r.m.client.state(sid).shownOutbox.contains { $0.id == g.cua }, "its cua retired")
        }
        do {    // the cancel could not be stored: the session halts and acks none / interrupted — stopped before it started
            let r = Rig(); openOK(r.mock)
            let g = r.goal(); g.start(); g.stop()
            r.ack("none", status: "interrupted")
            ended(r, g, .failed(L.Why.stoppedBeforeStart), "none, interrupted (halted)")
        }
        do {    // Stop before the task, then the task comes: the stop covers it; already_ended from the history ends it
            let r = Rig(); openOK(r.mock)
            let g = r.goal(); g.start(); g.stop()
            for l in taskLines { r.m.client.feed(l) }
            check(g.state == .stopping(sid: sid, run: rid) && r.sent("stop").allSatisfy { $0["client_id"] != nil }, "its task came: still the stop {client_id}")
            r.ack("already_ended", run: rid, status: "succeeded")
            ended(r, g, .ended(sid: sid, run: rid, status: "succeeded"), "already ended")
        }
        do {    // Stop, the session gone before its answer: sent again (the send reopens it), answered from its history
            let r = Rig(); openOK(r.mock)
            let g = r.goal(); g.start(); g.stop()
            r.m.client.feed(exitLine)
            check(g.state == .stopping(sid: sid), "the session gone: still stopping")
            let n = r.cuaStops.count
            r.timers.advance(15)
            check(r.cuaStops.count == n + 1, "sent again after the exit")
            r.ack("already_ended", run: rid, status: "stopped")
            ended(r, g, .ended(sid: sid, run: rid, status: "stopped"), "answered after a reopen")
        }
        do {    // the helper does not take the stop: retried with backoff; after the first failed retry, said plainly;
                // never over until answered
            let r = Rig(); openOK(r.mock)
            let g = r.goal(); g.start()
            r.mock.replies[SessionClient.Op.send] = ["ok": false]
            g.stop()
            check(g.state == .stopping(sid: sid, misses: 1) && GoalRunScreen(g.state, lang: .en).line == "Stopping…", "not taken once: retried, not said yet")
            r.timers.advance(2)
            check(g.state == .stopping(sid: sid, misses: 2), "the first retry failed: \(g.state)")
            check(GoalRunScreen(g.state, lang: .en).line == "Can't confirm the stop: DeskMind's helper isn't answering. Quitting DeskMind ends the task.",
                  "said plainly: \(GoalRunScreen(g.state, lang: .en).line ?? "")")
            r.timers.advance(3600)
            check(!L.over(g.state) && r.records.isEmpty, "never made up: not over")
            r.mock.replies[SessionClient.Op.send] = ["ok": true]
            r.timers.advance(30)
            check(g.state == .stopping(sid: sid) && GoalRunScreen(g.state, lang: .en).line == "Stopping…", "the helper back: taken")
            r.ack("none")
            ended(r, g, .failed(L.Why.stoppedBeforeStart), "after the helper came back")
        }
        do {    // Stop before the open went: nothing opened, no cua — stopped before it started (provably: nothing sent)
            let r = Rig(holdWork: true); openOK(r.mock)
            let g = r.goal(); g.start()
            g.stop()
            check(g.state == .opening(sid: nil, stopAsked: true) && GoalRunScreen(g.state, lang: .en).stopShown, "Stop while opening: asked")
            r.drain()
            check(r.opens == 0 && r.sent("cua").isEmpty, "nothing opened, no cua")
            ended(r, g, .failed(L.Why.stoppedBeforeStart), "stopped before the open")
        }
        do {    // Stop while the open is under way: once opened, its cua held and stop {client_id} sent
            let r = Rig(holdWork: true); openOK(r.mock)
            let g = r.goal(); g.start()
            r.mock.onRequest = { op in if op == SessionClient.Op.open { g.stop() } }
            r.drain()
            r.mock.onRequest = nil
            check(r.sent("cua").isEmpty && g.state == .stopping(sid: sid) && r.cuaStops.count == 1, "opened: its cua never sent, stopping: \(g.state)")
            r.ack("none")
            ended(r, g, .failed(L.Why.stoppedBeforeStart), "stopped while opening")
        }
        do {    // a (stale) exit before its task: failing, stop {client_id}; the session answers stopped (its task ran)
            let r = Rig(); openOK(r.mock)
            let g = r.goal(); g.start()
            r.m.client.feed(exitLine)
            check(g.state == .failing(L.Why.gone, sid: sid), "gone before its task: failing: \(g.state)")
            r.m.client.feed(["kind": "session.start", "session_id": sid, "resumed": true, "last_seq": 0])
            for l in taskLines { r.m.client.feed(l) }
            r.ack("stopped", run: rid, status: "stopped")
            ended(r, g, .failed(L.Why.gone), "a stale exit")
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
        do {    // sent: a task of the user's own in the goal's session is not the goal's
            let r = Rig(); openOK(r.mock)
            let g = r.goal(); g.start()
            for l in userTaskLines { r.m.client.feed(l) }
            check(g.state == .sent(sid: sid) && g.task == nil, "the user's task: not adopted: \(g.state)")
            check(r.sent("stop").isEmpty, "and not stopped")
        }
        do {    // Codex on harness#72: a retry's task replies to the same message as the goal's cua — never the goal's
            let r = Rig(); openOK(r.mock)
            let g = r.goal(); g.start()
            r.m.client.feed(taskLines[0])           // the /cua's stored message (client_id c_1)
            r.m.client.feed(["kind": "session.task", "session_id": sid, "seq": 2, "msg_id": "t_retry", "run_id": "r_retry", "raw": "x",
                             "by": "model", "reply_to": "u1"])
            check(g.state == .sent(sid: sid) && g.task == nil, "a retry's task (same reply_to, no client_id): not adopted: \(g.state)")
            g.stop()
            check(!r.sent("stop").contains { $0["run_id"] as? String == "r_retry" }, "and never stopped by its run")
            r.m.client.feed(["kind": "session.task", "session_id": sid, "seq": 3, "msg_id": "t1", "run_id": rid, "raw": "x", "by": "slash",
                             "reply_to": "u1", "client_id": "c_1"])
            check(g.state == .stopping(sid: sid, run: rid), "its own (its client_id): the one it stops: \(g.state)")
        }
        do {    // stopping: the user's own task in the same session is neither its task nor stopped
            let r = Rig(); openOK(r.mock)
            let g = r.goal(); g.start(); g.stop()
            for l in userTaskLines { r.m.client.feed(l) }
            check(g.state == .stopping(sid: sid), "the user's task: not the goal's: \(g.state)")
            check(!r.sent("stop").contains { $0["run_id"] as? String == "r_user" } && r.runlessStops == 0, "the user's task left alone")
        }
        do {    // a retired cua that the process's end makes unsent again: hidden, never resent
            let r = Rig(holdWork: true); openOK(r.mock)
            let g = r.goal(); g.start()
            r.mock.onRequest = { op in if op == SessionClient.Op.send, r.sent("cua").count == 1, r.cuaStops.isEmpty { r.timers.advance(L.openingBound) } }
            r.drain()
            r.mock.onRequest = nil
            r.drain()
            r.ack("none")
            check(g.state == .failed(L.Why.noAnswer), "answered none: failed: \(g.state)")
            check(r.m.client.state(sid).outbox.contains { $0.id == g.cua && $0.sending }, "the cua in flight when retired: still in the outbox, sending")
            r.m.client.feed(exitLine)
            let st = r.m.client.state(sid)
            check(st.outbox.contains { $0.id == g.cua && !$0.sending && $0.refused == "exited" }, "the process's end makes it unsent (processGone)")
            check(!st.shownOutbox.contains { $0.id == g.cua } && !st.unsent.contains { $0.id == g.cua }, "retired: never shown")
            let cuas = r.sent("cua").count
            check(r.m.client.resend(g.cua, in: sid) != .sent && r.sent("cua").count == cuas, "retired: never resent")
        }
        do {    // Codex's repro (84d72f3): the user's own task runs in the goal's session; the goal is stopped before its
                // task — no run-less stop, no stop of the user's run
            let r = Rig(); openOK(r.mock)
            let g = r.goal(); g.start()
            for l in userTaskLines { r.m.client.feed(l) }
            g.stop()
            r.timers.advance(600)
            check(r.runlessStops == 0 && !r.sent("stop").contains { $0["run_id"] as? String == "r_user" }, "the user's task left alone: \(r.sent("stop"))")
            r.ack("none")
            check(r.records.count == 1 && !g.watching, "the goal over once answered, let go")
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
        see(.opening(sid: nil), running: true, stop: true, live: true, after: false, task: nil, line: "Getting ready…")
        see(.opening(sid: "s"), running: true, stop: true, live: true, after: false, task: nil, line: "Getting ready…")
        see(.opening(sid: nil, stopAsked: true), running: true, stop: true, live: false, after: false, task: nil, line: "Stopping…")
        see(.sent(sid: "s"), running: true, stop: true, live: true, after: false, task: nil, line: "Getting ready…")
        see(.stopping(sid: "s"), running: true, stop: true, live: false, after: false, task: nil, line: "Stopping…")
        see(.stopping(sid: "s", run: "r", misses: 2), running: true, stop: true, live: false, after: false, task: "r",
            line: "Can't confirm the stop: DeskMind's helper isn't answering. Quitting DeskMind ends the task.")
        see(.failing(L.Why.notStarted, sid: "s"), running: true, stop: false, live: false, after: false, task: nil,
            line: "The task didn't start. Try again.\nMaking sure it stopped…")
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
        check(g?.state == .sent(sid: sid) && r.opens == 1, "started")
        check(runs.start(b) { r.goal() } == nil && r.opens == 1, "another while it runs: none, no second session")
        check(runs.start(a) { r.goal() } === g && r.opens == 1, "its view back: the same goal")
        r.timers.advance(60)
        check(g?.state == .failing(L.Why.notStarted, sid: sid) && runs.run(a) != nil && runs.start(b) { r.goal() } == nil,
              "failing (its stop unanswered): still active, kept, no next")
        r.ack("none")
        check(runs.run(a) == nil && g?.watching == false, "answered: failed, let go, its watch cancelled")
        let g2 = runs.start(b) { r.goal() }
        check(g2 != nil && g2 !== g && r.opens == 2, "once it is over: the next")
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
    /// Codex review at 84d72f3 (1): the window is only minimised while a goal is not over; a window that opens again
    /// goes straight to the goal not over.
    static func goalReopenTests() {
        let a = UUID(), b = UUID()
        check(GoalRuns.reopenRoute(active: a, showing: nil) == a && GoalRuns.reopenRoute(active: a, showing: b) == a, "reopened: to the goal not over")
        check(GoalRuns.reopenRoute(active: a, showing: a) == nil && GoalRuns.reopenRoute(active: nil, showing: nil) == nil, "shown already, or none: as it is")
        let r = Rig(); openOK(r.mock)
        let runs = GoalRuns()
        let g = runs.start(a) { r.goal() }
        check(runs.active == a, "a goal sent, not over: active")
        for l in taskLines { r.m.client.feed(l) }
        check(runs.active == a, "running: active")
        for l in endLines { r.m.client.feed(l) }
        check(g?.state == .ended(sid: sid, run: rid, status: "succeeded") && runs.active == nil, "ended: none active (Home as usual)")
    }

    /// Codex delta review at 1f77d1a (2): the window's close button is GoalRuns' alone — closable exactly while no
    /// goal is active, told on every change (start, end, failing then failed, released), no view involved. (minor) a
    /// released goal's request goes. Codex review at b767ca7 (P2): a reopen while a goal is active restores the window
    /// (hands#69 gives the front back without a reopen); the old engine's run and the 0.5 window's task still hold it.
    static func goalClosableTests() {
        check(Activation.reopenRestores(oldRunWithoutCard: false, shellTaskWithoutCard: false, goalActive: true), "a goal active: the reopen restores")
        check(!Activation.reopenRestores(oldRunWithoutCard: true, shellTaskWithoutCard: false, goalActive: false)
              && !Activation.reopenRestores(oldRunWithoutCard: false, shellTaskWithoutCard: true, goalActive: false), "an old run / a shell task without card: held, as before")
        do {    // start → end → released
            let r = Rig(); openOK(r.mock)
            var closable: [Bool] = [], released: [UUID] = []
            let runs = GoalRuns(setClosable: { closable.append($0) }, released: { released.append($0) })
            let a = UUID()
            let g = runs.start(a) { r.goal() }
            check(closable == [false], "started: not closable: \(closable)")
            check(Activation.reopenRestores(oldRunWithoutCard: false, shellTaskWithoutCard: false, goalActive: runs.active != nil) && runs.active == a,
                  "a goal active, no card: the user's reopen (Dock, live card) restores the window")
            for l in taskLines { r.m.client.feed(l) }
            r.m.client.feed(["kind": "ask", "session_id": sid, "run_id": rid, "seq": 2, "ask_id": "ask_g",
                             "card": ["kind": "missing", "text": "发给谁？", "free_text": false, "blocking": true,
                                      "options": [["kind": "value", "text": "小王"], ["kind": "cancel", "text": "先别做了"]]]])
            check(g?.task != nil && Activation.reopenRestores(oldRunWithoutCard: false, shellTaskWithoutCard: false, goalActive: true),
                  "its card waits: restores too")
            for l in endLines { r.m.client.feed(l) }
            check(closable == [false, true] && released == [a], "ended: closable, released once: \(closable) \(released)")
        }
        do {    // failing, its stop unanswered: not closable, kept; answered: closable, released once
            let r = Rig(); openOK(r.mock)
            var closable: [Bool] = [], released: [UUID] = []
            let runs = GoalRuns(setClosable: { closable.append($0) }, released: { released.append($0) })
            let a = UUID()
            let g = runs.start(a) { r.goal() }
            r.timers.advance(60)
            check(g?.state == .failing(L.Why.notStarted, sid: sid) && closable == [false] && released.isEmpty,
                  "failing: still active, not closable: \(closable)")
            r.ack("none")
            check(closable == [false, true] && released == [a], "answered: failed, closable, released")
            let b = UUID()
            _ = runs.start(b) { r.goal() }
            check(closable == [false, true, false], "the next goal: not closable again")
        }
    }

    /// Codex delta review at 1f77d1a (4): every Stop on the goal screen is the goal's (GoalRun.stop — TaskRow's Stop,
    /// the screen's button and ⌘., the island's): in every state, with the user's own task streaming in its session,
    /// never a run-less stop.
    static func goalStopTests() {
        let r = Rig(); openOK(r.mock)
        let g = r.goal(); g.start()
        for l in userTaskLines { r.m.client.feed(l) }
        g.stop()                                    // sent
        for l in taskLines.map({ l -> [String: Any] in
            var l = l
            if l["kind"] as? String == "session.message" { l["seq"] = 3 }
            if l["kind"] as? String == "session.task" { l["seq"] = 4 }
            return l
        }) { r.m.client.feed(l) }
        g.stop()                                    // running
        r.m.client.feed(["kind": "session.task_end", "session_id": sid, "seq": 5, "run_id": rid, "status": "stopped", "summary": "", "undo": "none"])
        g.stop()                                    // ended
        check(r.runlessStops == 0 && !r.sent("stop").contains { $0["run_id"] as? String == "r_user" },
              "the goal screen's Stop: never run-less, never the user's task: \(r.sent("stop"))")
        check(r.sent("stop").allSatisfy { $0["run_id"] as? String == rid || $0["client_id"] as? String == g.cua } && !r.sent("stop").isEmpty,
              "only its own: its cua (stop {client_id}) or its task's run")
    }

    /// Codex review at 84d72f3 (3): the goal's pinned card takes 1–9 and Esc / Tab through the chat's one wiring
    /// (ShellModel.cardKeyHandlers, which the goal screen's CardKeyMonitor installs too).
    static func goalCardKeysTests() {
        let r = Rig(); openOK(r.mock)
        let g = r.goal(); g.start()
        for l in taskLines { r.m.client.feed(l) }
        r.m.client.feed(["kind": "ask", "session_id": sid, "run_id": rid, "seq": 2, "ask_id": "ask_g",
                         "card": ["kind": "missing", "text": "发给谁？", "free_text": false, "blocking": true,
                                  "options": [["kind": "value", "text": "小王"], ["kind": "cancel", "text": "先别做了"]]]])
        guard let (s, _) = g.task, let p = r.m.pinned(s) else { check(false, "the goal's card is pinned"); return }
        let m = CardModel(card: p.card.card, runId: p.runId, askId: p.card.askId)
        r.m.cardShown(m)
        r.m.cardBody(m, contentHeight: 1, visibleHeight: 1, offset: 0)
        r.timers.advance(5)
        let keys = r.m.cardKeyHandlers
        _ = keys.onKey("\t", false, true, false, false, false)
        check(r.m.keysActive(m), "Tab: the goal's card takes its keys")
        keys.onLeave()
        check(!r.m.keysActive(m), "the window left: its keys end (onLeave)")
        keys.onReturn()
        r.timers.advance(2)
        _ = keys.onKey("\t", false, true, false, false, false)
        check(keys.onKey("1", false, true, false, false, false), "1: its first option picked")
        r.timers.advance(5)
        let answers = r.sent("answer")
        check(answers.count == 1 && answers.first?["ask_id"] as? String == "ask_g", "its answer sent once: \(answers)")
    }


}

extension GoalRunScreen {
    init(running: Bool, stopShown: Bool, stopLive: Bool, afterwards: Bool, taskRun: String?, line: String?) {
        self.init(.idle, lang: .en)
        self.running = running; self.stopShown = stopShown; self.stopLive = stopLive; self.afterwards = afterwards; self.taskRun = taskRun; self.line = line
    }
}
