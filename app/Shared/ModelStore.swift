// Where the model services' keys live (A11, decision 6): one item in the keychain, the helper's -- it starts the session
// processes, whose environment carries them. The main app writes a new key through the helper (`keys.set`) and is told
// only whether one is set, each key's last 4 characters, the settings that are no secret, and the digest; it never
// reads a value back. The old Application Support/DeskMind/models.env is moved in and removed.
//
// The one fact that decides between the two places: which was written last -- the keychain item's modification date
// against the file's (#127 review: a moved-aside copy and a marker went wrong a third way; the fact is the dates).
// A file written after the item (an older version after a downgrade, a hand edit) is the newest settings; one plainly
// written before it (a crash between keys.set's write and its removal) is not; within a second either way it is taken
// as the newer (ambiguity never retires a credential). A file whose settings the keychain now holds is unlinked (no
// plaintext key stays on disk); one that says something else goes to the Trash. A crash anywhere leaves one of these
// states:
//
// | state                                   | keychain after          | models.env after                | used               |
// |-----------------------------------------|-------------------------|---------------------------------|--------------------|
// | file only                               | the file's              | removed, after the read back    | the file's         |
// | keychain only                           | as it was               | --                              | the keychain's     |
// | both, the same                          | as it was               | removed                         | the keychain's     |
// | both, different, the file newer         | the file's              | removed, after the read back    | the file's         |
// | both, different, the keychain newer     | as it was               | removed                         | the keychain's     |
// | neither                                 | --                      | --                              | none: not set      |
// | the keychain write (or read back) fails | as it was               | kept (tried again next read)    | the file's         |
// | the keychain read fails (not "none")    | as it was               | kept                            | the file's if it   |
// |                                         |                         |                                 |   is the newer,    |
// |                                         |                         |                                 |   else unknown     |
//
// keys.set writes the item, reads it back, then retires the file -- one it cannot retire undoes the write and fails
// the change (a file left beside a newer item could be taken for the newer one). Over any sequence of reads, changes,
// hand-written files and failures, the settings in use are the last ones successfully set (ModelStoreTests). One read
// or change at a time in the process (a lock).

import Foundation

enum ModelStore {
    /// What the keychain said.
    enum Read: Equatable { case value(String), none, failed }

    /// The keychain as one item (the helper's; a test's own in tests).
    protocol Keychain: AnyObject {
        func read() -> Read
        /// When the item was last written (nil: not known).
        func modified() -> Date?
        /// True: written.
        func write(_ text: String) -> Bool
        /// The item removed and written anew (an item this helper cannot read -- another build's, a locked one --
        /// replaced at the user's own save). True: written.
        func replace(_ text: String) -> Bool
    }

    /// One read or change of the settings at a time, in this process (#127 review: the helper serves each connection
    /// on its own thread; a keys.set and a read's migration interleaved lost a change reported as made).
    private static let lock = NSRecursiveLock()

    /// What one read decides: what to write, whether the file goes, which text the processes use.
    struct Plan: Equatable {
        var write: String?
        /// Remove models.env -- only once the keychain read back `write` (or already held the file's text, or is newer).
        var removeFile: Bool
        /// The settings in use (nil: unknown -- the keychain could not be read and there is no file).
        var use: String?
    }

    /// The plan from the file's text (nil: no file) and the keychain's read; `fileNewer`: the file was written after
    /// the item (nil dates: the file is taken as newer -- it can only be an older version's or the user's).
    static func plan(file: String?, keychain: Read, fileNewer: Bool = true) -> Plan {
        switch (file, keychain) {
        case (nil, .value(let k)): return Plan(write: nil, removeFile: false, use: k)
        case (nil, .none): return Plan(write: nil, removeFile: false, use: "")
        case (nil, .failed): return Plan(write: nil, removeFile: false, use: nil)
        case (let f?, .value(let k)) where same(f, k): return Plan(write: nil, removeFile: true, use: k)
        case (_?, .value(let k)) where !fileNewer: return Plan(write: nil, removeFile: true, use: k)
        case (let f?, .value), (let f?, .none): return Plan(write: f, removeFile: true, use: f)
        // (the item unreadable: the file only when it is the newer -- an older one is no longer what was set)
        case (let f?, .failed): return Plan(write: nil, removeFile: false, use: fileNewer ? f : nil)
        }
    }

    /// The same settings (the same pairs, whatever their order, comments and quoting).
    static func same(_ a: String, _ b: String) -> Bool { parse(a) == parse(b) }

    /// One read of the settings, the move from models.env done on the way: the text the processes use (nil: unknown).
    static func current(keychain: Keychain, file: URL, files: Files = Disk()) -> String? {
        lock.lock(); defer { lock.unlock() }
        let fileText = files.read(file)
        let read = keychain.read()
        // (a keychain date may be cut to the second: a file within a second of it may be the newer -- ambiguity never
        // retires a credential, so it is taken as newer and moved in; only a file plainly older loses -- #127 Codex)
        let newer: Bool = {
            guard fileText != nil, let f = files.modified(file), let k = keychain.modified() else { return true }
            return f.timeIntervalSince(k) > -1
        }()
        let p = plan(file: fileText, keychain: read, fileNewer: newer)
        var remove = p.removeFile
        if let w = p.write { remove = keychain.write(w) && keychain.read() == .value(w) }
        if remove, let f = fileText { _ = drop(file, f, holding: p.use, files: files) }
        return p.use
    }

    enum SetResult: Equatable { case set(String), failed(String) }

    /// A change from the app, merged into the settings now (`set`: these pairs; `unset`: these names) -- keys the app
    /// never shows are kept. Written, read back, then models.env removed (a removal that fails leaves a file older than
    /// the item: the next read removes it). `replace`: the user's own save over an item this helper cannot read --
    /// that item is removed and the settings written anew (from models.env if there is one). Never on its own.
    static func set(_ pairs: [String: String], unset: [String] = [], replace: Bool = false, keychain: Keychain, file: URL,
                    files: Files = Disk()) -> SetResult {
        lock.lock(); defer { lock.unlock() }
        let read = current(keychain: keychain, file: file, files: files)
        guard read != nil || replace else { return .failed("unreadable") }
        let now = read ?? files.read(file) ?? ""
        var env = parse(now)
        for (k, v) in pairs where validName(k) && !v.isEmpty { env[k] = v }
        for k in unset { env[k] = nil }
        let text = ModelKeys.fingerprint(env)
        let wrote = read == nil ? keychain.replace(text) : keychain.write(text)
        guard wrote, keychain.read() == .value(text) else {
            if read != nil { _ = keychain.write(now) }      // (a write that did not read back: what was there before)
            return .failed("keychain")
        }
        // the file gone -- or the change undone: a file left beside a newer item could be taken for the newer one
        // (within a second) and bring the old settings back
        guard files.read(file).map({ drop(file, $0, holding: text, files: files) }) ?? true else {
            if read != nil { _ = keychain.write(now) }
            return .failed("old_file")
        }
        return .set(text)
    }

    /// models.env, gone from its place: unlinked when the keychain holds exactly what it said (read back: nothing is
    /// lost, and no plaintext key stays on disk -- #127 Codex); retired to the Trash when it says something else (an
    /// older file, one a change replaced: what the user put there never just vanishes).
    private static func drop(_ file: URL, _ text: String, holding: String?, files: Files) -> Bool {
        if let h = holding, same(text, h) { return files.remove(file) }
        return files.retire(file)
    }

    /// The file system as these moves see it (a test's own, with failures). `remove`: unlinked; `retire`: to the
    /// Trash (or renamed beside it).
    protocol Files {
        func read(_ u: URL) -> String?
        func modified(_ u: URL) -> Date?
        func remove(_ u: URL) -> Bool
        func retire(_ u: URL) -> Bool
    }
    struct Disk: Files {
        func read(_ u: URL) -> String? { try? String(contentsOf: u, encoding: .utf8) }
        func modified(_ u: URL) -> Date? { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        func remove(_ u: URL) -> Bool {
            guard FileManager.default.fileExists(atPath: u.path) else { return true }
            return (try? FileManager.default.removeItem(at: u)) != nil
        }
        /// To the Trash (what the user put there never just vanishes: a restored backup, a hand edit); no Trash: renamed
        /// models.env.replaced-<date> beside it. True: it is no longer at `u`.
        func retire(_ u: URL) -> Bool {
            let fm = FileManager.default
            guard fm.fileExists(atPath: u.path) else { return true }
            if (try? fm.trashItem(at: u, resultingItemURL: nil)) != nil { return true }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            return (try? fm.moveItem(at: u, to: u.deletingLastPathComponent().appendingPathComponent(u.lastPathComponent + ".replaced-" + stamp))) != nil
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
