// Recording a chat's computer task (owner 10-25: the old window's recording, moved into the main window): a
// 「录制这个任务」 switch per conversation, off unless the user turns it on (the last choice is the next
// conversation's start: record.default). With it on, the recorder starts when that conversation's next computer task
// starts and stops when the task is over -- task_done, task_end, closed, its process gone -- or the switch goes off,
// or the app quits. Nothing records with the switch off; one recording at a time (one task holds the computer).
// Pure: what happened, to what the recorder is told (Main: RunRecorder through the helper's record_start /
// record_stop, with the decision panel).
//
// | what happened                         | recording now | the app                                      |
// |---------------------------------------|---------------|----------------------------------------------|
// | a task starts, its switch on, none on | that run      | asks the helper to record it                 |
// | a task starts, its switch off         | --            | nothing                                      |
// | the recorded run steered              | the same      | nothing (one task, one movie)                |
// | the recorded run ends (any way)       | none          | nothing to send: the helper stopped it (its  |
// |                                       |               |   RecordingOwner); waits for the movie       |
// | its switch turned off while recording | none          | cancels (asked again until answered)         |
// | the helper said no                    | none          | nothing more                                 |
// | the app quits while recording         | none          | cancels (the helper stops it at the run's    |
// |                                       |               |   end anyway)                                |

import Foundation

struct TaskRecording: Equatable {
    enum Event: Equatable {
        case toggled(session: String, on: Bool)
        case taskStarted(session: String, run: String)
        case taskEnded(run: String)
        case startFailed(run: String)
        case appQuit
    }
    /// start: ask the helper; cancel: ask it to stop (retried until it answers); ended: the task is over -- the helper
    /// stopped the recording itself, the app hides its panel and waits for the movie.
    enum Action: Equatable { case start(session: String, run: String), cancel(run: String), ended(session: String, run: String) }

    /// The switch, by conversation (absent: off -- a conversation is seeded with the last choice only when it is new:
    /// ShellModel; #127 delta: the default flipped every untouched conversation on).
    var on: [String: Bool] = [:]
    /// The last choice: a new conversation's start.
    var defaultOn = false
    /// The run being recorded (and its conversation), if any.
    private(set) var recording: (session: String, run: String)?

    static func == (a: TaskRecording, b: TaskRecording) -> Bool {
        a.on == b.on && a.defaultOn == b.defaultOn && a.recording?.session == b.recording?.session && a.recording?.run == b.recording?.run
    }

    func isOn(_ session: String) -> Bool { on[session] ?? false }
    var recordingRun: String? { recording?.run }

    mutating func apply(_ e: Event) -> [Action] {
        switch e {
        case .toggled(let s, let v):
            on[s] = v
            if !v, let r = recording, r.session == s { recording = nil; return [.cancel(run: r.run)] }
            return []
        case .taskStarted(let s, let run):
            guard recording == nil, isOn(s) else { return [] }
            recording = (s, run)
            return [.start(session: s, run: run)]
        case .taskEnded(let run):
            guard let r = recording, r.run == run else { return [] }
            recording = nil
            return [.ended(session: r.session, run: run)]
        case .startFailed(let run):
            if recording?.run == run { recording = nil }
            return []
        case .appQuit:
            guard let r = recording else { return [] }
            recording = nil
            return [.cancel(run: r.run)]
        }
    }

    /// The last choice of the switch: the next conversation starts with it.
    static let defaultKey = "record.default"
    /// Each conversation's switch, by session id.
    static let conversationsKey = "record.conversations"
    /// The movies recorded, by run (shown on the task's row as 「已录制」).
    static let moviesKey = "record.movies"
}

/// The recorder as the window's model drives it (Main: the helper's record ops and the decision panel; a test: its
/// own). The helper owns the recording (RecordingOwner): the app asks, and learns the movie from the run's folder.
protocol TaskRecorder: AnyObject {
    /// Ask the helper to record `run` (of `session`) for `goal`; `started(false)`: it said no (no permission).
    func start(goal: String, run: String, session: String, started: @escaping (Bool) -> Void)
    /// Ask the helper to stop recording `run` -- asked again until it answers (it stops by itself at the run's end).
    func cancel(run: String)
    /// The task is over: the helper stopped its recording; `saved` gets the movie once it is made.
    func ended(run: String, session: String, saved: @escaping (URL) -> Void)
    /// A step of the recorded task, for the decision panel: its number and words.
    func step(_ n: Int, _ words: String)
}

/// The helper's own recording (#127 Codex at 24cbf17: the app's bookkeeping of start / stop messages failed three
/// ways; the helper owns the lifecycle): one capture at a time, bound to the run it is for. It stops by itself when
/// that run ends (SessionHost sees the run's task_done, task_end, closed, its process gone) and when the helper quits,
/// so no lost message of the app's can leave it running; the app's cancel (record_stop) stops it too. Stopping ends the
/// capture at once and answers at once; the movie is made in the background and its path written beside the run
/// (`recording.json`), which is how the app learns it. A new start while a movie is still being made is fine: the
/// capture is free. Pure: what happened, to what the helper does (Helper/ScreenRecorder.swift follows it).
///
/// One state machine under the recorder's one lock (#127 Codex at 29841c4: a start registered, unlocked, then set up
/// the capture under a second lock -- a stop in the gap left a capture nobody owned). A start is accepted only for a
/// run the helper itself knows is live now and that has not ended or been cancelled (a late start, sent before the
/// run's end and come after it, is refused): ends and cancels are kept per run (tombstones) even when nothing records.
/// The start's token is checked again, under the lock, once the capture is set up (outside it): a stop, an end or a
/// newer start meanwhile, and the starter tears its capture down.
///
/// | state                   | start(r)                      | set up (token)          | r ended / cancelled    |
/// |-------------------------|-------------------------------|-------------------------|------------------------|
/// | idle                    | r live, no tombstone:         | --                      | tombstone              |
/// |                         |   starting(r, t); else refused |                         |                        |
/// | starting(r, t)          | the newer: starting(r2, t2)   | t: recording(r, t);     | idle (+ tombstone): the |
/// |                         |   (t torn down when it is set |   any other: torn down  |   starter tears down   |
/// |                         |   up)                         |                         |                        |
/// | recording(r, t)         | the newer: r's movie, then    | --                      | idle; r's movie        |
/// |                         |   starting(r2, t2)            |                         |                        |
/// | the helper quits        | idle; the capture ended       |                         |                        |
struct RecordingOwner: Equatable {
    /// Written beside the run when its movie is made: {"path": …}.
    static let savedFile = "recording.json"

    enum State: Equatable { case idle, starting(run: String?, token: Int), recording(run: String?, token: Int) }
    enum Event: Equatable {
        /// `live`: the helper's own word that the run is running now (SessionHost); an op run's (run nil): always.
        case start(run: String?, live: Bool)
        /// The capture of `token` is set up (`ok`) or could not be.
        case setUp(token: Int, ok: Bool)
        case runEnded(run: String), cancel(run: String?), quit
    }
    enum Do: Equatable {
        case refuse
        /// Set up a capture for the run under this token (outside the lock).
        case setUp(run: String?, token: Int)
        /// Keep the capture just set up: it is the active one.
        case keep(token: Int)
        /// Throw away the capture just set up (a stop, an end or a newer start came first).
        case tearDown(token: Int)
        /// End the active capture and make its movie.
        case end(run: String?)
    }
    private(set) var state: State = .idle
    /// Runs ended or cancelled, for the session's life: never recorded after.
    private(set) var tombstones: Set<String> = []
    private var lastToken = 0

    /// Whether `token`'s start is still the one being set up (no stop, end or newer start since).
    func isCurrent(token: Int) -> Bool { if case .starting(_, let t) = state { return t == token }; return false }

    /// The run being captured (`.some(nil)`: an op run's).
    var capturing: String?? { if case .recording(let r, _) = state { return .some(r) }; return nil }

    mutating func apply(_ e: Event) -> [Do] {
        switch e {
        case .start(let run, let live):
            if let r = run, tombstones.contains(r) || !live { return [.refuse] }
            var out: [Do] = []
            if case .recording(let r, _) = state { out.append(.end(run: r)) }
            lastToken += 1
            state = .starting(run: run, token: lastToken)
            out.append(.setUp(run: run, token: lastToken))
            return out
        case .setUp(let token, let ok):
            guard case .starting(let r, let t) = state, t == token else { return ok ? [.tearDown(token: token)] : [] }
            state = ok ? .recording(run: r, token: t) : .idle
            return ok ? [.keep(token: token)] : []
        case .runEnded(let run):
            tombstones.insert(run)
            return stop(if: { $0 == run })
        case .cancel(let run):
            if let run { tombstones.insert(run) }
            return stop(if: { run == nil || $0 == run })
        case .quit:
            return stop(if: { _ in true })
        }
    }

    private mutating func stop(if matches: (String?) -> Bool) -> [Do] {
        switch state {
        case .starting(let r, _) where matches(r): state = .idle; return []       // (the starter tears down at its check)
        case .recording(let r, _) where matches(r): state = .idle; return [.end(run: r)]
        default: return []
        }
    }
}

/// Whether the helper takes a record_start now (HandsHelper): not while another task acts on this Mac -- but the
/// recording of the task that holds it (`forRun`: the run it is for) is passive capture of that very task.
enum RecordStart {
    static func allowed(acting: Bool, holderRun: String?, forRun: String?) -> Bool {
        !acting || (forRun != nil && forRun == holderRun)
    }
}

/// A recording's folder, its own (#127 Codex at 8d9b4f7: names are to the second and the instruction's start, so two
/// starts in the same second shared one, and one's clean-up took the other's movie). Claimed with a create that fails
/// when the folder is there: the name asked for, else with `tag` (the run, a token), else with a counter.
enum RecordingFolder {
    static func claim(_ base: URL, tag: String) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        let name = base.lastPathComponent, parent = base.deletingLastPathComponent()
        let names = [name, "\(name) \(tag)"] + (2...50).map { "\(name) \(tag) \($0)" }
        for n in names {
            let u = parent.appendingPathComponent(n, isDirectory: true)
            if (try? fm.createDirectory(at: u, withIntermediateDirectories: false)) != nil { return u }
        }
        return nil
    }
}
