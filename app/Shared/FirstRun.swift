// The first launch (A12): the language, the two permissions, the model key with its check, a first task's examples --
// four steps, each skippable, none waiting on something the user cannot do now. Pure: what the facts are (from the
// helper's status and keys.status, never waited on) and what the user did, to the step shown.
//
// | step        | 下一步                         | 稍后            | facts read                               |
// |-------------|-------------------------------|----------------|------------------------------------------|
// | language    | permissions                   | (no 稍后)       | --                                       |
// | permissions | key                           | key            | accessibility, screen (「已授权」 only from  |
// |             |                               |                |   the status, never assumed)              |
// | key         | examples                      | examples       | the key set, the check's result (a failed |
// |             |                               |                |   check never traps: 稍后 goes on)        |
// | examples    | done (an example in the       | done           | --                                       |
// |             |   composer, never sent)       |                |                                          |
// | 跳过全部      | done                          |                |                                          |
//
// Done sets the flag; a later launch shows no flow, only a row in the empty chat for what is still unmet (FirstRun.unmet).

import Foundation

struct FirstRun: Equatable {
    enum Step: Int, Equatable, CaseIterable { case language, permissions, key, examples, done }
    enum Event: Equatable { case next, later, back, skipAll, checked(ok: Bool) }
    struct Facts: Equatable {
        var accessibility = false
        var screen = false
        var keySet = false
        /// The last model check's result (nil: none yet).
        var checkOK: Bool?
    }

    var step: Step = .language
    var facts = Facts()

    init(step: Step = .language, facts: Facts = Facts()) { self.step = step; self.facts = facts }

    mutating func apply(_ e: Event) {
        switch e {
        case .next, .later:
            guard let n = Step(rawValue: step.rawValue + 1) else { return }
            step = n
        case .back:
            if let p = Step(rawValue: step.rawValue - 1), step != .done { step = p }
        case .skipAll:
            step = .done
        case .checked(let ok):
            facts.checkOK = ok
        }
    }

    /// What the step's main button says: 下一步 when what it asks for is there, else the step can still be left (稍后).
    var canLater: Bool { step != .language && step != .done }

    /// What is still unmet once the flow is over: rows in the empty chat (in this order).
    enum Unmet: Equatable { case permissions, key }
    static func unmet(_ f: Facts) -> [Unmet] {
        (f.accessibility && f.screen ? [] : [.permissions]) + (f.keySet ? [] : [.key])
    }

    /// The flag: the flow was finished (or skipped) once.
    static let doneKey = "firstRun.done"

    /// The first tasks offered (filled into the composer, never sent), by key.
    static let examples = [
        "/cua Open TextEdit and write a shopping list: milk, eggs, bread",
        "/cua Find the largest file in my Downloads folder",
        "What can you do on my Mac?",
    ]
}
