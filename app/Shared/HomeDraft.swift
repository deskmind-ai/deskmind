// The home screen's draft — the instruction typed and its folder chip — around the goals started from it (rc.16: a
// goal started from home left its words and folder in the prompt; Back showed them, one click on Start ran the same
// goal again — it did, once, in a new session).
//
// Rule: a goal started from home clears the draft once GoalRuns has accepted it (a start refused — another goal is
// not over — keeps it). Using a goal's words again is always explicit: Edit / "Use this instruction", a recent run or
// an example put them in; Run again and "Next task…" start from their own screen and leave the draft alone.
//
// | event                                   | draft (goal, folder) after                         | pending home start |
// |-----------------------------------------|----------------------------------------------------|--------------------|
// | typed / folder chip changed             | as the user made it                                | —                  |
// | Start from home (or its confirm sheet)  | unchanged (not started yet)                        | that request       |
// | confirm sheet cancelled                 | unchanged                                          | none               |
// | started: GoalRuns accepted it           | cleared ("", none) — when it is the pending one    | none               |
// | refused: another goal is not over       | unchanged (kept to start again)                    | none               |
// | Back (from a goal or a record)          | unchanged                                          | unchanged          |
// | Edit / "Use this instruction"           | that request's goal and folder                     | none               |
// | a recent run's words, an example        | its goal (an example: its folder too)              | none               |
// | Run again / "Next task…" started        | unchanged (another request, not the pending one)   | unchanged          |

import Foundation

struct HomeDraft: Equatable {
    var goal = ""
    var folder: String? = nil
    /// The request Start sent from home, until GoalRuns accepts or refuses it.
    var pending: UUID? = nil

    enum Event: Equatable {
        case typed(String)
        case folder(String?)
        case homeStart(UUID)
        case confirmCancelled
        case started(UUID)
        case refused(UUID)
        case back
        case edit(goal: String, folder: String?)
        case reuse(goal: String, folder: String??)
    }

    static func next(_ d: HomeDraft, _ e: Event) -> HomeDraft {
        var d = d
        switch e {
        case .typed(let g): d.goal = g
        case .folder(let f): d.folder = f
        case .homeStart(let id): d.pending = id
        case .confirmCancelled: d.pending = nil
        case .started(let id):
            guard d.pending == id else { break }
            d = HomeDraft()
        case .refused(let id):
            if d.pending == id { d.pending = nil }
        case .back: break
        case .edit(let g, let f): d.goal = g; d.folder = f; d.pending = nil
        case .reuse(let g, let f):
            d.goal = g; d.pending = nil
            if let f { d.folder = f }
        }
        return d
    }
}
