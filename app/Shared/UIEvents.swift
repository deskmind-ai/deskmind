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
// helper has other defaults). Turning it off stops writing; Clear removes every log file, both processes'. Clear and
// every write hold the same lock (flock on `ui-events.lock`), and Clear moves a generation on (`ui-events.gen`): an
// event recorded before a Clear and written after it -- the other process's queue was behind -- is dropped, never
// written into the cleared file (#123 Codex review at 19236f0).
//
// One line, one event: {"t": <ms since 1970>, "e": "<event>", <its fields>}. tools/ui_events_summary.py reads them.

import Foundation

enum UIEvent: Equatable {
    /// A run or ask id, as the harness makes them: the only text an event carries.
    struct ID: Equatable {
        let raw: String
        /// `run_` or `ask_`, then 4 to 32 lowercase hex digits; anything else is not an id and is not kept. Checked
        /// byte by byte (UTF-8): a check by Characters lets a combining mark, a tag character, a joiner or a variation
        /// selector ride on an allowed one, and those can spell text (#123 review at 20e66ab).
        init?(_ s: String) {
            let b = Array(s.utf8)
            guard (8...36).contains(b.count), b[3] == UInt8(ascii: "_"),
                  Array(b[0..<3]) == Array("run".utf8) || Array(b[0..<3]) == Array("ask".utf8),
                  b[4...].allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return nil }
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
    /// What DeskMind's own funnel (Activation.bringForward) was asked to bring forward by: one of its buttons (the
    /// island, the float) or a reopen; `none`: the app became active with no call of the funnel. Facts, no guess: the
    /// summary puts an unattributed activation next to the reopens and the live card's opens around it.
    enum Activation: String { case button, reopen, none }
    /// The event AppKit was handling when the app became active (NSApp.currentEvent), by its type: a mouse-down in a
    /// window of DeskMind's, one elsewhere, a key-down, an AppKit-defined one, another, or none. A fact, read then.
    enum Input: String { case mouseDownInWindow = "mouse_down_in_window", mouseDown = "mouse_down", keyDown = "key_down",
                         appKitDefined = "appkit_defined", other, none }
    enum Undo: String { case undone, partial, unknown, expiredLate = "expired_late", expiredTime = "expired_time",
                        expiredNewTask = "expired_new_task", expiredHelperQuit = "expired_helper_quit", expiredOther = "expired_other" }

    case cardShown(run: ID?, ask: ID?, kind: CardKind, place: Place, window: Window, options: Int, details: Bool)
    /// `ms`: since the card was shown here; nil when that is not known (a card shown before a relaunch).
    case cardPick(run: ID?, ask: ID?, kind: CardKind, option: Option, by: Pick, place: Place, ms: Int?)
    case cardTakeBack(run: ID?, ask: ID?, kind: CardKind)
    /// Written to the session; `heldMs`: how long it was held for its take-back (0: sent at once).
    case cardSent(run: ID?, ask: ID?, kind: CardKind, heldMs: Int)
    case cardEnded(run: ID?, ask: ID?, kind: CardKind, why: Ending)
    case cardReask(run: ID?, ask: ID?, kind: CardKind)
    case undo(run: ID?, outcome: Undo)
    /// The app became active.
    case activation(by: Activation, input: Input)
    /// The app delegate was asked to reopen (the Dock icon, a notification, the live card -- or hands' `open -b`).
    case reopenAsked
    /// The helper's live card was clicked to open DeskMind (the helper's log).
    case liveCardOpen

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
        case .reopenAsked: "reopen_asked"
        case .liveCardOpen: "live_card_open"
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
            var f = with(ids(r, a), ["kind": k.rawValue, "option": o.rawValue, "by": b.rawValue, "place": p.rawValue])
            if let ms { f["ms"] = ms }
            return f
        case .cardTakeBack(let r, let a, let k), .cardReask(let r, let a, let k):
            return with(ids(r, a), ["kind": k.rawValue])
        case .cardSent(let r, let a, let k, let ms):
            return with(ids(r, a), ["kind": k.rawValue, "held_ms": ms])
        case .cardEnded(let r, let a, let k, let why):
            return with(ids(r, a), ["kind": k.rawValue, "why": why.rawValue])
        case .undo(let r, let o):
            return with(ids(r, nil), ["outcome": o.rawValue])
        case .activation(let by, let input):
            return ["by": by.rawValue, "input": input.rawValue]
        case .reopenAsked, .liveCardOpen:
            return [:]
        }
    }
}

/// One process's log file, with its cap and rotation. `UIEvents` holds the process's own; tests make their own in a
/// temporary directory.
final class UIEventLog {
    static let mainFile = "ui-events.jsonl", helperFile = "ui-events-helper.jsonl", offFile = "ui-events.off"
    static let lockFile = "ui-events.lock", genFile = "ui-events.gen"
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
        let t = now(), gen = generation()
        queue.async { self.append(e, at: t, generation: gen) }
    }

    /// Tests: hold this log's queue (an event recorded now waits), and let it go.
    func hold() { queue.suspend() }
    func release() { queue.resume() }

    /// The Clear generation on disk (0 before any Clear).
    func generation() -> Int {
        (try? String(contentsOf: dir.appendingPathComponent(Self.genFile), encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    }

    /// How long a write or a Clear waits for the lock the other process holds, at most (#123 Codex re-review at
    /// 85a6d11: the wait was unbounded, and a helper stuck in IO held the main thread's Clear). Then it gives up.
    static let lockWait: Double = 0.2
    /// A Clear the user asked for is tried again this many times, this far apart, on the log's queue without holding it
    /// (#123 Codex at a5c8995: it gave up once, silently, and the logs stayed): it is done, or the user is told.
    var clearRetries = 10
    var clearRetryEvery: Double = 0.5

    /// Runs `f` holding the lock both processes write under, tried without blocking for at most `lockWait`; true when
    /// it ran. Not had in time: `f` does not run (a write is dropped, a Clear not done) and the failure is counted.
    /// (No lock file at all -- the folder refuses it --: `f` runs, and the write that follows fails the same way.)
    @discardableResult
    private func locked(_ f: () -> Void) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent(Self.lockFile).path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { f(); return true }
        defer { close(fd) }
        let until = Date().addingTimeInterval(Self.lockWait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() >= until { failedWrites += 1; return false }
            usleep(5_000)
        }
        defer { flock(fd, LOCK_UN) }
        f()
        return true
    }

    /// Waits for every line recorded so far to be written (tests; Clear).
    func flush() { queue.sync {} }

    /// Turns the switch on or off on the log's queue, never on the caller's thread; `done` (on the main queue) once it
    /// is written, with the switch as it is then.
    func setEnabled(_ on: Bool, done: ((Bool) -> Void)? = nil) {
        queue.async { [self] in
            setSwitch(on)
            let now = enabled
            if let done { DispatchQueue.main.async { done(now) } }
        }
    }

    private func setSwitch(_ on: Bool) {
        let off = dir.appendingPathComponent(Self.offFile)
        if on {
            if FileManager.default.fileExists(atPath: off.path), (try? FileManager.default.removeItem(at: off)) == nil { failedWrites += 1 }
        } else {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.createFile(atPath: off.path, contents: Data()) { failedWrites += 1 }
        }
    }

    /// Removes both logs of both processes (the switch stays as it is), under the lock, moving the generation on:
    /// what either process recorded before it is never written after it. On the log's queue, never the caller's thread
    /// (the menu's: the main thread never waits on the other process); `done` (on the main queue): whether it was done
    /// -- false when the lock was not had within `lockWait`.
    func clear(done: ((Bool) -> Void)? = nil) { clear(attempt: 0, done: done) }

    private func clear(attempt: Int, done: ((Bool) -> Void)?) {
        queue.async { [self] in
            let ok = locked {
                let next = generation() + 1
                if (try? "\(next)\n".write(to: dir.appendingPathComponent(Self.genFile), atomically: true, encoding: .utf8)) == nil { failedWrites += 1 }
                for f in [Self.mainFile, Self.helperFile] {
                    for name in [f, f + ".1"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
                }
            }
            if !ok && attempt < clearRetries {
                // (the lock still held: again a little later, the queue free meanwhile for the writes)
                queue.asyncAfter(deadline: .now() + clearRetryEvery) { [self] in clear(attempt: attempt + 1, done: done) }
                return
            }
            if let done { DispatchQueue.main.async { done(ok) } }
        }
    }

    private func append(_ e: UIEvent, at t: Int, generation gen: Int) {
        guard enabled else { return }
        locked {
            // (recorded before a Clear that came since: dropped)
            guard generation() == gen else { return }
            write(e, at: t)
        }
    }

    private func write(_ e: UIEvent, at t: Int) {
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
    /// Off the caller's thread; `done` on the main queue (the switch as it is then; whether Clear was done).
    static func setEnabled(_ on: Bool, done: ((Bool) -> Void)? = nil) { log?.setEnabled(on, done: done) }
    static func clear(done: ((Bool) -> Void)? = nil) { log?.clear(done: done) }

    /// The funnel's call behind an activation: one made in the `activationWindow` seconds before it, else none.
    static let activationWindow = 1.0
    static func activation(funnel: (by: UIEvent.Activation, at: Double)?, now: Double) -> UIEvent.Activation {
        if let f = funnel, now - f.at >= 0, now - f.at <= activationWindow { return f.by }
        return .none
    }
}

extension UIEvent.CardKind {
    init(_ kind: String) { self = UIEvent.CardKind(rawValue: kind) ?? .other }
}
