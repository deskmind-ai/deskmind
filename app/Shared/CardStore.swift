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
    }

    struct Sent: Equatable {
        var sessionId: String
        var answer: CardAnswer
    }

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
    mutating func pick(_ a: CardAnswer, sessionId: String, immediate: Bool, now: Double, in s: SessionState) -> Action {
        guard a.askId != nil, SessionClient.refusal(a, in: s) == nil else { return .none }
        let key = Self.key(a)
        guard sent[key] == nil else { return .none }
        if immediate {
            picks[key] = nil
            sent[key] = Sent(sessionId: sessionId, answer: a)
            return .send(key: key, a)
        }
        tokens += 1
        picks[key] = Pick(sessionId: sessionId, answer: a, until: now + Self.takeBack, token: tokens)
        return .hold(key: key, token: tokens)
    }

    /// A result card's answer (respond): written now, once.
    mutating func respond(_ a: CardAnswer, sessionId: String, in s: SessionState) -> Action {
        guard a.askId == nil, SessionClient.refusal(a, in: s) == nil else { return .none }
        let key = Self.key(a)
        guard sent[key] == nil else { return .none }
        sent[key] = Sent(sessionId: sessionId, answer: a)
        return .send(key: key, a)
    }

    /// The take-back: the held answer is dropped, never sent.
    mutating func takeBack(_ key: String) { picks[key] = nil }

    /// The take-back of `key`'s pick `token` ran out: its answer, to write now — once, and only if that pick is still
    /// the card's (not taken back, not picked again) and the card is still the open one in `s`. Either way the pick
    /// is gone.
    mutating func due(_ key: String, token: Int, in s: SessionState) -> CardAnswer? {
        guard let p = picks[key], p.token == token else { return nil }
        picks[key] = nil
        guard SessionClient.refusal(p.answer, in: s) == nil, sent[key] == nil else { return nil }
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
            return t.resultResponse == nil && t.sessionUndo == nil && t.closed == nil && t.respond == nil
        }
        for (k, p) in picks where p.sessionId == sessionId && !openCard(p.answer) { picks[k] = nil }
        for (k, v) in sent where v.sessionId == sessionId && !openCard(v.answer) { sent[k] = nil }
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
    }
}
