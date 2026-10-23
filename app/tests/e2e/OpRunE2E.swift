// The helper's op run (HarnessRun.run, as HandsHelper calls it — the old window's task) on a support folder of its
// own, its harness wrapped onto the simulated computer (tests/e2e/node-wrapper.sh: it refuses any request that is not
// the helper's `driver: hands`, and rewrites it to `sim`), a fake model on localhost (fake2.py). Checks models.off
// against it: a run waiting on its card stops with no model call after (and says why), the card's answer gate, a
// models.off between accepting a run and starting its harness, models.off twice (one stop), undo on a lingering run.
// Run by tests/e2e/session.sh, which lays out <dir>/bin/{OpRunE2E, runtime/node/bin/node (the wrapper),
// runtime/harness/harness.mjs, runtime/wrapper.env}.
//   OpRunE2E <scenario> <fake model url>
import AppKit
import Foundation

@main
enum OpRunE2E {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var events: [[String: Any]] = []
    nonisolated(unsafe) static var stops = 0
    static let evLock = NSLock()
    nonisolated(unsafe) static var modelURL = ""

    static func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL") \(what)"); fflush(stdout)
        if !ok { failures += 1 }
    }
    static func until(_ s: Double, _ f: () -> Bool) -> Bool {
        let t = Date().addingTimeInterval(s)
        while Date() < t { if f() { return true }; Thread.sleep(forTimeInterval: 0.05) }
        return f()
    }
    static func calls() -> Int {
        guard let d = try? Data(contentsOf: URL(string: modelURL + "/calls")!),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return -1 }
        return o["calls"] as? Int ?? -1
    }
    static func evs(_ name: String) -> [[String: Any]] {
        evLock.lock(); defer { evLock.unlock() }
        return events.filter { $0["event"] as? String == name }
    }
    static func names() -> [String] {
        evLock.lock(); defer { evLock.unlock() }
        return events.map { e in
            let name = e["event"] as? String ?? "?"
            return name == "error" ? "error(\(e["code"] ?? ""): \(e["error"] ?? ""))" : name     // (an error says what it was)
        }
    }

    /// The op run as HandsHelper.serve starts it (refusesRun, accept, HarnessRun.run on its own thread).
    static func startRun(_ goal: String = "给笔记换个颜色", folder: String? = nil) -> Bool {
        evLock.lock(); events = []; evLock.unlock()
        var req: [String: Any] = ["op": "run", "engine": "harness", "goal": goal, "config": "openai:local|fake", "lang": "zh"]
        if let folder { req["folder"] = folder }
        if let r = SessionHost.refusesRun(req) { print("refused: \(r)"); return false }
        guard Runner.accept() else { print("not accepted"); return false }
        var spec = Runner.Spec(req)
        spec.runID = "run_" + UUID().uuidString.lowercased().prefix(8)
        Thread.detachNewThread {
            HarnessRun.run(spec) { e in evLock.lock(); events.append(e); evLock.unlock(); return true }
        }
        return true
    }

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let a = CommandLine.arguments
        let scenario = a[1]; modelURL = a[2]
        let exe = Bundle.main.bundleURL
        let root = exe.deletingLastPathComponent()
        let support = root.appendingPathComponent("support-\(scenario)")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        DeskMindIPC.supportOverride = support
        SessionHost.setup = .init(node: URL(fileURLWithPath: "/"), bundle: URL(fileURLWithPath: "/"), dir: support, cwd: nil,
                                  logs: support.appendingPathComponent("logs"), environment: { _ in [:] }, prepare: {}, idleSeconds: 300, driver: "sim")
        guard Runner.runtime.path.hasSuffix("/oprun/bin/runtime") else { print("FAIL runtime is \(Runner.runtime.path), not the test's"); exit(1) }
        // prepareWork: nothing to copy (the working copy says the shipped version)
        try? FileManager.default.createDirectory(at: Runner.work, withIntermediateDirectories: true)
        try? "e2e".write(to: Runner.work.appendingPathComponent(".version"), atomically: true, encoding: .utf8)
        // as HandsHelper.main wires it
        SessionHost.onModelsOff = { evLock.lock(); stops += 1; evLock.unlock(); HarnessRun.stopForModelsOff() }
        print("runtime \(Runner.runtime.path), support \(support.path)")
        _ = SessionHost.modelsOff(["off": false])

        switch scenario {
        case "stop": stopScenario()
        case "gate": gateScenario()
        case "race": raceScenario()
        case "twice": twiceScenario()
        case "undo": undoScenario(root.appendingPathComponent("ws"))
        default: print("unknown scenario"); exit(2)
        }
        print(failures == 0 ? "op-run e2e \(scenario): all passed" : "op-run e2e \(scenario): \(failures) failed")
        exit(Int32(min(failures, 100)))
    }

    /// An old-window cloud op run waits on a card → models.off true → the run stops → no further model call.
    static func stopScenario() {
        guard startRun() else { check(false, "run started"); return }
        check(until(60) { !evs("ask").isEmpty }, "the run shows its card (events: \(names()))")
        let c0 = calls()
        let r = SessionHost.modelsOff(["off": true])
        check(r["ok"] as? Bool == true, "models.off true acked: \(r)")
        check(stops == 1, "onModelsOff called once (\(stops))")
        check(until(25) { !evs("done").isEmpty }, "the run ends after models.off (events: \(names()))")
        let done = evs("done").first ?? [:]
        print("  done: \(done)")
        check(done["reason"] as? String == "models_off" && done["exit"] as? Int == 0, "the run says it stopped because cloud models went off (\(done["reason"] ?? "-"))")
        check(Runner.current == nil && !Runner.busy, "the helper is free again")
        Thread.sleep(forTimeInterval: 4)
        check(calls() == c0, "no model call after models.off (\(c0) → \(calls()))")
        // a second models.off with nothing going: nothing happens
        let r2 = SessionHost.modelsOff(["off": true])
        check(r2["ok"] as? Bool == true && calls() == c0, "a repeated models.off is harmless")
        // a new op run is refused now
        let refused = SessionHost.refusesRun(["engine": "harness", "goal": "x"])
        check(refused?["code"] as? String == "no_model", "a new cloud op run is refused")
    }

    /// While off with a card still open (the stop not yet taken effect): a pick is refused, the way out passes.
    static func gateScenario() {
        guard startRun() else { check(false, "run started"); return }
        check(until(60) { !evs("ask").isEmpty }, "the run shows its card (events: \(names()))")
        let ask = evs("ask").first ?? [:]
        let askID = ask["ask_id"] as? String ?? ""
        let opts = ask["options"] as? [String] ?? []
        print("  card: \(ask["question"] ?? "") options \(opts) kinds \((ask["card"] as? [String: Any])?["options"] ?? "")")
        let saved = SessionHost.onModelsOff
        SessionHost.onModelsOff = {}          // the stop has not reached the run yet
        _ = SessionHost.modelsOff(["off": true])
        SessionHost.onModelsOff = saved
        let c0 = calls()
        let pick = HarnessRun.answer(HarnessEvents.CardButton.option(0, opts.first ?? "").request(askID: askID))
        check(pick["code"] as? String == "no_model", "a pick while off is refused no_model: \(pick)")
        let words = HarnessEvents.CardButton.words("用绿色").request(askID: askID)
        let w = HarnessEvents.answer_(words)
        check(w["code"] as? String == "no_model", "words while off are refused no_model: \(w)")
        // the cancel option by its own button (an option whose kind is cancel)
        let kinds = ((ask["card"] as? [String: Any])?["options"] as? [[String: Any]] ?? []).map { $0["kind"] as? String ?? "" }
        if let ci = kinds.firstIndex(of: "cancel") {
            let shown = ((ask["card"] as? [String: Any])?["options"] as? [[String: Any]] ?? []).filter { $0["text"] is String }
            let n = shown.firstIndex { $0["kind"] as? String == "cancel" } ?? ci
            let r = HarnessRun.answer(HarnessEvents.CardButton.option(n, opts[n]).request(askID: askID))
            check(r["ok"] as? Bool == true, "the cancel option passes while off: \(r)")
        } else {
            let r = HarnessRun.answer(HarnessEvents.CardButton.deny.request(askID: askID))
            check(r["ok"] as? Bool == true, "deny passes while off: \(r)")
        }
        check(until(25) { !evs("done").isEmpty }, "the run ends (events: \(names()))")
        Thread.sleep(forTimeInterval: 4)
        check(calls() == c0, "no model call after the way out (\(c0) → \(calls()))")
    }

    /// models.off true arrives after the op run was accepted, before its harness started (HarnessRun.input nil).
    static func raceScenario() {
        Runner.clearing.lock()                       // the run waits here (a 「清除全部」 going), as long as it takes
        guard startRun() else { check(false, "run started"); Runner.clearing.unlock(); return }
        Thread.sleep(forTimeInterval: 0.5)
        let c0 = calls()
        let r = SessionHost.modelsOff(["off": true])
        check(r["ok"] as? Bool == true && stops == 1, "models.off true acked while the run is accepted, not launched")
        Runner.clearing.unlock()
        _ = until(30) { !evs("ask").isEmpty || !evs("done").isEmpty || !evs("error").isEmpty }
        Thread.sleep(forTimeInterval: 2)
        print("  events: \(names())")
        check(calls() == c0, "no model call for a run accepted before models.off (\(c0) → \(calls()))")
        check(evs("ask").isEmpty && (evs("done").first?["reason"] as? String) == "models_off",
              "it never started its task, and says why (\(evs("done").first?["reason"] ?? "-"))")
        if !evs("ask").isEmpty { Runner.requestStop() }
        _ = until(25) { !evs("done").isEmpty }
    }

    /// models.off true twice in a row while the run waits on its card: one stop, one done, no crash.
    static func twiceScenario() {
        guard startRun() else { check(false, "run started"); return }
        check(until(60) { !evs("ask").isEmpty }, "the run shows its card")
        let c0 = calls()
        let t0 = Date()
        let s0 = HarnessRun.stopSchedules
        _ = SessionHost.modelsOff(["off": true])
        Thread.sleep(forTimeInterval: 0.2)
        _ = SessionHost.modelsOff(["off": true])
        check(HarnessRun.stopSchedules - s0 == 1, "the stop's signals scheduled once (\(HarnessRun.stopSchedules - s0)): a second SIGINT would cut the driver's wait")
        check(until(25) { !evs("done").isEmpty }, "the run ends (events: \(names()))")
        print("  ended after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s; done: \(evs("done").first ?? [:])")
        check(evs("done").count == 1, "one done")
        Thread.sleep(forTimeInterval: 3)
        check(calls() == c0, "no model call (\(c0) → \(calls()))")
    }
}

extension OpRunE2E {
    /// A finished run lingering for its result card → models.off true → not stopped; its undo still works, no model call.
    static func undoScenario(_ ws: URL) {
        try? FileManager.default.removeItem(at: ws)
        try? FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        guard startRun("在文件夹里建一个 a.txt", folder: ws.path) else { check(false, "run started"); return }
        var answered = 0
        let over = until(90) {
            if let a = evs("ask").dropFirst(answered).first {
                answered += 1
                print("  card: \((a["card"] as? [String: Any])?["kind"] ?? "") \(a["question"] ?? "")")
                _ = HarnessRun.answer(HarnessEvents.CardButton.approve.request(askID: a["ask_id"] as? String ?? ""))
            }
            return !evs("done").isEmpty
        }
        check(over, "the run is over (events: \(names()))")
        let td = evs("task_done").first ?? [:]
        print("  task_done: status \(td["harness_status"] ?? td["status"] ?? "") card \(td["result_card"] ?? td["card"] ?? "none")")
        check(FileManager.default.fileExists(atPath: ws.appendingPathComponent("a.txt").path), "the file was made")
        check(HarnessRun.undoWaiting, "the run lingers for its result card")
        let c0 = calls()
        let r = SessionHost.modelsOff(["off": true])
        check(r["ok"] as? Bool == true, "models.off true acked")
        Thread.sleep(forTimeInterval: 1)
        check(HarnessRun.undoWaiting, "a lingering run is left alone by models.off")
        _ = SessionHost.modelsOff(["off": true])
        check(HarnessRun.undoWaiting, "and by a repeated models.off")
        let tdEv = evs("task_done").first ?? [:]
        let card = (tdEv["result_card"] as? [String: Any]) ?? [:]
        let kinds = (card["options"] as? [[String: Any]] ?? []).map { $0["kind"] as? String ?? "" }
        print("  result card options: \(kinds)")
        let undo = kinds.firstIndex(of: "undo") ?? 1
        let runID = tdEv["run_id"] as? String ?? ""
        let resp = HarnessRun.respond(runID: runID, option: undo, wait: 10)
        print("  respond: \(resp)")
        check(resp["ok"] as? Bool == true && ((resp["result"] as? [String: Any])?["undone"] as? Int) == 1, "undo on the lingering run works while off")
        check(!FileManager.default.fileExists(atPath: ws.appendingPathComponent("a.txt").path), "the file is gone")
        Thread.sleep(forTimeInterval: 2)
        check(calls() == c0, "no model call for the undo (\(c0) → \(calls()))")
    }
}

extension HarnessEvents {
    static func answer_(_ req: [String: Any]) -> [String: Any] { HarnessRun.answer(req) }
}
