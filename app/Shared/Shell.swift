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
        for s in summaries where !deleted.contains(s.sessionId) {
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
    /// Cards answered from here whose answer has not taken effect yet (`run/ask`; `run` for the result card): their
    /// buttons stay off until the card's outcome changes, so one card is never answered twice.
    @Published private(set) var answering: Set<String> = []
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
    private var summaries: [SessionSummary] = []
    private var deleted: Set<String> = []
    private let pendingLock = NSLock()
    private var pending: Set<String> = []
    private let runLock = NSLock()
    private var watching = false
    private var stopWatch = false

    weak static var shared: ShellModel?

    init(client: SessionClient, defaults: UserDefaults = .standard,
         config: @escaping () -> String?, lang: @escaping () -> ResolvedLang, cloudOn: @escaping () -> Bool = { true },
         work: @escaping (@escaping () -> Void) -> Void = { f in DispatchQueue.global(qos: .userInitiated).async(execute: f) },
         deliver: @escaping (@escaping () -> Void) -> Void = { f in DispatchQueue.main.async(execute: f) }) {
        self.client = client
        self.names = SessionNames(defaults: defaults)
        self.config = config
        self.lang = lang
        self.cloudOn = cloudOn
        self.work = work
        self.deliver = deliver
        client.onChange = { [weak self] id, _ in self?.changed(id) }
        client.onWaitingForHelper = { [weak self] waiting in self?.deliver { self?.waitingForHelper = waiting } }
        applySettings()
    }

    static func langCode(_ l: ResolvedLang) -> String { l == .zhHans ? "zh" : "en" }

    /// Everything a session opens with — the model configuration and the language — as one value, from the app's
    /// settings as they are now (#107 review: one rule for both fields).
    func sessionSettings() -> (config: String?, lang: String) { (config(), Self.langCode(lang())) }

    /// Sessions open with the settings as they are now: when either field changed (a key saved, the UI language
    /// switched), every session's next process opens with the new value (SessionClient.adoptSettings), not only those
    /// this client never opened. Called before each open and send, and when the settings change.
    func applySettings() { applySettings(reconcileIfModelChanged: true) }

    /// `reconcileIfModelChanged`: the switch moved since the client last heard (turned in the window as it was, say):
    /// the client takes it at once (an open from now on sees it) and every session it knows is told (`reconcile`).
    private func applySettings(reconcileIfModelChanged: Bool) {
        let now = sessionSettings()
        if client.defaultConfig != now.config || client.defaultLang != now.lang { client.adoptSettings(config: now.config, lang: now.lang) }
        let off = !cloudOn()
        guard client.modelOff != off else { return }
        client.modelOff = off
        if reconcileIfModelChanged { work { [weak self] in self?.client.reconcile(config: now.config, lang: now.lang, off: off) } }
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
            // a card's answer took effect, or the card went: its buttons are the card's again
            answering = answering.filter { key in
                let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
                guard let t = s.task(parts[0]) else { return true }
                if parts.count == 2 { return t.openCard?.askId == parts[1] }
                return t.resultResponse == nil && t.sessionUndo == nil && t.closed == nil
            }
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
        let (config, lang) = sessionSettings(), cloud = cloudOn()
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
            guard cloud else { return }     // (cloud models off: no process for it)
            let ok = self.client.open(sessionId: id, config: config, lang: lang) != nil
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
        draft = ""
        work { [weak self] in
            guard let self else { return }
            let r = self.client.send(control, to: id)
            if r != .sent { self.deliver { self.notSent(r, text: text, in: id) } }
        }
    }

    /// The new conversation's first message: the session is opened (with the settings now), then the words sent.
    private func openThenSend(_ control: SessionControl, text: String) {
        guard !opening else { return }
        opening = true
        drafts[""] = ""
        let (config, lang) = sessionSettings()
        work { [weak self] in
            guard let self else { return }
            guard let id = self.client.open(config: config, lang: lang) else {
                self.deliver {
                    self.opening = false
                    if (self.drafts[""] ?? "").isEmpty { self.drafts[""] = text }
                    self.notice = L("Couldn't start a conversation. Is DeskMind's helper running?", lang: self.lang())
                }
                return
            }
            self.deliver {
                self.opening = false
                self.states[id] = self.client.state(id)
                if self.selected == nil { self.selected = id }
                self.rebuild()
            }
            let r = self.client.send(control, to: id)
            if r != .sent { self.deliver { self.notSent(r, text: text, in: id) } }
        }
    }

    /// Words not sent and not held by the client (a refusal before they were held, or no helper): back in the
    /// composer, unless the user has typed something new there.
    private func notSent(_ r: SessionClient.SendResult, text: String, in id: String) {
        if client.state(id).outbox.contains(where: { $0.text == text }) { return }   // held: shown with 「重新发送」
        if (drafts[id] ?? "").isEmpty { drafts[id] = text }
        if r == .unavailable { notice = L("DeskMind's helper didn't answer. Your message is back in the box.", lang: lang()) }
    }

    /// Stop (⌘.): the running task, else the reply that streams. Always available while there is one.
    func stop() {
        guard let id = selected, let s = states[id] else { return }
        let control: SessionControl
        if let t = s.runningTask { control = .stop(runId: t.runId) }
        else if s.streamingMessage != nil { control = .stop() }
        else { return }
        work { [weak self] in _ = self?.client.send(control, to: id) }
    }

    // MARK: cards

    static func answerKey(_ a: CardAnswer) -> String { a.askId.map { "\(a.runId)/\($0)" } ?? a.runId }

    /// A click on a card's button: that card's answer (its option index, its ask_id), sent only while it is the open
    /// card; then its buttons stay off until the answer takes effect.
    func click(_ button: CardModel.Button) {
        guard let id = selected else { return }
        // an approve-type option only once the card's whole body has been on screen (never approve what was not seen)
        if button.role.needsWholeBody && !bodySeen.contains(Self.cardKey(runId: button.runId, askId: button.askId)) { return }
        // cloud models off: only what reaches no model is held back — the way out and undo (the session undoes from
        // its receipts, no model) always go; an answer that resumes the task would make the model go on
        if !button.role.reachesNoModel && !cloudAllows() { return }
        send(CardModel.answer(button), in: id)
    }

    /// The user's own words on a card that takes them (its own field): on a card with an approve-type option, only once
    /// its whole body has been on screen, as its approve (words can approve too; they are never read).
    func answer(_ card: CardModel, text: String) {
        guard let id = selected, !Self.wordsWaitForBody(card) || bodySeen.contains(Self.cardKey(card)),
              let a = card.answer(text: text), cloudAllows() else { return }
        send(a, in: id)
    }

    /// A card whose own words wait for its whole body: one with an approve-type option (#107 re-review).
    static func wordsWaitForBody(_ card: CardModel) -> Bool { card.buttons.contains { $0.role.needsWholeBody } }

    /// Whether the card's own field (and its Send) takes words now: as `answer` sends them.
    func wordsEnabled(_ card: CardModel, in s: SessionState) -> Bool {
        answerable(card, in: s) && (!Self.wordsWaitForBody(card) || bodySeen.contains(Self.cardKey(card)))
    }

    static func cardKey(runId: String, askId: String?) -> String { askId.map { "\(runId)/\($0)" } ?? runId }
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

    private func send(_ a: CardAnswer, in id: String) {
        let key = Self.answerKey(a)
        guard !answering.contains(key) else { return }
        answering.insert(key)
        work { [weak self] in
            guard let self else { return }
            let r = self.client.answer(a, in: id)
            if r != .sent { self.deliver { self.answering.remove(key) } }
        }
    }

    /// Whether a card's buttons take a click now: it is the open card (or the result card can still be answered) and
    /// no answer from here is on its way.
    func answerable(_ card: CardModel, in s: SessionState) -> Bool {
        let probe: CardAnswer = card.askId.map { .option(runId: card.runId, askId: $0, option: 0) } ?? .respond(runId: card.runId, option: 0)
        return SessionClient.refusal(probe, in: s) == nil && !answering.contains(Self.answerKey(probe))
    }

    // MARK: the queue, unsent words, retry

    func queueEdit(_ id: String, text: String) { control(.queueEdit(id: id, text: text)) }
    func queueCancel(_ id: String) { control(.queueCancel(id: id)) }
    func queueSendNow(_ id: String) { guard cloudAllows() else { return }; control(.queueSendNow(id: id)) }
    func retry() { guard cloudAllows() else { return }; control(.retry) }

    func resend(_ outgoing: String) {
        guard let id = selected, cloudAllows() else { return }
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

    /// The model settings were saved (a key, a service, cloud on or off): every session opens again with them, whenever
    /// its next process starts. The UI language goes the same way (MainSplitView: on a language change).
    ///
    /// Each live session gets them in place (set_config, harness#64: no restart, nothing stopped); with cloud models
    /// off, no model at all (set_config null: it stops its running task, nothing that needs a model goes on). Only a
    /// new key needs a new process (a process reads its keys when it starts): `keyChanged` then asks the helper for one
    /// once the session is idle (end_if_idle; the helper and the session decide when).
    func settingsChanged(keyChanged: Bool = false) {
        applySettings(reconcileIfModelChanged: false)
        refreshSettings()
        let (config, lang) = sessionSettings()
        let off = !cloudOn()
        work { [weak self] in
            guard let self else { return }
            // every session the client knows with a process or one coming (live, opening, reopening, awaiting its
            // start: the client's list, not this window's view of it)
            self.client.reconcile(config: config, lang: lang, off: off)
            // a new key reaches a process only when it starts: asked for whatever the switch says now (turned on
            // later, a session must not run on the old key)
            if keyChanged { for id in self.client.liveIds() { self.client.restart(id, config: config, lang: lang) } }
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
        states.values.contains { $0.runningTask != nil && $0.openCard == nil }
    }
}

extension CardModel.Role {
    /// An option that lets the task go ahead on what the card shows (yes; "you decide"): answered only once the card's
    /// whole body has been on screen (owner: never approve what you can't fully see). The way out, a pick, a skip and
    /// undo are not.
    var needsWholeBody: Bool { self == .approve || self == .delegate }
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
    static func modelName(_ typed: String) -> String { typed.trimmingCharacters(in: .whitespacesAndNewlines) }
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
