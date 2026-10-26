// The 「过程」 tab's pure parts (M5, plan §11): the run folder read (RunDir), the labels (Annotations), how long records are
// kept (RunRetention), the tabs (ProcessTabs). Temp folders only; synthetic runs.
import Foundation

enum ProcessTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "process: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("process.rundir"); runDirTests()
        DecisionTests.group("process.annotations"); annotationTests()
        DecisionTests.group("process.retention"); retentionTests()
        DecisionTests.group("process.tabs"); tabTests()
        DecisionTests.group("process.readonly"); readOnlyTests()
    }

    static func temp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("process-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func jsonl(_ lines: [[String: Any]]) -> String {
        lines.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }.joined(separator: "\n") + "\n"
    }

    // MARK: a synthetic run: two steps, two judge questions, calls, changes

    static let events: [[String: Any]] = [
        ["seq": 1, "t": 1_000.0, "kind": "start", "raw": "把笔记的正文改成「新的」"],
        ["seq": 2, "t": 1_001.0, "kind": "step", "step_id": "st_1", "plan_step": 1, "text": "set_value", "human": "在「正文」里填入「新的」"],
        ["seq": 3, "t": 1_002.0, "kind": "judge", "judge_id": "jd_a", "question": "intent", "answer": "matches", "by": "frontier", "confidence": 0.9,
         "tiers": [["tier": "frontier", "outcome": "answered", "choice": "matches", "settled": true]], "step_id": "st_1", "ms": 1200],
        ["seq": 4, "t": 1_003.0, "kind": "model_call", "call_id": "mc_1", "role": "loop", "model": "m", "outcome": "answered", "tokens_in": 100, "tokens_out": 10, "cost_usd": 0.001, "latency_ms": 300, "step_id": "st_1"],
        ["seq": 5, "t": 1_004.0, "kind": "model_call", "call_id": "mc_2", "role": "intent", "model": "m", "outcome": "answered", "tokens_in": 50, "tokens_out": 5, "cost_usd": 0.0005, "latency_ms": 900, "step_id": "st_1", "judge_id": "jd_a"],
        ["seq": 6, "t": 1_005.0, "kind": "step_result", "step_id": "st_1", "status": "ok", "shot": "shots/st_1.png"],
        ["seq": 7, "t": 1_006.0, "kind": "changes", "created": [], "modified": ["/tmp/x/笔记.txt"], "deleted": [], "external": [], "unconfirmed": []],
        ["seq": 8, "t": 1_007.0, "kind": "step", "step_id": "st_2", "text": "click", "human": "点「保存」"],
        ["seq": 9, "t": 1_008.0, "kind": "step_result", "step_id": "st_2", "status": "stale", "why": "the screen moved"],
        ["seq": 10, "t": 1_009.0, "kind": "shot_ready", "step_id": "st_2", "shot": "shots/st_2.png"],
        ["seq": 11, "t": 1_010.0, "kind": "judge", "judge_id": "jd_b", "question": "verify", "answer": "pass", "by": "frontier", "tiers": [["tier": "frontier", "outcome": "answered", "choice": "pass", "settled": true]]],
        ["seq": 12, "t": 1_011.0, "kind": "model_call", "call_id": "mc_3", "role": "loop", "model": "m", "outcome": "answered", "tokens_in": 120, "tokens_out": 12, "cost_usd": 0.002, "latency_ms": 500],
        ["seq": 13, "t": 1_012.0, "kind": "task_done", "status": "succeeded", "reason": "", "summary": "改好了", "result_card": NSNull(),
         "changes": ["created": [], "modified": ["/tmp/x/笔记.txt"], "deleted": [], "external": [], "unconfirmed": ["/tmp/x/other.txt"]]],
        ["seq": 14, "t": 1_013.0, "kind": "result_response", "picked": "undo", "effect": "undone", "undone": 1, "total": 1],
    ]
    static let trace: [[String: Any]] = [
        ["t": 1, "kind": "executor.act", "step_id": "st_1", "status": "ok", "changed": ["value": true]],
        ["t": 2, "kind": "executor.act", "step_id": "st_2", "status": "stale", "epoch_reason": "the window's elements changed"],
        ["t": 3, "kind": "judge.asked", "judge_id": "jd_a", "question_kind": "intent", "prompt": "Does this action match the request?\n…", "options": [["id": "matches", "text": "yes"], ["id": "mismatch", "text": "no"]]],
        ["t": 4, "kind": "executor.files_written", "paths": ["/tmp/x/笔记.txt"]],
        ["t": 5, "kind": "executor.files_not_credited", "paths": ["/tmp/x/other.txt"], "while": "screen action"],
    ]

    /// Every string the model holds, gathered.
    static func strings(_ v: Any) -> [String] {
        if let s = v as? String { return [s] }
        return Mirror(reflecting: v).children.flatMap { strings($0.value) }
    }

    static func runDirTests() {
        let full = RunDir.Files(events: jsonl(events), trace: jsonl(trace), shots: ["st_1.png", "st_2.png"])
        let m = RunDir.model(full)
        check(m.state == .ended && m.steps.count == 2 && m.judges.count == 2, "the whole run: \(m.state) \(m.steps.count) \(m.judges.count)")
        check(m.steps[0] == RunDir.Step(stepId: "st_1", planStep: 1, words: "在「正文」里填入「新的」", status: "ok", why: nil, shot: "shots/st_1.png",
                                        act: RunDir.Act(status: "ok", epochReason: nil, changed: "{\"value\":true}"), human: "在「正文」里填入「新的」", text: "set_value"),
              "step 1: \(m.steps[0])")
        check(m.steps[1].shot == "shots/st_2.png" && m.steps[1].act?.epochReason == "the window's elements changed" && m.steps[1].why == "the screen moved", "step 2: its late picture, its epoch reason")
        check(m.judges[0].prompt?.hasPrefix("Does this action") == true && m.judges[0].options?.map(\.id) == ["matches", "mismatch"] && m.judges[0].kind == "intent",
              "judge 1: its material from judge.asked")
        check(m.judges[1].prompt == nil && m.judges[1].options == nil, "judge 2: no judge.asked -- no material (没有记录), never put together")
        check(m.cost.map(\.role) == ["loop", "intent"] && m.cost[0].calls == 2 && m.cost[0].tokensIn == 220 && m.cost[0].medianMs == 300 && m.cost[1].medianMs == 900,
              "cost: the acting model first, by role: \(m.cost)")
        check(m.costByStep["st_1"]?.map(\.calls) == [1, 1] && m.costByStep["st_2"] == nil, "cost by step")
        check(m.changes?.final == true && m.changes?.unconfirmed == ["/tmp/x/other.txt"] && m.changes?.undo?.effect == "undone"
              && m.changes?.filesWritten == ["/tmp/x/笔记.txt"] && m.changes?.notCredited == ["/tmp/x/other.txt"] && m.changes?.windowsCreated == [],
              "changes: task_done's, the undo, the trace's lists")
        // invariant 11: every string the pane can show is a record's (the fixed words aside, in the views)
        let source = (jsonl(events) + jsonl(trace)).replacingOccurrences(of: "\\/", with: "/") + "st_1.png st_2.png"
        let foreign = strings(m).filter { !$0.isEmpty && !source.contains($0) && !source.contains($0.replacingOccurrences(of: "\n", with: "\\n")) }
        check(foreign.isEmpty, "every string in the model is in a record: \(foreign)")

        // the table: folder contents -> what each view has (nil: 没有记录)
        let noTrace = RunDir.model(RunDir.Files(events: jsonl(events), trace: nil, shots: ["st_1.png", "st_2.png"]))
        check(!noTrace.hasTrace && noTrace.steps.allSatisfy { $0.act == nil } && noTrace.judges.allSatisfy { $0.prompt == nil }
              && noTrace.changes?.filesWritten == nil && noTrace.changes?.modified == ["/tmp/x/笔记.txt"], "no trace: its cells none, the events' still there")
        let noShots = RunDir.model(RunDir.Files(events: jsonl(events), trace: jsonl(trace), shots: []))
        check(noShots.steps.allSatisfy { $0.shot == nil } && noShots.steps.count == 2, "no pictures on disk (pending, taken): the rows stay, no picture")
        let running = RunDir.model(RunDir.Files(events: jsonl(Array(events.prefix(7))), trace: nil))
        check(running.state == .running && running.changes?.final == false && running.changes?.modified == ["/tmp/x/笔记.txt"], "running: the last changes so far")
        let torn = RunDir.model(RunDir.Files(events: jsonl(Array(events.prefix(6))) + "{\"seq\": 7, \"kind\": \"chan", trace: nil))
        check(torn.state == .running && torn.steps.count == 1, "a torn last line: what parses, no crash")
        // (#126) a picture's path outside the run's shots/: never read
        for bad in ["/etc/x.png", "shots/../../x.png", "../x.png", "shots/a/b.png", "shots/", "shots/.hidden", "x.png"] {
            check(RunDir.contained(bad) == nil, "not contained: \(bad)")
        }
        let escaping = events.map { e -> [String: Any] in var e = e; if e["kind"] as? String == "step_result" && e["step_id"] as? String == "st_1" { e["shot"] = "/tmp/st_1.png" }; return e }
        check(RunDir.model(RunDir.Files(events: jsonl(escaping), shots: ["st_1.png"])).steps[0].shot == nil, "an absolute shot path: no picture")
        check(RunDir.model(RunDir.Files(events: nil)) == .none && RunDir.model(RunDir.Files(events: "")) == .none, "no events: none (没有记录)")
        check(RunDir.model(RunDir.Files(events: jsonl(events), trace: jsonl(trace), shots: ["st_1.png"], pruned: true)).state == .pruned,
              "the marker: pruned (运行记录已清理), whatever stray file came after it")

        // (#126 Codex at e419501, 2) any record appended changes what the pane watches
        do {
            let support = temp()
            let dir = support.appendingPathComponent("sessions/s1/runs/run_s")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? jsonl(Array(events.prefix(13))).write(to: dir.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
            let before = RunDir.signature(session: "s1", run: "run_s", support: support)
            let h = try! FileHandle(forWritingTo: dir.appendingPathComponent("events.jsonl")); h.seekToEndOfFile()
            h.write(Data((jsonl([events[13]])).utf8)); try? h.close()
            let after = RunDir.signature(session: "s1", run: "run_s", support: support)
            check(before != after, "an undo's result_response appended: the pane reads again")
            try? "x\n".write(to: dir.appendingPathComponent("trace.jsonl"), atomically: true, encoding: .utf8)
            check(RunDir.signature(session: "s1", run: "run_s", support: support) != after, "a trace line: again")
            check(RunDir.signature(session: "../x", run: "run_s", support: support) == "", "an id that names no folder: nothing")
        }
        // on disk: the one read
        let dir = temp().appendingPathComponent("run_1")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("shots"), withIntermediateDirectories: true)
        try? jsonl(events).write(to: dir.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        try? jsonl(trace).write(to: dir.appendingPathComponent("trace.jsonl"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("shots/st_1.png").path, contents: Data([1]))
        let read = RunDir.model(RunDir.files(at: dir))
        check(read.steps.map(\.shot) == ["shots/st_1.png", nil] && read.judges.count == 2, "read from disk: \(read.steps.map(\.shot))")
        check(RunDir.files(at: dir.appendingPathComponent("nope")) == RunDir.Files(), "a folder not there: nothing")
    }

    // MARK: annotations (invariant 12)

    static func annotationTests() {
        let support = temp()
        let m = RunDir.model(RunDir.Files(events: jsonl(events), trace: jsonl(trace)))
        let a = m.judges[0], b = m.judges[1]
        func line(_ j: RunDir.Judge, _ label: Annotations.Label, _ note: String?, _ at: Double) -> Annotations.Line {
            Annotations.Line(judge_id: j.judgeId, run_id: "run_1", label: label, note: note, at: at, sample: Annotations.sample(j))
        }
        check(Annotations.add(line(a, .right, nil, 1), support: support), "written")
        Annotations.add(line(a, .wrong, "它其实没对上", 2), support: support)
        Annotations.add(line(b, .right, nil, 3), support: support)
        // the run's records go (and the folder with them): the labels still whole
        try? FileManager.default.removeItem(at: support.appendingPathComponent("sessions"))
        let cur = Annotations.current(Annotations.lines("run_1", support: support))
        check(cur.count == 2 && cur[0].label == .wrong && cur[0].note == "它其实没对上" && cur[0].sample.prompt == a.prompt
              && cur[0].sample.options == a.options && cur[0].sample.tiers.count == 1 && cur[0].sample.answer == "matches",
              "the last line counts, its sample whole: \(cur.first.map { "\($0)" } ?? "")")
        check(cur[1].sample.prompt == nil, "labelled with no material: prompt null (原文未保存)")
        check(Annotations.count("run_1", support: support) == 2, "the count")
        // (#126) the labels view, from the line alone: options and every tier's answer
        let shown = Annotations.shown(cur[0])
        check(shown.options == ["matches: yes", "mismatch: no"] && shown.tiers == ["frontier · answered · matches"] && shown.prompt == a.prompt
              && shown.answer == "matches" && shown.by == "frontier" && shown.label == .wrong && shown.note == "它其实没对上",
              "the labels view shows the sample whole: \(shown)")
        check(Annotations.shown(cur[1]).prompt == nil && Annotations.shown(cur[1]).tiers.count == 1, "no material: 原文未保存, the tiers still")
        let mode = (try? FileManager.default.attributesOfItem(atPath: Annotations.file("run_1", support: support).path)[.posixPermissions]) as? NSNumber
        check(mode?.intValue == 0o600, "the labels file is the user's only: \(String(describing: mode))")
        let out = temp().appendingPathComponent("export.jsonl")
        check(Annotations.export("run_1", to: out, support: support)
              && (try? String(contentsOf: out, encoding: .utf8)) == (try? String(contentsOf: Annotations.file("run_1", support: support), encoding: .utf8)),
              "exported as it is")
        check(!Annotations.add(Annotations.Line(judge_id: "j", run_id: "../x", label: .right, note: nil, at: 0, sample: Annotations.sample(a)), support: support),
              "a run id that is no file name: not written")
        // property: any sequence of labels -> the last per judge, in first-label order
        var g = CardStoreTests.RNG(x: 77)
        for _ in 0..<50 {
            var ls: [Annotations.Line] = []
            for i in 0..<g.next(12) { ls.append(line([a, b][g.next(2)], g.next(2) == 0 ? .right : .wrong, g.next(3) == 0 ? "n\(i)" : nil, Double(i))) }
            let text = ls.map { String(decoding: try! JSONEncoder.sorted.encode($0), as: UTF8.self) }.joined(separator: "\n")
            let got = Annotations.current(Annotations.parse(text))
            let want = [a.judgeId, b.judgeId].filter { id in ls.contains { $0.judge_id == id } }
                .sorted { i, j in ls.firstIndex { $0.judge_id == i }! < ls.firstIndex { $0.judge_id == j }! }
                .map { id in ls.last { $0.judge_id == id }! }
            if got != want { check(false, "last line per judge: \(got) vs \(want)"); break }
        }
    }

    // MARK: retention (invariant 13)

    static func retentionTests() {
        typealias R = RunRetention
        let day = 24 * 3600.0, now = 100 * day, gb = R.maxBytes
        func r(_ id: String, _ age: Double?, _ bytes: Int64, kind: R.Kind = .session, live: Bool = false, pruned: Bool = false) -> R.Run {
            R.Run(id: id, folder: URL(fileURLWithPath: "/nonexistent/" + id), kind: kind, ended: age.map { now - $0 * day }, bytes: bytes, live: live, pruned: pruned)
        }
        // the table: (runs) -> taken
        let rows: [(String, [R.Run], [String])] = [
            ("all young, small", [r("a", 1, 10), r("b", 2, 10)], []),
            ("one older than 30 days", [r("a", 31, 10), r("b", 2, 10)], ["a"]),
            ("over 1 GB: the oldest until it fits", [r("a", 3, gb / 2), r("b", 2, gb / 2), r("c", 1, gb / 2)], ["a"]),
            ("over 1 GB by a lot", [r("a", 3, gb), r("b", 2, gb), r("c", 1, 10)], ["a", "b"]),
            ("age not known: kept, and not counted", [r("a", nil, 2 * gb), r("b", 40, 10)], ["b"]),
            ("(#126) a never-ending run of 1.2 GB does not strip the young ones", [r("x", nil, gb * 6 / 5), r("y1", 0.01, gb / 100), r("y2", 0.02, gb / 100)], []),
            ("a live run of 2 GB: kept, the young ones too", [r("l", 1, 2 * gb, live: true), r("y", 1, 10)], []),
            ("live (its late shots landing): never", [r("a", 40, 10, live: true)], []),
            ("pruned, nothing left: nothing to take", [r("a", 40, 0, pruned: true)], []),
            ("pruned, a stray shot came: taken again", [r("a", 1, 5, pruned: true)], ["a"]),
            ("the old window's: whole, by the same rule", [r("w", 31, 0, kind: .whole), r("s", 1, 10)], ["w"]),
        ]
        for (name, runs, want) in rows {
            let got = R.plan(runs, now: now).map(\.id)
            check(got == want, "\(name): \(got)")
        }
        // property against a brute-force oracle: of the runs that may go (oldest first), the shortest prefix after which
        // none left is older than 30 days and the total is at most 1 GB (or all of them), plus the pruned ones with strays
        var g = CardStoreTests.RNG(x: 13)
        for _ in 0..<400 {
            var runs: [R.Run] = []
            for i in 0..<g.next(9) {
                let ended: Double? = g.next(6) == 0 ? nil : Double(g.next(60))
                runs.append(r("r\(i)", ended, Int64(g.next(5)) * gb / 3, kind: g.next(4) == 0 ? .whole : .session, live: g.next(8) == 0, pruned: g.next(6) == 0))
            }
            let may = runs.filter(R.mayGo).sorted { ($0.ended!, $0.id) < ($1.ended!, $1.id) }
            let strays = Set(may.filter(\.pruned).map(\.id))
            let total = may.reduce(Int64(0)) { $0 + $1.bytes }
            var want: Set<String> = []
            for k in 0...may.count {
                let taken = Set(may.prefix(k).map(\.id)).union(strays)
                let left = may.filter { !taken.contains($0.id) }
                let stays = total - runs.filter { taken.contains($0.id) }.reduce(Int64(0)) { $0 + $1.bytes }
                if left.allSatisfy({ now - $0.ended! <= R.maxAge }) && stays <= gb || k == may.count { want = taken; break }
            }
            let got = Set(R.plan(runs, now: now).map(\.id))
            if got != want { check(false, "plan vs oracle: \(got.sorted()) vs \(want.sorted()) for \(runs.map { "\($0.id):\($0.ended ?? -1):\($0.bytes):\($0.kind):\($0.live):\($0.pruned)" })"); break }
            if got.contains(where: { id in runs.contains { $0.id == id && ($0.ended == nil || $0.live) } }) {
                check(false, "a running or live run taken"); break
            }
        }
        // on disk: a session run keeps its events and journal, loses its records, gets the marker; the old window's goes
        // whole; a running one and annotations/ are untouched
        let support = temp(), fm = FileManager.default
        func mk(_ dir: URL, done: Double?, records: Bool = true) {
            try? fm.createDirectory(at: dir.appendingPathComponent("shots"), withIntermediateDirectories: true)
            var evs: [[String: Any]] = [["seq": 1, "t": 1.0, "kind": "start", "raw": "x"]]
            if let done { evs.append(["seq": 2, "t": done, "kind": "task_done", "status": "succeeded", "reason": "", "summary": "", "result_card": NSNull()]) }
            try? jsonl(evs).write(to: dir.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
            try? "{}\n".write(to: dir.appendingPathComponent("journal.jsonl"), atomically: true, encoding: .utf8)
            if records {
                for f in ["trace.jsonl", "trace.otel.jsonl", "model_calls.jsonl", "shots/1.png"] { fm.createFile(atPath: dir.appendingPathComponent(f).path, contents: Data(repeating: 7, count: 100)) }
            }
        }
        let t0 = Date().timeIntervalSince1970
        let old = support.appendingPathComponent("sessions/ses_a/runs/run_old"), young = support.appendingPathComponent("sessions/ses_a/runs/run_young")
        let going = support.appendingPathComponent("sessions/ses_a/runs/run_going"), liveRun = support.appendingPathComponent("sessions/ses_b/runs/run_live")
        let oldWin = support.appendingPathComponent("work/harness-runs/run_w")
        mk(old, done: t0 - 40 * day); mk(young, done: t0 - day); mk(going, done: nil); mk(liveRun, done: t0 - 40 * day); mk(oldWin, done: t0 - 40 * day)
        let ann = Annotations.file("run_old", support: support)
        try? fm.createDirectory(at: ann.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: ann.path, contents: Data("x\n".utf8))
        let n = R.prune(support: support, live: ["run_live"], now: t0)
        check(n == 2, "two taken: \(n)")
        func has(_ u: URL, _ f: String) -> Bool { fm.fileExists(atPath: u.appendingPathComponent(f).path) }
        check(has(old, "events.jsonl") && has(old, "journal.jsonl") && has(old, R.marker) && !has(old, "trace.jsonl") && !has(old, "shots")
              && !has(old, "model_calls.jsonl") && !has(old, "trace.otel.jsonl"), "a session run: records gone, events and journal kept, marked")
        check(!fm.fileExists(atPath: oldWin.path), "the old window's run: gone whole")
        check(has(young, "trace.jsonl") && has(going, "trace.jsonl") && has(liveRun, "trace.jsonl"), "young, running, live: untouched")
        check(fm.fileExists(atPath: ann.path), "annotations/: untouched")
        check(RunDir.model(RunDir.files(at: old)).state == .pruned, "its 过程: 运行记录已清理")
        // a stray shot after the pass: taken by the next, the marker stays
        fm.createFile(atPath: old.appendingPathComponent("trace.jsonl").path, contents: Data("late\n".utf8))
        check(R.prune(support: support, live: ["run_live"], now: t0) >= 1 && !has(old, "trace.jsonl") && has(old, R.marker), "a stray record: taken again")
        // 「清除运行记录」: every run not live
        let cleared = R.prune(support: support, live: ["run_live"], now: t0, everything: true)
        check(cleared >= 1 && !has(young, "trace.jsonl") && has(young, "events.jsonl")
              && !has(going, "trace.jsonl") && has(liveRun, "trace.jsonl") && fm.fileExists(atPath: ann.path), "clear all: every run not live (an unended one too); live runs and annotations kept")
        // (#126) a killed old-window run (no task_done) 90 days on: aged by its events' last write, taken; a session run
        // closed without an end, young: kept; a symlinked run folder: never followed
        let s2 = temp()
        let killed = s2.appendingPathComponent("work/harness-runs/killed")
        try? fm.createDirectory(at: killed.appendingPathComponent("shots"), withIntermediateDirectories: true)
        try? "{\"kind\":\"step\",\"t\":1}\n".write(to: killed.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        let open = s2.appendingPathComponent("sessions/s1/runs/open")
        mk(open, done: nil)
        fm.createFile(atPath: open.appendingPathComponent("runtime.jsonl").path, contents: Data(repeating: 1, count: 10))
        let outside = s2.appendingPathComponent("outside")
        mk(outside, done: 1)
        try? fm.createSymbolicLink(at: s2.appendingPathComponent("sessions/s1/runs/link"), withDestinationURL: outside)
        check(R.prune(support: s2, live: [], now: Date().timeIntervalSince1970 + 90 * day) == 2, "90 days on: the killed run and the unended one, not the link")
        check(!fm.fileExists(atPath: killed.path), "the killed old-window run: taken whole")
        check(!has(open, "runtime.jsonl") && !has(open, "trace.jsonl") && has(open, "events.jsonl") && has(open, R.marker), "the unended session run: its records (runtime.jsonl too) taken")
        check(has(outside, "trace.jsonl") && has(outside, "shots"), "the symlinked run folder: never followed")
        let s3 = temp(), fresh = s3.appendingPathComponent("sessions/s1/runs/fresh")
        mk(fresh, done: nil)
        check(R.prune(support: s3, live: [], now: Date().timeIntervalSince1970) == 0 && has(fresh, "trace.jsonl"), "unended and young: kept")
        check(R.prune(support: s3, live: ["fresh"], now: Date().timeIntervalSince1970 + 90 * day) == 0, "live (a fact): never")
        // (#126 Codex at e419501, 1) a task that starts during the pass: the live facts read again right before each
        // run is taken -- a lock that names it mid-scan keeps it; and nothing written after the pass began is taken
        let s4 = temp(), late = s4.appendingPathComponent("sessions/s1/runs/run_late"), other = s4.appendingPathComponent("sessions/s1/runs/run_other")
        mk(late, done: t0 - 40 * day); mk(other, done: t0 - 40 * day)
        var reads = 0
        let n4 = R.prune(support: s4, live: { reads += 1; return reads == 1 ? [] : ["run_late"] }, now: t0, everything: true)
        check(n4 == 1 && has(late, "trace.jsonl") && !has(late, R.marker) && !has(other, "trace.jsonl"), "live by the time it is taken: kept (\(n4), reads \(reads))")
        mk(other, done: t0 - 40 * day)
        check(R.prune(support: s4, live: { [] }, now: t0, everything: true, began: Date(timeIntervalSinceNow: -3600)) == 0 && has(other, "trace.jsonl"),
              "written after the pass began: never taken")
        // the age from task_done's own t, not the folder's date
        check(R.run(young, kind: .session, live: []).ended.map { abs($0 - (t0 - day)) < 1 } == true, "age: task_done's t")
    }

    // MARK: tabs (§11.4)

    static func tabTests() {
        typealias T = ProcessTabs
        var t = T()
        t.apply(.taskStarted("r1")); check(t.tab == .now && t.run == "r1", "a task starts, 现在 shown: its run")
        t.apply(.taskDone("r1")); check(t.tab == .process && t.run == "r1", "its end: 过程")
        t.apply(.taskStarted("r2")); t.apply(.taskDone("r2"))
        check(t.tab == .process && t.run == "r1", "(#126 3b) reached by the switch, being read: the next run's start and end change nothing")
        t.apply(.picked(.now, latest: "r2")); t.apply(.taskStarted("r3")); t.apply(.taskDone("r3"))
        check(t.tab == .now && t.run == "r3", "picked 现在: no switch to 过程 in this conversation")
        t.apply(.picked(.process, latest: "r3")); check(t.tab == .process && t.run == "r3", "picked 过程: its run")
        t.apply(.taskStarted("r4")); t.apply(.taskDone("r4"))
        check(t.tab == .process && t.run == "r3", "picked 过程 on the latest run, then the next run starts and ends: stays")
        var u = T(); u.apply(.picked(.process, latest: "a")); u.apply(.taskStarted("b")); u.apply(.taskDone("b"))
        check(u.tab == .process && u.run == "a", "picked 过程 with no run shown: the latest, kept")
        t.apply(.clickedTask("old")); check(t.tab == .process && t.run == "old", "a task message clicked: its 过程")
        var f = T(); f.apply(.clickedChanges("x")); f.apply(.clickedChanges("x"))
        check(f.tab == .process && f.run == "x" && f.focus == .changes && f.focusAsks == 2, "「明细 ›」: 过程 at 改动, each click asks again")
        f.apply(.clickedTask("x")); check(f.focus == nil, "a task's own 过程: from its top")
        // #131 review: one-shot -- a tab pick after 明细, a pane that used it, a task's start or end: no jump later
        var p = T(); p.apply(.clickedChanges("x")); p.apply(.picked(.now, latest: "x")); p.apply(.picked(.process, latest: "x"))
        check(p.focus == nil, "明细, then 现在 → 过程: 过程 from its top, no jump to 改动")
        var q = T(); q.apply(.clickedChanges("x")); q.apply(.focusShown)
        check(q.focus == nil && q.tab == .process && q.run == "x", "the pane scrolled: the ask used; a new pane (another run, a reopen) starts at the top")
        var r = T(); r.apply(.clickedChanges("x")); r.apply(.taskStarted("y"))
        check(r.focus == nil, "a task starts after 明细: the ask gone")
        t.apply(.taskStarted("B")); t.apply(.taskDone("B")); check(t.run == "old", "a queued task starts and ends while reading 'old': not yanked")
        t.apply(.picked(.now, latest: "B")); t.apply(.picked(.process, latest: "B")); t.apply(.taskDone("C"))
        check(t.tab == .process && t.run == "old", "back on 过程: still 'old', being read")
        // property: random sequences against an oracle written from the table
        var g = CardStoreTests.RNG(x: 5)
        for _ in 0..<500 {
            var s = T(), tab = T.Tab.now, run: String? = nil, stayNow = false, focus: T.Focus? = nil, asks = 0
            for _ in 0..<20 {
                let r = "r\(g.next(3))"
                let e: T.Event = [.taskStarted(r), .taskDone(r), .picked(g.next(2) == 0 ? .now : .process, latest: g.next(4) == 0 ? nil : r), .clickedTask(r),
                                  .clickedChanges(r), .focusShown][g.next(6)]
                let before = (tab, run)
                // (the 改动 ask is one-shot: any other move clears it)
                if case .clickedChanges = e {} else { focus = nil }
                switch e {
                case .taskStarted(let x): if tab == .now { run = x }
                case .taskDone(let x): if tab == .now && !stayNow { tab = .process; run = x }
                case .picked(let p, let latest): tab = p; stayNow = p == .now; if p == .process && run == nil { run = latest }
                case .clickedTask(let x): tab = .process; run = x; stayNow = false; focus = nil
                case .clickedChanges(let x): tab = .process; run = x; stayNow = false; focus = .changes; asks += 1
                case .focusShown: break
                }
                s.apply(e)
                if s.tab != tab || s.run != run || s.focus != focus || s.focusAsks != asks {
                    check(false, "tabs vs the table after \(e): \(s) vs \(tab) \(run ?? "-") \(String(describing: focus)) \(asks)"); return
                }
                // being read: 过程 with a run shown -- a task's start or end never moves it
                if before.0 == .process, before.1 != nil, case .taskStarted = e, (s.tab, s.run) != (before.0, before.1) { check(false, "yanked on a start"); return }
                if before.0 == .process, before.1 != nil, case .taskDone = e, (s.tab, s.run) != (before.0, before.1) { check(false, "yanked on an end"); return }
            }
        }
        // the window's model: a task's end here switches to 过程 and prunes once; a history read does neither
        do {
            let r = CardStoreTests.Rig()
            var ended = 0
            r.m.onTaskEnded = { ended += 1 }
            check(r.m.currentTabs.run == CardStoreTests.rid, "the task started here: its run")
            r.done("succeeded")
            check(r.m.currentTabs.tab == .process && r.m.currentTabs.run == CardStoreTests.rid && ended == 1, "its end: 过程, one prune: \(ended)")
            r.m.pickTab(.now)
            check(r.m.currentTabs.tab == .now, "picked 现在")
            r.m.showProcess("r0")
            check(r.m.currentTabs.tab == .process && r.m.currentTabs.run == "r0", "a task message: its 过程")
            // (#126 Codex at e419501, 3) a task that starts and ends within one batched flush: switched and pruned all the same
            do {
                let wire = CardStoreTests.Wire(), timers = ShellTests.Timers()
                let client = SessionClient(transport: wire)
                let sid = CardStoreTests.sid
                for l: [String: Any] in [["kind": "session.message", "session_id": sid, "seq": 1, "msg_id": "u1", "role": "user", "text": "/cua x", "via": "cua"],
                                         ["kind": "session.task", "session_id": sid, "seq": 2, "msg_id": "u1", "run_id": "r_fast", "raw": "x", "by": "slash"],
                                         ["kind": "start", "session_id": sid, "run_id": "r_fast", "seq": 1, "raw": "x"],
                                         ["kind": "task_done", "session_id": sid, "run_id": "r_fast", "seq": 2, "status": "succeeded", "reason": "", "summary": "", "result_card": NSNull()]] {
                    client.feed(l)
                }
                let m = ShellModel(client: client, defaults: ShellTests.scratchDefaults(), config: { "openai:local|fake" }, lang: { .zhHans },
                                   takeBackAfter: timers.after, now: { timers.now }, work: { $0() }, deliver: { $0() })
                m.selected = sid
                var pruned = 0
                m.onTaskEnded = { pruned += 1 }
                client.feed(["kind": "session.message", "session_id": sid, "seq": 3, "msg_id": "a1", "role": "assistant", "text": "好"])
                check(m.currentTabs.tab == .process && m.currentTabs.run == "r_fast" && pruned == 1, "started and ended in one flush: 过程, one prune (\(m.currentTabs), \(pruned))")
                client.feed(["kind": "session.message", "session_id": sid, "seq": 4, "msg_id": "a2", "role": "assistant", "text": "好"])
                check(pruned == 1, "told once")
            }
            let h = CardStoreTests.Rig.make(CardStoreTests.Wire(), ShellTests.Timers())
            var replayed = 0
            h.onTaskEnded = { replayed += 1 }
            let sid = CardStoreTests.sid
            for l: [String: Any] in [["kind": "session.message", "session_id": sid, "seq": 1, "msg_id": "u1", "role": "user", "text": "/cua x", "via": "cua"],
                                     ["kind": "session.task", "session_id": sid, "seq": 2, "msg_id": "u1", "run_id": "r_old", "raw": "x", "by": "slash"],
                                     ["kind": "start", "session_id": sid, "run_id": "r_old", "seq": 1, "t": 10.0, "raw": "x"],
                                     ["kind": "task_done", "session_id": sid, "run_id": "r_old", "seq": 2, "t": 20.0, "status": "succeeded", "reason": "", "summary": "", "result_card": NSNull()]] {
                h.client.feed(l)
            }
            check(h.currentTabs.tab == .now && replayed == 0, "a history read: no switch, no prune: \(h.currentTabs)")
        }
    }

    // MARK: read only (invariant 14, 15)

    static func readOnlyTests() {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func code(_ f: String) -> String {
            ((try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) ?? "")
                .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        }
        for f in ["Shared/RunDir.swift", "Shared/ProcessTabs.swift", "Shared/Annotations.swift", "Main/ProcessPane.swift"] {
            let c = code(f)
            check(!c.isEmpty, "\(f) read")
            for bad in ["SessionClient", "client.", "transport", "socket(", "activate(", "makeKey", "NSApp.activate", "orderFront"] where c.contains(bad) {
                check(false, "\(f) sends or activates: \(bad)")
            }
        }
        // a prompt is written only by Annotations (its file, the user's export)
        for f in ["Shared/RunDir.swift", "Shared/ProcessTabs.swift", "Main/ProcessPane.swift"] {
            let c = code(f)
            for w in [".write(", "createFile(", "FileHandle(forWritingTo", "removeItem("] where c.contains(w) {
                check(false, "\(f) writes: \(w)")
            }
        }
    }
}
