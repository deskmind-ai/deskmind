// The harness engine's event stream, translated into the socket events the main app already reads.
//
// harness (`harness.mjs app-run`) writes one JSON event per line: start, preparing, plan, step, ask, waiting,
// resumed, ask_void, consent, refused, answer_given, task_done (src/protocol/events.ts in deskmind-ai/harness). Each becomes
// zero or more of the app's events (start/task, preparing, step, ask, ask_closed, task_done, done), plus three new
// ones the app may ignore until it shows them: plan, consent, refused. The ask event carries the whole card too (`card`), so a
// newer app can show typed options; an older one reads `question`/`options`/`approval` as before.
//
// Pure functions over dictionaries, so they are tested without a process (tests/DecisionTests.swift).

import Foundation

enum HarnessEvents {
    /// What a run needs to remember between lines: the open question's id (answers quote it) and the answer given.
    struct State {
        var askID: String? = nil
        var askOptions: [[String: Any]] = []
        var answer = ""
        var steps = 0
        var finished: [String: Any]? = nil   // the task_done we sent, for `done`
    }

    /// Card kinds that ask for permission rather than information: shown as an approval in the app (the hand icon,
    /// Deny / Approve). Styling only: what a button sends is decided by the button (`CardButton`), never by the kind.
    static let approvalKinds: Set<String> = ["plan", "action", "result_check"]

    /// One harness event → the app's events, updating `state`. `title` is the instruction (the task's title),
    /// `hasFolder` whether a folder was attached (the change list is shown only then).
    static func translate(_ e: [String: Any], state: inout State, title: String, hasFolder: Bool, pid: Int) -> [[String: Any]] {
        switch e["kind"] as? String {
        case "start":
            return [["event": "start", "set": "harness", "real": true, "pid": pid],
                    ["event": "task", "task": "do", "title": title]]
        case "preparing":
            return [["event": "preparing", "what": "looking"]]
        case "plan":
            return [["event": "plan", "steps": e["steps"] ?? []]]
        case "step":
            state.steps += 1
            let status = e["status"] as? String ?? "ok"
            let text = e["text"] as? String ?? ""
            return [["event": "step", "task": "do", "n": state.steps, "describe": text, "human": humanize(text),
                     "app": appOf(e["object"] as? String ?? ""), "shot": "", "detail": status == "ok" ? "" : status,
                     "ok": status == "ok" || status == "unverified", "consequence": e["consequence"] ?? "",
                     "object": e["object"] ?? "", "latency": 0]]
        case "ask":
            guard let card = e["card"] as? [String: Any] else { return [] }
            let options = card["options"] as? [[String: Any]] ?? []
            state.askID = e["ask_id"] as? String
            state.askOptions = options
            let kind = card["kind"] as? String ?? ""
            return [["event": "ask", "question": card["text"] as? String ?? "", "approval": approvalKinds.contains(kind),
                     "options": options.compactMap { $0["text"] as? String }, "card": card, "ask_id": e["ask_id"] ?? ""]]
        case "ask_void":
            // A card let go without an answer (the user changed the request, stopped, the app went away): it leaves
            // the window, and an answer to it is refused from here on.
            return closeCard(e, why: e["why"] as? String ?? "void", state: &state)
        case "waiting", "resumed":
            // waiting with an ask_id: the harness waits for the answer to a card, which the ask already shows.
            // resumed with one: that card is closed (answered, or voided: `voided`), and leaves the window.
            // Without one: the executor pauses while the user uses the Mac, and resumes — which is exactly what the
            // app's own "waiting" / "resumed" mean (the hands engine's HANDS_WAIT / HANDS_RESUME).
            if e["ask_id"] != nil {
                guard e["kind"] as? String == "resumed" else { return [] }
                return closeCard(e, why: e["voided"] as? String ?? "answered", state: &state)
            }
            return [["event": e["kind"] as? String ?? "waiting", "reason": "user_active"]]
        case "consent":
            return [["event": "consent", "object": e["object"] ?? "", "consequence": e["consequence"] ?? "",
                     "scope": e["scope"] ?? "", "picked": e["picked"] ?? NSNull()]]
        case "refused":
            // A refusal is shown as a step that did not happen, and kept as its own event for a newer app.
            state.steps += 1
            return [["event": "refused", "what": e["what"] ?? "", "why": e["why"] ?? "", "by": e["by"] ?? ""],
                    ["event": "step", "task": "do", "n": state.steps, "describe": e["what"] as? String ?? "",
                     "human": humanize(e["what"] as? String ?? ""), "app": "", "shot": "",
                     "detail": e["why"] as? String ?? "", "ok": false, "latency": 0]]
        case "answer_given":
            state.answer = e["text"] as? String ?? ""
            return []
        case "task_done":
            let status = e["status"] as? String ?? "failed"
            let done: [String: Any] = ["event": "task_done", "task": "do", "strict": status == "succeeded",
                                       "state": appState(status), "free": true, "reason": reason(status, e["reason"] as? String ?? ""),
                                       "answer": (e["answer"] as? String) ?? state.answer, "has_folder": hasFolder,
                                       "created": paths(e, "created"), "modified": paths(e, "modified"), "deleted": paths(e, "deleted"),
                                       "external": paths(e, "external"),
                                       "summary": e["summary"] ?? "", "harness_status": status, "detail": e["reason"] as? String ?? "",
                                       "result_card": e["result_card"] ?? NSNull(), "run_id": e["run_id"] ?? ""]
            state.finished = done
            return [done]
        default:
            return []   // kinds a newer harness adds are ignored, as the app ignores events it does not know
        }
    }

    /// The card `e["ask_id"]` is no longer open: the app's `ask_closed` (the window drops it if it shows that card),
    /// and the helper answers it no more.
    static func closeCard(_ e: [String: Any], why: String, state: inout State) -> [[String: Any]] {
        let id = e["ask_id"] as? String ?? ""
        if state.askID == id { state.askID = nil; state.askOptions = [] }
        return [["event": "ask_closed", "ask_id": id, "why": why]]
    }

    /// The file changes the harness reports (its executor's ledger: what the task created, changed, deleted, and what
    /// other programs changed meanwhile), as the app's lists.
    static func paths(_ e: [String: Any], _ key: String) -> [String] {
        ((e["changes"] as? [String: Any])?[key] as? [String]) ?? []
    }

    /// The closing `done` event, from the task_done we sent (or none: the process died first).
    static func done(state: State, terminationStatus: Int32, stopped: Bool, stderrTail: String) -> [String: Any] {
        let finished = state.finished
        let status = stopped ? "cancelled" : finished?["harness_status"] as? String ?? "errored"
        // Like `hands do`: a run that came to an end on its own is a result, not an error, whatever its status —
        // except an environment stop (the computer could not be read, the executor did not start): that is a
        // failure the user has to see the cause of, so it exits non-zero with the harness's words as the tail.
        let ranToAnEnd = finished != nil
        let environment = status == "environment"
        let exit = stopped ? 0 : environment ? 1 : ranToAnEnd ? 0 : Int(terminationStatus == 0 ? 1 : terminationStatus)
        let detail = finished?["detail"] as? String ?? ""
        return ["event": "done", "exit": exit,
                "reason": finished?["reason"] ?? (stopped ? "" : "harness exited"), "passed": status == "succeeded" ? 1 : 0, "total": 1,
                "answer": state.answer, "stderr_tail": stopped ? "" : environment ? (detail.isEmpty ? stderrTail : detail) : ranToAnEnd ? "" : stderrTail]
    }

    /// What the user did on a card. Each button says itself what it sends: an option button its own option (by its
    /// place among the options shown), Approve the card's approve option, Deny its way out, the field their words.
    /// The card's kind only picks which buttons are shown (deskmind#102: every option button used to be sent as
    /// "approve", so on a question card with an approve-kind option any click was sent as approval).
    enum CardButton: Hashable {
        case option(Int, String)   // the n-th option shown, and its text (the old helper and `hands do` read the text)
        case words(String)
        case approve               // an approval card's Approve
        case deny                  // an approval card's Deny

        /// The main app's `answer` request to the helper for this button, on the card `askID` (the one the window
        /// shows): the helper sends it only if that card is still the open one.
        func request(askID: String) -> [String: Any] {
            var r: [String: Any]
            switch self {
            case .option(let i, let text): r = ["op": "answer", "reply": text, "approve": false, "option": i]
            case .words(let text): r = ["op": "answer", "reply": text, "approve": false]
            case .approve: r = ["op": "answer", "reply": "", "approve": true]
            case .deny: r = ["op": "answer", "reply": "", "approve": false]
            }
            r["ask_id"] = askID
            return r
        }

        /// The helper's reading of an `answer` request: `option` when the app named one (this app); without it, an
        /// older app's reply and verdict — words are words (an option's text is that option), never an approval.
        init(request req: [String: Any]) {
            let reply = (req["reply"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = req["option"] as? Int { self = .option(i, reply) }
            else if !reply.isEmpty { self = .words(reply) }
            else { self = req["approve"] as? Bool == true ? .approve : .deny }
        }
    }

    /// The buttons a card shows: Deny and Approve on an approval card (`approvalKinds`), otherwise one per option and
    /// the field for words. A kind the app does not know is not an approval: its options are shown and sent as clicked.
    static func buttons(approval: Bool, options: [String]) -> [CardButton] {
        approval ? [.deny, .approve] : options.enumerated().map { CardButton.option($0.offset, $0.element) }
    }

    /// The options shown are the ones with a text, in the card's order (translate): the n-th shown → its index.
    static func shownOptions(_ state: State) -> [Int] {
        state.askOptions.indices.filter { state.askOptions[$0]["text"] is String }
    }

    /// Why an answer must not be sent to the open card, or nil. `askID` is the card the user answered (the one their
    /// window showed): a card that is no longer open (voided by a steer, already answered, replaced) is never answered
    /// for the open one -- Approve on an old plan card must not approve the new plan. An option button must also be
    /// the open card's option of that place and text.
    static func refusal(_ b: CardButton, askID: String?, state: State) -> String? {
        guard let open = state.askID else { return "no card is open" }
        if let a = askID, a != open { return "stale card: \(a) is not the open card \(open)" }
        if case .option(let n, let text) = b, !text.isEmpty {
            let shown = shownOptions(state)
            let same = shown.indices.contains(n)
                && (state.askOptions[shown[n]]["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !same { return "option \(n) of the open card is not \"\(text)\"" }
        }
        return nil
    }

    /// The user's answer, as the harness reads it: an option's index, or their own words. Nil when it is refused
    /// (`refusal`), or when the button has nothing on this card to send (Approve on a card with no approve option).
    /// The line names the card only when the request did (`askID`); an answer that names none (an older app) goes
    /// without, so the harness's own guard applies (after a voided card it answers nothing).
    static func answerLine(_ b: CardButton, askID: String?, state: State) -> [String: Any]? {
        guard refusal(b, askID: askID, state: state) == nil, let open = state.askID else { return nil }
        let line = { (more: [String: Any]) -> [String: Any] in askID == nil ? more : more.merging(["ask_id": open]) { a, _ in a } }
        let shown = shownOptions(state)
        let kind = { (i: Int) in state.askOptions[i]["kind"] as? String }
        switch b {
        case .option(let n, _):
            guard shown.indices.contains(n) else { return nil }
            return line(["option": shown[n]])
        case .approve:
            guard let i = state.askOptions.indices.first(where: { kind($0) == "approve" }) else { return nil }
            return line(["option": i])
        case .deny:
            // the way out the card offers: cancel, else the first option that is not approve (a result check's undo);
            // a card with nothing but approve is answered with nothing, which the harness reads as no
            if let i = state.askOptions.indices.first(where: { kind($0) == "cancel" })
                ?? state.askOptions.indices.first(where: { kind($0) != "approve" }) { return line(["option": i]) }
            return line([:])
        case .words(let w):
            let trimmed = w.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = shown.first(where: { state.askOptions[$0]["text"] as? String == trimmed }) { return line(["option": i]) }
            return trimmed.isEmpty ? nil : line(["text": trimmed])
        }
    }

    /// hands' run states the app knows, for the harness's statuses.
    static func appState(_ status: String) -> String {
        switch status {
        case "succeeded": return "completed"
        case "cancelled", "stopped": return "cancelled"
        case "environment": return "errored"
        case "unconfirmed": return "unconfirmed"
        default: return "gave_up"
        }
    }

    static func reason(_ status: String, _ reason: String) -> String {
        status == "environment" ? "environment" : reason
    }

    /// `window:com.apple.TextEdit#2153` → the app's bundle id, for the step's app column.
    static func appOf(_ object: String) -> String {
        guard object.hasPrefix("window:") else { return "" }
        let rest = object.dropFirst(7)
        return String(rest.split(separator: "#").first ?? "")
    }

    /// A step's text is the action as JSON (`{"kind":"click","target":"elem_55",…}`) or the file capability's
    /// description; the first is turned into a few words, the second kept.
    static func humanize(_ text: String) -> String {
        guard text.hasPrefix("{"), let d = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let kind = d["kind"] as? String else { return text }
        switch kind {
        case "click": return "click \(d["target"] ?? "")"
        case "set_value": return "set \(d["target"] ?? "") = \(d["value"] ?? "")"
        case "type": return "type \(d["text"] ?? "")"
        case "select": return "select \(d["option"] ?? "") in \(d["target"] ?? "")"
        case "key": return "press \(d["chord"] ?? "")"
        case "open_window": return "open \(d["app"] ?? "")"
        case "close_window": return "close window"
        case "focus_window": return "switch window"
        case "scroll": return "scroll"
        case "wait": return "wait"
        case "file": return "\(d["capability"] ?? "file") \(d["args"].map { String(describing: $0) } ?? "")"
        default: return kind
        }
    }
}

// MARK: - A child process's end, made sure of

/// Ending a run's process for certain, with everything it started: the harness (node) runs hands' executor (Python)
/// under it, and the executor is what changes files -- a node that exits leaves an executor that may still be acting.
/// Its members are its process group (Process starts a child in a group of its own, which node's children share) and
/// its descendants (one that made a group of its own), each known by pid and start time, as pids are reused.
enum HarnessProcess {
    struct Member: Hashable { let pid: pid_t; let start: UInt64 }

    /// The process `pid` is now, or nil when there is none or it has exited (a zombie is gone: it can act no more).
    static func member(_ pid: pid_t) -> Member? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != SZOMB else { return nil }
        return Member(pid: pid, start: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec)
    }

    /// The pids `proc_listpids` lists of a kind (PROC_PGRP_ONLY: a group's; PROC_PPID_ONLY: a parent's children).
    private static func list(_ type: UInt32, _ of: pid_t) -> [pid_t] {
        let bytes = proc_listpids(type, UInt32(of), nil, 0)
        guard bytes > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 32)
        let got = proc_listpids(type, UInt32(of), &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return got > 0 ? buf.prefix(Int(got) / MemoryLayout<pid_t>.size).filter { $0 > 0 } : []
    }

    /// One run's processes -- the harness, its process group, its descendants -- recorded from the moment it starts
    /// until every one of them is confirmed gone (HarnessRun.trees). Refreshed while they are up, so a child whose
    /// parent then exits (out of the group, no parent to find it by) is still known.
    final class Tree {
        let process: Process
        private var members = Set<Member>()
        /// The harness gone and its group seen empty: never read by that id again (an emptied group cannot come
        /// back, and its id may then be another process's group).
        private var groupEnded = false
        private let lock = NSLock()
        init(_ process: Process) { self.process = process }

        var known: Set<Member> { lock.lock(); defer { lock.unlock() }; return members }
        /// Look again at who is up.
        func refresh() { lock.lock(); defer { lock.unlock() }; look() }
        /// The harness and every member gone (looked again first).
        var gone: Bool { lock.lock(); defer { lock.unlock() }; look(); return !process.isRunning && members.isEmpty }

        // Who is up: the group and the descendants of every member known (one whose parent is gone is still known).
        // A member gone, or its pid taken by another process, is dropped first: never descended from, never
        // signalled. The group is read until, the harness gone, it is seen empty (`groupEnded`), and not while another
        // process holds the harness's pid: the kernel gives no process a pid that is a live group's id, so a group by
        // that id is then another's. A child that leaves the group and whose parent exits between two looks (0.25 s
        // apart, HarnessRun.record) is not seen: polling's limit. Under `lock`.
        private func look() {
            let p = process, root = p.processIdentifier
            members = members.filter { member($0.pid) == $0 }
            var found: [Member] = []
            if !groupEnded && (p.isRunning || member(root) == nil || members.contains(where: { getpgid($0.pid) == root })) {
                let group = list(UInt32(PROC_PGRP_ONLY), root)
                if group.isEmpty && !p.isRunning { groupEnded = true }
                found = group.compactMap(member)
            }
            var queue = (p.isRunning ? [root] : []) + members.map(\.pid) + found.map(\.pid)
            var seen = Set<pid_t>()
            while let pid = queue.popLast() {
                guard seen.insert(pid).inserted else { continue }
                for c in list(UInt32(PROC_PPID_ONLY), pid) { if let m = member(c) { found.append(m); queue.append(c) } }
            }
            members = members.union(found).filter { $0.pid != root }
        }

        /// End them all: `close` first (the run's stdin closed: it exits by itself), wait up to `grace` s; then SIGTERM
        /// to every one still up, wait up to `term` s; then SIGKILL, wait up to `kill` s. True once all are gone;
        /// false when one is still up after all that (no next run may start; the members found are kept for the next
        /// attempt). `signal`: kill(2) (a test hands in one that does nothing).
        func end(close: () -> Void, grace: Double, term: Double, kill: Double,
                 signal: (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) }) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let p = process, root = p.processIdentifier
            func gone() -> Bool { look(); return !p.isRunning && members.isEmpty }
            func wait(_ seconds: Double) -> Bool {
                let until = Date().addingTimeInterval(seconds)
                while !gone() {
                    if Date() >= until { return false }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                return true
            }
            look()    // before stdin is closed: a child is known even if the harness is gone the moment after
            close()
            if wait(grace) { return true }
            for (sig, seconds) in [(SIGTERM, term), (SIGKILL, kill)] {
                if p.isRunning { _ = signal(root, sig) }
                for m in members where member(m.pid) == m { _ = signal(m.pid, sig) }
                if wait(seconds) { return true }
            }
            return false
        }
    }
}
