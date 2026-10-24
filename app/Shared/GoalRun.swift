// One goal from the home screen's GoalRunView, run as a session task (harness engine): its lifecycle, keyed on this
// goal's own session and its own task — never on the selected session's newest task (#118 review at 6554042:
// inferring "running" from tasks.last let Run again open a second session, left Stop reaching nothing, and left a
// goal that never got a task "Getting ready…" for good with its recording never stopped).
//
// GoalLifecycle is pure (state × event → state, and the side effects it calls for). GoalRun applies it: the open and
// the send's results (ShellModel.startTask's report), this goal's own session's state, the deadlines, the recording,
// the recent-runs record. GoalRuns keeps every GoalRun by its request until it is over, so the lifecycle and its
// once-only effects outlive the view (a view gone mid-task, a window closed, skips nothing).
//
// | state                  | event                    | next                     | effects                         |
// |------------------------|--------------------------|--------------------------|---------------------------------|
// | idle                   | start(record)            | recordingStart           | begin the recording             |
// | idle                   | start(no record)         | opening                  | open + send cua; 70 s bound     |
// | recordingStart         | recordingStarted         | opening                  | open + send cua; 70 s bound     |
// |   (its 25 s bound: RunRecorder.begin, Main/Recording.swift — DeskMindIPC.request(body, timeout: 25), then
// |    `started(false)`: the goal goes on unrecorded, as before)                                                     |
// | opening                | opened(sid)              | opening(sid)             | —                               |
// | opening                | cloudRefused / openFailed / refused / unavailable | failed(why) | end effects           |
// | opening                | deadline (70 s)          | failed(helper no answer) | end effects                     |
// | opening(sid)           | sent                     | sent(sid)                | 60 s bound                      |
// | opening(sid)           | taskStarted(run)         | running(sid, run)        | — (its lines before send's ok)  |
// | sent(sid)              | taskStarted(run)         | running(sid, run)        | —                               |
// | sent(sid)              | stop                     | sent(sid, stop asked)    | stop to sid (no run); 15 s bound|
// | sent(sid)              | exited                   | failed(session gone)     | end effects                     |
// | sent(sid)              | deadline (60 s)          | failed(task didn't start)| end effects                     |
// | sent(sid, stop asked)  | taskStarted(run)         | running(sid, run)        | stop(run) to sid                |
// | sent(sid, stop asked)  | exited / deadline (15 s) | failed(stopped before it started) | end effects            |
// | running(sid, run)      | stop                     | running                  | stop(run) to sid                |
// | running(sid, run)      | taskEnded(status)        | ended(status)            | end effects                     |
// | running(sid, run)      | exited                   | ended(interrupted)       | end effects (no undo: cut off)  |
// | ended / failed         | anything                 | the same                 | —                               |
// | any other pair         |                          | the same                 | —                               |
//
// End effects (entering ended or failed, which happens once): stop the recording when this goal records, and write
// the recent-runs record. What the screen shows comes from the state alone (GoalRunScreen): Stop is shown in sent and
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
        /// A deadline `seconds` from now; a newer one replaces it.
        case deadline(seconds: Double)
        case stopRecording
        case writeRecord
    }

    static let openingBound: Double = 70
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
        static func refused(_ code: String) -> String { "refused:" + code }
    }

    /// The next state and what it calls for. `recording`: this goal records (its recording is stopped at its end).
    static func next(_ s: State, _ e: Event, recording: Bool) -> (State, [Effect]) {
        let end: [Effect] = (recording ? [.stopRecording] : []) + [.writeRecord]
        // (the bound first: an open that answers at once — its `sent` sets the next bound — is never overtaken by it)
        let open: [Effect] = [.deadline(seconds: openingBound), .open]
        switch (s, e) {
        case (.idle, .start(let record)):
            return record ? (.recordingStart, [.beginRecording]) : (.opening(sid: nil), open)
        case (.recordingStart, .recordingStarted):
            return (.opening(sid: nil), open)

        case (.opening(nil), .opened(let sid)): return (.opening(sid: sid), [])
        case (.opening, .cloudRefused): return (.failed(Why.cloudOff), end)
        case (.opening, .openFailed), (.opening, .unavailable): return (.failed(Why.noHelper), end)
        case (.opening, .refused(let code)): return (.failed(Why.refused(code)), end)
        case (.opening, .deadline): return (.failed(Why.noAnswer), end)
        case (.opening(let sid?), .sent): return (.sent(sid: sid, stopAsked: false), [.deadline(seconds: sentBound)])
        case (.opening(let sid?), .taskStarted(let run)): return (.running(sid: sid, run: run), [])

        case (.sent(let sid, let asked), .taskStarted(let run)):
            return (.running(sid: sid, run: run), asked ? [.sendStop(sid: sid, run: run)] : [])
        case (.sent(let sid, false), .stop):
            return (.sent(sid: sid, stopAsked: true), [.sendStop(sid: sid, run: nil), .deadline(seconds: stopBound)])
        case (.sent(_, let asked), .exited): return (.failed(asked ? Why.stoppedBeforeStart : Why.gone), end)
        case (.sent(_, let asked), .deadline): return (.failed(asked ? Why.stoppedBeforeStart : Why.notStarted), end)

        case (.running(let sid, let run), .stop): return (s, [.sendStop(sid: sid, run: run)])
        case (.running(let sid, let run), .taskEnded(let status)): return (.ended(sid: sid, run: run, status: status), end)
        case (.running(let sid, let run), .exited): return (.ended(sid: sid, run: run, status: "interrupted"), end)

        default: return (s, [])
        }
    }

    /// What this goal's own session says now, as an event (nil: nothing for the lifecycle). `s`: the session's state.
    static func observed(_ st: State, _ s: SessionState) -> Event? {
        switch st {
        case .opening(_?), .sent:
            // a new session of its own: its first task is the goal's
            if let t = s.tasks.first { return .taskStarted(run: t.runId) }
            if case .sent = st, s.exited != nil { return .exited }
            return nil
        case .running(_, let run):
            guard let t = s.task(run) else { return s.exited != nil ? .exited : nil }
            // (a task cut off by its process's exit has ended: `interrupted`, no undo)
            if t.ended { return .taskEnded(status: t.status ?? "interrupted") }
            return s.exited != nil ? .exited : nil
        default:
            return nil
        }
    }

    static func over(_ s: State) -> Bool {
        switch s { case .ended, .failed: return true; default: return false }
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
        case .failed(let why): taskRun = nil; line = Self.why(why, lang: lang)
        }
    }

    static func why(_ why: String, lang: ResolvedLang) -> String {
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
    private let effects: GoalRunEffects
    private var watch: AnyCancellable?
    /// The newest deadline (a newer one replaces it).
    private var deadline = 0
    /// Its session's newest state, as the shell's `states` takes it: the sink runs before `states` is set, so what
    /// the goal reads (its task's end, the record) is this, never the shell's previous one.
    private var latest: SessionState?

    init(goal: String, folder: String?, record: Bool, shell: ShellModel, effects: GoalRunEffects) {
        self.goal = goal; self.folder = folder; self.record = record; self.shell = shell; self.effects = effects
    }

    var sessionId: String? {
        switch state {
        case .opening(let sid): return sid
        case .sent(let sid, _), .running(let sid, _), .ended(let sid, _, _): return sid
        default: return nil
        }
    }

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

    func send(_ e: GoalLifecycle.Event) {
        let before = state
        let (n, fx) = GoalLifecycle.next(state, e, recording: record)
        guard n != before || !fx.isEmpty else { return }
        state = n
        for f in fx { apply(f) }
        // (a session that already says more: its task may have come with the open)
        if n != before, let sid = sessionId, let s = latest ?? shell.states[sid] { see(s) }
    }

    private func see(_ s: SessionState) {
        if let e = GoalLifecycle.observed(state, s) { send(e) }
    }

    private func apply(_ f: GoalLifecycle.Effect) {
        switch f {
        case .beginRecording:
            effects.beginRecording(goal) { [weak self] in self?.send(.recordingStarted) }
        case .open:
            // this goal's own session's state, whenever the shell takes a newer one (kept after its end too: its
            // task's result card and undo go on changing)
            watch = shell.$states.sink { [weak self] all in
                guard let self, let sid = self.sessionId, let s = all[sid] else { return }
                self.latest = s
                self.see(s)
            }
            shell.startTask(goal, scope: folder) { [weak self] e in self?.send(e) }
        case .sendStop(let sid, let run):
            shell.stop(sessionId: sid, runId: run)
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
        if case .failed(let why) = state { failed = why }
        return GoalRecord(goal: goal, folder: folder, sessionId: sessionId, task: task?.task, failed: failed)
    }
}

/// Every goal started from GoalRunView, by its request, kept until the app quits (a goal's lifecycle outlives its
/// view: the view finds its goal again here). One at a time: a goal starts only while every earlier one is over.
final class GoalRuns {
    private(set) var runs: [UUID: GoalRun] = [:]

    func run(_ id: UUID) -> GoalRun? { runs[id] }

    /// The goal for a request: the one already started for it, else a new one, started — or nil while another goal
    /// is not over (no second session then).
    func start(_ id: UUID, make: () -> GoalRun) -> GoalRun? {
        if let r = runs[id] { return r }
        guard runs.values.allSatisfy({ GoalLifecycle.over($0.state) }) else { return nil }
        let r = make()
        runs[id] = r
        r.start()
        return r
    }
}
