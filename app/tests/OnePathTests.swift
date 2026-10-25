// One path (A10, invariant 10 as fable reworded it): card state lives only in CardStore; cards are drawn only from
// CardLayout, by CardView and the float's FloatCard; every card button goes through shell.click / canSend; nothing
// the old window had is left in a build; HarnessEvents is the helper's `op run` format only.
import Foundation

enum OnePathTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "one path: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("onepath.static"); staticTests()
    }

    static let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    static func code(_ f: String) -> String {
        ((try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) ?? "")
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }
    /// The files on one of build.sh's compile lines (the one after `marker`).
    static func line(_ marker: String) -> [String] {
        let b = (try? String(contentsOf: dir.appendingPathComponent("build.sh"), encoding: .utf8)) ?? ""
        let lines = b.split(separator: "\n").map(String.init)
        guard let i = lines.firstIndex(where: { $0.contains(marker) }), i + 1 < lines.count else { return [] }
        return lines[i + 1].split(separator: " ").map(String.init).filter { $0.hasSuffix(".swift") }
    }

    static func staticTests() {
        let main = line("MacOS/DeskMind\" \\"), helper = line("DeskMindHands\" \\"), tests = line("decision-tests\" \\")
        check(main.count > 30 && helper.count > 20 && tests.count > 30, "the build's lines read: \(main.count) \(helper.count) \(tests.count)")
        // nothing of the old window, anywhere in a build
        let gone = ["ShellFlag", "HomeView", "GoalRunView", "RunModel", "GoalRun(", "GoalRuns", "GoalRequest", "RunHistory", "AskCard",
                    "WaitingCard", "EyesDownloader", "GoalTicket", "GoalLifecycle", "IslandFeed.route", "detailsRecord", "ui05.trace", "traceOn"]
        for f in Set(main + helper + tests) where f != "tests/OnePathTests.swift" {
            let c = code(f)
            for n in gone where c.contains(n) { check(false, "\(f) still names \(n)") }
        }
        // cards drawn only by CardView and FloatCard, from CardLayout; their buttons through shell.click / canSend
        for f in main where f.hasPrefix("Main/") {
            let c = code(f)
            let draws = c.contains("CardLayout(") || c.contains("Button(c.button") || c.contains("layout.controls")
            if draws && f != "Main/CardViews.swift" && f != "Main/FloatPanel.swift" { check(false, "\(f) draws a card") }
        }
        let float = code("Main/FloatPanel.swift"), cards = code("Main/CardViews.swift")
        check(float.contains("shell.click(c.button, session: sessionId") && float.contains("shell.canSend(c.button, session: sessionId)"),
              "the float's buttons: shell.click / canSend")
        check(cards.contains("shell.click(") && cards.contains("canSend") || cards.contains("buttonEnabled("), "the chat's buttons: shell.click / canSend")
        // card state only in CardStore: no view keeps picks or phases of its own
        for f in main where f.hasPrefix("Main/") {
            let c = code(f)
            if c.contains("var picks") || c.contains("CardStore(") { check(false, "\(f) keeps card state") }
        }
        // HarnessEvents: the helper's op run format only (HarnessRun), and tests
        for f in main + helper where f != "Shared/HarnessEvents.swift" && code(f).contains("HarnessEvents") && f != "Helper/HarnessRun.swift" {
            check(false, "\(f) uses HarnessEvents")
        }
        check(!main.contains("Shared/HarnessEvents.swift"), "the main app is built without HarnessEvents")
        // the helper shows no card of its own for a session
        let host = code("Helper/SessionHost.swift")
        check(!host.contains("LiveCard") && !host.contains("HarnessEvents") && !host.contains("cardRun"), "a session: no helper live card, no translation")
    }
}
