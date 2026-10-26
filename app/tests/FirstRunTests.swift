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
        DecisionTests.group("firstrun.form"); formTests()
        DecisionTests.group("firstrun.staleCheck"); staleCheckTests()
        DecisionTests.group("firstrun.later"); laterTests()
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
            (F.keyState(known: true, readable: false, last4: "abcd", busy: false, checkOK: true, why: nil, model: nil), .unreadable, "unreadable over a result"),
            (F.keyState(known: true, readable: false, last4: nil, busy: true, checkOK: nil, why: nil, model: nil), .checking, "a save over unreadable keys under way: busy (no second press)"),
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

    /// The model settings' one form (#130 review: the first run's key step had re-made the sheet's save and dropped parts
    /// of it): the first run turns the engine on; a custom service's settings survive 继续 with no new key; another
    /// service clears what was typed and its check.
    static func formTests() {
        let deepseek = CloudProvider.named("deepseek"), openrouter = CloudProvider.named("openrouter"), custom = CloudProvider.named("custom")
        // 1. the first run turns the engine on (a fresh install's first message needs it)
        var f = ModelForm(provider: deepseek, settings: [:])
        f.key = "sk-new"
        let p = f.plan(engine: true)
        check(p.engine == true && p.pairs == ["DEEPSEEK_API_KEY": "sk-new"] && p.engineConfig == "ds-flash" && p.provider == deepseek,
              "first run, a key typed: the key, the service, its configuration, the engine on: \(p)")
        // 2. a custom service: its URL and model as kept, through 继续 with no new key and with one
        let kept = ["CUSTOM_URL": "https://llm.example/v1", "CUSTOM_MODEL": "m-7"]
        var c = ModelForm(provider: custom, settings: kept)
        check(c.url == kept["CUSTOM_URL"] && c.model == "m-7" && c.canSave(keySet: true), "custom: loaded as kept, savable with the key it has")
        let none = c.plan(engine: true)
        check(none.pairs == kept && none.engineConfig == "openai:custom|m-7", "custom, no new key: its URL and model kept, its configuration whole: \(none)")
        c.key = "sk-c"
        check(c.plan(engine: true).pairs == kept.merging(["CUSTOM_API_KEY": "sk-c"]) { a, _ in a }, "custom, a new key: with its URL and model, never empty ones")
        check(!ModelForm(provider: custom, settings: [:]).canSave(keySet: true), "custom with no URL and model: not savable")
        var late = ModelForm(provider: custom, settings: [:]); late.settingsCame(kept)
        check(late.url == kept["CUSTOM_URL"] && late.model == "m-7", "the helper's answer after opening: filled in")
        // 3. another service: what was typed and its check go
        var s = ModelForm(provider: deepseek, settings: [:])
        s.key = "sk-deepseek"; s.checkOK = false; s.why = "401"; s.reached = "x"
        s.select(openrouter, settings: [:])
        check(s.key.isEmpty && s.checkOK == nil && s.why == nil && s.reached == nil && s.plan(engine: true).pairs["OPENROUTER_API_KEY"] == nil,
              "another service: the key typed for the last one never saved in its place, its check gone")
        check(!s.canSave(keySet: false) && s.canSave(keySet: true), "nothing typed: savable only with a key set")
        var off = ModelForm(provider: deepseek, settings: [:], useCloud: false); off.key = "sk"
        check(off.plan(engine: false) == ModelForm.Plan(pairs: [:], provider: nil, engineConfig: nil, engine: false), "the cloud off: nothing but the engine")
        // both windows save the one way
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func read(_ f: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) ?? "" }
        let firstRun = read("Main/FirstRunView.swift"), sheet = read("Main/CloudModel.swift")
        check(firstRun.contains("form.plan(engine: true)") && firstRun.contains("CloudModelSettings.apply(plan)") && !firstRun.contains("CloudModelSettings.set(")
              && !firstRun.contains("CloudModelSettings.provider = ") && !firstRun.contains("engineConfig = "),
              "the first run saves through the form: the engine on, nothing written by hand")
        check(sheet.contains("@State private var form = ModelForm(") && sheet.contains("form.plan(engine: ModelChoice.engineToWrite(") && sheet.contains("CloudModelSettings.apply(plan)"),
              "the sheet saves through the same form")
    }

    /// A save or check answers for the form it was made from: one that comes after the user changed the form is
    /// dropped -- no advance, no 「能用」 (#130 Codex review). The view's steps, as FirstRunView takes them.
    static func staleCheckTests() {
        let deepseek = CloudProvider.named("deepseek"), openrouter = CloudProvider.named("openrouter")
        var flow = FirstRun(step: .key, facts: FirstRun.Facts(accessibility: true, screen: true))
        var form = ModelForm(provider: deepseek, settings: [:])
        form.edit({ var n = form; n.key = "sk-deepseek"; return n }(), settings: [:])
        // 继续: tagged with the form as it is
        let v = form.version
        check(form.saved(version: v, failure: nil) == true, "the save of the form as it is: taken")
        flow.apply(.saved(ok: true))
        // the user switches the service while the check is out
        form.edit({ var n = form; n.provider = openrouter; return n }(), settings: [:])
        check(form.version != v && form.provider == openrouter && form.checkOK == nil, "another service: a new version, nothing checked")
        // the old service's 「能用」 arrives
        if let ok = form.checked(version: v, ok: true, reached: "deepseek-chat", why: nil), ok { flow.apply(.checked(ok: true)) }
        check(flow.step == .key, "the old check's ok: no advance (step \(flow.step))")
        check(form.checkOK == nil && form.reached == nil, "the old check's ok: no 「能用」 on the new form")
        check(FirstRun.keyState(known: false, readable: true, last4: nil, busy: false, checkOK: form.checkOK, why: form.why, model: form.reached) == .empty,
              "the key step shows nothing checked")
        // a stale failure says nothing either
        check(form.checked(version: v, ok: false, reached: nil, why: "401") == nil && form.why == nil, "the old check's failure: no 「不能用」 on the new form")
        check(form.saved(version: v, failure: "disk") == nil && form.why == nil, "an old save's failure: nothing said")
        // the same form, typed into: also a new version; a check of the current form is taken
        var g = ModelForm(provider: deepseek, settings: [:]); let g0 = g.version
        g.edit({ var n = g; n.key = "sk-1"; return n }(), settings: [:])
        check(g.version == g0 + 1, "a key typed: a new version")
        let gv = g.version
        g.edit(g, settings: [:])
        check(g.version == gv, "nothing changed: the same version")
        g.checkOK = nil
        check(g.checked(version: gv, ok: true, reached: "deepseek-chat", why: nil) == true && g.checkOK == true && g.reached == "deepseek-chat",
              "the current form's check: taken")
        // the page holds its fields while a save or check is out
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let src = (try? String(contentsOf: dir.appendingPathComponent("Main/FirstRunView.swift"), encoding: .utf8)) ?? ""
        let fields = src.components(separatedBy: "private var keyFields").dropFirst().first?.components(separatedBy: "            status\n").first ?? ""
        check(fields.components(separatedBy: ".disabled(keyState == .checking)").count - 1 == 2 && fields.contains("Picker(") && fields.contains("SecureField("),
              "the service picker, the key and a custom service's fields are off while checking")
        check(src.contains("form.saved(version: version") && src.contains("form.checked(version: version") && src.contains("form.edit(new"),
              "the view takes results only through the version")
    }

    /// 「稍后」 on the key step whenever the last save or check failed or the keychain can't be read: a key saved but
    /// not working never leaves only 「全部跳过」 (#130 Codex review).
    static func laterTests() {
        func flow(keySet: Bool, saveOK: Bool? = nil, checkOK: Bool? = nil) -> FirstRun {
            FirstRun(step: .key, facts: FirstRun.Facts(accessibility: true, screen: true, keySet: keySet, saveOK: saveOK, checkOK: checkOK))
        }
        let table: [(String, FirstRun, FirstRun.KeyState, Bool)] = [
            ("no key: 继续 off", flow(keySet: false), .empty, true),
            ("a key set, never checked", flow(keySet: true), .set(last4: "abcd"), false),
            ("a key set, checking", flow(keySet: true), .checking, false),
            ("a key saved, its check failed", flow(keySet: true, saveOK: true, checkOK: false), .bad(why: "401"), true),
            ("a key set, its check failed (state only)", flow(keySet: true), .bad(why: "401"), true),
            ("a key set, check failed (fact only)", flow(keySet: true, checkOK: false), .set(last4: "abcd"), true),
            ("a save failed", flow(keySet: true, saveOK: false), .set(last4: "abcd"), true),
            ("the keychain unreadable", flow(keySet: true), .unreadable, true),
            ("a key that works", flow(keySet: true, saveOK: true, checkOK: true), .ok(model: "m"), false),
        ]
        for (what, f, k, later) in table { check(f.showsLater(k) == later, "\(what): 稍后 \(later ? "shown" : "not shown")") }
        var lang = FirstRun(step: .language); lang.facts.keySet = true
        check(!lang.showsLater(.bad(why: "x")), "the language step never has 稍后")
        let perm = FirstRun(step: .permissions)
        check(perm.showsLater(.empty) && !FirstRun(step: .permissions, facts: FirstRun.Facts(accessibility: true, screen: true)).showsLater(.bad(why: "x")),
              "permissions: 稍后 only while one is missing, whatever the key")
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
        check(view.contains("grant: { model.grant($0) }") && view.contains("CloudModelSettings.save(plan, replace: replace)"), "the permissions and the key through their own paths")
        check(view.contains("granted: { model.granted($0) }") && view.contains("if granted(g)"), "「已授权」 only from the helper's status")
        check(view.contains("shell.draft = L(e, lang: lang)") && !view.contains("submit"), "an example fills the composer, never sends")
    }
}
