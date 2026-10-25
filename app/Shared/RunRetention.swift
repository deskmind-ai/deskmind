// How long a task's run records are kept (M5, plan §11.2, decision 9): 30 days or 1 GB in all, whichever comes first,
// the oldest taken first, until both hold. After each task's end and at the app's launch; 「清除运行记录」 takes all.
//
// What goes is a run's *records* only -- shots/, trace.jsonl, trace.otel.jsonl, model_calls.jsonl -- for a run of a
// chat session: its events.jsonl is what the session replays (the chat's task, its cards, its end) and its
// journal.jsonl is undo's and recovery's source of truth (fable 10-25). Such a run then carries `marker`, and the
// 「过程」 tab says 「运行记录已清理」 for it whatever stray file the harness still writes there (a late shot): the next
// pass takes those again. The old window's runs (work/harness-runs) go whole, as before. Never touched: a run with no
// task_done (still running), the run a session runs now (its late shots may still be landing), annotations/.
//
// Sizes are the records' bytes (what deleting can free: events alone can never be asked to fit); a run's age is its
// task_done's own time (`t`), the folder's creation date only when that is not there (a copy or a restore resets it).

import Foundation

enum RunRetention {
    static let maxAge: TimeInterval = 30 * 24 * 3600
    static let maxBytes: Int64 = 1 << 30
    /// Written into a session run whose records were taken (an empty file).
    static let marker = "pruned"
    /// A session run's record files and folders: what goes.
    static let records = ["shots", "trace.jsonl", "trace.otel.jsonl", "model_calls.jsonl"]

    enum Kind: Equatable { case session, whole }
    struct Run: Equatable {
        var id: String
        var folder: URL
        var kind: Kind
        /// task_done's time (else the folder's creation), seconds since 1970; nil: no task_done (running).
        var ended: Double?
        /// The bytes deleting it would free.
        var bytes: Int64
        /// A session runs it now (its late writes may still be landing).
        var live = false
        /// Its records were taken already (the marker): only what came after it is left.
        var pruned = false
    }

    /// The runs to take, oldest first: of those that may go (mayGo), every one older than maxAge, and the oldest of the
    /// rest while the total of what stays is over maxBytes (the total counts every run, those that may not go too). A
    /// pruned run with stray records is taken whatever its age (its records are not kept).
    static func plan(_ runs: [Run], now: Double, maxAge: TimeInterval = maxAge, maxBytes: Int64 = maxBytes) -> [Run] {
        let may = runs.filter(mayGo).sorted { ($0.ended!, $0.id) < ($1.ended!, $1.id) }
        var take: [Run] = []
        var total = runs.reduce(Int64(0)) { $0 + $1.bytes }
        for r in may where r.pruned || now - r.ended! > maxAge || total > maxBytes {
            take.append(r)
            total -= r.bytes
        }
        return take
    }

    /// Whether `r` may be taken at all: ended, not live, and something of it left to take (a pruned session run with
    /// no stray record has none).
    static func mayGo(_ r: Run) -> Bool { r.ended != nil && !r.live && !(r.kind == .session && r.pruned && r.bytes == 0) }

    // MARK: on disk

    /// Every run under the old window's folder (`whole`) and every session's runs folder (`session`).
    static func runs(support: URL, live: Set<String>) -> [Run] {
        var out: [Run] = []
        let fm = FileManager.default
        func children(_ u: URL) -> [URL] { (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [] }
        for f in children(support.appendingPathComponent("work/harness-runs")) where isDir(f) {
            out.append(run(f, kind: .whole, live: live))
        }
        for s in children(support.appendingPathComponent("sessions")) where isDir(s) {
            for f in children(s.appendingPathComponent("runs")) where isDir(f) { out.append(run(f, kind: .session, live: live)) }
        }
        return out
    }

    static func run(_ folder: URL, kind: Kind, live: Set<String>) -> Run {
        let fm = FileManager.default
        let id = folder.lastPathComponent
        let events = RunDir.lines(try? String(contentsOf: folder.appendingPathComponent("events.jsonl"), encoding: .utf8))
        var ended: Double?
        if let done = events.last(where: { $0["kind"] as? String == "task_done" }) {
            ended = (done["t"] as? NSNumber)?.doubleValue      // (seconds since 1970: harness EventLog)
                ?? ((try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate)?.timeIntervalSince1970 ?? 0)
        }
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
    static func prune(support: URL = DeskMindIPC.supportDir, live: Set<String>, now: Double = Date().timeIntervalSince1970,
                      everything: Bool = false) -> Int {
        let all = runs(support: support, live: live)
        let go = everything ? all.filter(mayGo) : plan(all, now: now)
        for r in go { take(r) }
        return go.count
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
