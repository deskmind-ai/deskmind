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
// | key, 继续    | (the view: a key typed is saved -- saved(ok); then checked: checked(true) moves on to examples,|
// |             |   saved(false) / checked(false) stay, 稍后 still there; nothing typed and none set: 继续 off) |
// | examples    | done (an example in the       | done           | --                                       |
// |             |   composer, never sent)       |                |                                          |
// | 跳过全部      | done                          |                |                                          |
//
// Done sets the flag; a later launch shows no flow, only a row in the empty chat for what is still unmet (FirstRun.unmet).

import Foundation

struct FirstRun: Equatable {
    enum Step: Int, Equatable, CaseIterable { case language, permissions, key, examples, done }
    enum Event: Equatable { case next, later, back, skipAll, saved(ok: Bool), checked(ok: Bool) }
    struct Facts: Equatable {
        var accessibility = false
        var screen = false
        var keySet = false
        /// The last save of a typed key (nil: none yet).
        var saveOK: Bool?
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
        case .saved(let ok):
            facts.saveOK = ok
        case .checked(let ok):
            facts.checkOK = ok
            if ok && step == .key { step = .examples }     // (the key works: on, by itself)
        }
    }

    /// Whether the step's one main button (继续 / 完成) is on: the permissions when both are granted (else 稍后); the
    /// key when one is typed or set; the rest always.
    func canContinue(typed: Bool) -> Bool {
        switch step {
        case .permissions: facts.accessibility && facts.screen
        case .key: typed || facts.keySet
        default: true
        }
    }

    /// The key step's status line (P1Setup): nothing yet, set (by its last 4), being tried, works, doesn't (why), or
    /// the keychain can't be read.
    enum KeyState: Equatable { case empty, set(last4: String), checking, ok(model: String), bad(why: String), unreadable }
    static func keyState(known: Bool, readable: Bool, last4: String?, busy: Bool, checkOK: Bool?, why: String?, model: String?) -> KeyState {
        if busy { return .checking }         // (first: a save over unreadable keys is under way -- no second press)
        if known && !readable { return .unreadable }
        if checkOK == true { return .ok(model: model ?? "") }
        if let why, !why.isEmpty { return .bad(why: why) }
        if let l = last4, !l.isEmpty { return .set(last4: l) }
        return .empty
    }

    /// What the step's main button says: 下一步 when what it asks for is there, else the step can still be left (稍后).
    var canLater: Bool { step != .language && step != .done }

    /// What is still unmet once the flow is over: rows in the empty chat (in this order).
    enum Unmet: Equatable { case permissions, key, keyUnreadable }
    /// `keysReadable`: false when the helper cannot read the keychain -- said as that, never as "no key".
    static func unmet(_ f: Facts, keysReadable: Bool = true) -> [Unmet] {
        (f.accessibility && f.screen ? [] : [.permissions]) + (!keysReadable ? [.keyUnreadable] : f.keySet ? [] : [.key])
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
