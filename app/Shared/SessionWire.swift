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

    /// Which of one session's lines a watching connection gets. Stored session events in order and once: with seq
    /// `after + 1` only, so a live event that overtakes the replay (`attach{after_seq}`, sent when the connection
    /// starts watching) is dropped here and arrives again, in its place, in the replay — the session writes every
    /// stored event to disk before it sends it, and replays what is on disk. A task's events once each: by run and seq
    /// (a task's replay, `attach{run_id}`, may come after its live events). Lines with no seq always.
    struct Gate {
        /// The last stored event passed on.
        var after: Int
        /// Per run: every seq up to `upTo` passed on, and the ones above it passed on out of order.
        var runs: [String: (upTo: Int, above: Set<Int>)] = [:]

        init(after: Int, runs: [String: Int] = [:]) {
            self.after = max(0, after)
            for (r, n) in runs { self.runs[r] = (max(0, n), []) }
        }

        mutating func admit(_ e: [String: Any]) -> Bool {
            let kind = e["kind"] as? String ?? ""
            let seq = (e["seq"] as? NSNumber)?.intValue
            if kind.hasPrefix("session.") {
                guard let seq else { return true }
                guard seq == after + 1 else { return false }
                after = seq
                return true
            }
            guard let run = e["run_id"] as? String, let seq else { return true }
            var r = runs[run] ?? (0, [])
            if seq <= r.upTo || r.above.contains(seq) { return false }
            r.above.insert(seq)
            while r.above.remove(r.upTo + 1) != nil { r.upTo += 1 }
            runs[run] = r
            return true
        }
    }

    /// What a session has going on, from its events: tasks running (`session.task` until `session.task_end`), tasks
    /// whose executor is still there (until `session.task_closed`: its result card can be answered), and words queued
    /// while a task ran (`session.queue`, kept only in the process). A session with none of these loses nothing when its
    /// process ends: a reply in progress is let finish and stored before the process exits on stdin closed.
    struct Activity {
        var running: Set<String> = []
        var open: Set<String> = []
        var queued = false
        /// Each task's request (`raw`), for the live card's first line.
        var raw: [String: String] = [:]

        var idle: Bool { running.isEmpty && open.isEmpty && !queued }

        mutating func note(_ e: [String: Any]) {
            let run = e["run_id"] as? String ?? ""
            switch e["kind"] as? String {
            case "session.task":
                guard !run.isEmpty else { return }
                running.insert(run); open.insert(run)
                raw[run] = e["raw"] as? String ?? ""
            case "session.task_end":
                running.remove(run)
            case "session.task_closed":
                running.remove(run); open.remove(run); raw[run] = nil
            case "session.queue":
                queued = !((e["items"] as? [Any]) ?? []).isEmpty
            default: break
            }
        }
    }

    /// The machine lock's holder (harness sessions/computer.lock: `{pid, session_id, run_id, executor_pid?}`, or an
    /// old bare pid): the processes whose life holds it. Nil when the text is no lock.
    static func lockHolders(_ text: String?) -> [Int32]? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if let o = (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any] {
            guard let pid = o["pid"] as? NSNumber else { return nil }
            var out = [pid.int32Value]
            if let e = o["executor_pid"] as? NSNumber { out.append(e.int32Value) }
            return out
        }
        if let n = Int32(t), n > 0 { return [n] }
        return nil
    }

    /// Whether the lock is held: some holder is alive (`alive` asks the system; injected for the tests).
    static func lockHeld(_ text: String?, alive: (Int32) -> Bool) -> Bool {
        (lockHolders(text) ?? []).contains { $0 > 0 && alive($0) }
    }
}
