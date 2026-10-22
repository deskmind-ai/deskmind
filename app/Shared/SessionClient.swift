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
// Process lifetimes (helper side: deskmind#105). A session runs one process at a time; a run belongs to the process
// whose stored session.task named it. The helper says a process ended with {"kind":"helper.session_exit","session_id",
// "code","pid","start_seq","last_seq"}: `start_seq` is the stored seq it began after (its session.start's last_seq),
// `last_seq` the last stored session seq it forwarded from it. So, whatever order the lines come in, a run whose
// session.task seq is at or below an exit's last_seq (or a later process's session.start last_seq) is gone with its
// process, and an exit of an older process (another start_seq; or, if the helper also adds `pid` to the session.start
// it forwards, another pid) that comes after the next process's start leaves the new process alone. Without
// last_seq / pid (an older helper, or the app's own inference below), an exit is taken for the latest process and the
// runs the app has seen tied to it; a run whose session.task has not come stays provisional.
//
// The user's words have one owner at a time (harness#57). say / cua / steer carry a client_id; the words stay in
// SessionState.outbox (sending) until the session says what became of them: the stored user message or session.steer
// with that client_id, or a session.queue entry with it, takes them; a refusal naming it gives them back (unsent,
// 「重新发送」). The helper's ok only says the line was written, so nothing is dropped on it. A session.queue is the whole
// queue (attach sends it, empty included) and replaces the app's.
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

    /// The user's own words this line carries, and what it is sent as (say / cua / steer): they get a client_id and
    /// stay the app's until the session takes them.
    var words: (text: String, control: String)? {
        switch self {
        case .say(let t): return (t, "say")
        case .cua(let t, _): return (t, "cua")
        case .steer(let t, _): return (t, "steer")
        default: return nil
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
        let startsBefore = sessionId.map { state($0).starts } ?? 0
        let wasExited = sessionId.map { state($0).exited != nil } ?? false
        guard let r = transport.request(Request.open(sessionId: sessionId, config: config, lang: lang)), r["ok"] as? Bool != false,
              let id = r["session_id"] as? String ?? sessionId else { return nil }
        lock.lock()
        if states[id] == nil { states[id] = SessionState(sessionId: id) }
        states[id]?.exited = nil
        // a process was started (not one found running): words sent until its start is heard are its own
        // (unless that start came in while the request was out: a start heard since, at the stored seq the helper
        // says the process starts at, when it says it)
        let want = (r["last_seq"] as? NSNumber)?.intValue
        // (or a newer process than this one has started already: two opens, the other's reply handled first)
        let heard = ((states[id]?.starts ?? 0) != startsBefore && (want == nil || states[id]?.processStart == want))
            || (want != nil && (states[id]?.processStart ?? Int.min) > want!)
        // a process found running (another open started it) after the one the app knew had exited, its start not
        // heard yet: awaited too (its start seq unknown: any start is it)
        if r["already_open"] as? Bool == true && wasExited && (states[id]?.starts ?? 0) == startsBefore && states[id]?.awaitingStart != true {
            states[id]?.awaitingStart = true; states[id]?.awaitedStart = nil; states[id]?.awaitedPid = (r["pid"] as? NSNumber)?.intValue
        }
        if r["already_open"] as? Bool != true && !heard {
            let pid = (r["pid"] as? NSNumber)?.intValue
            // two opens whose replies come back in reverse order: the newer process (the higher seq) is the one awaited
            if states[id]?.awaitingStart == true, let old = states[id]?.awaitedStart, let w = want, w < old {}
            else { states[id]?.awaitedStart = want; states[id]?.awaitedPid = pid }
            states[id]?.awaitingStart = true
        }
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

    /// The id the app gives the user's words it sends (say, cua, steer): the session gives it back on what became of
    /// them (harness#57). Tests set their own.
    var newClientId: () -> String = { "c_" + UUID().uuidString.prefix(12).lowercased() }

    func send(_ control: SessionControl, to sessionId: String) -> SendResult { send(control, to: sessionId, clientId: nil) }

    /// `clientId`: the words' id when they are sent again (resend); new words get one.
    private func send(_ control: SessionControl, to sessionId: String, clientId: String?) -> SendResult {
        let s = state(sessionId)
        if control.isTyping && !s.composerEnabled { return .refused("card_open") }
        if case .answer(let a) = control, let why = Self.refusal(a, in: s) { return .refused(why) }
        if s.exited != nil, let why = Self.goneWithProcess(control, in: s) { return .refused(why) }
        // a steer names its task: the one running now, made explicit, so that a resend never goes to another one
        var control = control
        if case .steer(let t, nil) = control {
            guard let r = s.runningTask?.runId else { return .refused("no task is running") }    // nothing to name: not sent
            control = .steer(t, runId: r)
        }
        // the user's words: held in the outbox from here until the session says what became of them
        var line = control.line
        var words: String? = nil
        var startsAtHold = 0, heldNext = false
        if let w = control.words {
            // the session answers nothing for empty words (harness docs): never sent, so never held
            if w.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).isEmpty { return .refused("empty") }
            let id = clientId ?? newClientId()
            words = id
            line["client_id"] = id
            var gone = false
            mutate(sessionId) { st in
                // taken by the history meanwhile (a resend racing its stored line): nothing to send
                if st.taken.contains(id) { gone = true; return }
                // the send opens the session again, or it was opened and its process's start not heard yet: the
                // words are the next process's (decided on the state as it is now, not as it was read above)
                startsAtHold = st.starts
                let next = st.exited != nil || st.awaitingStart
                heldNext = next
                if let i = st.outbox.firstIndex(where: { $0.id == id }) { st.outbox[i].sending = true; st.outbox[i].refused = nil; st.outbox[i].toNextProcess = next }
                else { st.outbox.append(Outgoing(id: id, text: w.text, control: w.control, sending: true, toNextProcess: next, original: control)) }
            }
            if gone { return .refused("taken") }
        }
        // not sent after all: the words are the app's, not sent (never lost)
        let notSent = { [self] (r: SendResult) -> SendResult in
            if let id = words {
                mutate(sessionId) { st in
                    if let i = st.outbox.firstIndex(where: { $0.id == id }), st.outbox[i].sending { st.outbox[i].sending = false; st.outbox[i].refused = "unavailable" }
                }
            }
            return r
        }
        if s.exited != nil {
            guard reopenIfExited(sessionId) else { return notSent(.unavailable) }
            // (an exit heard while the open request was out may have made the word unsent: it is the new process's —
            // the next one's, if it was held so and no start was heard since)
            if let id = words { mutate(sessionId) { st in if let i = st.outbox.firstIndex(where: { $0.id == id }) { st.outbox[i].sending = true; st.outbox[i].refused = nil; st.outbox[i].toNextProcess = st.awaitingStart || (heldNext && st.starts == startsAtHold) } } }
        }
        var r = transport.request(Request.send(sessionId: sessionId, line: line))
        // the process ended and the exit line never reached this app (it was not watching, or the helper restarted):
        // the session reads as exited here too; it is opened again once and the line sent again — unless the app ended
        // it, or the line was for what went with the process (a stop, a steer, a card's answer: never opens a session)
        if r?["code"] as? String == "not_open" {
            if state(sessionId).exited == nil { feed(ProtocolLine(sessionId: sessionId, event: .sessionExit(HelperSessionExit(code: nil)))) }
            if let why = Self.goneWithProcess(control, in: state(sessionId)) { return notSent(.refused(why)) }
            lock.lock()
            let ended = endedByApp.contains(sessionId), how = opened[sessionId]
            lock.unlock()
            guard !ended, open(sessionId: sessionId, config: how?.config, lang: how?.lang) != nil else { return notSent(.unavailable) }
            if let id = words { mutate(sessionId) { st in if let i = st.outbox.firstIndex(where: { $0.id == id }) { st.outbox[i].sending = true; st.outbox[i].refused = nil; st.outbox[i].toNextProcess = st.awaitingStart || st.starts == startsAtHold } } }
            r = transport.request(Request.send(sessionId: sessionId, line: line))
        }
        guard let r, r["ok"] as? Bool != false else { return notSent(.unavailable) }
        // (sent: the words stay in the outbox, sending, until the session takes or refuses them)
        return .sent
    }

    /// Why a control is moot once the session's process ended (it was for the task or the card that went with it), or
    /// nil when a new process can take it (say, cua, retry, the queue's controls, attach).
    static func goneWithProcess(_ control: SessionControl, in s: SessionState) -> String? {
        switch control {
        case .stop: return "the session is not running"
        case .steer: return s.runningTask == nil ? "no task is running" : nil
        case .answer(let a): return refusal(a, in: s)
        default: return nil
        }
    }

    /// Sends again words the app holds, not sent (SessionState.unsent: refused, or queued when the process ended),
    /// exactly as they were first sent (the whole line: a /cua's scope, a steer's task) with their client_id. A steer
    /// whose task is no longer running is not sent anywhere else: refused, and the words stay unsent ("task_ended").
    /// They stay in the outbox until the session takes them.
    func resend(_ id: String, in sessionId: String) -> SendResult {
        let s = state(sessionId)
        guard let item = s.unsent.first(where: { $0.id == id }) else { return .refused("no such unsent message") }
        let control = item.original ?? .say(item.text)
        if case .steer(_, let r) = control, r.map({ s.task($0)?.running != true }) ?? true {
            mutate(sessionId) { st in if let i = st.outbox.firstIndex(where: { $0.id == id }) { st.outbox[i].refused = "task_ended" } }
            return .refused("task_ended")
        }
        return send(control, to: sessionId, clientId: item.id)
    }

    /// The user lets an unsent message go.
    func dropUnsent(_ id: String, in sessionId: String) {
        mutate(sessionId) { st in st.outbox.removeAll { $0.id == id && !$0.sending } }
    }

    private func mutate(_ sessionId: String, _ f: (inout SessionState) -> Void) {
        lock.lock()
        var s = states[sessionId] ?? SessionState(sessionId: sessionId)
        f(&s)
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
        var after = states[id] ?? SessionState(sessionId: id)
        states[id] = nil                                    // the reducer works on the only copy (no copy-on-write)
        let applied = SessionReducer.apply(&after, line)
        states[id] = after
        lock.unlock()
        // (no whole-state comparison per line: in a long session that cost more than the line itself)
        if applied == .applied || applied == .held { onChange?(id, after) }
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
