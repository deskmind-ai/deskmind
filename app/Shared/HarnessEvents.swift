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

    /// Card kinds that ask for permission rather than information: shown as an approval in the app.
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
            // After an ask the harness says it waits for the answer; the app's "waiting" means the user is busy at the
            // Mac, which is not this. Nothing to say.
            return []
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

    /// The user's answer, as the harness reads it: an option's index, or their own words.
    static func answerLine(reply: String, approve: Bool, state: State) -> [String: Any]? {
        guard let id = state.askID else { return nil }
        let texts = state.askOptions.compactMap { $0["text"] as? String }
        if approve, let i = state.askOptions.firstIndex(where: { ($0["kind"] as? String) == "approve" }) { return ["ask_id": id, "option": i] }
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = texts.firstIndex(of: trimmed) { return ["ask_id": id, "option": i] }
        if trimmed.isEmpty { return approve ? nil : ["ask_id": id, "option": state.askOptions.firstIndex(where: { ($0["kind"] as? String) == "cancel" }) ?? 0] }
        return ["ask_id": id, "text": trimmed]
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
