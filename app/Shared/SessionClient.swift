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
        DeskMindIPC.request(body, timeout: body["op"] as? String == SessionClient.Op.open ? 60 : 20)
    }
    func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool {
        DeskMindIPC.streamWhile(body, idle: SessionClient.idleTick, onIdle: onIdle, onLine)
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
    init(transport: SessionTransport, current: @escaping () -> Bool) { self.transport = transport; self.current = current }

    /// Tells the helper the switch (as it is when the send goes), until it acks; `then` once it has.
    func push(then: (() -> Void)? = nil) {
        lock.lock(); gen += 1; let g = gen; pending = true; if let then { waiting.append(then) }; lock.unlock()
        queue.async { [weak self] in self?.attempt(g, delay: self?.firstDelay ?? 0.25) }
    }

    private func attempt(_ g: Int, delay: Double) {
        lock.lock(); let latest = g == gen; lock.unlock()
        guard latest else { return }                         // (a newer push carries on)
        let off = current()
        let r = transport.request(SessionClient.Request.modelsOff(off))
        // a helper without the op holds no bit: nothing to keep equal
        let acked = r?["ok"] as? Bool == true || r?["error"] as? String == "unknown op"
        if acked && current() == off {
            lock.lock()
            var run: [() -> Void] = []
            if g == gen { pending = false; run = waiting; waiting = [] }
            lock.unlock()
            for f in run { f() }
            return
        }
        // not acked, or the switch moved while it went: again (at once if it only moved)
        let next = acked ? 0 : delay
        queue.asyncAfter(deadline: .now() + next) { [weak self] in self?.attempt(g, delay: min(delay * 2, 30)) }
    }

    /// The switch as it is now (where every path reads it).
    func switchOff() -> Bool { current() }
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
        let timeout = timeout ?? settleTimeout
        let until = Date().addingTimeInterval(timeout)
        while Date() < until {
            lock.lock(); let busy = pending; lock.unlock()
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
    case answer(CardAnswer)
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
        case .answer(let a): return a.control
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

    /// A control that makes the model work (say, cua, retry, steer, queue_send_now): never written while the model is
    /// off (the client's `modelOff`; the session would refuse it no_model).
    var needsModel: Bool {
        switch self { case .say, .cua, .retry, .steer, .queueSendNow: return true; default: return false }
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
    /// Listed by the helper only for the keys rounds (being spawned, no stored history yet): never a row.
    var new = false

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
        self.new = o["new"] as? Bool ?? false
    }
}

final class SessionClient {
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
    /// What a session this client did not open (one from an earlier launch) is opened again with: the app's current
    /// model config and language (the harness keeps no session's config: without one it would take its own default).
    /// A session this client opened keeps what it was opened with. Set from any thread.
    var defaultConfig: String? {
        get { lock.lock(); defer { lock.unlock() }; return defaults.config }
        set { lock.lock(); defaults.config = newValue; lock.unlock() }
    }
    var defaultLang: String? {
        get { lock.lock(); defer { lock.unlock() }; return defaults.lang }
        set { lock.lock(); defaults.lang = newValue; lock.unlock() }
    }
    private var defaults: (config: String?, lang: String?) = (nil, nil)
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
        get { lock.lock(); defer { lock.unlock() }; return off }
        set { lock.lock(); offStored = newValue; lock.unlock() }
    }
    private var offStored = false
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
        modelsSync.pushOnce { [weak self] in
            guard let self else { return }
            self.lock.lock(); let d = self.defaults, now = self.off; self.lock.unlock()
            self.reconcile(config: d.config, lang: d.lang, off: now)
        }
    }
    /// What each session's current process is known to run with: the last set_config sent to it (or acked), else what
    /// its open line carried; forgotten when the process goes (an unknown with the model off is reconciled to null).
    private var runsWith: [String: (config: String?, lang: String?)] = [:]
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

    /// How a session is opened again: with the settings saved since (adoptSettings, restart), else as this client
    /// opened it, else with the defaults (read under the lock).
    private func reopenSettings(_ sessionId: String) -> (config: String?, lang: String?) {
        reopenWith[sessionId] ?? opened[sessionId] ?? defaults
    }
    /// What each session was opened with, to open it again the same way after its process ended. Only sessions this
    /// client opened: a watch reopens these (and no others).
    private var opened: [String: (config: String?, lang: String?)] = [:]
    /// Settings saved after a session was opened, for its next process (never marks it opened here: #107 re-review,
    /// a settings save then a helper restart reopened every known session, ~80 MB each).
    private var reopenWith: [String: (config: String?, lang: String?)] = [:]
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

    init(transport: SessionTransport = HelperSessionTransport(), modelsSync: ModelsOffSync? = nil) {
        self.transport = transport
        self.injectedSync = modelsSync
        self.modelsSync = modelsSync ?? ModelsOffSync(transport: transport, current: { [weak self] in self?.modelOff ?? false })
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

    /// The sessions as rows: without one the helper lists only because it is being spawned (`new`).
    func list() -> [SessionSummary]? { listWithKeys()?.sessions.filter { !$0.new } }

    /// sessions.list, with the models.env digest now as the helper reads it (its `keys`; nil from an older helper).
    func listWithKeys() -> (sessions: [SessionSummary], keysNow: String?)? {
        guard let r = transport.request(Request.list()), r["ok"] as? Bool != false,
              let items = r["sessions"] as? [[String: Any]] else { return nil }
        return (items.compactMap(SessionSummary.init), r["keys"] as? String)
    }

    /// Opens a session (a new one when `sessionId` is nil); its id, or nil when the helper could not.
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
        if let sessionId { lock.lock(); opening.insert(sessionId); lock.unlock() }
        defer { if let sessionId { lock.lock(); opening.remove(sessionId); lock.unlock() } }
        guard let r = transport.request(Request.open(sessionId: sessionId, config: noModel ? nil : config, lang: lang)), r["ok"] as? Bool != false,
              let id = r["session_id"] as? String ?? sessionId else { return nil }
        // the model as it is now, not as it was when the request went out: off → null; turned on meanwhile → the
        // configuration (the open line carried none); before anything else is written to it
        lock.lock()
        generation[id, default: 0] += 1
        if r["already_open"] as? Bool != true { if noModel { runsWith[id] = nil } else { runsWith[id] = (config, lang) } }  // (none on the line: unknown)
        lock.unlock()
        // opened with the settings now (a configuration, or null): a "not stored" banner from before is past — cleared
        // before its set_config goes, so a refusal of that one stays shown
        mutate(id) { $0.settingsRefused = nil }
        let offNow = modelOff
        if offNow { _ = sendConfig(id, config: nil, lang: lang, attempt: 1) }
        else if noModel { _ = sendConfig(id, config: config ?? defaultConfig, lang: lang, attempt: 1) }
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
        opened[id] = (config, lang)         // (with the model off, what it opens with once it is on again)
        reopenWith[id] = nil                // opened with these now: they are what it opens again with
        endedByApp.remove(id)
        idleClosed.remove(id)
        lock.unlock()
        return id
    }

    /// Opens a session again whose process ended without the app asking, as it was opened (a session this client did
    /// not open — one from an earlier launch — with defaultConfig / defaultLang); true when
    /// it is open, or did not end. `onlyOpenedHere`: only a session this client opened (a watch does not bring back
    /// sessions it merely saw).
    @discardableResult
    func reopenIfExited(_ sessionId: String, onlyOpenedHere: Bool = false) -> Bool {
        lock.lock()
        let exited = states[sessionId]?.exited != nil
        let mine = opened[sessionId] != nil, how = reopenSettings(sessionId)
        let ended = endedByApp.contains(sessionId), idle = idleClosed.contains(sessionId)
        lock.unlock()
        guard exited else { return true }
        // (a watch does not bring back a session the helper closed for being idle: the next send does)
        if ended || (onlyOpenedHere && (!mine || idle)) { return false }
        return open(sessionId: sessionId, config: how.config, lang: how.lang) != nil
    }

    /// The id the app gives the user's words it sends (say, cua, steer): the session gives it back on what became of
    /// them (harness#57). Tests set their own.
    var newClientId: () -> String = { "c_" + UUID().uuidString.lowercased() }      // unique for the session's life (harness #59)

    /// Blocks while it reopens an ended session (up to a minute): call it off the main thread.
    func send(_ control: SessionControl, to sessionId: String) -> SendResult { send(control, to: sessionId, clientId: nil) }

    /// `clientId`: the words' id when they are sent again (resend); new words get one.
    private func send(_ control: SessionControl, to sessionId: String, clientId: String?) -> SendResult {
        let serial = sessionLock(sessionId)
        serial.lock(); defer { serial.unlock() }
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
        // the model off (now, not when the send began): a control that needs it is not written; the words stay the app's
        let modelGone = { [self] () -> SendResult? in
            guard control.needsModel && modelOff else { return nil }
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
            let ended = endedByApp.contains(sessionId), how = reopenSettings(sessionId)
            lock.unlock()
            guard !ended, open(sessionId: sessionId, config: how.config, lang: how.lang) != nil else { return notSent(.unavailable) }
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
        let live = states.filter { $0.value.exited == nil || $0.value.awaitingStart }.map(\.key)
        return Set(live).union(opening).subtracting(deleted).sorted()
    }

    /// The settings as they are now, for every session: remembered for each one's next process (adoptSettings), the
    /// model on or off (`modelOff`), and sent in place to every one with a process or one coming (`liveIds`): its
    /// configuration, or null with the model off. Call it off the main thread (one request per session).
    func reconcile(config: String?, lang: String?, off: Bool) {
        adoptSettings(config: config, lang: lang)
        modelOff = off
        for id in liveIds() { reconcileNow(id, settingsChanged: true) }
    }

    /// Reconciles one session to the settings now, whenever it comes into this client's view with a process (the
    /// watch's running list, a process's start, its first line here) — off the calling thread, one serial queue
    /// (`reconciling`). #107 review: after an app restart with cloud off, a session found running later never got
    /// its null.
    func reconcileSession(_ id: String) {
        reconciling.enter()
        reconcileQueue.async { [weak self] in
            defer { self?.reconciling.leave() }
            self?.reconcileNow(id, settingsChanged: false)
        }
    }
    private let reconcileQueue = DispatchQueue(label: "ai.deskmind.session.reconcile")
    /// Reconciles under way (tests wait on it).
    let reconciling = DispatchGroup()

    /// The one rule: a session with a process (or one coming) runs with the settings now — no model when off, else
    /// its configuration — compared with what it is known to run with (`runsWith`: the last set_config sent to this
    /// process or acked, else what its open line carried; else its stored session.config), never with an old switch.
    /// Unknown with the model on: left (it opened with a configuration of the app's), unless the settings just changed.
    private func reconcileNow(_ id: String, settingsChanged: Bool) {
        lock.lock()
        let live = !deleted.contains(id) && (opening.contains(id) || states[id].map { $0.exited == nil || $0.awaitingStart } ?? true)
        let how = reopenSettings(id), noModel = off
        let have = runsWith[id] ?? states[id]?.settings.map { (config: $0.config, lang: $0.lang) }
        let wantNow: String? = noModel ? nil : how.config
        let underWay = pendingConfigs.values.contains { $0.sessionId == id && $0.config == wantNow && $0.lang == how.lang }
        lock.unlock()
        if underWay { return }                                               // (its answer will say)
        guard live else { return }
        let want: (config: String?, lang: String?) = (noModel ? nil : how.config, how.lang)
        if !noModel && want.config == nil { return }                         // (no configuration to send)
        if let have, have.config == want.config && (want.lang == nil || have.lang == want.lang) { return }
        if have == nil && !noModel && !settingsChanged { return }
        setConfig(id, config: want.config, lang: want.lang)
    }

    /// Sends a live session its settings now (set_config, harness#64): applied in place to its next model turns, no
    /// restart; `config` nil (cloud models off): no model at all — the session stops its running task, and nothing that
    /// needs a model goes on. Remembered for its next process (reopenWith). Never taken as applied until its
    /// session.config: a `busy` refusal (it took effect but was not stored) is sent once more, then shown
    /// (SessionState.settingsRefused), as bad_config is. True when it was sent (or its session is not open: its next
    /// process opens with it).
    @discardableResult
    func setConfig(_ sessionId: String, config: String?, lang: String?) -> Bool {
        let serial = sessionLock(sessionId)
        serial.lock(); defer { serial.unlock() }
        // (a null — cloud models off — is never sent on an open line: what it opens with once they are on again stays)
        lock.lock()
        reopenWith[sessionId] = (config ?? reopenSettings(sessionId).config, lang)
        // the model as it is now, read under the session's lock: a configuration decided before the switch turned off
        // (queued behind its null) goes as null
        let noModel = off
        lock.unlock()
        return sendConfig(sessionId, config: noModel ? nil : config, lang: lang, attempt: 1)
    }

    /// The set_config line itself (the session's serial lock held, or the session just opened).
    private func sendConfig(_ sessionId: String, config: String?, lang: String?, attempt: Int) -> Bool {
        let cid = newClientId()
        lock.lock()
        // (what it runs with is known only from its answer: session.config, or busy — applied, not stored)
        pendingConfigs[cid] = PendingConfig(sessionId: sessionId, config: config, lang: lang, attempt: attempt)
        lock.unlock()
        var line = SessionControl.setConfig(config: config, lang: lang).line
        line["client_id"] = cid
        let r = requestLine(sessionId, line)
        if r?["ok"] as? Bool != false && r != nil { return true }
        if r?["code"] as? String == "no_model" { helperSays(modelsOff: true) }
        // not written (no answer, not open, refused): what it runs with is unknown — the next reconcile sends again
        lock.lock(); pendingConfigs[cid] = nil; runsWith[sessionId] = nil; lock.unlock()
        return r?["code"] as? String == "not_open"
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

    /// The settings changed (either field: the model configuration or the language): every session this client
    /// knows opens again with these, whenever its next process starts — whether or not its process now can end (#107
    /// review: a busy or exited session kept the old ones; a language switch reached only the defaults).
    func adoptSettings(config: String?, lang: String?) {
        lock.lock()
        defaults = (config, lang)
        for id in Set(opened.keys).union(states.keys).union(reopenWith.keys) { reopenWith[id] = (config, lang) }
        lock.unlock()
    }

    /// Asks the helper for a new process for the session, so that a new key reaches it: a process reads its keys when
    /// it starts (the rest of the settings go in place, `setConfig`). The session decides when (the helper's
    /// end_if_idle: now if it is idle, else asked again once it may be — never under a reply, a queue, a task or a
    /// recovery); this client only asks, after any send it made before (one request per session at a time). Not an
    /// `end`: the next send opens it again, with `config` and `lang`.
    @discardableResult
    func restart(_ sessionId: String, config: String?, lang: String?) -> Bool {
        let serial = sessionLock(sessionId)
        serial.lock(); defer { serial.unlock() }
        lock.lock()
        reopenWith[sessionId] = (config, lang)
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
        opened[sessionId] = nil
        reopenWith[sessionId] = nil
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
        var again: PendingConfig?, notApplied: String?
        switch line.event {
        case .sessionConfig(let e): if let c = e.clientId { pendingConfigs[c] = nil }
        case .sessionError(let e) where e.control == "set_config":
            if let c = e.clientId, let p = pendingConfigs.removeValue(forKey: c) {
                // busy: applied in this process, not stored — it runs with it; anything else: unknown
                if e.code == "busy" { runsWith[id] = (p.config, p.lang) } else { runsWith[id] = nil }
                if e.code == "busy" && p.attempt < 2 { again = p } else { notApplied = e.code }
            }
        default: break
        }
        let first = states[id] == nil
        var after = states[id] ?? SessionState(sessionId: id)
        states[id] = nil                                    // the reducer works on the only copy (no copy-on-write)
        let applied = SessionReducer.apply(&after, line)
        if let notApplied { after.settingsRefused = notApplied.isEmpty ? "busy" : notApplied }
        states[id] = after
        // a process's start or end: what it runs with is its own (a start: a new process, reconciled)
        var started = false
        switch line.event {
        case .sessionStart:
            generation[id, default: 0] += 1; started = true
            pendingConfigs = pendingConfigs.filter { $0.value.sessionId != id }    // (sent to a process that is gone)
        case .sessionExit:
            if after.exited != nil { runsWith[id] = nil; pendingConfigs = pendingConfigs.filter { $0.value.sessionId != id } }
        case .sessionConfig(let e): runsWith[id] = (e.config, e.lang)
        default: break
        }
        // nulled while the switch is on (by the helper, unseen here), or a refusal for having no model: repaired —
        // reconciled to the switch, and the helper told it again if it holds otherwise (a refusal of a set_config is
        // its own answer's echo, not a new one)
        var repair = false, noModelHere = false
        switch line.event {
        case .sessionConfig(let e): repair = e.config == nil && !off
        case .sessionError(let e) where e.code == "no_model" && e.control != "set_config": repair = !off; noModelHere = !off
        default: break
        }
        lock.unlock()
        if noModelHere { helperSays(modelsOff: true) }
        // a session that comes into view with a process (its first line here, its process's start): the settings now
        if started || (first && after.exited == nil) || repair { reconcileSession(id) }
        if let p = again {
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                let serial = self.sessionLock(p.sessionId)
                serial.lock(); defer { serial.unlock() }
                // (with the settings as they are now, not as that line had them)
                self.lock.lock(); let how = self.reopenSettings(p.sessionId), noModel = self.off; self.lock.unlock()
                if !self.sendConfig(p.sessionId, config: noModel ? nil : how.config, lang: how.lang, attempt: p.attempt + 1) {
                    self.mutate(p.sessionId) { $0.settingsRefused = "busy" }
                }
            }
        }
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
        if task.resultResponse != nil || task.respond != nil { return "the result card was answered" }
        return nil
    }
}
