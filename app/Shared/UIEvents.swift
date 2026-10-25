// The UI event log (plan §5): what the interface did — which cards came, where and how they were answered, how long
// that took, whether DeskMind came to the front on its own — so an acceptance run reads numbers, not impressions.
//
// The invariant: the log holds no user content. Held by the types, not by care:
// - `UIEvents.record(_:)` is the one way in (ShellTests: no other file names the log's files).
// - `UIEvent`'s associated values are enums, integers, booleans and `UIEvent.ID` — never a String — so the user's
//   words, a file name, a window title or an app name cannot be passed (ShellTests checks the declaration).
// - `UIEvent.ID` takes only a run or ask id as the harness makes them (`run_` / `ask_` and hex): random, and what
//   joins a line to the run's directory.
//
// The files: `ui-events.jsonl` (the main app) and `ui-events-helper.jsonl` (the helper), in DeskMind's support
// directory, on this Mac only (never uploaded, never attached to a report). A file grows to `maxBytes`; then it is
// renamed `.1` (replacing the older one) and a new one starts: two at most. Lines are written on a serial queue, off
// the caller's thread; a failed write is counted, never retried and never shown.
//
// The switch (on by default) is a file, `ui-events.off`, next to the logs: both processes read the same fact (the
// helper has other defaults). Turning it off stops writing; Clear removes every log file.
//
// One line, one event: {"t": <ms since 1970>, "e": "<event>", <its fields>}. tools/ui_events_summary.py reads them.

import Foundation

enum UIEvent: Equatable {
    /// A run or ask id, as the harness makes them: the only text an event carries.
    struct ID: Equatable {
        let raw: String
        /// `run_` or `ask_`, then 4 to 32 lowercase hex digits; anything else is not an id and is not kept.
        init?(_ s: String) {
            let parts = s.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "run" || parts[0] == "ask", (4...32).contains(parts[1].count),
                  parts[1].allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
            raw = s
        }
    }

    enum CardKind: String { case plan, action, ambiguity, missing, resultCheck = "result_check", cannot, result, other }
    /// Where a card is answerable: the chat, the float, or the float's summary (title + 「去主窗口回答」).
    enum Place: String { case chat, float, floatSummary = "float_summary" }
    enum Window: String { case front, behind, minimized, hidden, closed }
    enum Option: String { case approve, choice, skipStep = "skip_step", delegate, cancel, undo, other }
    enum Pick: String { case click, digit, enter, space, typed }
    enum Ending: String { case answered, steer, stop, ended, replaced, expired }
    /// What brought DeskMind to the front: one of its own buttons (the island, the float), a reopen (the Dock icon, a
    /// notification, the live card), the user's own input to the system right before (⌘Tab, a click on the window, the
    /// menu bar), or none of these (acceptance wants 0).
    enum Activation: String { case button, reopen, userInput = "user_input", other }
    enum Undo: String { case undone, partial, unknown, expiredLate = "expired_late", expiredTime = "expired_time",
                        expiredNewTask = "expired_new_task", expiredHelperQuit = "expired_helper_quit", expiredOther = "expired_other" }

    case cardShown(run: ID?, ask: ID?, kind: CardKind, place: Place, window: Window, options: Int, details: Bool)
    case cardPick(run: ID?, ask: ID?, kind: CardKind, option: Option, by: Pick, place: Place, ms: Int)
    case cardTakeBack(run: ID?, ask: ID?, kind: CardKind)
    /// Written to the session; `heldMs`: how long it was held for its take-back (0: sent at once).
    case cardSent(run: ID?, ask: ID?, kind: CardKind, heldMs: Int)
    case cardEnded(run: ID?, ask: ID?, kind: CardKind, why: Ending)
    case cardReask(run: ID?, ask: ID?, kind: CardKind)
    case undo(run: ID?, outcome: Undo)
    case activation(by: Activation)

    var name: String {
        switch self {
        case .cardShown: "card_shown"
        case .cardPick: "card_pick"
        case .cardTakeBack: "card_take_back"
        case .cardSent: "card_sent"
        case .cardEnded: "card_ended"
        case .cardReask: "card_reask"
        case .undo: "undo"
        case .activation: "activation"
        }
    }

    /// Its fields, as the line has them (the event's name and time apart).
    var fields: [String: Any] {
        func ids(_ r: ID?, _ a: ID?) -> [String: Any] {
            var o: [String: Any] = [:]
            if let r { o["run_id"] = r.raw }
            if let a { o["ask_id"] = a.raw }
            return o
        }
        func with(_ base: [String: Any], _ more: [String: Any]) -> [String: Any] { base.merging(more) { a, _ in a } }
        switch self {
        case .cardShown(let r, let a, let k, let p, let w, let n, let d):
            return with(ids(r, a), ["kind": k.rawValue, "place": p.rawValue, "window": w.rawValue, "options": n, "details": d])
        case .cardPick(let r, let a, let k, let o, let b, let p, let ms):
            return with(ids(r, a), ["kind": k.rawValue, "option": o.rawValue, "by": b.rawValue, "place": p.rawValue, "ms": ms])
        case .cardTakeBack(let r, let a, let k), .cardReask(let r, let a, let k):
            return with(ids(r, a), ["kind": k.rawValue])
        case .cardSent(let r, let a, let k, let ms):
            return with(ids(r, a), ["kind": k.rawValue, "held_ms": ms])
        case .cardEnded(let r, let a, let k, let why):
            return with(ids(r, a), ["kind": k.rawValue, "why": why.rawValue])
        case .undo(let r, let o):
            return with(ids(r, nil), ["outcome": o.rawValue])
        case .activation(let by):
            return ["by": by.rawValue]
        }
    }
}

/// One process's log file, with its cap and rotation. `UIEvents` holds the process's own; tests make their own in a
/// temporary directory.
final class UIEventLog {
    static let mainFile = "ui-events.jsonl", helperFile = "ui-events-helper.jsonl", offFile = "ui-events.off"
    static let maxBytes = 2 * 1024 * 1024

    let dir: URL
    let file: String
    let maxBytes: Int
    /// Milliseconds since 1970 (tests set their own clock).
    var now: () -> Int = { Int((Date().timeIntervalSince1970 * 1000).rounded()) }
    private let queue = DispatchQueue(label: "ai.deskmind.ui-events")
    private var failedWrites = 0

    init(dir: URL, file: String, maxBytes: Int = UIEventLog.maxBytes) {
        self.dir = dir; self.file = file; self.maxBytes = maxBytes
    }

    var url: URL { dir.appendingPathComponent(file) }
    var rotated: URL { dir.appendingPathComponent(file + ".1") }
    var enabled: Bool { !FileManager.default.fileExists(atPath: dir.appendingPathComponent(Self.offFile).path) }

    /// Writes failed so far (read on the log's queue).
    var failures: Int { queue.sync { failedWrites } }

    func record(_ e: UIEvent) {
        let t = now()
        queue.async { self.append(e, at: t) }
    }

    /// Waits for every line recorded so far to be written (tests; Clear).
    func flush() { queue.sync {} }

    func setEnabled(_ on: Bool) {
        queue.sync {
            let off = dir.appendingPathComponent(Self.offFile)
            if on { try? FileManager.default.removeItem(at: off) }
            else {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if !FileManager.default.createFile(atPath: off.path, contents: Data()) { failedWrites += 1 }
            }
        }
    }

    /// Removes both logs of both processes (the switch stays as it is).
    func clear() {
        queue.sync {
            for f in [Self.mainFile, Self.helperFile] {
                for name in [f, f + ".1"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
            }
        }
    }

    private func append(_ e: UIEvent, at t: Int) {
        guard enabled else { return }
        var o = e.fields
        o["t"] = t; o["e"] = e.name
        guard var line = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { failedWrites += 1; return }
        line.append(0x0A)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            if let size, size > 0, size + line.count > maxBytes {
                try? fm.removeItem(at: rotated)
                try fm.moveItem(at: url, to: rotated)
            }
            if !fm.fileExists(atPath: url.path) { guard fm.createFile(atPath: url.path, contents: nil) else { failedWrites += 1; return } }
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: line)
        } catch {
            failedWrites += 1
        }
    }
}

/// The one way in (see the file's header).
enum UIEvents {
    /// This process's log: none until the app (`ui-events.jsonl`) or the helper (`ui-events-helper.jsonl`) sets its
    /// own at launch, so a test or an e2e build never writes to the real support directory. Set once, before the
    /// first event.
    nonisolated(unsafe) static var log: UIEventLog?

    static func record(_ e: UIEvent) { log?.record(e) }
    static var enabled: Bool { log?.enabled ?? false }
    static func setEnabled(_ on: Bool) { log?.setEnabled(on) }
    static func clear() { log?.clear() }

    /// What brought the app to the front, when it became active: DeskMind's own funnel (Activation.bringForward) said
    /// within the last `window` seconds, else the user's own input to the system (a mouse-down or a key-down from the
    /// hardware within `window`), else `other`.
    static let activationWindow = 1.0
    static func activation(funnel: (by: UIEvent.Activation, at: Double)?, now: Double, userInputAgo: Double) -> UIEvent.Activation {
        if let f = funnel, now - f.at >= 0, now - f.at <= activationWindow { return f.by }
        return userInputAgo <= activationWindow ? .userInput : .other
    }
}

extension UIEvent.CardKind {
    init(_ kind: String) { self = UIEvent.CardKind(rawValue: kind) ?? .other }
}
