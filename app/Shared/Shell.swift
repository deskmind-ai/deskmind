// The 0.5 main window's logic (M1 S3), apart from its views (Main/MainSplitView.swift) so that it is tested without a
// screen: the `ui05.shell` flag; the session list (rows, titles, status dots); what the composer does with Enter and
// ⌘Enter; what each chat item says; and `ShellModel`, the glue between the views and the session client
// (SessionClient: the helper's sessions, the reducer's states).
//
// Owner rules this holds to: the composer never answers a card (a card is answered on the card, by option index and
// ask_id; one that takes words has its own field); a card waits → the composer takes no typing, Stop always works;
// nothing here reads the user's words to decide anything (`/cua` is a command's syntax, matched as such, never a
// keyword in a sentence); a task's end says what its status says, never more (succeeded alone is "done").

import Combine
import Foundation

// MARK: - The flag

/// The new main window (handoff §6, M1): off by default; the View menu's developer switch turns it on. Off, the app is
/// as it was.
enum ShellFlag {
    static let key = "ui05.shell"
    static func isOn(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key) }
}

// MARK: - Model settings saved

/// The model settings were saved — the key file, the service, the configuration — wherever that happened: the 0.5
/// window's sheet, the window as it was, any path that writes them (Main/CloudModel.swift's CloudModelSettings posts it
/// from each of its writers). The app's one ShellModel (`ShellModel.live`) takes it, so what its sessions run with no
/// longer depends on which window saved (#107 review at 5999bd9: a key changed in the old window's settings never
/// reached the live sessions; once the old key was revoked, chat failed for good). Cloud models on or off is not posted
/// here: it has its own single path to the helper (ModelsOffSync, models.off).
enum ModelSettingsSaved {
    static let name = Notification.Name("ai.deskmind.modelSettingsSaved")
    static func post(_ center: NotificationCenter = .default) { center.post(name: name, object: nil) }
}

// MARK: - The composer

/// What Enter and ⌘Enter do in a session's state (handoff §1.3 输入框, §3.4, §3.7).
struct ComposerMode: Equatable {
    /// Typing is taken: false while a card waits (the card is answered on the card).
    var enabled: Bool
    /// A computer task runs: Enter queues (the session holds it until the task is done), ⌘Enter sends it now (steer).
    var taskRunning: Bool
    /// A reply streams and no task runs: Enter sends nothing (the session would refuse it busy); Stop stops the reply.
    var replying: Bool
    /// There is something to stop: a running task, or a reply.
    var canStop: Bool { taskRunning || replying }

    static func of(_ s: SessionState?) -> ComposerMode {
        guard let s else { return ComposerMode(enabled: true, taskRunning: false, replying: false) }
        let task = s.runningTask != nil
        return ComposerMode(enabled: s.composerEnabled, taskRunning: task, replying: !task && s.streamingMessage != nil)
    }

    /// The `/cua` command: the words after it, when the text is that command (it begins with `/cua` and a space or
    /// nothing else). A command's syntax, as a terminal reads one; never a keyword looked for inside a sentence.
    static func cuaCommand(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/cua") else { return nil }
        let rest = t.dropFirst(4)
        guard rest.isEmpty || rest.first!.isWhitespace else { return nil }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The control line Enter (or ⌘Enter, `sendNow`) sends for `text`; nil when it sends nothing (empty, a card
    /// waits, a reply streams, `/cua` with nothing after it). The text stays in the composer then.
    func control(_ text: String, sendNow: Bool) -> SessionControl? {
        guard enabled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if taskRunning {
            // ⌘Enter: to the running task now; Enter: queued by the session (a `/cua` too: one task per session)
            return sendNow ? .steer(text) : .say(text)
        }
        if replying { return nil }
        if let words = Self.cuaCommand(text) { return words.isEmpty ? nil : .cua(words) }
        return .say(text)
    }
}

// MARK: - What the chat says

enum ShellText {
    /// The session's state for the list's subtitle, the right column and VoiceOver (handoff §1.5).
    static func status(_ st: SessionStatus, lang: ResolvedLang) -> String {
        switch st {
        case .waitingForYou(let kind): return L("Waiting for you: %@", cardKind(kind, lang: lang), lang: lang)
        case .cardExpired(let kind): return L("Expired, waiting for you: %@", cardKind(kind, lang: lang), lang: lang)
        case .error(let code): return problem(code, lang: lang)
        case .locked: return L("Stopped: the screen is locked", lang: lang)
        case .stopping: return L("Stopping…", lang: lang)
        case .paused: return L("You're using the Mac, paused", lang: lang)
        case .lookOnly: return L("Checking the result", lang: lang)
        case .acting(let n, let m):
            if let m { return L("Working · step %d of %d", n, m, lang: lang) }
            return n > 0 ? L("Working · step %d", n, lang: lang) : L("Working", lang: lang)
        case .thinking: return L("Thinking…", lang: lang)
        case .done(let at, let stopped):
            if stopped { return L("Stopped", lang: lang) }
            guard let at else { return L("Done", lang: lang) }
            return L("Done · %@", time(at), lang: lang)
        case .idle: return L("Idle", lang: lang)
        }
    }

    static func time(_ t: Double) -> String {
        DateFormatter.localizedString(from: Date(timeIntervalSince1970: t), dateStyle: .none, timeStyle: .short)
    }

    /// A card's kind in words (the card's own text is the harness's, already in the request's language).
    static func cardKind(_ kind: String, lang: ResolvedLang) -> String {
        switch CardModel.Kind(kind) {
        case .plan: return L("approve the plan", lang: lang)
        case .action: return L("confirm before acting", lang: lang)
        case .ambiguity: return L("which one you mean", lang: lang)
        case .missing: return L("a missing detail", lang: lang)
        case .resultCheck: return L("check the result", lang: lang)
        case .cannot: return L("it can't be done as asked", lang: lang)
        case .result: return L("the result", lang: lang)
        case .other: return L("a question", lang: lang)
        }
    }

    /// A card's line in the chat once it is no longer pinned, and the state VoiceOver says first: from its phase alone
    /// (CardStore.phase), the same for every view.
    static func cardLine(_ phase: CardPhase, kind: String, lang: ResolvedLang) -> String {
        let k = cardKind(kind, lang: lang)
        return L("%@: %@", cardState(phase, lang: lang), k, lang: lang)
    }

    /// A card's state in words (handoff §2.2, plan §4.2).
    static func cardState(_ phase: CardPhase, lang: ResolvedLang) -> String {
        switch phase {
        case .open: return L("Waiting for your answer", lang: lang)
        case .pending: return L("Picked, sending in a moment", lang: lang)
        case .sent: return L("Sent, waiting for the task", lang: lang)
        case .answered: return L("Answered", lang: lang)
        case .expired(_, .refused(let why)):
            return why.isEmpty ? L("Expired; answering it now was refused", lang: lang) : L("Expired; answering it now was refused: %@", why, lang: lang)
        case .expired(let late, _):
            return late ? L("Expired; your late answer was not used", lang: lang) : L("Expired: no answer in time", lang: lang)
        case .voided(let why):
            switch why {
            case "steer": return L("No longer needed (you changed the request)", lang: lang)
            case "stop": return L("No longer needed (the task stopped)", lang: lang)
            case "replaced": return L("No longer needed (a new card replaced it)", lang: lang)
            case "session_exit", "executor_exit": return L("No longer needed (the task was interrupted)", lang: lang)
            default: return L("No longer needed (the task ended)", lang: lang)
            }
        }
    }

    /// A task that ended badly, or the model's error, by its code.
    static func problem(_ code: String, lang: ResolvedLang) -> String {
        switch code {
        case "failed": return L("Didn't finish", lang: lang)
        case "environment": return L("The Mac's state didn't allow it", lang: lang)
        case "unconfirmed": return L("Done, but not confirmed. Please check", lang: lang)
        case "interrupted": return L("Interrupted", lang: lang)
        case "no_key": return L("No API key for the model", lang: lang)
        case "key_invalid": return L("The model's service rejected the API key", lang: lang)
        case "quota": return L("The model's service is out of quota or rate-limited", lang: lang)
        case "network": return L("Couldn't reach the model", lang: lang)
        case "bad_config": return L("The model settings don't work", lang: lang)
        default: return L("Something went wrong", lang: lang)
        }
    }

    /// New settings a session did not store (set_config's refusal): busy — they apply in this process now, but its
    /// next process may open with the ones before; bad_config — refused, nothing changed.
    static func settingsRefused(_ code: String, lang: ResolvedLang) -> String {
        code == "bad_config"
            ? L("This conversation refused the new model settings. Check them in the model settings.", lang: lang)
            : L("The new model settings apply now, but may not last if this conversation restarts.", lang: lang)
    }

    /// Why the user's words were not sent (a refusal's code, or the process's end).
    static func unsent(_ code: String?, lang: ResolvedLang) -> String {
        switch code {
        case "busy": return L("Not sent: a reply was still coming", lang: lang)
        case "too_long": return L("Not sent: the message is too long", lang: lang)
        case "computer_busy": return L("Not sent: another conversation is using the Mac", lang: lang)
        case "card_open": return L("Not sent: a card is waiting for your answer", lang: lang)
        case "no_task", "task_ended": return L("Not sent: the task has ended", lang: lang)
        case "exited": return L("Not sent: the conversation was restarted", lang: lang)
        case "no_model": return L("Not sent: the cloud model is off", lang: lang)
        default: return L("Not sent", lang: lang)
        }
    }

    /// A computer task's line in the chat: where it is, or how it ended (from its status alone: only succeeded is
    /// "done", handoff §2.1).
    static func task(_ t: TaskState, lang: ResolvedLang) -> String {
        if t.running {
            if t.stopping { return L("Stopping…", lang: lang) }
            if t.openCard != nil { return L("Waiting for your answer", lang: lang) }
            if t.expiredCard != nil { return L("The card expired; the task waits where it was", lang: lang) }
            if t.preparing { return L("Getting ready…", lang: lang) }
            if t.userActive { return L("You're using the Mac, paused", lang: lang) }
            if t.lookOnly { return L("Checking the result (looking only)", lang: lang) }
            let n = t.steps.count
            return n > 0 ? L("Working · step %d", n, lang: lang) : L("Working", lang: lang)
        }
        switch t.status {
        case "succeeded": return L("Done", lang: lang)
        case "unconfirmed": return L("Done, but not confirmed. Please check", lang: lang)
        case "failed": return L("Didn't finish", lang: lang)
        case "cancelled": return L("Cancelled", lang: lang)
        case "stopped":
            return t.cause == .lastStepUnknown ? L("Stopped. The last step may or may not have happened", lang: lang) : L("Stopped", lang: lang)
        case "environment":
            return t.cause == .screenLocked ? L("Stopped: the screen is locked", lang: lang) : L("The Mac's state didn't allow it", lang: lang)
        default: return L("Interrupted", lang: lang)
        }
    }

    /// What an undo came to, when there is something to say.
    static func undo(_ u: UndoState, lang: ResolvedLang) -> String? {
        switch u {
        case .none, .available, .declined: return nil
        case .done(let n, let m, let refused):
            let base = L("Undid %d of %d", n, m, lang: lang)
            return refused.map { base + " · " + $0 } ?? base
        case .expired: return L("Undo is no longer available", lang: lang)
        case .undoing: return L("Undoing…", lang: lang)
        case .unknown(let refused):
            let base = L("The undo was cut off: some of it may not have been undone. Please check", lang: lang)
            return refused.map { base + " · " + $0 } ?? base
        }
    }
}

/// A stored model error as the chat shows it.
struct ErrorRowModel: Equatable {
    var code: String
    var headline: String
    /// The harness's text (the env var it misses, the service's message; keys already removed).
    var detail: String
    /// A button to the model settings: the key or the service is what is wrong.
    var showsSettings: Bool
    /// 「再试一次」: the session answers the last message again (`retry`).
    var showsRetry: Bool

    static let settingsCodes: Set<String> = ["no_key", "key_invalid", "bad_config", "quota"]

    init(_ e: SessionErrorEvent, latest: Bool, idle: Bool, lang: ResolvedLang) {
        code = e.code
        headline = ShellText.problem(e.code, lang: lang)
        detail = e.text
        showsSettings = Self.settingsCodes.contains(e.code)
        // only the latest item, and only when nothing runs (the session refuses a retry then)
        showsRetry = latest && idle && e.replyTo != nil
    }
}

// MARK: - The list

struct ShellRow: Equatable, Identifiable {
    var id: String
    var title: String
    var status: SessionStatus
    var updatedAt: Double?
    /// A task of it runs (delete waits for it to end).
    var taskRunning: Bool
}

enum ShellList {
    /// The harness's own title rule (`sessions list`): the first user message, whitespace collapsed, 40 characters.
    static func title(firstUserMessage text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.count > 40 ? String(collapsed.prefix(40)) + "…" : collapsed
    }

    /// The rows, newest first: the helper's list joined with what this app holds (a session it opened that the list
    /// has not caught up with), a name the user gave it first, else the harness's title, else the first message.
    static func rows(summaries: [SessionSummary], states: [String: SessionState], names: [String: String],
                     deleted: Set<String>, untitled: String) -> [ShellRow] {
        var out: [String: ShellRow] = [:]
        // (a session the helper lists only because its process is starting — no stored message yet, none of this app's
        // — is no row: if its start fails, it would stay an empty "untitled" row at the top; #107 review at 36c5737)
        for s in summaries where !deleted.contains(s.sessionId) && !(s.starting && s.updatedAt == nil && states[s.sessionId] == nil) {
            out[s.sessionId] = ShellRow(id: s.sessionId, title: s.title, status: .idle, updatedAt: s.updatedAt, taskRunning: false)
        }
        for (id, st) in states where !deleted.contains(id) {
            var r = out[id] ?? ShellRow(id: id, title: "", status: .idle, updatedAt: nil, taskRunning: false)
            r.status = st.status
            r.taskRunning = st.runningTask != nil
            if let t = st.lastEventAt { r.updatedAt = max(r.updatedAt ?? t, t) }
            if r.title.isEmpty, let first = st.messages.first(where: { $0.role == "user" }) { r.title = title(firstUserMessage: first.text) }
            if r.title.isEmpty, let task = st.tasks.first { r.title = title(firstUserMessage: task.raw) }
            out[id] = r
        }
        for (id, name) in names where out[id] != nil && !name.isEmpty { out[id]!.title = name }
        for id in out.keys where out[id]!.title.isEmpty { out[id]!.title = untitled }
        return out.values.sorted { a, b in
            if (a.updatedAt ?? .infinity) != (b.updatedAt ?? .infinity) { return (a.updatedAt ?? .infinity) > (b.updatedAt ?? .infinity) }
            return a.id < b.id
        }
    }
}

/// The names the user gave sessions (rename): the app's own, by session id. The harness keeps no title of its own
/// beyond the first message.
struct SessionNames {
    static let key = "ui05.sessionNames"
    let defaults: UserDefaults
    var all: [String: String] { defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:] }
    func set(_ id: String, _ name: String?) {
        var d = all
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        d[id] = n.isEmpty ? nil : n
        defaults.set(d, forKey: Self.key)
    }
}

// MARK: - The model behind the window

/// The 0.5 main window's state and actions. The views read its published values on the main thread; the session
/// client's lines come on its watch thread and are handed over with `deliver`; anything that waits on the helper
/// runs through `work`. Tests and the e2e give both their own.
final class ShellModel: ObservableObject {
    /// The selection: a session, or the new conversation not opened yet (nil: its first message opens it).
    @Published var selected: String?
    @Published private(set) var rows: [ShellRow] = []
    @Published private(set) var states: [String: SessionState] = [:]
    /// The composer's text per session ("" key: the new conversation).
    @Published var drafts: [String: String] = [:]
    /// A new conversation is being opened (its first message waits for the session's id).
    @Published private(set) var opening = false
    /// Something the helper did not do, said once above the composer (nil when none).
    @Published var notice: String?
    /// What the app holds for cards (CardStore): answers in their take-back, answers written and not yet taken, reasks.
    /// With the session's state it is a card's one state (`phase`), which every view reads.
    @Published private(set) var cards = CardStore()
    /// The helper answers (its socket): the session list came back.
    @Published private(set) var reachable = true
    /// An open waits for DeskMind's helper to take the cloud switch (at most a few seconds): said meanwhile.
    @Published private(set) var waitingForHelper = false
    /// Cloud models are off in the settings: a session sends nothing (0.5 has no local-only session: it needs a cloud
    /// model, owner 10-22); the chat says so with a button to the settings.
    @Published private(set) var cloudOff = false
    /// Cards whose whole body has been on screen (`cardBody`), by card key: their approve-type options take a click.
    @Published private(set) var bodySeen: Set<String> = []

    let client: SessionClient
    private let names: SessionNames
    private let work: (@escaping () -> Void) -> Void
    private let deliver: (@escaping () -> Void) -> Void
    /// The model configuration and language sessions are opened with: the app's settings now.
    var config: () -> String?
    var lang: () -> ResolvedLang
    /// The settings' "use a cloud model" switch.
    var cloudOn: () -> Bool
    /// The key file as saved now (keys, a custom service's URL and model: MainSplitView.envFingerprint): a session
    /// process reads it once, when it starts.
    var keyFile: () -> String
    private let defaults: UserDefaults
    /// The settings this shell last gave its sessions (`settingsPrint`: configuration, language, cloud on or off), so
    /// that a save is acted on once however many paths report it (`syncSettings`).
    private var appliedSettings = ""
    /// A new key's restarts (`askNewProcesses`): one round at a time (`keysRound`; asked meanwhile: `keysAgain`, run
    /// once more after it); a round that left processes owed is tried again after `keysRetryDelay` (2 s, doubling, at
    /// most 60 s), by `retryAfter` — the app's: the main queue's clock; nil (a test's default): only the next
    /// syncSettings. `keysChecked`: the key file (this app's digest of it) at the last round that left nothing owed;
    /// `keysOwed`: the last round left some. `askedUnknown`: sessions asked once for a key file without knowing what
    /// their process runs on (an older helper; the list unread), by that file's digest.
    private let keysLock = NSLock()
    private var keysRound = false
    private var keysAgain = false
    private var keysRetryDelay: TimeInterval = 0
    private var keysRetryScheduled = false
    private var keysChecked: String?
    private var keysOwed = false
    private var askedUnknown: [String: String] = [:]
    let retryAfter: ((TimeInterval, @escaping () -> Void) -> Void)?
    /// The take-back's timer (CardStore.takeBack): runs `f` on the main thread after the delay. Tests drive their own.
    private let takeBackAfter: (TimeInterval, @escaping () -> Void) -> Void
    /// Now, in seconds since 1970 (a held answer's deadline, for the countdown).
    let now: () -> Double
    private var savedObserver: (center: NotificationCenter, token: NSObjectProtocol)?
    private var summaries: [SessionSummary] = []
    private var deleted: Set<String> = []
    private let pendingLock = NSLock()
    private var pending: Set<String> = []
    private let runLock = NSLock()
    private var watching = false
    private var stopWatch = false

    weak static var shared: ShellModel?

    /// `savedSettings`: where ModelSettingsSaved is posted (the app's: `.default`; a test's own; nil: not observed).
    init(client: SessionClient, defaults: UserDefaults = .standard,
         config: @escaping () -> String?, lang: @escaping () -> ResolvedLang, cloudOn: @escaping () -> Bool = { true },
         keyFile: @escaping () -> String = { "" }, savedSettings: NotificationCenter? = nil,
         retryAfter: ((TimeInterval, @escaping () -> Void) -> Void)? = nil,
         takeBackAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { d, f in DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: f) },
         now: @escaping () -> Double = { Date().timeIntervalSince1970 },
         work: @escaping (@escaping () -> Void) -> Void = { f in DispatchQueue.global(qos: .userInitiated).async(execute: f) },
         deliver: @escaping (@escaping () -> Void) -> Void = { f in DispatchQueue.main.async(execute: f) }) {
        self.client = client
        self.names = SessionNames(defaults: defaults)
        self.defaults = defaults
        self.config = config
        self.lang = lang
        self.cloudOn = cloudOn
        self.keyFile = keyFile
        self.retryAfter = retryAfter
        self.takeBackAfter = takeBackAfter
        self.now = now
        self.work = work
        self.deliver = deliver
        client.onChange = { [weak self] id, _ in self?.changed(id) }
        // the settings as stored now, read by the client whenever it opens or converges a session (never a copy)
        client.settingsSource = { [weak self] in
            guard let self else { return (nil, nil) }
            let s = self.sessionSettings(); return (s.config, s.lang)
        }
        client.onWaitingForHelper = { [weak self] waiting in self?.deliver { self?.waitingForHelper = waiting } }
        applySettings()
        appliedSettings = settingsPrint()
        // (on the main thread, after the save that posted it: a sheet's several writes are read once, all done)
        if let center = savedSettings {
            let token = center.addObserver(forName: ModelSettingsSaved.name, object: nil, queue: nil) { [weak self] _ in
                self?.deliver { self?.syncSettings() }
            }
            savedObserver = (center, token)
        }
    }

    deinit { if let o = savedObserver { o.center.removeObserver(o.token) } }

    static func langCode(_ l: ResolvedLang) -> String { l == .zhHans ? "zh" : "en" }

    /// Everything a session opens with — the model configuration and the language — as one value, from the app's
    /// settings as they are now (#107 review: one rule for both fields).
    func sessionSettings() -> (config: String?, lang: String) { (config(), Self.langCode(lang())) }

    /// The client reads the settings where they are stored, when it needs them (SessionClient.settingsSource, set in
    /// init: desired()); nothing is handed to it. Only the cloud switch of a client with no ModelsOffSync of the app's
    /// (a test's) is kept here: `reconcileIfModelChanged` — it moved since the client last heard: every session
    /// converged. Called before each open and send, and when the settings change.
    func applySettings() { applySettings(reconcileIfModelChanged: true) }

    private func applySettings(reconcileIfModelChanged: Bool) {
        let off = !cloudOn()
        if off && !cards.picks.isEmpty { cards.cloudOff() }    // (held answers go with the switch: SessionClient.offEpoch)
        guard client.modelOff != off else { return }
        client.modelOff = off
        if reconcileIfModelChanged { work { [weak self] in self?.client.convergeAll() } }
    }

    /// The settings as the window shows them (on the main thread): cloud models on or off.
    func refreshSettings() {
        let off = !cloudOn()
        if cloudOff != off { cloudOff = off }
    }

    /// Cloud models are off: nothing goes to a session (said once above the composer; the chat's row offers the
    /// settings). True when the send may go on.
    private func cloudAllows() -> Bool {
        applySettings()
        refreshSettings()
        guard cloudOn() else {
            notice = L("A conversation needs a cloud model. Turn it on in the model settings.", lang: lang())
            return false
        }
        return true
    }

    // MARK: watching

    /// Starts watching the helper's sessions (on its own thread, until `stopWatching`), and reads the list.
    func start() {
        // the helper holds whether cloud models are off: told the switch as the app starts its watch (and again
        // whenever the helper says otherwise)
        applySettings(reconcileIfModelChanged: false)
        client.modelsSync.push()
        runLock.lock()
        stopWatch = false
        let already = watching
        watching = true
        runLock.unlock()
        guard !already else { return }
        let t = Thread { [weak self] in
            while true {
                guard let self else { return }
                self.runLock.lock(); let stop = self.stopWatch; self.runLock.unlock()
                if stop { break }
                self.applySettings()
                // the list first: it says whether the helper answers (and what is on the disk), then the stream
                let list = self.client.list()
                self.deliver {
                    self.reachable = list != nil
                    if let list { self.summaries = list }
                    self.rebuild()
                }
                let ok = list != nil && self.client.watch()
                self.runLock.lock(); let stopNow = self.stopWatch; self.runLock.unlock()
                if stopNow { break }
                Thread.sleep(forTimeInterval: ok ? 0.2 : 1)
            }
            self?.runLock.lock(); self?.watching = false; self?.runLock.unlock()
        }
        t.name = "ai.deskmind.shell.watch"
        t.start()
    }

    /// Ends the watch at its next quiet moment (the transport asks; `StoppableTransport`).
    func stopWatching() {
        runLock.lock(); stopWatch = true; runLock.unlock()
    }
    var stopped: Bool { runLock.lock(); defer { runLock.unlock() }; return stopWatch }

    func refreshList() {
        work { [weak self] in
            guard let self else { return }
            let list = self.client.list()
            self.deliver {
                self.reachable = list != nil
                if let list { self.summaries = list }
                self.rebuild()
            }
        }
    }

    private func changed(_ id: String) {
        pendingLock.lock()
        let first = pending.isEmpty
        pending.insert(id)
        pendingLock.unlock()
        guard first else { return }
        deliver { [weak self] in self?.flush() }
    }

    /// Takes the latest state of every session that changed since the last flush (read now: a later line is never
    /// overwritten by an earlier one's state).
    private func flush() {
        pendingLock.lock()
        let ids = pending
        pending = []
        pendingLock.unlock()
        for id in ids where !deleted.contains(id) {
            let s = client.state(id)
            states[id] = s
            // a card that is no longer open: what the app held for it goes (a held answer is never sent then)
            var c = cards
            c.settle(id, s)
            if c != cards { cards = c }
        }
        // the open session's problems are seen as they come (once per new stored line or process end: never a loop of
        // marks)
        if let sel = selected, ids.contains(sel), let s = states[sel], s.lastSeq > s.seenSeq || s.goneUpTo > s.seenGone,
           SessionStatus.problemShown(s) { client.markSeen(sel) }
        rebuild()
    }

    private func rebuild() {
        let r = ShellList.rows(summaries: summaries, states: states, names: names.all, deleted: deleted,
                               untitled: L("New conversation", lang: lang()))
        if r != rows { rows = r }
    }

    // MARK: the list

    func newConversation() {
        selected = nil
        notice = nil
    }

    /// The user opened a session: its error dot clears. Reading it needs no process (#107 review): what is stored after
    /// the app's cursor is read from the log (session.history) and goes through the reducer, whether or not the app has
    /// some of it (one whose process ended starts again on the next message). Only an older helper without that op
    /// has an unknown session opened (and closes it once idle).
    func select(_ id: String) {
        selected = id
        notice = nil
        client.markSeen(id)
        let known = (states[id]?.lastSeq ?? 0) > 0 || client.state(id).lastSeq > 0
        applySettings()
        work { [weak self] in
            guard let self else { return }
            // what this app has is never taken as the whole of it (#107 review: a reply finished while the window was
            // closed showed as its first words, interrupted): what is stored after its cursor is read, every time
            if self.client.history(id) {
                // (what it showed when opened is seen)
                self.deliver { if self.selected == id { self.client.markSeen(id) } }
                return
            }
            guard !known else { return }    // (an older helper without session.history: the watch keeps it current)
            guard self.cloudOn() else { return }     // (cloud models off: no process for it)
            let ok = self.client.open(sessionId: id) != nil
            if !ok { self.deliver { self.notice = L("Couldn't open this conversation. Is DeskMind's helper running?", lang: self.lang()) } }
        }
    }

    func rename(_ id: String, to name: String) {
        names.set(id, name)
        rebuild()
    }

    func name(_ id: String) -> String? { names.all[id] }

    /// A task's result can still be undone (its executor lingers): ending the session's process gives that up.
    static func undoOpen(_ s: SessionState) -> Bool { s.tasks.contains { $0.undo == .available } }
    func undoOpen(_ id: String) -> Bool { states[id].map(Self.undoOpen) ?? false }

    /// Deleting is refused while a task of the session runs: stop it first (a delete is never a stop).
    func canDelete(_ id: String) -> Bool { !(rows.first { $0.id == id }?.taskRunning ?? false) }

    func delete(_ id: String) {
        guard canDelete(id) else { return }
        work { [weak self] in
            guard let self else { return }
            let why = self.client.delete(id)
            self.deliver {
                if let why {
                    self.notice = why == "task_running" ? L("Stop the task before deleting the conversation.", lang: self.lang())
                                                        : L("Couldn't delete the conversation. Try again in a moment.", lang: self.lang())
                    return
                }
                self.deleted.insert(id)
                self.states[id] = nil
                self.cards.forget(id)
                self.names.set(id, nil)
                self.drafts[id] = nil
                if self.selected == id { self.selected = nil }
                self.rebuild()
            }
        }
    }

    /// The previous (−1) or next (+1) row (⌘↑ ⌘↓).
    func move(_ by: Int) {
        guard !rows.isEmpty else { return }
        let i = selected.flatMap { s in rows.firstIndex { $0.id == s } } ?? (by > 0 ? -1 : rows.count)
        let j = max(0, min(rows.count - 1, i + by))
        select(rows[j].id)
    }

    // MARK: the selected session

    var current: SessionState? { selected.flatMap { states[$0] } }
    var composer: ComposerMode { ComposerMode.of(current) }

    var draft: String {
        get { drafts[selected ?? ""] ?? "" }
        set { drafts[selected ?? ""] = newValue }
    }

    /// Enter (`sendNow` false) or ⌘Enter: the composer's text as the control its state calls for. The text leaves the
    /// composer once it is in the session's hands (the outbox shows it until the session takes it); when nothing is
    /// sent it stays.
    func submit(sendNow: Bool = false) {
        let text = draft
        guard let control = composer.control(text, sendNow: sendNow) else { return }
        guard cloudAllows() else { return }     // (the text stays in the composer)
        guard let id = selected else { openThenSend(control, text: text); return }
        // (from here the words are the session's or an unsent bubble of it — SessionClient.send — never the composer's
        // again: a draft typed meanwhile is never overwritten)
        draft = ""
        work { [weak self] in
            guard let self else { return }
            let r = self.client.send(control, to: id)
            if r != .sent { self.deliver { self.notSent(r, text: text, in: id) } }
        }
    }

    /// The new conversation's first message: the session is opened (with the settings now), then the words sent. The
    /// words stay in the composer until the session is open (it takes no typing meanwhile: `opening`); not opened, they
    /// are still there; opened, they are the session's (sent, or an unsent bubble of it).
    private func openThenSend(_ control: SessionControl, text: String) {
        guard !opening else { return }
        opening = true
        work { [weak self] in
            guard let self else { return }
            // (with the settings stored when it goes: SessionClient.desired())
            guard let id = self.client.open() else {
                self.deliver {
                    self.opening = false
                    self.notice = L("Couldn't start a conversation. Is DeskMind's helper running?", lang: self.lang())
                }
                return
            }
            self.deliver {
                self.opening = false
                if self.drafts[""] == text { self.drafts[""] = "" }
                self.states[id] = self.client.state(id)
                if self.selected == nil { self.selected = id }
                self.rebuild()
            }
            let r = self.client.send(control, to: id)
            if r != .sent { self.deliver { self.notSent(r, text: text, in: id) } }
        }
    }

    /// Words not sent: the client holds them as an unsent bubble with its reason (「重新发送」), whatever the refusal —
    /// never put back in the composer (a newer draft there stays as it is). No helper: said once too.
    private func notSent(_ r: SessionClient.SendResult, text: String, in id: String) {
        if r == .unavailable { notice = L("DeskMind's helper didn't answer. Your message is kept below; send it again.", lang: lang()) }
    }

    /// Stop (⌘.): the running task, else the reply that streams. Always available while there is one.
    func stop() {
        guard let id = selected, let s = states[id] else { return }
        let control: SessionControl
        if let t = s.runningTask { control = .stop(runId: t.runId); cards.stopping(t.runId) }   // (a held answer is never sent after Stop)
        else if s.streamingMessage != nil { control = .stop() }
        else { return }
        work { [weak self] in _ = self?.client.send(control, to: id) }
    }

    // MARK: cards

    /// A card's one state, as every view shows it (CardStore.phase).
    func phase(_ runId: String, _ card: CardState, in s: SessionState) -> CardPhase {
        guard let t = s.task(runId) else { return .voided("task_done") }
        return cards.phase(card, of: t)
    }

    /// The card pinned above the composer, with its phase: the open card, else the expired one the task waits on.
    func pinned(_ s: SessionState) -> (runId: String, card: CardState, phase: CardPhase)? { cards.pinned(s) }

    /// A click on a card's button: that card's answer (its option index, its ask_id). On a card that waits, the answer
    /// is held for its take-back (3 s: picking again starts over, 「撤回」 drops it) and sent once that ran out — only if
    /// the card is still the open one; the way out (「先别做了」) is sent at once. A result card's answer goes at once.
    func click(_ button: CardModel.Button) {
        guard let id = selected else { return }
        // an approve-type option only once the card's whole body has been on screen (never approve what was not seen)
        if button.role.needsWholeBody && !bodySeen.contains(Self.cardKey(runId: button.runId, askId: button.askId)) { return }
        // cloud models off: only what reaches no model is held back — the way out and undo (the session undoes from
        // its receipts, no model) always go; an answer that resumes the task would make the model go on
        if !button.role.reachesNoModel && !cloudAllows() { return }
        let a = CardModel.answer(button)
        if a.askId == nil { act(cards.respond(a, sessionId: id, in: client.state(id)), in: id); return }
        pick(a, immediate: button.role == .cancel, in: id)
    }

    /// The user's own words on a card that takes them (its own field): on a card with an approve-type option, only once
    /// its whole body has been on screen, as its approve (words can approve too; they are never read). Held for the
    /// take-back as a click is.
    func answer(_ card: CardModel, text: String) {
        guard let id = selected, !Self.wordsWaitForBody(card) || bodySeen.contains(Self.cardKey(card)),
              let a = card.answer(text: text), cloudAllows() else { return }
        pick(a, immediate: false, in: id)
    }

    /// When each card came on screen (CardView's appear; gone when it leaves), by card key; the last key-down the
    /// window saw (any key).
    private var shownAt: [String: Double] = [:]
    private var lastKeyDown = -Double.infinity

    func cardShown(_ card: CardModel) { let k = Self.cardKey(card); if shownAt[k] == nil { shownAt[k] = now() } }
    func cardHidden(_ card: CardModel) { shownAt[Self.cardKey(card)] = nil }

    /// Every key-down of the main window (CardKeyMonitor, before it goes anywhere): true when it picked on the pinned
    /// card and is consumed. A digit picks only when it is a card key (CardKeys.number), no key-down at all came in
    /// the `CardKeys.quiet` before it (typing in progress — wherever the focus is now), and the pinned card has been on
    /// screen for `CardKeys.cardOnScreen`. Typing in progress never lands on a card (#107).
    func keyDown(characters: String?, commandLike: Bool, mainWindowIsKey: Bool, editingText: Bool, isRepeat: Bool) -> Bool {
        let t = now()
        let quietFor = t - lastKeyDown
        lastKeyDown = t
        guard let n = CardKeys.number(characters: characters, commandLike: commandLike, mainWindowIsKey: mainWindowIsKey,
                                      editingText: editingText, isRepeat: isRepeat),
              quietFor >= CardKeys.quiet,
              let id = selected, let s = states[id], let p = pinned(s),
              let since = shownAt[Self.cardKey(runId: p.runId, askId: p.card.askId)], t - since >= CardKeys.cardOnScreen else { return false }
        return pressKey(n)
    }

    /// Key `n` (1–9, CardKeys) on the pinned card: its n-th control as shown (CardLayout), picked as a click is — held for
    /// the take-back, an approve-type option only once the whole card was seen. False when it picks nothing (the key is
    /// the window's then).
    @discardableResult
    func pressKey(_ n: Int) -> Bool {
        guard let id = selected, let s = states[id], let p = pinned(s), p.phase.takesPick else { return false }
        let card = CardModel(card: p.card.card, runId: p.runId, askId: p.card.askId)
        guard let c = CardLayout(card).control(forKey: n) else { return false }
        click(c.button)
        return true
    }

    /// 「撤回」 within the take-back: the held answer is dropped, never sent; the card waits again.
    func takeBack(_ card: CardModel) { cards.takeBack(Self.cardKey(card)) }

    /// 「现在回答」 on an expired card: the task looks again and asks a new card (reask). Sent once.
    func answerNow(_ runId: String, askId: String) {
        guard let id = selected, cloudAllows(),
              cards.answerNow(runId, askId: askId, sessionId: id, in: client.state(id)) else { return }
        let key = CardStore.key(runId: runId, askId: askId)
        work { [weak self] in
            guard let self else { return }
            if self.client.send(.reask(runId: runId), to: id) != .sent { self.deliver { self.cards.reaskNotSent(key) } }
        }
    }

    /// A card whose own words wait for its whole body: one with an approve-type option (#107 re-review).
    static func wordsWaitForBody(_ card: CardModel) -> Bool { card.buttons.contains { $0.role.needsWholeBody } }

    /// Whether the card's own field (and its Send) takes words now: as `answer` sends them.
    func wordsEnabled(_ card: CardModel, in s: SessionState) -> Bool {
        answerable(card, in: s) && (!Self.wordsWaitForBody(card) || bodySeen.contains(Self.cardKey(card)))
    }

    static func cardKey(runId: String, askId: String?) -> String { CardStore.key(runId: runId, askId: askId) }
    static func cardKey(_ card: CardModel) -> String { cardKey(runId: card.runId, askId: card.askId) }

    /// The card's body as it is on screen (its scroll view's geometry, CardBody.endShown): once its end has been on
    /// screen — it fits, or it was scrolled to its last line — its approve-type options take a click, for good.
    func cardBody(_ card: CardModel, contentHeight: Double, visibleHeight: Double, offset: Double) {
        let key = Self.cardKey(card)
        guard !bodySeen.contains(key), CardBody.endShown(contentHeight: contentHeight, visibleHeight: visibleHeight, offset: offset) else { return }
        bodySeen.insert(key)
    }

    /// Whether this button takes a click now: its card can be answered, and an approve-type option's card was seen whole.
    func buttonEnabled(_ b: CardModel.Button, card: CardModel, in s: SessionState) -> Bool {
        answerable(card, in: s) && (!b.role.needsWholeBody || bodySeen.contains(Self.cardKey(card)))
    }

    /// A pick on its card (CardStore.pick, against the newest state the client has): held, then — its take-back run
    /// out — written once; or written now.
    private func pick(_ a: CardAnswer, immediate: Bool, in id: String) {
        act(cards.pick(a, sessionId: id, immediate: immediate, now: now(), offEpoch: client.offEpoch, in: client.state(id)), in: id)
    }

    private func act(_ action: CardStore.Action, in id: String) {
        switch action {
        case .none: break
        case .send(let key, let a): write(a, key: key, in: id)
        case .hold(let key, let token):
            takeBackAfter(CardStore.takeBack) { [weak self] in self?.due(key, token: token, in: id) }
        }
    }

    /// A held answer's take-back ran out: written if it is still the card's pick and the card still waits (the newest
    /// state the client has); cloud models turned off meanwhile: dropped (an answer that resumes the task would make the
    /// model go on).
    private func due(_ key: String, token: Int, in id: String) {
        guard cards.picks[key]?.token == token else { return }
        if !cloudAllows() { cards.takeBack(key); return }
        guard let a = cards.due(key, token: token, offEpoch: client.offEpoch, in: client.state(id)) else { return }
        write(a, key: key, in: id)
    }

    private func write(_ a: CardAnswer, key: String, in id: String) {
        work { [weak self] in
            guard let self else { return }
            let r = self.client.answer(a, in: id)
            if r != .sent { self.deliver { self.cards.notSent(key, a) } }
        }
    }

    /// Whether a card's buttons take a click now: it waits (open, or held — a click picks again) and nothing for it is
    /// on its way; a result card while it can still be answered and no answer from here is on its way.
    func answerable(_ card: CardModel, in s: SessionState) -> Bool {
        guard let askId = card.askId else {
            return SessionClient.refusal(.respond(runId: card.runId, option: 0), in: s) == nil && !cards.responding(card.runId)
        }
        guard let t = s.task(card.runId), let c = t.cards.first(where: { $0.askId == askId }) else { return false }
        return cards.phase(c, of: t).takesPick && SessionClient.refusal(.option(runId: card.runId, askId: askId, option: 0), in: s) == nil
    }

    // MARK: the queue, unsent words, retry

    func queueEdit(_ id: String, text: String) { control(.queueEdit(id: id, text: text)) }
    func queueCancel(_ id: String) { control(.queueCancel(id: id)) }
    func queueSendNow(_ id: String) { guard cloudAllows() else { return }; control(.queueSendNow(id: id)) }
    func retry() { guard cloudAllows() else { return }; control(.retry) }

    /// Send again: only while the composer takes words (a card waits: it is answered on the card first — M1 decision 1).
    func resend(_ outgoing: String) {
        guard let id = selected, composer.enabled, cloudAllows() else { return }
        work { [weak self] in _ = self?.client.resend(outgoing, in: id) }
    }

    func dropUnsent(_ outgoing: String) {
        guard let id = selected else { return }
        client.dropUnsent(outgoing, in: id)
    }

    private func control(_ c: SessionControl) {
        guard let id = selected else { return }
        applySettings()
        work { [weak self] in _ = self?.client.send(c, to: id) }
    }

    // MARK: settings

    /// The key file's digest at the last round that left nothing owed (a cache): only for a helper that does not say
    /// what its processes run on — its open sessions are asked once when the file differs from this.
    static let keysSeenKey = "shell.keysSeen"

    /// What a live session takes in place (set_config): the configuration, the language, cloud models on or off.
    private func settingsPrint() -> String {
        let (config, lang) = sessionSettings()
        return (config ?? "") + "|" + lang + "|" + (cloudOn() ? "on" : "off")
    }
    private func keysPrint() -> String { ModelKeys.digest(keyFile()) }
    /// Some session process may still run on keys no longer saved: the key file changed since the last round that
    /// found none (or none has run in this launch), or that round left some owed.
    var keysPending: Bool {
        let now = keysPrint()
        keysLock.lock(); defer { keysLock.unlock() }
        return keysOwed || keysChecked != now
    }

    /// The settings as saved now, compared with what this shell last gave its sessions. One path for every way a save
    /// is learnt of, whichever window saved (#107 review at 5999bd9): ModelSettingsSaved from any writer, this window
    /// appearing (a save while it was not shown, or before this launch), its own sheet closing, a language switch, and
    /// a key's retry. The settings that go in place (configuration, language, cloud on or off) are sent once per change:
    /// a save already given compares equal (`appliedSettings`). The keys: a round (`askNewProcesses`) while any may be
    /// owed (`keysPending`): the helper says which processes run on keys no longer saved, and only those are asked —
    /// the sheet's close after its own writes' notice restarts no session twice. Main thread.
    func syncSettings() {
        if settingsPrint() != appliedSettings { settingsChanged(keyChanged: keysPending); return }
        guard keysPending else { return }
        work { [weak self] in self?.askNewProcesses() }
    }

    /// The model settings were saved (a key, a service, cloud on or off): every session opens again with them, whenever
    /// its next process starts. The UI language goes the same way (MainSplitView: on a language change).
    ///
    /// Each live session gets them in place (set_config, harness#64: no restart, nothing stopped); with cloud models
    /// off, no model at all (set_config null: it stops its running task, nothing that needs a model goes on). Only a
    /// new key needs a new process (a process reads its keys when it starts): `keyChanged` then asks the helper for one
    /// once the session is idle (end_if_idle; the helper and the session decide when): `askNewProcesses`.
    func settingsChanged(keyChanged: Bool = false) {
        applySettings(reconcileIfModelChanged: false)
        refreshSettings()
        appliedSettings = settingsPrint()
        // only "converge now": the settings are read when each set_config goes, never carried here (#107 review at
        // 00969e8: two saves whose work ran C then B left the sessions on B)
        work { [weak self] in
            guard let self else { return }
            self.client.convergeAll()
            if keyChanged { self.askNewProcesses() }
        }
    }

    /// A new key reaches a process only when it starts: a process that runs on keys no longer saved is asked for a new
    /// one (`restart`, when idle), whatever the switch says now (turned on later, a session must not run on old keys).
    /// Which ones is the helper's to say (#107 review at b3b8464: the app's own record of what it had asked missed a
    /// session that restarted on B when the file went back to A): sessions.list gives the digest of the file now and
    /// the helper's own process table (`processes`, every process it holds, whether or not its session is stored yet):
    /// each one's digest at its start and whether a restart is asked already (`ending`). Owed: a process whose digest
    /// is not the file's (or not read yet); asked: the started ones not ending. After asking, the list is read again (a
    /// process ended at once is gone; one busy stays owed, `ending`, until it goes). An ask not taken (no answer, an
    /// error) stays owed and is not asked again in the same round. Owed left, or the list unread: tried again on the
    /// next syncSettings and after a backoff (`retryAfter`), with no user action. A quit, a helper restart, a lost ask,
    /// A→B→A: the next round reads them.
    ///
    /// An older helper (no digests) or a list not read: what each process runs on is unknown — each such session
    /// (open in the list; else the ones this client knows to be live) is asked once per key file (`askedUnknown`, set
    /// only when the helper took the ask), when the file differs from the last checked one (`keysSeenKey`, written
    /// only when nothing is owed). Off the main thread; one round at a time.
    private func askNewProcesses() {
        keysLock.lock()
        if keysRound { keysAgain = true; keysLock.unlock(); return }
        keysRound = true
        keysLock.unlock()
        while true {
            let digest = keysPrint()
            var owed = false
            // `asked`: asks the helper took in this round (not asked again in it); `failed`: asks it did not take — not
            // asked again in this round either (the retry does), and owed until one is taken (#107 review at 588dbad:
            // a failed ask was put with the taken ones, the next pass cleared `owed`, and the round committed)
            var asked: Set<String> = [], failed: Set<String> = []
            for pass in 0..<3 {
                let listed = client.listWithKeys()
                var stale: [String] = [], unknown: [String] = []
                owed = false
                if let listed, let now = listed.keysNow, let processes = listed.processes {
                    // the helper's own process table (never the stored list: a process with nothing stored yet is in it)
                    for s in processes {
                        if s.keys == now { continue }
                        // starting, or its keys not read yet: not asked (the helper's end finds it not open), owed; the
                        // backoff reads it again once started (#107 reviews at 85d81f6, 36c5737)
                        if s.starting || s.keys == nil { owed = true; continue }
                        owed = true
                        if !s.ending { stale.append(s.sessionId) }
                    }
                } else {
                    // an older helper (no digests, no process table), or the list unread: what each runs on is unknown
                    let open = listed.map { $0.sessions.filter(\.open).map(\.sessionId) } ?? client.liveIds()
                    unknown = open
                    if listed == nil { owed = true }
                }
                // unknown: asked once per key file, only when it differs from the last checked one
                keysLock.lock()
                let seen = defaults.string(forKey: Self.keysSeenKey)
                unknown = seen == digest ? [] : unknown.filter { askedUnknown[$0] != digest }
                keysLock.unlock()
                let ask = Set(stale).union(unknown).subtracting(asked).subtracting(failed)
                if ask.isEmpty { break }
                for id in ask.sorted() {
                    // (what its next process opens with is the client's newest settings: an ask carries none)
                    if client.restart(id) {
                        asked.insert(id)
                        if unknown.contains(id) { keysLock.lock(); askedUnknown[id] = digest; keysLock.unlock() }
                    } else {
                        failed.insert(id)
                    }
                }
                // (read again: what the asks did — ended at once, or ending at its next idle moment — and an ask lost)
                if pass == 2 { owed = true }
            }
            if !failed.isEmpty { owed = true }
            let done = !owed && keysPrint() == digest
            if done { defaults.set(digest, forKey: Self.keysSeenKey) }
            // whether to run again, and the round's end, decided under one lock (a request at the round's end is
            // either run by this round or starts its own)
            keysLock.lock()
            let again = keysAgain
            keysAgain = false
            if !again {
                keysRound = false
                keysOwed = !done
                if done { keysChecked = digest; keysRetryDelay = 0 }
            }
            keysLock.unlock()
            if again { continue }
            if !done { scheduleKeysRetry() }
            return
        }
    }

    /// Owed processes: tried again after a backoff (2 s, doubling to 60 s at most), one retry waiting at a time, for as
    /// long as some are owed (each retry is a syncSettings: nothing when nothing is owed by then).
    private func scheduleKeysRetry() {
        guard let retryAfter else { return }
        keysLock.lock()
        guard !keysRetryScheduled else { keysLock.unlock(); return }
        keysRetryScheduled = true
        keysRetryDelay = min(60, max(2, keysRetryDelay * 2))
        let delay = keysRetryDelay
        keysLock.unlock()
        retryAfter(delay) { [weak self] in
            guard let self else { return }
            self.keysLock.lock(); self.keysRetryScheduled = false; self.keysLock.unlock()
            self.deliver { self.syncSettings() }
        }
    }

    /// The chat's "cloud model is off" row: the settings say so, or this session refused words for having no model
    /// (no_model: its stored settings say so, whatever this app's switch says).
    /// An unsent bubble's line: "the cloud model is off" only while it is; after, plainly not sent (Send again works).
    func unsentText(_ code: String?) -> String {
        ShellText.unsent(code == "no_model" && !cloudOff ? nil : code, lang: lang())
    }

    func showsCloudOff(_ s: SessionState?) -> Bool {
        if cloudOff { return true }
        // a session with a process now that runs with no model (its stored settings, its refusal): not one that exited
        // (its next process opens with the settings now)
        guard let s, s.exited == nil else { return false }
        return s.lastRefusal?.code == "no_model" || (s.settings.map { $0.config == nil } ?? false)
    }

    /// A task runs in some session with no card waiting for the user (a reopen of the app then is not the user's:
    /// handoff §3.1).
    var taskRunningWithoutCard: Bool {
        states.values.contains { $0.runningTask != nil && cards.pinned($0) == nil }
    }
}

extension CardModel.Role {
    /// An option that lets the task go ahead on what the card shows (yes; "you decide") — or one whose kind this app
    /// does not know, which might (it fails closed): answered only once the card's whole body has been on screen
    /// (owner: never approve what you can't fully see). The way out, a pick, a skip and undo are not.
    var needsWholeBody: Bool { self == .approve || self == .delegate || self == .other }
    /// An answer that resumes no model work (the way out; undo, which the session runs from its receipts): it goes
    /// with cloud models off too (#107 re-review: holding back an undo for its 600 s would break the gate).
    var reachesNoModel: Bool { self == .cancel || self == .undo }
}

/// The model settings as the 0.5 window offers them (#107 re-review, owner: 0.5.0 has no local-only mode — a
/// conversation needs a cloud model). The window as it was (flag off) keeps its choice. The switch is a privacy
/// setting: it shows what is stored, and only the user moving it changes it (#107 re-review, bug A: the sheet showed it
/// on over a stored "off", and its default Save turned the cloud model on for the old window too).
enum ModelChoice {
    /// Whether the settings offer turning the cloud model off.
    static func offersLocalOnly(inShell: Bool) -> Bool { !inShell }
    /// What the switch shows when the settings open: what is stored, in either window.
    static func startsCloud(inShell: Bool, saved: Bool) -> Bool { saved }
    /// Whether the switch can be moved: in the 0.5 window only from off to on (once stored on, nothing to move).
    static func switchLocked(inShell: Bool, saved: Bool) -> Bool { inShell && saved }
    /// What Save writes for the engine: nothing unless the user moved the switch (shown differs from stored).
    static func engineToWrite(saved: Bool, shown: Bool) -> Bool? { shown == saved ? nil : shown }
    /// A model name as saved and sent: without the spaces and line ends a paste brings (the harness trims too).
    /// Trimmed of what JavaScript's trim() takes and of what Foundation counts as whitespace (U+0085 too): the stored
    /// name is clean, and the harness's normalisation leaves it as it is (a U+0085 it keeps fails its model-id check:
    /// bad_config). normalizeConfig stays the JavaScript set exactly.
    static let saveTrim = SessionClient.jsWhitespace.union(.whitespacesAndNewlines)
    static func modelName(_ typed: String) -> String { typed.trimmingCharacters(in: saveTrim) }
}

/// A card's body on screen (MainSplitView.CardView: the body scrolls inside a bounded height, its header and buttons
/// stay put): whether its end is on screen, from the scroll view's geometry only (never from the text).
enum CardBody {
    /// The tallest the body is shown before it scrolls (points); a short window makes it less.
    static let maxHeight: Double = 220
    /// The least it keeps when the window is short.
    static let minHeight: Double = 60

    /// It fits, or its last line is on screen (the content's top is `offset` above the visible top).
    static func endShown(contentHeight: Double, visibleHeight: Double, offset: Double) -> Bool {
        guard contentHeight > 0, visibleHeight > 0 else { return false }
        return contentHeight <= visibleHeight + 0.5 || offset + visibleHeight >= contentHeight - 0.5
    }

    /// The body's height cap in a chat column `columnHeight` tall: a share of it, between minHeight and maxHeight, so
    /// that the header, the card's buttons and the composer always keep their place.
    static func cap(columnHeight: Double) -> Double {
        min(maxHeight, max(minHeight, columnHeight * 0.3))
    }
}

extension CardModel.Kind {
    /// The kind as the harness names it.
    var name: String {
        switch self {
        case .plan: return "plan"
        case .action: return "action"
        case .ambiguity: return "ambiguity"
        case .missing: return "missing"
        case .resultCheck: return "result_check"
        case .cannot: return "cannot"
        case .result: return "result"
        case .other(let k): return k
        }
    }
}

extension SessionStatus {
    /// The session shows a problem the user has not seen (opening it clears it).
    static func problemShown(_ s: SessionState) -> Bool {
        switch s.status { case .error, .locked: return true; default: return false }
    }
}

/// The helper's transport, which the app can end (`ShellModel.stop`): a quiet watch stream asks it, and ends.
final class StoppableTransport: SessionTransport {
    let inner: SessionTransport
    var isStopped: () -> Bool = { false }
    init(_ inner: SessionTransport) { self.inner = inner }
    func request(_ body: [String: Any]) -> [String: Any]? { inner.request(body) }
    func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool {
        inner.stream(body, onLine: { [weak self] l in onLine(l) && !(self?.isStopped() ?? false) },
                     onIdle: { [weak self] in onIdle() && !(self?.isStopped() ?? false) })
    }
}
