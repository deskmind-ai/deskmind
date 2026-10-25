// Rule 1.7 (plan §1.7, owner 10-25) and the window's contrast: one language per screen, from one setting.
// - resolveTests: the setting (follow the system by default, 中文, English) → the language, by one function.
// - oneSourceTests: nothing reads the setting but that function; the session is opened in the same language.
// - completenessTests: every key the code passes to L has its Chinese, with the same arguments.
// - unmixedTests: no English words in the Chinese (names, units and commands apart), no Chinese in the English.
// - bypassTests: the views put no words on screen outside L (numbers, symbols and proper names apart).
// - contrastTests: every text colour on every background it is drawn on, 4.5:1 at least, in both appearances.
import Foundation

enum L10nTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "l10n: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("l10n.resolve"); resolveTests()
        DecisionTests.group("l10n.oneSource"); oneSourceTests()
        DecisionTests.group("l10n.completeness"); completenessTests()
        DecisionTests.group("l10n.unmixed"); unmixedTests()
        DecisionTests.group("l10n.bypass"); bypassTests()
        DecisionTests.group("l10n.contrast"); contrastTests()
    }

    static var appDir: URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath) }
    static func source(_ f: String) -> String { (try? String(contentsOf: appDir.appendingPathComponent(f), encoding: .utf8)) ?? "" }

    /// The code of a file without its comments (line comments; a `//` inside a string literal is kept).
    static func code(_ f: String) -> String {
        source(f).components(separatedBy: "\n").map { line -> String in
            var inString = false, prev: Character = " ", out = ""
            for ch in line {
                if ch == "\"" && prev != "\\" { inString.toggle() }
                if !inString && ch == "/" && prev == "/" { out.removeLast(); break }
                out.append(ch); prev = ch
            }
            return out
        }.joined(separator: "\n")
    }

    /// Every source of both apps (build.sh's two lines).
    static func appSources() -> [String] {
        let build = source("build.sh").components(separatedBy: "\n")
        var files: Set<String> = []
        for marker in ["-o \"$MAIN/Contents/MacOS/DeskMind\"", "-o \"$HELPER/Contents/MacOS/DeskMindHands\""] {
            guard let at = build.firstIndex(where: { $0.contains(marker) }), at + 1 < build.count else { check(false, "build.sh: \(marker)"); continue }
            files.formUnion(build[at + 1].split(separator: " ").map(String.init).filter { $0.hasSuffix(".swift") })
        }
        return files.sorted()
    }

    // MARK: Swift string literals

    /// The literal starting at `i` (a `"`): its text, and the index after it; nil text when it interpolates.
    static func literal(_ s: [Character], at i: Int) -> (text: String?, end: Int) {
        guard i < s.count, s[i] == "\"" else { return (nil, i) }
        var j = i + 1, out = "", plain = true
        while j < s.count {
            let c = s[j]
            if c == "\\", j + 1 < s.count {
                let n = s[j + 1]
                if n == "(" {   // an interpolation: skip to its closing parenthesis
                    plain = false
                    var depth = 0; j += 1
                    while j < s.count { if s[j] == "(" { depth += 1 } else if s[j] == ")" { depth -= 1; if depth == 0 { break } }; j += 1 }
                    out.append("\u{1}")   // (a placeholder: no letters of its own)
                    j += 1; continue
                }
                out.append(["n": "\n", "t": "\t", "\"": "\"", "\\": "\\"][n] ?? n); j += 2; continue
            }
            if c == "\"" { return (plain ? out : nil, j + 1) }
            if c == "\n" { break }
            out.append(c); j += 1
        }
        return (nil, j)
    }

    /// Every plain literal in the first argument of each call of `name(` in `text`, the argument read up to its
    /// first top-level comma or the call's closing parenthesis (a ternary's two keys both count).
    static func firstArgumentLiterals(_ text: String, call name: String) -> (keys: [String], interpolated: Int) {
        let s = Array(text), n = Array(name)
        var keys: [String] = [], interpolated = 0, i = 0
        while i + n.count <= s.count {
            guard Array(s[i..<i + n.count]) == n, i == 0 || !(s[i - 1].isLetter || s[i - 1].isNumber || s[i - 1] == "_" || s[i - 1] == ".") else { i += 1; continue }
            var j = i + n.count, depth = 0
            while j < s.count {
                let c = s[j]
                if c == "\"" {
                    let (t, end) = literal(s, at: j)
                    if let t { if depth == 0 { keys.append(t) } } else if depth == 0 { interpolated += 1 }
                    j = end; continue
                }
                if c == "(" || c == "[" { depth += 1 } else if c == ")" || c == "]" { if depth == 0 { break }; depth -= 1 } else if c == "," && depth == 0 { break }
                j += 1
            }
            i = j
        }
        return (keys, interpolated)
    }

    // MARK: the setting

    static func resolveTests() {
        let table: [(String?, ResolvedLang, ResolvedLang)] = [
            (nil, .zhHans, .zhHans), (nil, .en, .en), ("system", .zhHans, .zhHans), ("system", .en, .en),
            ("zh-Hans", .en, .zhHans), ("zh-Hans", .zhHans, .zhHans), ("en", .zhHans, .en), ("en", .en, .en),
            ("fr", .zhHans, .zhHans), ("", .en, .en), ("zh", .en, .en),   // unknown: follow the system
        ]
        for (stored, system, want) in table {
            check(AppLanguage.resolve(stored, system: { system }) == want, "stored \(stored ?? "nil"), system \(system): \(want)")
        }
        let systems: [([String], ResolvedLang)] = [(["zh-Hans-CN", "en"], .zhHans), (["zh-Hant-TW"], .zhHans), (["zh-CN"], .zhHans),
                                                   (["en-US", "zh-Hans"], .en), (["ja-JP"], .en), ([], .en)]
        for (pref, want) in systems { check(ResolvedLang.fromSystem(pref) == want, "system languages \(pref): \(want)") }
        check(AppLanguage.choice(nil) == .system && AppLanguage.choice("x") == .system && AppLanguage.choice("en") == .en, "the shown choice: system unless set")
        let d = ShellTests.scratchDefaults()
        d.set("zh-Hans", forKey: AppLanguage.key)
        check(AppLanguage.current(d) == .zhHans, "read from the defaults given")
        d.set("en", forKey: AppLanguage.key)
        check(AppLanguage.current(d) == .en, "and again after a change")
    }

    static func oneSourceTests() {
        var found: [String] = []
        for f in appSources() where f != "Shared/L10n.swift" {
            let c = code(f)
            if c.contains("AppLanguage(rawValue") { found.append("\(f): AppLanguage(rawValue") }
            if c.contains("\"language\"") { found.append("\(f): the setting's key as a literal") }
            if c.contains("ResolvedLang.fromSystem") { found.append("\(f): the system's language read directly") }
        }
        check(found.isEmpty, "only L10n.swift reads the setting (AppLanguage.resolve / current): \(found)")
        let app = code("Main/DeskMindApp.swift"), split = code("Main/MainSplitView.swift")
        check(app.contains(".onChange(of: lang, initial: true) { _, now in ResolvedLang.current = now }") && app.contains("let lang = AppLanguage.resolve(language)"),
              "the views and ResolvedLang.current (every request's lang) from the one setting")
        check(split.contains("lang: { AppLanguage.current() }"), "the window's sessions are opened in the setting's language")
        check(code("Shared/Protocol.swift").contains("body[\"lang\"] = ResolvedLang.current.rawValue"), "the helper is told the same language with every request")
        // the session's language is the app's: what it writes (H3) follows the setting
        for (lang, codeWanted) in [(ResolvedLang.zhHans, "zh"), (.en, "en")] {
            let t = ShellTests.Timers()
            let m = ShellModel(client: SessionClient(transport: CardStoreTests.Wire()), defaults: ShellTests.scratchDefaults(), config: { "openai:local|fake" },
                               lang: { lang }, takeBackAfter: t.after, now: { t.now }, work: { $0() }, deliver: { $0() })
            check(m.sessionSettings().lang == codeWanted, "a session opened in \(lang): \(m.sessionSettings().lang)")
        }
        check(app.contains("Picker(L(\"Language\"") && app.contains("AppLanguage.system.rawValue") && app.contains("AppLanguage.zhHans.rawValue") && app.contains("AppLanguage.en.rawValue"),
              "the setting offers follow system, 中文 and English (View menu)")
    }

    // MARK: every key has both languages

    /// The keys the code passes to L: the literals of its first argument, and what the functions that hand L its
    /// key return.
    static func usedKeys() -> (keys: Set<String>, interpolated: [String]) {
        var keys: Set<String> = [], interpolated: [String] = []
        for f in appSources() {
            let r = firstArgumentLiterals(code(f), call: "L(")
            keys.formUnion(r.keys)
            if r.interpolated > 0 && f != "Shared/L10n.swift" { interpolated.append("\(f): \(r.interpolated)") }
        }
        let statuses: [LiveView.Status] = [.starting, .working, .waitingForUser, .paused, .hidden, .done, .failed, .stopped]
        keys.formUnion(statuses.map(LiveView.word))
        keys.formUnion([Island.Ending.done, .failed, .stopped].map(Island.endWord))
        keys.formUnion(RunStage.allCases.flatMap { [$0.key, $0.shortKey] })
        keys.formUnion(["Run again", "Start"].filter { SelfTest.startLabel(selected: "a", lastRun: "a") == $0 || SelfTest.startLabel(selected: "a", lastRun: nil) == $0 })
        keys.formUnion(SelfTest.titles.values)
        return (keys, interpolated)
    }

    static func specifiers(_ s: String) -> [String] {
        // %@ %d %ld %.1f %.0f %1$@ …, in order of their argument
        var out: [(Int, String)] = [], i = s.startIndex, n = 0
        while i < s.endIndex {
            if s[i] == "%" {
                var j = s.index(after: i)
                if j < s.endIndex && s[j] == "%" { i = s.index(after: j); continue }
                var spec = ""
                while j < s.endIndex && !"@dfsuxlc".contains(s[j]) { spec.append(s[j]); j = s.index(after: j) }
                while j < s.endIndex && s[j] == "l" { j = s.index(after: j) }
                if j < s.endIndex {
                    let kind = s[j] == "@" ? "@" : (s[j] == "f" ? "f" : "d")
                    var pos = n
                    if let dollar = spec.firstIndex(of: "$"), let p = Int(spec[..<dollar]) { pos = p - 1 }
                    out.append((pos, kind)); n += 1
                    i = s.index(after: j); continue
                }
            }
            i = s.index(after: i)
        }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func completenessTests() {
        let (keys, interpolated) = usedKeys()
        check(keys.count > 400, "the keys found in the code: \(keys.count)")
        check(interpolated.isEmpty, "no key passed to L is built by interpolation: \(interpolated)")
        let missing = keys.filter { L10n.zh[$0] == nil }.sorted()
        check(missing.isEmpty, "every key the code passes to L has its Chinese: \(missing)")
        let empty = L10n.zh.filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.key)
        check(empty.isEmpty, "no empty Chinese: \(empty)")
        let mismatched = L10n.zh.filter { specifiers($0.key) != specifiers($0.value) }.map(\.key).sorted()
        check(mismatched.isEmpty, "the Chinese takes the same arguments as the English: \(mismatched)")
        check(specifiers("%1$@，%2$@") == ["@", "@"] && specifiers("%d 秒 %.1f GB %%") == ["d", "f"] && specifiers("%2$@ %1$d") == ["d", "@"], "(the specifier reader)")
        // the reader itself, on the shapes the code uses
        let probe = firstArgumentLiterals(#"L("a", lang: l) + L(x ? "b" : "c", lang: l) + L("d %@", n, lang: l) + L("\(v)", lang: l) + xL("e")"#, call: "L(")
        check(probe.keys == ["a", "b", "c", "d %@"] && probe.interpolated == 1, "(the key reader: \(probe))")
    }

    // MARK: one language per screen

    /// Words that stay as they are in Chinese text: names (of the product, its parts, services, apps), units, file
    /// types, the slash command, and the debug panel's process id. Paths and file names are skipped as a whole.
    static let keptInChinese: Set<String> = ["DeskMind", "Brain", "Hands", "API", "DeepSeek", "OpenRouter", "GitHub", "Mac", "macOS",
                                              "Finder", "Safari", "Python", "GB", "MB", "ms", "HTTP", "csv", "zip", "cua", "pid", "Tab"]

    static func unmixedTests() {
        var mixed: [String] = []
        for (k, v) in L10n.zh {
            var word = ""
            let words = v.replacingOccurrences(of: #"[~/A-Za-z0-9_-]*[./][A-Za-z0-9_./-]+"#, with: " ", options: .regularExpression)
            for ch in words + " " {
                if ch.isASCII && ch.isLetter { word.append(ch); continue }
                if word.count >= 2 && !keptInChinese.contains(word) { mixed.append("\(word) in 「\(v)」") }
                word = ""
            }
            _ = k
        }
        check(mixed.isEmpty, "no English word in the Chinese but names, units and commands: \(mixed.sorted())")
        // the English: no Chinese, except names that are Chinese (an example task's song and singer)
        let cjk = L10n.zh.keys.filter { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
        check(cjk.allSatisfy { $0.hasPrefix("In NetEase Cloud Music") || $0.hasPrefix("Open NetEase Cloud Music") }, "no Chinese in the English but names: \(cjk.sorted())")
    }

    // MARK: no words on screen outside L

    /// Literals that are names and read the same in both languages.
    static let names: Set<String> = ["DeskMind", "DeskMind Hands", "GitHub", "English", "中文"]

    static func bypassTests() {
        let calls = ["Text(", "Button(", "Label(", "Toggle(", "Menu(", "Picker(", "TextField(", "SecureField(", "Section(", ".help(",
                     ".accessibilityLabel(", ".accessibilityHint(", ".accessibilityValue(", ".alert(", ".navigationTitle(",
                     ".confirmationDialog(", "setAccessibilityLabel(", "labelWithString:", "NSMenuItem(title:", "Text(verbatim:"]
        var found: [String] = []
        let views = appSources().filter { $0.hasPrefix("Main/") || $0 == "Helper/LiveCard.swift" }
        for f in views {
            let c = code(f)
            for call in calls {
                let s = Array(c), n = Array(call)
                var i = 0
                while i + n.count <= s.count {
                    guard Array(s[i..<i + n.count]) == n else { i += 1; continue }
                    var j = i + n.count
                    while j < s.count && s[j] == " " { j += 1 }
                    if j < s.count && s[j] == "\"" {
                        let (t, end) = literal(s, at: j)
                        let text = t ?? String(s[j..<min(end, s.count)])
                        // its own words: letters outside interpolations
                        let own = text.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "", options: .regularExpression)
                        if own.contains(where: \.isLetter) && !names.contains(text) {
                            let lineNo = s[0..<j].filter { $0 == "\n" }.count + 1
                            found.append("\(f):\(lineNo) \(call)\"\(text)\"")
                        }
                        i = end; continue
                    }
                    i = j
                }
            }
            // text set on AppKit views
            for (i, l) in c.components(separatedBy: "\n").enumerated() {
                for marker in ["stringValue = \"", "toolTip = \"", "title = \""] where l.contains(marker) {
                    let after = l.components(separatedBy: marker)[1]
                    if after.prefix { $0 != "\"" }.contains(where: \.isLetter) { found.append("\(f):\(i + 1) \(marker)…") }
                }
            }
        }
        check(found.isEmpty, "no words on screen outside L (numbers, symbols and names apart): \(found)")
    }

    // MARK: contrast, in both appearances

    static func contrastTests() {
        for (fg, bg) in ShellPalette.textOn {
            let r = ShellPalette.contrast(fg, bg)
            check(r >= 4.5, String(format: "text #%06X on #%06X: %.2f:1 (at least 4.5)", fg, bg, r))
        }
        check(ShellPalette.secondary == 0x5E675F && ShellPalette.orangeText == 0xA3402A, "secondary #5E675F, orange text #A3402A (handoff §3.10)")
        // the tinted backgrounds, as drawn
        check(ShellPalette.panel == 0xFBF9F4 && ShellPalette.panelSelected == 0xE9EAE3 && ShellPalette.banner == 0xF0E1D8 && ShellPalette.problem == 0xF1E6DD,
              String(format: "the solid tints: panel #%06X, selected #%06X, banner #%06X, problem #%06X",
                     ShellPalette.panel, ShellPalette.panelSelected, ShellPalette.banner, ShellPalette.problem))
        check(ShellPalette.blend(0xFFFFFF, 0.5, over: 0x000000) == 0x808080 && ShellPalette.blend(0x123456, 1, over: 0xABCDEF) == 0x123456, "(blend)")
        // why solid and light: the old translucent panel over the sidebar's Dark Mode material put secondary text
        // under 2.5:1
        let darkMaterial: UInt32 = 0x1E1E1E
        check(ShellPalette.contrast(ShellPalette.secondary, ShellPalette.blend(ShellPalette.card, 0.6, over: darkMaterial)) < 4.5,
              "(a translucent panel over Dark Mode's material fails: why the tints are solid)")
        let brand = source("Main/Brand.swift")
        check(brand.contains("static let dot = Color(hex: 0xC95536)") && brand.contains("static let mist = Color(hex: 0xB2BBAF)"), "the palette's orange and mist are Brand's")
        let split = code("Main/MainSplitView.swift")
        for c in ["panel", "panelSelected", "banner", "problem"] {
            check(split.contains("static let \(c) = Color(hex: ShellPalette.\(c))"), "the window's \(c) is the palette's")
        }
        // the window and its sheet are light in both appearances: the system's own controls (fields, lists) would
        // otherwise draw Dark Mode's light text on the light palette
        check(split.components(separatedBy: ".preferredColorScheme(.light)").count - 1 >= 2, "the window and its settings sheet: light in both appearances")
        // no translucent fill behind text in the window's views: what is checked is what is on screen
        let views = ShellTests.windowViewFiles().filter { ["Main/MainSplitView.swift", "Main/CardViews.swift", "Main/TaskViews.swift"].contains($0.name) }
        var tinted: [String] = []
        for v in views {
            for (i, l) in v.code.components(separatedBy: "\n").enumerated() where l.contains(".background(") || l.contains(".fill(") {
                if l.range(of: #"(Brand\.(card|mist|paper|dot)\.opacity\()"#, options: .regularExpression) != nil && !l.contains("strokeBorder") && !l.contains(".stroke(") {
                    tinted.append("\(v.name):\(i + 1)")
                }
            }
        }
        check(views.count == 3 && tinted.isEmpty, "no translucent background behind the window's text: \(tinted)")
    }
}
