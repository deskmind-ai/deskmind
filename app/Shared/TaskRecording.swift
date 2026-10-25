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
/// | what happened                     | capture                 | the helper                                   |
/// |-----------------------------------|-------------------------|----------------------------------------------|
/// | start for run r                   | r (one before: ended)   | end the one before (its movie made), capture |
/// | r's task ended (any way)          | none if it was r's      | end the capture, make r's movie              |
/// | cancel (for r, or any)            | none if it matches      | end the capture, make its movie              |
/// | the helper quits                  | none                    | end the capture                              |
struct RecordingOwner: Equatable {
    /// Written beside the run when its movie is made: {"path": …}.
    static let savedFile = "recording.json"
    enum Event: Equatable { case start(run: String?), runEnded(run: String), cancel(run: String?), quit }
    enum Do: Equatable { case capture(run: String?), end(run: String?) }
    /// The run being captured (`.some(nil)`: an op run's, bound to none).
    private(set) var capturing: String??

    mutating func apply(_ e: Event) -> [Do] {
        switch e {
        case .start(let run):
            var out: [Do] = []
            if let c = capturing { out.append(.end(run: c)) }
            capturing = .some(run)
            out.append(.capture(run: run))
            return out
        case .runEnded(let run):
            guard capturing == .some(run) else { return [] }
            capturing = nil
            return [.end(run: run)]
        case .cancel(let run):
            guard let c = capturing, run == nil || c == run else { return [] }
            capturing = nil
            return [.end(run: c)]
        case .quit:
            guard let c = capturing else { return [] }
            capturing = nil
            return [.end(run: c)]
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
