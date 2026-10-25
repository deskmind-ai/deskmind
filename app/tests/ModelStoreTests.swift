// The model keys in one place (A11, Shared/ModelStore.swift): the move from models.env into the helper's keychain
// item, its table (the last written wins), a crash at any point, changes beside reads, and over any sequence of
// moves, changes and failures, the settings in use are the last ones successfully set. A fake keychain and file
// system with a clock; nothing touches the user's.
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
        DecisionTests.group("keys.concurrent"); concurrentTests()
        DecisionTests.group("keys.crash"); crashTests()
    }

    /// A clock the fakes stamp their writes with (each write a few seconds after the last).
    final class Clock { var t = Date(timeIntervalSince1970: 1_000_000); func tick() -> Date { t += 5; return t } }

    /// A keychain with failures to order.
    final class FakeKeychain: ModelStore.Keychain {
        let clock: Clock
        var item: String?, at: Date?
        var failRead = false, failWrite = false, lieOnReadBack = false
        init(_ c: Clock) { clock = c }
        func read() -> ModelStore.Read {
            if failRead { return .failed }
            if lieOnReadBack, let i = item { return .value(i + "#") }
            return item.map { .value($0) } ?? .none
        }
        func modified() -> Date? { at }
        func write(_ text: String) -> Bool { if failWrite { return false }; item = text; at = clock.tick(); return true }
        /// (an unreadable item replaced: readable again, this one's)
        func replace(_ text: String) -> Bool { if failWrite { return false }; failRead = false; return write(text) }
    }
    /// A file system of named texts with their dates, with failures to order.
    final class FakeFiles: ModelStore.Files {
        let clock: Clock
        var files: [String: (text: String, at: Date)] = [:]
        var failRemove = false
        init(_ c: Clock) { clock = c }
        func put(_ u: URL, _ text: String) { files[u.path] = (text, clock.tick()) }
        func read(_ u: URL) -> String? { files[u.path]?.text }
        func modified(_ u: URL) -> Date? { files[u.path]?.at }
        func remove(_ u: URL) -> Bool { if failRemove && files[u.path] != nil { return false }; files[u.path] = nil; return true }
    }
    static let file = URL(fileURLWithPath: "/fake/models.env")

    static func tableTests() {
        typealias S = ModelStore
        let a = "DEEPSEEK_API_KEY=sk-aaaa1111\n", b = "DEEPSEEK_API_KEY=sk-bbbb2222\n"
        // (file, keychain read, the file newer) -> plan
        let rows: [(String, String?, S.Read, Bool, S.Plan)] = [
            ("file only", a, .none, true, S.Plan(write: a, removeFile: true, use: a)),
            ("keychain only", nil, .value(a), true, S.Plan(write: nil, removeFile: false, use: a)),
            ("both, the same", a, .value(a), true, S.Plan(write: nil, removeFile: true, use: a)),
            ("both, the same pairs written differently", "# keys\nDEEPSEEK_API_KEY=\"sk-aaaa1111\"\n", .value(a), true, S.Plan(write: nil, removeFile: true, use: a)),
            ("both, different, the file newer (a downgrade, a hand edit)", b, .value(a), true, S.Plan(write: b, removeFile: true, use: b)),
            ("both, different, the keychain newer (a keys.set whose removal failed)", b, .value(a), false, S.Plan(write: nil, removeFile: true, use: a)),
            ("neither", nil, .none, true, S.Plan(write: nil, removeFile: false, use: "")),
            ("the keychain read fails, a newer file", a, .failed, true, S.Plan(write: nil, removeFile: false, use: a)),
            ("the keychain read fails, an older file: unknown, never the old settings", a, .failed, false, S.Plan(write: nil, removeFile: false, use: nil)),
            ("the keychain read fails, no file: unknown, never none", nil, .failed, true, S.Plan(write: nil, removeFile: false, use: nil)),
        ]
        for (name, f, k, newer, want) in rows { check(S.plan(file: f, keychain: k, fileNewer: newer) == want, "\(name): \(S.plan(file: f, keychain: k, fileNewer: newer))") }
        // on the fakes: the file goes only after the keychain read back what was written
        let c = Clock(), kc = FakeKeychain(c), fs = FakeFiles(c)
        fs.put(file, a)
        kc.failWrite = true
        check(S.current(keychain: kc, file: file, files: fs) == a && fs.read(file) != nil, "the write fails: the file kept, its keys used")
        kc.failWrite = false; kc.lieOnReadBack = true
        check(S.current(keychain: kc, file: file, files: fs) == a && fs.read(file) != nil, "the read back differs: the file kept")
        kc.lieOnReadBack = false
        _ = kc.write("")                      // (the item written before the file: the file is newer)
        fs.put(file, a)
        check(S.current(keychain: kc, file: file, files: fs) == a && fs.read(file) == nil && kc.item == a, "moved in, then removed")
        // keys.set: a merge; written and read back, then the file removed
        fs.put(file, b)
        kc.failWrite = true
        check(S.set(["OPENROUTER_API_KEY": "or-9999"], keychain: kc, file: file, files: fs) == .failed("keychain") && fs.read(file) == b,
              "keys.set fails: the file as it was")
        kc.failWrite = false
        if case .set(let t) = S.set(["OPENROUTER_API_KEY": "or-9999"], keychain: kc, file: file, files: fs) {
            let env = S.parse(t)
            check(env["OPENROUTER_API_KEY"] == "or-9999" && env["DEEPSEEK_API_KEY"] == "sk-bbbb2222" && fs.read(file) == nil,
                  "keys.set merges (the file's key kept, the new one added), the file gone: \(env.keys.sorted())")
        } else { check(false, "keys.set") }
        // the file cannot be retired: the change undone, refused -- never a newer item beside an older file
        fs.put(file, b)
        _ = S.current(keychain: kc, file: file, files: fs)
        fs.put(file, b); fs.failRemove = true
        let before = kc.item
        check(S.set(["OPENROUTER_API_KEY": "or-7777"], keychain: kc, file: file, files: fs) == .failed("old_file") && kc.item == before,
              "the file cannot be retired: the change undone, refused")
        fs.failRemove = false
        if case .set(let t) = S.set([:], unset: ["OPENROUTER_API_KEY"], keychain: kc, file: file, files: fs) {
            check(S.parse(t).keys.sorted() == ["DEEPSEEK_API_KEY"], "unset removes that name only")
        } else { check(false, "unset") }
        kc.failRead = true
        check(S.set(["X_API_KEY": "1"], keychain: kc, file: file, files: fs) == .failed("unreadable"), "unreadable: nothing set")
        // the user's own save over an item the helper cannot read: replaced, readable, in use
        if case .set(let t) = S.set(["DEEPSEEK_API_KEY": "sk-9999"], replace: true, keychain: kc, file: file, files: fs) {
            check(S.parse(t)["DEEPSEEK_API_KEY"] == "sk-9999" && S.current(keychain: kc, file: file, files: fs) == t, "replace: the new key, readable, in use")
        } else { check(false, "replace") }
    }

    /// Over any sequence of the helper's reads, keys.set, a hand-written or downgraded file, and injected failures
    /// (reads, writes, removals), the settings in use are the last ones successfully set -- by the file or keys.set.
    static func sequenceTests() {
        typealias S = ModelStore
        var g = CardStoreTests.RNG(x: 99)
        for seed in 0..<400 {
            let c = Clock(), kc = FakeKeychain(c), fs = FakeFiles(c)
            var last: [String: String]? = [:]          // the oracle: the last settings successfully set
            for step in 0..<25 {
                kc.failRead = g.next(8) == 0; kc.failWrite = g.next(6) == 0
                fs.failRemove = g.next(4) == 0
                switch g.next(4) {
                case 0:
                    // a downgrade or a hand edit writes the file: newer than anything before it
                    let v = ["DEEPSEEK_API_KEY": "sk-\(seed)-\(step)"]
                    fs.put(file, ModelKeys.fingerprint(v)); last = v
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

    /// (#127 review) The helper killed at any point of a change, or of a read's move: the next read uses the newest.
    static func crashTests() {
        typealias S = ModelStore
        let old = "DEEPSEEK_API_KEY=sk-file1111\n"
        // killed after keys.set's write, before the file was removed: the item is newer -- it wins, the file goes
        do {
            let c = Clock(), kc = FakeKeychain(c), fs = FakeFiles(c)
            fs.put(file, old)
            _ = kc.write(ModelKeys.fingerprint(["DEEPSEEK_API_KEY": "sk-file1111", "OPENROUTER_API_KEY": "or-2222"]))
            let used = S.current(keychain: kc, file: file, files: fs).map(S.parse)
            check(used?["OPENROUTER_API_KEY"] == "or-2222" && fs.read(file) == nil, "killed after the write: the change kept, the old file gone")
        }
        // killed before the write: the file as it was, newer than the item -- it wins, moved in
        do {
            let c = Clock(), kc = FakeKeychain(c), fs = FakeFiles(c)
            _ = kc.write("DEEPSEEK_API_KEY=sk-kc0000\n")
            fs.put(file, old)
            check(S.current(keychain: kc, file: file, files: fs).map(S.parse)?["DEEPSEEK_API_KEY"] == "sk-file1111" && kc.item == old,
                  "killed before the write: the file's settings, moved in")
        }
        // (#127 Codex) a file written within the second after the item, with a new key: it may be the newer -- it wins,
        // moved in, never retired unread
        do {
            let c = Clock(), kc = FakeKeychain(c), fs = FakeFiles(c)
            _ = kc.write("DEEPSEEK_API_KEY=sk-old0000\n")
            fs.files[file.path] = ("DEEPSEEK_API_KEY=sk-new1111\n", kc.at!.addingTimeInterval(0.5))
            check(S.current(keychain: kc, file: file, files: fs).map(S.parse)?["DEEPSEEK_API_KEY"] == "sk-new1111" && kc.item == "DEEPSEEK_API_KEY=sk-new1111\n",
                  "a file half a second after the item: the newer, moved in")
            _ = kc.write("DEEPSEEK_API_KEY=sk-kc2222\n")
            fs.files[file.path] = ("DEEPSEEK_API_KEY=sk-file3333\n", kc.at!.addingTimeInterval(-0.5))
            check(S.current(keychain: kc, file: file, files: fs).map(S.parse)?["DEEPSEEK_API_KEY"] == "sk-file3333", "half a second before: ambiguous -- the file")
        }
        // no dates known (an item without one): the file is taken as newer -- only an older version or the user wrote it
        check(S.plan(file: old, keychain: .value("DEEPSEEK_API_KEY=x\n")) == S.Plan(write: old, removeFile: true, use: old), "no dates: the file")
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

    /// The main app reads no key: no keychain query, no models.env read in Main/ or Shared/ (the store aside).
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
        // the e2e helpers never use the user's Application Support or keychain (#127 review)
        for f in ["tests/e2e/SessionE2E.swift", "tests/e2e/HelperE2E.swift", "tests/e2e/OpRunE2E.swift"] {
            let c = (try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) ?? ""
            check(c.contains("DeskMindIPC.supportOverride = ") && !c.contains("DeskMindIPC.supportOverride = nil"), "\(f): its own support folder, always")
        }
    }

    /// (#127 review) A keys.set and the reads beside it (sessions.list, keys.status: each connection on its own
    /// thread): a change reported as made is always the one in use after.
    static func concurrentTests() {
        typealias S = ModelStore
        final class SlowKeychain: ModelStore.Keychain {
            let l = NSLock(); var v: String?, at: Date?
            func read() -> ModelStore.Read { usleep(UInt32.random(in: 0...200)); l.lock(); defer { l.unlock() }; return v.map { .value($0) } ?? .none }
            func modified() -> Date? { l.lock(); defer { l.unlock() }; return at }
            func write(_ t: String) -> Bool { usleep(UInt32.random(in: 0...200)); l.lock(); v = t; at = Date(); l.unlock(); return true }
            func replace(_ t: String) -> Bool { write(t) }
        }
        final class LockedFiles: ModelStore.Files {
            let l = NSLock(); var m: [String: (String, Date)] = [:]
            func read(_ u: URL) -> String? { l.lock(); defer { l.unlock() }; return m[u.path]?.0 }
            func modified(_ u: URL) -> Date? { l.lock(); defer { l.unlock() }; return m[u.path]?.1 }
            func remove(_ u: URL) -> Bool { l.lock(); m[u.path] = nil; l.unlock(); return true }
        }
        var lost = 0, ok = 0
        for _ in 0..<120 {
            let kc = SlowKeychain(), fs = LockedFiles()
            fs.m[file.path] = ("DEEPSEEK_API_KEY=sk-old0000\n", Date())
            let g = DispatchGroup()
            let box = NSLock(); var r1: S.SetResult?
            DispatchQueue.global().async(group: g) { let r = S.set(["DEEPSEEK_API_KEY": "sk-new1111"], keychain: kc, file: file, files: fs); box.lock(); r1 = r; box.unlock() }
            for _ in 0..<3 { DispatchQueue.global().async(group: g) { _ = S.current(keychain: kc, file: file, files: fs) } }
            g.wait()
            if case .set? = r1 {
                ok += 1
                if S.current(keychain: kc, file: file, files: fs).map(S.parse)?["DEEPSEEK_API_KEY"] != "sk-new1111" { lost += 1 }
            }
        }
        check(ok > 100 && lost == 0, "a change made beside reads: never lost (\(lost) of \(ok))")
    }
}
