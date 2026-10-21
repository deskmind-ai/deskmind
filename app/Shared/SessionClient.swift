// The main app's side of chat sessions: it asks the helper (DeskMind Hands) to open, feed and end session processes,
// and folds what comes back into each session's state (SessionReducer). Thin on purpose: the helper owns the processes,
// the reducer owns the meaning; this only moves lines and keeps the states.
//
// Helper ops (built in M1 S1, same names): session.open, session.send, session.end, sessions.watch, sessions.list. Their
// request shapes are all in `SessionClient.Request`, so a change on the helper side is a change in one place.

import Foundation

/// How the client reaches the helper: one request, one reply; or one request and a stream of lines. The real one is the
/// helper's socket (`HelperSessionTransport`); tests use a mock.
protocol SessionTransport: AnyObject {
    func request(_ body: [String: Any]) -> [String: Any]?
    /// Blocks until the helper closes the stream; false when the helper is not listening.
    func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Void) -> Bool
}

final class HelperSessionTransport: SessionTransport {
    func request(_ body: [String: Any]) -> [String: Any]? { DeskMindIPC.request(body) }
    func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Void) -> Bool { DeskMindIPC.stream(body, onLine: onLine) }
}

/// What the user does in a session, as the session's control lines (docs/protocol.md 「会话（第 1 版）」, 控制).
enum SessionControl: Equatable {
    case say(String)
    case cua(String, scope: String? = nil)
    case stop(runId: String? = nil)
    case steer(String, runId: String? = nil)
    case answer(CardAnswer)
    case retry
    case queueEdit(id: String, text: String)
    case queueCancel(id: String)
    case queueSendNow(id: String)
    case attach(afterSeq: Int, runId: String? = nil)

    var line: [String: Any] {
        switch self {
        case .say(let t): return ["type": "say", "text": t]
        case .cua(let t, let scope): return ["type": "cua", "text": t].merging(scope.map { ["scope": $0] } ?? [:]) { a, _ in a }
        case .stop(let r): return ["type": "stop"].merging(r.map { ["run_id": $0] } ?? [:]) { a, _ in a }
        case .steer(let t, let r): return ["type": "steer", "text": t].merging(r.map { ["run_id": $0] } ?? [:]) { a, _ in a }
        case .answer(let a): return a.control
        case .retry: return ["type": "retry"]
        case .queueEdit(let id, let t): return ["type": "queue_edit", "id": id, "text": t]
        case .queueCancel(let id): return ["type": "queue_cancel", "id": id]
        case .queueSendNow(let id): return ["type": "queue_send_now", "id": id]
        case .attach(let n, let r): return ["type": "attach", "after_seq": n].merging(r.map { ["run_id": $0] } ?? [:]) { a, _ in a }
        }
    }

    /// Typing that the session refuses while a card waits (card_open): the composer is disabled then, and the client
    /// does not send it either.
    var isTyping: Bool {
        switch self { case .say, .steer, .queueSendNow: return true; default: return false }
    }
}

/// A row of the session list (`harness.mjs sessions list`).
struct SessionSummary: Equatable {
    var sessionId: String
    var title: String
    var updatedAt: Double?
    var lastMessage: (role: String, text: String)?

    static func == (a: SessionSummary, b: SessionSummary) -> Bool {
        a.sessionId == b.sessionId && a.title == b.title && a.updatedAt == b.updatedAt
            && a.lastMessage?.role == b.lastMessage?.role && a.lastMessage?.text == b.lastMessage?.text
    }

    init(sessionId: String, title: String, updatedAt: Double?, lastMessage: (role: String, text: String)?) {
        self.sessionId = sessionId; self.title = title; self.updatedAt = updatedAt; self.lastMessage = lastMessage
    }

    init?(_ o: [String: Any]) {
        guard let id = o["session_id"] as? String else { return nil }
        let last = o["last_message"] as? [String: Any]
        self.init(sessionId: id, title: o["title"] as? String ?? "", updatedAt: (o["updated_at"] as? NSNumber)?.doubleValue,
                  lastMessage: last.map { ($0["role"] as? String ?? "", $0["text"] as? String ?? "") })
    }
}

final class SessionClient {
    enum Op {
        static let open = "session.open"
        static let send = "session.send"
        static let end = "session.end"
        static let watch = "sessions.watch"
        static let list = "sessions.list"
    }

    enum SendResult: Equatable {
        case sent
        case refused(String)        // not sent: why (the reason is for logs, not for the user)
        case unavailable            // the helper did not answer, or said no
    }

    /// The request bodies, in one place (the helper's ops, S1).
    enum Request {
        static func open(sessionId: String?, config: String?, lang: String?) -> [String: Any] {
            var b: [String: Any] = ["op": Op.open]
            if let s = sessionId { b["session_id"] = s }
            if let c = config { b["config"] = c }
            if let l = lang { b["lang"] = l }
            return b
        }
        static func send(sessionId: String, line: [String: Any]) -> [String: Any] { ["op": Op.send, "session_id": sessionId, "line": line] }
        static func end(sessionId: String) -> [String: Any] { ["op": Op.end, "session_id": sessionId] }
        static func list() -> [String: Any] { ["op": Op.list] }
        /// `after`: per session the last stored seq the app has, and per run the last executor seq: the helper replays
        /// what came after (attach), then streams.
        static func watch(after: [String: Int], runs: [String: Int]) -> [String: Any] { ["op": Op.watch, "after": after, "runs": runs] }
    }

    private let transport: SessionTransport
    private let lock = NSLock()
    private var states: [String: SessionState] = [:]
    /// Called after a line changed a session's state (on the thread that fed it).
    var onChange: ((String, SessionState) -> Void)?

    init(transport: SessionTransport = HelperSessionTransport()) {
        self.transport = transport
    }

    func state(_ sessionId: String) -> SessionState {
        lock.lock(); defer { lock.unlock() }
        return states[sessionId] ?? SessionState(sessionId: sessionId)
    }

    var sessionIds: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(states.keys)
    }

    // MARK: ops

    func list() -> [SessionSummary]? {
        guard let r = transport.request(Request.list()), r["ok"] as? Bool != false else { return nil }
        return (r["sessions"] as? [[String: Any]])?.compactMap(SessionSummary.init)
    }

    /// Opens a session (a new one when `sessionId` is nil); its id, or nil when the helper could not.
    func open(sessionId: String? = nil, config: String? = nil, lang: String? = nil) -> String? {
        guard let r = transport.request(Request.open(sessionId: sessionId, config: config, lang: lang)), r["ok"] as? Bool != false,
              let id = r["session_id"] as? String ?? sessionId else { return nil }
        lock.lock()
        if states[id] == nil { states[id] = SessionState(sessionId: id) }
        lock.unlock()
        return id
    }

    func send(_ control: SessionControl, to sessionId: String) -> SendResult {
        let s = state(sessionId)
        if control.isTyping && !s.composerEnabled { return .refused("card_open") }
        if case .answer(let a) = control, let why = Self.refusal(a, in: s) { return .refused(why) }
        guard let r = transport.request(Request.send(sessionId: sessionId, line: control.line)), r["ok"] as? Bool != false else { return .unavailable }
        return .sent
    }

    /// Answers a card (or the result card): sent only if that card can still be answered.
    func answer(_ a: CardAnswer, in sessionId: String) -> SendResult { send(.answer(a), to: sessionId) }

    func end(_ sessionId: String) -> Bool {
        guard let r = transport.request(Request.end(sessionId: sessionId)) else { return false }
        return r["ok"] as? Bool != false
    }

    /// Streams every session's lines until the helper closes the stream (call it off the main thread); false when the
    /// helper is not listening. Reconnecting is calling it again: it says what the app already has.
    @discardableResult
    func watch() -> Bool {
        let (after, runs) = cursor()
        return transport.stream(Request.watch(after: after, runs: runs)) { [weak self] obj in self?.feed(obj) }
    }

    /// What the app has: per session the last stored seq, per run the last executor seq.
    func cursor() -> (after: [String: Int], runs: [String: Int]) {
        lock.lock(); defer { lock.unlock() }
        var after: [String: Int] = [:], runs: [String: Int] = [:]
        for (id, s) in states {
            after[id] = s.lastSeq
            for t in s.tasks { runs[t.runId] = t.lastSeq }
        }
        return (after, runs)
    }

    // MARK: feeding

    /// One line from the helper. Lines without a session_id are not a session's (the helper's own replies) and are left.
    func feed(_ obj: [String: Any]) {
        guard let line = ProtocolLine.parse(object: obj) else { return }
        feed(line)
    }

    func feed(_ line: ProtocolLine) {
        guard let id = line.sessionId else { return }
        lock.lock()
        let before = states[id] ?? SessionState(sessionId: id)
        let after = SessionReducer.reduce(before, line)
        states[id] = after
        lock.unlock()
        if after != before { onChange?(id, after) }
    }

    /// The user opened this session: its error dot clears.
    func markSeen(_ sessionId: String) {
        lock.lock()
        var s = states[sessionId] ?? SessionState(sessionId: sessionId)
        s.markSeen()
        states[sessionId] = s
        lock.unlock()
        onChange?(sessionId, s)
    }

    /// Why an answer must not be sent, or nil: a card answer goes only to the card that is open in that run (a click on
    /// a card that was voided, answered or replaced must never answer the open one, #103); a result-card answer only
    /// while the result card is still answerable (its executor lingers and it was not answered yet).
    static func refusal(_ a: CardAnswer, in s: SessionState) -> String? {
        guard let task = s.task(a.runId) else { return "no such task" }
        if let askId = a.askId {
            guard let open = task.openCard else { return "no card is open" }
            if open.askId != askId { return "stale card: \(askId) is not the open card \(open.askId)" }
            return nil
        }
        guard task.resultCard != nil else { return "no result card" }
        if task.closed != nil { return "the result card is closed" }
        if task.resultResponse != nil { return "the result card was answered" }
        return nil
    }
}
