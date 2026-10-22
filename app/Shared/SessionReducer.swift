// A chat session's state, folded from its event stream (ProtocolEvent.swift): the messages (streamed replies assembled
// from session.delta), each computer task by run_id (its steps, the open card, changes, result and undo), the queue,
// errors, whether the composer takes typing, and the status dot (handoff §1.5).
//
// Pure: `SessionReducer.reduce(state, line)` → the next state, nothing else. Lines with a `seq` belong to a stream — the
// session's stored events, and each run's executor events — whose seqs are contiguous from 1. Per stream the reducer
// keeps a contiguous cursor: it applies only seq == cursor + 1 (then whatever it held that now follows), drops seq <=
// cursor as a replay, and holds seq > cursor + 1 back as a gap (SessionState.hasGap) until the missing lines come; the
// client then watches again from the cursor (SessionClient.watch). The unstored lines — deltas, the queue, refusals —
// have no seq and are idempotent by construction. So a reconnect may simply replay, and a late line is never lost.
//
// Streams are not ordered against each other (a reconnect replays the session's events before the runs'), so the state
// is the same whichever stream came first: what a session event implies about a run (its end voids an open card,
// closes steps with no result) is provisional, recomputed from the facts after every line (`settle`), and the run's own
// word (resumed, ask_void, step_result) always wins; the chat and the tasks are kept in the session's stored order
// (`place`). SessionTests.interleavingPropertyTests holds the reducer to it.

import Foundation

// MARK: - State

struct ChatMessage: Equatable {
    var id: String
    var role: String                // user | assistant
    var text: String
    /// Deltas are still coming: no final session.message yet.
    var streaming: Bool
    /// A delta came past the end of what this app has: the text is incomplete until the final message (or an offset-0 delta).
    var gap = false
    var replyTo: String? = nil
    var model: String? = nil
    var via: String? = nil
    var stopped = false
    var truncated = false
    /// The user asked for this answer again (session.retry): it is no longer in the model's context.
    var retracted = false
    var t: Double? = nil
    /// The stored seq of its final session.message (nil while it streams): its place in the chat.
    var seq: Int? = nil
    /// The session's stored seq when it began streaming: its place if it is never stored (interrupted).
    var anchor: Int? = nil
    /// The session's process ended while it streamed: no final message came and nothing was stored. It shows as
    /// interrupted, never as a finished reply.
    var interrupted = false
}

/// The user's words the app holds (SessionState.outbox).
struct Outgoing: Equatable {
    /// The client_id it is sent with (a queue entry's own id when it had none).
    var id: String
    var text: String
    /// say | cua | steer: what it is sent as.
    var control: String = "say"
    /// Sent, and the session has not said yet what became of it.
    var sending = false
    /// Why it is not sent: the session's refusal code, or "exited" (its process ended first).
    var refused: String? = nil
    /// Sent after the app knew the latest process had ended (the send opened the session again): for the next
    /// process, so that process's session.start leaves it alone; words sent to a process that a new one replaced
    /// without an exit heard are made unsent by that start.
    var toNextProcess = false
    /// The line as it was first sent, all of it (a /cua's scope, a steer's run): what a resend sends again, never
    /// retargeted. nil for words the app took over from the queue at an exit (a say).
    var original: SessionControl? = nil
}

struct StoredError: Equatable {
    var seq: Int
    var error: SessionErrorEvent
    var t: Double?
}

struct StepState: Equatable {
    enum Status: String, Equatable {
        case running                // sent, no step_result yet
        case ok, unverified, refused, stale, error
        case unknown                // a stop came while it was with the driver: whether it took effect is not known
        case notFinished            // the task ended before this step had a result
    }
    var id: String
    var n: Int                      // 1, 2, … in the order the steps came
    var text: String                // the action as JSON (or the file capability's words)
    var human: String?
    var purpose: String?
    var consequence: String?
    var object: String?
    var planStep: Int?
    var target: StepTarget?
    /// What the step shows: its result, else what the task's end makes of a step with none (SessionReducer.settle).
    var status: Status = .running
    /// Its own result (step_result, or an older harness's status on the step): nil while it has none.
    var result: Status? = nil
    var why: String? = nil
    var executorStatus: String? = nil
    var shot: String? = nil
    var shotPending = false
    var targetFrame: Frame? = nil
    var windowFrame: Frame? = nil
    /// What the step shows: the executor's sentence in the user's language, else the raw action.
    var displayText: String { (human?.isEmpty == false ? human : nil) ?? text }
}

struct CardState: Equatable {
    enum Outcome: Equatable {
        case open
        case answered               // resumed{ask_id}: the answer took effect
        case void(String)           // steer | stop | ended (ask_void / resumed{voided}), or task_done (the task ended first)
    }
    var askId: String
    var card: CardEvent
    var askedAt: Double?
    /// What the card shows: its own outcome, else open, or void when its task ended first (SessionReducer.settle).
    var outcome: Outcome = .open
    /// What the run said of it (resumed, ask_void, a newer card): it always wins over what the task's end implies.
    var explicit: Outcome? = nil
    /// consent.picked after an action card was answered: what the consent covers (action / object / rule), if any.
    var picked: String? = nil
}

enum UndoState: Equatable {
    case none                       // no result card that offers undo
    case available                  // the result card's undo can be clicked (the executor lingers)
    case done(undone: Int, total: Int, refused: String?)
    case declined                   // the user picked another option on the result card ("OK")
    case expired(String)            // linger | new_task | session_end: the executor is gone, undo with it
}

struct TaskState: Equatable {
    var runId: String
    var msgId: String? = nil
    var raw = ""
    var goal: String? = nil
    var by: String? = nil           // slash | model
    var replyTo: String? = nil
    var lang: String? = nil
    var startedAt: Double? = nil
    /// Between session.task / start and the first plan, step or card.
    var preparing = true
    var plan: [PlanEvent.Step] = []
    var steps: [StepState] = []
    var cards: [CardState] = []
    var openCardId: String? = nil
    /// The executor waits for the user to stop using the Mac (waiting without ask_id).
    var userActive = false
    /// The verdict wants evidence only: from here the task only looks (verify unknown, missing evidence).
    var lookOnly = false
    /// The user stopped it (refused by user) and task_done has not come yet.
    var stopping = false
    var steersSent: [String] = []   // session.steer
    var steered: [String] = []      // steered: the executor took them
    var refusals: [RefusedEvent] = []
    /// The executor's running total (changes events).
    var runChanges: Changes? = nil
    var verify: VerifyEvent? = nil
    /// answer_given's text.
    var givenAnswer: String? = nil
    var done: TaskDone? = nil
    var doneAt: Double? = nil
    var end: SessionTaskEnd? = nil
    var endSeq: Int? = nil          // the session seq of session.task_end
    /// What came of an undo: session.task_undo's (preferred) and result_response's; nil while none was done.
    var sessionUndo: UndoState? = nil
    var responseUndo: UndoState? = nil
    var resultResponse: ResultResponse? = nil
    /// The session seq of session.task: the task's place in the chat (nil until it comes).
    var sessionSeq: Int? = nil
    /// session.task_closed's why.
    var closedWhy: String? = nil
    /// The session process that started it is gone (its session.task seq is at or below SessionState.goneUpTo). A run
    /// whose session.task has not come is not tied to a process yet, and is not gone.
    var gone = false
    /// The run's contiguous cursor: every executor seq up to it is applied (replays at or below it are skipped).
    var lastSeq = 0

    /// Undo, from the facts whichever order they came in: an undo done or the result card answered otherwise; else
    /// offered by session.task_end's `undo` ("open" / "none") when it came, by the result card's options before; an
    /// offer whose executor closed (session.task_closed) is expired.
    var undo: UndoState {
        if let d = sessionUndo ?? responseUndo { return d }
        let offered: Bool
        if let u = end?.undo, u == "open" || u == "none" { offered = u == "open" }
        else { offered = done?.resultCard?.options.contains { $0.kind == "undo" } == true }
        guard offered else { return .none }
        if resultResponse != nil { return .declined }
        if let why = closed { return .expired(why) }
        return .available
    }
    /// Why the task ended, structured: task_done's, else session.task_end's.
    var cause: TaskCause? { done?.cause ?? end?.cause }
    /// What it changed: task_done's (with the windows it made from the running total), else session.task_end's when
    /// no task_done came, else the running total — whichever order they came in.
    var changes: Changes {
        if let d = done?.changes {
            var m = d
            if m.createdWindows == nil { m.createdWindows = runChanges?.createdWindows }
            return m
        }
        if done == nil, let e = end?.changes { return e }
        return runChanges ?? Changes()
    }
    /// The answer: task_done's, else answer_given's, else session.task_end's.
    var answer: String? { done?.answer ?? givenAnswer ?? end?.answer }

    /// Its result card is closed: session.task_closed, or its process is gone (and its executor with it).
    var closed: String? { closedWhy ?? (gone ? "session_exit" : nil) }
    /// Its process went away before it ended (no task_done, no session.task_end): it is not running any more.
    var cutOff: Bool { gone && done == nil && end == nil }

    var ended: Bool { done != nil || end != nil || cutOff }
    var running: Bool { !ended }
    var openCard: CardState? { openCardId.flatMap { id in cards.first { $0.askId == id } } }
    /// The task's final status: task_done's, else session.task_end's (`interrupted` when no task_done was ever written).
    var status: String? { done?.status ?? end?.status }
    var resultCard: CardEvent? { done?.resultCard }
    func step(_ id: String) -> StepState? { steps.first { $0.id == id } }
}

enum TimelineItem: Equatable {
    case message(String)            // msg_id
    case task(String)               // run_id
    case error(Int)                 // a stored session.error, by seq
}

struct SessionState: Equatable {
    var sessionId: String? = nil
    var resumed = false
    /// The session stream's contiguous cursor: every stored session seq up to it is applied.
    var lastSeq = 0
    /// Lines held back past a gap, by seq: the session stream's, and each run's.
    var pendingSession: [Int: ProtocolLine] = [:]
    var pendingRuns: [String: [Int: ProtocolLine]] = [:]
    var messages: [ChatMessage] = []
    var tasks: [TaskState] = []
    var timeline: [TimelineItem] = []
    /// How many items at the front of `timeline` / `tasks` have their stored place (SessionReducer.place).
    var placedItems = 0
    var placedTasks = 0
    /// Where each run's task is in `tasks` (a long session has many; looking one up must not scan them all).
    var taskPos: [String: Int] = [:]
    var queue: [QueueItem] = []
    /// The user's words the app holds, by client_id: sent and not yet taken (`sending`), or not sent — refused by the
    /// session, or queued when its process ended. Each piece of text has one owner at a time: here, the session's
    /// queue, or the history. It leaves here only when the session says it took it (the stored user message, the
    /// session.steer, a queue entry with its client_id), comes back (not sending) on a refusal naming it, and is never
    /// dropped on the helper's ack (SessionClient.send / resend; dropUnsent is the user's choice).
    var outbox: [Outgoing] = []
    /// A queue snapshot held back while stored session lines before it wait behind a gap (applied when they are in).
    var deferredQueue: [QueueItem]? = nil
    /// The client_ids the history took (a stored user message or session.steer): never anyone else's again.
    var taken: Set<String> = []
    /// The newest stored seq received when it was held: it applies once the stored lines up to there are in.
    var deferredMark = 0
    /// The app opened the session (SessionClient.open started a process) and has not heard that process's start yet:
    /// words sent meanwhile are the new process's (Outgoing.toNextProcess).
    var awaitingStart = false
    /// How many new processes' starts were heard (SessionClient.open tells whether its process's start came already).
    var starts = 0
    /// The stored seq the awaited process starts at (the open reply's last_seq), when the helper said it.
    var awaitedStart: Int? = nil
    /// The awaited process's pid (the open reply's).
    var awaitedPid: Int? = nil
    /// What is not sent: shown with 「重新发送」 (SessionClient.resend) or dropped (SessionClient.dropUnsent).
    var unsent: [Outgoing] { outbox.filter { !$0.sending } }
    var errors: [StoredError] = []
    /// The latest refusal of a control (busy, card_open, computer_busy, …): not stored, shown once.
    var lastRefusal: SessionErrorEvent? = nil
    var unknownKinds: Set<String> = []
    /// Replies whose bubble left (never said a word, or failed): their deltas, replayed, do not bring it back.
    var droppedMessages: Set<String> = []
    /// The stored seq the user has seen up to (markSeen): problems after it make the error dot.
    var seenSeq = 0
    var lastEventAt: Double? = nil
    /// The latest process ended (helper.session_exit for it, its exit code): nothing runs until it is opened again
    /// (SessionClient re-opens it on the next send or watch); the next process's session.start clears it.
    var exited: Int? = nil
    /// The latest process (its session.start): its pid (when the helper adds it) and the stored seq it started at.
    var processPid: Int? = nil
    var processStart: Int? = nil
    /// Runs whose session.task seq is at or below this belong to processes that are gone: an exit's last_seq, or a
    /// later process's start (only one process runs a session at a time).
    var goneUpTo = 0

    func message(_ id: String) -> ChatMessage? { messages.last { $0.id == id } }
    func task(_ runId: String) -> TaskState? { taskPos[runId].map { tasks[$0] } }
    /// The open card, whichever task holds it (one computer task per session at a time: at most one).
    var openCard: (runId: String, card: CardState)? {
        for t in tasks.reversed() { if let c = t.openCard { return (t.runId, c) } }
        return nil
    }
    /// The composer takes typing unless a card waits: a card is answered on the card (its own field for words).
    var composerEnabled: Bool { openCard == nil }
    var runningTask: TaskState? { tasks.last { $0.running } }
    var streamingMessage: ChatMessage? { messages.last { $0.streaming } }
    var status: SessionStatus { SessionStatus.derive(self) }
    /// A stream has lines held back past a gap: watch again from the cursors to get the missing ones.
    var hasGap: Bool { !pendingSession.isEmpty || !pendingRuns.isEmpty }

    /// The user opened this session: the error dot clears.
    mutating func markSeen() { seenSeq = lastSeq }
}

// MARK: - Reducer

enum SessionReducer {
    static func reduce(_ state: SessionState, _ line: ProtocolLine) -> SessionState {
        var s = state
        apply(&s, line)
        return s
    }

    static func reduce(_ state: SessionState, _ lines: [ProtocolLine]) -> SessionState {
        lines.reduce(state, reduce)
    }

    /// What became of a line.
    enum Applied: Equatable {
        case applied                // in its place (with any held lines that now follow)
        case duplicate              // its stream already has it
        case held                   // past a gap: held back until the missing lines come
        case ignored                // an executor event with no run
    }

    @discardableResult
    static func apply(_ s: inout SessionState, _ line: ProtocolLine) -> Applied {
        let ev = line.event
        if ev.isSessionEvent {
            guard let seq = line.seq else { applySession(&s, line); return .applied }
            if seq <= s.lastSeq { return .duplicate }               // a replay of a stored event
            if seq > s.lastSeq + 1 { s.pendingSession[seq] = line; return .held }
            applySession(&s, line)
            // a held queue snapshot applies right after the stored lines that came before it (not after later ones)
            func deferred() { if let d = s.deferredQueue, s.lastSeq >= s.deferredMark { applyQueue(&s, d); s.deferredQueue = nil } }
            deferred()
            while let next = s.pendingSession.removeValue(forKey: s.lastSeq + 1) { applySession(&s, next); deferred() }
            s.pendingSession = s.pendingSession.filter { $0.key > s.lastSeq }
            return .applied
        } else {
            if case .unknown(let k, _) = ev { s.unknownKinds.insert(k) }
            guard let runId = line.runId else { return .ignored }   // an executor event belongs to a run
            guard let seq = line.seq else { applyExecutor(&s, runId, line); return .applied }
            let cursor = s.taskPos[runId].map { s.tasks[$0].lastSeq } ?? 0
            if seq <= cursor { return .duplicate }
            if seq > cursor + 1 { s.pendingRuns[runId, default: [:]][seq] = line; return .held }
            applyExecutor(&s, runId, line)
            while let i = s.taskPos[runId],
                  let next = s.pendingRuns[runId]?.removeValue(forKey: s.tasks[i].lastSeq + 1) {
                applyExecutor(&s, runId, next)
            }
            let now = s.taskPos[runId].map { s.tasks[$0].lastSeq } ?? 0
            let rest = (s.pendingRuns[runId] ?? [:]).filter { $0.key > now }
            s.pendingRuns[runId] = rest.isEmpty ? nil : rest
            return .applied
        }
    }

    /// One session line in its place.
    private static func applySession(_ s: inout SessionState, _ line: ProtocolLine) {
        if let seq = line.seq { s.lastSeq = seq }
        if let t = line.t { s.lastEventAt = max(s.lastEventAt ?? t, t) }
        session(&s, line.event, line)
        // what the line implies about runs: their own task only, or every task when the process went away
        switch line.event {
        case .task(let e): settle(&s, e.runId)
        case .taskEnd(let e): settle(&s, e.runId)
        case .taskClosed(let e): settle(&s, e.runId)
        case .taskUndo(let e): settle(&s, e.runId)
        case .steer(let e): settle(&s, e.runId)
        case .sessionExit, .sessionStart: for i in s.tasks.indices { settle(&s.tasks[i], goneUpTo: s.goneUpTo) }
        default: break
        }
    }

    private static func settle(_ s: inout SessionState, _ runId: String) {
        if let i = s.taskPos[runId] { settle(&s.tasks[i], goneUpTo: s.goneUpTo) }
    }

    /// One executor line of `runId` in its place.
    private static func applyExecutor(_ s: inout SessionState, _ runId: String, _ line: ProtocolLine) {
        let i = taskIndex(&s, runId)
        if let seq = line.seq { s.tasks[i].lastSeq = seq }
        if let t = line.t { s.lastEventAt = max(s.lastEventAt ?? t, t) }
        executor(&s.tasks[i], line.event, line.t)
        settle(&s.tasks[i], goneUpTo: s.goneUpTo)
    }

    // MARK: the order of the chat

    // The chat (timeline) and the tasks are in the order the session stored them, whatever order the streams came in:
    // a front part of stored items in seq order (`placedItems`, `placedTasks` long), then what has no stored place yet
    // (a reply streaming, a run whose session.task has not come) as it came. Session lines come in seq order, so an
    // item that gets its stored seq goes at the end of the front part; a reply cut off by the process's end (never
    // stored) goes right after what was stored when it began (`placeInterrupted`).

    /// `item` just got its stored seq `seq`, the newest stored: to the end of the stored part — before any cut-off
    /// reply placed there that began after it (its anchor is at or past `seq`).
    private static func place(_ s: inout SessionState, _ item: TimelineItem, seq: Int) {
        if let i = s.timeline.lastIndex(of: item) {
            s.timeline.remove(at: i)
            if i < s.placedItems { s.placedItems -= 1 }
        }
        var at = s.placedItems
        while at > 0, case .message(let id) = s.timeline[at - 1], let m = s.message(id), m.seq == nil, m.interrupted, let a = m.anchor, a >= seq {
            at -= 1
        }
        s.timeline.insert(item, at: at)
        s.placedItems += 1
    }

    /// The task got its session.task: to the end of the stored tasks, and its item in the chat with it.
    private static func placeTask(_ s: inout SessionState, _ runId: String) {
        if let i = s.taskPos[runId], i >= s.placedTasks {
            if i != s.placedTasks {
                s.tasks.insert(s.tasks.remove(at: i), at: s.placedTasks)
                for k in s.placedTasks...i { s.taskPos[s.tasks[k].runId] = k }
            }
            s.placedTasks += 1
        }
        if let q = s.task(runId)?.sessionSeq { place(&s, .task(runId), seq: q) }
    }

    /// A reply cut off by the process's end: right after the stored items up to the seq it began at.
    private static func placeInterrupted(_ s: inout SessionState, _ id: String, anchor: Int) {
        guard let i = s.timeline.lastIndex(of: .message(id)), i >= s.placedItems else { return }
        s.timeline.remove(at: i)
        var msgSeq: [String: Int] = [:]
        for m in s.messages { if let q = m.seq { msgSeq[m.id] = q } else if m.interrupted, let a = m.anchor { msgSeq[m.id] = a } }
        var taskSeq: [String: Int] = [:]
        for t in s.tasks { if let q = t.sessionSeq { taskSeq[t.runId] = q } }
        func key(_ item: TimelineItem) -> Int {
            switch item {
            case .message(let m): return msgSeq[m] ?? 0
            case .task(let r): return taskSeq[r] ?? 0
            case .error(let q): return q
            }
        }
        let at = s.timeline[..<s.placedItems].firstIndex { key($0) > anchor } ?? s.placedItems
        s.timeline.insert(.message(id), at: at)
        s.placedItems += 1
    }

    /// The latest process went away: a reply it was streaming is cut off (kept, interrupted, at its place); what it
    /// had queued was never sent (SessionState.unsent).
    /// `exited`: an exit (helper.session_exit, or the app's own inference), not a new process's session.start — words
    /// sent to the new process (a send reopens the session first) are not the old one's.
    private static func processGone(_ s: inout SessionState, exited: Bool) {
        dropEmptyStreaming(&s)
        for i in s.messages.indices where s.messages[i].streaming {
            s.messages[i].streaming = false
            s.messages[i].interrupted = true
            if let a = s.messages[i].anchor { placeInterrupted(&s, s.messages[i].id, anchor: a) }
        }
        // the latest queue it said it had (one held back behind a gap included); words whose stored line is held
        // behind a gap were taken already, and stay the history's
        if let d = s.deferredQueue { applyQueue(&s, d); s.deferredQueue = nil }
        let held = heldClientIds(s)
        for q in s.queue {
            let id = q.clientId ?? q.id
            if !held.contains(id) && !s.outbox.contains(where: { $0.id == id }) { s.outbox.append(Outgoing(id: id, text: q.text, control: "say")) }
        }
        s.queue = []
        // sent and never taken: the process is gone, so it is not sent (should its stored message still come in a
        // replay, that takes it out again)
        // (at a new process's start: words sent to the one before it — not those sent for the new one, which are its own)
        for i in s.outbox.indices where s.outbox[i].sending && !held.contains(s.outbox[i].id) && (exited || !s.outbox[i].toNextProcess) {
            s.outbox[i].sending = false; s.outbox[i].refused = "exited"
        }
        if !exited { for i in s.outbox.indices where s.outbox[i].toNextProcess { s.outbox[i].toNextProcess = false } }
    }

    /// The client_ids of the user's words whose stored line (session.message / session.steer) is held behind a gap.
    private static func heldClientIds(_ s: SessionState) -> Set<String> {
        var ids: Set<String> = []
        for l in s.pendingSession.values {
            switch l.event {
            case .message(let m): if let c = m.clientId { ids.insert(c) }
            case .steer(let e): if let c = e.clientId { ids.insert(c) }
            default: break
            }
        }
        return ids
    }

    /// The session took the app's words into the history (a stored user message or session.steer with their
    /// client_id): the one place they live from now on. Every acceptance goes through here, and it takes them out of
    /// every other place they could be — the outbox (sending or unsent), the queue, a held queue snapshot — and keeps
    /// the id, so that no older snapshot puts them back.
    private static func taken(_ s: inout SessionState, _ id: String) {
        s.taken.insert(id)
        if s.outbox.contains(where: { $0.id == id }) { s.outbox.removeAll { $0.id == id } }
        if s.queue.contains(where: { $0.clientId == id }) { s.queue.removeAll { $0.clientId == id } }
        if s.deferredQueue?.contains(where: { $0.clientId == id }) == true { s.deferredQueue?.removeAll { $0.clientId == id } }
    }

    /// A queue snapshot in its place: the whole queue; the app's words in it are the queue's now (words the history
    /// took already are not: the snapshot is older than that).
    private static func applyQueue(_ s: inout SessionState, _ items: [QueueItem]) {
        let items = items.filter { $0.clientId.map { !s.taken.contains($0) } ?? true }
        s.queue = items
        let queued = Set(items.compactMap(\.clientId))
        if !queued.isEmpty { s.outbox.removeAll { queued.contains($0.id) } }
    }

    // MARK: session events

    private static func session(_ s: inout SessionState, _ ev: ProtocolEvent, _ line: ProtocolLine) {
        switch ev {
        case .sessionStart(let e):
            if let id = line.sessionId { s.sessionId = id }
            s.resumed = e.resumed
            // the same process's start again (a replay fed twice): nothing new. By pid when the helper adds it; else
            // a start at the same stored seq while the latest process has not exited.
            // While the app awaits the process it started (awaitingStart): a start at or past that process's stored seq
            // (the open reply's last_seq) is it; one before it is an older process's, late (nothing to do).
            let same: Bool
            if s.awaitingStart {
                if let want = s.awaitedStart, let l = e.lastSeq { same = l < want } else { same = false }
            }
            else if let p = e.pid, let cur = s.processPid { same = p == cur }
            else { same = s.exited == nil && s.processStart != nil && e.lastSeq == s.processStart }
            if !same {
                // a new process: the one before is gone, with what lived only in it (whether or not its exit came first)
                processGone(&s, exited: false)
                s.exited = nil
                s.awaitingStart = false
                s.awaitedStart = nil
                s.awaitedPid = nil
                s.starts += 1
                s.processPid = e.pid
                s.processStart = e.lastSeq
                s.goneUpTo = max(s.goneUpTo, e.lastSeq ?? 0)
            }
        case .sessionExit(let e):
            // the latest process, or one before it (an exit that comes after the next process's start)? By the stored
            // seq it started at (start_seq) first, then by pid when both have it: an earlier start is an older process; a
            // later one is newer than the latest start seen (its session.start was missed: it started while no watch
            // was connected), so the latest; the same start is the latest if it stored anything (a later process starts
            // past it), and ambiguous if not — taken for an older one, which loses nothing (a process that stored
            // nothing queued and streamed nothing; a send to it finds it not_open and recovers).
            var latest: Bool
            if let st = s.processStart, let es = e.startSeq, es != st { latest = es > st }      // (a start missed, or an older one)
            else if let p = e.pid, let cur = s.processPid { latest = p == cur }
            else if let st = s.processStart, let es = e.startSeq { latest = (e.lastSeq ?? es) > st }
            else if let st = s.processStart, let l = e.lastSeq { latest = l > st }
            else { latest = true }
            // the app opened the session again and waits for the new process's start: an exit of a process that started
            // no later than the latest start seen is the one before (the app already took it for gone), not the new one
            if s.awaitingStart, let p = e.pid, p == s.awaitedPid,
               (e.startSeq ?? Int.max) >= (s.awaitedStart ?? s.processStart ?? Int.min) {   // (a reused pid of an older start: not it)
                // the awaited process's own exit, by the open reply's pid (its start missed, or already heard): it is
                // the latest, and nothing is awaited any more
                latest = true
                s.awaitingStart = false; s.awaitedStart = nil; s.awaitedPid = nil
            } else if s.awaitingStart, let es = e.startSeq {
                // past the seq the awaited process starts at: it (its start missed); before: an older one; at it: by pid
                // (the open reply's), else taken for the older one (which loses nothing; a send recovers on not_open)
                if let want = s.awaitedStart { latest = es > want || (es == want && ((e.pid != nil && e.pid == s.awaitedPid) || (e.lastSeq ?? es) > want)) }
                else if let st = s.processStart, es <= st { latest = false }
            }
            // its runs are gone whenever this comes; without last_seq, those the app has seen of the latest process
            if let l = e.lastSeq { s.goneUpTo = max(s.goneUpTo, l) }
            else if latest { s.goneUpTo = max(s.goneUpTo, s.lastSeq, s.pendingSession.keys.max() ?? 0) }
            if latest {
                s.exited = e.code ?? -1
                processGone(&s, exited: true)
            }
        case .message(let m):
            // the session took the app's words: they leave the outbox, and the queue entry they waited in
            if let c = m.clientId, m.role == "user" { taken(&s, c) }
            if let i = s.messages.lastIndex(where: { $0.id == m.msgId }) {
                s.messages[i].text = m.text
                s.messages[i].role = m.role
                s.messages[i].streaming = false
                s.messages[i].gap = false
                s.messages[i].replyTo = m.replyTo
                s.messages[i].model = m.model
                s.messages[i].via = m.via
                s.messages[i].stopped = m.stopped ?? false
                s.messages[i].truncated = m.truncated ?? false
                s.messages[i].t = line.t
                s.messages[i].seq = line.seq
                s.messages[i].interrupted = false
                s.messages[i].anchor = nil              // stored: its place is its seq
                if let q = line.seq { place(&s, .message(m.msgId), seq: q) }
            } else {
                // (stored: whatever was dropped of it before — an empty bubble the process's end removed — is back)
                s.droppedMessages.remove(m.msgId)
                if m.role == "assistant" { dropEmptyStreaming(&s) }
                s.messages.append(ChatMessage(id: m.msgId, role: m.role, text: m.text, streaming: false, replyTo: m.replyTo, model: m.model,
                                              via: m.via, stopped: m.stopped ?? false, truncated: m.truncated ?? false, t: line.t, seq: line.seq))
                s.timeline.append(.message(m.msgId))
                if let q = line.seq { place(&s, .message(m.msgId), seq: q) }
            }
        case .delta(let d):
            delta(&s, d, t: line.t)
        case .sessionError(let e):
            if let id = e.msgId { dropStreaming(&s, id) }
            if let seq = line.seq {
                s.errors.append(StoredError(seq: seq, error: e, t: line.t))
                s.timeline.append(.error(seq))
                place(&s, .error(seq), seq: seq)
            } else {
                s.lastRefusal = e
                // a refusal of the app's words: they are the app's again, not sent (a queue entry's refusal leaves it
                // in the queue, the session's: nothing here then)
                if let c = e.clientId, let i = s.outbox.firstIndex(where: { $0.id == c }) {
                    s.outbox[i].sending = false
                    s.outbox[i].refused = e.code
                }
            }
        case .task(let e):
            dropEmptyStreaming(&s)
            let i = taskIndex(&s, e.runId)
            s.tasks[i].msgId = e.msgId
            s.tasks[i].raw = e.raw
            s.tasks[i].goal = e.goal
            s.tasks[i].by = e.by
            s.tasks[i].replyTo = e.replyTo
            s.tasks[i].startedAt = line.t ?? s.tasks[i].startedAt     // session.task's time, before or after the run's start
            if let seq = line.seq, s.tasks[i].sessionSeq == nil {
                s.tasks[i].sessionSeq = seq
                placeTask(&s, e.runId)
            }
        case .taskEnd(let e):
            let i = taskIndex(&s, e.runId)
            s.tasks[i].end = e
            s.tasks[i].endSeq = line.seq
        case .taskClosed(let e):
            let i = taskIndex(&s, e.runId)
            s.tasks[i].closedWhy = e.why
        case .taskUndo(let e):
            let i = taskIndex(&s, e.runId)
            s.tasks[i].sessionUndo = .done(undone: e.undone ?? 0, total: e.total ?? 0, refused: e.refused)
        case .steer(let e):
            if let c = e.clientId { taken(&s, c) }
            let i = taskIndex(&s, e.runId)
            s.tasks[i].steersSent.append(e.text)
        case .retry(let e):
            for i in s.messages.indices where s.messages[i].role == "assistant" && s.messages[i].replyTo == e.replyTo {
                s.messages[i].retracted = true
            }
        case .queue(let q):
            // the whole queue, as the session has it (attach sends it, empty included): it replaces the app's — once
            // the stored lines before it are in (the session stores queued words before it sends the queue without
            // them: applied while their stored line is held behind a gap, the words would be in neither place)
            if s.pendingSession.isEmpty { applyQueue(&s, q.items); s.deferredQueue = nil }
            else { s.deferredQueue = q.items; s.deferredMark = max(s.lastSeq, s.pendingSession.keys.max() ?? 0) }
        case .duplicate(let d):
            // the session had taken these words already (their stored line has come, or comes in a replay)
            if !d.clientId.isEmpty { taken(&s, d.clientId) }
        case .unknown(let k, _):
            s.unknownKinds.insert(k)
        default:
            break
        }
    }

    /// Streaming assembly, by offset in UTF-16 code units (the harness counts a JavaScript string's length).
    private static func delta(_ s: inout SessionState, _ d: SessionDelta, t: Double?) {
        let i: Int
        if let found = s.messages.lastIndex(where: { $0.id == d.msgId }) {
            i = found
        } else {
            if s.droppedMessages.contains(d.msgId) { return }
            dropEmptyStreaming(&s)
            // its place, should it never be stored: after the newest stored line here, held ones included
            s.messages.append(ChatMessage(id: d.msgId, role: "assistant", text: "", streaming: true, t: t,
                                          anchor: max(s.lastSeq, s.pendingSession.keys.max() ?? 0)))
            s.timeline.append(.message(d.msgId))
            i = s.messages.count - 1
        }
        guard s.messages[i].streaming else { return }   // the final message is in: deltas replayed after it change nothing
        let cur = Array(s.messages[i].text.utf16)
        let add = Array(d.text.utf16)
        let off = d.offset ?? cur.count
        // past the end: a gap, wait for the final text (or a full offset-0 delta); negative: a broken line, the same
        if off < 0 || off > cur.count { s.messages[i].gap = true; return }
        if add.isEmpty { return }
        // already have exactly these units at this place: a duplicate, keep what follows
        if off + add.count <= cur.count && Array(cur[off..<(off + add.count)]) == add { return }
        // otherwise what came replaces everything from `off` on (offset 0 with the whole text: the full replacement)
        let joined = Array(cur[0..<off]) + add
        s.messages[i].text = String(decoding: joined, as: UTF16.self)
        if off == 0 { s.messages[i].gap = false }
    }

    /// A reply that opened (its empty first delta) and never said a word: the model went straight to a computer task, or
    /// a new reply began. It leaves the chat.
    private static func dropEmptyStreaming(_ s: inout SessionState) {
        let gone = Set(s.messages.filter { $0.streaming && $0.text.isEmpty }.map(\.id))
        guard !gone.isEmpty else { return }
        s.droppedMessages.formUnion(gone)
        s.messages.removeAll { gone.contains($0.id) }
        s.timeline.removeAll { if case .message(let id) = $0 { return gone.contains(id) }; return false }
    }

    /// A failed reply's deltas are void: the growing bubble leaves (a final message is never removed).
    /// (Also one already cut off by the process's end, whichever of the two came first: it was never a reply.)
    private static func dropStreaming(_ s: inout SessionState, _ id: String) {
        guard let m = s.message(id), m.streaming || (m.seq == nil && m.interrupted) else { return }
        s.droppedMessages.insert(id)
        s.messages.removeAll { $0.id == id }
        if let i = s.timeline.lastIndex(of: .message(id)) {
            s.timeline.remove(at: i)
            if i < s.placedItems { s.placedItems -= 1 }
        }
    }

    private static func taskIndex(_ s: inout SessionState, _ runId: String) -> Int {
        if let i = s.taskPos[runId] { return i }
        s.taskPos[runId] = s.tasks.count
        s.tasks.append(TaskState(runId: runId))
        s.timeline.append(.task(runId))
        return s.tasks.count - 1
    }

    // MARK: executor events

    private static func executor(_ task: inout TaskState, _ ev: ProtocolEvent, _ t: Double?) {
        switch ev {
        case .start(let e):
            if task.raw.isEmpty { task.raw = e.raw }
            task.lang = e.lang
            if task.startedAt == nil { task.startedAt = t }
        case .preparing:
            break
        case .plan(let p):
            task.plan = p.steps
            task.preparing = false
        case .step(let e):
            task.preparing = false
            let id = e.stepId ?? "step-\(task.steps.count + 1)"
            var st = task.step(id) ?? StepState(id: id, n: task.steps.count + 1, text: e.text)
            st.text = e.text
            st.human = e.human
            st.purpose = e.purpose
            st.consequence = e.consequence
            st.object = e.object
            st.planStep = e.planStep
            st.target = e.target
            if e.stepId == nil, let old = e.status { st.result = resultStatus(old, else: .ok) }   // an older harness: one line per step
            if let i = task.steps.firstIndex(where: { $0.id == id }) { task.steps[i] = st } else { task.steps.append(st) }
        case .stepResult(let r):
            guard let i = task.steps.firstIndex(where: { $0.id == r.stepId }) else { return }
            task.steps[i].result = resultStatus(r.status, else: .error)
            task.steps[i].why = r.why
            task.steps[i].executorStatus = r.executorStatus
            if let c = r.consequence { task.steps[i].consequence = c }
            task.steps[i].shot = r.shot
            task.steps[i].shotPending = r.shotPending ?? false
            task.steps[i].targetFrame = r.targetFrame
            task.steps[i].windowFrame = r.windowFrame
        case .shotReady(let r):
            guard let i = task.steps.firstIndex(where: { $0.id == r.stepId }) else { return }
            task.steps[i].shot = r.shot
            task.steps[i].shotPending = false
        case .ask(let a):
            task.preparing = false
            // a card asked again (a replay without seq): nothing changes, an answered or voided one stays closed
            if task.cards.contains(where: { $0.askId == a.askId }) { break }
            // a new card: one the run left open before it is replaced (one card waits at a time)
            for i in task.cards.indices where task.cards[i].explicit == nil { task.cards[i].explicit = .void("replaced") }
            task.cards.append(CardState(askId: a.askId, card: a.card, askedAt: t))
        case .waiting(let w):
            if w.askId == nil && task.running { task.userActive = true }
        case .resumed(let r):
            if let id = r.askId {
                setOutcome(&task, id, r.voided.map { .void($0) } ?? .answered)
            } else {
                task.userActive = false
            }
        case .askVoid(let v):
            setOutcome(&task, v.askId, .void(v.why))
        case .consent(let c):
            if let i = task.cards.lastIndex(where: { $0.outcome == .answered }) { task.cards[i].picked = c.picked }
        case .refused(let r):
            task.refusals.append(r)
            if r.by == "user" && task.running { task.stopping = true }
        case .steered(let e):
            task.steered.append(e.text)
            // the executor drops "only look for evidence" when it applies a steer (harness ed96440, applySteers;
            // docs/protocol.md: until finish unconfirmed, or the user changed the request)
            task.lookOnly = false
        case .verify(let v):
            task.verify = v
            task.lookOnly = v.verdict == "unknown" && v.missingKind == "evidence"
        case .changes(let c):
            task.runChanges = c
        case .answerGiven(let a):
            task.givenAnswer = a.text
        case .taskDone(let d):
            task.done = d
            task.doneAt = t
        case .resultResponse(let r):
            task.resultResponse = r
            if let undone = r.undone { task.responseUndo = .done(undone: undone, total: r.total ?? undone, refused: r.refused) }
            else if r.picked == "undo" { task.responseUndo = .done(undone: 0, total: r.total ?? 0, refused: r.refused) }
        case .modelCall, .judge, .unknown:
            break
        default:
            break
        }
    }

    /// The run's word on a card (the first wins): over whatever the task's end implied, which was only provisional.
    private static func setOutcome(_ task: inout TaskState, _ askId: String, _ outcome: CardState.Outcome) {
        if let i = task.cards.firstIndex(where: { $0.askId == askId }), task.cards[i].explicit == nil { task.cards[i].explicit = outcome }
    }

    /// A step result's status from the wire: one of the results a step can have, else `fallback`.
    private static func resultStatus(_ raw: String, else fallback: StepState.Status) -> StepState.Status {
        switch StepState.Status(rawValue: raw) {
        case .ok?: return .ok
        case .unverified?: return .unverified
        case .refused?: return .refused
        case .stale?: return .stale
        case .error?: return .error
        default: return fallback
        }
    }

    /// What the task's facts make of its parts, whichever stream told what first (a replay sends the session's events
    /// before the runs'): a card shows the run's word on it, else open while the task runs, else void (its task ended
    /// first); a step shows its result, else running while the task runs, else — the task ended without one — not
    /// finished, the last such one unknown when the end says so (cause last_step_unknown) or the process went away. An
    /// ended task waits for nobody: no open card, no pause, no look-only, no stopping, no preparing.
    private static func settle(_ task: inout TaskState, goneUpTo: Int) {
        let gone = task.sessionSeq.map { $0 <= goneUpTo } ?? false
        if task.gone != gone { task.gone = gone }
        let ended = task.ended
        let endedWhy = (task.done == nil && task.end == nil) ? "session_exit" : "task_done"
        // (written only where it changes: the arrays stay shared with the state before, which keeps feeding cheap)
        for i in task.cards.indices {
            let o = task.cards[i].explicit ?? (ended ? .void(endedWhy) : .open)
            if task.cards[i].outcome != o { task.cards[i].outcome = o }
        }
        let open = ended ? nil : task.cards.last { $0.outcome == .open }?.askId
        if task.openCardId != open { task.openCardId = open }
        let lastUnknown = task.cause == .lastStepUnknown || (task.cutOff && task.done == nil && task.end == nil)
        let lastUnresolved = task.steps.lastIndex { $0.result == nil }
        for i in task.steps.indices {
            let st = task.steps[i].result ?? (!ended ? .running : (lastUnknown && i == lastUnresolved) ? .unknown : .notFinished)
            if task.steps[i].status != st { task.steps[i].status = st }
        }
        if ended && (task.userActive || task.lookOnly || task.stopping || task.preparing) {
            task.userActive = false
            task.lookOnly = false
            task.stopping = false
            task.preparing = false
        }
    }
}

// MARK: - The status dot (handoff §1.5)

/// What a session row's dot says. Each case has its own shape (`shape`) and the row always has words beside it, so it
/// never rests on colour alone.
enum SessionStatus: Equatable {
    case waitingForYou(cardKind: String)    // a card waits
    case error(String)                      // a task ended failed / environment / unconfirmed, or the model failed (its code); not yet seen
    case locked                             // the task ended because the screen is locked; not yet seen
    case stopping                           // the user stopped the task; its end has not come yet
    case paused                             // the executor waits while the user uses the Mac
    case lookOnly                           // the verdict wants evidence: the task only looks now ("checking the result")
    case acting(step: Int, of: Int?)        // "step n of m" (m from the plan, when the steps say which plan step they serve)
    case thinking                           // a reply is streaming, or a task is preparing
    case done(at: Double?, stopped: Bool)
    case idle

    enum Shape: Equatable { case haloDot, bang, solidDot, hollowRing, check, mistDot }
    var shape: Shape {
        switch self {
        case .waitingForYou: return .haloDot
        case .error, .locked: return .bang
        case .stopping, .paused, .lookOnly, .acting: return .solidDot
        case .thinking: return .hollowRing
        case .done: return .check
        case .idle: return .mistDot
        }
    }

    static let problemStatuses: Set<String> = ["failed", "environment", "unconfirmed", "interrupted"]

    /// The first that holds, in the handoff's order — with one reading of it: a task that is running (the newest) goes
    /// before an earlier task's unseen error, since a session runs one computer task at a time and the running one is
    /// what the user needs to see. (Owner confirmed this order, 10-22.)
    static func derive(_ s: SessionState) -> SessionStatus {
        // 1. waiting for you: a card is open
        if let open = s.openCard { return .waitingForYou(cardKind: open.card.card.kind) }
        // 2. a running task
        if let t = s.runningTask {
            if t.stopping { return .stopping }
            if t.preparing { return .thinking }
            if t.userActive { return .paused }
            if t.lookOnly { return .lookOnly }
            let last = t.steps.last
            if !t.plan.isEmpty, let p = last?.planStep { return .acting(step: p, of: t.plan.count) }
            return .acting(step: t.steps.count, of: nil)
        }
        // 3. an error the user has not seen: the newest task's bad end, or the model's error
        if let p = problem(s) { return p }
        // 4. thinking: a reply is streaming
        if s.streamingMessage != nil { return .thinking }
        // 5. done: the newest thing in the chat is a task that ended or an assistant message
        for item in s.timeline.reversed() {
            switch item {
            case .task(let id):
                guard let t = s.task(id), let st = t.status else { continue }
                if st == "succeeded" { return .done(at: t.doneAt ?? s.lastEventAt, stopped: false) }
                if st == "cancelled" || st == "stopped" { return .done(at: t.doneAt ?? s.lastEventAt, stopped: true) }
                return .idle
            case .message(let id):
                guard let m = s.message(id) else { continue }
                // done only with the final message: a reply cut off by the process's end is not a finished one
                return m.role == "assistant" && !m.interrupted ? .done(at: m.t, stopped: m.stopped) : .idle
            case .error:
                return .idle
            }
        }
        return .idle
    }

    private static func problem(_ s: SessionState) -> SessionStatus? {
        // the newest of: a task's end with a bad status, a stored model error — after what the user has seen
        var newest: (seq: Int, status: SessionStatus)? = nil
        if let t = s.tasks.last, let st = t.status, problemStatuses.contains(st) {
            let seq = t.endSeq ?? Int.max                   // task_done came, task_end not yet: nothing seen of it
            let locked = t.cause == .screenLocked             // from the structured cause only, never the reason's words
            newest = (seq, locked ? .locked : .error(st))
        }
        if let e = s.errors.last, e.seq > (newest?.seq ?? 0) { newest = (e.seq, .error(e.error.code)) }
        guard let n = newest, n.seq > s.seenSeq else { return nil }
        return n.status
    }
}
