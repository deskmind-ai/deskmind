// The user's labels on judge answers (M5, plan §11.2): 「对 / 不对」 and a note, in `annotations/<run_id>.jsonl` on this
// Mac only -- one line per label, a change is a new line, the last line of a judge_id counts. Each line carries a copy
// of the question's material (`sample`: the question, its kind, the prompt and options when the trace had them, what
// every tier answered), so a label still shows whole after its run's records were taken (RunRetention never touches
// this folder). Nothing here is sent anywhere; a prompt (the user's words, their windows' text) is written only here
// and to the file the user exports to.

import Foundation

enum Annotations {
    enum Label: String, Codable { case right, wrong }

    /// The question as the judge view showed it when it was labelled (RunDir.Judge): what a label is about.
    struct Sample: Codable, Equatable {
        struct Tier: Codable, Equatable { var tier: String; var outcome: String; var choice: String?; var confidence: Double?; var settled: Bool }
        var question: String
        var question_kind: String?
        /// nil: the trace had no judge.asked for it (an older run, or its records were taken first): 「原文未保存」.
        var prompt: String?
        var prompt_cut: Bool?
        var options: [RunDir.Judge.Option]?
        var answer: String?
        var by: String?
        var confidence: Double?
        var tiers: [Tier]
        var shadow_top: String?
        var shadow_agree: Bool?
    }

    struct Line: Codable, Equatable {
        var judge_id: String
        var run_id: String
        var label: Label
        var note: String?
        /// Seconds since 1970.
        var at: Double
        var sample: Sample
    }

    static func sample(_ j: RunDir.Judge) -> Sample {
        Sample(question: j.question, question_kind: j.kind, prompt: j.prompt, prompt_cut: j.prompt == nil ? nil : j.promptCut,
               options: j.options, answer: j.answer, by: j.by, confidence: j.confidence,
               tiers: j.tiers.map { Sample.Tier(tier: $0.tier, outcome: $0.outcome, choice: $0.choice, confidence: $0.confidence, settled: $0.settled) },
               shadow_top: j.shadow?.top, shadow_agree: j.shadow?.agree)
    }

    static func folder(support: URL = DeskMindIPC.supportDir) -> URL { support.appendingPathComponent("annotations") }
    static func file(_ runId: String, support: URL = DeskMindIPC.supportDir) -> URL {
        folder(support: support).appendingPathComponent(runId + ".jsonl")
    }

    /// One label, appended (the folder made when it is not there). False: not written.
    @discardableResult
    static func add(_ l: Line, support: URL = DeskMindIPC.supportDir) -> Bool {
        guard RunId.valid(l.run_id), let data = try? JSONEncoder.sorted.encode(l) else { return false }
        let fm = FileManager.default
        let dir = folder(support: support), f = file(l.run_id, support: support)
        // (the user's words and their windows' text: this user's only -- the folder 0700, the file 0600)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: f.path) { fm.createFile(atPath: f.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let h = try? FileHandle(forWritingTo: f) else { return false }
        defer { try? h.close() }
        do { try h.seekToEnd(); try h.write(contentsOf: data + Data("\n".utf8)); return true } catch { return false }
    }

    /// Every line of the run's file as written (a torn or foreign line skipped).
    static func lines(_ runId: String, support: URL = DeskMindIPC.supportDir) -> [Line] {
        guard RunId.valid(runId), let text = try? String(contentsOf: file(runId, support: support), encoding: .utf8) else { return [] }
        return parse(text)
    }
    static func parse(_ text: String) -> [Line] {
        text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Line.self, from: Data($0.utf8)) }
    }

    /// The label that counts for each judge question: its last line, in the order they were first labelled.
    static func current(_ lines: [Line]) -> [Line] {
        var order: [String] = [], last: [String: Line] = [:]
        for l in lines {
            if last[l.judge_id] == nil { order.append(l.judge_id) }
            last[l.judge_id] = l
        }
        return order.compactMap { last[$0] }
    }

    /// The run's file as it is, for the user's export (written where they chose: never by this app on its own).
    static func export(_ runId: String, to url: URL, support: URL = DeskMindIPC.supportDir) -> Bool {
        guard RunId.valid(runId), let d = try? Data(contentsOf: file(runId, support: support)) else { return false }
        return (try? d.write(to: url, options: .atomic)) != nil
    }

    /// A label as the labels view shows it (invariant 12): all of it from the line's own copy, nothing from the run's
    /// folder -- the question, its answer and who settled it, the prompt (nil: 原文未保存), every option, every tier's
    /// answer, the shadow comparison, the label and the note.
    struct Shown: Equatable {
        var question: String
        var answer: String?
        var by: String?
        var prompt: String?
        var options: [String]
        var tiers: [String]
        var shadow: String?
        var label: Label
        var note: String?
    }
    static func shown(_ l: Line) -> Shown {
        let s = l.sample
        return Shown(question: s.question, answer: s.answer, by: s.by, prompt: s.prompt,
                     options: (s.options ?? []).map { "\($0.id): \($0.text)" },
                     tiers: s.tiers.map { RunDir.Judge.Tier(tier: $0.tier, outcome: $0.outcome, choice: $0.choice, confidence: $0.confidence, settled: $0.settled).line },
                     shadow: s.shadow_top.map { top in "\(top)\(s.shadow_agree.map { $0 ? " =" : " ≠" } ?? "")" },
                     label: l.label, note: l.note)
    }

    /// How many labels the run has (a problem report may say this much, nothing more).
    static func count(_ runId: String, support: URL = DeskMindIPC.supportDir) -> Int { current(lines(runId, support: support)).count }
}

extension JSONEncoder {
    /// Keys sorted: the same line for the same label.
    static var sorted: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }
}
