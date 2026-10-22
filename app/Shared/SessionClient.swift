// The main app's side of chat sessions: it asks the helper (DeskMind Hands) to open, feed and end session processes,
// and folds what comes back into each session's state (SessionReducer). Thin on purpose: the helper owns the processes,
// the reducer owns the meaning; this only moves lines and keeps the states.
//
// Helper ops (built in M1 S1, same names): session.open, session.send, session.end, sessions.watch, sessions.list. Their
// request shapes are all in `SessionClient.Request`, so a change on the helper side is a change in one place.
//
// The ordering contract with the helper (sessions.watch, deskmind#105 SessionHost): per stream — a session's stored
// events, and each run's executor events, each numbered by `seq` contiguously from 1 — the helper sends the replay after
// the cursor the app named first, then the live lines, contiguous: no seq skipped, none out of order, within a stream
// (streams interleave freely). The app holds to it without trusting it: the reducer applies only the next seq of each
// stream, drops what it has, and holds back a line past a gap. A replay to a new watcher has been seen out of order
// (a run's 3…8 before its 1, 2: deskmind#105 review), so a gap is given `gapGrace` to fill on the same stream; one that
// stays past it ends the watch, and this client watches again from its contiguous cursors (`watch`), so the helper's
// replay fills it.
//
// A session whose process ended without the app asking (helper.session_exit, or missing from helper.watching's `open`
// though this client opened it) is opened again (session.open with its id) on the next send to it, and — if this client
// opened it — on the next watch. A session the app ended (`end`) is not.

import Foundation

/// How the client reaches the helper: one request, one reply; or one request and a stream of lines. The real one is the
/// helper's socket (`HelperSessionTransport`); tests use a mock.
protocol SessionTransport: AnyObject {
    func request(_ body: [String: Any]) -> [String: Any]?
    /// Blocks until the helper closes the stream, or `onLine` or `onIdle` returns false (the app ends it); false when
    /// the helper is not listening. `onIdle` is asked now and then while nothing comes (`SessionClient.idleTick`).
    func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool
}

final class HelperSessionTransport: SessionTransport {
    func request(_ body: [String: Any]) -> [String: Any]? { DeskMindIPC.request(body) }
    func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool {
        DeskMindIPC.streamWhile(body, idle: SessionClient.idleTick, onIdle: onIdle, onLine)
    }
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
    /// What each session was opened with, to open it again the same way after its process ended.
    private var opened: [String: (config: String?, lang: String?)] = [:]
    /// Sessions the app ended (`end`): their process's exit is expected, and they are not opened again by themselves.
    private var endedByApp: Set<String> = []
    /// The clock the gap grace is measured by (tests set their own).
    var now: () -> Date = Date.init
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
        states[id]?.exited = nil
        opened[id] = (config, lang)
        endedByApp.remove(id)
        lock.unlock()
        return id
    }

    /// Opens a session again whose process ended without the app asking, as it was opened (a session this client did
    /// not open — one from an earlier launch — with the helper's defaults, which resume its stored settings); true when
    /// it is open, or did not end. `onlyOpenedHere`: only a session this client opened (a watch does not bring back
    /// sessions it merely saw).
    @discardableResult
    func reopenIfExited(_ sessionId: String, onlyOpenedHere: Bool = false) -> Bool {
        lock.lock()
        let exited = states[sessionId]?.exited != nil
        let how = opened[sessionId]
        let ended = endedByApp.contains(sessionId)
        lock.unlock()
        guard exited else { return true }
        if ended || (onlyOpenedHere && how == nil) { return false }
        return open(sessionId: sessionId, config: how?.config, lang: how?.lang) != nil
    }

    func send(_ control: SessionControl, to sessionId: String) -> SendResult {
        let s = state(sessionId)
        if control.isTyping && !s.composerEnabled { return .refused("card_open") }
        if case .answer(let a) = control, let why = Self.refusal(a, in: s) { return .refused(why) }
        if s.exited != nil {
            if case .stop = control { return .refused("the session is not running") }   // nothing to stop: not opened for it
            guard reopenIfExited(sessionId) else { return .unavailable }
        }
        var r = transport.request(Request.send(sessionId: sessionId, line: control.line))
        // the process ended and the exit line never reached this app (it was not watching, or the helper restarted):
        // the session reads as exited here too; it is opened again once and the line sent again — unless the app ended
        // it, or the line is a stop (a stop never opens a session: there is nothing to stop)
        if r?["code"] as? String == "not_open" {
            if state(sessionId).exited == nil { feed(ProtocolLine(sessionId: sessionId, event: .sessionExit(HelperSessionExit(code: nil)))) }
            if case .stop = control { return .refused("the session is not running") }
            lock.lock()
            let ended = endedByApp.contains(sessionId), how = opened[sessionId]
            lock.unlock()
            guard !ended, open(sessionId: sessionId, config: how?.config, lang: how?.lang) != nil else { return .unavailable }
            r = transport.request(Request.send(sessionId: sessionId, line: control.line))
        }
        guard let r, r["ok"] as? Bool != false else { return .unavailable }
        return .sent
    }

    /// Sends again what was queued when the session's process ended (SessionState.unsent), as a new message; it leaves
    /// the unsent list once sent.
    func resend(_ itemId: String, in sessionId: String) -> SendResult {
        guard let item = state(sessionId).unsent.first(where: { $0.id == itemId }) else { return .refused("no such unsent message") }
        let r = send(.say(item.text), to: sessionId)
        if r == .sent { dropUnsent(itemId, in: sessionId) }
        return r
    }

    /// The user lets an unsent message go.
    func dropUnsent(_ itemId: String, in sessionId: String) {
        lock.lock()
        var s = states[sessionId] ?? SessionState(sessionId: sessionId)
        s.unsent.removeAll { $0.id == itemId }
        states[sessionId] = s
        lock.unlock()
        onChange?(sessionId, s)
    }

    /// Answers a card (or the result card): sent only if that card can still be answered.
    func answer(_ a: CardAnswer, in sessionId: String) -> SendResult { send(.answer(a), to: sessionId) }

    /// A click on a card's button: it answers the button's own card (its run_id and ask_id), and is sent only while
    /// that card is the open one (or that run's result card is answerable): a stale card's button never answers a new
    /// card, however alike their options.
    func click(_ button: CardModel.Button, in sessionId: String) -> SendResult { answer(CardModel.answer(button), in: sessionId) }

    func end(_ sessionId: String) -> Bool {
        lock.lock()
        endedByApp.insert(sessionId)        // before the request: its exit line may come first
        lock.unlock()
        guard let r = transport.request(Request.end(sessionId: sessionId)) else { return false }
        return r["ok"] as? Bool != false
    }

    /// Watches again from the same cursors at most this many times in a row when a gap stays (the helper has not the
    /// missing lines): then the stream is kept, the held lines wait, and the next reconnect asks again.
    static let maxStalledRewatches = 3
    /// How long a gap may stay open on the same stream before the client watches again: a replay may come out of order.
    static let gapGrace: TimeInterval = 1.0
    /// How often a quiet stream checks whether a gap is overdue.
    static let idleTick: TimeInterval = 0.25

    /// Streams every session's lines until the helper closes the stream (call it off the main thread); false when the
    /// helper is not listening. Reconnecting is calling it again: it says what the app already has, after opening again
    /// the sessions whose process ended. A gap still open `gapGrace` after it appeared ends the stream, and it watches
    /// again from the contiguous cursors (the ordering contract above).
    @discardableResult
    func watch() -> Bool {
        var lastGaps: Set<String>? = nil
        var stalled = 0
        while true {
            for id in sessionIds { reopenIfExited(id, onlyOpenedHere: true) }
            let c = cursor()
            let rewatchOnGap = stalled < Self.maxStalledRewatches
            lock.lock()
            let openedBefore = Set(opened.keys)    // helper.watching's `open` is checked against these only
            lock.unlock()
            // each gap (a stream at its cursor) gets its own grace from when it was first seen
            var since: [String: Date] = [:]
            var rewatch = false
            let overdue: () -> Bool = { [weak self] in
                guard let self, rewatchOnGap else { return false }
                let gaps = self.gaps(), t = self.now()
                since = since.filter { gaps.contains($0.key) }
                for g in gaps where since[g] == nil { since[g] = t }
                return since.values.contains { t.timeIntervalSince($0) >= Self.gapGrace }
            }
            let ok = transport.stream(Request.watch(after: c.after, runs: c.runs), onLine: { [weak self] obj in
                guard let self else { return false }
                if obj["kind"] as? String == "helper.watching", let open = obj["open"] as? [String] {
                    self.notRunning(openedBefore.subtracting(open))
                } else {
                    self.feed(obj)
                }
                if overdue() { rewatch = true; return false }
                return true
            }, onIdle: {
                if overdue() { rewatch = true; return false }
                return true
            })
            if !ok { return false }
            if !rewatch { return true }
            // progress counts only on the streams that held lines back: another stream moving is not progress
            let now = gaps()
            stalled = now == lastGaps ? stalled + 1 : 0
            lastGaps = now
        }
    }

    /// Some session holds lines back past a gap.
    var hasGap: Bool {
        lock.lock(); defer { lock.unlock() }
        return states.values.contains { $0.hasGap }
    }

    /// The streams holding lines back past a gap, each with its cursor ("session@cursor", "session/run@cursor").
    private func gaps() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        var g: Set<String> = []
        for (id, s) in states {
            if !s.pendingSession.isEmpty { g.insert("\(id)@\(s.lastSeq)") }
            for r in s.pendingRuns.keys { g.insert("\(id)/\(r)@\(s.task(r)?.lastSeq ?? 0)") }
        }
        return g
    }

    /// Sessions this client opened that the helper does not run (helper.watching): their process ended unheard (the
    /// idle reaper, a helper restart). They read as exited, and are opened again on the next send or watch.
    private func notRunning(_ ids: Set<String>) {
        for id in ids {
            lock.lock()
            let skip = endedByApp.contains(id) || states[id]?.exited != nil
            lock.unlock()
            if !skip { feed(ProtocolLine(sessionId: id, event: .sessionExit(HelperSessionExit(code: nil)))) }
        }
    }

    /// What the app has, per stream its contiguous cursor: per session the stored seq, per run the executor seq. A run
    /// the app knows of with none of its lines applied yet (named by session.task, or only held back) is at 0, so the
    /// helper replays it from its start.
    func cursor() -> (after: [String: Int], runs: [String: Int]) {
        lock.lock(); defer { lock.unlock() }
        var after: [String: Int] = [:], runs: [String: Int] = [:]
        for (id, s) in states {
            after[id] = s.lastSeq
            for t in s.tasks { runs[t.runId] = t.lastSeq }
            for r in s.pendingRuns.keys where runs[r] == nil { runs[r] = 0 }
            for l in s.pendingSession.values { if case .task(let e) = l.event, runs[e.runId] == nil { runs[e.runId] = 0 } }
        }
        return (after, runs)
    }

    // MARK: feeding

    /// One line from the helper. Lines without a session_id are not a session's (the helper's own replies) and are left.
    /// What became of it: `.held` when it came past a gap in its stream.
    @discardableResult
    func feed(_ obj: [String: Any]) -> SessionReducer.Applied {
        guard let line = ProtocolLine.parse(object: obj) else { return .ignored }
        return feed(line)
    }

    @discardableResult
    func feed(_ line: ProtocolLine) -> SessionReducer.Applied {
        guard let id = line.sessionId else { return .ignored }
        lock.lock()
        let before = states[id] ?? SessionState(sessionId: id)
        var after = before
        let applied = SessionReducer.apply(&after, line)
        states[id] = after
        lock.unlock()
        if after != before { onChange?(id, after) }
        return applied
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
