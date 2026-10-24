// One goal from the home screen's GoalRunView, run as a session task (harness engine): its lifecycle, keyed on this
// goal's own session and its own task — never on the selected session's newest task (#118 review at 6554042:
// inferring "running" from tasks.last let Run again open a second session, left Stop reaching nothing, and left a
// goal that never got a task "Getting ready…" for good with its recording never stopped).
//
// GoalLifecycle is pure (state × event → state, and the side effects it calls for). GoalRun applies it: the open and
// the send's results (ShellModel.startTask's report), this goal's own session's state, the deadlines, the recording,
// the recent-runs record. GoalRuns keeps a GoalRun by its request while it is not over, so the lifecycle and its
// once-only effects outlive the view; then it lets it go — its watch of the session cancelled — and keeps only its
// last state, for a view that comes back.
//
// Invariants:
// - Once a goal is over, nothing it started acts (#118 delta review at 4ff4f6d). Its cua is never sent once the goal
//   is stopping, failing or over (GoalTicket: openThenSend checks it before the send).
// - A task is the goal's only when it provably came from the goal's own cua (GoalLifecycle.task(of:in:): the stored
//   /cua message carries the cua's client_id, its session.task replies to that message; #118 delta review at 221a7f3).
// - A goal never sends a run-less stop (Codex review at 84d72f3): the session takes it for whatever task runs there.
// - Cancelling is confirmed by the session, never by a local timeout (Codex review at b767ca7: a Stop before the
//   goal's session.task was seen only cleared local state; its task could run on). Before its task is known the goal
//   stops by its cua: `stop {client_id}` (harness#72), answered by exactly one session.stop_ack — `stopped` /
//   `already_ended` (its task, run and status) or `none` (no task came of it: session.cua_cancelled is stored and the
//   cua is refused `cancelled` if it comes). The ack is not stored: the stop is sent again every `resendEvery` while
//   waiting (after a reconnect, or a reopen — the send reopens the session — the session answers again from history).
//   A helper that does not answer: retried with backoff, and said plainly after the first failed retry; the goal
//   waits (not over: quitting DeskMind ends it), and no ending is made up.
//
// | state                       | event                          | next                        | effects                     |
// |-----------------------------|--------------------------------|-----------------------------|-----------------------------|
// | idle                        | start(record)                  | recordingStart              | begin the recording         |
// | idle                        | start(no record)               | opening                     | open + send cua; opening bnd|
// | recordingStart              | recordingStarted               | opening                     | open + send cua; opening bnd|
// |   (its 25 s bound: RunRecorder.begin, Main/Recording.swift — DeskMindIPC.request(body, timeout: 25), then
// |    `started(false)`: the goal goes on unrecorded, as before)                                                     |
// | opening(nil)                | opened(sid)                    | opening(sid)                | —                           |
// | opening(nil)                | stop                           | opening(nil, stop asked)    | — (no session: the cua held)|
// | opening(nil, stop asked)    | opened(sid)                    | stopping(sid)               | stop{cid}; resend           |
// | opening(nil, stop asked)    | openFailed / unavailable / bnd | failed(stopped before start)| end                         |
// | opening                     | cloudRefused / openFailed      | failed(why)                 | end                         |
// | opening(nil)                | unavailable / deadline         | failed(why)                 | end (no session: no cua)    |
// | opening(sid)                | stop                           | stopping(sid)               | stop{cid}; resend           |
// | opening(sid)                | unavailable / deadline         | failing(why, sid)           | stop{cid}; resend           |
// |   (the opening bound: SessionClient.openTimeout + SessionClient.sendTimeout + 5 s)                               |
// | opening / sent              | refused / sessionRefused       | failed(refused; `cancelled`: stopped before start) | end; retire |
// | opening(sid)                | sent                           | sent(sid)                   | 60 s bound                  |
// | opening(sid) / sent(sid)    | taskStarted(run)               | running(sid, run)           | —                           |
// | sent(sid)                   | stop                           | stopping(sid)               | stop{cid}; resend           |
// | sent(sid)                   | exited / deadline (60 s)       | failing(why, sid)           | stop{cid}; resend           |
// | running(sid, run)           | stop                           | running                     | stop(run)                   |
// | running(sid, run)           | taskEnded(status)              | ended(status)               | end                         |
// | running(sid, run)           | exited                         | ended(interrupted)          | end (no undo: cut off)      |
// | stopping(sid, run?)         | taskStarted(run)               | stopping(sid, run)          | — (stop{cid} covers it)     |
// | stopping(sid, run)          | taskEnded(status)              | ended(sid, run, status)     | end                         |
// | stopping                    | ack stopped / already_ended    | ended(sid, its run, status) | end                         |
// | stopping                    | ack none / own cua refused     | failed(stopped before start)| end; retire                 |
// | failing(why, sid)           | ack (any) / own cua refused    | failed(why)                 | end; retire                 |
// | failing(why, sid)           | taskStarted(run)               | failing                     | — (stop{cid} covers it)     |
// | stopping / failing          | resend (every 15 s)            | the same                    | stop{cid}; resend           |
// | stopping / failing          | stopUnsent (helper no answer)  | misses + 1                  | retry: 2, 4, 8, 16, 30 s    |
// |   (misses ≥ 2 — the first retry failed too: the screen says the stop can't be confirmed, the helper isn't
// |    answering, and quitting DeskMind ends it; still not over)                                                     |
// | stopping / failing          | stopSent                       | misses 0                    | —                           |
// | stopping / failing          | exited / deadline / stop       | the same                    | — (the resend reopens)      |
// | ended / failed              | anything                       | the same                    | —                           |
// | any other pair              |                                | the same                    | —                           |
//
// end: stop the recording when this goal records, write the recent-runs record — entering ended or failed, once.
// What the screen shows comes from the state alone (GoalRunScreen): Stop live in opening, sent and running, greyed
// while stopping, hidden in recordingStart and failing; Back / Edit / Run again only in ended and failed — so a goal
// starts a session only from idle, and no second one while it is not over.

import Combine
import Foundation

enum GoalLifecycle {
    enum State: Equatable {
        case idle
        case recordingStart
        case opening(sid: String?, stopAsked: Bool = false)
        case sent(sid: String)
        case running(sid: String, run: String)
        /// Stopped before its task was known: `stop {client_id}` sent, the session's answer awaited. `run`: its task,
        /// once seen; `misses`: sends in a row the helper did not take.
        case stopping(sid: String, run: String? = nil, misses: Int = 0)
        /// Failed with its cua perhaps on its way: `stop {client_id}` sent, the session's answer awaited; then failed.
        case failing(String, sid: String, misses: Int = 0)
        case ended(sid: String, run: String, status: String)
        case failed(String)
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
        /// The session's answer to `stop {client_id}` (session.stop_ack).
        case stopAck(result: String, run: String?, status: String?)
        /// The `stop {client_id}` went (the helper took it) / did not (the helper did not answer).
        case stopSent
        case stopUnsent
        /// Time to send the `stop {client_id}` again.
        case resend
    }

    enum Effect: Equatable {
        case beginRecording
        case open
        /// Stop the goal's own task by its run (never run-less: the session would stop whatever task runs there).
        case sendStop(sid: String, run: String)
        /// `stop {client_id}` with the goal's cua (harness#72).
        case sendStopCua(sid: String)
        /// The goal's cua in `sid` is never resent nor shown as a bubble to resend (SessionClient.retire).
        case retire(sid: String)
        /// A deadline `seconds` from now; a newer one replaces it.
        case deadline(seconds: Double)
        /// The next `stop {client_id}` `seconds` from now; a newer one replaces it.
        case resend(seconds: Double)
        case stopRecording
        case writeRecord
    }

    /// The open, then the send (which may reopen the session): what the opening waits for, from the client's own
    /// timeouts, and a margin.
    static let openingBound: Double = SessionClient.openTimeout + SessionClient.sendTimeout + 5
    static let sentBound: Double = 60
    /// While a stop's answer is awaited: sent again (its answer is not stored — a reconnect may have lost it).
    static let resendEvery: Double = 15
    /// The helper did not take the stop: tried again after 2, 4, 8, 16, then every 30 s.
    static func backoff(_ misses: Int) -> Double { min(30, pow(2, Double(max(1, misses)))) }
    /// After this many sends in a row the helper did not take (the first, then the first retry): said plainly.
    static let unansweredAfter = 2

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
        // (the resend first: a send the helper does not take answers at once, and its backoff replaces it)
        let stopCua: (String) -> [Effect] = { [.resend(seconds: resendEvery), .sendStopCua(sid: $0)] }
        /// Refused (by the send or the session): nothing on its way; the refused cua retired. `cancelled`: a stop of
        /// ours came first.
        func refusal(_ code: String, _ text: String, _ sid: String?) -> (State, [Effect]) {
            let why = code == "cancelled" ? Why.stoppedBeforeStart : Why.refused(code, text: text)
            return (.failed(why), end + (sid.map { [.retire(sid: $0)] } ?? []))
        }
        switch (s, e) {
        case (.idle, .start(let record)):
            return record ? (.recordingStart, [.beginRecording]) : (.opening(sid: nil), open)
        case (.recordingStart, .recordingStarted):
            return (.opening(sid: nil), open)

        // opening, no session yet
        case (.opening(nil, false), .opened(let sid)): return (.opening(sid: sid), [])
        case (.opening(nil, false), .stop): return (.opening(sid: nil, stopAsked: true), [])
        case (.opening(nil, true), .opened(let sid)): return (.stopping(sid: sid), stopCua(sid))
        case (.opening(nil, true), .openFailed), (.opening(nil, true), .unavailable), (.opening(nil, true), .deadline),
             (.opening(nil, true), .cloudRefused):
            return (.failed(Why.stoppedBeforeStart), end)
        case (.opening, .cloudRefused): return (.failed(Why.cloudOff), end)
        case (.opening(nil, _), .openFailed), (.opening(nil, _), .unavailable): return (.failed(Why.noHelper), end)
        case (.opening(nil, _), .deadline): return (.failed(Why.noAnswer), end)
        case (.opening(nil, _), .refused(let code)): return refusal(code, "", nil)

        // opening, its session open (the cua's send under way)
        case (.opening(let sid?, _), .stop): return (.stopping(sid: sid), stopCua(sid))
        case (.opening(let sid?, _), .openFailed), (.opening(let sid?, _), .unavailable): return (.failing(Why.noHelper, sid: sid), stopCua(sid))
        case (.opening(let sid?, _), .deadline): return (.failing(Why.noAnswer, sid: sid), stopCua(sid))
        case (.opening(let sid?, _), .refused(let code)): return refusal(code, "", sid)
        case (.opening(let sid?, _), .sessionRefused(let code, let text)): return refusal(code, text, sid)
        case (.opening(let sid?, _), .sent): return (.sent(sid: sid), [.deadline(seconds: sentBound)])
        case (.opening(let sid?, _), .taskStarted(let run)): return (.running(sid: sid, run: run), [])

        case (.sent(let sid), .taskStarted(let run)): return (.running(sid: sid, run: run), [])
        case (.sent(let sid), .stop): return (.stopping(sid: sid), stopCua(sid))
        case (.sent(let sid), .refused(let code)): return refusal(code, "", sid)
        case (.sent(let sid), .sessionRefused(let code, let text)): return refusal(code, text, sid)
        case (.sent(let sid), .exited): return (.failing(Why.gone, sid: sid), stopCua(sid))
        case (.sent(let sid), .deadline): return (.failing(Why.notStarted, sid: sid), stopCua(sid))

        case (.running(let sid, let run), .stop): return (s, [.sendStop(sid: sid, run: run)])
        case (.running(let sid, let run), .taskEnded(let status)): return (.ended(sid: sid, run: run, status: status), end)
        case (.running(let sid, let run), .exited): return (.ended(sid: sid, run: run, status: "interrupted"), end)

        // stopping: the session's answer ends it
        case (.stopping(let sid, nil, let m), .taskStarted(let run)): return (.stopping(sid: sid, run: run, misses: m), [])
        case (.stopping(let sid, let run?, _), .taskEnded(let status)): return (.ended(sid: sid, run: run, status: status), end)
        case (.stopping(let sid, let known, _), .stopAck(let result, let run, let status)):
            if result == "none" { return (.failed(Why.stoppedBeforeStart), end + [.retire(sid: sid)]) }
            guard let run = run ?? known else { return (s, []) }
            return (.ended(sid: sid, run: run, status: status ?? "stopped"), end)
        case (.stopping(let sid, _, _), .refused), (.stopping(let sid, _, _), .sessionRefused):
            return (.failed(Why.stoppedBeforeStart), end + [.retire(sid: sid)])

        // failing: the session's answer (whatever it is) ends it as failed
        case (.failing(let why, let sid, _), .stopAck), (.failing(let why, let sid, _), .refused), (.failing(let why, let sid, _), .sessionRefused):
            return (.failed(why), end + [.retire(sid: sid)])

        // stopping / failing: sent again until answered; a helper that does not take it, with backoff
        case (.stopping(let sid, _, _), .resend), (.failing(_, let sid, _), .resend): return (s, stopCua(sid))
        case (.stopping(let sid, let run, let m), .stopUnsent):
            return (.stopping(sid: sid, run: run, misses: m + 1), [.resend(seconds: backoff(m + 1))])
        case (.failing(let why, let sid, let m), .stopUnsent):
            return (.failing(why, sid: sid, misses: m + 1), [.resend(seconds: backoff(m + 1))])
        case (.stopping(let sid, let run, let m), .stopSent) where m > 0: return (.stopping(sid: sid, run: run), [])
        case (.failing(let why, let sid, let m), .stopSent) where m > 0: return (.failing(why, sid: sid), [])

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
        case .opening(_?, _), .sent:
            if let t = task(of: cua, in: s) { return .taskStarted(run: t.runId) }
            if let r = refusedCua() { return r }
            if case .sent = st, s.exited != nil { return .exited }
            return nil
        case .running(_, let run):
            guard let t = s.task(run) else { return s.exited != nil ? .exited : nil }
            // (a task cut off by its process's exit has ended: `interrupted`, no undo)
            if t.ended { return .taskEnded(status: t.status ?? "interrupted") }
            return s.exited != nil ? .exited : nil
        case .stopping(_, let known, _):
            // the session's answer first; then what it shows of the goal's own task (never an exit: the resend reopens)
            if let a = s.stopAcks[cua] { return .stopAck(result: a.result, run: a.runId, status: a.status) }
            if s.cancelledCuas.contains(cua) { return .stopAck(result: "none", run: nil, status: nil) }
            if let t = task(of: cua, in: s) {
                if t.ended, known != nil { return .taskEnded(status: t.status ?? "interrupted") }
                if known == nil { return .taskStarted(run: t.runId) }
            }
            return refusedCua()
        case .failing:
            if let a = s.stopAcks[cua] { return .stopAck(result: a.result, run: a.runId, status: a.status) }
            if s.cancelledCuas.contains(cua) { return .stopAck(result: "none", run: nil, status: nil) }
            return refusedCua()
        default:
            return nil
        }
    }

    /// The task the goal's own cua started, and only that: its session.task carries the cua's client_id (harness#72,
    /// bound when the cua's task is created). Any other task — the user's own in the same session, a retry or the
    /// model's task replying to the same message (no client_id) — is never the goal's: never adopted, never stopped,
    /// never shown as the goal's (#118 delta review at 221a7f3; Codex on harness#72: a retry replies to the same
    /// message). The one matcher: opening, sent, stopping.
    static func task(of cua: String, in s: SessionState) -> TaskState? {
        s.tasks.first { $0.clientId == cua }
    }

    static func over(_ s: State) -> Bool {
        switch s { case .ended, .failed: return true; default: return false }
    }

    /// Over: its watch of the session can go.
    static func done(_ s: State) -> Bool { over(s) }

    /// It still wants its cua sent (openThenSend reads this, through GoalTicket, before the send).
    static func wantsCua(_ s: State) -> Bool {
        switch s {
        case .idle, .recordingStart, .opening(_, false), .sent, .running: return true
        default: return false
        }
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
        case .opening(_, false), .sent, .running: stopShown = true; stopLive = true
        case .opening(_, true), .stopping: stopShown = true; stopLive = false
        default: stopShown = false; stopLive = false
        }
        let unanswered = L("Can't confirm the stop: DeskMind's helper isn't answering. Quitting DeskMind ends the task.", lang: lang)
        switch s {
        case .running(_, let run), .ended(_, let run, _): taskRun = run; line = nil
        case .idle: taskRun = nil; line = nil
        case .recordingStart: taskRun = nil; line = L("Starting the recording…", lang: lang)
        case .opening(_, false), .sent: taskRun = nil; line = L("Getting ready…", lang: lang)
        case .opening(_, true): taskRun = nil; line = L("Stopping…", lang: lang)
        case .stopping(_, let run, let m):
            taskRun = run; line = m >= GoalLifecycle.unansweredAfter ? unanswered : L("Stopping…", lang: lang)
        case .failing(let why, _, let m):
            taskRun = nil
            line = Self.why(why, lang: lang) + "\n" + (m >= GoalLifecycle.unansweredAfter ? unanswered : L("Making sure it stopped…", lang: lang))
        case .failed(let why): taskRun = nil; line = Self.why(why, lang: lang)
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
    /// How the goal ended (its lifecycle's `ended` status; nil when it failed): its outcome, whatever its task says.
    var ended: String? = nil
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
    /// Called after every change of its state (GoalRuns: whether a goal is active).
    var onStateChanged: (() -> Void)?
    private let effects: GoalRunEffects
    private var watch: AnyCancellable?
    /// The newest deadline (a newer one replaces it).
    private var deadline = 0
    /// The newest resend of its `stop {client_id}` (a newer one replaces it).
    private var resendTimer = 0
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
        if case .opened(let sid) = e, sessionId == nil, case .opening(nil, _) = state { sessionId = sid }
        let (n, fx) = GoalLifecycle.next(state, e, recording: record)
        guard n != before || !fx.isEmpty else { return }
        state = n
        // (stopping, failing or over: its cua is never sent from here — openThenSend reads this before the send)
        if !GoalLifecycle.wantsCua(n) { ticket.over = true }
        for f in fx { apply(f) }
        // (a session that already says more: its task may have come with the open)
        if n != before, let sid = sessionId, let s = latest ?? shell.states[sid] { see(s) }
        // (the island and notifications first — its end frame — then, done, it is let go)
        if n != before { effects.changed(self) }
        changed(from: before)
        if n != before { onStateChanged?() }
    }

    /// After a change: done with it (over) — its watch cancelled, it let go.
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
        case .sendStopCua(let sid):
            // (its answer — session.stop_ack — comes on the session's stream: observed)
            shell.stopCua(sessionId: sid, clientId: cua) { [weak self] sent in self?.send(sent ? .stopSent : .stopUnsent) }
        case .resend(let seconds):
            resendTimer += 1
            let mine = resendTimer
            effects.after(seconds) { [weak self] in
                guard let self, self.resendTimer == mine else { return }
                self.send(.resend)
            }
        case .stopRecording:
            effects.stopRecording(recordOf()) { [weak self] url in self?.movie = url }
        case .writeRecord:
            effects.writeRecord(recordOf())
        }
    }

    private func recordOf() -> GoalRecord {
        var failed: String? = nil
        var ended: String? = nil
        if case .failed(let why) = state { failed = why }
        if case .ended(_, _, let status) = state { ended = status }
        return GoalRecord(goal: goal, folder: folder, sessionId: sessionId, task: task?.task, failed: failed, ended: ended)
    }
}

/// The goals started from GoalRunView, by request. A goal is kept while it is not over or still guards its session
/// (its lifecycle outlives its view); once done it is let go — its session's watch cancelled — and only its last state
/// is kept, so a view that comes back shows it and never starts it again. One at a time: a goal starts only while
/// every earlier one is over.
final class GoalRuns {
    private(set) var runs: [UUID: GoalRun] = [:]
    private var finished: [UUID: (state: GoalLifecycle.State, sessionId: String?)] = [:]
    /// The window's close button, owned here for goals (Codex delta review at 1f77d1a: views drove it; a view that
    /// went or another that came left it wrong): closable exactly while no goal is active. Told on every change.
    private let setClosable: (Bool) -> Void
    /// A goal let go (its request no longer needed to route to it).
    private let released: (UUID) -> Void
    private var closable: Bool?

    init(setClosable: @escaping (Bool) -> Void = { _ in }, released: @escaping (UUID) -> Void = { _ in }) {
        self.setClosable = setClosable; self.released = released
    }

    private func activeChanged() {
        let c = active == nil
        guard c != closable else { return }
        closable = c
        setClosable(c)
    }

    func run(_ id: UUID) -> GoalRun? { runs[id] }

    /// The goal that is not over (one at a time), by its request.
    var active: UUID? { runs.first { !GoalLifecycle.over($0.value.state) }?.key }

    /// Where a window that opens (again) goes: the goal that is not over, unless it shows it already — so its cards
    /// can be answered and it can be stopped (Codex review at 84d72f3: closing the window stranded it). nil: as it is.
    static func reopenRoute(active: UUID?, showing: UUID?) -> UUID? {
        guard let active, active != showing else { return nil }
        return active
    }

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
            self.released(id)
            self.activeChanged()
        }
        r.onStateChanged = { [weak self] in self?.activeChanged() }
        r.start()
        activeChanged()
        return r
    }
}
