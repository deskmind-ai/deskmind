// The island and the notifications for a session task (M2, PR B): what they say comes from the task's one state
// (TaskState, its pinned card's phase — the chat's), through this one adapter; no second state. GoalRunView applies
// each new frame to RunOverlay (Main/SessionIsland.swift); the decisions are here, pure, and tested
// (tests/IslandFeedTests.swift).
//
// | the session task                  | the island                                   | a notification                         |
// |-----------------------------------|----------------------------------------------|----------------------------------------|
// | preparing                         | shown: the goal, 「准备中」                    | —                                      |
// | working, step n                   | step n, its words                            | —                                      |
// | paused (you use the Mac)          | 「你在用电脑，已暂停」                          | —                                      |
// | a card waits (open / held / sent) | 「在 DeskMind 里等你回答 / 批准」, Open DeskMind | once per card, when DeskMind is not    |
// |                                   |                                              |   active or the user types elsewhere   |
// | the card expired                  | 「卡片已过期…」, Open DeskMind                  | —                                      |
// | checking the result / stopping    | its words                                    | —                                      |
// | ended                             | finish: passed only when succeeded; stopped  | the result, when DeskMind is not       |
// |                                   |   (cancelled / stopped) says so; its line    |   active (RunOverlay.finish)           |
// |                                   |   the ending in words                        |                                        |
//
// The bar (U2, the Island board): one of seven kinds, its dot, its left and right words, already in the language.
//
// | kind      | when                                      | dot     | left                    | right                         |
// |-----------|-------------------------------------------|---------|-------------------------|-------------------------------|
// | preparing | running, preparing                        | grey    | 准备中                    | its seconds (the view counts) |
// | working   | running, a step, no card                  | orange  | the app, else the task  | 第 n 步 · m:ss (the view)      |
// | needsYou  | a card waits (open / held / sent / an     | orange, | 需要你                    | the card's kind when the float|
// |           |   expired one still answerable)           |   halo  |                         |   shows it, else its title    |
// | paused    | you use the Mac                           | grey    | 你在用电脑，先停一下          | 停手后继续                       |
// | done      | ended, succeeded                          | white   | 完成了                    | n 步 · its time                 |
// | failed    | ended, anything else but stopped          | grey    | 没做完                    | 查看原因                         |
// | stopped   | ended, cancelled / stopped                | grey    | 已停下                    | n 步                            |

import Foundation

struct IslandFrame: Equatable {
    enum Phase: Equatable { case running, ended(passed: Bool, stopped: Bool) }
    enum Kind: Equatable { case preparing, working, needsYou, paused, done, failed, stopped }
    var phase: Phase
    /// The bar's state (the table above), and its words: left, right ("" while the view counts the time itself).
    var kind: Kind = .working
    var left = ""
    var right = ""
    /// Since when it runs: the preparing seconds and the working m:ss, counted where it is drawn.
    var startedAt: Double? = nil
    var step: Int
    var line: String
    /// A card waits in DeskMind (the island's 「Open DeskMind」).
    var asking: Bool
    /// The card that waits (for its notification, once).
    var cardId: String?
    var cardApproval: Bool
    var cardText: String
    /// The recent-runs record its "Show Details" opens (once kept).
}

enum IslandFeed {
    /// The frame for `t`, a session task, whose pinned card (if any) is `pinned`; `app`, the app its last step acts
    /// in (by name, where known); `floatShows`, whether the float shows the card (the bar then names its kind only).
    static func frame(_ t: TaskState, pinned: (card: CardState, phase: CardPhase)?, app: String? = nil, floatShows: Bool = false,
                      lang: ResolvedLang) -> IslandFrame {
        var f = core(t, pinned: pinned, lang: lang)
        bar(&f, t, pinned: pinned, app: app, floatShows: floatShows, lang: lang)
        return f
    }

    /// The bar's kind and words (the second table).
    private static func bar(_ f: inout IslandFrame, _ t: TaskState, pinned: (card: CardState, phase: CardPhase)?, app: String?,
                            floatShows: Bool, lang: ResolvedLang) {
        f.startedAt = t.startedAt
        let n = t.steps.count
        if case .ended(let passed, let stopped) = f.phase {
            if passed {
                f.kind = .done; f.left = L("Done", lang: lang)
                let secs = max(0, Int((t.endedAt ?? 0) - (t.startedAt ?? t.endedAt ?? 0)))
                let time = secs < 60 ? L("%d s", secs, lang: lang) : String(format: "%d:%02d", secs / 60, secs % 60)
                f.right = L("%d steps · %@", n, time, lang: lang)
            } else if stopped {
                f.kind = .stopped; f.left = L("Stopped", lang: lang); f.right = L("%d steps", n, lang: lang)
            } else {
                f.kind = .failed; f.left = L("Didn't finish", lang: lang); f.right = L("See why", lang: lang)
            }
            return
        }
        if let p = pinned, p.phase.ending == nil || p.phase.isExpiredOffer {
            f.kind = .needsYou; f.left = L("Needs you", lang: lang)
            f.right = floatShows ? ShellText.cardKind(p.card.card.kind, lang: lang) : CardLayout(CardModel(card: p.card.card, runId: t.runId, askId: p.card.askId)).title
        } else if t.userActive {
            f.kind = .paused; f.left = L("You're on the Mac, paused", lang: lang); f.right = L("Resumes when you stop", lang: lang)
        } else if t.preparing && n == 0 {
            f.kind = .preparing; f.left = L("Getting ready", lang: lang)
        } else {
            f.kind = .working
            let name = (app ?? "").isEmpty ? (t.goal ?? t.raw) : app!
            f.left = name.count > 24 ? String(name.prefix(23)) + "…" : name
        }
    }

    private static func core(_ t: TaskState, pinned: (card: CardState, phase: CardPhase)?, lang: ResolvedLang) -> IslandFrame {
        if t.ended {
            let st = t.status
            return IslandFrame(phase: .ended(passed: st == "succeeded", stopped: st == "cancelled" || st == "stopped"),
                               step: t.steps.count, line: ShellText.task(t, lang: lang), asking: false, cardId: nil, cardApproval: false, cardText: "")
        }
        var f = IslandFrame(phase: .running, step: t.steps.count, line: ShellText.task(t, lang: lang), asking: false, cardId: nil,
                            cardApproval: false, cardText: "")
        if let p = pinned {
            let approval = p.card.card.options.contains { $0.kind == "approve" }
            if p.phase.ending == nil {
                f.asking = true
                f.cardId = p.card.askId
                f.cardApproval = approval
                f.cardText = p.card.card.text
                f.line = approval ? L("Waiting for your approval in DeskMind", lang: lang) : L("Waiting for your answer in DeskMind", lang: lang)
            } else if p.phase.isExpiredOffer {
                f.asking = true
                f.line = ShellText.task(t, lang: lang)
            }
        } else if !t.userActive, !t.lookOnly, !t.stopping, !t.preparing, let s = t.steps.last {
            f.line = s.displayText
        }
        return f
    }

    /// The notification a new frame calls for: a card that newly waits (by its id), when DeskMind is not the active
    /// app or the user typed elsewhere a moment ago; nil otherwise. (The end's notification is RunOverlay.finish's.)
    static func cardNotification(from old: IslandFrame?, to new: IslandFrame, appActive: Bool, userTyping: Bool, lang: ResolvedLang) -> (title: String, body: String)? {
        guard let id = new.cardId, id != old?.cardId, !appActive || userTyping else { return nil }
        return (new.cardApproval ? L("DeskMind needs your approval", lang: lang) : L("DeskMind has a question", lang: lang), new.cardText)
    }
}
