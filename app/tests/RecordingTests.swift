// Recording a chat's computer task (Shared/TaskRecording.swift): started only with the conversation's switch on, at
// its next task's start; stopped exactly once when that task is over (any way), the switch goes off, or the app
// quits; never recording with the switch off; only this path asks the helper to record.
import Foundation

enum RecordingTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "recording: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("recording.table"); tableTests()
        DecisionTests.group("recording.sequences"); sequenceTests()
        DecisionTests.group("recording.shell"); shellTests()
        DecisionTests.group("recording.static"); staticTests()
    }

    static func tableTests() {
        typealias T = TaskRecording
        var r = T()
        check(r.apply(.taskStarted(session: "s", run: "r1")).isEmpty, "the switch off (the default): nothing records")
        check(r.apply(.toggled(session: "s", on: true)).isEmpty, "turned on between tasks: nothing yet")
        check(r.apply(.taskStarted(session: "s", run: "r2")) == [.start(session: "s", run: "r2")], "the next task starts: recorded")
        check(r.apply(.taskStarted(session: "t", run: "r3")).isEmpty, "another conversation's task meanwhile: not (one at a time, its switch off)")
        check(r.apply(.taskEnded(run: "r3")).isEmpty, "its end: nothing")
        check(r.apply(.taskEnded(run: "r2")) == [.stop(run: "r2")], "the recorded task ends: stopped")
        check(r.apply(.taskEnded(run: "r2")).isEmpty, "told again: once")
        _ = r.apply(.taskStarted(session: "s", run: "r4"))
        check(r.apply(.toggled(session: "s", on: false)) == [.stop(run: "r4")], "switched off while recording: stopped")
        _ = r.apply(.toggled(session: "s", on: true)); _ = r.apply(.taskStarted(session: "s", run: "r5"))
        check(r.apply(.appQuit) == [.stop(run: "r5")], "the app quits while recording: stopped")
        _ = r.apply(.taskStarted(session: "s", run: "r6"))
        _ = r.apply(.startFailed(run: "r6"))
        check(r.apply(.taskEnded(run: "r6")).isEmpty && r.recordingRun == nil, "a start that failed: nothing to stop")
        var d = T(); d.defaultOn = true
        check(d.apply(.taskStarted(session: "new", run: "x")) == [.start(session: "new", run: "x")], "the last choice is a new conversation's start")
    }

    /// Random lifecycles -- tasks starting and ending every way, steers (nothing for the recording), switches,
    /// failed starts, a quit: every start is followed by exactly one stop of that run before the next start; nothing
    /// starts with its conversation's switch off.
    static func sequenceTests() {
        typealias T = TaskRecording
        var g = CardStoreTests.RNG(x: 21)
        for seed in 0..<500 {
            var r = T(), open: String? = nil, active: String? = nil
            var switches: [String: Bool] = [:]
            var bad = ""
            for step in 0..<30 {
                let s = ["s1", "s2"][g.next(2)], run = "r\(step)"
                var acts: [T.Action] = []
                switch g.next(6) {
                case 0: switches[s] = g.next(2) == 0; acts = r.apply(.toggled(session: s, on: switches[s]!))
                case 1, 2: if open == nil { open = run; acts = r.apply(.taskStarted(session: s, run: run)); if case .start? = acts.first, !(switches[s] ?? false) { bad = "started with the switch off" } }
                case 3: if let o = open { open = nil; acts = r.apply(.taskEnded(run: o)) }      // done, ended, closed, crashed: one end
                case 4: if let a = active, g.next(4) == 0 { acts = r.apply(.startFailed(run: a)); active = nil }
                default: acts = []                                                              // a steer: nothing
                }
                for a in acts {
                    switch a {
                    case .start(_, let run): if active != nil { bad = "two at once" }; active = run
                    case .stop(let run): if active != run { bad = "a stop of \(run), recording \(active ?? "-")" }; active = nil
                    }
                }
                if !bad.isEmpty { check(false, "seed \(seed) step \(step): \(bad)"); return }
            }
            // the app quits: whatever is recorded stops
            let last = r.apply(.appQuit)
            if let a = active, last != [.stop(run: a)] { check(false, "seed \(seed): the quit did not stop \(a)"); return }
        }
    }

    final class FakeRecorder: TaskRecorder {
        var log: [String] = []
        var ok = true
        func start(goal: String, started: @escaping (Bool) -> Void) { log.append("start:\(goal)"); started(ok) }
        func stop(done: @escaping (URL?) -> Void) { log.append("stop"); done(URL(fileURLWithPath: "/tmp/movie.mov")) }
        func step(_ n: Int, _ words: String) { log.append("step:\(n)") }
    }

    /// The window's model with a recorder: the switch, a task's start and its end (done, the executor killed).
    static func shellTests() {
        let wire = CardStoreTests.Wire(), timers = ShellTests.Timers()
        let m = ShellModel(client: SessionClient(transport: wire), defaults: ShellTests.scratchDefaults(), config: { "openai:local|fake" },
                           lang: { .zhHans }, takeBackAfter: timers.after, now: { timers.now }, work: { $0() }, deliver: { $0() })
        let rec = FakeRecorder()
        m.recorder = rec
        let sid = CardStoreTests.sid
        m.selected = sid
        func task(_ run: String, seq: Int, raw: String) {
            m.client.feed(["kind": "session.task", "session_id": sid, "seq": seq, "msg_id": "u\(seq)", "run_id": run, "raw": raw, "by": "slash"])
            m.client.feed(["kind": "start", "session_id": sid, "run_id": run, "seq": 1, "raw": raw])
        }
        m.client.feed(["kind": "session.message", "session_id": sid, "seq": 1, "msg_id": "u1", "role": "user", "text": "/cua a", "via": "cua"])
        task("r1", seq: 2, raw: "写周报")
        check(rec.log.isEmpty, "the switch off: no recording")
        m.client.feed(["kind": "task_done", "session_id": sid, "run_id": "r1", "seq": 2, "status": "succeeded", "reason": "", "summary": "", "result_card": NSNull()])
        m.setRecording(true)
        check(m.recordsNext, "switched on")
        task("r2", seq: 3, raw: "发邮件")
        m.client.feed(["kind": "step", "session_id": sid, "run_id": "r2", "seq": 2, "step_id": "st1", "text": "click", "human": "点「发送」"])
        check(rec.log == ["start:发邮件", "step:1"], "its next task: recorded, its step on the panel: \(rec.log)")
        // the executor killed: the session ends the task (task_end) -- stopped, the movie on its row
        m.client.feed(["kind": "session.task_end", "session_id": sid, "seq": 4, "run_id": "r2", "status": "failed"])
        check(rec.log.last == "stop" && rec.log.filter { $0 == "stop" }.count == 1 && m.movies["r2"] == "/tmp/movie.mov", "its end: stopped once, 「已录制」: \(rec.log)")
        rec.ok = false
        task("r3", seq: 5, raw: "再来")
        m.client.feed(["kind": "task_done", "session_id": sid, "run_id": "r3", "seq": 2, "status": "stopped", "reason": "", "summary": "", "result_card": NSNull()])
        check(rec.log.filter { $0 == "stop" }.count == 1, "a start that failed: no stop after it: \(rec.log)")
    }

    /// Only this path asks the helper to record: record_start in RunRecorder alone, RunRecorder.begin from
    /// AppTaskRecorder alone.
    static func staticTests() {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fm = FileManager.default
        var starts: [String] = [], begins: [String] = []
        for sub in ["Main", "Shared"] {
            for f in (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent(sub).path)) ?? [] where f.hasSuffix(".swift") {
                let c = (try? String(contentsOf: dir.appendingPathComponent("\(sub)/\(f)"), encoding: .utf8)) ?? ""
                let code = c.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
                if code.contains("\"record_start\"") { starts.append(f) }
                if code.contains("RunRecorder.shared.begin(") { begins.append(f) }
            }
        }
        check(starts == ["Recording.swift"] && begins == ["Recording.swift"], "only RunRecorder asks to record, only AppTaskRecorder starts it: \(starts) \(begins)")
        let rec = (try? String(contentsOf: dir.appendingPathComponent("Main/Recording.swift"), encoding: .utf8)) ?? ""
        let app = rec.components(separatedBy: "final class AppTaskRecorder").last ?? ""
        check(app.contains("RunRecorder.shared.begin(") && rec.contains(".nonactivatingPanel"), "the recorder through the helper; the decision panel takes no focus")
    }
}
