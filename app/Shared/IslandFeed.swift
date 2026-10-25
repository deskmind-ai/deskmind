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

import Foundation

struct IslandFrame: Equatable {
    enum Phase: Equatable { case running, ended(passed: Bool, stopped: Bool) }
    var phase: Phase
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
    /// The frame for `t`, a session task, whose pinned card (if any) is `pinned`.
    static func frame(_ t: TaskState, pinned: (card: CardState, phase: CardPhase)?, lang: ResolvedLang) -> IslandFrame {
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
