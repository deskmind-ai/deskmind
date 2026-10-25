// How long a task's run records are kept (M5, plan §11.2, decision 9): 30 days or 1 GB in all, whichever comes first,
// the oldest taken first, until both hold. After each task's end and at the app's launch; 「清除运行记录」 takes all.
//
// What goes is a run's *records* only -- shots/, trace.jsonl, trace.otel.jsonl, model_calls.jsonl -- for a run of a
// chat session: its events.jsonl is what the session replays (the chat's task, its cards, its end) and its
// journal.jsonl is undo's and recovery's source of truth (fable 10-25). Such a run then carries `marker`, and the
// 「过程」 tab says 「运行记录已清理」 for it whatever stray file the harness still writes there (a late shot): the next
// pass takes those again. The old window's runs (work/harness-runs) go whole, as before. Never touched: a live run --
// known live from live facts only (the window's running and lingering runs, the computer lock's holder, the helper's
// own sessions' runs: #126 review) -- a folder that is a symbolic link, annotations/. A run with no task_done that is
// not live (killed, crashed, a session closed without an end) is one like any other: kept while young, then taken.
//
// Sizes are the records' bytes (what deleting can free: events alone can never be asked to fit); a run's age is its
// task_done's own time (`t`), else when its events were last written (events.jsonl, else the folder), else now (an age
// not known keeps it this pass -- never 1970).

import Foundation

enum RunRetention {
    static let maxAge: TimeInterval = 30 * 24 * 3600
    static let maxBytes: Int64 = 1 << 30
    /// Written into a session run whose records were taken (an empty file).
    static let marker = "pruned"
    /// A session run's record files and folders: what goes.
    static let records = ["shots", "trace.jsonl", "trace.otel.jsonl", "model_calls.jsonl", "runtime.jsonl", "runtime.log"]

    enum Kind: Equatable { case session, whole }
    struct Run: Equatable {
        var id: String
        var folder: URL
        var kind: Kind
        /// Its age's start, seconds since 1970: task_done's `t`, else its events' last write, else now.
        var ended: Double?
        /// The bytes deleting it would free.
        var bytes: Int64
        /// A session runs it now (its late writes may still be landing).
        var live = false
        /// Its records were taken already (the marker): only what came after it is left.
        var pruned = false
    }

    /// The runs to take, oldest first: of those that may go (mayGo), every one older than maxAge, and the oldest of the
    /// rest while their total is over maxBytes. A pruned run with stray records is taken whatever its age (its records
    /// are not kept).
    static func plan(_ runs: [Run], now: Double, maxAge: TimeInterval = maxAge, maxBytes: Int64 = maxBytes) -> [Run] {
        let may = runs.filter(mayGo).sorted { ($0.ended!, $0.id) < ($1.ended!, $1.id) }
        // the pruned ones' strays first (taken whatever), then the oldest of the rest while one is too old or the
        // total of what stays is over
        // (the total is of the runs that may go: a live run, or one whose age is not known, is kept and is not a reason
        // to take every other -- #126 review)
        var take = may.filter(\.pruned)
        var total = may.reduce(Int64(0)) { $0 + $1.bytes } - take.reduce(Int64(0)) { $0 + $1.bytes }
        for r in may where !r.pruned {
            guard now - r.ended! > maxAge || total > maxBytes else { break }
            take.append(r)
            total -= r.bytes
        }
        return take.sorted { ($0.ended!, $0.id) < ($1.ended!, $1.id) }
    }

    /// Whether `r` may be taken at all: ended, not live, and something of it left to take (a pruned session run with
    /// no stray record has none).
    static func mayGo(_ r: Run) -> Bool { r.ended != nil && !r.live && !(r.kind == .session && r.pruned && r.bytes == 0) }
    /// (`ended` nil only in tests' runs: not known, kept.)

    // MARK: on disk

    /// Every run under the old window's folder (`whole`) and every session's runs folder (`session`).
    static func runs(support: URL, live: Set<String>) -> [Run] {
        var out: [Run] = []
        let fm = FileManager.default
        // (a folder that is a symbolic link is never followed: what it points at is not ours to take)
        func children(_ u: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []).filter { realDir($0) }
        }
        for f in children(support.appendingPathComponent("work/harness-runs")) {
            out.append(run(f, kind: .whole, live: live))
        }
        for s in children(support.appendingPathComponent("sessions")) where realDir(s.appendingPathComponent("runs")) {
            for f in children(s.appendingPathComponent("runs")) { out.append(run(f, kind: .session, live: live)) }
        }
        return out
    }

    static func run(_ folder: URL, kind: Kind, live: Set<String>) -> Run {
        let fm = FileManager.default
        let id = folder.lastPathComponent
        let eventsFile = folder.appendingPathComponent("events.jsonl")
        // task_done is near the end: its last 64 KB is read, not the whole file
        let done = RunDir.lines(tail(eventsFile, 64 * 1024)).last { $0["kind"] as? String == "task_done" }
        func modified(_ u: URL) -> Double? { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 }
        let ended = (done?["t"] as? NSNumber)?.doubleValue      // (seconds since 1970: harness EventLog)
            ?? modified(eventsFile) ?? modified(folder) ?? Date().timeIntervalSince1970
        let bytes: Int64 = kind == .whole ? size(folder) : records.reduce(0) { $0 + size(folder.appendingPathComponent($1)) }
        return Run(id: id, folder: folder, kind: kind, ended: ended, bytes: bytes, live: live.contains(id),
                   pruned: fm.fileExists(atPath: folder.appendingPathComponent(marker).path))
    }

    /// Takes `r`: a whole run's folder, or a session run's records (then its marker). Never anything else.
    static func take(_ r: Run) {
        let fm = FileManager.default
        switch r.kind {
        case .whole: try? fm.removeItem(at: r.folder)
        case .session:
            for name in records { try? fm.removeItem(at: r.folder.appendingPathComponent(name)) }
            if !fm.fileExists(atPath: r.folder.appendingPathComponent(marker).path) {
                fm.createFile(atPath: r.folder.appendingPathComponent(marker).path, contents: Data())
            }
        }
    }

    /// One pass: what the plan says goes, now. `everything`: 「清除运行记录」 (every ended, not live run). The count taken.
    @discardableResult
    /// `live`: the caller's live facts, read again right before each run is taken (#126 Codex review at e419501: a
    /// task that started during the scan lost its trace) -- with the computer lock's holder, read again then too. A run
    /// is taken only when, at that moment, it is not live and nothing in its folder was written after the pass began
    /// (a run that new cannot be over yet).
    static func prune(support: URL = DeskMindIPC.supportDir, live: @escaping () -> Set<String>, now: Double = Date().timeIntervalSince1970,
                      everything: Bool = false, began: Date = Date()) -> Int {
        let liveNow = { live().union(lockHolder(support: support)) }
        let all = runs(support: support, live: liveNow())
        let go = everything ? all.filter(mayGo) : plan(all, now: now)
        var n = 0
        for r in go {
            guard !liveNow().contains(r.id), !writtenSince(began, r.folder) else { continue }
            take(r)
            n += 1
        }
        return n
    }
    static func prune(support: URL = DeskMindIPC.supportDir, live: Set<String>, now: Double = Date().timeIntervalSince1970,
                      everything: Bool = false) -> Int {
        prune(support: support, live: { live }, now: now, everything: everything)
    }

    /// Something in the run's folder (it, its events, its trace) was made or written at or after `t`.
    static func writtenSince(_ t: Date, _ folder: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
        return [folder, folder.appendingPathComponent("events.jsonl"), folder.appendingPathComponent("trace.jsonl")].contains { u in
            guard let v = try? u.resourceValues(forKeys: keys) else { return false }
            return [v.contentModificationDate, v.creationDate].contains { ($0 ?? .distantPast) >= t }
        }
    }

    /// The run that holds the computer now (sessions/computer.lock), whatever its process's state: a lingering run
    /// writes into its folder until it lets go (fail closed: a holder that may be gone is still not pruned).
    static func lockHolder(support: URL) -> Set<String> {
        let text = try? String(contentsOf: support.appendingPathComponent("sessions/computer.lock"), encoding: .utf8)
        return SessionWire.Holder.parse(text, alive: { _ in true }).map { [$0.runID] } ?? []
    }

    /// The last `n` bytes of a file as text (from the first whole line in them).
    static func tail(_ u: URL, _ n: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: u) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let from = size > UInt64(n) ? size - UInt64(n) : 0
        try? h.seek(toOffset: from)
        guard let d = try? h.readToEnd() else { return nil }
        let text = String(decoding: d, as: UTF8.self)
        return from == 0 ? text : String(text.drop { $0 != "\n" })
    }

    /// A folder that is a folder itself, not a symbolic link to one.
    static func realDir(_ u: URL) -> Bool {
        guard (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
        return isDir(u)
    }

    private static func isDir(_ u: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
    }

    /// The bytes of a file or of everything under a folder (0: not there).
    static func size(_ u: URL) -> Int64 {
        let fm = FileManager.default
        var d: ObjCBool = false
        guard fm.fileExists(atPath: u.path, isDirectory: &d) else { return 0 }
        if !d.boolValue { return ((try? fm.attributesOfItem(atPath: u.path)[.size]) as? NSNumber)?.int64Value ?? 0 }
        var n: Int64 = 0
        for case let f as URL in fm.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) ?? FileManager.DirectoryEnumerator() {
            n += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return n
    }
}
