// A card's state in one place, by run_id + ask_id (M2 A1). The invariant: a card has exactly one ending — answered,
// voided or expired; every view reads the same state; an answer is sent at most once.
//
// Who owns what:
// - The ending is the harness's word on the card, folded from the events alone (SessionReducer: resumed, ask_void —
//   `timeout` is an expiry —, a newer card, the task's end, its process's end). The app never keeps its own record of
//   how a card ended.
// - What only the app knows lives here: an answer held for its 3-second take-back (`picks`, never sent yet), an answer
//   written to the session whose effect has not come (`sent`), and an 「现在回答」 (reask) on its way for an expired card
//   (`reasks`). All of it is in memory: an app restart drops it, so a held answer is never sent after a restart.
// - `phase` puts the two together. The chat line, the pinned card, VoiceOver, the status dot and the session's subtitle
//   read `phase` (ShellModel.phase / ShellModel.pinned) and nothing else; the float (M3) reads it too.
//
// One card (plan §4.2; owner 10-24: the take-back is 3 s, 「先别做了」 and Stop act at once, only action cards expire):
//
// | phase \ event | pick      | 先别做了 / Stop | 3 s up      | resumed  | ask_void steer/stop/ended, | ask_void timeout | 现在回答 | restart       |
// |               |           |                 |             |          | newer card, task_done, exit |                  |          |               |
// |---------------|-----------|-----------------|-------------|----------|-----------------------------|------------------|----------|---------------|
// | open          | pending   | sent at once    | —           | answered | voided                      | expired          | —        | open          |
// | pending       | re-pick:  | pick dropped,   | sent (if    | answered | voided, pick dropped        | expired, pick    | —        | open (pick    |
// |               | new timer | sent at once    | still open) | (dropped)|   (never sent)              |   dropped        |          |  never sent)  |
// | sent          | —         | Stop only       | —           | answered | voided                      | expired          | —        | open (a new   |
// |               |           |                 |             |          |                             |                  |          |  answer only  |
// |               |           |                 |             |          |                             |                  |          |  by a click)  |
// | answered      | —         | —               | —           | —        | —                           | —                | —        | answered      |
// | voided        | —         | —               | —           | —        | —                           | —                | —        | voided        |
// | expired       | —         | Stop            | —           | —        | —                           | —                | reask    | expired       |
//
// The first word the run says on a card wins (SessionReducer.setOutcome), so a card's ending never changes once the
// run said it; an ending the task's end implied (no word from the run) gives way to the run's word when that comes.
// A late answer the harness refused (`refused{what:"answer for <ask_id>"}`) changes no ending: the card says it.

import Foundation

/// A card as every view shows it.
enum CardPhase: Equatable {
    /// Waiting for an answer.
    case open
    /// Picked: held for its take-back until `until` (seconds since 1970), not sent. Picking again starts over.
    case pending(CardAnswer, until: Double)
    /// Written to the session; the run has not said yet what came of it.
    case sent(CardAnswer)
    case answered
    /// steer | stop | ended | replaced (a newer card) | task_done (its task ended first) | session_exit | executor_exit
    case voided(String)
    /// No answer in time (ask_void timeout): the task waits where it was. `late`: an answer to it came after and the
    /// harness refused it. `answerNow`: whether 「现在回答」 is offered.
    case expired(late: Bool, answerNow: AnswerNow)

    enum AnswerNow: Equatable {
        case offered            // the newest card of a task that still runs: reask
        case asked              // reask sent; the task looks again and asks a new card
        case gone               // a newer card came, the task went on without it, or it ended
        case refused(String)    // 「现在回答」 was refused: why
    }

    enum Ending: Equatable { case answered, voided, expired }

    /// The card's ending, or nil while it waits (open, pending, sent).
    var ending: Ending? {
        switch self {
        case .open, .pending, .sent: return nil
        case .answered: return .answered
        case .voided: return .voided
        case .expired: return .expired
        }
    }

    /// Its options take a click: open, or held (a click picks again).
    var takesPick: Bool {
        switch self { case .open, .pending: return true; default: return false }
    }

    /// The answer held for its take-back.
    var pending: CardAnswer? { if case .pending(let a, _) = self { return a }; return nil }

    /// An expired card the task still waits on (「现在回答」 offered or asked).
    var isExpiredOffer: Bool { if case .expired(_, let n) = self { return n == .offered || n == .asked }; return false }
}

struct CardStore: Equatable {
    /// The take-back: how long a picked answer is held before it is sent (owner 10-24).
    static let takeBack: Double = 3

    struct Pick: Equatable {
        var sessionId: String
        var answer: CardAnswer
        var until: Double
        var token: Int
        /// The cloud switch's off-epoch when it was picked (SessionClient.offEpoch).
        var offEpoch: Int = 0
    }

    struct Sent: Equatable {
        var sessionId: String
        var answer: CardAnswer
    }

    /// An answer line this client wrote, by its req_id (harness#71 echoes it on a refusal of that line and on
    /// session.task_respond): recorded on the UI queue before the line is written, dropped when the write failed or
    /// the session answered it. Only a refusal carrying one of these ever touches a card (#114 Codex review at
    /// f38b3e5: refusals go to every watcher — matching them by order took another client's).
    struct Issued: Equatable {
        var sessionId: String
        var key: String
        var runId: String
        var isResult: Bool
    }
    private(set) var issued: [String: Issued] = [:]
    /// A result card's refusal this client's own answer got, by run: shown until the history speaks (the card's state
    /// leaves open) or the user answers again. busy / bad_control: try again; undo_expired / no_task: closing, the card
    /// takes no more answers from here until the history closes it.
    private(set) var hints: [String: String] = [:]
    static let closingRefusals: Set<String> = ["undo_expired", "no_task"]

    /// What `pick` asks the caller to do.
    enum Action: Equatable {
        case none
        /// Hold it: call `due(key, token)` after `takeBack` seconds.
        case hold(key: String, token: Int)
        /// Write it now (the way out: no take-back).
        case send(key: String, CardAnswer)
    }

    /// Answers held for their take-back, by card key: never written.
    private(set) var picks: [String: Pick] = [:]
    /// Answers written, by card key (a result card's: its run_id), until the card's ending (or the result card's
    /// answer) comes, or the write failed.
    private(set) var sent: [String: Sent] = [:]
    /// Expired cards whose 「现在回答」 was sent, by card key, until a newer card or the task's end.
    private(set) var reasks: [String: String] = [:]
    private var tokens = 0

    static func key(runId: String, askId: String?) -> String { askId.map { "\(runId)/\($0)" } ?? runId }
    static func key(_ a: CardAnswer) -> String { key(runId: a.runId, askId: a.askId) }

    // MARK: reading

    /// The phase of `card`, a card of `task`.
    func phase(_ card: CardState, of task: TaskState) -> CardPhase {
        let key = Self.key(runId: task.runId, askId: card.askId)
        switch card.outcome {
        case .answered:
            return .answered
        case .void(let why) where why == CardState.timeout:
            let now: CardPhase.AnswerNow
            if let why = task.reaskRefused[card.askId] { now = .refused(why) }
            else { now = task.expiredCard?.askId != card.askId ? .gone : reasks[key] != nil ? .asked : .offered }
            return .expired(late: task.refusedAnswers.contains(card.askId), answerNow: now)
        case .void(let why):
            return .voided(why)
        case .open:
            if let s = sent[key] { return .sent(s.answer) }
            if let p = picks[key] { return .pending(p.answer, until: p.until) }
            return .open
        }
    }

    /// The card pinned above the composer: the open card, else the expired card the task waits on (with 「现在回答」).
    func pinned(_ s: SessionState) -> (runId: String, card: CardState, phase: CardPhase)? {
        if let (run, c) = s.openCard, let t = s.task(run) { return (run, c, phase(c, of: t)) }
        if let t = s.tasks.last(where: { $0.expiredCard != nil }), let c = t.expiredCard { return (t.runId, c, phase(c, of: t)) }
        return nil
    }

    /// The result card of `runId` has an answer on its way.
    func responding(_ runId: String) -> Bool { sent[runId] != nil }

    // MARK: the user

    /// The user picked `a` on its card (`immediate`: the way out, 「先别做了」, which has no take-back). Taken only while
    /// the card is the open one in `s` (the newest state the app has) and nothing was written for it yet: held, or —
    /// immediate — to be written now (a held pick of the card is dropped: it is never sent).
    mutating func pick(_ a: CardAnswer, sessionId: String, immediate: Bool, now: Double, offEpoch: Int = 0, in s: SessionState) -> Action {
        guard a.askId != nil, SessionClient.refusal(a, in: s) == nil else { return .none }
        let key = Self.key(a)
        guard sent[key] == nil else { return .none }
        if immediate {
            picks[key] = nil
            sent[key] = Sent(sessionId: sessionId, answer: a)
            return .send(key: key, a)
        }
        tokens += 1
        picks[key] = Pick(sessionId: sessionId, answer: a, until: now + Self.takeBack, token: tokens, offEpoch: offEpoch)
        return .hold(key: key, token: tokens)
    }

    /// Whether `pick` would take `a` now (the card is the open one in `s`, nothing written for it): what keyWorks asks.
    func wouldPick(_ a: CardAnswer, askId: String, in s: SessionState) -> Bool {
        a.askId == askId && SessionClient.refusal(a, in: s) == nil && sent[Self.key(a)] == nil
    }

    /// Whether `respond` would take `a` now: what ShellModel.canSend asks of a result card's option.
    func wouldRespond(_ a: CardAnswer, in s: SessionState) -> Bool {
        a.askId == nil && SessionClient.refusal(a, in: s) == nil && sent[Self.key(a)] == nil
            && !(hints[a.runId].map(Self.closingRefusals.contains) ?? false)
    }

    /// The line for `key` is about to be written with `reqId` (on the UI queue, before the write): a new answer, so an
    /// older retry hint of its run goes.
    mutating func issue(_ reqId: String, sessionId: String, key: String, answer a: CardAnswer) {
        issued[reqId] = Issued(sessionId: sessionId, key: key, runId: a.runId, isResult: a.askId == nil)
        if a.askId == nil { hints[a.runId] = nil }
    }
    /// A refusal of one of our own lines (its req_id is ours: ShellModel lets no other through), taken as it comes and
    /// not kept: its card's hint; a retryable one lets the answer go, so the user can try again. Any other refusal —
    /// another client's, one without a req_id — changes nothing.
    mutating func refused(_ e: SessionErrorEvent, sessionId: String, in s: SessionState) {
        guard let r = e.reqId, let mine = issued[r], mine.sessionId == sessionId else { return }
        issued[r] = nil
        if !Self.closingRefusals.contains(e.code) { sent[mine.key] = nil }
        if mine.isResult, s.task(mine.runId)?.resultCardState.isOpen == true { hints[mine.runId] = e.code }
    }

    /// The write of `reqId` did not go: nothing of it is awaited.
    mutating func unissue(_ reqId: String) { issued[reqId] = nil }

    /// A result card's answer (respond): written now, once.
    mutating func respond(_ a: CardAnswer, sessionId: String, in s: SessionState) -> Action {
        guard a.askId == nil, SessionClient.refusal(a, in: s) == nil else { return .none }
        let key = Self.key(a)
        guard sent[key] == nil else { return .none }
        sent[key] = Sent(sessionId: sessionId, answer: a)
        return .send(key: key, a)
    }

    /// The cloud switch went off at off-epoch `epoch`: every answer held before it is dropped, never sent (turning it
    /// on again revives none); one picked after it (the switch on again, same epoch) stays.
    mutating func cloudOff(before epoch: Int) {
        let stale = picks.filter { $0.value.offEpoch < epoch }
        if !stale.isEmpty { picks = picks.filter { $0.value.offEpoch >= epoch } }
    }

    /// The take-back: the held answer is dropped, never sent.
    mutating func takeBack(_ key: String) { picks[key] = nil }

    /// The take-back of `key`'s pick `token` ran out: its answer, to write now — once, and only if that pick is still
    /// the card's (not taken back, not picked again) and the card is still the open one in `s`. Either way the pick
    /// is gone.
    mutating func due(_ key: String, token: Int, offEpoch: Int = 0, in s: SessionState) -> CardAnswer? {
        guard let p = picks[key], p.token == token else { return nil }
        picks[key] = nil
        // (the cloud switch went off since it was picked — whether or not it is on again: never sent)
        guard p.offEpoch == offEpoch, SessionClient.refusal(p.answer, in: s) == nil, sent[key] == nil else { return nil }
        sent[key] = Sent(sessionId: p.sessionId, answer: p.answer)
        return p.answer
    }

    /// The write of `a` did not go through (the helper did not take it, or refused it): the card takes a click again.
    mutating func notSent(_ key: String, _ a: CardAnswer) { if sent[key]?.answer == a { sent[key] = nil } }

    /// Stop on `runId`: its held picks are dropped (Stop acts at once; nothing held is sent after it).
    mutating func stopping(_ runId: String) {
        for (k, p) in picks where p.answer.runId == runId { picks[k] = nil }
    }

    /// 「现在回答」 on an expired card: to send (true) only while it is the expired card its running task waits on and
    /// none was sent for it.
    mutating func answerNow(_ runId: String, askId: String, sessionId: String, in s: SessionState) -> Bool {
        guard s.task(runId)?.expiredCard?.askId == askId, SessionClient.reaskRefusal(runId, in: s) == nil else { return false }
        let key = Self.key(runId: runId, askId: askId)
        guard reasks[key] == nil else { return false }
        reasks[key] = sessionId
        return true
    }

    mutating func reaskNotSent(_ key: String) { reasks[key] = nil }

    // MARK: the run's word

    /// The session's state changed: what the app held for a card that is no longer open is dropped (a held pick then
    /// is never sent), a result card's answer once it was taken or the card closed, a reask once its card is no
    /// longer the one the task waits on.
    mutating func settle(_ sessionId: String, _ s: SessionState?) {
        func openCard(_ a: CardAnswer) -> Bool {
            guard let s, let t = s.task(a.runId) else { return false }
            if let id = a.askId { return t.openCard?.askId == id }
            return t.resultCardState.isOpen
        }
        for (k, p) in picks where p.sessionId == sessionId && !openCard(p.answer) { picks[k] = nil }
        for (k, v) in sent where v.sessionId == sessionId && !openCard(v.answer) { sent[k] = nil }
        if let s {
            // the session took one of our lines (session.task_respond with its req_id): nothing more is awaited of it
            for t in s.tasks { if let r = t.respond?.reqId, issued[r]?.sessionId == sessionId { issued[r] = nil } }
            // a hint lasts until the history speaks: the card no longer open
            for (run, _) in hints where s.task(run)?.resultCardState.isOpen != true { hints[run] = nil }
        }
        for (k, sid) in reasks where sid == sessionId {
            let parts = k.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count != 2 || s?.task(parts[0])?.expiredCard?.askId != parts[1] { reasks[k] = nil }
        }
    }

    /// The session is gone (deleted): nothing of it is held.
    mutating func forget(_ sessionId: String) {
        picks = picks.filter { $0.value.sessionId != sessionId }
        sent = sent.filter { $0.value.sessionId != sessionId }
        reasks = reasks.filter { $0.value != sessionId }
        issued = issued.filter { $0.value.sessionId != sessionId }
    }

    /// The refusal hint of a run's result card (its code), if one of this client's answers got one.
    func hint(_ runId: String) -> String? { hints[runId] }
}

// MARK: - the UI event log's part (Shared/UIEvents.swift)

extension UIEvents {
    /// What one change of a session's state says of its cards, for the log -- only what happened live: each change
    /// has the time of the record that made it (CardState.askedAt, TaskState.endedAt(card), TaskState.resultAt), and one written
    /// before `liveSince` (the app began watching) is history being replayed -- a relaunch, a history fill, a backfill
    /// -- and is not put down again (#123 review at 20e66ab). A line with no time is never from the stored log (it always
    /// has one) and counts as live.
    /// - a card shown: in `new` and open, not in `old`, asked live;
    /// - a card's ending: open in `old`, ended in `new`, ended live;
    /// - the result card shown (open in `new`, not in `old`) and ended, live;
    /// - an undo's outcome: from an offered or running undo in `old`, live.
    /// Read from the run's word alone (CardState.outcome, ResultCardState), never from what the app holds.
    static func changes(from old: SessionState?, to new: SessionState, window: UIEvent.Window, liveSince: Double = -.infinity) -> [UIEvent] {
        cardChanges(from: old, to: new, window: window, liveSince: liveSince).map(\.event)
    }

    /// The same, each with the card it is about, by the session's own ids (CardStore.key: the run's, the ask's).
    static func cardChanges(from old: SessionState?, to new: SessionState, window: UIEvent.Window,
                            liveSince: Double = -.infinity) -> [(key: String, event: UIEvent)] {
        func live(_ t: Double?) -> Bool { (t ?? .infinity) >= liveSince }
        var out: [(key: String, event: UIEvent)] = []
        for t in new.tasks {
            let before = old?.task(t.runId)
            let run = UIEvent.ID(t.runId)
            for c in t.cards {
                let was = before?.cards.first { $0.askId == c.askId }
                let kind = UIEvent.CardKind(c.card.kind), ask = UIEvent.ID(c.askId)
                let key = CardStore.key(runId: t.runId, askId: c.askId)
                if was == nil, c.outcome == .open, live(c.askedAt) {
                    out.append((key, .cardShown(run: run, ask: ask, kind: kind, place: .chat, window: window,
                                                options: c.card.options.count, details: c.card.plan != nil || c.card.consent != nil)))
                }
                if was?.outcome == .open, c.outcome != .open, live(t.endedAt(c)) {
                    out.append((key, .cardEnded(run: run, ask: ask, kind: kind, why: ending(c.outcome))))
                }
            }
            let r0 = before?.resultCardState ?? ResultCardState.none, r1 = t.resultCardState
            guard r0 != r1, live(t.resultAt) else { continue }
            if !r0.isOpen, r1.isOpen, let card = t.resultCard {
                out.append((t.runId, .cardShown(run: run, ask: nil, kind: .result, place: .chat, window: window,
                                                options: card.options.count, details: card.plan != nil || card.consent != nil)))
            }
            if r0.isOpen, !r1.isOpen { out.append((t.runId, .cardEnded(run: run, ask: nil, kind: .result, why: resultEnding(r1)))) }
            if let u = undo(from: r0, to: r1) { out.append((t.runId, .undo(run: run, outcome: u))) }
        }
        return out
    }

    /// How a result card left open: answered (好的, or undo asked: its outcome is the `undo` event), or closed --
    /// its time ran out (expired), or another task / the process ended it.
    static func resultEnding(_ r: ResultCardState) -> UIEvent.Ending {
        switch r {
        case .closed(let why): return why == "linger" || why == "deadline" ? .expired : .ended
        case .none: return .ended
        default: return .answered
        }
    }

    static func ending(_ o: CardState.Outcome) -> UIEvent.Ending {
        switch o {
        case .open, .answered: return .answered
        case .void(let why):
            switch why {
            case CardState.timeout: return .expired
            case "steer": return .steer
            case "stop": return .stop
            case "replaced": return .replaced
            default: return .ended       // ended, task_done, session_exit, executor_exit
            }
        }
    }

    /// An undo's outcome, when the result card's state comes to one: undone (all of it), partial (some refused), cut
    /// off (unknown), or expired (asked too late, or the card closed while undo was offered — by why).
    static func undo(from r0: ResultCardState, to r1: ResultCardState) -> UIEvent.Undo? {
        // (only from an undo offered or running: a task first seen, or seen already undone, says nothing)
        switch r0 {
        case .open(true, _), .undoing: break
        default: return nil
        }
        switch r1 {
        case .undone(let n, let total, let refused): return refused == nil && n == total ? .undone : .partial
        case .undoUnknown: return .unknown
        case .undoExpired: return .expiredLate
        case .closed(let why):
            guard r0.undoEnabled else { return nil }
            switch why {
            case "linger", "deadline": return .expiredTime
            case "new_task": return .expiredNewTask
            case "session_exit", "session_end": return .expiredHelperQuit
            default: return .expiredOther
            }
        default: return nil
        }
    }
}

extension UIEvent.Option {
    init(_ role: CardModel.Role) {
        switch role {
        case .approve: self = .approve
        case .choice: self = .choice
        case .skipStep: self = .skipStep
        case .delegate: self = .delegate
        case .cancel: self = .cancel
        case .undo: self = .undo
        case .other: self = .other
        }
    }
}
