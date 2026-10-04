// A report about a run, as a new GitHub issue on DeskMind's repository, filled in for the user to read, edit and
// submit in their browser. Nothing is sent from the app: the URL opens the issue form, and the user decides. What
// goes in is what the run screen shows -- the instruction, how it ended, the steps in words -- plus the app and macOS
// versions; no screenshots, no file contents, no paths.
//
// Foundation only, so tests/DecisionTests.swift checks it.

import Foundation

enum IssueReport {
    static let repo = "https://github.com/deskmind-ai/deskmind"

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

    static func url(kind: Kind, goal: String, outcome: String, steps: [String], appVersion: String,
                    macOS: String) -> URL? {
        let title = "\(kind.titlePrefix): \(oneLine(goal, max: 80))"
        var shown = Array(steps.prefix(40))
        while true {
            let body = self.body(kind: kind, goal: goal, outcome: outcome, steps: shown, total: steps.count,
                                 appVersion: appVersion, macOS: macOS)
            var c = URLComponents(string: repo + "/issues/new")!
            c.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
            guard let u = c.url else { return nil }
            if u.absoluteString.count <= maxURL || shown.isEmpty { return u }
            shown.removeLast(max(1, shown.count / 4))
        }
    }

    static func body(kind: Kind, goal: String, outcome: String, steps: [String], total: Int, appVersion: String,
                     macOS: String) -> String {
        var b = "<!-- This issue is public. Check the instruction and the steps below for anything private before you submit. -->\n\n"
        b += "**What I asked**\n\n> \(goal.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
        b += "**What happened**\n\n\(outcome.isEmpty ? "(no result)" : outcome)\n\n"
        switch kind {
        case .guessed: b += "**What it should have asked**\n\n(Which choice was ambiguous, and what you would have answered.)\n\n"
        case .wrong: b += "**What I expected**\n\n(The result you wanted.)\n\n"
        case .stuck, .error: break
        }
        if !steps.isEmpty {
            b += "**Steps**\n\n"
            for (i, s) in steps.enumerated() { b += "\(i + 1). \(oneLine(s, max: 140))\n" }
            if total > steps.count { b += "… and \(total - steps.count) more\n" }
            b += "\n"
        }
        b += "DeskMind \(appVersion) · macOS \(macOS)\n"
        return b
    }

    static func oneLine(_ s: String, max: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count <= max ? flat : String(flat.prefix(max - 1)) + "…"
    }
}
