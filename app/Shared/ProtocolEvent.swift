// The harness's events as the main app reads them: the session process's own (`session.*`, docs/protocol.md
// 「会话（第 1 版）」) and the executor's, forwarded with `session_id` (section 2, src/protocol/events.ts).
//
// One line of JSON → `ProtocolLine` (the envelope: seq, t, run_id, session_id) holding a `ProtocolEvent`. Reading is
// lenient, as the compatibility rule asks (docs/protocol.md section 4): extra fields are ignored, a missing field takes
// its empty value, and a kind this app does not know — or a known kind whose fields cannot be read — is kept as
// `.unknown(kind, raw)` rather than dropped or thrown, so one odd line never ends the stream.
//
// No UI and no process here: tests/DecisionTests.swift feeds recorded streams (tests/fixtures/session/*.jsonl).

import Foundation

// MARK: - Raw JSON

/// Any JSON value, kept as it came (an unknown event's body, a field the app does not model).
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Deeper than this, a value is kept as null: a line nested hundreds deep must not exhaust a background thread's
    /// stack (the watch runs on one); nothing the app reads is nested near this deep.
    static let maxDepth = 64

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if decoder.codingPath.count > Self.maxDepth { self = .null; return }
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var int: Int? { if case .number(let n) = self { return Int(exactly: n) }; return nil }
}

// MARK: - Lenient fields

/// A field's empty value when it is missing, null or of another type: the reader never fails on one field.
protocol EmptyValue { associatedtype Value: Codable & Equatable; static var empty: Value { get } }
enum EmptyString: EmptyValue { static var empty: String { "" } }
enum EmptyFalse: EmptyValue { static var empty: Bool { false } }
enum EmptyZero: EmptyValue { static var empty: Double { 0 } }
enum EmptyList<T: Codable & Equatable>: EmptyValue { static var empty: [T] { [] } }

@propertyWrapper
struct Lenient<E: EmptyValue>: Codable, Equatable {
    var wrappedValue: E.Value
    init(wrappedValue: E.Value) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        wrappedValue = (try? decoder.singleValueContainer().decode(E.Value.self)) ?? E.empty
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    /// A missing key is the empty value (the synthesized init asks for every non-optional key).
    func decode<E>(_ type: Lenient<E>.Type, forKey key: Key) throws -> Lenient<E> {
        (try? decodeIfPresent(type, forKey: key)) ?? Lenient(wrappedValue: E.empty)
    }
}

typealias LStr = Lenient<EmptyString>
typealias LBool = Lenient<EmptyFalse>
typealias LNum = Lenient<EmptyZero>
typealias LList<T: Codable & Equatable> = Lenient<EmptyList<T>>

// MARK: - Cards (src/protocol/cards.ts)

struct CardOption: Codable, Equatable {
    @LStr var kind: String = ""
    @LStr var text: String = ""
}

/// A plan card in fields (`ask.card.plan`): per step its purpose, class, the objects it touches and the sites it opens.
struct PlanFacts: Codable, Equatable {
    struct Object: Codable, Equatable {
        @LStr var ref: String = ""
        @LStr var label: String = ""
        @LStr var owner: String = ""
        @LList<String> var marks: [String] = []
    }
    struct Site: Codable, Equatable {
        @LStr var host: String = ""
        var sends: String?
        @LBool var asksEach: Bool = false
        enum CodingKeys: String, CodingKey { case host, sends, asksEach = "asks_each" }
    }
    struct Step: Codable, Equatable {
        @LStr var purpose: String = ""
        @LStr var `class`: String = ""
        @LList<Object> var objects: [Object] = []
        @LList<Site> var sites: [Site] = []
    }
    struct Foreground: Codable, Equatable {
        @LList<String> var apps: [String] = []
        @LStr var note: String = ""
    }
    @LList<Step> var steps: [Step] = []
    var foreground: Foreground?
}

/// A consent card for one action in fields (`ask.card.consent`).
struct ConsentFacts: Codable, Equatable {
    struct Outgoing: Codable, Equatable {
        @LStr var kind: String = ""
        @LStr var label: String = ""
        @LStr var value: String = ""
    }
    @LStr var action: String = ""
    @LStr var actionText: String = ""
    var target: String?
    @LStr var object: String = ""
    @LStr var objectLabel: String = ""
    @LStr var consequence: String = ""
    @LList<Outgoing> var outgoing: [Outgoing] = []
    var site: String?
    enum CodingKeys: String, CodingKey {
        case action, actionText = "action_text", target, object, objectLabel = "object_label", consequence, outgoing, site
    }
}

struct CardEvent: Codable, Equatable {
    @LStr var kind: String = ""
    @LStr var text: String = ""
    @LList<CardOption> var options: [CardOption] = []
    @LBool var freeText: Bool = false
    @LBool var blocking: Bool = false
    var plan: PlanFacts?
    var consent: ConsentFacts?
    enum CodingKeys: String, CodingKey { case kind, text, options, freeText = "free_text", blocking, plan, consent }
}

// MARK: - Session events (docs/protocol.md 「会话（第 1 版）」)

struct SessionStart: Codable, Equatable {
    struct Proto: Codable, Equatable { var session: Int? }
    var protocolVersion: Proto?
    /// The last stored seq on disk when this process started: its own stored lines come after it.
    var lastSeq: Int?
    @LBool var resumed: Bool = false
    /// The process's pid, added by the helper as it forwards the line (deskmind#105); nil from a helper without it.
    var pid: Int?
    enum CodingKeys: String, CodingKey { case protocolVersion = "protocol", lastSeq = "last_seq", resumed, pid }
    init(protocolVersion: Proto? = nil, lastSeq: Int? = nil, resumed: Bool = false, pid: Int? = nil) {
        self.protocolVersion = protocolVersion; self.lastSeq = lastSeq; self.resumed = resumed; self.pid = pid
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = (try? c.decodeIfPresent(Proto.self, forKey: .protocolVersion)) ?? nil
        lastSeq = (try? c.decodeIfPresent(Int.self, forKey: .lastSeq)) ?? nil
        resumed = (try? c.decodeIfPresent(Bool.self, forKey: .resumed)) ?? false
        pid = (try? c.decodeIfPresent(Int.self, forKey: .pid)) ?? nil
    }
}

struct SessionMessage: Codable, Equatable {
    @LStr var msgId: String = ""
    @LStr var role: String = "" // user | assistant
    @LStr var text: String = ""
    var replyTo: String?
    var model: String?
    var stopped: Bool?
    var truncated: Bool?
    var via: String?                // cua | queue
    enum CodingKeys: String, CodingKey { case msgId = "msg_id", role, text, replyTo = "reply_to", model, stopped, truncated, via }
}

struct SessionDelta: Codable, Equatable {
    @LStr var msgId: String = ""
    @LStr var text: String = ""
    /// Where `text` starts in the whole reply, in UTF-16 code units (a JavaScript string's length).
    var offset: Int?
    enum CodingKeys: String, CodingKey { case msgId = "msg_id", text, offset }
}

struct SessionErrorEvent: Codable, Equatable {
    @LStr var code: String = ""
    @LStr var text: String = ""
    var msgId: String?
    var replyTo: String?
    var control: String?
    enum CodingKeys: String, CodingKey { case code, text, msgId = "msg_id", replyTo = "reply_to", control }
}

struct SessionTaskEvent: Codable, Equatable {
    @LStr var msgId: String = ""
    @LStr var runId: String = ""
    @LStr var raw: String = ""
    var goal: String?
    @LStr var by: String = "" // slash | model
    var replyTo: String?
    enum CodingKeys: String, CodingKey { case msgId = "msg_id", runId = "run_id", raw, goal, by, replyTo = "reply_to" }
}

struct Changes: Codable, Equatable {
    @LList<String> var created: [String] = []
    @LList<String> var modified: [String] = []
    @LList<String> var deleted: [String] = []
    @LList<String> var external: [String] = []
    @LList<String> var unconfirmed: [String] = []
    var createdWindows: [String]?
    /// session.task_end only: how many more per kind than the 20 listed.
    var more: JSONValue?
    enum CodingKeys: String, CodingKey { case created, modified, deleted, external, unconfirmed, createdWindows = "created_windows", more }
    var isEmpty: Bool { created.isEmpty && modified.isEmpty && deleted.isEmpty && external.isEmpty && unconfirmed.isEmpty && (createdWindows ?? []).isEmpty }
}

struct SessionTaskEnd: Codable, Equatable {
    @LStr var runId: String = ""
    @LStr var status: String = ""
    @LStr var summary: String = ""
    @LStr var undo: String = "" // open | none
    var reason: String?
    /// Why it ended, structured; nil for a plain failure or a normal end (and from a harness older than the field).
    var cause: TaskCause?
    var answer: String?
    var changes: Changes?
    var steers: [String]?
    enum CodingKeys: String, CodingKey { case runId = "run_id", status, summary, undo, reason, cause, answer, changes, steers }
}

struct SessionTaskClosed: Codable, Equatable {
    @LStr var runId: String = ""
    @LStr var why: String = "" // linger | new_task | session_end
    enum CodingKeys: String, CodingKey { case runId = "run_id", why }
}

struct SessionTaskUndo: Codable, Equatable {
    @LStr var runId: String = ""
    var undone: Int?
    var total: Int?
    var refused: String?
    enum CodingKeys: String, CodingKey { case runId = "run_id", undone, total, refused }
}

struct SessionSteer: Codable, Equatable {
    @LStr var runId: String = ""
    @LStr var text: String = ""
    enum CodingKeys: String, CodingKey { case runId = "run_id", text }
}

struct SessionRetry: Codable, Equatable {
    @LStr var replyTo: String = ""
    enum CodingKeys: String, CodingKey { case replyTo = "reply_to" }
}

struct QueueItem: Codable, Equatable {
    @LStr var id: String = ""
    @LStr var text: String = ""
    var held: Bool?
    var note: String?
}

struct SessionQueue: Codable, Equatable {
    @LList<QueueItem> var items: [QueueItem] = []
}

/// The helper's word that a session's process ended: {"kind":"helper.session_exit","session_id","code","pid"?,
/// "start_seq"?,"last_seq"?} (SessionHost, deskmind#105). `last_seq`: the last stored session seq the helper
/// forwarded from that process, so the runs it started (session.task seq <= it) are known to be gone whenever the line
/// comes; `start_seq`: the stored seq it began after (its session.start's last_seq) and `pid`: which process (matched
/// against a session.start's `pid` when the helper adds one). Not stored, no seq. Without them (an older helper, or the
/// app's own inference) the exit is taken for the latest process and what the app has seen of it.
struct HelperSessionExit: Codable, Equatable {
    var code: Int?
    var lastSeq: Int?
    var pid: Int?
    /// The stored seq the process began after (its session.start's last_seq).
    var startSeq: Int?
    enum CodingKeys: String, CodingKey { case code, lastSeq = "last_seq", pid, startSeq = "start_seq" }
    init(code: Int?, lastSeq: Int? = nil, pid: Int? = nil, startSeq: Int? = nil) {
        self.code = code; self.lastSeq = lastSeq; self.pid = pid; self.startSeq = startSeq
    }
    /// A field of another type (or out of range) is absent: the exit itself must not be lost.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = (try? c.decodeIfPresent(Int.self, forKey: .code)) ?? nil
        lastSeq = (try? c.decodeIfPresent(Int.self, forKey: .lastSeq)) ?? nil
        pid = (try? c.decodeIfPresent(Int.self, forKey: .pid)) ?? nil
        startSeq = (try? c.decodeIfPresent(Int.self, forKey: .startSeq)) ?? nil
    }
}

// MARK: - Executor events (docs/protocol.md section 2)

struct TaskStart: Codable, Equatable {
    @LStr var raw: String = ""
    var lang: String?
    var engine: String?
    var config: String?
    var scope: String?
}

struct PlanEvent: Codable, Equatable {
    struct Step: Codable, Equatable {
        @LStr var purpose: String = ""
        @LList<String> var objects: [String] = []
        @LStr var consequence: String = ""
    }
    @LList<Step> var steps: [Step] = []
}

struct StepTarget: Codable, Equatable {
    @LStr var id: String = ""
    @LStr var label: String = ""
    @LStr var role: String = ""
    /// [x, y, w, h] in its window, 0–1.
    var rectNorm: [Double]?
    /// [x, y, w, h] on screen, points.
    var frame: [Double]?
    enum CodingKeys: String, CodingKey { case id, label, role, rectNorm = "rect_norm", frame }
}

struct StepEvent: Codable, Equatable {
    @LStr var text: String = ""
    var consequence: String?
    var object: String?
    var status: String?
    var purpose: String?
    var stepId: String?
    var human: String?
    var planStep: Int?
    var target: StepTarget?
    enum CodingKeys: String, CodingKey { case text, consequence, object, status, purpose, stepId = "step_id", human, planStep = "plan_step", target }
}

struct Frame: Codable, Equatable {
    @LNum var x: Double = 0
    @LNum var y: Double = 0
    @LNum var w: Double = 0
    @LNum var h: Double = 0
}

struct StepResultEvent: Codable, Equatable {
    @LStr var stepId: String = ""
    @LStr var status: String = "" // ok | unverified | refused | stale | error
    var why: String?
    var executorStatus: String?
    var consequence: String?
    var shot: String?
    var shotPending: Bool?
    var targetFrame: Frame?
    var windowFrame: Frame?
    enum CodingKeys: String, CodingKey {
        case stepId = "step_id", status, why, executorStatus = "executor_status", consequence, shot, shotPending = "shot_pending",
             targetFrame = "target_frame", windowFrame = "window_frame"
    }
}

struct ShotReady: Codable, Equatable {
    @LStr var stepId: String = ""
    @LStr var shot: String = ""
    enum CodingKeys: String, CodingKey { case stepId = "step_id", shot }
}

struct AskEvent: Codable, Equatable {
    @LStr var askId: String = ""
    var card: CardEvent
    enum CodingKeys: String, CodingKey { case askId = "ask_id", card }
}

struct WaitingEvent: Codable, Equatable {
    var askId: String?
    enum CodingKeys: String, CodingKey { case askId = "ask_id" }
}

struct ResumedEvent: Codable, Equatable {
    var askId: String?
    var voided: String?
    /// Without ask_id: how the wait for the user ended — "" they paused, "stopped", "timed_out".
    var why: String?
    enum CodingKeys: String, CodingKey { case askId = "ask_id", voided, why }
}

struct AskVoid: Codable, Equatable {
    @LStr var askId: String = ""
    @LStr var why: String = "" // steer | stop | ended
    enum CodingKeys: String, CodingKey { case askId = "ask_id", why }
}

struct SteeredEvent: Codable, Equatable { @LStr var text: String = "" }

struct VerifyEvent: Codable, Equatable {
    @LStr var verdict: String = "" // pass | fail | unknown
    var by: String?
    @LStr var reason: String = ""
    var missingKind: String?        // action | evidence
    var judgeId: String?
    enum CodingKeys: String, CodingKey { case verdict, by, reason, missingKind = "missing_kind", judgeId = "judge_id" }
}

struct ConsentEvent: Codable, Equatable {
    @LStr var object: String = ""
    @LStr var consequence: String = ""
    @LStr var scope: String = ""
    var picked: String?
}

struct RefusedEvent: Codable, Equatable {
    @LStr var what: String = ""
    @LStr var why: String = ""
    @LStr var by: String = "" // user | executor
}

struct AnswerGiven: Codable, Equatable { @LStr var text: String = "" }

struct ModelCall: Codable, Equatable {
    @LStr var callId: String = ""
    @LStr var role: String = ""
    @LStr var model: String = ""
    @LStr var outcome: String = ""
    @LNum var tokensIn: Double = 0
    @LNum var tokensOut: Double = 0
    @LNum var costUsd: Double = 0
    @LNum var latencyMs: Double = 0
    var stepId: String?
    var judgeId: String?
    enum CodingKeys: String, CodingKey {
        case callId = "call_id", role, model, outcome, tokensIn = "tokens_in", tokensOut = "tokens_out", costUsd = "cost_usd",
             latencyMs = "latency_ms", stepId = "step_id", judgeId = "judge_id"
    }
}

struct JudgeEvent: Codable, Equatable {
    @LStr var judgeId: String = ""
    @LStr var question: String = ""
    var answer: String?
    var by: String?
    var stepId: String?
    enum CodingKeys: String, CodingKey { case judgeId = "judge_id", question, answer, by, stepId = "step_id" }
}

struct Usage: Codable, Equatable {
    @LNum var calls: Double = 0
    @LNum var tokensIn: Double = 0
    @LNum var tokensOut: Double = 0
    @LNum var costUsd: Double = 0
    enum CodingKeys: String, CodingKey { case calls, tokensIn = "tokens_in", tokensOut = "tokens_out", costUsd = "cost_usd" }
}

/// Why a task ended, as task_done's and session.task_end's optional `cause` (harness ed96440, docs/protocol.md): the
/// app reads these, never the reason's words. Absent: a plain failure or a normal end. A value this app does not know
/// reads as absent (the harness may add some), never as a line that could not be read.
enum TaskCause: String, Codable, Equatable {
    case screenLocked = "screen_locked"
    /// A stop came while an action was with the driver: whether that step took effect is not known.
    case lastStepUnknown = "last_step_unknown"
    case userStopped = "user_stopped"
}

extension KeyedDecodingContainer {
    /// `cause`: an unknown value, or one of another type, is nil.
    func decodeIfPresent(_ type: TaskCause.Type, forKey key: Key) throws -> TaskCause? {
        ((try? decodeIfPresent(String.self, forKey: key)) ?? nil).flatMap(TaskCause.init(rawValue:))
    }
}

struct TaskDone: Codable, Equatable {
    @LStr var status: String = ""
    @LStr var reason: String = ""
    @LStr var summary: String = ""
    /// Why it ended, structured; nil for a plain failure or a normal end (and from a harness older than the field).
    var cause: TaskCause?
    var resultCard: CardEvent?
    var answer: String?
    var changes: Changes?
    var usage: Usage?
    var usageIncomplete: Bool?
    enum CodingKeys: String, CodingKey {
        case status, reason, summary, cause, resultCard = "result_card", answer, changes, usage, usageIncomplete = "usage_incomplete"
    }
}

struct ResultResponse: Codable, Equatable {
    var picked: String?
    var text: String?
    @LStr var effect: String = ""
    var undone: Int?
    var total: Int?
    var refused: String?
}

// MARK: - The event

enum ProtocolEvent: Equatable {
    // the session process
    case sessionStart(SessionStart)
    case message(SessionMessage)
    case delta(SessionDelta)
    case sessionError(SessionErrorEvent)
    case task(SessionTaskEvent)
    case taskEnd(SessionTaskEnd)
    case taskClosed(SessionTaskClosed)
    case taskUndo(SessionTaskUndo)
    case steer(SessionSteer)
    case retry(SessionRetry)
    case queue(SessionQueue)
    // the helper, about a session
    case sessionExit(HelperSessionExit)
    // the executor, forwarded
    case start(TaskStart)
    case preparing
    case plan(PlanEvent)
    case step(StepEvent)
    case stepResult(StepResultEvent)
    case shotReady(ShotReady)
    case ask(AskEvent)
    case waiting(WaitingEvent)
    case resumed(ResumedEvent)
    case askVoid(AskVoid)
    case steered(SteeredEvent)
    case verify(VerifyEvent)
    case changes(Changes)
    case consent(ConsentEvent)
    case refused(RefusedEvent)
    case answerGiven(AnswerGiven)
    case modelCall(ModelCall)
    case judge(JudgeEvent)
    case taskDone(TaskDone)
    case resultResponse(ResultResponse)
    /// A kind this app does not know, or a known kind whose fields could not be read: the whole line, as it came.
    case unknown(kind: String, raw: JSONValue)

    var kind: String {
        switch self {
        case .sessionStart: return "session.start"
        case .message: return "session.message"
        case .delta: return "session.delta"
        case .sessionError: return "session.error"
        case .task: return "session.task"
        case .taskEnd: return "session.task_end"
        case .taskClosed: return "session.task_closed"
        case .taskUndo: return "session.task_undo"
        case .steer: return "session.steer"
        case .retry: return "session.retry"
        case .queue: return "session.queue"
        case .sessionExit: return "helper.session_exit"
        case .start: return "start"
        case .preparing: return "preparing"
        case .plan: return "plan"
        case .step: return "step"
        case .stepResult: return "step_result"
        case .shotReady: return "shot_ready"
        case .ask: return "ask"
        case .waiting: return "waiting"
        case .resumed: return "resumed"
        case .askVoid: return "ask_void"
        case .steered: return "steered"
        case .verify: return "verify"
        case .changes: return "changes"
        case .consent: return "consent"
        case .refused: return "refused"
        case .answerGiven: return "answer_given"
        case .modelCall: return "model_call"
        case .judge: return "judge"
        case .taskDone: return "task_done"
        case .resultResponse: return "result_response"
        case .unknown(let k, _): return k
        }
    }

    /// The session's own events (`session.*`, and the helper's word that its process ended); everything else is an
    /// executor's, forwarded.
    var isSessionEvent: Bool { kind.hasPrefix("session.") || kind == "helper.session_exit" }
}

extension ProtocolEvent: Codable {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let raw = try JSONValue(from: decoder)
        let kind = raw["kind"]?.string ?? ""
        func read<T: Decodable>(_ make: (T) -> ProtocolEvent) -> ProtocolEvent {
            (try? T(from: decoder)).map(make) ?? .unknown(kind: kind, raw: raw)
        }
        switch kind {
        case "session.start": self = read(ProtocolEvent.sessionStart)
        case "session.message": self = read(ProtocolEvent.message)
        case "session.delta": self = read(ProtocolEvent.delta)
        case "session.error": self = read(ProtocolEvent.sessionError)
        case "session.task": self = read(ProtocolEvent.task)
        case "session.task_end": self = read(ProtocolEvent.taskEnd)
        case "session.task_closed": self = read(ProtocolEvent.taskClosed)
        case "session.task_undo": self = read(ProtocolEvent.taskUndo)
        case "session.steer": self = read(ProtocolEvent.steer)
        case "session.retry": self = read(ProtocolEvent.retry)
        case "session.queue": self = read(ProtocolEvent.queue)
        case "helper.session_exit": self = read(ProtocolEvent.sessionExit)
        case "start": self = read(ProtocolEvent.start)
        case "preparing": self = .preparing
        case "plan": self = read(ProtocolEvent.plan)
        case "step": self = read(ProtocolEvent.step)
        case "step_result": self = read(ProtocolEvent.stepResult)
        case "shot_ready": self = read(ProtocolEvent.shotReady)
        case "ask": self = read(ProtocolEvent.ask)
        case "waiting": self = read(ProtocolEvent.waiting)
        case "resumed": self = read(ProtocolEvent.resumed)
        case "ask_void": self = read(ProtocolEvent.askVoid)
        case "steered": self = read(ProtocolEvent.steered)
        case "verify": self = read(ProtocolEvent.verify)
        case "changes": self = read(ProtocolEvent.changes)
        case "consent": self = read(ProtocolEvent.consent)
        case "refused": self = read(ProtocolEvent.refused)
        case "answer_given": self = read(ProtocolEvent.answerGiven)
        case "model_call": self = read(ProtocolEvent.modelCall)
        case "judge": self = read(ProtocolEvent.judge)
        case "task_done": self = read(ProtocolEvent.taskDone)
        case "result_response": self = read(ProtocolEvent.resultResponse)
        default: self = .unknown(kind: kind, raw: raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .unknown(_, let raw): try raw.encode(to: encoder); return
        case .sessionStart(let v): try v.encode(to: encoder)
        case .message(let v): try v.encode(to: encoder)
        case .delta(let v): try v.encode(to: encoder)
        case .sessionError(let v): try v.encode(to: encoder)
        case .task(let v): try v.encode(to: encoder)
        case .taskEnd(let v): try v.encode(to: encoder)
        case .taskClosed(let v): try v.encode(to: encoder)
        case .taskUndo(let v): try v.encode(to: encoder)
        case .steer(let v): try v.encode(to: encoder)
        case .retry(let v): try v.encode(to: encoder)
        case .queue(let v): try v.encode(to: encoder)
        case .sessionExit(let v): try v.encode(to: encoder)
        case .start(let v): try v.encode(to: encoder)
        case .preparing: break
        case .plan(let v): try v.encode(to: encoder)
        case .step(let v): try v.encode(to: encoder)
        case .stepResult(let v): try v.encode(to: encoder)
        case .shotReady(let v): try v.encode(to: encoder)
        case .ask(let v): try v.encode(to: encoder)
        case .waiting(let v): try v.encode(to: encoder)
        case .resumed(let v): try v.encode(to: encoder)
        case .askVoid(let v): try v.encode(to: encoder)
        case .steered(let v): try v.encode(to: encoder)
        case .verify(let v): try v.encode(to: encoder)
        case .changes(let v): try v.encode(to: encoder)
        case .consent(let v): try v.encode(to: encoder)
        case .refused(let v): try v.encode(to: encoder)
        case .answerGiven(let v): try v.encode(to: encoder)
        case .modelCall(let v): try v.encode(to: encoder)
        case .judge(let v): try v.encode(to: encoder)
        case .taskDone(let v): try v.encode(to: encoder)
        case .resultResponse(let v): try v.encode(to: encoder)
        }
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(kind, forKey: Key("kind"))
    }
}

/// One line as the session process writes it: the envelope and the event.
/// - `seq`: a stored session event's number (from 1, gapless), or an executor event's number within its run; absent on
///   what is not stored (session.start, delta, queue, most errors).
/// - `runId`: the executor's events, and the session's task events through their payload.
struct ProtocolLine: Codable, Equatable {
    var seq: Int?
    var t: Double?
    var runId: String?
    var sessionId: String?
    var event: ProtocolEvent

    enum CodingKeys: String, CodingKey { case seq, t, runId = "run_id", sessionId = "session_id" }

    init(seq: Int? = nil, t: Double? = nil, runId: String? = nil, sessionId: String? = nil, event: ProtocolEvent) {
        self.seq = seq; self.t = t; self.runId = runId; self.sessionId = sessionId; self.event = event
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try? c.decodeIfPresent(Int.self, forKey: .seq)
        t = try? c.decodeIfPresent(Double.self, forKey: .t)
        runId = try? c.decodeIfPresent(String.self, forKey: .runId)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        event = try ProtocolEvent(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try event.encode(to: encoder)
        if case .unknown = event { return }   // the raw line already holds its envelope
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(seq, forKey: .seq)
        try c.encodeIfPresent(t, forKey: .t)
        try c.encodeIfPresent(runId, forKey: .runId)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
    }

    /// One line of the stream; nil when it is not a JSON object (the session ignores such lines too).
    static func parse(_ line: String) -> ProtocolLine? { parse(Data(line.utf8)) }
    static func parse(_ data: Data) -> ProtocolLine? {
        guard let first = data.first(where: { !($0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D) }), first == UInt8(ascii: "{"),
              DeskMindIPC.nestingWithin(data, limit: DeskMindIPC.maxLineDepth) else { return nil }
        return try? JSONDecoder().decode(ProtocolLine.self, from: data)
    }
    /// A line the helper already parsed (JSONSerialization).
    static func parse(object: [String: Any]) -> ProtocolLine? {
        guard JSONSerialization.isValidJSONObject(object), let d = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return parse(d)
    }
}
