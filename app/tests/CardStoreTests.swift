// M2 A1: a card has exactly one ending (answered, voided or expired); every view reads the same state; an answer is
// sent at most once. Through the window's model (ShellModel) on a simulated helper: the take-back (3 s, cancellable,
// sent once), 「先别做了」 and Stop at once, an answer racing a void or an expiry, 「现在回答」 (reask), a late answer
// refused, an app restart (with its replay fed twice).
//
// - tableTests: the plan's §4.2 table, cell by cell (phase × event → phase, and what was written).
// - allOrdersTests: every order of {pick, 3 s, resumed, expiry, task_done, restart}, against a spec of the outcome.
// - propertyTests: random runs of a simulated harness (its cards, its own record of each card's ending, its stdin read
//   when it reads it) and a user (picks, take-backs, the way out, Stop, 「现在回答」, restarts), lines delivered in any
//   order; the oracle is the simulated harness's record and the user's own actions, never the app's algorithm.
// - viewsTests: the views read a card only through its phase.
// Run from DecisionTests.main (build.sh).

import Combine
import Foundation

enum CardStoreTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "cards: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("cards.wireTests"); wireTests()
        DecisionTests.group("cards.movedOnTests"); movedOnTests()
        DecisionTests.group("cards.cloudOffTests"); cloudOffTests()
        DecisionTests.group("cards.uiQueueTests"); uiQueueTests()
        DecisionTests.group("cards.tableTests"); tableTests()
        DecisionTests.group("cards.allOrdersTests"); allOrdersTests()
        DecisionTests.group("cards.propertyTests"); propertyTests()
        DecisionTests.group("cards.viewsTests"); viewsTests()
    }

    // MARK: - the rig: one session, one run, a helper that records what the app writes

    /// The helper as the app sees it: every send is taken (ok), and recorded with the app's life it came from.
    final class Wire: SessionTransport {
        private let lock = NSLock()
        private var _lines: [(life: Int, line: [String: Any])] = []
        var life = 1
        /// Called with each control line as it is written (the simulated harness's stdin).
        var onLine: (([String: Any]) -> Void)?
        var lines: [(life: Int, line: [String: Any])] { lock.lock(); defer { lock.unlock() }; return _lines }
        func request(_ body: [String: Any]) -> [String: Any]? {
            if body["op"] as? String == SessionClient.Op.send, let l = body["line"] as? [String: Any], l["type"] as? String != "set_config" {
                lock.lock(); _lines.append((life, l)); lock.unlock()
                onLine?(l)
            }
            return ["ok": true]
        }
        func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool { false }
        /// The card answers written (answer lines), by ask_id.
        func answers(_ askId: String, life: Int? = nil) -> [[String: Any]] {
            lines.filter { ($0.life == life || life == nil) && $0.line["type"] as? String == "answer" && $0.line["ask_id"] as? String == askId }.map(\.line)
        }
        func count(_ type: String) -> Int { lines.filter { $0.line["type"] as? String == type }.count }
    }

    static let sid = "ses_c"
    static let rid = "r1"

    static func cardJSON(_ kind: String) -> [String: Any] {
        switch kind {
        case "plan":
            return ["kind": "plan", "text": "计划：1. 打开备忘录 2. 改标题", "blocking": true, "free_text": true,
                    "options": [["kind": "approve", "text": "可以，就这样做"], ["kind": "cancel", "text": "先别做了"]]]
        case "ambiguity":
            return ["kind": "ambiguity", "text": "你说的是哪一个？", "blocking": true, "free_text": true,
                    "options": [["kind": "reading", "text": "周报.txt"], ["kind": "reading", "text": "周报-终稿.txt"],
                                ["kind": "delegate", "text": "由你决定"], ["kind": "cancel", "text": "先别做了"]]]
        case "missing":
            return ["kind": "missing", "text": "发给谁？", "blocking": true, "free_text": true,
                    "options": [["kind": "value", "text": "小王"], ["kind": "delegate", "text": "由你决定"], ["kind": "cancel", "text": "先别做了"]]]
        default:
            return ["kind": "action", "text": "这会把内容发出去：在 Mail 里点「发送」", "blocking": true, "free_text": false,
                    "options": [["kind": "approve", "text": "可以"], ["kind": "skip_step", "text": "这一步不要"], ["kind": "cancel", "text": "先别做了"]]]
        }
    }

    /// The window's model on a Wire, its take-back on a test clock, with the session and its task begun.
    final class Rig {
        let wire = Wire()
        let timers: ShellTests.Timers
        var m: ShellModel
        var runSeq = 0
        /// Every line the app was given, in order (a restart replays them).
        var fed: [[String: Any]] = []

        init(timers: ShellTests.Timers = ShellTests.Timers()) {
            self.timers = timers
            m = Rig.make(wire, timers)
            feed(["kind": "session.message", "session_id": sid, "seq": 1, "msg_id": "u1", "role": "user", "text": "/cua 发周报", "via": "cua"])
            feed(["kind": "session.task", "session_id": sid, "seq": 2, "msg_id": "u1", "run_id": rid, "raw": "发周报", "by": "slash"])
            feed(line("start", ["raw": "发周报"]))
        }

        static func make(_ wire: Wire, _ t: ShellTests.Timers) -> ShellModel {
            let m = ShellModel(client: SessionClient(transport: wire), defaults: ShellTests.scratchDefaults(), config: { "openai:local|fake" },
                               lang: { .zhHans }, takeBackAfter: t.after, now: { t.now }, work: { $0() }, deliver: { $0() })
            m.selected = sid
            return m
        }

        /// A run line with the run's next seq.
        func line(_ kind: String, _ f: [String: Any]) -> [String: Any] {
            runSeq += 1
            var l = f
            l["kind"] = kind; l["session_id"] = sid; l["run_id"] = rid; l["seq"] = runSeq
            return l
        }

        func feed(_ l: [String: Any]) { fed.append(l); m.client.feed(l) }
        func emit(_ kind: String, _ f: [String: Any]) { feed(line(kind, f)) }

        func ask(_ id: String, _ kind: String = "action") { emit("ask", ["ask_id": id, "card": cardJSON(kind)]) }
        func ask(_ id: String, card: [String: Any]) { emit("ask", ["ask_id": id, "card": card]) }
        func resumed(_ id: String) { emit("resumed", ["ask_id": id]) }
        func void(_ id: String, _ why: String) { emit("ask_void", ["ask_id": id, "why": why]) }
        func done(_ status: String = "stopped") { emit("task_done", ["status": status, "reason": "", "summary": ""]) }
        func lateRefused(_ id: String) { emit("refused", ["what": "answer for \(id)", "why": "the card expired", "by": "executor"]) }

        /// The app quits and opens again: a new model and client, the stored lines replayed — twice.
        func restart() {
            wire.life += 1
            m = Rig.make(wire, timers)
            for l in fed { m.client.feed(l) }
            for l in fed { m.client.feed(l) }
        }

        var state: SessionState { m.states[sid] ?? SessionState() }
        func cardState(_ id: String) -> CardState? { state.task(rid)?.cards.first { $0.askId == id } }
        func phase(_ id: String) -> CardPhase? { cardState(id).map { m.phase(rid, $0, in: state) } }
        func model(_ id: String) -> CardModel? { cardState(id).map { CardModel(card: $0.card, runId: rid, askId: id) } }

        /// A click on the card's first option of `role` (its whole body seen first, as a user who read it).
        func click(_ id: String, _ role: CardModel.Role, nth: Int = 0) {
            guard let c = model(id) else { return }
            m.cardBody(c, contentHeight: 10, visibleHeight: 10, offset: 0)
            let bs = c.buttons.filter { $0.role == role }
            if nth < bs.count { m.click(bs[nth]) }
        }
        func words(_ id: String, _ text: String) {
            guard let c = model(id) else { return }
            m.cardBody(c, contentHeight: 10, visibleHeight: 10, offset: 0)
            m.answer(c, text: text)
        }
        func takeBack(_ id: String) { if let c = model(id) { m.takeBack(c) } }
        func answerNow(_ id: String) { m.answerNow(rid, askId: id) }
    }

    // MARK: - the wire, the reducer's facts

    static func wireTests() {
        check(SessionWire.validate(["type": "reask", "run_id": "r1"]).line != nil, "reask with its run: passed on")
        check(SessionWire.validate(["type": "reask"]).error == "reask needs run_id", "reask without a run: refused")
        check(SessionWire.needsModel(["type": "reask", "run_id": "r1"]), "reask makes the model work: the helper refuses it while cloud models are off (#110 Codex review)")
        check(SessionControl.reask(runId: "r1").line as NSDictionary == ["type": "reask", "run_id": "r1"] as NSDictionary, "the control line")
        let r = Rig()
        r.ask("a1")
        check(SessionClient.reaskRefusal(rid, in: r.state) != nil, "an open card: no reask")
        r.void("a1", "timeout")
        check(r.state.task(rid)?.expiredCard?.askId == "a1" && SessionClient.reaskRefusal(rid, in: r.state) == nil, "expired: the task waits on it")
        check(r.state.composerEnabled, "an expired card is not open: the composer takes typing (plan §4.1)")
        check(r.state.status == .cardExpired(cardKind: "action") && r.state.status.shape == .haloDot, "the dot: expired, waiting for you")
        r.lateRefused("a1")
        check(r.state.task(rid)?.refusedAnswers == ["a1"], "a late answer refused: recorded on its card")
        if case .expired(true, .offered) = r.phase("a1") {} else { check(false, "expired, the late answer said: \(String(describing: r.phase("a1")))") }
        r.ask("a2")
        check(r.state.task(rid)?.expiredCard == nil && r.phase("a1") == .expired(late: true, answerNow: .gone), "a newer card: 「现在回答」 gone")
        r.done()
        check(SessionClient.reaskRefusal(rid, in: r.state) != nil, "an ended task: no reask")
        // a refusal by the user (Stop) is no late answer
        let s = Rig()
        s.ask("a1")
        s.emit("refused", ["what": "answer for a1", "why": "", "by": "user"])
        check(s.state.task(rid)?.refusedAnswers.isEmpty == true, "only the executor's refusal of an answer counts")
    }

    // MARK: - the task goes on without its expired card (#110 review at 2712bb4)

    /// After a card's timeout void, the run's own word that it went on — a steer it took, a step, a new plan, a refused
    /// 「现在回答」 — or Stop ends the wait on it: nothing pinned, the dot says what the task does, the window may stay
    /// back (taskRunningWithoutCard, which IslandView reads before bringing the main window forward).
    static func movedOnTests() {
        func waits(_ r: Rig) -> Bool { r.m.pinned(r.state) != nil || r.state.task(rid)?.expiredCard != nil }
        func refusedSaid(_ r: Rig, _ why: String) -> Bool { r.phase("a1").map { ShellText.cardState($0, lang: .en).contains(why) } ?? false }
        // R1: a steer after the expiry, then a step
        let a = Rig()
        a.ask("a1"); a.void("a1", CardState.timeout)
        check(waits(a) && !a.m.taskRunningWithoutCard, "expired: the task waits on its card")
        a.emit("steered", ["text": "改成发给小李"])
        check(!waits(a) && a.m.taskRunningWithoutCard, "a steer taken: no longer waiting on the expired card (\(String(describing: a.m.pinned(a.state)?.phase)))")
        check(ShellText.status(a.state.status, lang: .en).hasPrefix("Working"), "the dot: working, not expired: \(ShellText.status(a.state.status, lang: .en))")
        a.emit("step", ["step_id": "s9", "text": "click 发送", "purpose": "send"])
        a.answerNow("a1")
        check(a.wire.count("reask") == 0, "「现在回答」 on a card the task left: nothing sent")
        // R1b: a step alone (the executor acts again)
        let b = Rig()
        b.ask("a1"); b.void("a1", CardState.timeout)
        b.emit("step", ["step_id": "s2", "text": "observe", "purpose": "look again"])
        check(!waits(b) && b.m.taskRunningWithoutCard, "a step after the expiry: no longer waiting")
        // R2: 「现在回答」, the screen moved, it goes on without a card
        let c = Rig()
        c.ask("a1"); c.void("a1", CardState.timeout)
        c.answerNow("a1")
        check(c.wire.count("reask") == 1 && waits(c), "reask sent; waiting for what it brings")
        c.emit("step", ["step_id": "s2", "text": "observe", "purpose": "look again"])
        check(!waits(c) && c.m.taskRunningWithoutCard && c.m.cards.reasks.isEmpty, "the reask brought a step, no card: nothing pinned, nothing held")
        // a reask the executor refuses: its reason on the card, nothing pinned, never stuck on 「正在重新看屏幕…」
        let d = Rig()
        d.ask("a1"); d.void("a1", CardState.timeout)
        d.answerNow("a1")
        d.emit("refused", ["what": "reask", "why": "no card has expired", "by": "executor"])
        check(!waits(d) && d.m.cards.reasks.isEmpty && refusedSaid(d, "no card has expired"), "refused by the executor: said, not pinned: \(String(describing: d.phase("a1")))")
        d.answerNow("a1")
        check(d.wire.count("reask") == 1, "and not offered again")
        // … or by the session (its refusal names no run: the running task's expired card)
        let e = Rig()
        e.ask("a1"); e.void("a1", CardState.timeout)
        e.answerNow("a1")
        e.m.client.feed(["kind": "session.error", "session_id": sid, "code": "no_task", "text": "no card of this task has expired", "control": "reask"])
        check(!waits(e) && refusedSaid(e, "no card of this task has expired"), "refused by the session: said, not pinned: \(String(describing: e.phase("a1")))")
        // Stop beats the expiry: the dot says stopping until task_done
        let f = Rig()
        f.ask("a1"); f.void("a1", CardState.timeout)
        f.m.stop()
        f.emit("refused", ["what": "the task", "why": "stopped", "by": "user"])
        check(f.state.status == .stopping && !waits(f), "stopping: the dot says so, nothing pinned: \(f.state.status)")
        f.done()
        check(!waits(f) && f.phase("a1")?.ending == .expired, "ended: the card stays expired in the chat")
        // a timeout void that was replayed: the same (the run's order decides, not when the lines came)
        let g = Rig()
        g.ask("a1"); g.void("a1", CardState.timeout); g.emit("steered", ["text": "x"])
        g.restart()
        check(!waits(g), "after a restart's replay: still not waiting")
    }

    // MARK: - cloud models off (#110 Codex review at 0a5e9b5)

    /// A model whose cloud switch is the app's kind: read live through a ModelsOffSync (every write of it pushes, as
    /// CloudModelSettings.engineIsCloud does), its work queued until the test runs it.
    final class OffRig {
        var cloud = true
        var queued: [() -> Void] = []
        let wire = Wire()
        let timers = ShellTests.Timers()
        var sync: ModelsOffSync!
        var m: ShellModel!
        let feeder = Rig()
        init() {
            // (weak: the sync's retries run on its own queue and may outlive the rig — an unowned read then crashed)
            sync = ModelsOffSync(transport: wire, current: { [weak self] in !(self?.cloud ?? true) })
            m = ShellModel(client: SessionClient(transport: wire, modelsSync: sync), defaults: ShellTests.scratchDefaults(), config: { "openai:local|fake" },
                           lang: { .zhHans }, cloudOn: { [weak self] in self?.cloud ?? true }, takeBackAfter: timers.after, now: { [weak self] in self?.timers.now ?? 0 },
                           work: { [weak self] f in self?.queued.append(f) }, deliver: { $0() })
            m.selected = sid
            for l in feeder.fed { m.client.feed(l) }        // (the session and its task begun)
        }
        /// The switch written (and pushed, as the app's setter does).
        func set(cloud on: Bool) { cloud = on; sync.push() }
        func runWork() { while !queued.isEmpty { queued.removeFirst()() } }
        func feed(_ f: (Rig) -> Void) { let n = feeder.fed.count; f(feeder); for l in feeder.fed[n...] { m.client.feed(l) } }
        var state: SessionState { m.states[sid] ?? SessionState() }
        func card(_ id: String) -> CardModel { CardModel(card: state.task(rid)!.cards.first { $0.askId == id }!.card, runId: rid, askId: id) }
        func answers() -> Int { wire.count("answer") }
    }

    /// The take-back while the cloud switch moves, and the controls that make the model work, checked as they are sent.
    ///
    /// | during the 3 s take-back | outcome |
    /// |---|---|
    /// | nothing | the pick is sent at 3 s |
    /// | cloud turned off | the pick is dropped now and never sent, even if cloud comes back on |
    /// | 「先别做了」 / Stop | at once, as before (cloud off too: it reaches no model) |
    /// | the card moved on / expired | the pick is dropped (tableTests) |
    static func cloudOffTests() {
        // nothing: sent at 3 s
        let a = OffRig()
        a.feed { $0.ask("a1") }
        a.m.cardBody(a.card("a1"), contentHeight: 1, visibleHeight: 1, offset: 0)
        a.m.click(a.card("a1").buttons[0])
        a.timers.advance(CardStore.takeBack); a.runWork()
        check(a.answers() == 1, "nothing in between: the pick goes at 3 s")
        // off then on again within the 3 s: never sent
        let b = OffRig()
        b.feed { $0.ask("a1") }
        b.m.cardBody(b.card("a1"), contentHeight: 1, visibleHeight: 1, offset: 0)
        b.m.click(b.card("a1").buttons[0])
        b.timers.advance(1); b.set(cloud: false)
        b.timers.advance(1); b.set(cloud: true)
        b.timers.advance(CardStore.takeBack); b.runWork()
        check(b.answers() == 0, "cloud off and on again within the take-back: the held approve is never sent (\(b.answers()))")
        // off, not seen by the window at all (no settings path ran) and on again: still never sent
        let b2 = OffRig()
        b2.feed { $0.ask("a1") }
        b2.m.cardBody(b2.card("a1"), contentHeight: 1, visibleHeight: 1, offset: 0)
        b2.m.click(b2.card("a1").buttons[0])
        b2.cloud = false; b2.sync.push(); b2.cloud = true; b2.sync.push()
        b2.timers.advance(CardStore.takeBack); b2.runWork()
        check(b2.answers() == 0, "a toggle the window never saw: not sent either (the off-epoch)")
        // the 3 s ran out while on, its write still queued; cloud goes off before the write: not sent (checked as it goes)
        let c = OffRig()
        c.feed { $0.ask("a1") }
        c.m.cardBody(c.card("a1"), contentHeight: 1, visibleHeight: 1, offset: 0)
        c.m.click(c.card("a1").buttons[0])
        c.timers.advance(CardStore.takeBack)
        c.set(cloud: false); c.runWork()
        check(c.answers() == 0, "the approve's write queued, cloud off before it ran: not sent")
        // the way out goes, off or not
        let d = OffRig()
        d.feed { $0.ask("a1") }
        d.m.click(d.card("a1").buttons.first { $0.role == .cancel }!)
        d.set(cloud: false); d.runWork()
        check(d.answers() == 1, "先别做了: sent at once, cloud off too (it reaches no model)")
        // 「现在回答」 queued, cloud off before it ran: not sent; the button is offered again (when cloud is back)
        let e = OffRig()
        e.feed { $0.ask("a1"); $0.void("a1", CardState.timeout) }
        e.m.answerNow(rid, askId: "a1")
        e.set(cloud: false); e.runWork()
        check(e.wire.count("reask") == 0 && e.m.cards.reasks.isEmpty, "reask queued, cloud off before it went: not sent, not left 'asked'")
        // the two boundaries classify the same, control by control (the audit: what can make the model work)
        let table: [(SessionControl, String, Bool)] = [
            (.say("x"), "say", true), (.cua("x"), "cua", true), (.steer("x", runId: rid), "steer", true), (.retry, "retry", true),
            (.queueSendNow(id: "q"), "queue_send_now", true), (.reask(runId: rid), "reask", true),
            (.stop(runId: rid), "stop", false), (.queueEdit(id: "q", text: "x"), "queue_edit", false), (.queueCancel(id: "q"), "queue_cancel", false),
            (.attach(afterSeq: 0), "attach", false), (.answer(.respond(runId: rid, option: 0)), "respond", false)]
        for (ctl, type, model) in table {
            check(SessionClient.needsModel(ctl, in: SessionState()) == model, "the app: \(type) \(model ? "needs" : "does not need") the model")
            check(SessionWire.needsModel(ctl.line) == model, "the helper: \(type) \(model ? "needs" : "does not need") the model")
        }
        check(SessionWire.needsModel(["type": "set_config", "config": "x"]) && !SessionWire.needsModel(["type": "set_config", "config": NSNull()]), "set_config: a model only when not null")
        // a card's answer, by its option (the app's boundary: the helper does not see options)
        let s = Rig(); s.ask("a1"); s.ask("a2", "ambiguity")
        let st = s.state
        check(SessionClient.needsModel(.answer(.option(runId: rid, askId: "a2", option: 0)), in: st), "a reading: resumes the task")
        check(!SessionClient.needsModel(.answer(.option(runId: rid, askId: "a2", option: 3)), in: st), "the way out: no model")
        check(SessionClient.needsModel(.answer(.text(runId: rid, askId: "a2", text: "x")), in: st), "words: resume the task")
        check(SessionClient.needsModel(.answer(.option(runId: rid, askId: "zz", option: 0)), in: st), "a card the app can't find: counted as resuming")
    }

    // MARK: - CardStore only on the UI queue (#110 Codex review at 4a411c2)

    /// A model as the app has it: `deliver` hops to the main queue (pumped by the test), work inline on the caller.
    final class MainRig {
        let wire = Wire()
        let timers = ShellTests.Timers()
        private let lock = NSLock()
        private var _cloud = true
        var cloud: Bool { get { lock.lock(); defer { lock.unlock() }; return _cloud } set { lock.lock(); _cloud = newValue; lock.unlock() } }
        var m: ShellModel!
        let feeder = Rig()
        init() {
            m = ShellModel(client: SessionClient(transport: wire), defaults: ShellTests.scratchDefaults(), config: { "openai:local|fake" },
                           lang: { .zhHans }, cloudOn: { [weak self] in self?.cloud ?? true }, takeBackAfter: timers.after,
                           now: { [weak self] in self?.timers.now ?? 0 }, work: { $0() }, deliver: { f in DispatchQueue.main.async(execute: f) })
            m.selected = sid
            for l in feeder.fed { m.client.feed(l) }
            pump()
        }
        /// Lets the main queue run what was handed to it.
        func pump() { for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) } }
        func ask(_ id: String, _ kind: String = "action") { feeder.ask(id, kind); m.client.feed(feeder.fed.last!); pump() }
        func card(_ id: String) -> CardModel { CardModel(card: m.states[sid]!.task(rid)!.cards.first { $0.askId == id }!.card, runId: rid, askId: id) }
        /// `f` on another thread, waited for.
        func elsewhere(_ f: @escaping () -> Void) { let done = DispatchSemaphore(value: 0); Thread { f(); done.signal() }.start(); done.wait() }
    }

    /// applySettings runs on the watch thread too (ShellModel.start): it must never touch CardStore there. Checked by
    /// what the store holds right after a call from another thread (nothing changed until the main queue runs), by a
    /// late clear after the switch is on again (it leaves the new pick), and under a race with clicks on main.
    static func uiQueueTests() {
        // a held approve; the switch goes off and applySettings runs on another thread: the store is not touched there
        let a = MainRig()
        a.ask("a1")
        let c = a.card("a1")
        a.m.cardBody(c, contentHeight: 1, visibleHeight: 1, offset: 0)
        a.m.click(c.buttons[0])
        check(a.m.cards.picks.count == 1, "(held)")
        a.cloud = false
        a.elsewhere { a.m.applySettings() }
        check(a.m.cards.picks.count == 1, "applySettings on another thread: the store is not touched there (its clear waits for the main queue)")
        a.pump()
        check(a.m.cards.picks.isEmpty, "on the main queue: the held approve is dropped")
        a.cloud = true
        a.timers.advance(CardStore.takeBack)
        check(a.wire.count("answer") == 0, "and never sent")
        // a late clear: queued while off, run after the switch is on again and a new pick was made — the new pick stays
        let b = MainRig()
        b.ask("a1")
        let cb = b.card("a1")
        b.m.cardBody(cb, contentHeight: 1, visibleHeight: 1, offset: 0)
        b.cloud = false
        b.elsewhere { b.m.applySettings() }            // (its clear is queued, not run)
        b.cloud = true
        b.m.click(cb.buttons[0])                        // (picked after the switch came back)
        b.pump()                                        // (the late clear runs now)
        check(b.m.cards.picks.count == 1, "a late clear after the switch is on again: the new pick stays")
        b.timers.advance(CardStore.takeBack)
        check(b.wire.answers("a1").count == 1, "and goes at 3 s")
        // the race (Codex's), made to happen every time: the watch thread's applySettings with the switch off while main
        // holds a pick; at the moment that thread publishes a change of the store (objectWillChange, sent before the
        // store is written), main answers the card with 先别做了; then 先别做了 again. A clear that wrote back a copy taken
        // before main's `sent` erased it, and the card was answered twice. Exactly one answer.
        let r = MainRig()
        r.ask("a1", "ambiguity")
        let cr = r.card("a1")
        let pickIt = cr.buttons.first { $0.role == .choice }!, out = cr.buttons.first { $0.role == .cancel }!
        r.m.click(pickIt)
        check(r.m.cards.picks.count == 1, "(a pick held)")
        let lock = NSLock()
        var armed = true
        let mainGo = DispatchSemaphore(value: 0), mainDone = DispatchSemaphore(value: 0), bgDone = DispatchSemaphore(value: 0)
        let watch = r.m.objectWillChange.sink { _ in
            guard !Thread.isMainThread, (lock.withLock { let a = armed; armed = false; return a }) else { return }
            mainGo.signal(); _ = mainDone.wait(timeout: .now() + 5)
        }
        r.cloud = false
        Thread { r.m.applySettings(); bgDone.signal() }.start()
        let raced = mainGo.wait(timeout: .now() + 0.5) == .success
        r.m.click(out)                                  // (inside the other thread's write when it publishes one)
        if raced { mainDone.signal() }
        bgDone.wait()
        r.pump()
        r.m.click(out)
        r.pump()
        watch.cancel()
        check(r.wire.answers("a1").count == 1, "the watch thread's applySettings racing main's answer: one answer (\(r.wire.answers("a1").count)\(raced ? ", the other thread wrote the store" : ""))")
        // the store is reached only through its UI-queue check
        let src = (try? String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Shared/Shell.swift"), encoding: .utf8)) ?? ""
        check(src.components(separatedBy: "cardStore").count - 1 == 3 && src.contains("get { onUI(); return cardStore }") && src.contains("set { onUI(); cardStore = newValue }")
              && src.contains("dispatchPrecondition(condition: .onQueue(uiQueue))"), "CardStore: one stored copy, every read and write through the UI-queue check")
    }

    // MARK: - the table (plan §4.2), cell by cell

    enum Start: String, CaseIterable { case open, pending, sent, answered, voided, expired }
    enum Event: String, CaseIterable {
        case pick, repick, wayOut, takeBack, tick, resumed, voidSteer, voidStop, taskDone, timeout, answerNow, lateRefused, restart, stop
    }
    /// What a cell expects: the phase after, and how many answer / reask / stop lines the event wrote.
    struct Cell { var phase: String; var answers = 0; var reasks = 0; var stops = 0 }

    /// A phase's name, for the table.
    static func name(_ p: CardPhase?) -> String {
        switch p {
        case nil: return "none"
        case .open?: return "open"
        case .pending?: return "pending"
        case .sent?: return "sent"
        case .answered?: return "answered"
        case .voided(let w)?: return "voided:\(w)"
        case .expired(_, let n)?: return "expired:\(n)"
        }
    }

    static func setUp(_ start: Start) -> Rig {
        let r = Rig()
        r.ask("a1")
        switch start {
        case .open: break
        case .pending: r.click("a1", .approve)
        case .sent: r.click("a1", .approve); r.timers.advance(CardStore.takeBack)
        case .answered: r.resumed("a1")
        case .voided: r.void("a1", "steer")
        case .expired: r.void("a1", "timeout")
        }
        return r
    }

    static func apply(_ e: Event, _ r: Rig) {
        switch e {
        case .pick: r.click("a1", .approve)
        case .repick: r.click("a1", .skipStep)
        case .wayOut: r.click("a1", .cancel)
        case .takeBack: r.takeBack("a1")
        case .tick: r.timers.advance(CardStore.takeBack)
        case .resumed: r.resumed("a1")
        case .voidSteer: r.void("a1", "steer")
        case .voidStop: r.void("a1", "stop")
        case .taskDone: r.done()
        case .timeout: r.void("a1", "timeout")
        case .answerNow: r.answerNow("a1")
        case .lateRefused: r.lateRefused("a1")
        case .restart: r.restart()
        case .stop: r.m.stop()
        }
    }

    /// The plan's table, as data. A cell not listed: the event does not apply in that phase (nothing changes, nothing
    /// is written).
    static let table: [Start: [Event: Cell]] = [
        .open: [.pick: Cell(phase: "pending"), .repick: Cell(phase: "pending"), .wayOut: Cell(phase: "sent", answers: 1),
                .resumed: Cell(phase: "answered"), .voidSteer: Cell(phase: "voided:steer"), .voidStop: Cell(phase: "voided:stop"),
                .taskDone: Cell(phase: "voided:task_done"), .timeout: Cell(phase: "expired:offered"), .stop: Cell(phase: "open", stops: 1)],
        .pending: [.pick: Cell(phase: "pending"), .repick: Cell(phase: "pending"), .wayOut: Cell(phase: "sent", answers: 1),
                   .takeBack: Cell(phase: "open"), .tick: Cell(phase: "sent", answers: 1), .resumed: Cell(phase: "answered"),
                   .voidSteer: Cell(phase: "voided:steer"), .voidStop: Cell(phase: "voided:stop"), .taskDone: Cell(phase: "voided:task_done"),
                   .timeout: Cell(phase: "expired:offered"), .restart: Cell(phase: "open"), .stop: Cell(phase: "open", stops: 1)],
        .sent: [.resumed: Cell(phase: "answered"), .voidSteer: Cell(phase: "voided:steer"), .voidStop: Cell(phase: "voided:stop"),
                .taskDone: Cell(phase: "voided:task_done"), .timeout: Cell(phase: "expired:offered"), .restart: Cell(phase: "open"),
                .stop: Cell(phase: "sent", stops: 1)],
        .answered: [.taskDone: Cell(phase: "answered"), .stop: Cell(phase: "answered", stops: 1)],
        .voided: [.taskDone: Cell(phase: "voided:steer"), .stop: Cell(phase: "voided:steer", stops: 1)],
        .expired: [.answerNow: Cell(phase: "expired:asked", reasks: 1), .taskDone: Cell(phase: "expired:gone"),
                   .stop: Cell(phase: "expired:offered", stops: 1), .lateRefused: Cell(phase: "expired:offered")],
    ]

    static func tableTests() {
        var cells = 0
        for start in Start.allCases {
            for e in Event.allCases {
                let r = setUp(start)
                let before = name(r.phase("a1"))
                let answers = r.wire.count("answer"), reasks = r.wire.count("reask"), stops = r.wire.count("stop")
                apply(e, r)
                let want = table[start]?[e] ?? Cell(phase: before)
                let got = Cell(phase: name(r.phase("a1")), answers: r.wire.count("answer") - answers, reasks: r.wire.count("reask") - reasks,
                               stops: r.wire.count("stop") - stops)
                check(got.phase == want.phase && got.answers == want.answers && got.reasks == want.reasks && got.stops == want.stops,
                      "\(start.rawValue) × \(e.rawValue): \(got.phase) (answers \(got.answers), reasks \(got.reasks), stops \(got.stops)); want \(want.phase) (\(want.answers), \(want.reasks), \(want.stops))")
                // what follows the cell: the held answer of a pending start never goes out after the event ended the card,
                // was taken back, or the app restarted; else it goes once
                let n = r.wire.count("answer")
                r.timers.advance(CardStore.takeBack * 2)
                let late = r.wire.count("answer") - n
                // (a pick still held after the cell goes once its take-back runs out: from the table, not the app)
                check(late == (want.phase == "pending" ? 1 : 0), "\(start.rawValue) × \(e.rawValue): then \(late) answer(s) when the take-back runs out")
                check(r.wire.answers("a1").count <= 1, "\(start.rawValue) × \(e.rawValue): at most one answer for the card")
                cells += 1
            }
        }
        check(cells == Start.allCases.count * Event.allCases.count, "every cell: \(cells)")
        // the expired card with a late answer: the card says so
        let r = setUp(.expired)
        r.lateRefused("a1")
        check(ShellText.cardState(r.phase("a1")!, lang: .zhHans) == "已过期：之后的回答没有用上", "a late answer, said: \(ShellText.cardState(r.phase("a1")!, lang: .zhHans))")
        // 「现在回答」 once: a second click writes nothing; a new card takes its place
        r.answerNow("a1"); r.answerNow("a1")
        check(r.wire.count("reask") == 1 && r.wire.lines.last?.line as NSDictionary? == ["type": "reask", "run_id": rid] as NSDictionary, "reask once, for its rid")
        r.ask("a2")
        check(r.phase("a2") == .open && r.phase("a1") == .expired(late: true, answerNow: .gone) && r.m.pinned(r.state)?.card.askId == "a2",
              "the new card is pinned; the expired one is a line")
        // a pick within the take-back, picked again: only the last pick goes, 3 s after it
        let p = setUp(.open)
        p.click("a1", .approve)
        p.timers.advance(2)
        p.click("a1", .skipStep)
        p.timers.advance(2)
        check(p.wire.count("answer") == 0, "picked again: the take-back starts over")
        p.timers.advance(1)
        check(p.wire.answers("a1").count == 1 && p.wire.answers("a1").first?["option"] as? Int == 1, "the last pick goes: \(p.wire.answers("a1"))")
        // words are held as a pick is, and taken back the same way
        let w = Rig()
        w.ask("a1", "missing")
        w.words("a1", "小李")
        check(w.phase("a1")?.pending == .text(runId: rid, askId: "a1", text: "小李"), "words held for the take-back")
        w.takeBack("a1")
        w.timers.advance(CardStore.takeBack)
        check(w.wire.count("answer") == 0 && w.phase("a1") == .open, "taken back: never sent")
        // the race: the take-back runs out after the client took a void, before the window drew it (its deliver still
        // queued): the newest state decides, nothing is written
        var queued: [() -> Void] = []
        let rw = Wire(), rt = ShellTests.Timers()
        let rm = ShellModel(client: SessionClient(transport: rw), defaults: ShellTests.scratchDefaults(), config: { "openai:local|fake" },
                            lang: { .zhHans }, takeBackAfter: rt.after, now: { rt.now }, work: { $0() }, deliver: { queued.append($0) })
        rm.selected = sid
        let rr = Rig(); rr.ask("a1")
        for l in rr.fed { rm.client.feed(l) }
        while !queued.isEmpty { queued.removeFirst()() }
        let rc = CardModel(card: rm.states[sid]!.openCard!.card.card, runId: rid, askId: "a1")
        rm.cardBody(rc, contentHeight: 1, visibleHeight: 1, offset: 0)
        rm.click(rc.buttons[0])
        rr.void("a1", "steer")
        rm.client.feed(rr.fed.last!)                    // the client has it; the window not yet
        check(rm.states[sid]?.openCard != nil, "(the window still shows the card open)")
        rt.advance(CardStore.takeBack)
        check(rw.count("answer") == 0, "a void the client has, the window not yet: the held answer is not sent")
        while !queued.isEmpty { queued.removeFirst()() }
        // cloud models turned off during the take-back: dropped, not sent
        var cloud = true
        let wire = Wire()
        let t = ShellTests.Timers()
        let c = ShellModel(client: SessionClient(transport: wire), defaults: ShellTests.scratchDefaults(), config: { "openai:local|fake" },
                           lang: { .zhHans }, cloudOn: { cloud }, takeBackAfter: t.after, now: { t.now }, work: { $0() }, deliver: { $0() })
        c.selected = sid
        let cr = Rig(); cr.ask("a1")
        for l in cr.fed { c.client.feed(l) }
        let cm = CardModel(card: c.states[sid]!.openCard!.card.card, runId: rid, askId: "a1")
        c.cardBody(cm, contentHeight: 1, visibleHeight: 1, offset: 0)
        c.click(cm.buttons[0])
        cloud = false
        t.advance(CardStore.takeBack)
        check(wire.count("answer") == 0, "cloud off within the take-back: the held approve is not sent")
    }

    // MARK: - every order

    enum Step: Character, CaseIterable { case pick = "P", tick = "T", resumed = "R", expiry = "V", taskDone = "D", restart = "X" }

    static func allOrdersTests() {
        func permutations(_ a: [Step]) -> [[Step]] {
            if a.count <= 1 { return [a] }
            return a.indices.flatMap { i -> [[Step]] in
                var rest = a; let x = rest.remove(at: i)
                return permutations(rest).map { [x] + $0 }
            }
        }
        var orders = 0, wrong = 0
        for order in permutations(Step.allCases) {
            let r = Rig()
            r.ask("a1")
            for s in order {
                switch s {
                case .pick: r.click("a1", .approve)
                case .tick: r.timers.advance(CardStore.takeBack)
                case .resumed: r.resumed("a1")
                case .expiry: r.void("a1", "timeout")
                case .taskDone: r.done()
                case .restart: r.restart()
                }
            }
            // the spec: the run's first word on the card ends it — resumed: answered; the expiry: expired, and with the
            // task ended by the end of the order, 「现在回答」 is gone (whatever the task's end implied before gives way).
            // The answer: a pick taken (made before anything ended the card) is written once, when its 3 s run out — in
            // the same life (no restart between) and before anything ended the card; else never.
            let at = { (x: Step) in order.firstIndex(of: x)! }
            let endAt = min(at(.resumed), at(.expiry), at(.taskDone))
            let sentOnce = at(.pick) < at(.tick) && at(.tick) < endAt && !(at(.pick) < at(.restart) && at(.restart) < at(.tick))
            let wantPhase = at(.resumed) < at(.expiry) ? "answered" : "expired:gone"
            let got = name(r.phase("a1"))
            let answers = r.wire.answers("a1").count
            let ok = got == wantPhase && answers == (sentOnce ? 1 : 0)
            if !ok { wrong += 1; check(false, "order \(String(order.map(\.rawValue))): \(got), \(answers) answer(s); want \(wantPhase), \(sentOnce ? 1 : 0)") }
            orders += 1
        }
        check(orders == 720 && wrong == 0, "all \(orders) orders: \(wrong) wrong")
    }

    // MARK: - random runs against a simulated harness

    /// The harness as the simulation has it: its cards and how each ended, by its own reading of its stdin.
    final class Harness {
        enum Ending: Equatable { case answered(String), void(String) }
        var cards: [(id: String, kind: String)] = []
        var endings: [String: Ending] = [:]
        var open: String? = nil
        var done = false
        var gone = false
        var stdin: [[String: Any]] = []
        var n = 0
        /// It waits on its expired card (after a timeout void, until a steer, a reask or its end).
        var waitingReask = false
        /// How a reask goes: 0 a new card, 1 the screen moved — it looks again and goes on without a card (H1's stale), 2
        /// refused, and it goes on.
        var reaskWay: () -> Int = { 0 }
        var steps = 0
        let rig: Rig
        init(_ rig: Rig) { self.rig = rig; rig.wire.onLine = { [weak self] l in self?.stdin.append(l) } }

        /// Lines the harness wrote, not yet delivered to the app (any order: the app holds what comes past a gap).
        var outbox: [[String: Any]] = []
        func emit(_ kind: String, _ f: [String: Any]) { outbox.append(rig.line(kind, f)) }

        func ask(_ kind: String) {
            guard !done, !gone, open == nil else { return }
            n += 1
            let id = "a\(n)"
            cards.append((id, kind)); open = id; waitingReask = false
            emit("ask", ["ask_id": id, "card": cardJSON(kind)])
        }
        func void(_ why: String) {
            guard !done, !gone, let id = open else { return }
            endings[id] = .void(why); open = nil
            if why == "steer" { emit("resumed", ["ask_id": id, "voided": "steer"]) }
            emit("ask_void", ["ask_id": id, "why": why])
            if why == CardState.timeout { waitingReask = true }
        }
        func finish(_ status: String) {
            guard !done, !gone else { return }
            if let id = open { endings[id] = .void("ended"); open = nil; emit("ask_void", ["ask_id": id, "why": "ended"]) }
            done = true
            emit("task_done", ["status": status, "reason": "", "summary": ""])
        }
        /// Its process ends (the helper's exit line): an open card ends with it, unanswered.
        func exit() {
            guard !gone else { return }
            if let id = open { endings[id] = .void("gone"); open = nil }
            gone = true
            outbox.append(["kind": "helper.session_exit", "session_id": sid, "code": 0, "last_seq": 2])
        }
        /// It acts: a step.
        func step() { steps += 1; emit("step", ["step_id": "s\(steps)", "text": "click", "purpose": "go on"]) }
        /// Reads the next line on its stdin, as the executor does.
        func read() {
            guard !stdin.isEmpty else { return }
            let l = stdin.removeFirst()
            guard !gone else { return }
            switch l["type"] as? String {
            case "answer":
                let id = l["ask_id"] as? String ?? ""
                if !done, open == id {
                    endings[id] = .answered((l["option"] as? Int).map { "\($0)" } ?? "t:" + (l["text"] as? String ?? ""))
                    open = nil
                    emit("resumed", ["ask_id": id])
                } else if !done {
                    emit("refused", ["what": "answer for \(id)", "why": "not the open card", "by": "executor"])
                }
            case "stop":
                if !done { void("stop"); emit("refused", ["what": "the task", "why": "stopped", "by": "user"]); finish("stopped") }
            case "reask":
                guard !done else { break }
                if waitingReask && open == nil {
                    switch reaskWay() {
                    case 0: ask("action")
                    case 1: waitingReask = false; step()
                    default: waitingReask = false; emit("refused", ["what": "reask", "why": "the screen changed", "by": "executor"]); step()
                    }
                } else {
                    emit("refused", ["what": "reask", "why": "no card has expired", "by": "executor"])
                }
            case "steer":
                // (the session refuses a steer while a card waits: card_open, nothing stored)
                guard !done, open == nil else { break }
                waitingReask = false
                emit("steered", ["text": l["text"] as? String ?? ""])
                step()
            default: break
            }
        }
    }

    struct RNG { var x: UInt64; mutating func next(_ n: Int) -> Int { x = x &* 6364136223846793005 &+ 1442695040888963407; return Int((x >> 33) % UInt64(n)) } }

    static func propertyTests() {
        var failures: [String] = []
        let seeds = 400
        for seed in 1...seeds {
            if let f = oneRun(seed: UInt64(seed)) { failures.append("seed \(seed): \(f)") }
        }
        check(failures.isEmpty, "\(failures.count) of \(seeds) random runs break the invariant: \(failures.prefix(5))")
    }

    /// One random run; nil when every check held, else what broke first.
    static func oneRun(seed: UInt64) -> String? {
        var g = RNG(x: seed &* 2654435761 &+ 7)
        let r = Rig()
        let h = Harness(r)
        var gw = RNG(x: seed &* 31 &+ 3)
        h.reaskWay = { gw.next(3) }
        // (action cards half the time: only they expire)
        let kinds = ["action", "plan", "action", "ambiguity", "action", "missing"]
        // the user's own record, per app life: each card's picks (when, what) and take-backs — what may be written
        struct Intent { var life: Int; var at: Double; var answer: [String: Any]?; var immediate: Bool }
        var intents: [String: [Intent]] = [:]
        var problem: String? = nil
        // a write is checked against the user's record as it is written
        r.wire.onLine = { [weak h] l in
            h?.stdin.append(l)
            guard problem == nil, l["type"] as? String == "answer", let id = l["ask_id"] as? String else { return }
            let life = r.wire.life
            if r.wire.answers(id, life: life).count > 1 { problem = "a second answer for \(id) in one life"; return }
            guard let last = intents[id]?.last(where: { $0.life == life }), let a = last.answer else {
                problem = "an answer for \(id) the user did not pick (or took back) in this life"; return
            }
            var want = a; want["type"] = "answer"; want["run_id"] = rid; want["ask_id"] = id
            if !(want as NSDictionary).isEqual(to: l) { problem = "\(id): wrote \(l), the last pick was \(a)"; return }
            if !last.immediate && r.timers.now < last.at + CardStore.takeBack - 1e-9 { problem = "\(id): sent before its take-back ran out"; return }
            // the app never answers a card whose ending it already has (the run's lines applied so far)
            if let c = r.cardState(id), c.explicit != nil { problem = "\(id): answered after the app had its ending \(c.outcome)" }
        }
        var lastEnding: [String: CardPhase.Ending] = [:]
        h.ask(kinds[g.next(kinds.count)])
        for _ in 0..<(40 + g.next(40)) {
            if problem != nil { break }
            switch g.next(16) {
            case 0, 1, 2:                                           // a line reaches the app (any of those written)
                if !h.outbox.isEmpty { r.feed(h.outbox.remove(at: g.next(min(2, h.outbox.count)))) }
            case 3, 4:                                              // the harness reads its stdin
                h.read()
            case 5:                                                 // the harness: a new card, a changed request, an expiry
                if h.open == nil { if !h.waitingReask || g.next(4) == 0 { h.ask(kinds[g.next(kinds.count)]) } }
                else if h.cards.last?.kind == "action", g.next(2) == 0 { h.void(CardState.timeout) }      // (action cards only expire)
                else if g.next(3) == 0 { h.void("steer") }
            case 6, 7:                                              // the user picks an option on the pinned card
                if let p = r.m.pinned(r.state), p.phase.takesPick, let c = r.model(p.card.askId) {
                    let bs = c.buttons.filter { $0.role != .cancel }
                    let b = bs[g.next(bs.count)]
                    r.m.cardBody(c, contentHeight: 1, visibleHeight: 1, offset: 0)
                    intents[c.askId!, default: []].append(Intent(life: r.wire.life, at: r.timers.now, answer: ["option": b.index], immediate: false))
                    r.m.click(b)
                }
            case 8:                                                 // the user's own words, or the way out
                if let p = r.m.pinned(r.state), p.phase.takesPick, let c = r.model(p.card.askId) {
                    if c.allowsFreeText && g.next(2) == 0 {
                        let w = "第\(g.next(9))个"
                        intents[c.askId!, default: []].append(Intent(life: r.wire.life, at: r.timers.now, answer: ["text": w], immediate: false))
                        r.words(c.askId!, w)
                    } else if let out = c.buttons.first(where: { $0.role == .cancel }) {
                        intents[c.askId!, default: []].append(Intent(life: r.wire.life, at: r.timers.now, answer: ["option": out.index], immediate: true))
                        r.m.click(out)
                    }
                }
            case 9:                                                 // the take-back
                if let p = r.m.pinned(r.state), p.phase.pending != nil {
                    intents[p.card.askId, default: []].append(Intent(life: r.wire.life, at: r.timers.now, answer: nil, immediate: false))
                    r.takeBack(p.card.askId)
                }
            case 10, 11:                                            // time passes
                r.timers.advance(Double(1 + g.next(3)))
            case 12:                                                // 「现在回答」
                if let p = r.m.pinned(r.state), case .expired(_, .offered) = p.phase { r.answerNow(p.card.askId) }
            case 13:                                                // Stop, or a changed request (⌘Return) while no card waits
                if g.next(12) == 0 { r.m.stop() }
                else if r.state.composerEnabled, r.state.runningTask != nil, g.next(r.state.task(rid)?.expiredCard != nil ? 2 : 6) == 0 {
                    _ = r.m.client.send(.steer("改一下", runId: rid), to: sid)
                }
            case 14:                                                // the app restarts (its held picks are gone)
                if g.next(3) == 0 { r.restart() }
            default:                                                // the task ends, or (rarely) its process
                if g.next(5) == 0 { if g.next(3) == 0 { h.exit() } else { h.finish("succeeded") } }
            }
            // a card's ending the run said never changes; the views agree
            if let s = r.m.states[sid], let t = s.task(rid) {
                for c in t.cards {
                    let p = r.m.phase(rid, c, in: s)
                    if c.explicit != nil {
                        guard let e = p.ending else { problem = "\(c.askId): the run ended it, the app shows \(p)"; break }
                        if let was = lastEnding[c.askId], was != e { problem = "\(c.askId): its ending changed \(was) → \(e)" }
                        lastEnding[c.askId] = e
                    }
                }
                let pin = r.m.pinned(s)
                let waiting = pin.map { $0.phase.ending == nil } ?? false
                // (the dot as the list says it: its words)
                let dot = ShellText.status(s.status, lang: .en)
                if dot.hasPrefix("Waiting for you") != waiting { problem = "the dot (\(dot)) and the pinned card (\(String(describing: pin?.phase))) disagree" }
                if waiting, s.composerEnabled { problem = "a card waits, the composer takes typing" }
                if dot.hasPrefix("Expired") != (pin?.phase.isExpiredOffer ?? false) { problem = "the dot (\(dot)) and the expired card (\(String(describing: pin?.phase))) disagree" }
                // caught up with the harness (all it wrote delivered): the app waits on an expired card exactly while the
                // harness does, and a task the harness runs with nothing for the user lets the window stay back
                if h.outbox.isEmpty, !h.gone, !h.done, problem == nil {
                    let harnessWaits = h.open == nil && h.waitingReask
                    if harnessWaits != (pin?.phase.isExpiredOffer ?? false) {
                        problem = "the harness \(harnessWaits ? "waits" : "does not wait") on its expired card; the app pins \(String(describing: pin?.phase))"
                    } else if (h.open == nil && !harnessWaits) != r.m.taskRunningWithoutCard {
                        problem = "the harness runs \(h.open == nil && !harnessWaits ? "with nothing for the user" : "waiting for the user"); taskRunningWithoutCard is \(r.m.taskRunningWithoutCard)"
                    }
                }
            }
        }
        if let problem { return problem }
        // quiesce: the harness ends the task, everything is read and delivered, every timer runs
        for _ in 0..<50 {
            r.timers.advance(CardStore.takeBack)
            while !h.stdin.isEmpty { h.read() }
            if h.outbox.isEmpty && h.stdin.isEmpty { h.finish("succeeded") }
            while !h.outbox.isEmpty { r.feed(h.outbox.removeFirst()) }
            if let problem { return problem }
            if h.outbox.isEmpty && h.stdin.isEmpty && (h.done || h.gone) && r.timers.pending == 0 { break }
        }
        // every card: the app's ending is the harness's own
        guard let s = r.m.states[sid], let t = s.task(rid) else { return "no task" }
        for (id, _) in h.cards {
            guard let c = t.cards.first(where: { $0.askId == id }) else { return "\(id): the app has no such card" }
            let p = r.m.phase(rid, c, in: s)
            switch h.endings[id] {
            case .answered(let what)?:
                guard p == .answered else { return "\(id): the harness took an answer (\(what)), the app shows \(p)" }
                let wrote = r.wire.answers(id).map { ($0["option"] as? Int).map { "\($0)" } ?? "t:" + ($0["text"] as? String ?? "") }
                if !wrote.contains(what) { return "\(id): the harness took \(what), the app wrote \(wrote)" }
            case .void(let why)?:
                if why == CardState.timeout { if case .expired = p {} else { return "\(id): expired, the app shows \(p)" } }
                else if case .voided = p {} else { return "\(id): voided (\(why)), the app shows \(p)" }
            case nil:
                return "\(id): the harness left it open at the end"
            }
            // at most one answer per card in each life of the app
            for life in 1...r.wire.life where r.wire.answers(id, life: life).count > 1 { return "\(id): \(r.wire.answers(id, life: life).count) answers in life \(life)" }
        }
        if !r.m.cards.picks.isEmpty || !r.m.cards.sent.isEmpty { return "held after the end: \(r.m.cards.picks.keys) \(r.m.cards.sent.keys)" }
        return nil
    }

    // MARK: - the views read one state

    /// The window's views read a card through its phase (ShellModel.phase / pinned) only: never the reducer's outcome
    /// or the open card directly, so the chat, the pinned card, VoiceOver and the dot cannot disagree.
    static func viewsTests() {
        // (the window's view files, as the focus check finds them: from build.sh)
        let text = ShellTests.windowViewFiles().map(\.code).joined(separator: "\n")
        guard !text.isEmpty else { check(false, "the window's view files readable"); return }
        let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for banned in [".outcome", ".openCard", ".explicit", "cards.picks", "cards.sent"] {
            check(!code.contains(banned), "the views do not read \(banned)")
        }
        check(code.contains("shell.pinned(") && code.contains("shell.phase(") && code.contains("voiceOverLabel(m, phase:"), "they read pinned / phase")
        // every phase has its words, in both languages
        let phases: [CardPhase] = [.open, .pending(.option(runId: "r", askId: "a", option: 0), until: 0), .sent(.option(runId: "r", askId: "a", option: 0)),
                                   .answered, .voided("steer"), .voided("stop"), .voided("replaced"), .voided("session_exit"), .voided("task_done"),
                                   .expired(late: false, answerNow: .offered), .expired(late: true, answerNow: .gone)]
        let zh = Set(phases.map { ShellText.cardState($0, lang: .zhHans) })
        check(zh.count == phases.count, "each phase says something of its own: \(zh.count) of \(phases.count)")
        for p in phases { check(ShellText.cardState(p, lang: .zhHans) != ShellText.cardState(p, lang: .en), "translated: \(ShellText.cardState(p, lang: .en))") }
    }
}
