// Where the model services' keys live (A11, decision 6): one item in the keychain, the helper's -- it starts the session
// processes, whose environment carries them. The main app writes a new key through the helper (`keys.set`) and is told
// only whether one is set, each key's last 4 characters, the settings that are no secret, and the digest; it never
// reads a value back. The old Application Support/DeskMind/models.env is moved in once and removed, only after the
// keychain read back what it held.
//
// | state                                   | keychain after          | models.env after                | used               |
// |-----------------------------------------|-------------------------|---------------------------------|--------------------|
// | file only                               | the file's              | removed, after the read back    | the file's         |
// | keychain only                           | as it was               | --                              | the keychain's     |
// | both, the same                          | as it was               | removed                         | the keychain's     |
// | both, different                         | the file's (Q4)         | removed, after the read back    | the file's         |
// | neither                                 | --                      | --                              | none: not set      |
// | the keychain write (or read back) fails | as it was               | kept (tried again next read)    | the file's         |
// | the keychain read fails (not "none")    | as it was               | kept                            | the file's, else   |
// |                                         |                         |                                 |   unknown          |
//
// "Both, different" can only be a downgrade or a hand edit -- both newer than the keychain item -- because a key set
// from the app (keys.set) moves models.env aside before it writes, and puts it back when the write fails: the file is
// never older than the keychain item (fable 10-25). Over any sequence of moves, writes and failures, the settings in
// use are the last ones successfully set, by the file or by keys.set (ModelStoreTests).

import Foundation

enum ModelStore {
    /// What the keychain said.
    enum Read: Equatable { case value(String), none, failed }

    /// The keychain as one item (the helper's; a test's own in tests).
    protocol Keychain: AnyObject {
        func read() -> Read
        /// True: written.
        func write(_ text: String) -> Bool
    }

    /// What one read decides: what to write, whether the file goes, which text the processes use.
    struct Plan: Equatable {
        var write: String?
        /// Remove models.env -- only once the keychain read back `write` (or already held the file's text).
        var removeFile: Bool
        /// The settings in use (nil: unknown -- the keychain could not be read and there is no file).
        var use: String?
    }

    /// The plan from the file's text (nil: no file) and the keychain's read.
    static func plan(file: String?, keychain: Read) -> Plan {
        switch (file, keychain) {
        case (nil, .value(let k)): return Plan(write: nil, removeFile: false, use: k)
        case (nil, .none): return Plan(write: nil, removeFile: false, use: "")
        case (nil, .failed): return Plan(write: nil, removeFile: false, use: nil)
        case (let f?, .value(let k)) where same(f, k): return Plan(write: nil, removeFile: true, use: k)
        case (let f?, .value), (let f?, .none): return Plan(write: f, removeFile: true, use: f)
        case (let f?, .failed): return Plan(write: nil, removeFile: false, use: f)
        }
    }

    /// The same settings (the same pairs, whatever their order, comments and quoting).
    static func same(_ a: String, _ b: String) -> Bool { parse(a) == parse(b) }

    /// One read of the settings, the migration done on the way: the text the processes use (nil: unknown). `file`:
    /// models.env's place; the file goes only after the keychain read back what was written.
    static func current(keychain: Keychain, file: URL, files: Files = Disk()) -> String? {
        let fileText = files.read(file)
        let read = keychain.read()
        let p = plan(file: fileText, keychain: read)
        var remove = p.removeFile
        if let w = p.write {
            remove = keychain.write(w) && keychain.read() == .value(w)
        }
        if remove, fileText != nil { _ = files.remove(file) }
        // (a keys.set cut short after its write: its moved-aside copy goes once the keychain holds the settings)
        if case .value = read { _ = files.remove(aside(file)) }
        return p.use
    }

    enum SetResult: Equatable { case set(String), failed(String) }

    /// A change from the app, merged into the settings now (`set`: these pairs; `unset`: these names) -- keys the app
    /// never shows are kept. models.env is moved aside first and put back if the keychain write (or its read back)
    /// fails; one that cannot be moved aside fails the change, nothing written.
    static func set(_ pairs: [String: String], unset: [String] = [], keychain: Keychain, file: URL, files: Files = Disk()) -> SetResult {
        guard let now = current(keychain: keychain, file: file, files: files) else { return .failed("unreadable") }
        var env = parse(now)
        for (k, v) in pairs where validName(k) && !v.isEmpty { env[k] = v }
        for k in unset { env[k] = nil }
        let text = ModelKeys.fingerprint(env)
        let had = files.exists(file)
        if had, !files.move(file, to: aside(file)) { return .failed("old_file") }      // 「旧的 models.env 删不掉」
        guard keychain.write(text), keychain.read() == .value(text) else {
            if had { _ = files.move(aside(file), to: file) }
            return .failed("keychain")
        }
        if had { _ = files.remove(aside(file)) }
        return .set(text)
    }

    static func aside(_ file: URL) -> URL { file.appendingPathExtension("old") }

    /// The file system as these moves see it (a test's own, with failures).
    protocol Files {
        func read(_ u: URL) -> String?
        func exists(_ u: URL) -> Bool
        func remove(_ u: URL) -> Bool
        func move(_ a: URL, to b: URL) -> Bool
    }
    struct Disk: Files {
        func read(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
        func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }
        func remove(_ u: URL) -> Bool {
            guard exists(u) else { return true }
            return (try? FileManager.default.removeItem(at: u)) != nil
        }
        func move(_ a: URL, to b: URL) -> Bool {
            _ = remove(b)
            return (try? FileManager.default.moveItem(at: a, to: b)) != nil
        }
    }

    // MARK: what the app is told

    /// The names whose values are secrets: only their last 4 characters ever leave the helper.
    static func secret(_ name: String) -> Bool { name.hasSuffix("_KEY") || name.hasSuffix("_TOKEN") || name.hasSuffix("_SECRET") }

    /// keys.status: set or not, each key by its last 4, the settings that are no secret, the digest. Nothing else.
    static func status(_ text: String?) -> [String: Any] {
        guard let text else { return ["ok": true, "readable": false] }
        let env = parse(text)
        var keys: [String: String] = [:], settings: [String: String] = [:]
        for (k, v) in env {
            if secret(k) { keys[k] = String(v.suffix(4)) } else { settings[k] = v }
        }
        return ["ok": true, "readable": true, "configured": !keys.isEmpty, "keys": keys, "settings": settings,
                "digest": ModelKeys.digest(env: env)]
    }

    // MARK: the text

    /// KEY=VALUE lines (comments, blank lines and quotes as models.env had them).
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            if !k.isEmpty { out[k] = v }
        }
        return out
    }

    static func validName(_ k: String) -> Bool { k.range(of: "^[A-Z][A-Z0-9_]*$", options: .regularExpression) != nil }
}
