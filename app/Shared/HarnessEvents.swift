// The harness engine's event stream, translated into the socket events the main app already reads.
//
// harness (`harness.mjs app-run`) writes one JSON event per line: start, preparing, plan, step, ask, waiting,
// resumed, consent, refused, answer_given, task_done (src/protocol/events.ts in deskmind-ai/harness). Each becomes
// zero or more of the app's events (start/task, preparing, step, ask, task_done, done), plus three new ones the app
// may ignore until it shows them: plan, consent, refused. The ask event carries the whole card too (`card`), so a
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
        case "waiting", "resumed":
            // With an ask_id: the harness waits for the answer to a card, which the ask already shows — nothing to say.
            // Without one: the executor pauses while the user uses the Mac, and resumes — which is exactly what the
            // app's own "waiting" / "resumed" mean (the hands engine's HANDS_WAIT / HANDS_RESUME).
            if e["ask_id"] != nil { return [] }
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

        /// The main app's `answer` request to the helper for this button.
        var request: [String: Any] {
            switch self {
            case .option(let i, let text): return ["op": "answer", "reply": text, "approve": false, "option": i]
            case .words(let text): return ["op": "answer", "reply": text, "approve": false]
            case .approve: return ["op": "answer", "reply": "", "approve": true]
            case .deny: return ["op": "answer", "reply": "", "approve": false]
            }
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

    /// The user's answer, as the harness reads it: an option's index, or their own words. Nil when nothing is asked,
    /// or when the button has nothing on this card to send (Approve on a card with no approve option).
    static func answerLine(_ b: CardButton, state: State) -> [String: Any]? {
        guard let id = state.askID else { return nil }
        // the options shown are the ones with a text, in the card's order (translate): the n-th shown → its index
        let shown = state.askOptions.indices.filter { state.askOptions[$0]["text"] is String }
        let kind = { (i: Int) in state.askOptions[i]["kind"] as? String }
        switch b {
        case .option(let n, _):
            guard shown.indices.contains(n) else { return nil }
            return ["ask_id": id, "option": shown[n]]
        case .approve:
            guard let i = state.askOptions.indices.first(where: { kind($0) == "approve" }) else { return nil }
            return ["ask_id": id, "option": i]
        case .deny:
            // the way out the card offers: cancel, else the first option that is not approve (a result check's undo);
            // a card with nothing but approve is answered with nothing, which the harness reads as no
            if let i = state.askOptions.indices.first(where: { kind($0) == "cancel" })
                ?? state.askOptions.indices.first(where: { kind($0) != "approve" }) { return ["ask_id": id, "option": i] }
            return ["ask_id": id]
        case .words(let w):
            let trimmed = w.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = shown.first(where: { state.askOptions[$0]["text"] as? String == trimmed }) { return ["ask_id": id, "option": i] }
            return trimmed.isEmpty ? nil : ["ask_id": id, "text": trimmed]
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
