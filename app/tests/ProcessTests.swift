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
                                        act: RunDir.Act(status: "ok", epochReason: nil, changed: "{\"value\":true}")), "step 1: \(m.steps[0])")
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
        check(RunDir.model(RunDir.Files(events: nil)) == .none && RunDir.model(RunDir.Files(events: "")) == .none, "no events: none (没有记录)")
        check(RunDir.model(RunDir.Files(events: jsonl(events), trace: jsonl(trace), shots: ["st_1.png"], pruned: true)).state == .pruned,
              "the marker: pruned (运行记录已清理), whatever stray file came after it")

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
            ("running (no task_done): never", [r("a", nil, 2 * gb), r("b", 40, 10)], ["b"]),
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
            let total = runs.reduce(Int64(0)) { $0 + $1.bytes }
            var want: Set<String> = []
            for k in 0...may.count {
                let taken = Set(may.prefix(k).map(\.id)).union(strays)
                let left = may.filter { !taken.contains($0.id) }
                let stays = total - runs.filter { taken.contains($0.id) }.reduce(Int64(0)) { $0 + $1.bytes }
                if left.allSatisfy({ now - $0.ended! <= R.maxAge }) && stays <= gb || k == may.count { want = taken; break }
            }
            let got = Set(R.plan(runs, now: now).map(\.id))
            if got != want { check(false, "plan vs oracle: \(got.sorted()) vs \(want.sorted()) for \(runs.map { "\($0.id):\($0.ended ?? -1):\($0.bytes):\($0.kind):\($0.live):\($0.pruned)" })"); break }
            if runs.contains(where: { $0.ended == nil || $0.live }) && got.contains(where: { id in runs.contains { $0.id == id && ($0.ended == nil || $0.live) } }) {
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
        // 「清除运行记录」: every ended, not live run
        let cleared = R.prune(support: support, live: ["run_live"], now: t0, everything: true)
        check(cleared >= 1 && !has(young, "trace.jsonl") && has(young, "events.jsonl")
              && has(going, "trace.jsonl") && has(liveRun, "trace.jsonl") && fm.fileExists(atPath: ann.path), "clear all: ended runs' records; running, live, annotations kept")
        // the age from task_done's own t, not the folder's date
        check(R.run(young, kind: .session, live: []).ended.map { abs($0 - (t0 - day)) < 1 } == true, "age: task_done's t")
    }

    // MARK: tabs (§11.4)

    static func tabTests() {
        typealias T = ProcessTabs
        var t = T()
        t.apply(.taskStarted("r1")); check(t.tab == .now && t.run == "r1", "a task starts: 现在")
        t.apply(.taskDone("r1")); check(t.tab == .process && t.run == "r1", "its end: 过程")
        t.apply(.picked(.now)); t.apply(.taskDone("r1")); check(t.tab == .now, "picked 现在 after: never again for it")
        t.apply(.clickedTask("r0")); check(t.tab == .process && t.run == "r0", "a task message clicked: its 过程")
        t.apply(.taskStarted("r2")); t.apply(.clickedTask("r0")); t.apply(.taskDone("r2"))
        check(t.tab == .process && t.run == "r0", "an end while reading an older run: not yanked")
        check(T().shown(traceOn: false) == .now && t.shown(traceOn: false) == .now, "the switch off: 现在 only")
        // property: random sequences against an oracle written from the table
        var g = CardStoreTests.RNG(x: 5)
        for _ in 0..<500 {
            var s = T(), tab = T.Tab.now, run: String? = nil, ended: Set<String> = []
            for _ in 0..<20 {
                let r = "r\(g.next(3))"
                let e: T.Event = [.taskStarted(r), .taskDone(r), .picked(g.next(2) == 0 ? .now : .process), .clickedTask(r)][g.next(4)]
                switch e {
                case .taskStarted(let x): tab = .now; run = x
                case .taskDone(let x):
                    if !ended.contains(x) { ended.insert(x); if !(tab == .process && run != nil && run != x) { tab = .process; run = x } }
                case .picked(let p): tab = p
                case .clickedTask(let x): tab = .process; run = x
                }
                s.apply(e)
                if s.tab != tab || s.run != run { check(false, "tabs vs the table after \(e): \(s) vs \(tab) \(run ?? "-")"); return }
            }
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
