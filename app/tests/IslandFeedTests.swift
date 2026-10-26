// M2 PR B: a session task's island and notifications come from its one state through IslandFeed — a table, session
// state → island frame and notification — and a goal's island follows its own task (GoalRun's `changed`), Show
// Details opens its record (IslandFeed.detailsRoute).
// Run from DecisionTests.main (build.sh).

import Foundation

enum IslandFeedTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "island: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("island.tableTests"); tableTests()
        DecisionTests.group("island.notifyTests"); notifyTests()
        DecisionTests.group("island.barTests"); barTests()
        DecisionTests.group("island.notchSideTests"); notchSideTests()
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

    /// The bar (U2): each state its kind and words.
    static func barTests() {
        let step = #""kind":"step","text":"click","step_id":"s1","human":"点「发送」""#
        func bar(_ body: [String], phase: CardPhase? = nil, app: String? = nil, floatShows: Bool = false) -> IslandFrame {
            let (s, t) = task(body)
            let pinned: (card: CardState, phase: CardPhase)? = (s.openCard?.card ?? t.expiredCard).map { c in (c, phase ?? CardStore().phase(c, of: t)) }
            return IslandFeed.frame(t, pinned: pinned, app: app, floatShows: floatShows, lang: .zhHans)
        }
        let z = { (k: String) in L10n.zh[k] ?? "?" + k }
        let ask = #""kind":"ask","ask_id":"a1","# + action
        let rows: [(String, IslandFrame, IslandFrame.Kind, String, String)] = [
            ("preparing", bar([]), .preparing, z("Getting ready"), ""),
            ("working, the app known", bar([step], app: "Safari"), .working, "Safari", ""),
            ("working, no app: the task", bar([step]), .working, "x", ""),
            ("a card, the float shows it: its kind", bar([ask], floatShows: true), .needsYou, z("Needs you"), z("confirm before acting")),
            ("a card, no float: its title", bar([ask]), .needsYou, z("Needs you"), "要点「发送」吗？"),
            ("held (take-back): still needs you", bar([ask], phase: .pending(.option(runId: "r1", askId: "a1", option: 0), until: 0)), .needsYou, z("Needs you"), "要点「发送」吗？"),
            ("expired, still answerable", bar([ask, #""kind":"ask_void","ask_id":"a1","why":"timeout""#]), .needsYou, z("Needs you"), "要点「发送」吗？"),
            ("paused", bar([step, #""kind":"waiting""#]), .paused, z("You're on the Mac"), z("Resumes when you stop")),
            ("done", bar([step, #""kind":"task_done","status":"succeeded","reason":"","summary":"s""#]), .done, z("Done"), "1 步 · 0 秒"),
            ("failed", bar([#""kind":"task_done","status":"failed","reason":"","summary":"s""#]), .failed, z("Didn't finish"), z("See why")),
            ("stopped", bar([step, #""kind":"task_done","status":"stopped","reason":"","summary":"s""#]), .stopped, z("Stopped"), "1 步"),
            ("cancelled: stopped", bar([#""kind":"task_done","status":"cancelled","reason":"","summary":"s""#]), .stopped, z("Stopped"), "0 步"),
        ]
        for (name, f, kind, left, right) in rows {
            check(f.kind == kind && f.left == left && f.right == right, "bar, \(name): \(f.kind) «\(f.left)» «\(f.right)» (want \(kind) «\(left)» «\(right)»)")
        }
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

    /// The island as a test sees it: every call, in order, and the details link.
    final class FakeSurface: IslandSurface {
        var owner: ObjectIdentifier?
        var calls: [String] = []
        var appActive = true
        var userTyping = false
        func requestNotifications() {}
        func show(title: String, line: String, onStop: @escaping () -> Void) { calls.append("show") }
        func update(step: Int, line: String) { calls.append("update") }
        func apply(_ frame: IslandFrame) {}
        func setAsking(_ on: Bool) { calls.append("asking:\(on)") }
        func finish(passed: Bool, stopped: Bool, summary: String) { calls.append("finish:\(passed):\(summary)") }
        func notify(title: String, body: String) { calls.append("notify") }
    }

    /// Each side of the bar at a notch: what is outside the notch, less the inset and the gap; the two sides and the
    /// notch never overlap, at any notch width and either bar width (#130 Codex review).
    static func notchSideTests() {
        check(Island.sideWidth(bar: 380, notchWidth: nil) == nil && Island.sideWidth(bar: 380, notchWidth: 0) == nil, "no notch: no sides")
        check(Island.sideWidth(bar: 380, notchWidth: 200) == 66 && Island.sideWidth(bar: 460, notchWidth: 200) == 106, "the 200 pt notch: 66 / 106 a side")
        check(Island.sideWidth(bar: 380, notchWidth: 400) == 0, "a notch wider than the bar: no room, never negative")
        // at a notch the bar is 460 in every state (fable, #130): 106 a side at the 200 pt notch, needing you or not
        check(Island.width(notched: true, needsYou: false) == 460 && Island.width(notched: true, needsYou: true) == 460,
              "at the notch: 460 whatever the state")
        check(Island.width(notched: false, needsYou: false) == 380 && Island.width(notched: false, needsYou: true) == 460,
              "no notch: 380, 460 while it needs you")
        check(Island.sideWidth(bar: Island.width(notched: true, needsYou: false), notchWidth: 200) == 106, "working at the 200 pt notch: 106 a side")
        for bar in [Island.barWidth, Island.barWideWidth] {
            for n in stride(from: CGFloat(1), through: 500, by: 7) {
                let side = Island.sideWidth(bar: bar, notchWidth: n)!
                // the left side ends, and the right one starts, at least the gap away from the notch
                let leftEnd = Island.barInset + side, notchStart = (bar - n) / 2
                check(side >= 0 && (side == 0 || leftEnd + Island.notchGap <= notchStart + 0.001), "bar \(bar), notch \(n): the left side \(side) stays clear")
            }
        }
        // the screen's notch is what the bar is told: the gap between the menu bar's two areas
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let n = Island.notch(screen: screen, safeTop: 37, left: CGRect(x: 0, y: 945, width: 656, height: 37), right: CGRect(x: 856, y: 945, width: 656, height: 37))
        check(n?.width == 200, "the notch between the two areas: 200 pt")
    }
}
