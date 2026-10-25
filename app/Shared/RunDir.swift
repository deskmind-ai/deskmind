// A task's run folder, read for the right column's 「过程」 tab (M5, plan §11): `runs/<run_id>/` -- its protocol events
// (events.jsonl), the executor's trace (trace.jsonl), the pictures (shots/) -- read once each and joined by step_id and
// judge_id, pure. Nothing here is guessed or put together from two sources that disagree: a value is the one record's,
// and a cell whose record is not there is nil (the pane says 「没有记录」). Read only: nothing is written, nothing sent.
//
// | view      | from                                                                                              |
// |-----------|---------------------------------------------------------------------------------------------------|
// | timeline  | events: step (step_id, plan_step, human/text), step_result (status, why, shot), shot_ready (shot); |
// |           |   trace: executor.act (epoch_reason, changed) by step_id; a shot only when its file is there       |
// | judges    | events: judge; trace: judge.asked (prompt, options) by judge_id (harness#76; before it: none)     |
// | cost      | events: model_call, by role (role "loop" the acting model), and by step                           |
// | changes   | events: task_done.changes (else the last `changes`), result_response (the undo); trace:            |
// |           |   executor.files_written / files_not_credited / external_change / window_created                  |
//
// The folder's state: running (events, no task_done), ended, pruned (the retention pass took its records: RunRetention's
// marker), none (no folder or no events: an old version, the command line).

import Foundation

enum RunDir {
    /// The files of one run folder, as read (nil: not there).
    struct Files: Equatable {
        var events: String?
        var trace: String?
        /// The names under shots/.
        var shots: Set<String> = []
        /// The retention pass took this run's records (RunRetention.marker).
        var pruned = false
    }

    enum State: Equatable { case none, running, ended, pruned }

    struct Step: Equatable {
        var stepId: String
        var planStep: Int?
        /// The step in the user's words (step.human), else its text.
        var words: String
        var status: String?
        var why: String?
        /// The picture's path relative to the run folder, only when the file is there.
        var shot: String?
        /// The trace's executor.act for it (nil: no trace, or none for this step).
        var act: Act?
    }
    struct Act: Equatable {
        var status: String
        var epochReason: String?
        /// `changed` as recorded (its JSON, keys sorted).
        var changed: String?
    }

    struct Judge: Equatable {
        struct Tier: Equatable { var tier: String; var outcome: String; var choice: String?; var confidence: Double?; var settled: Bool }
        struct Shadow: Equatable { var tier: String; var top: String?; var agree: Bool? }
        struct Option: Equatable, Codable { var id: String; var text: String }
        var judgeId: String
        var question: String
        var answer: String?
        var by: String?
        var confidence: Double?
        var tiers: [Tier]
        var shadow: Shadow?
        var ms: Int?
        var stepId: String?
        /// From the trace's judge.asked: the kind, the prompt and the options the tiers were given (nil: no record).
        var kind: String?
        var prompt: String?
        var options: [Option]?
        /// The trace cut the prompt (judge.asked `cut`).
        var promptCut = false
    }

    struct CostRow: Equatable {
        var role: String
        var calls: Int
        var tokensIn: Int
        var tokensOut: Int
        var costUSD: Double
        /// The median latency of its calls, ms.
        var medianMs: Int
    }

    struct Changes: Equatable {
        var created: [String] = []
        var modified: [String] = []
        var deleted: [String] = []
        var external: [String] = []
        var unconfirmed: [String] = []
        /// From task_done (true) or the last `changes` event while running (false).
        var final = false
        /// The undo's result (result_response): effect, undone of total (nil: no undo answered).
        var undo: (effect: String, undone: Int?, total: Int?)?
        /// The trace's own lists (nil: no trace).
        var filesWritten: [String]?
        var notCredited: [String]?
        var externalChange: [String]?
        var windowsCreated: [String]?

        static func == (a: Changes, b: Changes) -> Bool {
            a.created == b.created && a.modified == b.modified && a.deleted == b.deleted && a.external == b.external
                && a.unconfirmed == b.unconfirmed && a.final == b.final && a.undo?.effect == b.undo?.effect
                && a.undo?.undone == b.undo?.undone && a.undo?.total == b.undo?.total && a.filesWritten == b.filesWritten
                && a.notCredited == b.notCredited && a.externalChange == b.externalChange && a.windowsCreated == b.windowsCreated
        }
    }

    struct Model: Equatable {
        var state: State
        var steps: [Step] = []
        var judges: [Judge] = []
        /// By role, the acting model's ("loop") first, then the others by name.
        var cost: [CostRow] = []
        /// By step id: its calls by role.
        var costByStep: [String: [CostRow]] = [:]
        /// nil: no record of any change (no task_done.changes, no changes event).
        var changes: Changes?
        /// The trace was there (its cells are records or say there are none).
        var hasTrace = false

        static let none = Model(state: .none)
    }

    // MARK: reading

    /// The run folder's files, read once each (the only I/O here). A folder that is not there: none.
    static func files(at folder: URL) -> Files {
        let fm = FileManager.default
        func text(_ name: String) -> String? { try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) }
        let shots = Set((try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent("shots").path)) ?? [])
        return Files(events: text("events.jsonl"), trace: text("trace.jsonl"), shots: shots,
                     pruned: fm.fileExists(atPath: folder.appendingPathComponent(RunRetention.marker).path))
    }

    static func lines(_ text: String?) -> [[String: Any]] {
        (text ?? "").split(separator: "\n").compactMap { l in
            (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any]
        }
    }

    /// The model the pane draws, from `f` alone.
    static func model(_ f: Files) -> Model {
        let events = lines(f.events)
        if f.pruned { return Model(state: .pruned) }
        guard !events.isEmpty else { return .none }
        let done = events.last { $0["kind"] as? String == "task_done" }
        var m = Model(state: done != nil ? .ended : .running)
        let trace = f.trace.map { lines($0) }
        m.hasTrace = trace != nil
        let t = trace ?? []

        // timeline: the steps in the order they began; their results and pictures by step id
        var acts: [String: Act] = [:]
        for l in t where l["kind"] as? String == "executor.act" {
            guard let id = l["step_id"] as? String else { continue }
            acts[id] = Act(status: str(l["status"]) ?? "", epochReason: str(l["epoch_reason"]), changed: l["changed"].map(json))
        }
        var index: [String: Int] = [:]
        for e in events {
            guard let id = e["step_id"] as? String else { continue }
            switch e["kind"] as? String {
            case "step":
                guard index[id] == nil else { continue }
                index[id] = m.steps.count
                m.steps.append(Step(stepId: id, planStep: e["plan_step"] as? Int, words: str(e["human"]) ?? str(e["text"]) ?? "",
                                    act: trace == nil ? nil : acts[id]))
            case "step_result":
                guard let i = index[id] else { continue }
                m.steps[i].status = str(e["status"]); m.steps[i].why = str(e["why"]).flatMap { $0.isEmpty ? nil : $0 }
                if let s = str(e["shot"]), f.shots.contains(shotName(s)) { m.steps[i].shot = s }
            case "shot_ready":
                guard let i = index[id], let s = str(e["shot"]), f.shots.contains(shotName(s)) else { continue }
                m.steps[i].shot = s
            default: break
            }
        }

        // judges: the protocol's judge event, its material from the trace's judge.asked
        var asked: [String: [String: Any]] = [:]
        for l in t where l["kind"] as? String == "judge.asked" { if let id = l["judge_id"] as? String { asked[id] = l } }
        for e in events where e["kind"] as? String == "judge" {
            guard let id = e["judge_id"] as? String else { continue }
            var j = Judge(judgeId: id, question: str(e["question"]) ?? "", answer: str(e["answer"]), by: str(e["by"]),
                          confidence: num(e["confidence"]), tiers: ((e["tiers"] as? [[String: Any]]) ?? []).map {
                              Judge.Tier(tier: str($0["tier"]) ?? "", outcome: str($0["outcome"]) ?? "", choice: str($0["choice"]),
                                         confidence: num($0["confidence"]), settled: ($0["settled"] as? Bool) ?? false)
                          },
                          shadow: (e["shadow"] as? [String: Any]).map { Judge.Shadow(tier: str($0["tier"]) ?? "", top: str($0["top"]), agree: $0["agree"] as? Bool) },
                          ms: (e["ms"] as? NSNumber)?.intValue, stepId: str(e["step_id"]))
            if let a = asked[id] {
                j.kind = str(a["question_kind"]); j.prompt = str(a["prompt"]); j.promptCut = (a["cut"] as? Bool) ?? false
                j.options = (a["options"] as? [[String: Any]])?.compactMap { o in str(o["id"]).map { Judge.Option(id: $0, text: str(o["text"]) ?? "") } }
            }
            m.judges.append(j)
        }

        // cost: every model call, by role and by step
        let calls = events.filter { $0["kind"] as? String == "model_call" }
        m.cost = rows(calls)
        for (step, cs) in Dictionary(grouping: calls.filter { $0["step_id"] is String }, by: { $0["step_id"] as! String }) { m.costByStep[step] = rows(cs) }

        // changes: task_done's, else the last changes event; the undo's answer; the trace's lists
        let lastChanges = events.last { $0["kind"] as? String == "changes" }
        if let c = (done?["changes"] as? [String: Any]) ?? lastChanges {
            var ch = Changes(created: list(c["created"]), modified: list(c["modified"]), deleted: list(c["deleted"]),
                             external: list(c["external"]), unconfirmed: list(c["unconfirmed"]), final: done?["changes"] != nil)
            if let r = events.last(where: { $0["kind"] as? String == "result_response" }), let effect = str(r["effect"]) {
                ch.undo = (effect, (r["undone"] as? NSNumber)?.intValue, (r["total"] as? NSNumber)?.intValue)
            }
            if trace != nil {
                func paths(_ kind: String) -> [String] { t.filter { $0["kind"] as? String == kind }.flatMap { list($0["paths"]) } }
                ch.filesWritten = paths("executor.files_written"); ch.notCredited = paths("executor.files_not_credited")
                ch.externalChange = paths("executor.external_change")
                ch.windowsCreated = t.filter { $0["kind"] as? String == "executor.window_created" }.compactMap { str($0["id"]) }
            }
            m.changes = ch
        }
        return m
    }

    /// A step's picture by its name under shots/ (the event says it relative to the run folder: "shots/3.png").
    static func shotName(_ s: String) -> String { (s as NSString).lastPathComponent }

    private static func rows(_ calls: [[String: Any]]) -> [CostRow] {
        let by = Dictionary(grouping: calls, by: { str($0["role"]) ?? "" })
        return by.keys.sorted { ($0 == "loop" ? 0 : 1, $0) < ($1 == "loop" ? 0 : 1, $1) }.map { role in
            let cs = by[role]!
            let ms = cs.compactMap { ($0["latency_ms"] as? NSNumber)?.intValue }.sorted()
            return CostRow(role: role, calls: cs.count, tokensIn: cs.reduce(0) { $0 + (($1["tokens_in"] as? NSNumber)?.intValue ?? 0) },
                           tokensOut: cs.reduce(0) { $0 + (($1["tokens_out"] as? NSNumber)?.intValue ?? 0) },
                           costUSD: cs.reduce(0) { $0 + (num($1["cost_usd"]) ?? 0) }, medianMs: ms.isEmpty ? 0 : ms[(ms.count - 1) / 2])
        }
    }

    private static func str(_ v: Any?) -> String? { v as? String }
    private static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    private static func list(_ v: Any?) -> [String] { (v as? [Any])?.compactMap { $0 as? String } ?? [] }
    static func json(_ v: Any) -> String {
        if let s = v as? String { return s }
        guard JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) else { return "\(v)" }
        return String(decoding: d, as: UTF8.self)
    }
}
