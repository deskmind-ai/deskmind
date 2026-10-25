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
    /// Typing is taken (A9, owner 10-25 decisions 3 + 4: while a task runs, a card open or not -- Return with text then
    /// steers the task, and the card it voids ends by the run's word, ask_void{why: steer}).
    var enabled: Bool
    /// A computer task runs: Return sends the words to it now (steer); no queue, ⌘Return is no other gesture.
    var taskRunning: Bool
    /// A reply streams and no task runs: Enter sends nothing (the session would refuse it busy); Stop stops the reply.
    var replying: Bool
    /// There is something to stop: a running task, or a reply.
    var canStop: Bool { taskRunning || replying }

    static func of(_ s: SessionState?) -> ComposerMode {
        guard let s else { return ComposerMode(enabled: true, taskRunning: false, replying: false) }
        let task = s.runningTask != nil
        return ComposerMode(enabled: s.composerEnabled || task, taskRunning: task, replying: !task && s.streamingMessage != nil)
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
            // Return (⌘Return the same): to the running task now -- a card open is voided first, by the session (H5)
            return .steer(text)
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
            if !t.plan.isEmpty, let p = t.steps.last?.planStep { return L("Working · step %d of %d", p, t.plan.count, lang: lang) }
            return n > 0 ? L("Working · step %d", n, lang: lang) : L("Working", lang: lang)
        }
        // (why it stopped is its end's own: status and cause — never how its result card closed later — unless an undo
        // took back all it did, which is then what happened: A8)
        if fullyUndone(t) != nil { return L("Undone", lang: lang) }
        switch t.status {
        case "stopped" where t.cause == .lastStepUnknown: return L("Stopped. The last step may or may not have happened", lang: lang)
        case "environment" where t.cause == .screenLocked: return L("Stopped: the screen is locked", lang: lang)
        default: return ending(t.status, lang: lang)
        }
    }

    // A finished task's words come from its latest record of what happened (plan §3.7, A8): its end (task_done, else
    // session.task_end -- one recorded on a reopen replaces the one cut off), then an undo of it. A full undo is what
    // happened now: its title and summary say so. A partial, refused, cut-off or late undo keeps the end's words (the
    // result line says what came of it). task_closed changes no words: it only adds the result line's why.
    //
    // | records (any arrival order)            | title            | summary                        |
    // |----------------------------------------|------------------|--------------------------------|
    // | end                                    | the end's        | the end's                      |
    // | end, undo all n of n                   | 已撤回            | 改动都撤回了（n 处）             |
    // | end, undo m of n / refused / cut off   | the end's        | the end's (line: why)          |
    // | end, undo expired / closed             | the end's        | the end's (line: why)          |
    // | closed, no end                         | 中断了            | —                              |

    /// All of the task's changes were undone: how many (nil otherwise).
    static func fullyUndone(_ t: TaskState) -> Int? {
        if case .undone(let n, let m, nil) = t.resultCardState, n == m, m > 0 { return m }
        return nil
    }

    /// A finished task's summary: what it did, or -- all of it undone -- that it was undone.
    static func summary(_ t: TaskState, lang: ResolvedLang) -> String {
        if let m = fullyUndone(t) { return L("All changes were undone (%d)", m, lang: lang) }
        return t.done?.summary ?? t.end?.summary ?? ""
    }

    /// An ending by its status alone.
    static func ending(_ status: String?, lang: ResolvedLang) -> String {
        switch status {
        case "succeeded": return L("Done", lang: lang)
        case "unconfirmed": return L("Done, but not confirmed. Please check", lang: lang)
        case "failed": return L("Didn't finish", lang: lang)
        case "cancelled": return L("Cancelled", lang: lang)
        case "stopped": return L("Stopped", lang: lang)
        case "environment": return L("The Mac's state didn't allow it", lang: lang)
        default: return L("Interrupted", lang: lang)
        }
    }

    /// Who started the task: the user's /cua, or the model.
    static func origin(_ t: TaskState, lang: ResolvedLang) -> String? {
        switch t.by {
        case "slash": return L("Started by you (/cua)", lang: lang)
        case "model": return L("Started by DeskMind", lang: lang)
        default: return nil
        }
    }

    /// The result card's line, from its one state (ResultCardState): what came of the undo, or why it can no longer
    /// be done; the minutes left while it is open (display only — `now` is the clock, never a gate). Nothing when the
    /// harness offered no undo (its card says why) and nothing closed it for a reason worth saying.
    static func resultLine(_ t: TaskState, hint: String? = nil, now: Double, lang: ResolvedLang) -> String? {
        // a refusal this client's own answer got (CardStore.hint): until the history speaks
        if t.resultCardState.isOpen, let h = hint {
            return CardStore.closingRefusals.contains(h) ? L("Undo expired", lang: lang) : L("Your answer didn't reach the task. Try again", lang: lang)
        }
        switch t.resultCardState {
        case .none, .answered: return nil
        case .open(let undo, let until):
            guard undo, let until else { return nil }
            let m = max(0, Int(((until - now) / 60).rounded(.up)))
            return m > 0 ? L("Undo available for %d more min", m, lang: lang) : nil
        case .undoing: return L("Undoing…", lang: lang)
        case .undone(let n, let m, let refused):
            guard let r = refused else { return L("Undid %d of %d", n, m, lang: lang) }
            return L("Undid %d of %d, then stopped: %@", n, m, r, lang: lang)
        case .undoExpired: return L("Undo expired: its time ran out", lang: lang)
        case .undoUnknown(let refused):
            let base = L("The undo was cut off: some of it may not have been undone. Please check", lang: lang)
            return refused.map { base + " · " + $0 } ?? base
        case .closed(let why):
            // (only when undo was offered: a card that never had it says why itself, and never reads as expired)
            guard t.undoOffered else { return nil }
            switch why {
            case "new_task": return L("Undo expired: another computer task started", lang: lang)
            case "session_end", "session_exit", "no_task":
                return L("Undo expired: DeskMind's helper quit, so the undo window ended early", lang: lang)
            case "linger", "deadline": return L("Undo expired: its time ran out", lang: lang)
            default: return L("Undo expired", lang: lang)
            }
        }
    }

    /// The undo button's VoiceOver hint, by the state.
    static func undoHint(_ s: ResultCardState, lang: ResolvedLang) -> String {
        s.undoEnabled ? L("Undoes what the task changed", lang: lang) : L("Undo is not available now", lang: lang)
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
    @Published var selected: String? {
        // (another session shown: the card mode of this one's card ends — a new move into it when it is back)
        didSet { if oldValue != selected { leaveCardMode() } }
    }
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
    ///
    /// Touched only on the UI queue (`uiQueue`: the main queue; a test's own) — every read and every write traps
    /// anywhere else (dispatchPrecondition, in release builds too). The watcher, the socket and the work queue hand
    /// over with `deliver` (#110 Codex review at 4a411c2: a clear from the watch thread overwrote a `sent` just
    /// recorded on main, and one card wrote two answers).
    var cards: CardStore {
        get { onUI(); return cardStore }
        set { onUI(); cardStore = newValue }
    }
    @Published private var cardStore = CardStore()
    /// The queue the window's model runs on (where `deliver` lands).
    let uiQueue: DispatchQueue
    private func onUI() { dispatchPrecondition(condition: .onQueue(uiQueue)) }
    private let uiKey = DispatchSpecificKey<Bool>()
    /// `f` now when on the UI queue, else queued to it.
    private func onUIQueue(_ f: @escaping () -> Void) { if DispatchQueue.getSpecific(key: uiKey) == true { f() } else { uiQueue.async(execute: f) } }
    /// The helper answers (its socket): the session list came back.
    @Published private(set) var reachable = true
    /// An open waits for DeskMind's helper to take the cloud switch (at most a few seconds): said meanwhile.
    @Published private(set) var waitingForHelper = false
    /// Cloud models are off in the settings: a session sends nothing (0.5 has no local-only session: it needs a cloud
    /// model, owner 10-22); the chat says so with a button to the settings.
    @Published private(set) var cloudOff = false
    /// Each card's height as laid out (CardView, unscrolled: a card never scrolls inside), and the room the pinned place
    /// above the composer has (MainSplitView): a card fits there when its whole height does (`cardFits`). One fact, read
    /// by where the card is drawn (pinned, or in place in the chat) and by the keys (an approve-type option takes no key
    /// on a card that does not fit: its content may be off screen; the mouse reaches its button only past the content).
    @Published private(set) var cardHeights: [String: Double] = [:]
    @Published private(set) var pinRoom: Double = 0
    /// Cards whose 「细节」 is open, by card key, and the words typed in a card's own field: kept here, not in the view, so
    /// that a card moving between the pinned place and the chat keeps them (#124 reviews). The card's height counts as
    /// it is, open or not: a card that outgrew the pinned place with its details open moves to the chat, open.
    @Published private(set) var openDetails: Set<String> = []
    @Published private(set) var cardDrafts: [String: String] = [:]
    func cardDraft(_ card: CardModel) -> String { cardDrafts[Self.cardKey(card)] ?? "" }
    func setCardDraft(_ card: CardModel, _ text: String) {
        let key = Self.cardKey(card)
        if text.isEmpty { cardDrafts[key] = nil } else if cardDrafts[key] != text { cardDrafts[key] = text }
    }

    let client: SessionClient
    private let names: SessionNames
    private let work: (@escaping () -> Void) -> Void
    /// THE place steer and answer lines are written (A9, #125 Codex re-review at 3c6f5cc): one job after another, in
    /// the order they were put in (`laneSeq`, on the UI queue). An answer's job decides there, right before its write,
    /// whether a steer for its card put in before it is still on its way (SessionState.steerPending) -- the decision and
    /// the write on the same lane, so no steer can come between them. The app passes a serial queue (serialLane); nil:
    /// `work` (tests: inline).
    private let lane: (@escaping () -> Void) -> Void
    private var laneSeq = 0
    private func nextSeq() -> Int { laneSeq += 1; return laneSeq }
    /// The app's write lane: a serial queue of its own.
    static func serialLane() -> (@escaping () -> Void) -> Void {
        let q = DispatchQueue(label: "deskmind.shell.lane", qos: .userInitiated)
        return { f in q.async(execute: f) }
    }
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
         deliver: @escaping (@escaping () -> Void) -> Void = { f in DispatchQueue.main.async(execute: f) },
         lane: ((@escaping () -> Void) -> Void)? = nil,
         uiQueue: DispatchQueue = .main) {
        self.uiQueue = uiQueue
        uiQueue.setSpecific(key: uiKey, value: true)
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
        liveSince = now()
        self.work = work
        self.lane = lane ?? work
        self.deliver = deliver
        client.clock = now        // (an exit the client infers for a session alive this run is stamped by this clock)
        client.onChange = { [weak self] id, _ in self?.changed(id) }
        // each refusal of an answer as it comes: one of ours goes to the UI queue to be matched; any other is dropped here
        client.onAnswerRefusal = { [weak self] id, e in self?.answerRefused(id, e) }
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

    /// Called from any thread (the watch thread too): the held answers' clear goes to the UI queue, carrying the
    /// switch's off-epoch it saw — it drops only picks made before that off (a clear that runs late, after the switch
    /// is on again, leaves the picks made since alone). The take-back's own check (CardStore.due's epoch) is what
    /// keeps a held answer from going after an off; this clear only makes the window show it at once.
    private func applySettings(reconcileIfModelChanged: Bool) {
        let off = !cloudOn()
        if client.modelOff != off {
            client.modelOff = off
            if reconcileIfModelChanged { work { [weak self] in self?.client.convergeAll() } }
        }
        if off {
            let epoch = client.offEpoch
            deliver { [weak self] in self?.cards.cloudOff(before: epoch) }
        }
    }

    /// The settings as the window shows them (on the main thread): cloud models on or off.
    func refreshSettings() {
        let off = !cloudOn()
        if cloudOff != off { cloudOff = off }
        if keysCloudOn == off { keysCloudOn = !off }
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
            logChanges(from: states[id], to: s)
            tabChanges(id, from: states[id], to: s)
            states[id] = s
            // a card that is no longer open: what the app held for it goes (a held answer is never sent then) — on the
            // UI queue only (flush runs there in the app; a test that delivers inline from a client thread hands it over)
            onUIQueue { [weak self] in
                guard let self else { return }
                var c = self.cards
                c.settle(id, self.client.state(id))
                if c != self.cards { self.cards = c; self.syncOwnReqs() }
            }
        }
        // the open session's problems are seen as they come (once per new stored line or process end: never a loop of
        // marks)
        if let sel = selected, ids.contains(sel), let s = states[sel], s.lastSeq > s.seenSeq || s.goneUpTo > s.seenGone,
           SessionStatus.problemShown(s) { client.markSeen(sel) }
        // a card no longer pinned anywhere: its height and its fold go (they were the layout's, not the card's) -- on
        // the UI queue, where CardStore is read
        onUIQueue { [weak self] in self?.dropLayoutFacts() }
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
        // a steer (A9): put in the write lane, marked on its card first when one is open (steerGoes), then written
        if case .steer(_, let run) = control {
            guard let (clientId, seq) = steerGoes(run, in: id) else { return }
            lane { [weak self] in
                guard let self else { return }
                // (a card that opened since it was put in: the steer is its too, from here)
                self.client.steerGoesNow(clientId, runId: run, seq: seq, in: id)
                let r = self.client.send(control, to: id, clientId: clientId)
                self.client.steerWritten(clientId, sent: r == .sent, in: id)
                if r != .sent { self.deliver { self.notSent(r, text: text, in: id) } }
            }
            return
        }
        work { [weak self] in
            guard let self else { return }
            let r = self.client.send(control, to: id, clientId: nil)
            if r != .sent { self.deliver { self.notSent(r, text: text, in: id) } }
        }
    }

    /// A computer task of its own, from the home screen's GoalRunView (harness engine): a new session, opened, then
    /// `cua` with the goal and its folder as the scope — the same session task the chat runs, so it shows with the
    /// chat's task row, cards and result card (A3's one state, the same canSend / respond path). The new session
    /// becomes the selected one once it is open. What came of it goes to `report`, on the UI queue, each once: the
    /// cloud switch's refusal, else the open (its session id, or failed), then the send (sent, refused, unavailable)
    /// — GoalRun's lifecycle (Shared/GoalRun.swift) is driven by these, never by the selected session.
    /// `clientId`: its cua's (the goal matches a refusal by it); `ticket`: the goal still wants it — over, the cua is
    /// never sent, and a cua that went while it became over is followed by a stop.
    func startTask(_ goal: String, scope: String?, clientId: String? = nil, ticket: GoalTicket? = nil,
                   report: @escaping (GoalLifecycle.Event) -> Void = { _ in }) {
        newConversation()
        let control = SessionControl.cua(goal, scope: scope)
        guard cloudAllows() else { report(.cloudRefused); return }
        openThenSend(control, text: goal, clientId: clientId, ticket: ticket, report: report)
    }

    /// The new conversation's first message: the session is opened (with the settings now), then the words sent. The
    /// words stay in the composer until the session is open (it takes no typing meanwhile: `opening`); not opened, they
    /// are still there; opened, they are the session's (sent, or an unsent bubble of it).
    private func openThenSend(_ control: SessionControl, text: String, clientId: String? = nil, ticket: GoalTicket? = nil,
                              report: @escaping (GoalLifecycle.Event) -> Void = { _ in }) {
        guard !opening else { report(.openFailed); return }
        opening = true
        work { [weak self] in
            guard let self else { return }
            // (a goal over before its open went: nothing is opened for it)
            if ticket?.over == true { self.deliver { self.opening = false; report(.openFailed) }; return }
            // (with the settings stored when it goes: SessionClient.desired())
            guard let id = self.client.open() else {
                self.deliver {
                    self.opening = false
                    self.notice = L("Couldn't start a conversation. Is DeskMind's helper running?", lang: self.lang())
                    report(.openFailed)
                }
                return
            }
            self.deliver {
                self.opening = false
                if self.drafts[""] == text { self.drafts[""] = "" }
                self.states[id] = self.client.state(id)
                if self.selected == nil { self.selected = id }
                self.rebuild()
                report(.opened(sid: id))
            }
            // a goal over meanwhile (its bound ran out while the open waited): its cua is never sent
            if ticket?.over == true { return }
            let r = self.client.send(control, to: id, clientId: clientId)
            // (over while the send went: the goal's guard stops the task it starts, by its run — never a run-less
            // stop here, which the session would take for whatever task runs)
            self.deliver {
                switch r {
                case .sent: report(.sent)
                case .refused(let code): self.notSent(r, text: text, in: id); report(.refused(code))
                case .unavailable: self.notSent(r, text: text, in: id); report(.unavailable)
                }
            }
        }
    }

    /// Words not sent: the client holds them as an unsent bubble with its reason (「重新发送」), whatever the refusal —
    /// never put back in the composer (a newer draft there stays as it is). No helper: said once too.
    private func notSent(_ r: SessionClient.SendResult, text: String, in id: String) {
        if r == .unavailable { notice = L("DeskMind's helper didn't answer. Your message is kept below; send it again.", lang: lang()) }
    }

    /// `stop {client_id}` (harness#72) to one session: the task the cua with that client id started, or — none yet —
    /// the cua cancelled. `sent`: the helper took the line (true) or did not answer (false); the session's answer is
    /// session.stop_ack, on its stream. The send reopens an exited session (it answers from its history).
    func stopCua(sessionId id: String, clientId: String, sent: @escaping (Bool) -> Void) {
        work { [weak self] in
            guard let self else { return }
            let r = self.client.send(.stopCua(clientId: clientId), to: id)
            self.deliver { sent(r == .sent) }
        }
    }

    /// Stop one task of one session by its run (GoalRun). Never run-less: the session would stop whatever task runs.
    func stop(sessionId id: String, runId: String) {
        cards.stopping(runId)
        work { [weak self] in _ = self?.client.send(.stop(runId: runId), to: id) }
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
    /// True when it picked or sent something (a key that did nothing then passes on: ShellModel.keyDown). A click on
    /// an option — by the mouse or VoiceOver's press, the same action — is a click on its card: a move into it.
    @discardableResult
    func click(_ button: CardModel.Button, session: String? = nil, by: UIEvent.Pick = .click, place: UIEvent.Place = .chat) -> Bool {
        // (`session`: the card's own -- the float answers the running task's card whatever session the window shows)
        guard let id = session ?? selected else { return false }
        if id == selected, let ask = button.askId, let p = pinnedTakingPicks(), p.askId == ask, p.runId == button.runId { enterCardMode(p) }
        // the one predicate (canSend): what it says is what happens
        guard canSend(button, session: id) else {
            if !button.role.reachesNoModel && !cloudOn() { _ = cloudAllows() }     // (says why: the cloud model is off)
            return false
        }
        let a = CardModel.answer(button)
        if a.askId == nil {
            let action = cards.respond(a, sessionId: id, in: client.state(id))
            if action != .none { logPick(a, role: button.role, by: by, place: place) }
            return act(action, in: id)
        }
        return pick(a, role: button.role, by: by, place: place, immediate: button.role == .cancel, in: id)
    }

    /// The user's own words on a card that takes them (its own field): on a card with an approve-type option, only once
    /// its whole body has been on screen, as its approve (words can approve too; they are never read). Held for the
    /// take-back as a click is.
    func answer(_ card: CardModel, text: String) {
        guard let id = selected, let a = card.answer(text: text), cloudAllows() else { return }
        pick(a, role: .other, by: .typed, immediate: false, in: id)
    }

    // MARK: card keys (1–9): card mode
    //
    // A digit acts on a card only after the user explicitly moved into that card (#111 Codex review at 86878f6: two
    // rounds of time-based guards each let typing in progress, or a fast correction, decide for the user; timing alone
    // never turns keys on now). The explicit moves: a click on the card (anywhere on it, an option too), or Esc / Tab
    // in the main window (out of whatever was being typed), each while the card takes picks and has been on screen for
    // CardKeys.cardOnScreen. Card mode belongs to that card: a new card needs a new move.
    //
    // | state                                                   | 1–9                                              |
    // |---------------------------------------------------------|--------------------------------------------------|
    // | no explicit move to this card (composer typing, focus   | not the card's: typed, or nothing                |
    // |   lost, a new card arrived)                             |                                                  |
    // | card mode for this card, a field being typed in, ⌘⌃⌥,  | not the card's                                   |
    // |   an auto-repeat                                        |                                                  |
    // | card mode for this card                                 | picks that option (approve-type: once the whole  |
    // |                                                         |   card was seen), held for the take-back         |
    // | card mode, a pick held                                  | another option replaces it (the 3 s start again);|
    // |                                                         |   the way out cancels at once                    |
    //
    // A key's label, the 「按 n」 of its hint and the dispatcher read one predicate, `keyWorks`, which holds every gate
    // the key path has (#111 review at ba3eec8): card mode for this card (by run and ask_id), the card on screen in the
    // key window of the active app for CardKeys.cardOnScreen since it was last (re)shown there, it takes a pick (the
    // client's newest state: not answered, sent, expired or voided), the control has a key, an approve-type option only
    // once the whole card was seen, a model-reaching option only while cloud models are on, no field being edited and
    // no input-method composition. keyDown parses the event (a digit, no ⌘⌃⌥, not repeated) and then acts exactly when
    // keyWorks says so. Every input of those gates is published, so the labels follow it.

    /// Cards whose view is on screen (CardView's appear / disappear), by card key, counted: one card can have two views
    /// for a moment -- moving between the pinned place and the chat, the new one appears before the old one goes
    /// (#124 review) -- and it is off screen only when the last one went.
    private var visible: [String: Int] = [:]
    /// Since when each visible card has been on screen in the key window of the active app (set when it appears there,
    /// or when the window becomes key / the app active / the window is restored with it on screen; cleared when it
    /// leaves): the 1 s counts from then.
    private var shownAt: [String: Double] = [:]

    // MARK: the UI event log (Shared/UIEvents.swift)

    /// Where the log's events go (tests take them), and the main window's state as the app sees it now.
    var uiRecord: (UIEvent) -> Void = UIEvents.record
    var uiWindow: () -> UIEvent.Window = { .front }
    /// When each card was first shown here, by card key: a pick's time from it, a held answer's from its pick.
    private var cardShownAt: [String: Double] = [:]
    private var cardPickedAt: [String: Double] = [:]
    /// When this model began watching: a change made by a line written before it is history replayed (a relaunch, a
    /// history fill), not something the user saw happen here (UIEvents.changes).
    private var liveSince: Double = 0

    private func logChanges(from old: SessionState?, to new: SessionState) {
        for (k, e) in UIEvents.cardChanges(from: old, to: new, window: uiWindow(), liveSince: liveSince) {
            if case .cardShown = e { cardShownAt[k] = now() }
            if case .cardEnded = e { cardShownAt[k] = nil; cardPickedAt[k] = nil; placesLogged = placesLogged.filter { !$0.hasPrefix(k + "|") } }
            uiRecord(e)
        }
    }

    /// The cards the float showed (CardPlacement.Shown), by card key and place: each logged once.
    private var placesLogged: Set<String> = []
    /// The float shows `card` (A2): whole (`.float`) or its title and 「去主窗口回答」 (`.floatSummary`) -- logged once
    /// per card and place, as the chat's card_shown is (the time on screen still the card's first).
    func cardPlaced(_ card: CardModel, place: UIEvent.Place, in s: SessionState) {
        let key = Self.cardKey(card)
        guard place != .chat, placesLogged.insert(key + "|" + place.rawValue).inserted else { return }
        let c = card.askId.flatMap { a in s.task(card.runId)?.cards.first { $0.askId == a } }?.card
        uiRecord(.cardShown(run: UIEvent.ID(card.runId), ask: card.askId.flatMap(UIEvent.ID.init), kind: UIEvent.CardKind(c?.kind ?? "result"),
                            place: place, window: uiWindow(), options: card.buttons.count, details: c.map { $0.plan != nil || $0.consent != nil } ?? false))
    }

    /// The card an answer is for, as the log names it.
    private func logCard(_ a: CardAnswer) -> (run: UIEvent.ID?, ask: UIEvent.ID?, kind: UIEvent.CardKind) {
        let t = states.values.lazy.compactMap { $0.task(a.runId) }.first
        let kind: String = a.askId.map { id in t?.cards.first { $0.askId == id }?.card.kind ?? "" } ?? "result"
        return (UIEvent.ID(a.runId), a.askId.flatMap(UIEvent.ID.init), UIEvent.CardKind(kind))
    }

    private func logPick(_ a: CardAnswer, role: CardModel.Role, by: UIEvent.Pick, place: UIEvent.Place) {
        let c = logCard(a), key = CardStore.key(a)
        // (not known for a card shown before this model began watching: left out, never 0)
        let ms = cardShownAt[key].map { max(0, Int(((now() - $0) * 1000).rounded())) }
        cardPickedAt[key] = now()
        uiRecord(.cardPick(run: c.run, ask: c.ask, kind: c.kind, option: UIEvent.Option(role), by: by, place: place, ms: ms))
    }

    /// The answer is being written: what the log will say once the helper took it (write's `sent`).
    private func sentEvent(_ a: CardAnswer, key: String) -> UIEvent {
        let c = logCard(a)
        let held = cardPickedAt[key].map { Int(((now() - $0) * 1000).rounded()) } ?? 0
        cardPickedAt[key] = nil
        return .cardSent(run: c.run, ask: c.ask, kind: c.kind, heldMs: max(0, held))
    }
    // MARK: the right column's tabs (M5: 「现在」 / 「过程」)

    /// Each conversation's tabs (ProcessTabs), by session id.
    @Published private(set) var tabs: [String: ProcessTabs] = [:]
    /// A task of this window ended, as it happened here (not a history read): the app prunes the run records then.
    var onTaskEnded: () -> Void = {}

    /// What a session's change says to its tabs: a task that started, one that ended -- only as they happen here (their
    /// own times after this model began, as the UI log's changes are -- no time said: live; a history read or a
    /// relaunch's replay moves no tab).
    private func tabChanges(_ id: String, from old: SessionState?, to new: SessionState) {
        var t = tabs[id] ?? ProcessTabs()
        let before = t
        var ended = false
        for task in new.tasks {
            let was = old?.task(task.runId)
            if was == nil, task.running, (task.startedAt ?? .infinity) >= liveSince { t.apply(.taskStarted(task.runId)) }
            if was?.running == true, task.ended, (task.endedAt ?? .infinity) >= liveSince { t.apply(.taskDone(task.runId)); ended = true }
        }
        if t != before { tabs[id] = t }
        if ended { onTaskEnded() }
    }

    /// The selected conversation's tabs.
    var currentTabs: ProcessTabs { selected.flatMap { tabs[$0] } ?? ProcessTabs() }
    /// The user picks a tab in the right column.
    func pickTab(_ tab: ProcessTabs.Tab) {
        guard let id = selected else { return }
        tabs[id, default: ProcessTabs()].apply(.picked(tab))
    }
    /// The user clicks a task's message in the chat: its 过程.
    func showProcess(_ runId: String) {
        guard let id = selected else { return }
        tabs[id, default: ProcessTabs()].apply(.clickedTask(runId))
    }
    /// The runs whose folders may still be written: a task running, or one whose result card waits (its process
    /// lingers) -- never pruned (RunRetention).
    var liveRuns: Set<String> {
        Set(states.values.flatMap { $0.tasks.filter { $0.running || $0.resultCardState.isOpen }.map(\.runId) })
    }

    /// The card the user moved into (card mode), by card key.
    @Published private(set) var keyCard: String?
    /// The one way the window moves the keyboard focus (lead 10-25): the user's own Esc out of a card in card mode, in
    /// the key window, asks once for the composer (Composer takes it). Nothing else makes a request -- never a card
    /// arriving, ending or voided -- and a request is taken once (`takeFocus`: a re-render does not focus again) and
    /// dropped when the window stops being the key one.
    @Published private(set) var focusRequest = 0
    /// Conversations whose live view the user popped out into the float (⌘⇧P, handoff §3.7: kept on the conversation):
    /// the float shows the picture even while the window is in front; the right column shows a placeholder.
    @Published private(set) var poppedOut: Set<String> = []
    func togglePopOut() {
        guard let id = selected else { return }
        if poppedOut.contains(id) { poppedOut.remove(id) } else { poppedOut.insert(id) }
    }
    private var focusTaken = 0
    func takeFocus(_ n: Int) -> Bool {
        guard n > focusTaken, windowKey else { return false }
        focusTaken = n
        return true
    }
    /// An option of a card in place in the chat took the keyboard focus (the user's Tab): the window scrolls it into
    /// view (its ScrollViewReader takes this). Never set by a card arriving.
    @Published private(set) var scrollRequest: (id: String, n: Int)?
    private var scrolls = 0
    func requestScroll(to id: String) { scrolls += 1; scrollRequest = (id, scrolls) }
    /// Where the window scrolls to show an option of a card in place there (the option's view id).
    static func optionAnchor(_ card: CardModel, _ index: Int) -> String { "option/\(cardKey(card))/\(index)" }
    /// The main window is the key window of the active app (CardKeyMonitor's notifications; true until told otherwise).
    @Published private(set) var windowKey = true
    /// A field in the main window is being edited / an input method composes there (CardKeyMonitor: on every key-down
    /// and on every window update).
    @Published private(set) var editingText = false
    @Published private(set) var composing = false
    /// Published so that labels follow the cloud switch (`cloudOn` is read live; this changes with it).
    @Published private(set) var keysCloudOn = true

    func cardShown(_ card: CardModel) {
        let k = Self.cardKey(card)
        visible[k, default: 0] += 1
        if windowKey && shownAt[k] == nil { shownAt[k] = now() }
    }
    /// The card left the screen (its view went: the window closed, another session shown, the card answered): its card
    /// mode ends with it, and its time on screen starts again when it is back.
    ///
    /// Only that card's state goes (its time on screen, and card mode when it is its): a card's appear and disappear
    /// may come in any order — an animated replacement shows the new card before the old one goes (#111 Codex review
    /// at 656d5a9) — so everything here is by card key. The whole reset (every card) is the window's, the app's and the
    /// session's (windowLeft, leaveCardMode).
    func cardHidden(_ card: CardModel) {
        let k = Self.cardKey(card)
        let n = (visible[k] ?? 0) - 1
        visible[k] = n > 0 ? n : nil
        guard n <= 0 else { return }       // (another view of it is still on screen: its time and card mode stay)
        shownAt[k] = nil
        if keyCard == k { keyCard = nil }
    }
    /// Card mode ends: the card is no longer on screen in the key window — the window closed or is no longer the key
    /// one, another app came forward (leaving the app ends it, coordinator 10-24), another session shown. A new explicit
    /// move is needed, and the 1 s counts again from when it is back (windowReturned).
    func leaveCardMode() {
        if keyCard != nil { keyCard = nil }
        shownAt = [:]
    }
    /// The main window is no longer the key window of the active app (resigned key, closed, minimised, the app went
    /// back): card mode ends; the cards on screen are not counted as shown until it returns.
    func windowLeft() {
        if windowKey { windowKey = false }
        focusTaken = focusRequest              // (a request not taken yet is dropped: the window is not the key one)
        leaveCardMode()
    }
    /// The main window is the key window of the active app again (became key, the app active, restored): the cards on
    /// screen count as shown from now.
    func windowReturned() {
        if !windowKey { windowKey = true }
        let t = now()
        for k in visible.keys where shownAt[k] == nil { shownAt[k] = t }
    }
    /// Where the typing is in the main window (the monitor, on each key-down and window update).
    func focusChanged(editing: Bool, composing c: Bool) {
        if editingText != editing { editingText = editing }
        if composing != c { composing = c }
    }

    /// The pinned card that takes picks in the selected session (the client's newest state), as a CardModel.
    private func pinnedTakingPicks() -> CardModel? {
        guard let id = selected else { return nil }
        let s = client.state(id)
        guard let p = pinned(s), p.phase.takesPick else { return nil }
        return CardModel(card: p.card.card, runId: p.runId, askId: p.card.askId)
    }

    /// An explicit move into `card` (a click on it, Esc / Tab): card mode for it — only for the pinned card while it
    /// takes picks and has been on screen in the key window for CardKeys.cardOnScreen (a move made as the card
    /// appeared, or right after the window came back, was not about it).
    func enterCardMode(_ card: CardModel) {
        let k = Self.cardKey(card)
        guard windowKey, let p = pinnedTakingPicks(), Self.cardKey(p) == k, let since = shownAt[k], now() - since >= CardKeys.cardOnScreen else { return }
        if keyCard != k { keyCard = k }
    }

    /// Card mode is on for `card` (by its run and ask_id: never another card of the session, an older result card
    /// included), it is the pinned card that takes picks, on screen in the key window.
    func keysActive(_ card: CardModel) -> Bool {
        let k = Self.cardKey(card)
        guard windowKey, keyCard == k, shownAt[k] != nil, let p = pinnedTakingPicks() else { return false }
        return Self.cardKey(p) == k
    }

    /// THE predicate for a key: whether pressing `control`'s key on `card` picks it now — every gate of the key path
    /// (see above). The label, the hint's 「按 n」 and keyDown read only this.
    func keyWorks(_ card: CardModel, _ control: CardLayout.Control) -> Bool {
        guard control.key != nil, !editingText, !composing, keysActive(card), let id = selected else { return false }
        let b = control.button
        guard b.runId == card.runId, b.askId == card.askId, b.askId != nil, selected == id else { return false }
        // (a digit acts from a distance: only on a card that fits whole, every control of it on screen -- #124 Codex
        // review at 80c339e. On a card in place in the chat the focus-based keys still work -- Tab / ⇧Tab into it,
        // Space / Return on the focused control, Esc -- and the focused option is scrolled into view: lead 10-25)
        if !cardFits(card) { return false }
        return canSend(b)
    }

    /// What CardKeyMonitor is given, wherever a pinned card is shown (the chat, a goal's screen): the one wiring.
    var cardKeyHandlers: CardKeyHandlers {
        CardKeyHandlers(
            onKey: { [weak self] c, cmd, key, editing, rep, composing in
                self?.keyDown(characters: c, commandLike: cmd, mainWindowIsKey: key, editingText: editing, isRepeat: rep, composing: composing) ?? false
            },
            onLeave: { [weak self] in self?.windowLeft() },
            onReturn: { [weak self] in self?.windowReturned() },
            onFocus: { [weak self] editing, composing in self?.focusChanged(editing: editing, composing: composing) })
    }

    /// Every key-down of the main window (CardKeyMonitor, before it goes anywhere): true only when it acted on the
    /// pinned card (it is consumed then; otherwise it passes on). It first records where the typing is (the event's
    /// own: a field being edited, a composition, the window key). Esc and Tab (⇧Tab too), with no ⌘⌃⌥, not repeated,
    /// no field being edited and no composition, are explicit moves into the pinned card (never consumed: Esc in a
    /// field cancels the input method's candidates there, and is not a move). A digit (no ⌘⌃⌥, not repeated) acts
    /// exactly when keyWorks says its control does.
    func keyDown(characters: String?, commandLike: Bool, mainWindowIsKey: Bool, editingText editing: Bool, isRepeat: Bool, composing c: Bool = false) -> Bool {
        focusChanged(editing: editing, composing: c)
        if mainWindowIsKey { if !windowKey { windowReturned() } } else { windowLeft() }
        let p = pinnedTakingPicks()
        let held = p.flatMap { cards.picks[Self.cardKey($0)] } != nil
        let what = CardKeys.action(characters: characters, commandLike: commandLike, isRepeat: isRepeat,
                                   CardKeys.Context(inCard: p.map(keysActive) ?? false, held: held, editing: editingText, composing: composing))
        switch what {
        case .none: return false
        case .enterCard:
            if let p { enterCardMode(p) }
            return false        // (Esc / Tab go on: the focus moves natively; Esc cancels nothing in a field here)
        case .leaveCard:
            if keyCard != nil {
                keyCard = nil
                if windowKey { focusRequest += 1 }     // (the focus funnel: back to the composer)
            }
            return false
        case .takeBack:
            guard let p else { return false }
            takeBack(p)
            return true
        case .sendNow:
            guard let p, let id = selected else { return false }
            let key = Self.cardKey(p)
            guard let token = cards.picks[key]?.token else { return false }
            due(key, token: token, in: id)
            return true
        case .digit(let n):
            guard let p, let ctl = CardLayout(p).control(forKey: n), keyWorks(p, ctl), let id = selected else { return false }
            // (keyWorks said yes: act, with no gate of its own)
            return pick(CardModel.answer(ctl.button), role: ctl.button.role, by: .digit, immediate: ctl.button.role == .cancel, in: id)
        }
    }

    /// Key `n` (1–9, CardKeys) on the pinned card: its n-th control as shown (CardLayout), picked as a click is — held for
    /// the take-back, an approve-type option only once the whole card was seen. False when it picks nothing (the key is
    /// the window's then).
    @discardableResult
    func pressKey(_ n: Int) -> Bool {
        guard let id = selected, let s = states[id], let p = pinned(s), p.phase.takesPick else { return false }
        let card = CardModel(card: p.card.card, runId: p.runId, askId: p.card.askId)
        guard let c = CardLayout(card).control(forKey: n) else { return false }
        return click(c.button, by: .digit)
    }

    /// 「撤回」 within the take-back: the held answer is dropped, never sent; the card waits again.
    func takeBack(_ card: CardModel) {
        let key = Self.cardKey(card)
        guard let p = cards.picks[key] else { return }
        cards.takeBack(key)
        cardPickedAt[key] = nil
        let c = logCard(p.answer)
        uiRecord(.cardTakeBack(run: c.run, ask: c.ask, kind: c.kind))
    }

    /// 「现在回答」 on an expired card: the task looks again and asks a new card (reask). Sent once.
    func answerNow(_ runId: String, askId: String, session: String? = nil) {
        guard let id = session ?? selected, answerMayGo(runId: runId, askId: askId, in: id), cloudAllows(),
              cards.answerNow(runId, askId: askId, sessionId: id, in: client.state(id)) else { return }
        let key = CardStore.key(runId: runId, askId: askId)
        let kind = states[id]?.task(runId)?.cards.first { $0.askId == askId }?.card.kind ?? ""
        uiRecord(.cardReask(run: UIEvent.ID(runId), ask: UIEvent.ID(askId), kind: UIEvent.CardKind(kind)))
        let seq = nextSeq()
        lane { [weak self] in
            guard let self else { return }
            // (decided again at the write, as an answer is: write)
            if self.client.state(id).steerPending(runId: runId, askId: askId, before: seq) { self.deliver { self.cards.reaskNotSent(key) }; return }
            if self.client.send(.reask(runId: runId), to: id) != .sent { self.deliver { self.cards.reaskNotSent(key) } }
        }
    }

    /// A card whose own words wait for its whole body: one with an approve-type option (#107 re-review).
    /// Whether the card's own field (and its Send) takes words now: as `answer` sends them (the field is drawn after
    /// the card's content: reaching it is reading past it).
    func wordsEnabled(_ card: CardModel, in s: SessionState) -> Bool { answerable(card, in: s) && answerMayGo(runId: card.runId, askId: card.askId, in: s.sessionId ?? selected ?? "") }

    static func cardKey(runId: String, askId: String?) -> String { CardStore.key(runId: runId, askId: askId) }
    static func cardKey(_ card: CardModel) -> String { cardKey(runId: card.runId, askId: card.askId) }

    /// A steer on its way ends (A9): the session refused it (by its client id), or the card is no longer open -- its
    /// ending, the run's word (ask_void why steer, H5 voids it before the steer goes on). Taken while the card is still
    /// open, it stays marked: the card's options must not take a click between the session storing the steer and its
    /// ask_void (#125 delta check at 4945311). UI queue.
    /// A steer for `run` (the task it names) is put in the write lane of session `id`, with its client id (a new one,
    /// or `resending`'s) and its place in the lane; when that task's card is open, in one step its held pick goes (its
    /// timer finds nothing to send) and the steer is marked on the card (SessionClient.steerEnqueued). nil: the same
    /// words' attempt is in the lane already (a second 「重新发送」): nothing is put in. UI queue.
    private func steerGoes(_ run: String?, in id: String, resending: String? = nil) -> (clientId: String, seq: Int)? {
        let cid = resending ?? client.newClientId(), seq = nextSeq()
        let open = states[id].flatMap { cards.pinned($0) }.flatMap { p in
            p.card.outcome == .open && (run == nil || run == p.runId) ? (runId: p.runId, askId: p.card.askId) : nil
        }
        guard client.steerEnqueued(cid, card: open, seq: seq, in: id) else { return nil }
        if let open { cards.stopping(open.runId) }
        return (cid, seq)
    }

    /// Whether an answer for the card may be written now, as far as steers go: none of ours for it on its way (the
    /// client's state, the one the lane reads before it writes). The window's buttons, the keys, typed words, the
    /// float and 「现在回答」 read it; the lane decides again at the write (write, answerNow).
    func answerMayGo(runId: String, askId: String?, in id: String) -> Bool { !client.state(id).steerPending(runId: runId, askId: askId) }

    /// The layout facts of cards no longer pinned anywhere (nor an open result card) go. UI queue.
    private func dropLayoutFacts() {
        let pinnedKeys = Set(states.values.compactMap { cards.pinned($0) }.map { Self.cardKey(runId: $0.runId, askId: $0.card.askId) })
        let results = Set(states.values.flatMap { $0.tasks }.filter { $0.resultCardState.isOpen }.map(\.runId))
        let keep = { (k: String) in pinnedKeys.contains(k) || results.contains(k) }
        if cardHeights.keys.contains(where: { !keep($0) }) { cardHeights = cardHeights.filter { keep($0.key) } }
        if openDetails.contains(where: { !keep($0) }) { openDetails = openDetails.filter(keep) }
        if cardDrafts.keys.contains(where: { !keep($0) }) { cardDrafts = cardDrafts.filter { keep($0.key) } }
    }

    /// The card's height as laid out (its view's geometry), as it is -- 「细节」 open or not (#124 Codex review at 80c339e:
    /// a card kept pinned at its folded height grew past the window with its details open, its controls off screen) --
    /// and the pinned place's room (the window's that pins the card: the chat column, or a goal's screen).
    func cardLaidOut(_ card: CardModel, height: Double) {
        let key = Self.cardKey(card)
        guard height > 0 else { return }
        if cardHeights[key] != height { cardHeights[key] = height }
    }
    func detailsOpen(_ card: CardModel) -> Bool { openDetails.contains(Self.cardKey(card)) }
    func setDetails(_ card: CardModel, open: Bool) {
        let key = Self.cardKey(card)
        if open { openDetails.insert(key) } else { openDetails.remove(key) }
    }
    func pinRoom(columnHeight: Double) {
        let r = CardBody.pinRoom(columnHeight: columnHeight)
        if pinRoom != r { pinRoom = r }
    }
    /// The card fits in the pinned place, whole: laid out, and no taller than the room. Not yet laid out: not known --
    /// it is drawn pinned to be measured, and its approve-type keys wait.
    func cardFits(_ card: CardModel) -> Bool { cardFits(Self.cardKey(card)) }
    func cardFits(_ key: String) -> Bool { cardHeights[key].map { CardBody.fits(height: $0, room: pinRoom) } ?? false }
    /// Where the pinned card is drawn: pinned while it fits, is not laid out yet, or its window has not said its room
    /// (never two copies: the in-place one only when this says no -- #124 review at 64547f9); else in place in the
    /// window's scroll, with one line pinned (its title and 「跳到卡片」). Both windows draw it through PinnedCard and
    /// TaskRow, which read this one predicate.
    func cardPinnedWhole(_ card: CardModel) -> Bool { pinRoom <= 0 || cardHeights[Self.cardKey(card)] == nil || cardFits(card) }

    /// Whether this button takes a click now: its card can be answered (canSend).
    func buttonEnabled(_ b: CardModel.Button, card: CardModel, in s: SessionState) -> Bool { canSend(b, session: s.sessionId) }

    /// THE predicate for one option of one card (#114 Codex review at 7553637): whether pressing it now sends its answer
    /// (or holds it for the take-back). The button's enabled state, its VoiceOver state, the key path (keyWorks) and the
    /// click all read this, and nothing else decides: the card takes this option now (an ask card: it is the open one
    /// and takes a pick; a result card: it is open, the option is one it offers — undo only while offered — and no answer
    /// of ours is on its way), a model-reaching option only while cloud models are on. Read against the client's newest
    /// state, the one CardStore checks as it writes. (A card no longer scrolls inside, and what goes out is laid out
    /// before 「可以」 (A2, invariant 3): a click is never gated on scrolling; an approve-type option's key is, on a card
    /// that does not fit -- keyWorks.)
    func canSend(_ b: CardModel.Button, session: String? = nil) -> Bool {
        guard let id = session ?? selected else { return false }
        if !answerMayGo(runId: b.runId, askId: b.askId, in: id) { return false }     // (a steer on its way: A9)
        let s = client.state(id)
        if !b.role.reachesNoModel && !cloudOn() { return false }
        let a = CardModel.answer(b)
        guard let ask = b.askId else { return cards.wouldRespond(a, in: s) }
        guard let t = s.task(b.runId), let c = t.cards.first(where: { $0.askId == ask }), cards.phase(c, of: t).takesPick else { return false }
        return cards.wouldPick(a, askId: ask, in: s)
    }

    /// A pick on its card (CardStore.pick, against the newest state the client has): held, then — its take-back run
    /// out — written once; or written now.
    @discardableResult
    private func pick(_ a: CardAnswer, role: CardModel.Role, by: UIEvent.Pick, place: UIEvent.Place = .chat, immediate: Bool, in id: String) -> Bool {
        guard answerMayGo(runId: a.runId, askId: a.askId, in: id) else { return false }
        let action = cards.pick(a, sessionId: id, immediate: immediate, now: now(), offEpoch: client.offEpoch, in: client.state(id))
        if action != .none { logPick(a, role: role, by: by, place: place) }   // (before a send at once, which logs its own)
        return act(action, in: id)
    }

    @discardableResult
    private func act(_ action: CardStore.Action, in id: String) -> Bool {
        switch action {
        case .none: return false
        case .send(let key, let a): write(a, key: key, in: id)
        case .hold(let key, let token):
            takeBackAfter(CardStore.takeBack) { [weak self] in self?.due(key, token: token, in: id) }
        }
        return true
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

    /// The req_ids CardStore awaits, mirrored for the feeding thread (which may not read CardStore): a refusal whose
    /// req_id is not one of them is dropped as it comes, and none is ever kept in a buffer that could evict ours.
    private let reqLock = NSLock()
    private var ownReqs: Set<String> = []
    private func syncOwnReqs() { let now = Set(cards.issued.keys); reqLock.lock(); ownReqs = now; reqLock.unlock() }

    /// A session's refusal of a respond / answer (any thread): ours goes to the UI queue and is matched there, once.
    private func answerRefused(_ id: String, _ e: SessionErrorEvent) {
        guard let r = e.reqId else { return }
        reqLock.lock(); let mine = ownReqs.contains(r); reqLock.unlock()
        guard mine else { return }
        onUIQueue { [weak self] in
            guard let self else { return }
            self.cards.refused(e, sessionId: id, in: self.client.state(id))
            self.syncOwnReqs()
        }
    }

    /// A fresh id for each answer line written (tests set their own).
    var newReqId: () -> String = { "rq_" + UUID().uuidString.lowercased() }

    /// Writes an answer with a fresh req_id, recorded in CardStore first (here, on the UI queue); a failed write takes
    /// both back on the UI queue.
    private func write(_ a: CardAnswer, key: String, in id: String) {
        let req = newReqId()
        cards.issue(req, sessionId: id, key: key, answer: a)
        syncOwnReqs()
        let sent = sentEvent(a, key: key)
        let seq = nextSeq()
        lane { [weak self] in
            guard let self else { return }
            // the one decision, at the write: a steer for this card put in the lane before this answer, still on its
            // way -- the answer is not written, and taken back as a write that did not go is (notSent): the card takes
            // an answer again once the steer is over (#125 Codex re-review at a79b086: it stayed 「已发送」)
            if self.client.state(id).steerPending(runId: a.runId, askId: a.askId, before: seq) {
                self.deliver { self.cards.notSent(key, a); self.cards.unissue(req); self.syncOwnReqs() }
                return
            }
            let r = self.client.answer(a, in: id, reqId: req)
            // (the log's card_sent once the helper took the line; a write that did not go is no answer)
            if r != .sent { self.deliver { self.cards.notSent(key, a); self.cards.unissue(req); self.syncOwnReqs() } }
            else { self.deliver { self.uiRecord(sent) } }
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
        // a steer sent again: put in the write lane as a first send (steerGoes) -- once while its attempt is in it
        if let o = client.state(id).unsent.first(where: { $0.id == outgoing }), case .steer(_, let run)? = o.original {
            guard let (_, seq) = steerGoes(run, in: id, resending: outgoing) else { return }
            lane { [weak self] in
                guard let self else { return }
                self.client.steerGoesNow(outgoing, runId: run, seq: seq, in: id)
                let r = self.client.resend(outgoing, in: id)
                self.client.steerWritten(outgoing, sent: r == .sent, in: id)
            }
            return
        }
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
    /// does not know, which might (it fails closed): its key works only on a card that fits whole where it is pinned
    /// (owner: never approve what you can't fully see; fable 10-25 for A2). The way out, a pick, a skip and undo are not.
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

    /// A whole card fits the pinned place: laid out, and no taller than its room.
    static func fits(height: Double, room: Double) -> Bool { height > 0 && room > 0 && height <= room + 0.5 }

    /// The pinned place's room in a chat column `columnHeight` tall: half of it, so the chat and the composer keep
    /// their place; a card taller than that stays in place in the chat.
    static func pinRoom(columnHeight: Double) -> Double { max(0, columnHeight * 0.5) }

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

/// The card keys' handlers (CardKeyMonitor's): a key-down with what its gate needs (true: consumed — it picked), the
/// window left / back, where the typing is. ShellModel.cardKeyHandlers gives the one set every screen installs.
struct CardKeyHandlers {
    let onKey: (_ characters: String?, _ commandLike: Bool, _ mainWindowIsKey: Bool, _ editingText: Bool, _ isRepeat: Bool, _ composing: Bool) -> Bool
    let onLeave: () -> Void
    let onReturn: () -> Void
    let onFocus: (_ editing: Bool, _ composing: Bool) -> Void
}
