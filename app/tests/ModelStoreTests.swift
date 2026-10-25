// The model keys in one place (A11, Shared/ModelStore.swift): the move from models.env into the helper's keychain
// item, its table, and over any sequence of moves, changes and failures, the settings in use are the last ones
// successfully set. A fake keychain and file system; nothing touches the user's.
import Foundation

enum ModelStoreTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "keys: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("keys.table"); tableTests()
        DecisionTests.group("keys.sequences"); sequenceTests()
        DecisionTests.group("keys.status"); statusTests()
        DecisionTests.group("keys.app"); appTests()
    }

    /// A keychain with failures to order.
    final class FakeKeychain: ModelStore.Keychain {
        var item: String?
        var failRead = false, failWrite = false, lieOnReadBack = false
        func read() -> ModelStore.Read {
            if failRead { return .failed }
            if lieOnReadBack, let i = item { return .value(i + "#") }
            return item.map { .value($0) } ?? .none
        }
        func write(_ text: String) -> Bool { if failWrite { return false }; item = text; return true }
    }
    /// A file system of named texts, with failures to order.
    final class FakeFiles: ModelStore.Files {
        var files: [String: String] = [:]
        var failRemove = false, failMove = false
        func read(_ u: URL) -> String? { files[u.path] }
        func exists(_ u: URL) -> Bool { files[u.path] != nil }
        func remove(_ u: URL) -> Bool { if failRemove && files[u.path] != nil { return false }; files[u.path] = nil; return true }
        func move(_ a: URL, to b: URL) -> Bool {
            if failMove { return false }
            guard let t = files[a.path] else { return false }
            files[b.path] = t; files[a.path] = nil; return true
        }
    }
    static let file = URL(fileURLWithPath: "/fake/models.env")

    static func tableTests() {
        typealias S = ModelStore
        let a = "DEEPSEEK_API_KEY=sk-aaaa1111\n", b = "DEEPSEEK_API_KEY=sk-bbbb2222\n"
        // (file, keychain read) -> plan
        let rows: [(String, String?, S.Read, S.Plan)] = [
            ("file only", a, .none, S.Plan(write: a, removeFile: true, use: a)),
            ("keychain only", nil, .value(a), S.Plan(write: nil, removeFile: false, use: a)),
            ("both, the same", a, .value(a), S.Plan(write: nil, removeFile: true, use: a)),
            ("both, the same pairs written differently", "# keys\nDEEPSEEK_API_KEY=\"sk-aaaa1111\"\n", .value(a), S.Plan(write: nil, removeFile: true, use: a)),
            ("both, different: the file (newer: a downgrade, a hand edit)", b, .value(a), S.Plan(write: b, removeFile: true, use: b)),
            ("neither", nil, .none, S.Plan(write: nil, removeFile: false, use: "")),
            ("the keychain read fails, a file", a, .failed, S.Plan(write: nil, removeFile: false, use: a)),
            ("the keychain read fails, no file: unknown, never none", nil, .failed, S.Plan(write: nil, removeFile: false, use: nil)),
        ]
        for (name, f, k, want) in rows { check(S.plan(file: f, keychain: k) == want, "\(name): \(S.plan(file: f, keychain: k))") }
        // on the fakes: the file goes only after the keychain read back what was written
        let kc = FakeKeychain(), fs = FakeFiles()
        fs.files[file.path] = a
        kc.failWrite = true
        check(S.current(keychain: kc, file: file, files: fs) == a && fs.exists(file), "the write fails: the file kept, its keys used")
        kc.failWrite = false; kc.lieOnReadBack = true
        check(S.current(keychain: kc, file: file, files: fs) == a && fs.exists(file), "the read back differs: the file kept")
        kc.lieOnReadBack = false
        check(S.current(keychain: kc, file: file, files: fs) == a && !fs.exists(file) && kc.item == a, "moved in, then removed")
        // keys.set: a merge; the file moved aside first, put back when the write fails
        fs.files[file.path] = b
        kc.failWrite = true
        check(S.set(["OPENROUTER_API_KEY": "or-9999"], keychain: kc, file: file, files: fs) == .failed("keychain") && fs.files[file.path] == b,
              "keys.set fails: the file put back as it was")
        kc.failWrite = false
        // (a file the read cannot remove, and that cannot be moved aside either: keys.set writes nothing)
        fs.failRemove = true; fs.failMove = true
        let before = S.current(keychain: kc, file: file, files: fs)
        check(S.set(["OPENROUTER_API_KEY": "or-9999"], keychain: kc, file: file, files: fs) == .failed("old_file") && kc.item == before && fs.files[file.path] == b,
              "the old file cannot be moved aside: nothing written")
        fs.failRemove = false; fs.failMove = false
        if case .set(let t) = S.set(["OPENROUTER_API_KEY": "or-9999"], keychain: kc, file: file, files: fs) {
            let env = S.parse(t)
            check(env["OPENROUTER_API_KEY"] == "or-9999" && env["DEEPSEEK_API_KEY"] == "sk-bbbb2222" && !fs.exists(file) && !fs.exists(S.aside(file)),
                  "keys.set merges (the file's key kept, the new one added), the file gone: \(env.keys.sorted())")
        } else { check(false, "keys.set") }
        if case .set(let t) = S.set([:], unset: ["OPENROUTER_API_KEY"], keychain: kc, file: file, files: fs) {
            check(S.parse(t).keys.sorted() == ["DEEPSEEK_API_KEY"], "unset removes that name only")
        } else { check(false, "unset") }
        kc.failRead = true
        check(S.set(["X_API_KEY": "1"], keychain: kc, file: file, files: fs) == .failed("unreadable"), "unreadable: nothing set")
    }

    /// Over any sequence of the helper's reads (migrations), keys.set, a hand-written or downgraded file, and injected
    /// failures, the settings in use are the last ones successfully set -- by the file or by keys.set.
    static func sequenceTests() {
        typealias S = ModelStore
        var g = CardStoreTests.RNG(x: 99)
        for seed in 0..<400 {
            let kc = FakeKeychain(), fs = FakeFiles()
            var last: [String: String]? = [:]          // the oracle: the last settings successfully set (nil: none yet known)
            for step in 0..<25 {
                kc.failRead = g.next(8) == 0; kc.failWrite = g.next(6) == 0
                fs.failRemove = g.next(8) == 0; fs.failMove = g.next(8) == 0
                switch g.next(4) {
                case 0:
                    // a downgrade or a hand edit writes the file: newer than anything before it
                    let v = ["DEEPSEEK_API_KEY": "sk-\(seed)-\(step)"]
                    fs.files[file.path] = ModelKeys.fingerprint(v); last = v
                case 1:
                    let v = "or-\(seed)-\(step)"
                    if case .set = S.set(["OPENROUTER_API_KEY": v], keychain: kc, file: file, files: fs) {
                        var e = last ?? [:]; e["OPENROUTER_API_KEY"] = v; last = e
                    }
                default:
                    let used = S.current(keychain: kc, file: file, files: fs).map(S.parse)
                    if let used, let want = last, used != want {
                        check(false, "seed \(seed) step \(step): in use \(used) vs last set \(want)"); return
                    }
                }
            }
        }
    }

    static func statusTests() {
        let st = ModelStore.status("DEEPSEEK_API_KEY=sk-abcdef1234\nCUSTOM_URL=https://x.example/v1\nCUSTOM_MODEL=m1\n")
        let keys = st["keys"] as? [String: String], settings = st["settings"] as? [String: String]
        check(keys == ["DEEPSEEK_API_KEY": "1234"] && settings == ["CUSTOM_URL": "https://x.example/v1", "CUSTOM_MODEL": "m1"]
              && st["configured"] as? Bool == true && st["readable"] as? Bool == true, "status: the key by its last 4, the rest as is")
        let all = "\(st)"
        check(!all.contains("sk-abcdef"), "status never carries a key")
        check(ModelStore.status(nil)["readable"] as? Bool == false && ModelStore.status(nil)["configured"] == nil, "unreadable: said so, never 'not set'")
        check(ModelStore.status("")["configured"] as? Bool == false, "none set")
        // the digest is over everything kept: a change of any key changes it (sessions.list's restart path, #107)
        let d1 = ModelStore.status("DEEPSEEK_API_KEY=a\n")["digest"] as? String, d2 = ModelStore.status("DEEPSEEK_API_KEY=b\n")["digest"] as? String
        check(d1 != nil && d1 != d2 && d1 == ModelKeys.digest(env: ["DEEPSEEK_API_KEY": "a"]), "the digest: the helper's ModelKeys digest of what it keeps")
    }

    /// The main app reads no key: no keychain query, no models.env read in Main/ or Shared/ (the store's own move
    /// aside).
    static func appTests() {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fm = FileManager.default
        for sub in ["Main", "Shared"] {
            for f in (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent(sub).path)) ?? [] where f.hasSuffix(".swift") {
                let c = ((try? String(contentsOf: dir.appendingPathComponent("\(sub)/\(f)"), encoding: .utf8)) ?? "")
                    .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
                if c.contains("SecItemCopyMatching") { check(false, "\(sub)/\(f) reads the keychain") }
                if f != "ModelStore.swift" && c.contains("\"models.env\"") { check(false, "\(sub)/\(f) names models.env") }
            }
        }
    }
}
