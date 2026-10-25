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
        DecisionTests.group("recording.gate"); gateTests()
    }

    static func tableTests() {
        typealias T = TaskRecording
        var r = T()
        check(r.apply(.taskStarted(session: "s", run: "r1")).isEmpty, "the switch off (the default): nothing records")
        check(r.apply(.toggled(session: "s", on: true)).isEmpty, "turned on between tasks: nothing yet")
        check(r.apply(.taskStarted(session: "s", run: "r2")) == [.start(session: "s", run: "r2")], "the next task starts: recorded")
        check(r.apply(.taskStarted(session: "t", run: "r3")).isEmpty, "another conversation's task meanwhile: not (one at a time, its switch off)")
        check(r.apply(.taskEnded(run: "r3")).isEmpty, "its end: nothing")
        check(r.apply(.taskEnded(run: "r2")) == [.ended(session: "s", run: "r2")], "the recorded task ends: the helper stopped it; the movie awaited")
        check(r.apply(.taskEnded(run: "r2")).isEmpty, "told again: once")
        _ = r.apply(.taskStarted(session: "s", run: "r4"))
        check(r.apply(.toggled(session: "s", on: false)) == [.cancel(run: "r4")], "switched off while recording: cancelled")
        _ = r.apply(.toggled(session: "s", on: true)); _ = r.apply(.taskStarted(session: "s", run: "r5"))
        check(r.apply(.appQuit) == [.cancel(run: "r5")], "the app quits while recording: cancelled")
        _ = r.apply(.taskStarted(session: "s", run: "r6"))
        _ = r.apply(.startFailed(run: "r6"))
        check(r.apply(.taskEnded(run: "r6")).isEmpty && r.recordingRun == nil, "the helper said no: nothing after")
        var d = T(); d.defaultOn = true
        check(d.apply(.taskStarted(session: "old", run: "x")).isEmpty, "(#127 delta) the last choice never turns an existing conversation on")
    }

    /// (#127 Codex at 24cbf17 and 29841c4) The helper owns the recording (RecordingOwner, the model
    /// Helper/ScreenRecorder.swift follows under its one lock): random interleavings of the app's starts (late ones
    /// too: sent before the run's end, come after it), lost cancels asked again, runs ending every way, the capture's
    /// setup as a move of its own (between the start's registering and its check), the helper quitting. Never an
    /// active capture the owner does not own, nor one for a run that is not running or was cancelled; every capture
    /// kept makes its own movie, once.
    static func sequenceTests() {
        typealias O = RecordingOwner
        var g = CardStoreTests.RNG(x: 21)
        for seed in 0..<1000 {
            var o = O()
            var running: Set<String> = []        // tasks running now (the helper's own word: SessionHost)
            var cancelled: Set<String> = []      // runs the app cancelled (the helper may not have heard yet)
            var pending: [(run: String?, token: Int)] = []     // set-ups in progress (outside the lock)
            var active: (run: String?, token: Int)? = nil      // the capture kept
            var kept: [String] = [], movies: [String] = []
            var asks: [String] = []              // the app's starts on their way (may come late, or never)
            func run(_ e: O.Event) {
                for d in o.apply(e) {
                    switch d {
                    case .refuse: break
                    case .setUp(let r, let t): pending.append((r, t))
                    case .keep(let t):
                        guard let i = pending.firstIndex(where: { $0.token == t }) else { break }
                        active = pending.remove(at: i); if let r = active?.run { kept.append(r) }
                    case .tearDown(let t): pending.removeAll { $0.token == t }
                    case .end(let r):
                        if active?.run == r, let rr = r { movies.append(rr) }
                        active = nil
                    }
                }
            }
            for step in 0..<40 {
                let r = "r\(step)"
                switch g.next(7) {
                case 0:   // a task starts (switch on): the app's start on its way
                    if running.isEmpty { running.insert(r); asks.append(r) }
                case 1:   // a start arrives -- maybe after its run's end, maybe never
                    if !asks.isEmpty { let a = asks.removeFirst(); if g.next(5) != 0 { run(.start(run: a, live: running.contains(a))) } }
                case 2:   // a set-up finishes (ok, or it failed)
                    if let p = pending.first { pending.removeFirst(); let ok = g.next(5) != 0; pending.insert(p, at: 0); run(.setUp(token: p.token, ok: ok)); pending.removeAll { $0.token == p.token } }
                case 3:   // a task ends, any way: the helper sees it
                    if let t = running.first { running.remove(t); run(.runEnded(run: t)) }
                case 4:   // the switch off: a cancel (maybe lost; the app asks it again: modelled as arriving now or later)
                    if let t = running.first, !cancelled.contains(t) { cancelled.insert(t); run(.cancel(run: t)) }
                case 5:   // the helper quits (its tasks gone with it)
                    if g.next(6) == 0 { run(.quit); running = []; pending = []; active = nil; asks = [] }
                default: break
                }
                if let a = active {
                    let owned = o.capturing == .some(a.run)
                    let ok = a.run.map { running.contains($0) && !cancelled.contains($0) } ?? true
                    if !owned || !ok { check(false, "seed \(seed) step \(step): a capture of \(String(describing: a.run)) owned \(owned), wanted \(ok)"); return }
                }
            }
            for t in running { run(.runEnded(run: t)) }
            for p in pending { run(.setUp(token: p.token, ok: true)) }
            if active != nil || o.capturing != nil { check(false, "seed \(seed): still capturing after every run ended"); return }
            if kept != movies { check(false, "seed \(seed): kept \(kept) vs movies \(movies)"); return }
        }
        // the rows (Codex's repros among them)
        var o = O()
        check(o.apply(.start(run: "a", live: true)) == [.setUp(run: "a", token: 1)] && o.apply(.setUp(token: 1, ok: true)) == [.keep(token: 1)], "a start: set up, kept")
        check(o.apply(.start(run: "b", live: true)) == [.end(run: "a"), .setUp(run: "b", token: 2)], "the next task's start: the last one's movie, then this")
        _ = o.apply(.setUp(token: 2, ok: true))
        check(o.apply(.runEnded(run: "b")) == [.end(run: "b")] && o.capturing == nil, "its run ends: stopped by the helper")
        check(o.apply(.start(run: "b", live: true)) == [.refuse], "(Codex 1) a late start for an ended run: refused (its tombstone)")
        check(o.apply(.start(run: "c", live: false)) == [.refuse], "(Codex 1) a start for a run the helper does not know running: refused")
        check(o.apply(.cancel(run: "d")).isEmpty && o.apply(.start(run: "d", live: true)) == [.refuse], "a cancel before its start: kept, the start refused")
        _ = o.apply(.start(run: "e", live: true))
        check(o.apply(.cancel(run: "e")).isEmpty && o.apply(.setUp(token: 3, ok: true)) == [.tearDown(token: 3)] && o.capturing == nil,
              "(Codex 2) a stop while it is set up: the set-up torn down, nothing kept")
        _ = o.apply(.start(run: "f", live: true)); _ = o.apply(.setUp(token: 4, ok: true))
        check(o.apply(.quit) == [.end(run: "f")], "the helper quits: stopped")
    }

    final class FakeRecorder: TaskRecorder {
        var log: [String] = []
        var ok = true
        var saved: [String: (URL) -> Void] = [:]
        func start(goal: String, run: String, session: String, started: @escaping (Bool) -> Void) { log.append("start:\(goal)"); started(ok) }
        func cancel(run: String) { log.append("cancel:\(run)") }
        func ended(run: String, session: String, saved s: @escaping (URL) -> Void) { log.append("ended:\(run)"); saved[run] = s }
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
        // the executor killed: the session ends the task (task_end) -- the helper stopped it; the movie awaited, then shown
        m.client.feed(["kind": "session.task_end", "session_id": sid, "seq": 4, "run_id": "r2", "status": "failed"])
        check(rec.log.last == "ended:r2" && !rec.log.contains { $0.hasPrefix("cancel") }, "its end: nothing sent, the movie awaited: \(rec.log)")
        rec.saved["r2"]?(URL(fileURLWithPath: "/tmp/movie.mov"))
        check(m.movies["r2"] == "/tmp/movie.mov", "the movie made: 「已录制」")
        // switched off mid-task: cancelled
        task("r3", seq: 5, raw: "再来")
        m.setRecording(false)
        check(rec.log.contains("cancel:r3"), "switched off mid-task: cancelled")
        // (#127 delta, 3) another conversation that never touched the switch: not recorded though the last choice was on
        m.setRecording(true)
        let other = "ses_other"
        m.client.feed(["kind": "session.message", "session_id": other, "seq": 1, "msg_id": "o1", "role": "user", "text": "/cua b", "via": "cua"])
        m.client.feed(["kind": "session.task", "session_id": other, "seq": 2, "msg_id": "o1", "run_id": "ro", "raw": "别的", "by": "slash"])
        m.client.feed(["kind": "start", "session_id": other, "run_id": "ro", "seq": 1, "raw": "别的"])
        check(!rec.log.contains("start:别的"), "an untouched conversation: not recorded")
        // (#127 Codex) a new conversation (none selected yet): the switch is kept and carried to its session
        let d = ShellModel(client: SessionClient(transport: CardStoreTests.Wire()), defaults: ShellTests.scratchDefaults(), config: { "openai:local|fake" },
                           lang: { .zhHans }, takeBackAfter: timers.after, now: { timers.now }, work: { $0() }, deliver: { $0() })
        d.setRecording(true)
        check(d.selected == nil && d.recordsNext && d.recording.defaultOn, "a draft conversation: the switch on, kept")
    }

    /// The helper's side, as written: it follows RecordingOwner, stops a run's recording at the run's end and at its
    /// quit, answers a cancel at once; the record-start rule.
    static func gateTests() {
        // the helper takes a start for the task that holds the computer, none for another
        check(RecordStart.allowed(acting: false, holderRun: nil, forRun: nil), "nothing acting: yes")
        check(RecordStart.allowed(acting: true, holderRun: "r1", forRun: "r1"), "(#127 delta, 2) the task holding the computer: its own recording, yes")
        check(!RecordStart.allowed(acting: true, holderRun: "r1", forRun: "r2") && !RecordStart.allowed(acting: true, holderRun: "r1", forRun: nil),
              "another task acting: no")
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let helper = (try? String(contentsOf: dir.appendingPathComponent("Helper/HandsHelper.swift"), encoding: .utf8)) ?? ""
        let host = (try? String(contentsOf: dir.appendingPathComponent("Helper/SessionHost.swift"), encoding: .utf8)) ?? ""
        check(helper.contains("RecordStart.allowed(acting: ComputerLock.acting, holderRun: ComputerLock.read()?.runID, forRun: forRun)"),
              "record_start decides by the rule")
        check(host.contains("if ScreenRecorder.records(run) { recordApp(ev) }"), "(#127 delta, 6) only the recorded task's steps add apps")
        let screen = (try? String(contentsOf: dir.appendingPathComponent("Helper/ScreenRecorder.swift"), encoding: .utf8)) ?? ""
        check(!screen.contains("nonisolated(unsafe) static var forRun") && screen.contains("rec.forRun = forRun")
              && screen.contains("return active?.forRun == run"), "(#127 Codex) the task the recording is for: the recording's own, read under its lock")
        check(host.contains("ScreenRecorder.runEnded(run)") && helper.contains("ScreenRecorder.quit()")
              && helper.contains("ScreenRecorder.stop(forRun: req[\"for_run\"] as? String, wait: false)"),
              "(#127 Codex at 24cbf17) the helper stops a recording at its run's end and its own quit; a cancel answers at once")
        check(screen.contains("owner.apply(.start(run: forRun, live: live))") && screen.contains("owner.apply(.setUp(token: token, ok: error == nil))")
              && screen.contains("SessionHost.liveRuns().contains($0)") && screen.contains("owner.apply(.runEnded(run: run))")
              && screen.contains("owner.apply(.cancel(run: forRun))") && screen.contains("RecordingOwner.savedFile"),
              "the recorder follows RecordingOwner; the movie's path beside the run")
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
