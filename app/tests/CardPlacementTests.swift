// Where a card is answered (Shared/CardPlacement.swift, plan §1.4 / §4.1, invariant 4): the table cell by cell, the
// 250 ms settle, and random interleavings of window flips, the float coming and going, and the card's own life, judged
// by what the user can see in the simulated world (never by place()'s own rules).
import Foundation

enum CardPlacementTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "placement: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("placement.table"); tableTests()
        DecisionTests.group("placement.debounce"); debounceTests()
        DecisionTests.group("placement.property"); propertyTests()
        DecisionTests.group("placement.float"); floatTests()
    }

    typealias P = CardPlacement
    static let held = CardPhase.pending(.option(runId: "r", askId: "a", option: 0), until: 3)
    static let sent = CardPhase.sent(.option(runId: "r", askId: "a", option: 0))
    static let expired = CardPhase.expired(late: false, answerNow: .offered)

    static func tableTests() {
        // (phase, fits the float, window, float visible) → (shown, takes an answer, island, notification)
        let rows: [(CardPhase, Bool, MainWindowState, P.Float, P.Shown, Bool, P.Island, P.Notification)] = [
            // waiting
            (.open, true, .front, .visible, .chat, true, .none, .withdrawn),
            (.open, false, .front, .hidden, .chat, true, .none, .withdrawn),
            (.open, true, .behindVisible, .visible, .floatCard, true, .needsYou, .withdrawn),
            (.open, false, .behindVisible, .visible, .floatSummary, false, .needsYou, .withdrawn),
            (.open, true, .away, .visible, .floatCard, true, .needsYou, .withdrawn),
            (.open, false, .away, .visible, .floatSummary, false, .needsYou, .withdrawn),
            (.open, true, .behindVisible, .hidden, .islandOnly, false, .needsYou, .post),
            (.open, true, .away, .hidden, .islandOnly, false, .needsYou, .post),
            // held for its take-back: the same place, 撤回 there
            (held, true, .front, .visible, .chat, true, .none, .withdrawn),
            (held, true, .behindVisible, .visible, .floatCard, true, .needsYou, .withdrawn),
            (held, false, .away, .visible, .floatSummary, false, .needsYou, .withdrawn),
            (held, true, .away, .hidden, .islandOnly, false, .needsYou, .post),
            // sent: shown greyed where it is, takes nothing
            (sent, true, .front, .visible, .chat, false, .none, .withdrawn),
            (sent, true, .behindVisible, .visible, .floatCard, false, .needsYou, .withdrawn),
            (sent, true, .away, .hidden, .islandOnly, false, .needsYou, .post),
            // expired action card: 现在回答, never a notification for it
            (expired, false, .front, .visible, .chat, true, .none, .withdrawn),
            (expired, false, .behindVisible, .visible, .floatCard, true, .expired, .withdrawn),
            (expired, true, .away, .hidden, .islandOnly, false, .expired, .withdrawn),
            (.expired(late: false, answerNow: .asked), true, .behindVisible, .visible, .floatCard, false, .expired, .withdrawn),
            // ended: back to the task everywhere
            (.answered, true, .front, .visible, .ended, false, .none, .withdrawn),
            (.answered, true, .away, .hidden, .ended, false, .none, .withdrawn),
            (.voided("stop"), true, .behindVisible, .visible, .ended, false, .none, .withdrawn),
            (.voided("steer"), false, .away, .hidden, .ended, false, .none, .withdrawn),
            (.expired(late: false, answerNow: .gone), true, .behindVisible, .visible, .ended, false, .none, .withdrawn),
        ]
        for (phase, fits, window, fv, shown, takes, island, note) in rows {
            let p = P.place(phase, fitsFloat: fits, window: window, frontNow: window == .front, float: fv)
            check(p == P(shown: shown, takesAnswer: takes, island: island, notification: note),
                  "\(phase), fits \(fits), \(window), float \(fv): \(p)")
        }
        // the monitor cannot tell (another display, a full-screen app, the screen locked): as if unseen
        check(P.place(.open, fitsFloat: true, window: .behindVisible, frontNow: false, float: .unknown) == P(shown: .islandOnly, takesAnswer: false, island: .needsYou, notification: .post),
              "float unknown: told, as when unseen")
        // the notification over time: posted, kept, reminded once at 20 s, then kept; never while seen
        let note: [((Int, Double)?, P.Notification)] = [(nil, .post), ((1, 5), .keep), ((1, 19.9), .keep), ((1, 20), .remind), ((2, 1), .keep), ((2, 60), .keep)]
        for (n, want) in note {
            let p = P.place(.open, fitsFloat: false, window: .away, frontNow: false, float: .hidden, notified: n.map { (count: $0.0, since: $0.1) })
            check(p.notification == want, "notified \(String(describing: n)): \(want), got \(p.notification)")
        }
        check(P.place(.open, fitsFloat: false, window: .away, frontNow: false, float: .visible, notified: (count: 1, since: 30)).notification == .withdrawn,
              "the float came into sight: the notification goes")
        check(P.place(expired, fitsFloat: false, window: .away, frontNow: false, float: .hidden, notified: (count: 1, since: 30)).notification == .withdrawn,
              "expired: the old notification goes, no new one")
    }

    static func debounceTests() {
        var d = FrontmostDebounce(.front)
        check(d.saw(.behindVisible, at: 0) == .front, "a change: not yet")
        check(d.saw(.behindVisible, at: 0.2) == .front, "200 ms: not yet")
        check(d.saw(.behindVisible, at: 0.25) == .behindVisible, "250 ms: counts")
        check(d.saw(.front, at: 1) == .behindVisible && d.saw(.away, at: 1.1) == .behindVisible, "a flicker through two states: neither yet")
        check(d.tick(1.3) == .behindVisible, "the second has held 200 ms only")
        check(d.tick(1.35) == .away, "it held 250 ms: counts, by the clock alone")
        check(d.saw(.front, at: 2) == .away && d.saw(.away, at: 2.1) == .away && d.tick(5) == .away, "a flicker back: nothing moved")
        // a card arriving mid-flip is placed at once by the state that counts (the settle is for flips only)
        var e = FrontmostDebounce(.front)
        e.saw(.away, at: 10)
        check(P.place(.open, fitsFloat: true, window: e.stable, frontNow: false, float: .visible).takesAnswer == false
              && P.place(.open, fitsFloat: true, window: e.stable, frontNow: true, float: .visible).takesAnswer,
              "a card arriving during a flip: answerable at once in the chat while the window is in front; not where it is leaving")
        // #124 review (rev124TwoPlaces, adopted): the window just came to the front -- the chat takes keys and clicks at
        // once; for the 250 ms the settled state still says behind, the float must not take answers too
        var d2 = FrontmostDebounce(.behindVisible)
        let settled = d2.saw(.front, at: 0)
        let two = CardPlacement.place(.open, fitsFloat: true, window: settled, frontNow: true, float: .visible)
        check(two.shown == .chat && two.takesAnswer, "come to the front: the chat answers at once, the float does not (\(two))")
    }

    /// A small world: the main window's true state over time, the float's visibility, one card's life. At every step
    /// the placement made from the settled state is judged by what can be seen.
    static func propertyTests() {
        struct RNG { var s: UInt64; mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 } }
        let windows: [MainWindowState] = [.front, .behindVisible, .away]
        let phases: [CardPhase] = [.open, held, sent, expired, .answered, .voided("steer"), .voided("stop"), .expired(late: false, answerNow: .asked)]
        var runs = 0, violations: [String] = []
        for seed in 1...200 {
            var r = RNG(s: UInt64(seed))
            var t = 0.0, truth = MainWindowState.front, since = 0.0
            var d = FrontmostDebounce(.front)
            var phase = CardPhase.open
            var floatVisible = true
            // (whether the card fits the float: its structure and its measured height -- none yet, short, too tall)
            let fits = CardPlacement.fitsFloat(structure: r.next() % 2 == 0, height: [nil, 120, 1000][Int(r.next() % 3)])
            for _ in 0..<60 {
                t += [0.05, 0.1, 0.2, 0.3, 1.0][Int(r.next() % 5)]
                switch r.next() % 4 {
                case 0: let w = windows[Int(r.next() % 3)]; if w != truth { truth = w; since = t }
                case 1: floatVisible.toggle()
                case 2: phase = phases[Int(r.next() % UInt64(phases.count))]
                default: break
                }
                d.saw(truth, at: t)
                let p = CardPlacement.place(phase, fitsFloat: fits, window: d.stable, frontNow: truth == .front, float: floatVisible ? .visible : .hidden)
                runs += 1
                let tag = "seed \(seed) t \(t): \(phase) truth \(truth) settled \(d.stable) float \(floatVisible) → \(p)"
                // the oracle, from the world's true state (never the settled one place() is given): where an answer is
                // taken is a place the user can use now -- the chat only with the window truly in front, the float only
                // while it can be seen and the window is truly not in front (#124 review)
                let settledIsTrue = t - since >= FrontmostDebounce.settle
                if settledIsTrue && d.stable != truth { violations.append("settled lags the truth: " + tag) }
                if p.takesAnswer {
                    switch p.shown {
                    case .chat where truth == .front: break
                    case .floatCard where floatVisible && truth != .front: break
                    default: violations.append("an answer taken where it cannot be seen: " + tag)
                    }
                }
                // nothing is announced where the user already sees the card; an ended card leaves no notification
                if (p.notification == .post || p.notification == .remind) && (truth == .front || floatVisible) { violations.append("notified while seen: " + tag) }
                if phase.ending != nil && !phase.isExpiredOffer && (p.shown != .ended || p.notification != .withdrawn || p.island != .none) {
                    violations.append("an ended card still asks: " + tag)
                }
                if phase.isExpiredOffer && (p.notification == .post || p.notification == .remind) { violations.append("an expiry notified: " + tag) }
                // the take-back belongs to the phase: where the card is placed never depends on its deadline (a move
                // cannot restart or shorten it -- the countdown is CardStore's)
                if case .pending(let a, let until) = phase {
                    let other = CardPlacement.place(.pending(a, until: until + 7), fitsFloat: fits, window: d.stable, frontNow: truth == .front,
                                                    float: floatVisible ? .visible : .hidden)
                    if other != p { violations.append("placement depends on the take-back's deadline: " + tag) }
                }
            }
        }
        check(violations.isEmpty, "\(runs) steps: \(violations.prefix(3))")
    }
}

extension CardPlacementTests {
    /// The float's policy, cell by cell; and placement fed the panel's measured visibility never changes the policy
    /// (no loop: the policy does not read placement).
    static func floatTests() {
        typealias F = FloatPolicy
        let rows: [(MainWindowState, Bool, Bool, Bool, F.Shown)] = [
            (.front, false, false, false, .hidden), (.front, true, false, false, .hidden), (.front, true, true, true, .hidden),
            (.behindVisible, false, false, false, .hidden), (.away, false, false, true, .hidden),
            (.behindVisible, true, false, false, .open), (.away, true, false, true, .collapsed),
            (.behindVisible, true, true, true, .open), (.away, true, true, false, .open), (.away, false, true, true, .open),
        ]
        for (w, task, card, collapsed, want) in rows {
            check(F.shown(window: w, taskActive: task, cardWaiting: card, userCollapsed: collapsed) == want,
                  "float: \(w), task \(task), card \(card), collapsed \(collapsed): \(want)")
        }
        // #130 review: a waiting card is never collapsed away -- the user's 收起 waits for it to close
        check(F.collapsed(user: true, cardWaiting: false) && !F.collapsed(user: true, cardWaiting: true) && !F.collapsed(user: false, cardWaiting: false),
              "collapsed: the user's say, never while a card waits")
        let floatSource = ((try? String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Main/FloatPanel.swift"), encoding: .utf8)) ?? "")
        check(floatSource.contains("if FloatPolicy.collapsed(user: float.userCollapsed, cardWaiting: waits(n)) { capsule(n) }")
              && !floatSource.contains("if float.userCollapsed {") && floatSource.contains("if !waits(n) {\n                Button(L(\"Collapse\""),
              "the float draws a waiting card whole when collapsed, and offers no 收起 while one waits")
        // #125 Codex review at 2f29d42: whether the card fits the float is its measured height too
        check(!CardPlacement.fitsFloat(structure: true, height: nil) && !CardPlacement.fitsFloat(structure: true, height: 1000)
              && CardPlacement.fitsFloat(structure: true, height: 200) && !CardPlacement.fitsFloat(structure: false, height: 100),
              "fits the float: allowed by its structure and measured within the room (not measured yet: not)")
        check(CardPlacement.place(.open, fitsFloat: CardPlacement.fitsFloat(structure: true, height: 2000), window: .away, frontNow: false, float: .visible).shown == .floatSummary,
              "a 100-line card: the float gives its title and the way to the main window")
        // ⌘⇧P: popped out, the float is up with the window in front too (the card still the chat's then)
        check(F.shown(window: .front, taskActive: true, cardWaiting: false, userCollapsed: false, poppedOut: true) == .open, "popped out, in front: up")
        check(F.shown(window: .front, taskActive: false, cardWaiting: false, userCollapsed: false, poppedOut: true) == .hidden, "popped out, no task: not up")
        check(CardPlacement.place(.open, fitsFloat: true, window: .front, frontNow: true, float: .visible).shown == .chat, "popped out: the card is still the chat's in front")
        // the panel's fact -- seen, hidden, unknown -- goes into placement only: every combination gives one answer
        // place, the float's only where it is seen
        for w in [MainWindowState.behindVisible, .away] {
            for fact in [CardPlacement.Float.visible, .hidden, .unknown] {
                let p = CardPlacement.place(.open, fitsFloat: true, window: w, frontNow: false, float: fact)
                check((p.shown == .floatCard) == (fact == .visible) && (p.takesAnswer == (fact == .visible)), "\(w), float \(fact): \(p.shown)")
            }
        }
    }
}

extension ShellModel {
    /// A test's card laid out small in a tall column: it fits the pinned place whole (cardFits).
    func fit(_ card: CardModel) { pinRoom(columnHeight: 1000); cardLaidOut(card, height: 1) }
}
