// What the decision panel shows for a step, worked out from the helper's step event -- Foundation only, so the unit
// tests (tests/DecisionTests.swift) run it without a screen. And the name a run's recording gets.

import Foundation

struct DecisionStep: Equatable {
    struct Bar: Equatable {
        let name: String
        let p: Double
    }

    var n = 0
    /// "Open · 贝加尔湖畔（Live） · 李健": the operation in words, and its target.
    var headline = ""
    /// The three likeliest operations, as the planner weighed them.
    var top: [Bar] = []
    /// Which model answered: "0.8B", or "4B · <why it was asked>"; empty if the record does not say.
    var tier = ""
    /// The planner's own time for the step, in milliseconds (hands' latency_s).
    var ms = 0
    var question = ""
    var answer = ""

    /// From a step event: {"n", "describe", "target", "latency", "detail", "decision": hands' JSON record with
    /// "top" [[op, p], ...], "operation" and "routing" {"by": "fast"|"strong", "reason"}}.
    static func parse(_ e: [String: Any], lang: ResolvedLang, previous: Int = 0) -> DecisionStep {
        var s = DecisionStep()
        let d = (e["decision"] as? String).flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        } ?? [:]
        s.n = (e["n"] as? NSNumber)?.intValue ?? previous + 1
        let describe = e["describe"] as? String ?? ""
        let op = (d["operation"] as? String) ?? describe.components(separatedBy: " ").first ?? ""
        let target = (e["target"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        s.headline = target.isEmpty ? opName(op, lang) : "\(opName(op, lang)) · \(target.prefix(40))"
        s.top = ((d["top"] as? [[Any]]) ?? []).compactMap { pair in
            guard pair.count == 2, let k = pair[0] as? String else { return nil }
            return Bar(name: opName(k, lang), p: (pair[1] as? NSNumber)?.doubleValue ?? 0)
        }
        let routing = d["routing"] as? [String: Any] ?? [:]
        switch routing["by"] as? String {
        case "strong": s.tier = L("4B · %@", reason(routing["reason"] as? String ?? "", lang), lang: lang)
        case "fast": s.tier = "0.8B"
        default: s.tier = ""
        }
        s.ms = Int((((e["latency"] as? NSNumber)?.doubleValue) ?? 0) * 1000)
        if ["ask_user", "request_approval"].contains(describe) {
            let parts = (e["detail"] as? String ?? "").components(separatedBy: " → ")
            s.question = parts.first ?? ""
            s.answer = parts.count > 1 ? parts[1] : ""
        }
        return s
    }

    /// The operation in words. Its own table: several of these words already mean something else in L10n's.
    static func opName(_ op: String, _ lang: ResolvedLang) -> String {
        let names: [String: (String, String)] = [
            "CLICK": ("Click", "点击"), "CLICK_ON": ("Click", "点击"), "OPEN": ("Open", "打开"),
            "DOUBLE_CLICK": ("Open", "打开"), "TYPE_TEXT": ("Type", "输入"), "APPEND_TEXT": ("Type", "输入"),
            "REPLACE_TEXT": ("Replace", "替换"), "SCROLL": ("Scroll", "滚动"), "KEY": ("Key", "按键"),
            "DONE": ("Done", "完成"), "ANSWER": ("Answer", "回答"), "ASK": ("Ask", "提问"), "ASK_USER": ("Ask", "提问"),
            "FOCUS_WINDOW": ("Switch", "切换"), "FOCUS_APP": ("Switch", "切换"), "SELECT": ("Choose", "选择"),
            "BLOCKED": ("Stuck", "卡住"),
        ]
        guard let n = names[op.uppercased()] else { return op.capitalized }
        return lang == .zhHans ? n.1 : n.0
    }

    static func reason(_ r: String, _ lang: ResolvedLang) -> String {
        switch r {
        case "low_conf": return L("0.8B unsure", lang: lang)
        case "risky_DONE": return L("checking before done", lang: lang)
        case "risky_KEY": return L("checking a key", lang: lang)
        default: return r.replacingOccurrences(of: "_", with: " ")
        }
    }
}

enum RecordingSize {
    /// A delivery copy's longer side (the master is recorded at the screen's own size).
    static let maxLong = 1920

    /// The movie's pixel size for content of `width`×`height` points at `scale` pixels per point: full size, or
    /// scaled down (never up) so the longer side is at most `maxLong`; both even, as the encoder wants.
    static func pixels(width: Double, height: Double, scale: Double, maxLong: Int?) -> (Int, Int) {
        var w = width * scale, h = height * scale
        if let m = maxLong, max(w, h) > Double(m) {
            let k = Double(m) / max(w, h)
            w *= k; h *= k
        }
        return (max(2, Int(w.rounded()) / 2 * 2), max(2, Int(h.rounded()) / 2 * 2))
    }
}

enum MovieName {
    /// A recording's folder: "<yyyy-MM-dd HH.mm.ss> <the instruction's first 30 characters>" (see ScreenRecorder).
    static func folder(goal: String, date: Date) -> String {
        String(file(goal: goal, date: date).dropLast(4))
    }

    /// "<yyyy-MM-dd HH.mm.ss> <the instruction's first 30 characters>.mov", with nothing a path could trip on.
    static func file(goal: String, date: Date) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let words = goal.replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = "\(stamp.string(from: date)) \(String(words.prefix(30)))".trimmingCharacters(in: .whitespaces)
        return name + ".mov"
    }
}

/// steps.json from a run's trace (hands' trace.jsonl): each step's times in milliseconds from the recording's first
/// frame (t0, epoch seconds), where it acted on the screen, and what the planner weighed -- what an edit of the
/// recording is lined up and drawn from.
enum RecordingSteps {
    static func from(trace: String, t0: Double) -> (steps: [[String: Any]], state: String) {
        var out: [[String: Any]] = []
        var state = ""
        var lastObs: Double?
        func ms(_ v: Any?) -> Any {
            guard let t = (v as? NSNumber)?.doubleValue, t > 0 else { return NSNull() }
            return Int(((t - t0) * 1000).rounded())
        }
        for line in trace.split(separator: "\n") {
            guard let r = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            switch r["t"] as? String {
            case "obs": lastObs = (r["ts"] as? NSNumber)?.doubleValue
            case "summary": state = r["state"] as? String ?? ""
            case "step":
                let d = (r["decision"] as? String).flatMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                } ?? [:]
                let action = r["action"] as? [String: Any] ?? [:]
                let op = (d["operation"] as? String) ?? (action["kind"] as? String)?.uppercased()
                    ?? (r["kind"] as? String)?.uppercased() ?? ""
                let routing = d["routing"] as? [String: Any] ?? [:]
                let tier: Any = switch routing["by"] as? String {
                case "fast": "0.8B"
                case "strong": "4B"
                default: NSNull()
                }
                let start = (r["t_obs_start"] as? NSNumber)?.doubleValue
                let end = ((r["t_act_end"] ?? r["t_decide_end"]) as? NSNumber)?.doubleValue
                var s: [String: Any] = [
                    "n": r["n"] ?? out.count + 1, "operation": op,
                    "target": (r["target_label"] as? String ?? "").replacingOccurrences(of: "\n", with: " "),
                    "target_rect": r["target_rect"] ?? NSNull(),
                    "top": d["top"] ?? NSNull(), "tier": tier, "reason": routing["reason"] ?? NSNull(),
                    "t_obs_ms": ms(start ?? lastObs), "t_seen_ms": ms(lastObs),
                    "t_decide_start_ms": ms(r["t_decide_start"]), "t_decide_end_ms": ms(r["t_decide_end"]),
                    "t_act_start_ms": ms(r["t_act_start"]), "t_act_end_ms": ms(r["t_act_end"]),
                    "wall_ms": (start != nil && end != nil) ? Int(((end! - start!) * 1000).rounded()) : NSNull(),
                    "ok": r["ok"] ?? NSNull(),
                ]
                if let q = r["question"] {
                    s["question"] = q; s["reply"] = r["reply"] ?? NSNull()
                    // When the answer came (hands' t_reply): where the picture goes from the question to the work.
                    s["t_reply_ms"] = ms(r["t_reply"])
                }
                out.append(s)
            default: break
            }
        }
        return (out, state)
    }
}

/// Which display a run's recording shows. Foundation only, so the unit tests run it (tests/DecisionTests.swift).
enum RecordingDisplay {
    /// `requested` if it is one of `displays`; else the display with the most task-window area, when any task
    /// window is on screen (a run on a virtual display is recorded there, not on the user's screen); else `main`.
    static func pick(displays: [UInt32], taskArea: [UInt32: Double], requested: UInt32?, main: UInt32,
                     wholeScreen: Bool) -> UInt32? {
        if let r = requested, displays.contains(r) { return r }
        if !wholeScreen, let best = displays.max(by: { (taskArea[$0] ?? 0) < (taskArea[$1] ?? 0) }),
           (taskArea[best] ?? 0) > 0 {
            return best
        }
        return displays.contains(main) ? main : displays.first
    }

    /// Whether a recording on `current` should move to `candidate`: only to a different display that holds task
    /// windows while `current` holds none of them (the task opened there), so a window dragged half across does
    /// not make the picture jump back and forth.
    static func shouldMove(current: UInt32, candidate: UInt32, taskArea: [UInt32: Double]) -> Bool {
        candidate != current && (taskArea[candidate] ?? 0) > 0 && (taskArea[current] ?? 0) == 0
    }
}
