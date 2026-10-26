// The first launch completes (A12, Shared/FirstRun.swift): four steps, each skippable, never stuck; a failed check
// never traps; what is left unmet is said later, once; the flow asks the helper only for its steps and opens no
// conversation.
import Foundation

enum FirstRunTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "first run: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("firstrun.table"); tableTests()
        DecisionTests.group("firstrun.sequences"); sequenceTests()
        DecisionTests.group("firstrun.static"); staticTests()
    }

    static func tableTests() {
        typealias F = FirstRun
        var f = F()
        check(f.step == .language && !f.canLater, "it starts at the language, which has no 稍后")
        f.apply(.next); check(f.step == .permissions && f.canLater, "then the permissions, 稍后 there")
        f.apply(.later); check(f.step == .key, "稍后 on the permissions: the key")
        f.apply(.checked(ok: false)); check(f.step == .key && f.facts.checkOK == false, "a failed check: said, the step stays")
        f.apply(.later); check(f.step == .examples, "稍后 after a failed check: on (never trapped)")
        f.apply(.back); check(f.step == .key, "back")
        f.apply(.next); f.apply(.next); check(f.step == .done, "done")
        f.apply(.next); f.apply(.back); check(f.step == .done, "done stays done")
        var g = F(); g.apply(.skipAll); check(g.step == .done, "跳过全部: done at once")
        check(F.unmet(F.Facts(accessibility: true, screen: true, keySet: true)) == [], "all met: nothing said")
        check(F.unmet(F.Facts(accessibility: true, screen: false, keySet: false)) == [.permissions, .key], "a permission and the key missing: both rows")
        check(F.unmet(F.Facts(accessibility: true, screen: true, keySet: false)) == [.key], "only the key")
        check(F.unmet(F.Facts(accessibility: true, screen: true, keySet: false), keysReadable: false) == [.keyUnreadable], "(#127 delta) unreadable keys: said as that, never 'no key'")
        // the key step's one button (U2): off with nothing typed and none set; a failed save or check stays, 稍后 still
        // there; a check that works moves on by itself
        var k = F(step: .key)
        check(!k.canContinue(typed: false) && k.canContinue(typed: true), "nothing typed, none set: 继续 off; typed: on")
        k.apply(.saved(ok: false)); check(k.step == .key && k.facts.saveOK == false && k.canLater, "a save that failed: stays, 稍后 there")
        k.apply(.saved(ok: true)); k.apply(.checked(ok: false)); check(k.step == .key && k.canLater, "saved, the check failed: stays, 稍后 there")
        k.apply(.checked(ok: true)); check(k.step == .examples, "the check works: on to the examples")
        var p = F(step: .permissions); check(!p.canContinue(typed: false), "permissions not granted: 继续 off (稍后)")
        p.facts.accessibility = true; p.facts.screen = true; check(p.canContinue(typed: false), "both granted: on")
        var c = F(step: .language); c.apply(.checked(ok: true)); check(c.step == .language, "a check elsewhere moves nothing")
        let ks: [(F.KeyState, F.KeyState, String)] = [
            (F.keyState(known: true, readable: true, last4: nil, busy: false, checkOK: nil, why: nil, model: nil), .empty, "none"),
            (F.keyState(known: true, readable: true, last4: "abcd", busy: false, checkOK: nil, why: nil, model: nil), .set(last4: "abcd"), "set"),
            (F.keyState(known: true, readable: true, last4: "abcd", busy: true, checkOK: nil, why: nil, model: nil), .checking, "being tried"),
            (F.keyState(known: true, readable: true, last4: "abcd", busy: false, checkOK: true, why: nil, model: "m"), .ok(model: "m"), "works"),
            (F.keyState(known: true, readable: true, last4: "abcd", busy: false, checkOK: false, why: "401", model: nil), .bad(why: "401"), "doesn't, why"),
            (F.keyState(known: true, readable: false, last4: "abcd", busy: true, checkOK: true, why: nil, model: nil), .unreadable, "unreadable over all"),
        ]
        for (got, want, name) in ks { check(got == want, "key state, \(name): \(got)") }
        check(F.examples.count == 3 && F.examples.allSatisfy { L($0, lang: .zhHans) != $0 }, "three examples, each in Chinese too")
    }

    /// From any state reached by any sequence (facts as the helper says them, checks failing or not), 下一步 or 稍后
    /// reaches done in at most 4 moves.
    static func sequenceTests() {
        typealias F = FirstRun
        var g = CardStoreTests.RNG(x: 41)
        for _ in 0..<500 {
            var f = F()
            for _ in 0..<g.next(12) {
                f.facts.accessibility = g.next(2) == 0; f.facts.screen = g.next(2) == 0; f.facts.keySet = g.next(2) == 0
                f.apply([.next, .later, .back, .checked(ok: g.next(2) == 0), .saved(ok: g.next(2) == 0), .back][g.next(6)])
            }
            for useLater in [false, true] {
                var h = f, moves = 0
                while h.step != .done && moves < 10 { h.apply(useLater && h.canLater ? .later : .next); moves += 1 }
                if h.step != .done || moves > 4 { check(false, "stuck from \(f) (\(useLater ? "稍后" : "下一步")): \(moves) moves"); return }
            }
        }
    }

    /// The flow asks the helper only for what a step is about, and opens no conversation.
    static func staticTests() {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func code(_ f: String) -> String {
            ((try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) ?? "")
                .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        }
        let view = code("Main/FirstRunView.swift"), flow = code("Shared/FirstRun.swift")
        check(!view.isEmpty && !flow.isEmpty, "read")
        for c in [view, flow] {
            for bad in ["session.open", "SessionClient", "shell.submit", "shell.client", ".send(", "newConversation", "activate("] where c.contains(bad) {
                check(false, "the first run calls \(bad)")
            }
        }
        let ops = view.components(separatedBy: "\"op\": \"").dropFirst().compactMap { $0.split(separator: "\"").first.map(String.init) }
        check(Set(ops).isSubset(of: ["model_check"]), "its own requests: model_check only (permissions through the grant panel, keys through keys.set): \(ops)")
        // (U2: the key typed in place, saved as the model sheet saves it -- keys.set's merge, `replace` only over keys
        // the helper can't read: A11's "the key in effect is the last one set")
        check(view.contains("grant: { model.grant($0) }") && view.contains("CloudModelSettings.set(pairs, replace: replace)"), "the permissions and the key through their own paths")
        check(view.contains("granted: { model.granted($0) }") && view.contains("if granted(g)"), "「已授权」 only from the helper's status")
        check(view.contains("shell.draft = L(e, lang: lang)") && !view.contains("submit"), "an example fills the composer, never sends")
    }
}
