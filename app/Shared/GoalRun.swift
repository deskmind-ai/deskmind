// One goal from the home screen's GoalRunView, run as a session task (harness engine): its lifecycle, keyed on this
// goal's own session and its own task — never on the selected session's newest task (#118 review at 6554042:
// inferring "running" from tasks.last let Run again open a second session, left Stop reaching nothing, and left a
// goal that never got a task "Getting ready…" for good with its recording never stopped).
//
// GoalLifecycle is pure (state × event → state, and the side effects it calls for). GoalRun applies it: the open and
// the send's results (ShellModel.startTask's report), this goal's own session's state, the deadlines, the recording,
// the recent-runs record. GoalRuns keeps a GoalRun by its request while it is not over (and while it guards its
// session, below), so the lifecycle and its once-only effects outlive the view; then it lets it go — its watch of the
// session cancelled — and keeps only its last state, for a view that comes back.
//
// Invariant (#118 delta review at 4ff4f6d): once a goal is over, nothing it started acts. Its cua is never sent after
// it is over (GoalTicket: openThenSend checks it before the send, and stops the session if it became over while the
// send went); a goal that fails with a session whose cua may be on its way stops that session, retires its cua (never
// shown as a bubble to resend, never resent: SessionClient.retire) and guards the session for `sentBound` — a task
// that still comes is stopped by its run.
//
// | state                  | event                    | next                     | effects                         |
// |------------------------|--------------------------|--------------------------|---------------------------------|
// | idle                   | start(record)            | recordingStart           | begin the recording             |
// | idle                   | start(no record)         | opening                  | open + send cua; opening bound  |
// | recordingStart         | recordingStarted         | opening                  | open + send cua; opening bound  |
// |   (its 25 s bound: RunRecorder.begin, Main/Recording.swift — DeskMindIPC.request(body, timeout: 25), then
// |    `started(false)`: the goal goes on unrecorded, as before)                                                     |
// | opening                | opened(sid)              | opening(sid)             | —                               |
// | opening                | cloudRefused / openFailed| failed(why)              | end                             |
// | opening(sid?)          | unavailable / deadline   | failed(why), guarding sid| end; guard                      |
// |   (the opening bound: SessionClient.openTimeout + SessionClient.sendTimeout + 5 s — the open, then a send that
// |    may reopen the session — never shorter than what it waits for)                                               |
// | opening(sid?) / sent   | refused(code) (the send) | failed(refused)          | end; retire the cua             |
// | opening(sid?) / sent   | sessionRefused (its cua) | failed(the harness's words) | end; retire the cua          |
// | opening(sid)           | sent                     | sent(sid)                | 60 s bound                      |
// | opening(sid)           | taskStarted(run)         | running(sid, run)        | — (its lines before send's ok)  |
// | sent(sid)              | taskStarted(run)         | running(sid, run)        | —                               |
// | sent(sid)              | stop                     | sent(sid, stop asked)    | stop to sid (no run); 15 s bound|
// | sent(sid)              | exited                   | failed(session gone), guarding sid | end; guard            |
// | sent(sid)              | deadline (60 s)          | failed(task didn't start), guarding | end; guard           |
// | sent(sid, stop asked)  | taskStarted(run)         | running(sid, run)        | stop(run) to sid                |
// | sent(sid, stop asked)  | exited / deadline (15 s) | failed(stopped before it started), guarding | end; guard   |
// | running(sid, run)      | stop                     | running                  | stop(run) to sid                |
// | running(sid, run)      | taskEnded(status)        | ended(status)            | end                             |
// | running(sid, run)      | exited                   | ended(interrupted)       | end (no undo: cut off)          |
// | failed, guarding sid   | taskStarted(run)         | failed                   | stop(run) to sid                |
// | failed, guarding sid   | refused / deadline       | failed                   | —                               |
// |   (an exit does not end the guard — it may be stale; GoalLifecycle.observed never reports one then)            |
// | ended / failed         | anything else            | the same                 | —                               |
// | any other pair         |                          | the same                 | —                               |
//
// end: stop the recording when this goal records, write the recent-runs record — entering ended or failed, once.
// guard: stop to sid (no run), retire the cua, 60 s bound (failed keeps guarding sid until a task comes, the session
// goes, or the bound). What the screen shows comes from the state alone (GoalRunScreen): Stop is shown in sent and
// running (greyed once asked in sent), hidden before; Back / Edit / Run again only in ended and failed — so a goal
// starts a session only from idle, and no second one while it is not over.

import Combine
import Foundation

enum GoalLifecycle {
    enum State: Equatable {
        case idle
        case recordingStart
        case opening(sid: String?)
        case sent(sid: String, stopAsked: Bool)
        case running(sid: String, run: String)
        case ended(sid: String, run: String, status: String)
        /// `guarding`: the session its cua may still reach (nil: none, or no longer).
        case failed(String, guarding: String? = nil)
    }

    enum Event: Equatable {
        case start(record: Bool)
        case recordingStarted
        case opened(sid: String)
        case openFailed
        case cloudRefused
        case sent
        case refused(String)
        /// The session refused this goal's own cua (its client id): its code and words.
        case sessionRefused(code: String, text: String)
        case unavailable
        case taskStarted(run: String)
        case taskEnded(status: String)
        case exited
        case stop
        case deadline
    }

    enum Effect: Equatable {
        case beginRecording
        case open
        case sendStop(sid: String, run: String?)
        /// The goal's cua in `sid` is never resent nor shown as a bubble to resend (SessionClient.retire).
        case retire(sid: String)
        /// A deadline `seconds` from now; a newer one replaces it.
        case deadline(seconds: Double)
        case stopRecording
        case writeRecord
    }

    /// The open, then the send (which may reopen the session): what the opening waits for, from the client's own
    /// timeouts, and a margin.
    static let openingBound: Double = SessionClient.openTimeout + SessionClient.sendTimeout + 5
    static let sentBound: Double = 60
    static let stopBound: Double = 15

    /// Why a goal failed (GoalRunScreen says it in words).
    enum Why {
        static let cloudOff = "cloud_off"
        static let noHelper = "helper_unavailable"
        static let noAnswer = "helper_no_answer"
        static let notStarted = "task_not_started"
        static let stoppedBeforeStart = "stopped_before_start"
        static let gone = "session_gone"
        /// (GoalRuns started no goal: another one is not over)
        static let busy = "another_goal_running"
        /// Refused: its code, and the session's words when it said any.
        static func refused(_ code: String, text: String = "") -> String { "refused:" + code + "|" + text }
        static func refusal(_ why: String) -> (code: String, text: String)? {
            guard why.hasPrefix("refused:") else { return nil }
            let rest = why.dropFirst("refused:".count)
            guard let bar = rest.firstIndex(of: "|") else { return (String(rest), "") }
            return (String(rest[..<bar]), String(rest[rest.index(after: bar)...]))
        }
    }

    /// The next state and what it calls for. `recording`: this goal records (its recording is stopped at its end).
    static func next(_ s: State, _ e: Event, recording: Bool) -> (State, [Effect]) {
        let end: [Effect] = (recording ? [.stopRecording] : []) + [.writeRecord]
        // (the bound first: an open that answers at once — its `sent` sets the next bound — is never overtaken by it)
        let open: [Effect] = [.deadline(seconds: openingBound), .open]
        /// Failed with its cua perhaps on its way to `sid`: stopped, retired, guarded.
        func fail(_ why: String, _ sid: String?) -> (State, [Effect]) {
            guard let sid else { return (.failed(why), end) }
            return (.failed(why, guarding: sid), end + [.sendStop(sid: sid, run: nil), .retire(sid: sid), .deadline(seconds: sentBound)])
        }
        /// Failed with its cua refused: nothing on its way; the refused cua retired.
        func refusal(_ why: String, _ sid: String?) -> (State, [Effect]) {
            (.failed(why), end + (sid.map { [.retire(sid: $0)] } ?? []))
        }
        switch (s, e) {
        case (.idle, .start(let record)):
            return record ? (.recordingStart, [.beginRecording]) : (.opening(sid: nil), open)
        case (.recordingStart, .recordingStarted):
            return (.opening(sid: nil), open)

        case (.opening(nil), .opened(let sid)): return (.opening(sid: sid), [])
        case (.opening, .cloudRefused): return (.failed(Why.cloudOff), end)
        case (.opening(let sid), .openFailed): return fail(Why.noHelper, sid)
        case (.opening(let sid), .unavailable): return fail(Why.noHelper, sid)
        case (.opening(let sid), .refused(let code)): return refusal(Why.refused(code), sid)
        case (.opening(let sid), .sessionRefused(let code, let text)): return refusal(Why.refused(code, text: text), sid)
        case (.opening(let sid), .deadline): return fail(Why.noAnswer, sid)
        case (.opening(let sid?), .sent): return (.sent(sid: sid, stopAsked: false), [.deadline(seconds: sentBound)])
        case (.opening(let sid?), .taskStarted(let run)): return (.running(sid: sid, run: run), [])

        case (.sent(let sid, let asked), .taskStarted(let run)):
            return (.running(sid: sid, run: run), asked ? [.sendStop(sid: sid, run: run)] : [])
        case (.sent(let sid, false), .stop):
            return (.sent(sid: sid, stopAsked: true), [.sendStop(sid: sid, run: nil), .deadline(seconds: stopBound)])
        case (.sent(let sid, _), .refused(let code)): return refusal(Why.refused(code), sid)
        case (.sent(let sid, _), .sessionRefused(let code, let text)): return refusal(Why.refused(code, text: text), sid)
        case (.sent(let sid, let asked), .exited): return fail(asked ? Why.stoppedBeforeStart : Why.gone, sid)
        case (.sent(let sid, let asked), .deadline): return fail(asked ? Why.stoppedBeforeStart : Why.notStarted, sid)

        case (.running(let sid, let run), .stop): return (s, [.sendStop(sid: sid, run: run)])
        case (.running(let sid, let run), .taskEnded(let status)): return (.ended(sid: sid, run: run, status: status), end)
        case (.running(let sid, let run), .exited): return (.ended(sid: sid, run: run, status: "interrupted"), end)

        // over, its cua perhaps still on its way: a task that comes is stopped; the session gone, the cua refused or
        // the bound: no longer guarded
        case (.failed(let why, let sid?), .taskStarted(let run)): return (.failed(why), [.sendStop(sid: sid, run: run)])
        case (.failed(let why, _?), .exited), (.failed(let why, _?), .deadline), (.failed(let why, _?), .refused),
             (.failed(let why, _?), .sessionRefused):
            return (.failed(why), [])

        default: return (s, [])
        }
    }

    /// What this goal's own session says now, as an event (nil: nothing for the lifecycle). `s`: the session's state;
    /// `cua`: the client id the goal's cua was sent with.
    static func observed(_ st: State, _ s: SessionState, cua: String) -> Event? {
        /// The session refused this goal's own cua (its outbox entry, by its client id — never another refusal). Not a
        /// refusal: its process's end ("exited": the send reopens it, `exited` says the rest), the helper not answering
        /// ("unavailable": the send's own result says it).
        func refusedCua() -> Event? {
            guard let o = s.outbox.first(where: { $0.id == cua }), !o.sending, let code = o.refused,
                  code != "exited", code != "unavailable" else { return nil }
            let text = s.lastRefusal.flatMap { $0.clientId == cua ? $0.text : nil } ?? ""
            return .sessionRefused(code: code, text: text)
        }
        switch st {
        case .opening(_?), .sent:
            // a new session of its own: its first task is the goal's
            if let t = s.tasks.first { return .taskStarted(run: t.runId) }
            if let r = refusedCua() { return r }
            if case .sent = st, s.exited != nil { return .exited }
            return nil
        case .running(_, let run):
            guard let t = s.task(run) else { return s.exited != nil ? .exited : nil }
            // (a task cut off by its process's exit has ended: `interrupted`, no undo)
            if t.ended { return .taskEnded(status: t.status ?? "interrupted") }
            return s.exited != nil ? .exited : nil
        case .failed(_, _?):
            // (an exit does not end the guard: it may be stale, the cua run by the process the send reopened — the
            // guard ends with a task, a refusal or its bound)
            if let t = s.tasks.first { return t.running ? .taskStarted(run: t.runId) : .exited }
            return refusedCua()
        default:
            return nil
        }
    }

    static func over(_ s: State) -> Bool {
        switch s { case .ended, .failed: return true; default: return false }
    }

    /// Over, and guarding nothing: its watch of the session can go.
    static func done(_ s: State) -> Bool {
        switch s { case .ended, .failed(_, nil): return true; default: return false }
    }
}

/// Whether a goal still wants its cua sent — read from the work queue (openThenSend), set on the UI queue.
final class GoalTicket {
    private let lock = NSLock()
    private var _over = false
    var over: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _over }
        set { lock.lock(); _over = newValue; lock.unlock() }
    }
}

/// What GoalRunView shows of a goal, from its state alone.
struct GoalRunScreen: Equatable {
    var running: Bool
    var stopShown: Bool
    var stopLive: Bool
    /// Back, Edit, Run again and the next instruction.
    var afterwards: Bool
    /// The task, shown with the chat's TaskRow (and the pinned card): its run.
    var taskRun: String?
    /// The line shown while there is no task to show, or why it failed.
    var line: String?

    init(_ s: GoalLifecycle.State, lang: ResolvedLang) {
        running = !GoalLifecycle.over(s) && s != .idle
        afterwards = GoalLifecycle.over(s)
        switch s {
        case .sent(_, let asked): stopShown = true; stopLive = !asked
        case .running: stopShown = true; stopLive = true
        default: stopShown = false; stopLive = false
        }
        switch s {
        case .running(_, let run), .ended(_, let run, _): taskRun = run; line = nil
        case .idle: taskRun = nil; line = nil
        case .recordingStart: taskRun = nil; line = L("Starting the recording…", lang: lang)
        case .opening: taskRun = nil; line = L("Getting ready…", lang: lang)
        case .sent(_, false): taskRun = nil; line = L("Getting ready…", lang: lang)
        case .sent(_, true): taskRun = nil; line = L("Stopping…", lang: lang)
        case .failed(let why, _): taskRun = nil; line = Self.why(why, lang: lang)
        }
    }

    static func why(_ why: String, lang: ResolvedLang) -> String {
        // refused: the session's own words when it said any, else what its code means
        if let r = GoalLifecycle.Why.refusal(why) { return r.text.isEmpty ? ShellText.unsent(r.code, lang: lang) : r.text }
        switch why {
        case GoalLifecycle.Why.cloudOff: return L("A conversation needs a cloud model. Turn it on in the model settings.", lang: lang)
        case GoalLifecycle.Why.noHelper: return L("Couldn't start a conversation. Is DeskMind's helper running?", lang: lang)
        case GoalLifecycle.Why.noAnswer: return L("DeskMind's helper didn't answer. Try again.", lang: lang)
        case GoalLifecycle.Why.notStarted: return L("The task didn't start. Try again.", lang: lang)
        case GoalLifecycle.Why.stoppedBeforeStart: return L("Stopped before it started.", lang: lang)
        case GoalLifecycle.Why.gone: return L("The conversation ended before the task started.", lang: lang)
        case GoalLifecycle.Why.busy: return L("Another task is still running. Try again once it ends.", lang: lang)
        default: return L("The task couldn't be sent. Try again.", lang: lang)
        }
    }
}

/// The record a goal leaves in the recent runs: its task as its session has it (ended), or why it failed.
struct GoalRecord: Equatable {
    var goal: String
    var folder: String?
    var sessionId: String?
    var task: TaskState?
    var failed: String?
}

/// The app's side of a goal's effects (the app: RunRecorder and RunHistory; a test: its own).
struct GoalRunEffects {
    /// Start the recording; `started` once it did or could not (bounded: RunRecorder.begin's 25 s).
    var beginRecording: (_ goal: String, _ started: @escaping () -> Void) -> Void
    /// Stop it; `done` with the movie (nil: none).
    var stopRecording: (_ record: GoalRecord, _ done: @escaping (URL?) -> Void) -> Void
    var writeRecord: (GoalRecord) -> Void
    var after: (Double, @escaping () -> Void) -> Void
    /// The goal's state or its session's changed (the app: its island and notifications, IslandFeed.frame(goal) —
    /// kept with the goal, so they follow it while no view shows it).
    var changed: (GoalRun) -> Void = { _ in }
}

/// One goal, as GoalLifecycle runs it. On the UI queue (the shell's).
final class GoalRun: ObservableObject {
    @Published private(set) var state: GoalLifecycle.State = .idle
    /// The recording's movie, once it is finished.
    @Published private(set) var movie: URL?
    let goal: String
    let folder: String?
    let record: Bool
    let shell: ShellModel
    /// Its own session, once opened.
    private(set) var sessionId: String?
    /// The client id its cua is sent with: its refusal is matched by it, and it is retired by it.
    let cua: String
    /// Whether it still wants its cua sent (openThenSend reads it).
    let ticket = GoalTicket()
    /// Called once, when it is over and guards nothing (GoalRuns lets it go then).
    var onDone: (() -> Void)?
    private let effects: GoalRunEffects
    private var watch: AnyCancellable?
    /// The newest deadline (a newer one replaces it).
    private var deadline = 0
    /// Its session's newest state, as the shell's `states` takes it: the sink runs before `states` is set, so what
    /// the goal reads (its task's end, the record) is this, never the shell's previous one. Dropped with the watch.
    private var latest: SessionState?

    init(goal: String, folder: String?, record: Bool, shell: ShellModel, effects: GoalRunEffects) {
        self.goal = goal; self.folder = folder; self.record = record; self.shell = shell; self.effects = effects
        cua = shell.client.newClientId()
    }

    /// Its session's state is being watched.
    var watching: Bool { watch != nil }

    /// The goal's task, as its session has it now (running or ended).
    var task: (session: SessionState, task: TaskState)? {
        guard let sid = sessionId, let s = latest ?? shell.states[sid] else { return nil }
        switch state {
        case .running(_, let run), .ended(_, let run, _): return s.task(run).map { (s, $0) }
        default: return nil
        }
    }

    func start() { send(.start(record: record)) }
    func stop() { send(.stop) }

    /// A goal that was over before (GoalRuns' last state of it, for a view that comes back): shown, never run.
    func restore(_ s: GoalLifecycle.State, sessionId: String?) {
        state = s; self.sessionId = sessionId; ticket.over = true
    }

    func send(_ e: GoalLifecycle.Event) {
        let before = state
        if case .opened(let sid) = e, sessionId == nil, case .opening(nil) = state { sessionId = sid }
        let (n, fx) = GoalLifecycle.next(state, e, recording: record)
        guard n != before || !fx.isEmpty else { return }
        state = n
        // (over: its cua is never sent from here — openThenSend reads this before the send)
        if GoalLifecycle.over(n) { ticket.over = true }
        for f in fx { apply(f) }
        // (a session that already says more: its task may have come with the open)
        if n != before, let sid = sessionId, let s = latest ?? shell.states[sid] { see(s) }
        // (the island and notifications first — its end frame — then, done, it is let go)
        if n != before { effects.changed(self) }
        changed(from: before)
    }

    /// After a change: done with it (over, guarding nothing) — its watch cancelled, it let go.
    private func changed(from before: GoalLifecycle.State) {
        guard GoalLifecycle.done(state), !GoalLifecycle.done(before) else { return }
        watch = nil
        latest = nil
        let f = onDone
        onDone = nil
        f?()
    }

    private func see(_ s: SessionState) {
        if let e = GoalLifecycle.observed(state, s, cua: cua) { send(e) }
    }

    private func apply(_ f: GoalLifecycle.Effect) {
        switch f {
        case .beginRecording:
            effects.beginRecording(goal) { [weak self] in self?.send(.recordingStarted) }
        case .open:
            // this goal's own session's state, whenever the shell takes a newer one (until it is done with it)
            watch = shell.$states.sink { [weak self] all in
                guard let self, let sid = self.sessionId, let s = all[sid] else { return }
                self.latest = s
                self.see(s)
                // (not once it is let go — that change already told: its end frame; the shell's state is older here)
                if self.watch != nil { self.effects.changed(self) }
            }
            shell.startTask(goal, scope: folder, clientId: cua, ticket: ticket) { [weak self] e in self?.send(e) }
        case .sendStop(let sid, let run):
            shell.stop(sessionId: sid, runId: run)
        case .retire(let sid):
            shell.client.retire(cua, in: sid)
        case .deadline(let seconds):
            deadline += 1
            let mine = deadline
            effects.after(seconds) { [weak self] in
                guard let self, self.deadline == mine else { return }
                self.send(.deadline)
            }
        case .stopRecording:
            effects.stopRecording(recordOf()) { [weak self] url in self?.movie = url }
        case .writeRecord:
            effects.writeRecord(recordOf())
        }
    }

    private func recordOf() -> GoalRecord {
        var failed: String? = nil
        if case .failed(let why, _) = state { failed = why }
        return GoalRecord(goal: goal, folder: folder, sessionId: sessionId, task: task?.task, failed: failed)
    }
}

/// The goals started from GoalRunView, by request. A goal is kept while it is not over or still guards its session
/// (its lifecycle outlives its view); once done it is let go — its session's watch cancelled — and only its last state
/// is kept, so a view that comes back shows it and never starts it again. One at a time: a goal starts only while
/// every earlier one is over.
final class GoalRuns {
    private(set) var runs: [UUID: GoalRun] = [:]
    private var finished: [UUID: (state: GoalLifecycle.State, sessionId: String?)] = [:]

    func run(_ id: UUID) -> GoalRun? { runs[id] }

    /// The goal for a request: the one started for it (or, done, its last state), else a new one, started — or nil
    /// while another goal is not over (no second session then).
    func start(_ id: UUID, make: () -> GoalRun) -> GoalRun? {
        if let r = runs[id] { return r }
        if let f = finished[id] { let r = make(); r.restore(f.state, sessionId: f.sessionId); return r }
        guard runs.values.allSatisfy({ GoalLifecycle.over($0.state) }) else { return nil }
        let r = make()
        runs[id] = r
        r.onDone = { [weak self, weak r] in
            guard let self, let r else { return }
            self.finished[id] = (r.state, r.sessionId)
            self.runs[id] = nil
        }
        r.start()
        return r
    }
}
