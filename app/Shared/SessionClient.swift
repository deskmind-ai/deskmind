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
    /// (session.open waits for a process still closing, then for the new one's first line: up to about 40 s)
    func request(_ body: [String: Any]) -> [String: Any]? {
        DeskMindIPC.request(body, timeout: body["op"] as? String == SessionClient.Op.open ? SessionClient.openTimeout : SessionClient.requestTimeout)
    }
    func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool {
        DeskMindIPC.streamWhile(body, idle: SessionClient.idleTick, onIdle: onIdle, onLine)
    }
}

/// Where deferred work runs: a queue and the wall clock (the app), or a test's own steps, run when the test says — so a
/// test's interleaving is its seed's, not the machine's timing (deskmind#112).
struct DeferredWork {
    /// Runs `f` later, in order with the rest given to this lane (a serial queue's async).
    var soon: (@escaping () -> Void) -> Void
    /// Runs `f` after about `d` seconds.
    var after: (TimeInterval, @escaping () -> Void) -> Void
    /// A test's steps only: what a wait for this work does instead — it runs the work, on the caller's thread.
    var drain: (() -> Void)?
    static func queue(_ q: DispatchQueue) -> DeferredWork {
        DeferredWork(soon: { q.async(execute: $0) }, after: { d, f in q.asyncAfter(deadline: .now() + d, execute: f) }, drain: nil)
    }
}

/// The helper's "cloud models off" bit kept equal to the app's switch (#107 review: a lost models.off left the helper
/// off and the app on for good). One per app process, injected where it is used (never chosen by the transport's type:
/// two would race each other). Every send reads the switch as it is when it goes (`current`), never a value captured
/// before; sends go one at a time on one serial queue and again with backoff until the helper acks the switch as it is
/// then. What waits for the ack (`then`) runs once it comes, whichever push it was.
final class ModelsOffSync {
    /// The app's: the helper's own transport, the engine setting as written (CloudModelSettings.engineIsCloud).
    static let shared = ModelsOffSync(transport: HelperSessionTransport(),
                                      current: { UserDefaults.standard.string(forKey: "engine") != "harness" })
    private let transport: SessionTransport
    private let current: () -> Bool
    private let queue = DispatchQueue(label: "ai.deskmind.models-off")
    private let lock = NSLock()
    private var gen = 0
    private var pending = false
    private var waiting: [() -> Void] = []
    /// The first wait before a try again (doubling, up to 30 s).
    var firstDelay = 0.25
    init(transport: SessionTransport, current: @escaping () -> Bool) {
        self.transport = transport; self.current = current; self.work = .queue(queue)
    }
    /// Where its sends run (the app: its own serial queue; a test: its steps). Set before the first push.
    var work: DeferredWork
    private var acked_: [() -> Void] = []
    private var callbacks = 0
    /// Configurations on their way to a session, let go while no switch was on its way (`beginConfigSend`): a models.off
    /// waits for them, so none reaches the helper after it (#107 review at 00df2f8: one did, between a converge's check
    /// and its send).
    private var configSends = 0
    /// Guards `configSends`, and wakes a models.off waiting for it to reach 0.
    private let sendsDone = NSCondition()
    /// How long a models.off waits for configurations let go before it (bounded, as every wait). Past it, it goes: the
    /// helper keeps the order itself (SessionHost refuses a configuration after models.off, under the same lock), so the
    /// bound never breaks the rule; it only stops the app's wait.
    var offWaitBound: Double = 25
    /// What the helper last acked: it holds cloud models off (nil: not heard yet).
    private var helperOff: Bool?
    var helperHoldsOff: Bool? { lock.lock(); defer { lock.unlock() }; return helperOff }
    /// A configuration may go now: no switch on its way, and the helper not known to hold models off (the app's switch
    /// may already read on before its push has begun) — counted in the same step, so a push begun after it waits.
    func beginConfigSend() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if pending || helperOff == true { return false }
        sendsDone.lock(); configSends += 1; sendsDone.unlock()
        return true
    }
    func endConfigSend() {
        sendsDone.lock(); configSends -= 1; if configSends == 0 { sendsDone.broadcast() }; sendsDone.unlock()
    }
    /// Called after every ack (on this sync's queue: the callee must not wait for it — SessionClient queues a converge).
    func onAck(_ f: @escaping () -> Void) { lock.lock(); acked_.append(f); lock.unlock() }

    /// Tells the helper the switch (as it is when the send goes), until it acks; `then` once it has.
    func push(then: (() -> Void)? = nil) {
        let off = current()          // (read outside the lock: it reads the app's settings)
        lock.lock(); if off { offEpoch_ += 1 }; gen += 1; let g = gen; pending = true; if let then { waiting.append(then) }; lock.unlock()
        work.soon { [weak self] in self?.attempt(g, delay: self?.firstDelay ?? 0.25) }
    }

    private func attempt(_ g: Int, delay: Double) {
        lock.lock(); let latest = g == gen; lock.unlock()
        guard latest else { return }                         // (a newer push carries on)
        // configurations let go before this push began reach the helper first: waited for, at most `offWaitBound` (a
        // condition, not a poll)
        let deadline = Date().addingTimeInterval(offWaitBound)
        sendsDone.lock()
        while configSends > 0 { if !sendsDone.wait(until: deadline) { break } }
        sendsDone.unlock()
        let off = current()
        let r = transport.request(SessionClient.Request.modelsOff(off))
        // a helper without the op holds no bit: nothing to keep equal
        let acked = r?["ok"] as? Bool == true || r?["error"] as? String == "unknown op"
        if acked && current() == off {
            lock.lock()
            helperOff = r?["ok"] as? Bool == true ? off : nil
            var run: [() -> Void] = []
            if g == gen { pending = false; run = waiting; waiting = [] }
            let observers = acked_
            callbacks += 1                          // (settle waits for these too: what they start is under way after it)
            lock.unlock()
            for f in run { f() }
            for f in observers { f() }              // (each client's sessions converged: the switch the helper has now)
            lock.lock(); callbacks -= 1; lock.unlock()
            return
        }
        // not acked, or the switch moved while it went: again (at once if it only moved)
        let next = acked ? 0 : delay
        work.after(next) { [weak self] in self?.attempt(g, delay: min(delay * 2, 30)) }
    }

    /// The switch as it is now (where every path reads it).
    func switchOff() -> Bool { current() }
    /// How many times the switch was pushed while it read off: a value read before, different now, means the switch went
    /// off in between (even if it is on again). Every write of the switch pushes (CloudModelSettings.engineIsCloud).
    var offEpoch: Int { lock.lock(); defer { lock.unlock() }; return offEpoch_ }
    private var offEpoch_ = 0
    /// A push not acked yet (a retry may be scheduled).
    var isPending: Bool { lock.lock(); defer { lock.unlock() }; return pending }
    /// A push unless one is under way already (it carries `then` too): repair paths, at most one per push.
    func pushOnce(then: (() -> Void)? = nil) {
        lock.lock()
        if pending { if let then { waiting.append(then) }; lock.unlock(); return }
        lock.unlock()
        push(then: then)
    }
    /// How long an open waits for the helper's ack (settle's default).
    var settleTimeout: Double = 3

    /// Waits (bounded) until the switch the helper holds is acked — a retry still scheduled is waited for too.
    func settle(timeout: Double? = nil) {
        if let drain = work.drain { drain(); return }        // (a test's steps: run, not polled)
        let timeout = timeout ?? settleTimeout
        let until = Date().addingTimeInterval(timeout)
        while Date() < until {
            lock.lock(); let busy = pending || callbacks > 0; lock.unlock()
            if !busy { return }
            usleep(10_000)
        }
    }
}

/// What the user does in a session, as the session's control lines (docs/protocol.md 「会话（第 1 版）」, 控制).
enum SessionControl: Equatable {
    case say(String)
    case cua(String, scope: String? = nil)
    case stop(runId: String? = nil)
    case steer(String, runId: String? = nil)
    /// `reqId`: this client's id for the line (harness#71 echoes it on a refusal of it and on session.task_respond).
    case answer(CardAnswer, reqId: String? = nil)
    /// 「现在回答」 on a card that expired (ask_void timeout, harness H1): the task looks again and asks a new card.
    case reask(runId: String)
    case retry
    case queueEdit(id: String, text: String)
    case queueCancel(id: String)
    case queueSendNow(id: String)
    case attach(afterSeq: Int, runId: String? = nil)
    /// The session's settings, in place (harness#64): a configuration, or nil for no model at all.
    case setConfig(config: String?, lang: String?)

    var line: [String: Any] {
        switch self {
        case .say(let t): return ["type": "say", "text": t]
        case .cua(let t, let scope): return ["type": "cua", "text": t].merging(scope.map { ["scope": $0] } ?? [:]) { a, _ in a }
        case .stop(let r): return ["type": "stop"].merging(r.map { ["run_id": $0] } ?? [:]) { a, _ in a }
        case .steer(let t, let r): return ["type": "steer", "text": t].merging(r.map { ["run_id": $0] } ?? [:]) { a, _ in a }
        case .answer(let a, let req): var o = a.control; if let req { o["req_id"] = req }; return o
        case .reask(let r): return ["type": "reask", "run_id": r]
        case .retry: return ["type": "retry"]
        case .queueEdit(let id, let t): return ["type": "queue_edit", "id": id, "text": t]
        case .queueCancel(let id): return ["type": "queue_cancel", "id": id]
        case .queueSendNow(let id): return ["type": "queue_send_now", "id": id]
        case .attach(let n, let r): return ["type": "attach", "after_seq": n].merging(r.map { ["run_id": $0] } ?? [:]) { a, _ in a }
        case .setConfig(let c, let l):
            var o: [String: Any] = ["type": "set_config", "config": c.map { $0 as Any } ?? NSNull()]
            if let l { o["lang"] = l }
            return o
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

    /// A control that makes the model work (say, cua, retry, steer, queue_send_now, reask — 「现在回答」 has the task look
    /// and decide again): never written while the model is off (the client's `modelOff`, read as it is sent; the helper
    /// refuses the same list, SessionWire.needsModel). A card's answer depends on its option: SessionClient.needsModel.
    var needsModel: Bool {
        switch self { case .say, .cua, .retry, .steer, .queueSendNow, .reask: return true; default: return false }
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
    /// Its process runs in the helper now (sessions.list's `open`): one started before this app knew it, too — a new
    /// key must reach it as well (ShellModel.askNewProcesses, #107 review at 5999bd9). Not part of `==` (the list's
    /// rows do not show these three).
    var open = false
    /// The models.env digest its process started with (ModelKeys), when the helper says (nil: an older helper).
    var keys: String?
    /// A restart of its process is asked already (at its next idle moment).
    var ending = false
    /// Its process is being spawned, or its session.start has not come yet: not `open`; `keys` nil while unknown.
    var starting = false

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
        self.open = o["open"] as? Bool ?? false
        self.keys = o["keys"] as? String
        self.ending = o["ending"] as? Bool ?? false
        self.starting = o["starting"] as? Bool ?? false
    }
}

final class SessionClient {
    /// How long the helper is waited for: an open (it waits for a process still closing, then the new one's first
    /// line), any other request. A send may reopen the session first and send its line twice (`sendTimeout`).
    static let openTimeout: Double = 60
    static let requestTimeout: Double = 20
    static let sendTimeout: Double = openTimeout + 2 * requestTimeout

    enum Op {
        static let open = "session.open"
        static let send = "session.send"
        static let end = "session.end"
        static let watch = "sessions.watch"
        static let list = "sessions.list"
        static let delete = "session.delete"
        static let history = "session.history"
        /// Cloud models off, held by the helper for every session it runs (whichever client).
        static let modelsOff = "models.off"
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
        /// A restart: the helper ends the process once the session is idle (now, or when what runs is over).
        static func restart(sessionId: String) -> [String: Any] { ["op": Op.end, "session_id": sessionId, "when_idle": true] }
        static func history(sessionId: String, after: Int, runs: [String: Int]) -> [String: Any] {
            ["op": Op.history, "session_id": sessionId, "after_seq": after, "runs": runs]
        }
        static func list() -> [String: Any] { ["op": Op.list] }
        static func modelsOff(_ off: Bool) -> [String: Any] { ["op": Op.modelsOff, "off": off] }
        static func delete(sessionId: String) -> [String: Any] { ["op": Op.delete, "session_id": sessionId] }
        /// `after`: per session the last stored seq the app has, and per run the last executor seq: the helper replays
        /// what came after (attach), then streams.
        static func watch(after: [String: Int], runs: [String: Int]) -> [String: Any] { ["op": Op.watch, "after": after, "runs": runs] }
    }

    private let transport: SessionTransport
    private let lock = NSLock()
    private var states: [String: SessionState] = [:]
    // MARK: settings — desired, dirty, one send in flight
    //
    // Sending set_config is idempotent, so the client does not track what a process "has" (#107 review at 00df2f8: three
    // rounds of bugs came from deciding that out of racing evidence — open replies, starts, replayed and held rows).
    //
    // - desired(): the settings as stored now — read where the saves wrote them (`settingsSource`: the app's
    //   UserDefaults / CloudModelSettings, through the shell), with the models-off bit (no model: config null). Never
    //   captured into a closure or passed through a queue: async work only says "converge now", and reads it then.
    // - Per session: `dirty`, at most one send in flight {its generation}, one retry timer. `generation` goes up at every
    //   process start (an open reply that started one, a session.start).
    //
    // The invariant: after the last trigger for a session, a set_config carrying desired() — read when it was sent —
    // got ok (or busy) from the current process (same generation). Until then the session is dirty or has a send in
    // flight, and is retried with backoff until it exits. A next process opens with desired(), read at its open.
    //
    // Triggers (each marks the session dirty and converges): a save (convergeAll), a process start (an open reply that
    // started one, session.start), a session's first line here, the helper's watch (re)connect, a no_model refusal, the
    // switch's ack, an in-order applied session.config that is not desired (the reducer's settings after it took the
    // row: a held row counts once its gap fills), a send that failed. Our own send's echo equals desired: no loop.
    //
    // | state \ trigger         | trigger                          | own reply, same generation | old generation      | failed       | exit/delete |
    // |-------------------------|----------------------------------|----------------------------|---------------------|--------------|-------------|
    // | idle                    | dirty; send desired → in flight  | —                          | —                   | —            | clear all   |
    // | dirty, none in flight   | send desired (switch pending:    | —                          | —                   | —            | clear all   |
    // |                         |   null only, until its ack)      |                            |                     |              |             |
    // | in flight               | dirty (the reply re-checks)      | clear; dirty → send again  | drop; send again    | dirty; retry | clear all   |
    // | exited / not live       | nothing (next open: desired())   | —                          | —                   | —            | —           |
    //
    // Accepted cost: one extra set_config after each open or start, and one per triggering row.

    /// Where the settings are read from, now (the app's store, through the shell). nil: `stored` (a client in a test).
    var settingsSource: (() -> (config: String?, lang: String?))?
    private var stored: (config: String?, lang: String?) = (nil, nil)
    /// The settings stored now (configuration and language; the models-off bit apart: `off`).
    func desired() -> (config: String?, lang: String?) {
        if let s = settingsSource { return s() }
        lock.lock(); defer { lock.unlock() }; return stored
    }
    /// What a converge sends: desired, with no model while cloud models are off — normalised as the harness does
    /// (`normalizeConfig`), so that the session's own echo of it compares equal.
    private func desiredNow() -> (config: String?, lang: String?) {
        let d = desired()
        return (modelOff ? nil : d.config.map(Self.normalizeConfig), d.lang)
    }

    /// The harness's normalizeConfig (gateway/index.ts), exactly: the model of `openai:<service>|<model>` without the
    /// whitespace around it (a model name pasted into the settings keeps it; a version before 0.5 saved it so); anything
    /// else as it is. #107 review at 187ae8e: unnormalised, the echo never equalled desired — a set_config, and a stored
    /// line, every round.
    static func normalizeConfig(_ spec: String) -> String {
        guard spec.hasPrefix("openai:"), let bar = spec.firstIndex(of: "|") else { return spec }
        let service = spec[spec.index(spec.startIndex, offsetBy: 7)..<bar]
        guard !service.isEmpty, service.allSatisfy({ $0 >= "a" && $0 <= "z" }) else { return spec }
        return "openai:\(service)|" + spec[spec.index(after: bar)...].trimmingCharacters(in: jsWhitespace)
    }

    /// What JavaScript's String.prototype.trim removes, exactly (ECMA-262 WhiteSpace and LineTerminator): U+0009–000D,
    /// 0020, 00A0, 1680, 2000–200A, 2028, 2029, 202F, 205F, 3000, FEFF — not U+0085, not U+200B. Foundation's
    /// .whitespacesAndNewlines differs (it keeps U+FEFF, takes U+0085): a pasted name with a U+FEFF looped (#107 review
    /// at 32c458b).
    static let jsWhitespace: CharacterSet = {
        var s = CharacterSet(charactersIn: Unicode.Scalar(0x09)!...Unicode.Scalar(0x0D)!)
        for v: UInt32 in [0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF] { s.insert(Unicode.Scalar(v)!) }
        s.insert(charactersIn: Unicode.Scalar(0x2000)!...Unicode.Scalar(0x200A)!)
        return s
    }()
    /// desired()'s configuration and language (for a client in a test, settable: `stored`).
    var defaultConfig: String? {
        get { desired().config }
        set { lock.lock(); stored.config = newValue; lock.unlock() }
    }
    var defaultLang: String? {
        get { desired().lang }
        set { lock.lock(); stored.lang = newValue; lock.unlock() }
    }
    /// Cloud models are off in the settings: every session runs with no model (set_config null, harness#64). This
    /// client owns it: every session it knows with a process — live, opening, reopening, awaiting its start — is
    /// reconciled to it (`reconcile`), an open re-checks it once its reply is in (the switch may have moved meanwhile)
    /// and sends the matching set_config before anything else, and a control that needs the model is never written
    /// while it is off. An open then carries no configuration (one on the open line outranks the stored null).
    ///
    /// One source of truth: with the app's ModelsOffSync injected, the switch is read where it reads it (the engine
    /// setting), never a copy (#107 review: a cached copy that caught up only when the sheet closed set off a storm of
    /// models.off and refused set_configs). A client without one (a test) keeps its own.
    var modelOff: Bool {
        // (the app's switch read outside this client's lock: never a call out while holding it)
        get { if let s = injectedSync { return s.switchOff() }; lock.lock(); defer { lock.unlock() }; return offStored }
        set { lock.lock(); if newValue && !offStored { ownOffEpoch += 1 }; offStored = newValue; lock.unlock() }
    }
    private var offStored = false
    private var ownOffEpoch = 0
    /// Goes up whenever the switch goes off (ModelsOffSync.offEpoch; a test client's own): an answer held while it
    /// went off is never sent, even once it is on again.
    var offEpoch: Int {
        if let s = injectedSync { return s.offEpoch }
        lock.lock(); defer { lock.unlock() }; return ownOffEpoch
    }
    private var off: Bool { injectedSync?.switchOff() ?? offStored }
    /// Sessions whose open request is out (a reconcile reaches them too).
    private var opening: Set<String> = []
    /// Keeps the helper's models-off bit equal to `modelOff` (the app's switch): the app's one for the helper's own
    /// transport, else one of this client's.
    /// The one ModelsOffSync of the app (injected: `init(transport:modelsSync:)`); a client made without one (a test)
    /// has its own, on its own switch.
    private let injectedSync: ModelsOffSync?
    /// Made in init, not lazily: it is read from the reconcile queue and the watch thread at once, and a lazy var's first
    /// read is not thread-safe (ThreadSanitizer, #107 at c2997ba).
    private(set) var modelsSync: ModelsOffSync!

    /// The helper says whether it holds cloud models off (helper.watching's `models_off`, a `no_model` refusal): when
    /// that is not the app's switch, the switch is pushed again (until acked), then every session reconciled — to the
    /// switch as it is then, not as it was here.
    func helperSays(modelsOff theirs: Bool) {
        guard theirs != modelOff else { return }
        // at most once per push: while one is under way, it carries this too
        modelsSync.pushOnce { [weak self] in self?.convergeAllLater() }
    }
    /// Sessions whose settings must be sent (see "settings" above).
    private var dirty: Set<String> = []
    /// The one set_config in flight per session: the generation it went to.
    private var inFlight: [String: Int] = [:]
    /// The next send's attempt (2 after a first `busy`: one more send to get it stored).
    private var nextAttempt: [String: Int] = [:]
    /// Sessions with a converge retry waiting (one chain per session).
    private var retryScheduled: Set<String> = []
    /// The client_ids of this client's recent set_configs per session (their echoes are its own), and the (desired,
    /// generation) pairs an echo has already sent again: a guard, so that no normalisation the client does not share with
    /// the harness can loop (#107 review at 32c458b) — an echo of ours that is not desired sends at most once per pair; a
    /// row that is not ours (the helper's null, another client's) always does.
    private var ownConfigs: [String: [String]] = [:]
    private var echoResent: [String: Set<String>] = [:]
    /// A failed send's next try (per session: its delay; doubling, at most 30 s).
    private var retryDelay: [String: Double] = [:]
    /// Bumped on every open of a session and every process start heard: a check made before (a backfill's exit)
    /// applies only to the process it saw.
    private var generation: [String: Int] = [:]
    /// set_config lines sent and not yet answered (by client_id): a `busy` refusal (it took effect, was not stored) is
    /// sent once more; a second one, or bad_config, is shown (SessionState.settingsRefused).
    private struct PendingConfig { var sessionId: String; var config: String?; var lang: String?; var attempt: Int }
    private var pendingConfigs: [String: PendingConfig] = [:]
    /// The watch's stream ended and has not come back (no helper.watching since): a history read's `open: false` may
    /// then be a helper restarting (no process yet), and is not read as the session's process having ended.
    private var watchDown = false
    /// Stored lines read after a watch (re)connect (`watch`), off the stream's thread: tests wait on it.
    let backfilling = DispatchGroup()

    /// One set_config request per session at a time, each reading desired when it goes: two for one session never
    /// reach the helper out of order.
    private var configLocks: [String: NSLock] = [:]
    private func configLock(_ id: String) -> NSLock {
        lock.lock(); defer { lock.unlock() }
        if let l = configLocks[id] { return l }
        let l = NSLock(); configLocks[id] = l; return l
    }
    /// Sessions this client opened: a watch reopens these (and no others: #107 re-review, a settings save then a helper
    /// restart reopened every known session, ~80 MB each). With desired(), read at the open.
    private var openedHere: Set<String> = []
    /// Sessions the app ended (`end`): their process's exit is expected, and they are not opened again by themselves.
    private var endedByApp: Set<String> = []
    /// Sessions the user deleted (`delete`): whatever still comes of them is left.
    private var deleted: Set<String> = []
    /// Sessions whose process the helper closed because they were idle (helper.session_exit `idle`, helper.watching's
    /// `idle`): nothing was cut, so nothing reopens them but the next send (or open).
    private var idleClosed: Set<String> = []
    /// One request at a time per session (a send, a restart): a restart never overtakes a send the app made before it.
    private var sessionLocks: [String: NSLock] = [:]
    private func sessionLock(_ id: String) -> NSLock {
        lock.lock(); defer { lock.unlock() }
        if let l = sessionLocks[id] { return l }
        let l = NSLock(); sessionLocks[id] = l; return l
    }
    /// An open waits for the helper to take the switch (ModelsOffSync.settle): true while it does, then false.
    var onWaitingForHelper: ((Bool) -> Void)?
    /// The clock the gap grace is measured by (tests set their own).
    var now: () -> Date = Date.init
    /// Called after a line changed a session's state (on the thread that fed it).
    var onChange: ((String, SessionState) -> Void)?
    /// A session's refusal of a respond / answer that carries a req_id (harness#71), each as it comes (on the thread
    /// that fed it; never kept here): the window matches it to its own line or drops it.
    var onAnswerRefusal: ((String, SessionErrorEvent) -> Void)?

    init(transport: SessionTransport = HelperSessionTransport(), modelsSync: ModelsOffSync? = nil) {
        self.transport = transport
        self.injectedSync = modelsSync
        self.reconcileWork = .queue(reconcileQueue)
        self.modelsSync = modelsSync ?? ModelsOffSync(transport: transport, current: { [weak self] in self?.modelOff ?? false })
        // a models-off ack: every session converged to the switch the helper holds now
        self.modelsSync.onAck { [weak self] in self?.convergeAllLater() }
    }

    func state(_ sessionId: String) -> SessionState {
        lock.lock(); defer { lock.unlock() }
        return states[sessionId] ?? SessionState(sessionId: sessionId)
    }

    var sessionIds: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(states.keys)
    }

    /// The sessions this client has lines of (none deleted).
    private func knownIds() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(states.filter { $0.value.lastSeq > 0 }.keys).subtracting(deleted)
    }

    /// Reads these sessions' stored lines after their cursors (session.history), off the calling thread, one serial
    /// queue; those of them that do not run (`exits`) are marked exited only once their stored lines are in, with the
    /// history's last stored seq as the exit's (#107 review: an exit applied before the lines a process stored while
    /// the watch was down left the task it had just started running).
    private let backfillQueue = DispatchQueue(label: "ai.deskmind.session.backfill")
    /// The exit is marked only for the process the reconnect saw not running: the history says none runs now, and no
    /// open or start since (`generation`; #107 review: a reopen during the read had its new task cut off).
    private func backfill(_ ids: Set<String>, exits: Set<String>, idle: Set<String>) {
        guard !ids.isEmpty else { return }
        lock.lock(); let seen = generation; lock.unlock()
        backfilling.enter()
        backfillQueue.async { [weak self] in
            defer { self?.backfilling.leave() }
            for id in ids.sorted() {
                guard let self else { return }
                let read = self.readHistory(id, markExit: false)
                if exits.contains(id), read.open != true {
                    // (the generation checked under the same lock the exit is applied under)
                    self.notRunning([id], idle: idle, lastSeqs: read.lastSeq.map { [id: $0] } ?? [:], generations: seen)
                }
            }
        }
    }

    // MARK: ops

    /// The sessions as rows (the stored list).
    func list() -> [SessionSummary]? { listWithKeys()?.sessions }

    /// sessions.list: the stored sessions (rows), the models.env digest now as the helper reads it (`keys`), and the
    /// helper's own process table (`processes`: every session process it holds, stored or not). nil keys/processes:
    /// an older helper (its `sessions` say `open` only).
    func listWithKeys() -> (sessions: [SessionSummary], keysNow: String?, processes: [SessionSummary]?)? {
        guard let r = transport.request(Request.list()), r["ok"] as? Bool != false,
              let items = r["sessions"] as? [[String: Any]] else { return nil }
        let procs = (r["processes"] as? [[String: Any]]).map { $0.compactMap(SessionSummary.init) }
        return (items.compactMap(SessionSummary.init), r["keys"] as? String, procs)
    }

    /// Opens a session (a new one when `sessionId` is nil); its id, or nil when the helper could not. With desired(),
    /// read now, unless `config` / `lang` are given (a test's own).
    func open(sessionId: String? = nil, config: String? = nil, lang: String? = nil) -> String? {
        let startsBefore = sessionId.map { state($0).starts } ?? 0
        let wasExited = sessionId.map { state($0).exited != nil } ?? false
        // cloud models off: no configuration on the open line (it would outrank the session's stored null), and no
        // model from its first control on (set_config null, before anything else is written)
        // (the switch the helper holds, asserted before, is there first: said while it is awaited)
        if modelsSync.isPending {
            onWaitingForHelper?(true)
            modelsSync.settle()
            onWaitingForHelper?(false)
        }
        let noModel = modelOff
        // (desired, read now — never a value read before and carried here)
        let d = desired()
        let line: (config: String?, lang: String?) = (noModel ? nil : (config ?? d.config).map(Self.normalizeConfig), lang ?? d.lang)
        if let sessionId { lock.lock(); opening.insert(sessionId); lock.unlock() }
        defer { if let sessionId { lock.lock(); opening.remove(sessionId); lock.unlock() } }
        guard let r = transport.request(Request.open(sessionId: sessionId, config: line.config, lang: line.lang)), r["ok"] as? Bool != false,
              let id = r["session_id"] as? String ?? sessionId else { return nil }
        lock.lock()
        // a process it started is a new one: its settings sent again (desired, read when that goes); one found running
        // is converged too
        if r["already_open"] as? Bool != true { generation[id, default: 0] += 1 }
        dirty.insert(id)
        lock.unlock()
        // opened (a configuration, or null): a "not stored" banner from before is past — cleared before its set_config
        // goes, so a refusal of that one stays shown
        mutate(id) { $0.settingsRefused = nil }
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
        openedHere.insert(id)
        endedByApp.remove(id)
        idleClosed.remove(id)
        lock.unlock()
        // the open reply: converged now (desired read when its set_config goes) — off → null, turned on meanwhile or
        // saved since → the settings now, before anything else is written to it
        converge(id)
        return id
    }

    /// Opens a session again whose process ended without the app asking, with desired() read at the open; true when it
    /// is open, or did not end. `onlyOpenedHere`: only a session this client opened (a watch does not bring back sessions
    /// it merely saw).
    @discardableResult
    func reopenIfExited(_ sessionId: String, onlyOpenedHere: Bool = false) -> Bool {
        lock.lock()
        let exited = states[sessionId]?.exited != nil
        let mine = openedHere.contains(sessionId)
        let ended = endedByApp.contains(sessionId), idle = idleClosed.contains(sessionId)
        lock.unlock()
        guard exited else { return true }
        // (a watch does not bring back a session the helper closed for being idle: the next send does)
        if ended || (onlyOpenedHere && (!mine || idle)) { return false }
        return open(sessionId: sessionId) != nil
    }

    /// The id the app gives the user's words it sends (say, cua, steer): the session gives it back on what became of
    /// them (harness#57). Tests set their own.
    var newClientId: () -> String = { "c_" + UUID().uuidString.lowercased() }      // unique for the session's life (harness #59)

    /// Blocks while it reopens an ended session (up to a minute): call it off the main thread.
    func send(_ control: SessionControl, to sessionId: String) -> SendResult { send(control, to: sessionId, clientId: nil) }

    /// `clientId`: the words' id — when they are sent again (resend), or chosen by the sender (a GoalRun's cua, which
    /// it matches a refusal by); else new words get one.
    func send(_ control: SessionControl, to sessionId: String, clientId: String?) -> SendResult {
        let serial = sessionLock(sessionId)
        serial.lock(); defer { serial.unlock() }
        let s = state(sessionId)
        // a steer names its task first — the one running now — so that, refused for a card, its bubble still goes to that
        // task once the card is answered (#107 delta review of 7f09c1b: named after the card check, it was "task ended"
        // for good); a resend never goes to another task
        var control = control
        if case .steer(let t, nil) = control, let r = s.runningTask?.runId { control = .steer(t, runId: r) }
        // Every message the user submits ends in exactly one place: taken by the session (outbox, queue, history), or
        // an unsent bubble in the outbox with its reason, to send again or remove — never dropped, never put back over
        // a newer draft (#107 review at c0dbe96: a card that came between Enter and the send refused the words before
        // they were held, and the composer had a new draft: they were nowhere). A refusal before the words are
        // written holds them unsent here; one after, `notSent` / the session's refusal does the same.
        let refusedBeforeHeld = { [self] (why: String) -> SendResult in
            if let w = control.words, !w.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).isEmpty {
                let id = clientId ?? newClientId()
                mutate(sessionId) { st in
                    if st.taken.contains(id) { return }
                    if let i = st.outbox.firstIndex(where: { $0.id == id }) { st.outbox[i].sending = false; st.outbox[i].refused = why }
                    else { st.outbox.append(Outgoing(id: id, text: w.text, control: w.control, sending: false, refused: why, original: control)) }
                }
            }
            return .refused(why)
        }
        if control.isTyping && !s.composerEnabled { return refusedBeforeHeld("card_open") }
        if case .answer(let a, _) = control, let why = Self.refusal(a, in: s) { return .refused(why) }
        if case .reask(let r) = control, let why = Self.reaskRefusal(r, in: s) { return .refused(why) }
        if s.exited != nil, let why = Self.goneWithProcess(control, in: s) { return refusedBeforeHeld(why == "no task is running" ? "task_ended" : why) }
        if case .steer(_, nil) = control { return refusedBeforeHeld("task_ended") }    // no task to name: not sent
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
        // the model off (now, not when the send began): a control that needs it is not written; the words stay the app's
        let modelGone = { [self] () -> SendResult? in
            // (read now, as the line goes: never at the time the work was queued)
            guard Self.needsModel(control, in: state(sessionId)) && modelOff else { return nil }
            if let id = words { mutate(sessionId) { st in if let i = st.outbox.firstIndex(where: { $0.id == id }) { st.outbox[i].sending = false; st.outbox[i].refused = "no_model" } } }
            return .refused("no_model")
        }
        if let r = modelGone() { return r }
        if s.exited != nil {
            guard reopenIfExited(sessionId) else { return notSent(.unavailable) }
            // (an exit heard while the open request was out may have made the word unsent: it is the new process's —
            // the next one's, if it was held so and no start was heard since)
            if let id = words { mutate(sessionId) { st in if let i = st.outbox.firstIndex(where: { $0.id == id }) { st.outbox[i].sending = true; st.outbox[i].refused = nil; st.outbox[i].toNextProcess = st.awaitingStart || (heldNext && st.starts == startsAtHold) } } }
            // taken while the open blocked (its stored line replayed meanwhile): nothing to send
            if let id = words, stillOurs(id, in: sessionId) == false { return .refused("taken") }
            if let r = modelGone() { return r }
        }
        var r = requestLine(sessionId, line)
        // the helper holds cloud models off (from another window, another app, or a lost "on"): refused, the words
        // stay the app's; and if that is not the app's switch, the helper is told again
        let helperNoModel = { [self] () -> SendResult? in
            guard r?["code"] as? String == "no_model" else { return nil }
            if let id = words { mutate(sessionId) { st in if let i = st.outbox.firstIndex(where: { $0.id == id }) { st.outbox[i].sending = false; st.outbox[i].refused = "no_model" } } }
            helperSays(modelsOff: true)
            return .refused("no_model")
        }
        if let n = helperNoModel() { return n }
        // the process ended and the exit line never reached this app (it was not watching, or the helper restarted):
        // the session reads as exited here too; it is opened again once and the line sent again — unless the app ended
        // it, or the line was for what went with the process (a stop, a steer, a card's answer: never opens a session)
        if r?["code"] as? String == "not_open" {
            if state(sessionId).exited == nil { feed(ProtocolLine(sessionId: sessionId, event: .sessionExit(HelperSessionExit(code: nil)))) }
            if let why = Self.goneWithProcess(control, in: state(sessionId)) { return notSent(.refused(why)) }
            lock.lock()
            let ended = endedByApp.contains(sessionId)
            lock.unlock()
            guard !ended, open(sessionId: sessionId) != nil else { return notSent(.unavailable) }
            if let id = words { mutate(sessionId) { st in if let i = st.outbox.firstIndex(where: { $0.id == id }) { st.outbox[i].sending = true; st.outbox[i].refused = nil; st.outbox[i].toNextProcess = st.awaitingStart || st.starts == startsAtHold } } }
            // taken while the open blocked: nothing to send again
            if let id = words, stillOurs(id, in: sessionId) == false { return .refused("taken") }
            if let r = modelGone() { return r }
            r = requestLine(sessionId, line)
            if let n = helperNoModel() { return n }
        }
        guard let r, r["ok"] as? Bool != false else { return notSent(.unavailable) }
        // (sent: the words stay in the outbox, sending, until the session takes or refuses them)
        return .sent
    }

    /// Whether the words are still the app's to send (in the outbox, not taken by the history), read under the lock
    /// after a step that blocked (a reopen): a replay that came meanwhile may have taken them.
    private func stillOurs(_ id: String, in sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let st = states[sessionId] else { return false }
        return !st.taken.contains(id) && st.outbox.contains { $0.id == id }
    }

    /// Why a control is moot once the session's process ended (it was for the task or the card that went with it), or
    /// nil when a new process can take it (say, cua, retry, the queue's controls, attach).
    static func goneWithProcess(_ control: SessionControl, in s: SessionState) -> String? {
        switch control {
        case .stop: return "the session is not running"
        case .steer: return s.runningTask == nil ? "no task is running" : nil
        case .answer(let a, _): return refusal(a, in: s)
        case .reask(let r): return reaskRefusal(r, in: s)
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

    /// Words whose sender gave up on them (a GoalRun that is over: its cua): dropped now if not sending, and never shown
    /// as a bubble nor resent after — whatever later makes them unsent (a refusal, the process's end).
    func retire(_ id: String, in sessionId: String) {
        mutate(sessionId) { st in
            st.retired.insert(id)
            st.outbox.removeAll { $0.id == id && !$0.sending }
        }
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
    func answer(_ a: CardAnswer, in sessionId: String, reqId: String? = nil) -> SendResult { send(.answer(a, reqId: reqId), to: sessionId) }

    /// A click on a card's button: it answers the button's own card (its run_id and ask_id), and is sent only while
    /// that card is the open one (or that run's result card is answerable): a stale card's button never answers a new
    /// card, however alike their options.
    func click(_ button: CardModel.Button, in sessionId: String) -> SendResult { answer(CardModel.answer(button), in: sessionId) }

    /// Ends the session's process, if the helper finds it idle (else `not_idle`, and nothing changes here). Marked
    /// ended by the app before the request (its exit line may come before the reply: a watch must not reopen it then),
    /// and unmarked when the helper did not end it (a refused end must not keep it from opening again) — as `delete`.
    func end(_ sessionId: String) -> Bool {
        lock.lock()
        let was = endedByApp.contains(sessionId)
        endedByApp.insert(sessionId)
        lock.unlock()
        guard let r = transport.request(Request.end(sessionId: sessionId)), r["ok"] as? Bool != false else {
            if !was { lock.lock(); endedByApp.remove(sessionId); lock.unlock() }
            return false
        }
        return true
    }

    /// The sessions this client knows to have a process, or one coming: running (no exit heard), awaiting a start,
    /// being opened.
    func liveIds() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return liveIdsLocked()
    }
    private func liveIdsLocked() -> [String] {
        let live = states.filter { $0.value.exited == nil || $0.value.awaitingStart }.map(\.key)
        return Set(live).union(opening).subtracting(deleted).sorted()
    }

    /// For a client in a test (no `settingsSource`): the settings stored (`adoptSettings`), the switch, and every live
    /// session converged. The app's shell only says "converge" (convergeAll): it never hands settings over.
    func reconcile(config: String?, lang: String?, off: Bool) {
        adoptSettings(config: config, lang: lang)
        modelOff = off
        convergeAll()
    }

    /// Every session with a process (or one coming) marked dirty and converged — a save (off the main thread: one
    /// request per session).
    func convergeAll() {
        let ids = liveIds()
        lock.lock(); for id in ids { dirty.insert(id) }; lock.unlock()
        for id in ids { converge(id) }
    }
    /// convergeAll on this client's serial queue (from a callback that must not wait: ModelsOffSync's).
    func convergeAllLater() {
        for id in liveIds() { reconcileSession(id) }
    }

    /// A trigger for one session (a watch's running list, a process's start, its first line here, a refusal, a row that
    /// is not desired): dirty, and converged on this client's own serial queue (`reconciling`).
    func reconcileSession(_ id: String) {
        lock.lock(); dirty.insert(id); lock.unlock()
        reconciling.enter()
        reconcileWork.soon { [weak self] in
            defer { self?.reconciling.leave() }
            self?.converge(id)
        }
    }
    private let reconcileQueue = DispatchQueue(label: "ai.deskmind.session.reconcile")
    /// Where reconciles run (the app: the serial queue above; a test: its steps, and it waits by running them, not on
    /// `reconciling`).
    var reconcileWork: DeferredWork
    /// Where a retry waits for its time (the app: a global queue; a test: its steps).
    var retryWork: DeferredWork = .queue(.global())
    /// Reconciles under way (tests wait on it).
    let reconciling = DispatchGroup()

    /// The one rule (see "settings" above): a live, dirty session with no send in flight is sent desired() — read now —
    /// at its current generation. The sender handles the reply: clean (ok, busy) at the same generation; dirty again
    /// meanwhile, or a reply from an old process: sent again, on this thread; failed: dirty, retried after a backoff.
    /// Safe from any thread but the main one.
    func converge(_ id: String) { converge(id, retry: false) }

    /// `retry`: the session's retry chain, its time come — handed over to this converge in the same step that takes the
    /// session, so that no moment shows it dirty with neither a send in flight nor a retry waiting (deskmind#112: a
    /// quiescence check read that moment, after the timer's removal and before the send).
    private func converge(_ id: String, retry: Bool) {
        var retry = retry
        while true {
            // take the session: live, dirty, nothing in flight
            lock.lock()
            if retry {
                retry = false
                guard retryScheduled.remove(id) != nil else { lock.unlock(); return }          // (cancelled: exit, delete)
                if !liveIdsLocked().contains(id) { retryDelay[id] = nil; lock.unlock(); return }
            }
            guard isLiveLocked(id), inFlight[id] == nil, dirty.contains(id) else { lock.unlock(); return }
            let gen = generation[id, default: 0]
            inFlight[id] = gen; dirty.remove(id)
            let attempt = nextAttempt.removeValue(forKey: id) ?? 1
            lock.unlock()
            // the switch on its way to the helper (it may be turning off): no configuration until its ack, which converges
            // every session — a null goes at once. Counted with the sync before the switch is read, so a push begun after
            // this waits for this send (never a configuration after models.off).
            let gated = modelsSync.beginConfigSend()
            // ONE read: the settings and the switch together (#107 review at 9c59a1f: the switch read twice — off for the
            // value, on for the check — turned a null of "off" into "nothing configured", and nothing was scheduled)
            let snap = snapshot()
            afterSnapshot?(id)
            let outcome: ConvergeOutcome
            if snap.off {
                outcome = .sent(sendConfig(id, config: nil, lang: snap.lang, attempt: attempt))
            } else if snap.config == nil {
                outcome = .nothingToSend
            } else if !gated {
                outcome = .blocked
            } else {
                outcome = .sent(sendConfig(id, config: snap.config, lang: snap.lang, attempt: attempt))
            }
            if gated { modelsSync.endConfigSend() }
            switch release(id, gen: gen, acted: snap, outcome: outcome, attempt: attempt) {
            case .done: return
            case .again: continue
            case .retry: retryLater(id); return
            }
        }
    }

    /// A test's seam: called in a converge right after its one read, before it sends (nil in the app).
    var afterSnapshot: ((String) -> Void)?

    /// What desired() and the switch are, read together.
    private struct Snapshot: Equatable { var config: String?; var lang: String?; var off: Bool }
    private func snapshot() -> Snapshot {
        let off = modelOff
        let d = desired()
        return Snapshot(config: d.config.map(Self.normalizeConfig), lang: d.lang, off: off)
    }
    private enum ConvergeOutcome { case sent(ConfigSend), nothingToSend, blocked }
    private enum AfterRelease { case done, again, retry }

    /// The one way out of a converge that took a session (in flight): the slot cleared, the outcome recorded, and — the
    /// family of "dirty, nothing scheduled" exits closed in one place (#107 reviews at 187ae8e, 9c59a1f) — the settings
    /// and the switch read again: changed since the read, or dirty, it goes on (now, or after a backoff); never left
    /// dirty with nothing in flight and no timer, except "nothing configured" with nothing changed (only a save makes
    /// settings known, and a save converges every session).
    private func release(_ id: String, gen: Int, acted: Snapshot, outcome: ConvergeOutcome, attempt: Int) -> AfterRelease {
        lock.lock()
        if inFlight[id] == gen { inFlight[id] = nil }
        var failed = false
        switch outcome {
        case .nothingToSend, .blocked:
            dirty.insert(id); if attempt > 1 { nextAttempt[id] = attempt }
        case .sent(let r):
            // a reply from a process that is gone: what the new one runs is unknown — sent again. (A guard, not
            // load-bearing: every generation bump also sets dirty.)
            if generation[id, default: 0] != gen { dirty.insert(id) }
            if r == .failed { dirty.insert(id); failed = true } else { retryDelay[id] = nil }
        }
        lock.unlock()
        let now = snapshot()
        lock.lock()
        if now != acted { dirty.insert(id) }
        let owed = dirty.contains(id) && isLiveLocked(id)
        lock.unlock()
        guard owed else { return .done }
        if failed { return .retry }
        switch outcome {
        case .nothingToSend:
            return now != acted ? .again : .done
        case .blocked:
            return !modelsSync.isPending && modelsSync.helperHoldsOff != true ? .again : .retry
        case .sent:
            return .again
        }
    }

    /// Live sessions left dirty with nothing in flight and no retry waiting — what must never be (tests check it at
    /// quiescence).
    var settingsStranded: [String] {
        lock.lock(); defer { lock.unlock() }
        return dirty.filter { isLiveLocked($0) && inFlight[$0] == nil && !retryScheduled.contains($0) }.sorted()
    }

    /// Live for settings: a process running, or one coming whose start is heard (opening with no start: its reply and its
    /// start converge it).
    private func isLiveLocked(_ id: String) -> Bool {
        let st = states[id]
        let started = st.map { $0.exited == nil || $0.awaitingStart } ?? false
        return !deleted.contains(id) && (started || (st == nil && !opening.contains(id)))
    }

    /// The first wait before a failed send is tried again (doubling, at most 30 s; tests make it short).
    var retryBase: Double = 0.25
    /// Converge retries waiting (tests wait for none).
    var retriesPending: Int { lock.lock(); defer { lock.unlock() }; return retryScheduled.count }

    /// One retry chain per session: a failed send while one waits adds none.
    private func retryLater(_ id: String) {
        lock.lock()
        if retryScheduled.contains(id) { lock.unlock(); return }
        retryScheduled.insert(id)
        let delay = min(30, (retryDelay[id] ?? retryBase) * 2)
        retryDelay[id] = delay
        lock.unlock()
        // (not in `reconciling`: a retry waits for its time, and a helper that never answers is retried for as long as
        // the session lives — quiescence is not waiting for it)
        retryWork.after(delay) { [weak self] in self?.converge(id, retry: true) }
    }

    /// The session's process is gone (exit, delete): nothing owed to it — its next process opens with desired().
    private func forgetSettings(_ id: String) {
        dirty.remove(id); inFlight[id] = nil; nextAttempt[id] = nil; retryScheduled.remove(id); retryDelay[id] = nil
        echoResent[id] = nil
    }

    /// Sends a session these settings (a test's own: the app converges) — set_config, harness#64: applied in place to
    /// its next model turns, no restart; `config` nil: no model at all. With cloud models off, null whatever is given.
    /// True when sent (or its session is not open: its next process opens with desired()).
    @discardableResult
    func setConfig(_ sessionId: String, config: String?, lang: String?) -> Bool {
        let serial = sessionLock(sessionId)
        serial.lock(); defer { serial.unlock() }
        let wire = configLock(sessionId)
        wire.lock(); defer { wire.unlock() }
        let r = sendConfig(sessionId, config: modelOff ? nil : config, lang: lang, attempt: 1)
        return r != .failed
    }

    private enum ConfigSend { case sent, notOpen, failed }

    /// The set_config line itself, the session's `configLock` held by the caller (one per session on the wire at a time).
    private func sendConfig(_ sessionId: String, config: String?, lang: String?, attempt: Int) -> ConfigSend {
        let cid = newClientId()
        lock.lock()
        // (what it applied is known only from its answer: session.config, or busy — applied, not stored)
        pendingConfigs[cid] = PendingConfig(sessionId: sessionId, config: config, lang: lang, attempt: attempt)
        ownConfigs[sessionId, default: []].append(cid)
        if ownConfigs[sessionId]!.count > 32 { ownConfigs[sessionId]!.removeFirst() }
        lock.unlock()
        var line = SessionControl.setConfig(config: config, lang: lang).line
        line["client_id"] = cid
        let r = requestLine(sessionId, line)
        if r?["ok"] as? Bool != false && r != nil { return .sent }
        // not written (no answer, not open, refused): what it applied is unknown
        lock.lock(); pendingConfigs[cid] = nil; lock.unlock()
        if r?["code"] as? String == "no_model" { helperSays(modelsOff: true); return .notOpen }
        return r?["code"] as? String == "not_open" ? .notOpen : .failed
    }

    /// A control line to the helper; `busy_ending` (the helper is deciding whether the session ends: its process is
    /// still there) is sent again a few times rather than read as the process gone.
    private func requestLine(_ sessionId: String, _ line: [String: Any]) -> [String: Any]? {
        var r = transport.request(Request.send(sessionId: sessionId, line: line))
        var tries = 0
        while r?["code"] as? String == "busy_ending" && tries < 5 {
            tries += 1
            usleep(200_000)
            r = transport.request(Request.send(sessionId: sessionId, line: line))
        }
        return r
    }

    /// Tells the helper whether cloud models are off (models.off): it holds that for every session it runs, whichever
    /// client — nulls the running ones at once, starts new ones with null, refuses what needs a model. Sent where the
    /// engine setting is written (both windows) and when the app connects. True when the helper took it.
    @discardableResult
    static func setModelsOff(_ off: Bool, via transport: SessionTransport = HelperSessionTransport()) -> Bool {
        transport.request(Request.modelsOff(off))?["ok"] as? Bool == true
    }

    /// For a client in a test (no `settingsSource`): the settings stored. Nothing is sent here (reconcile / converge).
    func adoptSettings(config: String?, lang: String?) {
        lock.lock(); stored = (config, lang); lock.unlock()
    }

    /// Asks the helper for a new process for the session, so that a new key reaches it: a process reads its keys when
    /// it starts (the rest of the settings go in place, `setConfig`). The session decides when (the helper's
    /// end_if_idle: now if it is idle, else asked again once it may be — never under a reply, a queue, a task or a
    /// recovery); this client only asks, after any send it made before (one request per session at a time). Not an
    /// `end`: the next send opens it again, with the newest settings.
    /// What the next process opens with is desired(), read at that open: a restart carries no settings.
    @discardableResult
    func restart(_ sessionId: String) -> Bool {
        let serial = sessionLock(sessionId)
        serial.lock(); defer { serial.unlock() }
        lock.lock()
        endedByApp.remove(sessionId)
        lock.unlock()
        guard let r = transport.request(Request.restart(sessionId: sessionId)) else { return false }
        return r["ok"] as? Bool != false || r["code"] as? String == "not_open"
    }

    /// Reads a session's history from the helper's stored log (session.history): no process is started. A session
    /// with no process running there reads as exited (its tasks that never ended were cut off). False when the helper
    /// could not (an older helper without the op: open it instead).
    func history(_ sessionId: String, markExit: Bool = true) -> Bool { readHistory(sessionId, markExit: markExit).ok }

    /// session.history, the last stored seq it says, and whether a process of it runs.
    private func readHistory(_ sessionId: String, markExit: Bool) -> (ok: Bool, lastSeq: Int?, open: Bool?) {
        let s = state(sessionId)
        var runs: [String: Int] = [:]
        for t in s.tasks { runs[t.runId] = t.lastSeq }
        guard let r = transport.request(Request.history(sessionId: sessionId, after: s.lastSeq, runs: runs)), r["ok"] as? Bool == true,
              let lines = r["lines"] as? [[String: Any]] else { return (false, nil, nil) }
        for l in lines { feed(l) }
        // no process for it here: read as exited only while the watch is up (a helper restarting has none yet; the
        // watch's helper.watching says which ran when it is back)
        lock.lock(); let down = watchDown; lock.unlock()
        if markExit, !down, r["open"] as? Bool == false, state(sessionId).exited == nil {
            lock.lock(); idleClosed.insert(sessionId); lock.unlock()
            feed(ProtocolLine(sessionId: sessionId, event: .sessionExit(HelperSessionExit(code: nil, lastSeq: (r["last_seq"] as? NSNumber)?.intValue))))
        }
        return (true, (r["last_seq"] as? NSNumber)?.intValue, r["open"] as? Bool)
    }

    /// Deletes the session: the helper ends its process and removes its history from this Mac (session.delete; it
    /// refuses while a task of the session runs). The session leaves this client's states, and lines that still come
    /// of it are left. nil when deleted, else why not (the helper's code).
    func delete(_ sessionId: String) -> String? {
        lock.lock()
        endedByApp.insert(sessionId)        // its exit is expected: never opened again
        lock.unlock()
        guard let r = transport.request(Request.delete(sessionId: sessionId)) else {
            lock.lock(); endedByApp.remove(sessionId); lock.unlock()
            return "unavailable"
        }
        guard r["ok"] as? Bool != false else {
            lock.lock(); endedByApp.remove(sessionId); lock.unlock()
            return r["code"] as? String ?? "refused"
        }
        lock.lock()
        deleted.insert(sessionId)
        states[sessionId] = nil
        openedHere.remove(sessionId)
        forgetSettings(sessionId); ownConfigs[sessionId] = nil
        lock.unlock()
        return nil
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
            // helper.watching's `open` (what runs) is the truth for every session this client knew when it connected:
            // each one not in it reads as exited, opened here or not (#107 review: one opened by a history read, its
            // process gone while the watch was down, kept "replying" for good). `opened` decides only reopening.
            let knownBefore = Set(states.keys).subtracting(deleted)
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
                    self.lock.lock(); self.watchDown = false; self.lock.unlock()
                    if let theirs = obj["models_off"] as? Bool { self.helperSays(modelsOff: theirs) }
                    // a session with no process now gets no replay from the watch: what it stored while this app was
                    // away (a reply finished, a task ended) is read from its log after the cursor, through the reducer
                    // (#107 review: the cache is never taken as whole) — off this thread, so the live lines go on
                    // meanwhile; not for one whose last stored seq (the helper's `last_seq`, for a process that ended
                    // there) is the cursor already. An older helper without the op: nothing read.
                    let stored = (obj["last_seq"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
                    let behind = self.knownIds().subtracting(open).filter { stored[$0] == nil || stored[$0] != self.state($0).lastSeq }
                    let gone = knownBefore.subtracting(open), idle = Set(obj["idle"] as? [String] ?? [])
                    // the exit of one whose stored lines are being read comes after them (backfill); the others' now,
                    // at the last seq the helper says it stored, when it says
                    self.backfill(behind, exits: gone, idle: idle)
                    self.notRunning(gone.subtracting(behind), idle: idle, lastSeqs: stored)
                    // each running session, known before or not: reconciled to the settings now
                    for id in open { self.reconcileSession(id) }
                } else {
                    self.feed(obj)
                }
                if overdue() { rewatch = true; return false }
                return true
            }, onIdle: {
                if overdue() { rewatch = true; return false }
                return true
            })
            lock.lock(); watchDown = true; lock.unlock()
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

    /// Sessions this client knows that the helper does not run (helper.watching): their process, if any, ended unheard
    /// (the idle reclaim, a crash, a helper restart). They read as exited (a reply in progress interrupted, a running
    /// task cut off); those opened here are opened again on the next watch, any of them on the next send.
    /// `generations`: only a session still at the process generation these were read at (no open or start since).
    private func notRunning(_ ids: Set<String>, idle: Set<String> = [], lastSeqs: [String: Int] = [:], generations: [String: Int]? = nil) {
        for id in ids {
            let line = ProtocolLine(sessionId: id, event: .sessionExit(HelperSessionExit(code: nil, lastSeq: lastSeqs[id], idle: idle.contains(id) ? true : nil)))
            feed(line) { [self] in
                // (under the lock the exit is applied under)
                if endedByApp.contains(id) || states[id]?.exited != nil { return false }
                if let g = generations, generation[id] != g[id] { return false }
                if idle.contains(id) { idleClosed.insert(id) }
                return true
            }
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
    func feed(_ line: ProtocolLine) -> SessionReducer.Applied { feed(line, onlyIf: nil) }

    /// `onlyIf`: checked under the lock the line is applied under; false: not applied.
    @discardableResult
    private func feed(_ line: ProtocolLine, onlyIf: (() -> Bool)?) -> SessionReducer.Applied {
        guard let id = line.sessionId else { return .ignored }
        lock.lock()
        if deleted.contains(id) { lock.unlock(); return .ignored }
        if let onlyIf, !onlyIf() { lock.unlock(); return .ignored }
        if case .sessionExit(let e) = line.event, e.idle == true { idleClosed.insert(id) }
        // the answer to a set_config of this app's: stored (session.config), or not (busy: sent once more; then, or
        // bad_config, shown)
        var busyAgain = false, notApplied: String?
        switch line.event {
        case .sessionConfig(let e): if let c = e.clientId { pendingConfigs[c] = nil }
        case .sessionError(let e) where e.control == "set_config":
            if let c = e.clientId, let p = pendingConfigs.removeValue(forKey: c) {
                // busy: it took effect, was not stored — sent once more (dirty); a second busy, or bad_config: shown
                if e.code == "busy" && p.attempt < 2 { nextAttempt[id] = 2; busyAgain = true } else { notApplied = e.code }
            }
        default: break
        }
        let first = states[id] == nil
        var after = states[id] ?? SessionState(sessionId: id)
        let settingsBefore = after.settings
        states[id] = nil                                    // the reducer works on the only copy (no copy-on-write)
        let applied = SessionReducer.apply(&after, line)
        if let notApplied { after.settingsRefused = notApplied.isEmpty ? "busy" : notApplied }
        states[id] = after
        // the session's settings as its stream has them now, when they changed — only what the reducer took, in order
        // (a duplicate changes nothing; a held row counts once its gap fills)
        let settingsNow: SessionConfigEvent? = after.settings != settingsBefore ? after.settings : nil
        // a process's start (a new one: generation; its settings sent again) or end (nothing owed to it)
        var started = false
        if applied == .applied {
            switch line.event {
            case .sessionStart:
                generation[id, default: 0] += 1; started = true
                pendingConfigs = pendingConfigs.filter { $0.value.sessionId != id }    // (sent to a process that is gone)
            case .sessionExit:
                if after.exited != nil {
                    pendingConfigs = pendingConfigs.filter { $0.value.sessionId != id }
                    forgetSettings(id)
                }
            default: break
            }
        }
        // a refusal for having no model while the switch is on: the helper told again, and the settings sent (a refusal of
        // a set_config is its own answer's echo, not a new one)
        var noModelHere = false
        if case .sessionError(let e) = line.event, e.code == "no_model", e.control != "set_config", !off { noModelHere = true }
        lock.unlock()
        if noModelHere { helperSays(modelsOff: true) }
        // the triggers here (see "settings" above): a process start, its first line here, a no_model, a busy, a row whose
        // settings are not desired (our own send's echo is: no loop)
        var trigger = started || (first && after.exited == nil) || noModelHere || busyAgain
        if !trigger, let now = settingsNow, after.exited == nil {
            let d = desiredNow()
            if now.config.map(Self.normalizeConfig) != d.config || (d.lang != nil && now.lang != d.lang) {
                lock.lock()
                if let c = now.clientId, ownConfigs[id]?.contains(c) == true {
                    // our own echo, not desired (a normalisation not shared): once per (desired, generation)
                    let g = generation[id, default: 0]
                    let key = "\(g)|\(d.config ?? "\u{0}")|\(d.lang ?? "")"
                    // (keys of older generations can no longer match: pruned)
                    echoResent[id] = echoResent[id, default: []].filter { $0.hasPrefix("\(g)|") }
                    trigger = echoResent[id, default: []].insert(key).inserted
                } else {
                    trigger = true                                  // (not ours: the helper's null, another client's)
                }
                lock.unlock()
            }
        }
        if trigger { reconcileSession(id) }
        // (no whole-state comparison per line: in a long session that cost more than the line itself)
        if applied == .applied || applied == .held { onChange?(id, after) }
        if case .sessionError(let e) = line.event, line.seq == nil, e.control == "respond" || e.control == "answer", e.reqId != nil {
            onAnswerRefusal?(id, e)
        }
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
    /// Whether a control would make the model work, read against the session's state as it is sent. A card's answer
    /// resumes the task (the model with it) unless it is the way out (cancel): its option's kind, from the card; words,
    /// an option the app cannot find and an unknown kind count as resuming (fail closed). A result card's answer (undo,
    /// OK) never does: the session undoes from its receipts.
    static func needsModel(_ c: SessionControl, in s: SessionState) -> Bool {
        guard case .answer(let a, _) = c else { return c.needsModel }
        switch a {
        case .respond: return false
        case .text: return true
        case .option(let r, let ask, let i):
            guard let card = s.task(r)?.cards.first(where: { $0.askId == ask }), card.card.options.indices.contains(i) else { return true }
            return card.card.options[i].kind != "cancel"
        }
    }

    /// Why 「现在回答」 must not be sent, or nil: only for a task that still runs and waits on a card that expired.
    static func reaskRefusal(_ runId: String, in s: SessionState) -> String? {
        guard let task = s.task(runId) else { return "no such task" }
        guard task.running else { return "the task has ended" }
        guard task.expiredCard != nil else { return "no card of the task expired" }
        return nil
    }

    static func refusal(_ a: CardAnswer, in s: SessionState) -> String? {
        guard let task = s.task(a.runId) else { return "no such task" }
        if let askId = a.askId {
            guard let open = task.openCard else { return "no card is open" }
            if open.askId != askId { return "stale card: \(askId) is not the open card \(open.askId)" }
            return nil
        }
        // the result card's one state (TaskState.resultCardState): answerable only while open; its undo only while the
        // harness offers it
        guard task.resultCard != nil else { return "no result card" }
        let state = task.resultCardState
        guard state.isOpen else { return "the result card is not open (\(state))" }
        if case .respond(_, let i) = a, task.resultCard?.options.indices.contains(i) == true, task.resultCard?.options[i].kind == "undo", !state.undoEnabled {
            return "undo is not offered"
        }
        return nil
    }
}
