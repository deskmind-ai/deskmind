// Chat sessions on the helper's socket (SessionHost): what the main app may write to a session, which of a session's
// lines a watching connection gets, and when a session has nothing going on. Pure functions over dictionaries, so they
// are tested without a process (tests/DecisionTests.swift).
//
// A session is one `harness.mjs session` process (deskmind-ai/harness docs/protocol.md 「会话（第 1 版）」): control
// lines on its stdin, events on its stdout. Its stored events (`session.message`, `session.task`, …) carry `seq`, from
// 1 and without gaps, written to disk before they are sent; the executor events it forwards carry their run's own
// `seq` and `run_id`; the rest (`session.start`, `session.delta`, `session.queue`, refusals) carry none.

import Foundation

enum SessionWire {
    /// The control types the session process reads (control.ts / host.ts parseSessionControl), and what each must
    /// carry. A replay (`attach`) the app asks for itself is safe: each watching connection takes a stored line once
    /// (Gate), whoever asked for it.
    static let knownTypes: Set<String> = ["say", "cua", "steer", "answer", "respond", "stop", "retry", "attach",
                                          "queue_edit", "queue_cancel", "queue_send_now", "end"]
    /// A control line's longest JSON (the harness refuses a user message over 32k characters itself; this only keeps a
    /// runaway write off the session's stdin).
    static let maxLineBytes = 1 << 20

    /// `session.send`'s `line` (a JSON object, or its text) → the object to write, or why it is refused. Only a JSON
    /// object whose `type` the session knows, with the fields that type needs, is passed on: anything else the
    /// session would drop without a word, and the app would wait for an answer that never comes.
    static func validate(_ line: Any?) -> (line: [String: Any]?, error: String?) {
        var object: Any? = line
        if let text = line as? String {
            guard text.utf8.count <= maxLineBytes else { return (nil, "the line is too long") }
            object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
            if object == nil { return (nil, "the line is not JSON") }
        }
        guard let o = object as? [String: Any] else { return (nil, "the line must be a JSON object") }
        guard let type = o["type"] as? String else { return (nil, "the line has no type") }
        guard knownTypes.contains(type) else { return (nil, "unknown type \(type)") }
        let has = { (k: String) in o[k] is String }
        func integer(_ k: String) -> Bool {
            guard let n = o[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
            return n.doubleValue == n.doubleValue.rounded() && n.doubleValue >= 0
        }
        switch type {
        case "say", "cua", "steer":
            if !has("text") { return (nil, "\(type) needs text") }
        case "queue_edit":
            if !has("id") || !has("text") { return (nil, "queue_edit needs id and text") }
        case "queue_cancel", "queue_send_now":
            if !has("id") { return (nil, "\(type) needs id") }
        case "answer":
            // the card it answers (an answer without ask_id is refused once any card was voided, docs/protocol.md),
            // and the option by its index, or the user's words (neither: "no" on a card with only an approve option)
            if !has("ask_id") { return (nil, "answer needs ask_id") }
            if o["option"] != nil && !integer("option") { return (nil, "answer's option must be an index") }
            if o["text"] != nil && !has("text") { return (nil, "answer's text must be a string") }
        case "respond":
            if !integer("option") { return (nil, "respond needs option (an index)") }
        case "attach":
            if o["after_seq"] != nil && !integer("after_seq") { return (nil, "attach's after_seq must be a seq") }
        default: break
        }
        if o["run_id"] != nil && !has("run_id") { return (nil, "run_id must be a string") }
        guard JSONSerialization.isValidJSONObject(o),
              (try? JSONSerialization.data(withJSONObject: o))?.count ?? Int.max <= maxLineBytes else { return (nil, "the line is too long") }
        return (o, nil)
    }

    /// Which of one session's lines a watching connection gets, per stream: what was stored is replayed first, then
    /// the live lines, with contiguous seqs (no repeat, no gap).
    /// - Stored session events (`session.*` with seq): seq `after + 1` only, so a live event that overtakes the replay
    ///   (`attach{after_seq}`, sent when the connection starts watching) is dropped here and arrives again, in its
    ///   place, in the replay — the session writes every stored event to disk before it sends it, and replays what is
    ///   on disk.
    /// - A task's events (by run and seq): each run's lines in seq order from the cursor on. For a run whose replay
    ///   this connection asked for (`expect`: its cursor, or a task still open when it started watching), a live line
    ///   that comes before the replay of what is below it (`attach{run_id}` is answered from the run's events.jsonl,
    ///   which the executor writes before it sends) is held until the replay has filled the gap, then passed on behind
    ///   it; a gap not filled within `holdLimit` (a replay that never came) lets the held lines go, in order
    ///   (`expire`). Any other run (one that started while it watched; or a replay another connection or the app asked
    ///   for) is passed on only in order from its cursor: a line past a gap is dropped, never held and never passed
    ///   with the gap (a stray last line of a task closed before this connection came is not its stream).
    /// - Lines with no seq: always, at once.
    struct Gate {
        /// The last stored event passed on.
        var after: Int
        /// Per run: every seq up to this one passed on.
        var runs: [String: Int] = [:]
        /// Per run: live lines held for the replay below them (seq → line), and since when.
        private(set) var held: [String: [Int: [String: Any]]] = [:]
        private(set) var heldSince: [String: Date] = [:]
        /// The runs whose replay this connection asked for.
        private(set) var expected: Set<String> = []
        static let holdLimit: TimeInterval = 10

        init(after: Int, runs: [String: Int] = [:]) {
            self.after = max(0, after)
            for (r, n) in runs { self.runs[r] = max(0, n); expected.insert(r) }
        }

        /// This connection asked for `run`'s replay: its lines are held in order until the replay has come.
        mutating func expect(_ run: String) { expected.insert(run) }

        /// Some run's lines wait for their replay.
        var holding: Bool { !held.isEmpty }

        /// The lines to pass on now, in order, for one line of the session: none (a repeat, or held), the line, or
        /// the line and the held ones it lets go.
        mutating func admit(_ e: [String: Any], now: Date = Date()) -> [[String: Any]] {
            let kind = e["kind"] as? String ?? ""
            let seq = (e["seq"] as? NSNumber)?.intValue
            if kind.hasPrefix("session.") {
                guard let seq else { return [e] }
                guard seq == after + 1 else { return [] }
                after = seq
                return [e]
            }
            guard let run = e["run_id"] as? String, let seq else { return [e] }
            let upTo = runs[run] ?? 0
            if seq <= upTo || held[run]?[seq] != nil { return [] }
            if seq > upTo + 1 {
                guard expected.contains(run) else { return [] }
                held[run, default: [:]][seq] = e
                if heldSince[run] == nil { heldSince[run] = now }
                return []
            }
            var out = [e], n = seq
            while let next = held[run]?.removeValue(forKey: n + 1) { out.append(next); n += 1 }
            runs[run] = n
            if held[run]?.isEmpty ?? true { held[run] = nil; heldSince[run] = nil } else if n > seq { heldSince[run] = now }
            return out
        }

        /// The held lines of each run whose gap has stayed open for `limit`: passed on in seq order, the cursor moved
        /// past them (a replay that never came must not hold the task's card back for good).
        mutating func expire(now: Date = Date(), limit: TimeInterval = holdLimit) -> [[String: Any]] {
            var out: [[String: Any]] = []
            for run in heldSince.keys.sorted() where now.timeIntervalSince(heldSince[run]!) >= limit {
                let lines = held[run] ?? [:]
                for k in lines.keys.sorted() { out.append(lines[k]!) }
                runs[run] = max(runs[run] ?? 0, lines.keys.max() ?? 0)
                held[run] = nil; heldSince[run] = nil
            }
            return out
        }
    }

    /// Which of a session process's lines are new (not a replay of what it stored before) and which of its tasks run
    /// in this helper now: only those drive the live card and the recording (a replayed `start` or `step` of a task
    /// that ended long ago, or under another helper, must not). A stored line is new when its seq is past every one
    /// seen (the process's `session.start` says where its history ended: `last_seq`); a task is live from its new
    /// `session.task` until its task_done (or its new `session.task_end` / `session.task_closed`), and each of its
    /// executor lines is shown once.
    struct Live {
        /// The last stored seq seen: what a re-open of the running session reports as `last_seq`.
        private(set) var lastSeq: Int
        private(set) var runs: Set<String> = []
        private var shown: [String: Int] = [:]

        init(lastSeq: Int = 0) { self.lastSeq = max(0, lastSeq) }

        /// A `session.*` line: true when it is new (a stored line past every one seen, or one that is never stored).
        mutating func note(_ e: [String: Any]) -> Bool {
            guard let seq = (e["seq"] as? NSNumber)?.intValue else { return true }
            guard seq > lastSeq else { return false }
            lastSeq = seq
            if let run = e["run_id"] as? String {
                switch e["kind"] as? String {
                case "session.task": runs.insert(run)
                case "session.task_end", "session.task_closed": runs.remove(run); shown[run] = nil
                default: break
                }
            }
            return true
        }

        /// A task's executor line: true when its task is live here and the line was not shown before (a replay of
        /// the live task is not shown again). Its task_done ends it.
        mutating func show(_ e: [String: Any]) -> Bool {
            guard let run = e["run_id"] as? String, runs.contains(run) else { return false }
            if let seq = (e["seq"] as? NSNumber)?.intValue {
                guard seq > shown[run] ?? 0 else { return false }
                shown[run] = seq
            }
            if e["kind"] as? String == "task_done" { runs.remove(run); shown[run] = nil }
            return true
        }
    }

    /// What a session has going on, from its new events (Live.note): tasks running (`session.task` until
    /// `session.task_end`), tasks whose executor is still there (until `session.task_closed`: its result card can be
    /// answered), among them those whose card offers undo (`session.task_end` with `undo: "open"`), and words queued
    /// while a task ran (`session.queue`, kept only in the process). A session with none of these loses nothing when its
    /// process ends: a reply in progress is let finish and stored before the process exits on stdin closed.
    struct Activity {
        var running: Set<String> = []
        var open: Set<String> = []
        var undo: Set<String> = []
        var queued = false
        /// Each task's request (`raw`), for the live card's first line.
        var raw: [String: String] = [:]

        var idle: Bool { running.isEmpty && open.isEmpty && !queued }
        /// A task runs, or a finished one's undo can still be asked for: the helper does not restart under either
        /// (its process would go, and the undo with it).
        var holdsRestart: Bool { !running.isEmpty || !undo.isEmpty }

        mutating func note(_ e: [String: Any]) {
            let run = e["run_id"] as? String ?? ""
            switch e["kind"] as? String {
            case "session.task":
                guard !run.isEmpty else { return }
                running.insert(run); open.insert(run)
                raw[run] = e["raw"] as? String ?? ""
            case "session.task_end":
                running.remove(run)
                if e["undo"] as? String == "open" && open.contains(run) { undo.insert(run) }
            case "session.task_closed":
                running.remove(run); open.remove(run); undo.remove(run); raw[run] = nil
            case "session.queue":
                queued = !((e["items"] as? [Any]) ?? []).isEmpty
            default: break
            }
        }
    }

    /// The machine lock's holder (harness docs/protocol.md 「电脑锁」, version 2): the executor's process group, which
    /// state it is in, and whose task it is. ComputerLock (the helper) and harness src/session/computer.ts (a session)
    /// read and write the same file.
    struct Holder: Equatable {
        var state: String          // "acting" | "lingering"
        var pgid: Int32            // 0: an executor inside its owner's process (harness tests): held while `owner` lives
        var pid: Int32
        var start: Int             // the leader's start time, seconds since 1970 (0: unknown)
        var runID: String
        var sessionID: String
        var by: String
        var owner: Int32
        var t: Double
        /// When a task first found it orphaned (acting, its owner and leader gone, a process of its group up): the
        /// next task ends it `orphanSeconds` later.
        var orphanSince: Double? = nil

        var acting: Bool { state == "acting" }

        /// The lock's text → its holder; an earlier format (`{pid, executor_pid}`) reads as acting, held while one of
        /// those lives (`alive`); nil when it is no lock.
        static func parse(_ text: String?, alive: (Int32) -> Bool) -> Holder? {
            guard let t = text, let o = (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any] else { return nil }
            func int(_ k: String) -> Int? {
                guard let n = o[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == n.doubleValue.rounded(),
                      abs(n.doubleValue) < 1e15 else { return nil }
                return n.intValue
            }
            /// a pid: only a value that fits (a lock written by anyone must not crash the helper)
            func pid(_ k: String) -> Int32? { int(k).flatMap { Int32(exactly: $0) } }
            if o["v"] != nil {
                guard int("v") == 2, let state = o["state"] as? String, state == "acting" || state == "lingering",
                      let pgid = pid("pgid"), let owner = pid("owner") else { return nil }
                return Holder(state: state, pgid: pgid, pid: pid("pid") ?? pgid, start: int("start") ?? 0,
                              runID: o["run_id"] as? String ?? "", sessionID: o["session_id"] as? String ?? "",
                              by: o["by"] as? String ?? "", owner: owner, t: (o["t"] as? NSNumber)?.doubleValue ?? 0,
                              orphanSince: (o["orphan_since"] as? NSNumber)?.doubleValue)
            }
            // an earlier format, with no version
            if let p = pid("pid") {
                let up = [p, pid("executor_pid") ?? 0].first { $0 > 0 && alive($0) }
                return Holder(state: "acting", pgid: 0, pid: 0, start: 0, runID: o["run_id"] as? String ?? "",
                              sessionID: o["session_id"] as? String ?? "", by: "old", owner: up ?? 0, t: 0)
            }
            return nil
        }

        var json: Data {
            var o: [String: Any] = ["v": 2, "state": state, "pgid": Int(pgid), "pid": Int(pid), "start": start, "run_id": runID,
                                    "session_id": sessionID, "by": by, "owner": Int(owner), "t": t]
            if let orphanSince { o["orphan_since"] = orphanSince }
            return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
        }
    }

    /// Whether the holder's tree may still act: some (not zombie) process of its group lives — whether or not its owner
    /// does — unless the group's id now names another group (its leader's pid alive with another start time). The
    /// system is asked through `groupAlive`, `alive` and `startOf` (injected for the tests).
    static func held(_ h: Holder, groupAlive: (Int32) -> Bool, alive: (Int32) -> Bool, startOf: (Int32) -> Int?) -> Bool {
        if h.pgid == 0 { return h.owner > 0 && alive(h.owner) }
        guard h.pgid > 1, groupAlive(h.pgid) else { return false }
        if h.start > 0, alive(h.pid), let s = startOf(h.pid), abs(s - h.start) > 1 { return false }
        return true
    }
}
