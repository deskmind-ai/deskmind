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

    /// The switch, by conversation (absent: `defaultOn`).
    var on: [String: Bool] = [:]
    var defaultOn = false
    /// The run being recorded (and its conversation), if any.
    private(set) var recording: (session: String, run: String)?

    static func == (a: TaskRecording, b: TaskRecording) -> Bool {
        a.on == b.on && a.defaultOn == b.defaultOn && a.recording?.session == b.recording?.session && a.recording?.run == b.recording?.run
    }

    func isOn(_ session: String) -> Bool { on[session] ?? defaultOn }
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
    /// The movies recorded, by run (shown on the task's row as 「已录制」).
    static let moviesKey = "record.movies"
}

/// The recorder as the window's model drives it (Main: RunRecorder and the decision panel; a test: its own).
protocol TaskRecorder: AnyObject {
    /// Start recording for `goal`; `started(false)`: it could not (no permission, the helper away).
    func start(goal: String, started: @escaping (Bool) -> Void)
    /// Stop; `done`: the movie (nil: none).
    func stop(done: @escaping (URL?) -> Void)
    /// A step of the recorded task, for the decision panel: its number and words.
    func step(_ n: Int, _ words: String)
}
