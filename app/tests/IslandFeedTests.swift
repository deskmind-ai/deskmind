// M2 PR B: a session task's island and notifications come from its one state through IslandFeed — a table, session
// state → island frame and notification — and GoalRunView / SessionIsland / "Show Details" are wired to it.
// Run from DecisionTests.main (build.sh).

import Foundation

enum IslandFeedTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "island: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("island.tableTests"); tableTests()
        DecisionTests.group("island.notifyTests"); notifyTests()
        DecisionTests.group("island.wiringTests"); wiringTests()
    }

    static let action = #""card":{"kind":"action","text":"要点「发送」吗？","options":[{"kind":"approve","text":"可以"},{"kind":"cancel","text":"先别做了"}],"free_text":false,"blocking":true}"#
    static let missing = #""card":{"kind":"missing","text":"发给谁？","options":[{"kind":"value","text":"小王"},{"kind":"cancel","text":"先别做了"}],"free_text":true,"blocking":true}"#

    static func task(_ body: [String]) -> (SessionState, TaskState) {
        var lines = [SessionTests.taskR1, SessionTests.ex(1, #""kind":"start","raw":"x""#)]
        for (i, b) in body.enumerated() { lines.append(SessionTests.ex(i + 2, b)) }
        let s = SessionReducer.reduce(SessionState(), lines)
        return (s, s.task("r1")!)
    }

    static func frame(_ body: [String], phase: CardPhase? = nil) -> IslandFrame {
        let (s, t) = task(body)
        let pinned: (card: CardState, phase: CardPhase)? = (s.openCard?.card ?? t.expiredCard).map { c in (c, phase ?? CardStore().phase(c, of: t)) }
        return IslandFeed.frame(t, pinned: pinned, lang: .zhHans)
    }

    static func tableTests() {
        let step = #""kind":"step","text":"click","step_id":"s1","human":"点「发送」""#
        let rows: [(String, IslandFrame, IslandFrame.Phase, Bool, String)] = [
            ("preparing", frame([]), .running, false, L10n.zh["Getting ready…"] ?? ""),
            ("working", frame([#""kind":"plan","steps":[]"#, step]), .running, false, "点「发送」"),
            ("paused", frame([step, #""kind":"waiting""#]), .running, false, L10n.zh["You're using the Mac, paused"] ?? ""),
            ("an action card", frame([#""kind":"ask","ask_id":"a1","# + action]), .running, true, L10n.zh["Waiting for your approval in DeskMind"] ?? ""),
            ("a card held (take-back)", frame([#""kind":"ask","ask_id":"a1","# + action], phase: .pending(.option(runId: "r1", askId: "a1", option: 0), until: 0)), .running, true, L10n.zh["Waiting for your approval in DeskMind"] ?? ""),
            ("a question card", frame([#""kind":"ask","ask_id":"a1","# + missing]), .running, true, L10n.zh["Waiting for your answer in DeskMind"] ?? ""),
            ("the card expired", frame([#""kind":"ask","ask_id":"a1","# + action, #""kind":"ask_void","ask_id":"a1","why":"timeout""#]), .running, true, L10n.zh["The card expired; the task waits where it was"] ?? ""),
            ("checking", frame([step, #""kind":"verify","verdict":"unknown","reason":"r","missing_kind":"evidence""#]), .running, false, L10n.zh["Checking the result (looking only)"] ?? ""),
            ("stopping", frame([step, #""kind":"refused","what":"the task","why":"stopped","by":"user""#]), .running, false, L10n.zh["Stopping…"] ?? ""),
            ("succeeded", frame([#""kind":"task_done","status":"succeeded","reason":"","summary":"s""#]), .ended(passed: true, stopped: false), false, L10n.zh["Done"] ?? ""),
            ("failed", frame([#""kind":"task_done","status":"failed","reason":"","summary":"s""#]), .ended(passed: false, stopped: false), false, L10n.zh["Didn't finish"] ?? ""),
            ("cancelled", frame([#""kind":"task_done","status":"cancelled","reason":"","summary":"s""#]), .ended(passed: false, stopped: true), false, L10n.zh["Cancelled"] ?? ""),
            ("stopped", frame([#""kind":"task_done","status":"stopped","reason":"","summary":"s""#]), .ended(passed: false, stopped: true), false, L10n.zh["Stopped"] ?? ""),
            ("locked", frame([#""kind":"task_done","status":"environment","reason":"","summary":"s","cause":"screen_locked""#]), .ended(passed: false, stopped: false), false, L10n.zh["Stopped: the screen is locked"] ?? ""),
            ("not confirmed", frame([#""kind":"task_done","status":"unconfirmed","reason":"","summary":"s""#]), .ended(passed: false, stopped: false), false, L10n.zh["Done, but not confirmed. Please check"] ?? ""),
        ]
        for (name, f, phase, asking, line) in rows {
            check(f.phase == phase && f.asking == asking && f.line == line, "\(name): \(f.phase) asking \(f.asking) «\(f.line)» (want \(phase), \(asking), «\(line)»)")
        }
        check(frame([#""kind":"ask","ask_id":"a1","# + action]).cardId == "a1" && frame([#""kind":"ask","ask_id":"a1","# + action, #""kind":"resumed","ask_id":"a1""#]).cardId == nil,
              "the card waits: its id; answered: none")
    }

    static func notifyTests() {
        let asked = frame([#""kind":"ask","ask_id":"a1","# + action]), again = asked
        let working = frame([])
        check(IslandFeed.cardNotification(from: working, to: asked, appActive: false, userTyping: false, lang: .zhHans)?.title == L10n.zh["DeskMind needs your approval"],
              "a card arrives, DeskMind not active: a notification")
        check(IslandFeed.cardNotification(from: working, to: asked, appActive: true, userTyping: true, lang: .zhHans) != nil, "active but typing elsewhere: a notification")
        check(IslandFeed.cardNotification(from: working, to: asked, appActive: true, userTyping: false, lang: .zhHans) == nil, "DeskMind active, not typing: none")
        check(IslandFeed.cardNotification(from: asked, to: again, appActive: false, userTyping: false, lang: .zhHans) == nil, "the same card again: none (once per card)")
        let q = frame([#""kind":"ask","ask_id":"a2","# + missing])
        check(IslandFeed.cardNotification(from: asked, to: q, appActive: false, userTyping: false, lang: .zhHans).map { ($0.title, $0.body) } ?? ("", "") == (L10n.zh["DeskMind has a question"] ?? "", "发给谁？"),
              "a new card: its own notification, its text")
        check(IslandFeed.cardNotification(from: working, to: frame([#""kind":"task_done","status":"succeeded","reason":"","summary":"s""#]), appActive: false, userTyping: false, lang: .zhHans) == nil,
              "the end: not this one (RunOverlay.finish says it)")
    }

    static func wiringTests() {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func code(_ f: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) ?? "" }
        let goal = code("Main/GoalRunView.swift"), isl = code("Main/SessionIsland.swift"), ov = code("Main/RunOverlay.swift"), app = code("Main/DeskMindApp.swift")
        check(goal.contains("IslandFeed.frame(t, pinned: p") && goal.contains("island.apply(f, title: goal"), "GoalRunView: the session task's frames, applied")
        check(isl.contains("IslandFeed.cardNotification(") && isl.contains("o.show(") && isl.contains("o.update(") && isl.contains("o.setAsking(") && isl.contains("o.finish(")
              && !isl.contains("TaskState") && !isl.contains("SessionState"), "SessionIsland: only the feed's frames reach RunOverlay (no second state)")
        check(ov.contains("NotificationCenter.default.post(name: Self.showRecord, object: id)") && app.contains("publisher(for: RunOverlay.showRecord)") && app.contains("go(.record(r))"),
              "Show Details: opens the task's GoalRunView (its record)")
        check(goal.contains("let sid = record.sessionId") && goal.contains("shell.select(sid)") && goal.contains("sessionId: shell.selected, runId: t.runId"),
              "a session task's record keeps its session and run, and opens as the session has it")
    }
}
