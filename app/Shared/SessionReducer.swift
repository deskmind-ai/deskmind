// A chat session's state, folded from its event stream (ProtocolEvent.swift): the messages (streamed replies assembled
// from session.delta), each computer task by run_id (its steps, the open card, changes, result and undo), the queue,
// errors, whether the composer takes typing, and the status dot (handoff §1.5).
//
// Pure: `SessionReducer.reduce(state, line)` → the next state, nothing else. Replaying lines it already has changes
// nothing (stored session events are deduplicated by their `seq`, an executor's events by `seq` within their run, and the
// unstored ones — deltas, the queue, refusals — are idempotent by construction), so a reconnect may simply replay.

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
    var status: Status = .running
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
    var outcome: Outcome = .open
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
    var changes = Changes()
    var verify: VerifyEvent? = nil
    var answer: String? = nil
    var done: TaskDone? = nil
    var doneAt: Double? = nil
    var end: SessionTaskEnd? = nil
    var endSeq: Int? = nil          // the session seq of session.task_end
    var undo: UndoState = .none
    var resultResponse: ResultResponse? = nil
    var closed: String? = nil       // session.task_closed why
    /// The last executor seq applied (replays at or below it are skipped).
    var lastSeq = 0

    var running: Bool { done == nil && end == nil }
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
    /// The last stored session seq applied.
    var lastSeq = 0
    var messages: [ChatMessage] = []
    var tasks: [TaskState] = []
    var timeline: [TimelineItem] = []
    var queue: [QueueItem] = []
    var errors: [StoredError] = []
    /// The latest refusal of a control (busy, card_open, computer_busy, …): not stored, shown once.
    var lastRefusal: SessionErrorEvent? = nil
    var unknownKinds: Set<String> = []
    /// Replies whose bubble left (never said a word, or failed): their deltas, replayed, do not bring it back.
    var droppedMessages: Set<String> = []
    /// The stored seq the user has seen up to (markSeen): problems after it make the error dot.
    var seenSeq = 0
    var lastEventAt: Double? = nil

    func message(_ id: String) -> ChatMessage? { messages.first { $0.id == id } }
    func task(_ runId: String) -> TaskState? { tasks.first { $0.runId == runId } }
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

    static func apply(_ s: inout SessionState, _ line: ProtocolLine) {
        let ev = line.event
        if ev.isSessionEvent {
            if let seq = line.seq {
                if seq <= s.lastSeq { return }          // a replay of a stored event
                s.lastSeq = seq
            }
            if let t = line.t { s.lastEventAt = max(s.lastEventAt ?? t, t) }
            session(&s, ev, line)
        } else {
            if case .unknown(let k, _) = ev { s.unknownKinds.insert(k) }
            guard let runId = line.runId else { return }   // an executor event belongs to a run
            let i = taskIndex(&s, runId)
            if let seq = line.seq {
                if seq <= s.tasks[i].lastSeq { return }
                s.tasks[i].lastSeq = seq
            }
            if let t = line.t { s.lastEventAt = max(s.lastEventAt ?? t, t) }
            executor(&s.tasks[i], ev, line.t)
        }
    }

    // MARK: session events

    private static func session(_ s: inout SessionState, _ ev: ProtocolEvent, _ line: ProtocolLine) {
        switch ev {
        case .sessionStart(let e):
            if let id = line.sessionId { s.sessionId = id }
            s.resumed = e.resumed
        case .message(let m):
            if let i = s.messages.firstIndex(where: { $0.id == m.msgId }) {
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
            } else {
                if m.role == "assistant" { dropEmptyStreaming(&s) }
                s.messages.append(ChatMessage(id: m.msgId, role: m.role, text: m.text, streaming: false, replyTo: m.replyTo, model: m.model,
                                              via: m.via, stopped: m.stopped ?? false, truncated: m.truncated ?? false, t: line.t))
                s.timeline.append(.message(m.msgId))
            }
        case .delta(let d):
            delta(&s, d, t: line.t)
        case .sessionError(let e):
            if let id = e.msgId { dropStreaming(&s, id) }
            if let seq = line.seq {
                s.errors.append(StoredError(seq: seq, error: e, t: line.t))
                s.timeline.append(.error(seq))
            } else {
                s.lastRefusal = e
            }
        case .task(let e):
            dropEmptyStreaming(&s)
            let i = taskIndex(&s, e.runId)
            s.tasks[i].msgId = e.msgId
            s.tasks[i].raw = e.raw
            s.tasks[i].goal = e.goal
            s.tasks[i].by = e.by
            s.tasks[i].replyTo = e.replyTo
            if s.tasks[i].startedAt == nil { s.tasks[i].startedAt = line.t }
        case .taskEnd(let e):
            let i = taskIndex(&s, e.runId)
            s.tasks[i].end = e
            s.tasks[i].endSeq = line.seq
            if let c = e.changes, s.tasks[i].done == nil { s.tasks[i].changes = c }
            if s.tasks[i].answer == nil { s.tasks[i].answer = e.answer }
            if s.tasks[i].done == nil { closeOpenParts(&s.tasks[i], reason: e.reason ?? "") }
            switch (e.undo, s.tasks[i].undo) {
            case ("open", .none): s.tasks[i].undo = .available
            case ("none", .available): s.tasks[i].undo = .none
            default: break
            }
        case .taskClosed(let e):
            let i = taskIndex(&s, e.runId)
            s.tasks[i].closed = e.why
            if s.tasks[i].undo == .available { s.tasks[i].undo = .expired(e.why) }
        case .taskUndo(let e):
            let i = taskIndex(&s, e.runId)
            s.tasks[i].undo = .done(undone: e.undone ?? 0, total: e.total ?? 0, refused: e.refused)
        case .steer(let e):
            let i = taskIndex(&s, e.runId)
            s.tasks[i].steersSent.append(e.text)
        case .retry(let e):
            for i in s.messages.indices where s.messages[i].role == "assistant" && s.messages[i].replyTo == e.replyTo {
                s.messages[i].retracted = true
            }
        case .queue(let q):
            s.queue = q.items
        case .unknown(let k, _):
            s.unknownKinds.insert(k)
        default:
            break
        }
    }

    /// Streaming assembly, by offset in UTF-16 code units (the harness counts a JavaScript string's length).
    private static func delta(_ s: inout SessionState, _ d: SessionDelta, t: Double?) {
        let i: Int
        if let found = s.messages.firstIndex(where: { $0.id == d.msgId }) {
            i = found
        } else {
            if s.droppedMessages.contains(d.msgId) { return }
            dropEmptyStreaming(&s)
            s.messages.append(ChatMessage(id: d.msgId, role: "assistant", text: "", streaming: true, t: t))
            s.timeline.append(.message(d.msgId))
            i = s.messages.count - 1
        }
        guard s.messages[i].streaming else { return }   // the final message is in: deltas replayed after it change nothing
        let cur = Array(s.messages[i].text.utf16)
        let add = Array(d.text.utf16)
        let off = d.offset ?? cur.count
        if off > cur.count { s.messages[i].gap = true; return }   // a gap: wait for the final text (or a full offset-0 delta)
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
    private static func dropStreaming(_ s: inout SessionState, _ id: String) {
        guard let m = s.message(id), m.streaming else { return }
        s.droppedMessages.insert(id)
        s.messages.removeAll { $0.id == id }
        s.timeline.removeAll { $0 == .message(id) }
    }

    private static func taskIndex(_ s: inout SessionState, _ runId: String) -> Int {
        if let i = s.tasks.firstIndex(where: { $0.runId == runId }) { return i }
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
            if e.stepId == nil, let old = e.status { st.status = StepState.Status(rawValue: old) ?? .ok }   // an older harness: one line per step
            if let i = task.steps.firstIndex(where: { $0.id == id }) { task.steps[i] = st } else { task.steps.append(st) }
        case .stepResult(let r):
            guard let i = task.steps.firstIndex(where: { $0.id == r.stepId }) else { return }
            task.steps[i].status = StepState.Status(rawValue: r.status) ?? .error
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
            if let old = task.openCardId, old != a.askId { setOutcome(&task, old, .void("replaced")) }
            if !task.cards.contains(where: { $0.askId == a.askId }) {
                task.cards.append(CardState(askId: a.askId, card: a.card, askedAt: t))
            }
            if task.running { task.openCardId = a.askId }
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
        case .verify(let v):
            task.verify = v
            task.lookOnly = v.verdict == "unknown" && v.missingKind == "evidence"
        case .changes(let c):
            task.changes = c
        case .answerGiven(let a):
            task.answer = a.text
        case .taskDone(let d):
            task.done = d
            task.doneAt = t
            if let c = d.changes {
                var merged = c
                if merged.createdWindows == nil { merged.createdWindows = task.changes.createdWindows }
                task.changes = merged
            }
            if let a = d.answer { task.answer = a }
            closeOpenParts(&task, reason: d.reason)
            if task.undo == .none, d.resultCard?.options.contains(where: { $0.kind == "undo" }) == true { task.undo = .available }
        case .resultResponse(let r):
            task.resultResponse = r
            if let undone = r.undone { task.undo = .done(undone: undone, total: r.total ?? undone, refused: r.refused) }
            else if r.picked == "undo" { task.undo = .done(undone: 0, total: r.total ?? 0, refused: r.refused) }
            else if task.undo == .available { task.undo = .declined }
        case .modelCall, .judge, .unknown:
            break
        default:
            break
        }
    }

    private static func setOutcome(_ task: inout TaskState, _ askId: String, _ outcome: CardState.Outcome) {
        if let i = task.cards.firstIndex(where: { $0.askId == askId }), task.cards[i].outcome == .open { task.cards[i].outcome = outcome }
        if task.openCardId == askId { task.openCardId = nil }
    }

    /// The task is over (task_done, or session.task_end without one): an open card can no longer be answered, the user is
    /// no longer waited for, steps with no result are closed — the one with the driver when the stop came is "unknown".
    private static func closeOpenParts(_ task: inout TaskState, reason: String) {
        if let id = task.openCardId { setOutcome(&task, id, .void("task_done")) }
        task.userActive = false
        task.lookOnly = false
        task.stopping = false
        task.preparing = false
        let running = task.steps.indices.filter { task.steps[$0].status == .running }
        for i in running {
            task.steps[i].status = (reason == TaskDone.stepInProgressReason && i == running.last) ? .unknown : .notFinished
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
    /// what the user needs to see.
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
                return m.role == "assistant" ? .done(at: m.t, stopped: m.stopped) : .idle
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
            let locked = st == "environment" && (t.done?.reason ?? t.end?.reason) == TaskDone.lockedReason
            newest = (seq, locked ? .locked : .error(st))
        }
        if let e = s.errors.last, e.seq > (newest?.seq ?? 0) { newest = (e.seq, .error(e.error.code)) }
        guard let n = newest, n.seq > s.seenSeq else { return nil }
        return n.status
    }
}
