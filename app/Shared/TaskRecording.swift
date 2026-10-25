// Recording a chat's computer task (owner 10-25: the old window's recording, moved into the main window): a
// 「录制这个任务」 switch per conversation, off unless the user turns it on (the last choice is the next
// conversation's start: record.default). With it on, the recorder starts when that conversation's next computer task
// starts and stops when the task is over -- task_done, task_end, closed, its process gone -- or the switch goes off,
// or the app quits. Nothing records with the switch off; one recording at a time (one task holds the computer).
// Pure: what happened, to what the recorder is told (Main: RunRecorder through the helper's record_start /
// record_stop, with the decision panel).
//
// | what happened                         | recording now | the recorder                                 |
// |---------------------------------------|---------------|----------------------------------------------|
// | a task starts, its switch on, none on | that run      | start                                        |
// | a task starts, its switch off         | --            | nothing                                      |
// | the recorded run steered              | the same      | nothing (one task, one movie)                |
// | the recorded run ends (any way)       | none          | stop                                         |
// | its switch turned off while recording | none          | stop                                         |
// | the start failed                      | none          | nothing more                                 |
// | the app quits while recording         | none          | stop                                         |

import Foundation

struct TaskRecording: Equatable {
    enum Event: Equatable {
        case toggled(session: String, on: Bool)
        case taskStarted(session: String, run: String)
        case taskEnded(run: String)
        case startFailed(run: String)
        case appQuit
    }
    enum Action: Equatable { case start(session: String, run: String), stop(run: String) }

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
            if !v, let r = recording, r.session == s { recording = nil; return [.stop(run: r.run)] }
            return []
        case .taskStarted(let s, let run):
            guard recording == nil, isOn(s) else { return [] }
            recording = (s, run)
            return [.start(session: s, run: run)]
        case .taskEnded(let run):
            guard recording?.run == run else { return [] }
            recording = nil
            return [.stop(run: run)]
        case .startFailed(let run):
            if recording?.run == run { recording = nil }
            return []
        case .appQuit:
            guard let r = recording else { return [] }
            recording = nil
            return [.stop(run: r.run)]
        }
    }

    /// The last choice of the switch: the next conversation starts with it.
    static let defaultKey = "record.default"
    /// Each conversation's switch, by session id.
    static let conversationsKey = "record.conversations"
    /// The movies recorded, by run (shown on the task's row as 「已录制」).
    static let moviesKey = "record.movies"
}

/// The recorder as the window's model drives it (Main: RunRecorder and the decision panel; a test: its own).
protocol TaskRecorder: AnyObject {
    /// Start recording for `goal`; `started(false)`: it could not (no permission, the helper away).
    func start(goal: String, run: String, started: @escaping (Bool) -> Void)
    /// Stop; `done`: the movie (nil: none).
    func stop(done: @escaping (URL?) -> Void)
    /// A step of the recorded task, for the decision panel: its number and words.
    func step(_ n: Int, _ words: String)
}

/// The recorder's own state across the helper's slow answers (#127 delta and Codex: record_start waits up to 25 s, and
/// its answer may never come). A stop while the start is on its way is owed. A start's answer is one of three: ok,
/// refused (the helper said no: nothing records), unknown (timed out, lost: it may be recording). Unknown keeps the
/// obligation: the helper is told to stop (record_stop, harmless when nothing records) as soon as the recording is not
/// wanted, and again -- at the next stop, at the quit -- until it confirms. Pure: what happened, to what is sent.
///
/// | state         | begin        | start: ok          | refused | unknown            | stop               | stop's answer  |
/// |---------------|--------------|--------------------|---------|--------------------|--------------------|----------------|
/// | idle          | starting;    | --                 | --      | --                 | nothing            | --             |
/// |               |   send start |                    |         |                    |                    |                |
/// | starting      | nothing      | recording (owed:   | idle    | recording (owed:   | starting, owed     | --             |
/// |               |              |   stopping; stop)  |         |   stopping; stop)  |                    |                |
/// | recording     | nothing      | --                 | --      | --                 | stopping; stop     | --             |
/// | stopping      | nothing      | --                 | --      | --                 | send stop again    | confirmed:     |
/// |               |              |                    |         |                    |                    |   idle; else   |
/// |               |              |                    |         |                    |                    |   stopping     |
struct RecorderGate: Equatable {
    enum State: Equatable { case idle, starting(stopOwed: Bool), recording, stopping }
    enum Answer: Equatable { case ok, refused, unknown }
    enum Event: Equatable { case begin, answered(Answer), stop, stopAnswered(confirmed: Bool) }
    enum Send: Equatable { case start, stop }
    private(set) var state: State = .idle

    /// Something may be recording, or a start or a stop is still to be confirmed: the app's quit sends record_stop.
    var busy: Bool { state != .idle }

    mutating func apply(_ e: Event) -> [Send] {
        switch (state, e) {
        case (.idle, .begin): state = .starting(stopOwed: false); return [.start]
        case (.starting(let owed), .answered(let a)):
            if a == .refused { state = .idle; return [] }
            if owed { state = .stopping; return [.stop] }
            state = .recording
            return []
        case (.starting, .stop): state = .starting(stopOwed: true); return []
        case (.recording, .stop): state = .stopping; return [.stop]
        case (.stopping, .stop): return [.stop]
        case (.stopping, .stopAnswered(let confirmed)): if confirmed { state = .idle }; return []
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
