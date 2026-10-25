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

/// The recorder's own state across the helper's slow answer (#127 delta: record_start waits up to 25 s): a stop that
/// comes while the start is on its way is owed, and a start that succeeds with a stop owed is stopped at once -- the
/// helper never records past the task, unseen. Pure: what happened, to what is sent.
///
/// | state         | begin                | the start's answer: ok          | not ok | stop                    |
/// |---------------|----------------------|---------------------------------|--------|-------------------------|
/// | idle          | starting; send start | --                              | --     | nothing (no movie)      |
/// | starting      | nothing              | recording (stop owed: idle;     | idle   | starting, stop owed     |
/// |               |                      |   send stop)                    |        |                         |
/// | recording     | nothing              | --                              | --     | idle; send stop         |
struct RecorderGate: Equatable {
    enum State: Equatable { case idle, starting(stopOwed: Bool), recording }
    enum Event: Equatable { case begin, answered(ok: Bool), stop }
    enum Send: Equatable { case start, stop }
    private(set) var state: State = .idle

    mutating func apply(_ e: Event) -> [Send] {
        switch (state, e) {
        case (.idle, .begin): state = .starting(stopOwed: false); return [.start]
        case (.starting(let owed), .answered(let ok)):
            if ok && owed { state = .idle; return [.stop] }
            state = ok ? .recording : .idle
            return []
        case (.starting, .stop): state = .starting(stopOwed: true); return []
        case (.recording, .stop): state = .idle; return [.stop]
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
