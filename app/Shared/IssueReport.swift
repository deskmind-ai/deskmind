// A report about a run, as a new GitHub issue on DeskMind's repository, filled in for the user to read, edit and
// submit in their browser. Nothing is sent from the app: the URL opens the hub's "Problem using the app" form
// (deskmind-ai/.github, app_problem.yml) with its fields filled in by id, and the user decides. The form, not a blank
// issue: blank issues are off for people outside the team, and the form adds the labels and the privacy reminder. What
// goes in: the instruction the user typed, how it ended, how many steps it took and of what kind ("type_text x5"),
// and the app and macOS versions. Nothing read from the screen -- no step text, window titles, labels, file contents
// or paths -- since the issue is public; the user can add what helps.
//
// Foundation only, so tests/DecisionTests.swift checks it.

import Foundation

enum IssueReport {
    static let repo = "https://github.com/deskmind-ai/deskmind"
    /// Where wrong guesses are collected ("Ambiguous tasks: does it ask or guess?").
    static let ambiguousIssue = "https://github.com/deskmind-ai/deskmind/issues/10"

    /// Why the user is reporting. The title says it, so it reads the same whoever files it (labels in a new-issue
    /// URL apply only for people with triage rights).
    enum Kind: String, CaseIterable {
        case guessed, wrong, stuck, error

        /// The button's words (an English key, for L()).
        var label: String {
            switch self {
            case .guessed: "It guessed instead of asking"
            case .wrong: "Wrong result"
            case .stuck: "It got stuck"
            case .error: "Report on GitHub"
            }
        }

        var titlePrefix: String {
            switch self {
            case .guessed: "Guessed instead of asking"
            case .wrong: "Wrong result"
            case .stuck: "Got stuck"
            case .error: "Run failed"
            }
        }
    }

    /// The most a URL carries comfortably (browsers and GitHub cut long ones): the steps are trimmed to fit.
    static let maxURL = 7000

    /// The form and its field ids (deskmind-ai/.github/.github/ISSUE_TEMPLATE/app_problem.yml).
    static let template = "app_problem.yml"

    /// `steps`: each step's operation (hands' describe up to the first space: "click", "type_text"), nothing more.
    /// `diagnostics`: the folded section of numbers and kinds (Diagnostics.markdown), kept whole -- the instruction
    /// is what is shortened when the URL runs long.
    static func url(kind: Kind, goal: String, outcome: String, steps: [String], appVersion: String,
                    macOS: String, diagnostics: String = "") -> URL? {
        let title = "\(kind.titlePrefix): \(oneLine(goal, max: 80))"
        let happened = whatHappened(kind: kind, outcome: outcome, steps: steps)
            + (diagnostics.isEmpty ? "" : "\n" + diagnostics)
        var goalText = goal
        while true {
            var c = URLComponents(string: repo + "/issues/new")!
            c.queryItems = [URLQueryItem(name: "template", value: template), URLQueryItem(name: "title", value: title),
                            URLQueryItem(name: "goal", value: goalText), URLQueryItem(name: "what-happened", value: happened),
                            URLQueryItem(name: "version", value: appVersion), URLQueryItem(name: "mac", value: "macOS \(macOS)")]
            guard let u = c.url else { return nil }
            if u.absoluteString.count <= maxURL || goalText.count < 40 { return u }
            goalText = String(goalText.prefix(goalText.count * 3 / 4)) + "…"   // a very long instruction
        }
    }

    /// "9 (type_text ×5, click ×3, save)": how many steps, and of what kind, most common first.
    static func stepSummary(_ ops: [String]) -> String {
        var count: [String: Int] = [:]
        for op in ops where !op.isEmpty { count[op, default: 0] += 1 }
        let kinds = count.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { $0.value > 1 ? "\($0.key) ×\($0.value)" : $0.key }
        return kinds.isEmpty ? "\(ops.count)" : "\(ops.count) (\(kinds.joined(separator: ", ")))"
    }

    /// The "What happened" field: how it ended, what the user is asked to add for this kind of report, and the steps.
    static func whatHappened(kind: Kind, outcome: String, steps: [String]) -> String {
        var b = "\(outcome.isEmpty ? "(no result)" : outcome)\n\n"
        switch kind {
        case .guessed: b += "**What it should have asked**\n\n(Which choice was ambiguous, and what you would have answered.)\n\n"
            b += "More examples of tasks that should ask, and what they did: \(ambiguousIssue)\n\n"
        case .wrong: b += "**What I expected**\n\n(The result you wanted.)\n\n"
        case .stuck, .error: break
        }
        if !steps.isEmpty { b += "**Steps**: \(stepSummary(steps))\n" }
        return b
    }

    static func oneLine(_ s: String, max: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count <= max ? flat : String(flat.prefix(max - 1)) + "…"
    }
}
