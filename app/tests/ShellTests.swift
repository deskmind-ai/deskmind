// The 0.5 main window's glue (M1 S3, Shared/Shell.swift), without a screen: the ui05.shell flag, the status dot's
// priority, the composer's Enter / ⌘Enter / disabled, the queue bubbles' controls, the card answers' payloads, the
// session list (titles, rename, delete), the new conversation's open-then-send, and the settings reaching the client.
// Run from DecisionTests.main (build.sh).

import Foundation

enum ShellTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "shell: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("shell.defaultsHygieneTests"); defaultsHygieneTests()
        DecisionTests.group("shell.statusPriorityTests"); statusPriorityTests()
        DecisionTests.group("shell.composerTests"); composerTests()
        DecisionTests.group("shell.rowsTests"); rowsTests()
        DecisionTests.group("shell.newConversationTests"); newConversationTests()
        DecisionTests.group("shell.queueTests"); queueTests()
        DecisionTests.group("shell.cardAnswerTests"); cardAnswerTests()
        DecisionTests.group("shell.deleteRenameTests"); deleteRenameTests()
        DecisionTests.group("shell.settingsTests"); settingsTests()
        DecisionTests.group("shell.settingsOrderTests"); settingsOrderTests()
        DecisionTests.group("shell.cloudOffTests"); cloudOffTests()
        DecisionTests.group("shell.cardBodyTests"); cardBodyTests()
        DecisionTests.group("shell.focusTests"); focusTests()
        DecisionTests.group("shell.activationTests"); activationTests()
        DecisionTests.group("shell.idleReclaimTests"); idleReclaimTests()
        DecisionTests.group("shell.historyTests"); historyTests()
        DecisionTests.group("shell.cloudOffNoModelTests"); cloudOffNoModelTests()
        DecisionTests.group("shell.modelChoiceTests"); modelChoiceTests()
        DecisionTests.group("shell.cardWordsTests"); cardWordsTests()
        DecisionTests.group("shell.settingsReopenTests"); settingsReopenTests()
        DecisionTests.group("shell.endRefusedTests"); endRefusedTests()
        DecisionTests.group("shell.privacySwitchTests"); privacySwitchTests()
        DecisionTests.group("shell.cardHintTests"); cardHintTests()
        DecisionTests.group("shell.endMarkTests"); endMarkTests()
        DecisionTests.group("shell.backfillTests"); backfillTests()
        DecisionTests.group("shell.languageTests"); languageTests()
        DecisionTests.group("shell.modelOffConfigTests"); modelOffConfigTests()
        DecisionTests.group("shell.modelOffOpenTests"); modelOffOpenTests()
        DecisionTests.group("shell.configBusyTests"); configBusyTests()
        DecisionTests.group("shell.noModelTests"); noModelTests()
        DecisionTests.group("shell.modelNameTests"); modelNameTests()
        DecisionTests.group("shell.backfillOffStreamTests"); backfillOffStreamTests()
        DecisionTests.group("shell.historyWatchDownTests"); historyWatchDownTests()
        DecisionTests.group("shell.historyOpenedCrashTests"); historyOpenedCrashTests()
        DecisionTests.group("shell.modelOffMidOpenTests"); modelOffMidOpenTests()
        DecisionTests.group("shell.exitAfterBackfillTests"); exitAfterBackfillTests()
        DecisionTests.group("shell.settingsBannerTests"); settingsBannerTests()
        DecisionTests.group("shell.cloudOffRowNowTests"); cloudOffRowNowTests()
        DecisionTests.group("shell.keyChangeOffTests"); keyChangeOffTests()
        DecisionTests.group("shell.configRetryLatestTests"); configRetryLatestTests()
        DecisionTests.group("shell.restartCloudOffTests"); restartCloudOffTests()
        DecisionTests.group("shell.backfillReopenTests"); backfillReopenTests()
        DecisionTests.group("shell.lostNullTests"); lostNullTests()
        DecisionTests.group("shell.helperRefusalTests"); helperRefusalTests()
        DecisionTests.group("shell.modelsOffHookTests"); modelsOffHookTests()
        DecisionTests.group("shell.helperDisagreesTests"); helperDisagreesTests()
        DecisionTests.group("shell.modelsOffSyncTests"); modelsOffSyncTests()
        DecisionTests.group("shell.pendingConfigTests"); pendingConfigTests()
        DecisionTests.group("shell.openBannerTests"); openBannerTests()
        DecisionTests.group("shell.reopenNoModelTests"); reopenNoModelTests()
        DecisionTests.group("shell.oldWindowRunTests"); oldWindowRunTests()
        DecisionTests.group("shell.oneOwnerTests"); oneOwnerTests()
        DecisionTests.group("shell.nulledRepairTests"); nulledRepairTests()
        DecisionTests.group("shell.runAnswerGateTests"); runAnswerGateTests()
        DecisionTests.group("shell.pingPongTests"); pingPongTests()
        DecisionTests.group("shell.waitingForHelperTests"); waitingForHelperTests()
        DecisionTests.group("shell.savedAnywhereTests"); savedAnywhereTests()
        DecisionTests.group("shell.keyAckTests"); keyAckTests()
        DecisionTests.group("shell.reconcileNoWaitTests"); reconcileNoWaitTests()
        DecisionTests.group("shell.messageNeverLostTests"); messageNeverLostTests()
        DecisionTests.group("shell.settingsConvergeTests"); settingsConvergeTests()
        DecisionTests.group("shell.evidenceTests"); evidenceTests()
        DecisionTests.group("shell.dirtyFlagTests"); dirtyFlagTests()
        DecisionTests.group("shell.switchGateTests"); switchGateTests()
        DecisionTests.group("shell.normalizeTests"); normalizeTests()
        DecisionTests.group("shell.oneReadTests"); oneReadTests()
        DecisionTests.group("shell.textTests"); textTests()
    }

    typealias Mock = SessionTests.MockTransport

    /// Defaults of their own, in memory: never the app's, and never on disk (a suite per call left a plist in
    /// ~/Library/Preferences each time: 75,797 of them on one Mac by 10-25).
    static func scratchDefaults() -> UserDefaults { MemoryDefaults() }

    /// UserDefaults that keep everything in memory: reads and writes never reach cfprefsd or the disk. Every typed
    /// getter (bool, string, dictionary …) goes through object(forKey:).
    final class MemoryDefaults: UserDefaults {
        private var store: [String: Any] = [:]
        private let lock = NSLock()
        static let domain = "ai.deskmind.tests.memory"     // (the superclass's name only: nothing is written to it)
        init() { super.init(suiteName: Self.domain)! }
        override func object(forKey k: String) -> Any? { lock.lock(); defer { lock.unlock() }; return store[k] }
        override func set(_ v: Any?, forKey k: String) { lock.lock(); store[k] = v; lock.unlock() }
        override func removeObject(forKey k: String) { lock.lock(); store[k] = nil; lock.unlock() }
        override func set(_ v: Bool, forKey k: String) { set(v as Any?, forKey: k) }
        override func set(_ v: Int, forKey k: String) { set(v as Any?, forKey: k) }
        override func set(_ v: Double, forKey k: String) { set(v as Any?, forKey: k) }
        override func set(_ v: Float, forKey k: String) { set(v as Any?, forKey: k) }
        override func set(_ v: URL?, forKey k: String) { set(v as Any?, forKey: k) }
        override func dictionaryRepresentation() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return store }
        override func removePersistentDomain(forName: String) { lock.lock(); store = [:]; lock.unlock() }
        override func synchronize() -> Bool { true }
    }

    /// No test writes to the app's own defaults, and the unit tests write none to disk.
    static func defaultsHygieneTests() {
        check(Bundle.main.bundleIdentifier != "ai.deskmind.app", "the test process is not the app (its standard defaults are not the app's)")
        let d = scratchDefaults()
        d.set("x", forKey: "k"); d.set(true, forKey: "b"); d.set(["a": 1], forKey: "dict")
        check(d.string(forKey: "k") == "x" && d.bool(forKey: "b") && (d.dictionary(forKey: "dict")?["a"] as? Int) == 1, "scratch defaults work")
        d.removeObject(forKey: "k")
        check(d.object(forKey: "k") == nil && d.dictionaryRepresentation().count == 2, "and remove")
        _ = d.synchronize()
        let prefs = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Preferences/\(MemoryDefaults.domain).plist")
        usleep(200_000)
        check(!FileManager.default.fileExists(atPath: prefs), "nothing on disk: \(prefs)")
        // no test source opens the app's domain, or a disk suite but the e2e's own
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tests")
        let files = (FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".swift") || $0.hasSuffix(".py") || $0.hasSuffix(".sh") }
        for f in files {
            let t = (try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) ?? ""
            let code = t.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
            // (the needles are built, so this file does not match itself)
            let app = "ai.deskmind" + ".app", suite = "UserDefaults(" + "suiteName:"
            check(!code.contains("suiteName: \"\(app)\"") && !code.contains("defaults write \(app)") && !code.contains("defaults delete \(app)"),
                  "tests/\(f) never writes the app's defaults")
            if f.hasSuffix(".swift") && f != "e2e/ShellE2E.swift" { check(!code.contains(suite), "tests/\(f) opens no disk suite (scratchDefaults: in memory)") }
        }
    }

    /// A model whose work and deliveries run inline, on a mock helper; its take-back runs on `timers` (a test's clock).
    static func model(_ mock: Mock, defaults: UserDefaults = scratchDefaults(), config: String? = "openai:local|fake",
                      lang: ResolvedLang = .zhHans, timers: Timers = Timers()) -> ShellModel {
        let client = SessionClient(transport: mock)
        client.makeClientId = { "c_1" }
        return ShellModel(client: client, defaults: defaults, config: { config }, lang: { lang },
                          takeBackAfter: timers.after, now: { timers.now }, work: { $0() }, deliver: { $0() })
    }

    /// A test's clock and timers: nothing fires until `advance` moves the clock past it.
    final class Timers {
        var now: Double = 1_000_000
        private var due: [(at: Double, n: Int, f: () -> Void)] = []
        private var n = 0
        func after(_ d: TimeInterval, _ f: @escaping () -> Void) { n += 1; due.append((now + d, n, f)) }
        /// The clock moves on by `d` seconds; what falls due runs, in order.
        func advance(_ d: Double) {
            let until = now + d
            while let i = due.indices.filter({ due[$0].at <= until }).min(by: { (due[$0].at, due[$0].n) < (due[$1].at, due[$1].n) }) {
                let t = due.remove(at: i)
                now = max(now, t.at)
                t.f()
            }
            now = until
        }
        var pending: Int { due.count }
    }

    static func feed(_ m: ShellModel, _ name: String, upTo match: ((ProtocolLine) -> Bool)? = nil) {
        for l in SessionTests.lines(name) {
            m.client.feed(l)
            if let match, match(l) { break }
        }
    }

    /// The user's controls sent (the settings' set_config apart: SessionClient converges those on its own).
    static func isControl(_ r: [String: Any]) -> Bool {
        r["op"] as? String == SessionClient.Op.send && (r["line"] as? [String: Any])?["type"] as? String != "set_config"
    }
    /// The last control line sent (its req_id left out: a fresh id per answer, harness#71).
    static func sent(_ mock: Mock) -> [String: Any]? {
        guard var l = mock.requests.last(where: isControl)?["line"] as? [String: Any] else { return nil }
        l["req_id"] = nil
        return l
    }
    static func sends(_ mock: Mock) -> Int { mock.requests.filter(isControl).count }

    // MARK: the flag

    // MARK: the status dot

    static func statusPriorityTests() {
        let sid = "\"session_id\":\"s\""
        func se(_ seq: Int, _ body: String) -> ProtocolLine { ProtocolLine.parse("{\"seq\":\(seq),\(sid),\(body)}")! }
        func ex(_ seq: Int, _ run: String, _ body: String) -> ProtocolLine { ProtocolLine.parse("{\"seq\":\(seq),\"run_id\":\"\(run)\",\(sid),\(body)}")! }
        var s = SessionState()
        for l in [se(1, #""kind":"session.message","msg_id":"m1","role":"user","text":"做 A""#),
                  se(2, #""kind":"session.task","msg_id":"m1","run_id":"r1","raw":"做 A","by":"slash""#),
                  ex(1, "r1", #""kind":"start","raw":"做 A""#),
                  ex(2, "r1", #""kind":"step","text":"{}","step_id":"a1""#),
                  ex(3, "r1", #""kind":"task_done","status":"failed","reason":"x","summary":"没做完""#),
                  se(3, #""kind":"session.task_end","run_id":"r1","status":"failed","summary":"没做完","undo":"none""#)] {
            SessionReducer.apply(&s, l)
        }
        check(s.status == .error("failed"), "an earlier task's failure, not seen: the error dot (\(s.status))")
        check(s.status.shape == .bang, "drawn as !")
        // a new task starts and acts: the running task outranks the unseen error (owner rule)
        for l in [se(4, #""kind":"session.task","msg_id":"m2","run_id":"r2","raw":"做 B","by":"slash""#),
                  ex(1, "r2", #""kind":"start","raw":"做 B""#)] { SessionReducer.apply(&s, l) }
        check(s.status == .thinking, "the new task preparing: thinking, not the old error (\(s.status))")
        SessionReducer.apply(&s, ex(2, "r2", #""kind":"step","text":"{}","step_id":"b1""#))
        check(s.status == .acting(step: 1, of: nil) && s.status.shape == .solidDot, "acting outranks the unseen error (\(s.status))")
        // a card waits: waiting for you outranks acting
        SessionReducer.apply(&s, ex(3, "r2", #""kind":"ask","ask_id":"k1","card":{"kind":"action","text":"发送吗？","options":[{"kind":"approve","text":"发送"},{"kind":"cancel","text":"先别做了"}],"blocking":true}"#))
        check(s.status == .waitingForYou(cardKind: "action") && s.status.shape == .haloDot, "a card waits: waiting for you (\(s.status))")
        check(ShellText.status(s.status, lang: .zhHans) == "等你：动手前确认", "its words: \(ShellText.status(s.status, lang: .zhHans))")
        // the task ends well; the old error is still not seen, but the newest task's end is what counts
        for l in [ex(4, "r2", #""kind":"resumed","ask_id":"k1""#),
                  ex(5, "r2", #""kind":"task_done","status":"succeeded","reason":"","summary":"好了""#),
                  se(5, #""kind":"session.task_end","run_id":"r2","status":"succeeded","summary":"好了","undo":"none""#)] { SessionReducer.apply(&s, l) }
        if case .done(_, false) = s.status {} else { check(false, "the newest task succeeded: done (\(s.status))") }
        // opening the session (markSeen) clears an unseen error: the list's dot follows
        let mock = Mock()
        let m = model(mock)
        feed(m, "chat-error")
        check(m.rows.first?.status == .error("no_key"), "the list's dot: the model's error (\(String(describing: m.rows.first?.status)))")
        mock.replies[SessionClient.Op.open] = ["ok": true, "session_id": "ses_t", "already_open": true]
        m.select("ses_t")
        check(m.rows.first?.status != .error("no_key"), "opened: the error dot clears (\(String(describing: m.rows.first?.status)))")
    }

    // MARK: the composer

    static func composerTests() {
        let free = ComposerMode.of(nil)
        check(free.enabled && !free.taskRunning && !free.canStop, "a new conversation: typing, nothing to stop")
        check(free.control("你好", sendNow: false) == .say("你好"), "Enter: say")
        check(free.control("你好", sendNow: true) == .say("你好"), "⌘Enter with no task: the same as Enter")
        check(free.control("   \n", sendNow: false) == nil, "blank: nothing")
        check(free.control("/cua 打开备忘录", sendNow: false) == .cua("打开备忘录"), "/cua: a computer task, the words after it")
        check(free.control("/cua", sendNow: false) == nil && free.control("/cua   ", sendNow: false) == nil, "/cua alone: nothing")
        check(free.control("/cuax 是什么", sendNow: false) == .say("/cuax 是什么"), "not the command: words")
        check(free.control("请帮我 /cua 打开", sendNow: false) == .say("请帮我 /cua 打开"), "/cua inside a sentence: words (no keyword rules)")

        // a reply streams: Enter sends nothing (the session would say busy); Stop stops the reply
        let chat = SessionTests.lines("chat")
        var s = SessionState()
        for l in chat { SessionReducer.apply(&s, l); if s.streamingMessage != nil { break } }
        let replying = ComposerMode.of(s)
        check(replying.enabled && replying.replying && replying.canStop, "a reply streams: Stop available")
        check(replying.control("还有", sendNow: false) == nil, "a reply streams: Enter sends nothing (the text stays)")

        // a card waits (A9, owner 10-25): the composer takes words; Return steers (the card it voids ends by the run's word)
        let card = SessionTests.after("task-card", SessionTests.isKind("ask"))!
        let waiting = ComposerMode.of(card)
        check(waiting.enabled && waiting.taskRunning && waiting.canStop, "a card waits: composer on, Stop on")
        check(waiting.control("顺便", sendNow: false) == .steer("顺便") && waiting.control("顺便", sendNow: true) == .steer("顺便"), "a card waits: Return steers (⌘Return the same)")
        check(waiting.control("   ", sendNow: false) == nil, "an empty Return: nothing")

        // a task runs, no card: Return steers (no queue; ⌘Return is no other gesture)
        let running = SessionTests.after("task-card", SessionTests.isKind("resumed"))!
        let r = ComposerMode.of(running)
        check(r.enabled && r.taskRunning, "a task runs without a card: typing")
        check(r.control("改成蓝色", sendNow: false) == .steer("改成蓝色"), "Return while a task runs: steer")
        check(r.control("改成蓝色", sendNow: true) == .steer("改成蓝色"), "⌘Return while a task runs: steer")
        check(r.control("/cua 另一件事", sendNow: false) == .steer("/cua 另一件事"), "/cua while a task runs: the words to the task, as typed")

        // the model: submit while a card waits sends nothing and keeps the text
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true]]
        let m = model(mock)
        feed(m, "task-card", upTo: SessionTests.isKind("ask"))
        m.selected = "ses_t"
        m.draft = "顺便说一句"
        m.submit()
        check((sent(mock)?["type"] as? String) == "steer" && m.draft.isEmpty, "a card waits: Return steers (\(String(describing: sent(mock))))")
        // Stop is always sent, to the running task
        m.stop()
        check(sent(mock) as NSDictionary? == ["type": "stop", "run_id": "run_041c0f37"] as NSDictionary, "Stop while a card waits: the task's stop (\(String(describing: sent(mock))))")
    }

    // MARK: the list

    static func rowsTests() {
        let summaries = [SessionSummary(sessionId: "a", title: "把笔记的正文改成…", updatedAt: 10, lastMessage: nil),
                         SessionSummary(sessionId: "b", title: "", updatedAt: 20, lastMessage: nil),
                         SessionSummary(sessionId: "c", title: "旧的", updatedAt: 5, lastMessage: nil)]
        var st = SessionState(sessionId: "d")
        SessionReducer.apply(&st, ProtocolLine.parse(#"{"seq":1,"t":30,"session_id":"d","kind":"session.message","msg_id":"m","role":"user","text":"  一段   很长很长的话，超过四十个字的时候要截断，后面加省略号才对，这里再多写几个字凑够"}"#)!)
        let rows = ShellList.rows(summaries: summaries, states: ["d": st], names: ["c": "我的名字"], deleted: ["a"], untitled: "新对话")
        check(rows.map(\.id) == ["d", "b", "c"], "newest first, the deleted one gone: \(rows.map(\.id))")
        check(rows[0].title.count == 41 && rows[0].title.hasSuffix("…") && rows[0].title.hasPrefix("一段 很长"), "a title from the first message, as the harness makes it: \(rows[0].title)")
        check(rows[1].title == "新对话", "no message yet: untitled")
        check(rows[2].title == "我的名字", "a name the user gave wins")
    }

    // MARK: the new conversation: open, then send

    static func newConversationTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_new", "last_seq": 0], SessionClient.Op.send: ["ok": true],
                        SessionClient.Op.list: ["ok": true, "sessions": []]]
        let m = model(mock, config: "ds-flash", lang: .en)
        m.newConversation()
        m.draft = "hello"
        m.submit()
        let open = mock.requests.first { $0["op"] as? String == SessionClient.Op.open }
        check(open as NSDictionary? == ["op": "session.open", "config": "ds-flash", "lang": "en"] as NSDictionary, "opened with the model settings and the UI language: \(String(describing: open))")
        check(sent(mock) as NSDictionary? == ["type": "say", "text": "hello", "client_id": "c_1"] as NSDictionary, "then the words: \(String(describing: sent(mock)))")
        check(m.selected == "ses_new" && m.drafts[""] == "" && !m.opening, "the new session selected, the composer emptied")
        check(m.client.state("ses_new").outbox.first?.sending == true, "the words held as sending until the session takes them")
        check(m.rows.contains { $0.id == "ses_new" }, "it is in the list at once")
        // no helper: the words come back to the composer
        let none = Mock()
        let n = model(none)
        n.draft = "在吗"
        n.submit()
        check(n.drafts[""] == "在吗" && n.notice != nil && n.selected == nil, "no helper: the text back in the box, said why")
        // /cua in a new conversation: opened, then the cua line
        let mock2 = Mock()
        mock2.replies = mock.replies
        let c = model(mock2)
        c.draft = "/cua 新建 a.txt"
        c.submit()
        check(sent(mock2) as NSDictionary? == ["type": "cua", "text": "新建 a.txt", "client_id": "c_1"] as NSDictionary, "/cua: the same path, as a cua line")
    }

    // MARK: the queue

    static func queueTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true]]
        let m = model(mock)
        feed(m, "task-card", upTo: SessionTests.isKind("resumed"))
        m.client.feed(["kind": "session.queue", "session_id": "ses_t", "items": [["id": "q1", "text": "然后发给我", "client_id": "c_q"]]])
        m.selected = "ses_t"
        check(m.states["ses_t"]?.queue.map(\.id) == ["q1"], "the queue bubble from the session's queue")
        m.queueEdit("q1", text: "然后发给张三")
        check(sent(mock) as NSDictionary? == ["type": "queue_edit", "id": "q1", "text": "然后发给张三"] as NSDictionary, "edit: queue_edit with the new words")
        m.queueCancel("q1")
        check(sent(mock) as NSDictionary? == ["type": "queue_cancel", "id": "q1"] as NSDictionary, "cancel: queue_cancel")
        m.queueSendNow("q1")
        check(sent(mock) as NSDictionary? == ["type": "queue_send_now", "id": "q1"] as NSDictionary, "send now: queue_send_now")
        // while a card waits, send now is not sent (the session would refuse it card_open)
        let mock2 = Mock()
        mock2.replies = [SessionClient.Op.send: ["ok": true]]
        let w = model(mock2)
        feed(w, "task-card", upTo: SessionTests.isKind("ask"))
        w.client.feed(["kind": "session.queue", "session_id": "ses_t", "items": [["id": "q1", "text": "x"]]])
        w.selected = "ses_t"
        w.queueSendNow("q1")
        check(sends(mock2) == 0, "send now while a card waits: not sent")
        w.queueCancel("q1")
        check(sent(mock2) as NSDictionary? == ["type": "queue_cancel", "id": "q1"] as NSDictionary, "cancel while a card waits: sent (it is not typing)")
        // Return while a task runs: a steer (A9), the composer emptied
        m.draft = "再补一句"
        m.submit()
        check(sent(mock) as NSDictionary? == ["type": "steer", "text": "再补一句", "run_id": "run_041c0f37", "client_id": "c_1"] as NSDictionary && m.draft.isEmpty,
              "Return: steer, to the running task: \(String(describing: sent(mock)))")
        m.draft = "现在就改"
        m.submit(sendNow: true)
        check(sent(mock) as NSDictionary? == ["type": "steer", "text": "现在就改", "run_id": "run_041c0f37", "client_id": "c_1"] as NSDictionary, "⌘Enter: steer, to the running task: \(String(describing: sent(mock)))")
    }

    // MARK: card answers

    static func cardAnswerTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true]]
        let m = model(mock)
        feed(m, "task-card", upTo: SessionTests.isKind("ask"))
        m.selected = "ses_t"
        let s = m.states["ses_t"]!
        let (run, open) = s.openCard!
        let card = CardModel(card: open.card, runId: run, askId: open.askId)
        check(m.answerable(card, in: s), "the open card takes a click")
        let cancel = card.buttons.first { $0.role == .cancel }!
        m.click(cancel)
        check(sent(mock) as NSDictionary? == ["type": "answer", "run_id": run, "ask_id": open.askId, "option": cancel.index] as NSDictionary,
              "a click: the option's index and the card's ask_id: \(String(describing: sent(mock)))")
        let n = sends(mock)
        m.click(card.buttons.first { $0.role == .approve }!)
        check(sends(mock) == n && !m.answerable(card, in: m.states["ses_t"]!), "answered from here: its buttons off, a second click sends nothing")
        // a stale card's button (another ask_id, the same words) answers nothing
        var stale = cancel
        stale.askId = "ask_old"
        m.click(stale)
        check(sends(mock) == n, "a stale card's button: not sent")
        // the answer takes effect: the card is the session's again (answered), the buttons follow the card
        let rest = SessionTests.lines("task-card")
        let askAt = rest.firstIndex { $0.event.kind == "ask" }!, resumedAt = rest.firstIndex { $0.event.kind == "resumed" }!
        for l in rest[(askAt + 1)...resumedAt] { m.client.feed(l) }
        check(m.cards.sent.isEmpty && m.cards.picks.isEmpty, "resumed: nothing on its way any more")
        // a card that takes words: its own field, answered with text
        let mock2 = Mock()
        mock2.replies = [SessionClient.Op.send: ["ok": true]]
        let qt = Timers()
        let q = model(mock2, timers: qt)
        feed(q, "task-question", upTo: SessionTests.isKind("ask"))
        q.selected = "ses_t"
        let (qrun, qopen) = q.states["ses_t"]!.openCard!
        let qcard = CardModel(card: qopen.card, runId: qrun, askId: qopen.askId)
        check(qcard.allowsFreeText, "the missing card takes words")
        q.fit(qcard)   // (it has "you decide": words wait for its body)
        q.answer(qcard, text: "  明天下午三点  ")
        check(sends(mock2) == 0, "words are held for the take-back first")
        qt.advance(CardStore.takeBack)
        check(sent(mock2) as NSDictionary? == ["type": "answer", "run_id": qrun, "ask_id": qopen.askId, "text": "明天下午三点"] as NSDictionary, "its words: answer.text: \(String(describing: sent(mock2)))")
        // the result card: respond with the option's index
        let mock3 = Mock()
        mock3.replies = [SessionClient.Op.send: ["ok": true]]
        let u = model(mock3)
        feed(u, "task-undo", upTo: SessionTests.isKind("session.task_end"))
        u.selected = "ses_t"
        let t = u.states["ses_t"]!.tasks.last!
        let rc = CardModel(resultCard: t.resultCard!, runId: t.runId)
        check(u.answerable(rc, in: u.states["ses_t"]!), "the result card can be answered while its executor lingers")
        let undo = rc.buttons.first { $0.role == .undo }!
        u.click(undo)
        check(sent(mock3) as NSDictionary? == ["type": "respond", "run_id": t.runId, "option": undo.index] as NSDictionary, "undo: respond with its index: \(String(describing: sent(mock3)))")
        // once answered (result_response) or closed, the result card takes no click
        feed(u, "task-undo")
        check(!u.answerable(rc, in: u.states["ses_t"]!), "answered and closed: no click")
    }

    // MARK: delete, rename

    static func deleteRenameTests() {
        let d = scratchDefaults()
        let mock = Mock()
        mock.replies = [SessionClient.Op.list: ["ok": true, "sessions": [["session_id": "ses_t", "title": "你好", "updated_at": 1.0]]],
                        "session.delete": ["ok": true]]
        let m = model(mock, defaults: d)
        m.refreshList()
        check(m.rows.map(\.title) == ["你好"], "the list from the helper")
        m.rename("ses_t", to: "  问候  ")
        check(m.rows.first?.title == "问候", "renamed")
        let again = model(mock, defaults: d)
        again.refreshList()
        check(again.rows.first?.title == "问候", "the name survives a relaunch (the app's defaults)")
        again.rename("ses_t", to: "")
        check(again.rows.first?.title == "你好", "an empty name: back to the first message")
        // a task runs: no delete (stop first)
        let busy = model(Mock())
        feed(busy, "task-card", upTo: SessionTests.isKind("resumed"))
        check(!busy.canDelete("ses_t"), "a task runs: delete off")
        // delete: the helper's op, the row and the state gone, the name with it
        m.selected = "ses_t"
        m.rename("ses_t", to: "x")
        m.delete("ses_t")
        check(mock.requests.last as NSDictionary? == ["op": "session.delete", "session_id": "ses_t"] as NSDictionary, "session.delete sent")
        check(m.rows.isEmpty && m.selected == nil && m.states["ses_t"] == nil && SessionNames(defaults: d).all["ses_t"] == nil, "deleted: gone from the list, the selection, the names")
        m.client.feed(["kind": "session.message", "session_id": "ses_t", "seq": 1, "msg_id": "m", "role": "user", "text": "late"])
        check(m.rows.isEmpty, "a late line of it brings nothing back")
        // refused by the helper: said, kept
        let mock2 = Mock()
        mock2.replies = [SessionClient.Op.list: mock.replies[SessionClient.Op.list]!, "session.delete": ["ok": false, "code": "task_running"]]
        let r = model(mock2)
        r.refreshList()
        r.delete("ses_t")
        check(r.rows.count == 1 && r.notice != nil, "refused: kept, and said why")
    }

    // MARK: settings

    static func settingsTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.end: ["ok": true]]
        let config = Locked("ds-flash")
        let lang = Locked(ResolvedLang.zhHans)
        let client = SessionClient(transport: mock)
        let m = ShellModel(client: client, defaults: scratchDefaults(), config: { config.value }, lang: { lang.value }, work: { $0() }, deliver: { $0() })
        check(client.defaultConfig == "ds-flash" && client.defaultLang == "zh", "the client's defaults from the settings at once")
        config.value = "or-luna"; lang.value = .en
        m.applySettings()
        check(client.defaultConfig == "or-luna" && client.defaultLang == "en", "and when they change")
        // a key saved: idle sessions get a new process on their next message; one with a task running keeps its own
        feed(m, "chat")
        m.client.feed(["kind": "session.task", "session_id": "ses_busy", "seq": 1, "msg_id": "m", "run_id": "r9", "raw": "x", "by": "slash"])
        // and one whose task's undo is still open keeps its process (its end would close the undo)
        for l in SessionTests.lines("task-undo").prefix(while: { $0.event.kind != "result_response" }) {
            var l = l; l.sessionId = "ses_undo"; m.client.feed(l)
        }
        check(m.undoOpen("ses_undo"), "the undo is open")
        mock.replies[SessionClient.Op.send] = ["ok": true]
        // (they came into view with nothing known of their settings: each converged once already — their set_config
        // had no answer: settled, then the save)
        m.client.reconciling.wait()
        m.client.convergeAll(); mock.requests = []
        config.value = "ds-flash"
        m.settingsChanged()
        config.value = "or-luna"; mock.requests = []
        m.settingsChanged()
        // the new settings reach every live session in place (set_config, harness#64): nothing restarted, nothing stopped
        let configs = mock.requests.filter { (($0["line"] as? [String: Any])?["type"] as? String) == "set_config" }
        check(configs.compactMap { $0["session_id"] as? String } == ["ses_busy", "ses_t", "ses_undo"]
              && configs.allSatisfy { ($0["line"] as? [String: Any])?["config"] as? String == "or-luna" && ($0["line"] as? [String: Any])?["lang"] as? String == "en" },
              "set_config to each live session, with the settings now: \(configs)")
        check(!mock.requests.contains { $0["op"] as? String == SessionClient.Op.end }, "no restart for a model or language change")
        // a new key: the process reads keys when it starts, so a new one is asked of the helper too, when idle (end_if_idle)
        mock.requests = []
        m.settingsChanged(keyChanged: true)
        let ends = mock.requests.filter { $0["op"] as? String == SessionClient.Op.end }
        check(ends.compactMap { $0["session_id"] as? String } == ["ses_busy", "ses_t", "ses_undo"] && ends.allSatisfy { $0["when_idle"] as? Bool == true },
              "a new key: a restart asked of the helper for each live session, when idle: \(ends)")
    }

    /// #107 review (C, item 4): a /cua sent and not yet echoed is not "idle" to anyone but the helper; a settings change
    /// right after it asks for a restart only when idle, and only after the send (one request per session at a time).
    /// (B) Every session opens again with the new settings, whether or not its process could end then.
    static func settingsOrderTests() {
        // the reviewer's order: /cua acked by the helper, its session.task not here yet, then the settings saved
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true], SessionClient.Op.end: ["ok": true, "deferred": true]]
        let m = model(mock)
        for l in SessionTests.lines("chat") { m.client.feed(l) }
        m.selected = "ses_t"
        m.draft = "/cua 把报告发给老板"
        m.submit()
        check(m.client.state("ses_t").outbox.first?.sending == true && m.client.state("ses_t").runningTask == nil, "the /cua is on its way, no task here yet")
        m.settingsChanged(keyChanged: true)
        let after = mock.requests.drop { $0["op"] as? String != SessionClient.Op.send }
        check(after.filter { $0["op"] as? String == SessionClient.Op.end && $0["when_idle"] as? Bool != true }.isEmpty
              && after.contains { $0["op"] as? String == SessionClient.Op.end && $0["when_idle"] as? Bool == true },
              "no bare session.end after the /cua: a restart when idle, for the helper to decide: \(after.map { $0["op"] ?? "" })")

        // the client never lets a restart overtake a send it made first (the send blocks in the helper meanwhile)
        final class Slow: SessionTransport {
            let lock = NSLock()
            var log: [String] = []
            let release = DispatchSemaphore(value: 0)
            let inSend = DispatchSemaphore(value: 0)
            func request(_ body: [String: Any]) -> [String: Any]? {
                let op = body["op"] as? String ?? ""
                lock.lock(); log.append(op + ">"); lock.unlock()
                if op == SessionClient.Op.send { inSend.signal(); release.wait() }
                lock.lock(); log.append("<" + op); lock.unlock()
                return ["ok": true]
            }
            func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool { false }
        }
        let slow = Slow()
        let c = SessionClient(transport: slow)
        c.feed(SessionTests.lines("chat")[0])
        let sendDone = DispatchSemaphore(value: 0), restartDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = c.send(.cua("x"), to: "ses_t"); sendDone.signal() }
        slow.inSend.wait()
        DispatchQueue.global().async { c.restart("ses_t"); restartDone.signal() }
        usleep(100_000)
        slow.lock.lock(); let early = slow.log; slow.lock.unlock()
        slow.release.signal()
        sendDone.wait(); restartDone.wait()
        check(early == ["session.send>"] && slow.log == ["session.send>", "<session.send", "session.end>", "<session.end"],
              "the restart waits for the send before it: \(early) then \(slow.log)")

        // B: a session that exited (or was busy) opens again with the new settings, not the ones it was opened with
        let mock2 = Mock()
        mock2.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_x"], SessionClient.Op.send: ["ok": true],
                         SessionClient.Op.end: ["ok": false, "code": "not_open"]]
        let config = Locked("provider-a")
        let m2 = ShellModel(client: SessionClient(transport: mock2), defaults: scratchDefaults(), config: { config.value }, lang: { .zhHans },
                            work: { $0() }, deliver: { $0() })
        m2.newConversation(); m2.draft = "你好"; m2.submit()
        check(mock2.requests.first { $0["op"] as? String == SessionClient.Op.open }?["config"] as? String == "provider-a", "opened with provider a")
        m2.client.feed(["kind": "session.start", "session_id": "ses_x", "resumed": false, "last_seq": 0])
        m2.client.reconciling.wait()          // (the reconcile its start sets off, done first)
        m2.client.feed(["kind": "helper.session_exit", "session_id": "ses_x", "code": 0])
        check(m2.states["ses_x"]?.exited != nil, "its process gone")
        config.value = "provider-b"
        m2.settingsChanged()
        mock2.requests = []
        m2.selected = "ses_x"; m2.draft = "再问"; m2.submit()
        let reopen = mock2.requests.first { $0["op"] as? String == SessionClient.Op.open }
        check(reopen?["config"] as? String == "provider-b", "the exited session opens again with the new provider: \(String(describing: reopen?["config"]))")
    }

    /// #107 review (A): cloud models off — a session sends nothing (no session.open, no say), even with a key saved;
    /// the chat says so; turned back on, the next send goes.
    static func cloudOffTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_c"], SessionClient.Op.send: ["ok": true]]
        let on = Locked(false)
        let m = ShellModel(client: SessionClient(transport: mock), defaults: scratchDefaults(), config: { "ds-flash" }, lang: { .zhHans },
                           cloudOn: { on.value }, work: { $0() }, deliver: { $0() })
        m.refreshSettings()
        check(m.cloudOff, "cloud off: the chat's row says a conversation needs a cloud model")
        m.newConversation(); m.draft = "你好"; m.submit()
        check(mock.requests.isEmpty && m.draft == "你好" && m.notice != nil, "a new conversation: nothing opened, nothing sent, the text stays: \(mock.requests)")
        for l in SessionTests.lines("chat") { m.client.feed(l) }
        m.selected = "ses_t"; m.draft = "/cua 打开备忘录"; m.submit()
        m.retry()
        m.client.reconciling.wait()
        let types = mock.requests.compactMap { ($0["line"] as? [String: Any])?["type"] as? String }
        check(types.allSatisfy { $0 == "set_config" } && !mock.requests.contains { $0["op"] as? String == SessionClient.Op.open },
              "an open session: no say, no cua, no retry (only its null, set_config): \(types)")
        on.value = true
        m.settingsChanged()
        mock.requests = []
        m.submit()
        check(!m.cloudOff && sent(mock)?["type"] as? String == "cua", "cloud on again: the next send goes: \(String(describing: sent(mock)))")
    }

    /// A2 (replacing #107 review item 1's scroll gate): the card never scrolls inside, so its options take a click at
    /// once; "fits" is the one layout fact (its whole height against the pinned place's room).
    static func cardBodyTests() {
        check(CardBody.fits(height: 100, room: 100) && !CardBody.fits(height: 101, room: 100), "fits: no taller than the room")
        check(!CardBody.fits(height: 0, room: 100) && !CardBody.fits(height: 10, room: 0), "not laid out, or no room: not")
        check(CardBody.pinRoom(columnHeight: 800) == 400, "the room: half the column")
        check(CardBody.cap(columnHeight: 600) >= CardBody.minHeight && CardBody.cap(columnHeight: 600) <= 200 && CardBody.cap(columnHeight: 3000) == CardBody.maxHeight,
              "the queue's cap: a share of the column, bounded: \(CardBody.cap(columnHeight: 600))")
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true]]
        let timers = Timers()
        let m = model(mock, timers: timers)
        feed(m, "task-card", upTo: SessionTests.isKind("ask"))
        m.selected = "ses_t"
        let s = m.states["ses_t"]!
        let (run, open) = s.openCard!
        let card = CardModel(card: open.card, runId: run, askId: open.askId)
        guard let approve = card.buttons.first(where: { $0.role == .approve }) else { check(false, "the fixture's card has an approve option"); return }
        check(m.buttonEnabled(approve, card: card, in: s), "approve: on as the card shows, before any layout")
        m.click(approve)
        timers.advance(CardStore.takeBack)
        check(sent(mock)?["option"] as? Int == approve.index, "a click sends the approve option (after its take-back)")
        // another card starts unseen; its way out needs nothing
        let mock2 = Mock()
        mock2.replies = [SessionClient.Op.send: ["ok": true]]
        let m2 = model(mock2)
        feed(m2, "task-card", upTo: SessionTests.isKind("ask"))
        m2.selected = "ses_t"
        if let cancel = card.buttons.first(where: { $0.role == .cancel }) {
            check(m2.buttonEnabled(cancel, card: card, in: m2.states["ses_t"]!), "the way out: on without scrolling")
            m2.click(cancel)
            check(sent(mock2)?["option"] as? Int == cancel.index, "and sent")
        }
        check(CardModel.Role.approve.needsWholeBody && CardModel.Role.delegate.needsWholeBody && !CardModel.Role.cancel.needsWholeBody
              && !CardModel.Role.choice.needsWholeBody && !CardModel.Role.undo.needsWholeBody, "approve and delegate wait for the whole body; the rest do not")
    }

    /// #107 review (item 5, handoff §3.1): nothing in the window's views moves the keyboard focus — a card that arrives
    /// while the user types must never get the typing (its field's Return would send it as the answer).
    /// The 0.5 window's view files, from the main app's source list in build.sh (whatever they are named, wherever they
    /// are): each file that holds a view of the window (a `shell: ShellModel` property), and each file declaring a View
    /// those build (`Name(`), comment lines left out. The old window (flag off) is not in it: its views have no shell.
    static func windowViewFiles() -> [(name: String, code: String)] {
        let app = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard let build = try? String(contentsOf: app.appendingPathComponent("build.sh"), encoding: .utf8) else { check(false, "build.sh readable"); return [] }
        let lines = build.components(separatedBy: "\n")
        guard let at = lines.firstIndex(where: { $0.contains("-o \"$MAIN/Contents/MacOS/DeskMind\"") }), at + 1 < lines.count else {
            check(false, "build.sh: the main app's swiftc line"); return []
        }
        let files = lines[at + 1].split(separator: " ").map(String.init).filter { $0.hasSuffix(".swift") && !$0.hasPrefix("Shared/") }
        var code: [String: String] = [:]
        for f in files {
            guard let t = try? String(contentsOf: app.appendingPathComponent(f), encoding: .utf8) else { check(false, "\(f) readable"); continue }
            code[f] = t.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        }
        func views(_ c: String) -> [String] {
            c.components(separatedBy: "\n").compactMap { l -> String? in
                let t = l.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("struct ") || t.hasPrefix("final class ") || t.hasPrefix("class "), let colon = t.firstIndex(of: ":") else { return nil }
                let head = t[..<colon].split(separator: " ").last.map(String.init) ?? ""
                return t[colon...].contains(" View") ? head : nil
            }
        }
        var window = Set(code.filter { $0.value.contains("var shell: ShellModel") }.map(\.key))
        let built = window.flatMap { f in code.filter { g in !window.contains(g.key) && views(g.value).contains { code[f]!.contains($0 + "(") } }.map(\.key) }
        window.formUnion(built)
        return window.sorted().map { ($0, code[$0]!) }
    }

    /// M2 A2: every file of the window's views is checked (windowViewFiles: from build.sh's list, so a renamed or moved
    /// card view is still in it), and none of them brings a window forward or activates the app either (#103: the run
    /// view's five calls that did were removed; handoff §3.1).
    static func focusTests() {
        let files = windowViewFiles()
        let names = files.map(\.name)
        check(names.contains("Main/MainSplitView.swift") && names.count >= 2, "the window's view files: \(names)")
        let movers = ["@FocusState", ".focused(", "defaultFocus", "makeFirstResponder", "becomeFirstResponder", "prefersDefaultFocus", "focusScope", "FocusedValue",
                      "NSApp.activate", ".activate(", "makeKeyAndOrderFront", "orderFrontRegardless", "orderFront(", "makeKey()", "stepAside", "unhide("]
        for (n, code) in files {
            var c = code
            // the one focus move allowed (lead 10-25): the composer's @FocusState and its .focused binding, which take
            // ShellModel.focusRequest (the user's Esc out of a card) -- once each, in Composer, and nowhere else
            if n == "Main/MainSplitView.swift", let composer = c.range(of: "struct Composer: View {") {
                let part = String(c[composer.lowerBound...])
                let ok = part.components(separatedBy: "@FocusState private var focused: Bool").count == 2
                    && part.components(separatedBy: ".focused($focused)").count == 2
                    && part.contains("if shell.takeFocus(n) { focused = true }")
                check(ok, "the composer's focus: one @FocusState, one binding, set only from takeFocus")
                c = c.replacingOccurrences(of: "@FocusState private var focused: Bool", with: "").replacingOccurrences(of: ".focused($focused)", with: "")
            }
            // and the card's: which option has the focus, observed to scroll it into view -- never assigned
            if n == "Main/CardViews.swift" {
                check(c.components(separatedBy: "@FocusState private var focusedOption: Int?").count == 2
                      && c.components(separatedBy: ".focused($focusedOption, equals: c.index)").count == 2
                      && c.range(of: #"focusedOption\s*=[^=]"#, options: .regularExpression) == nil,
                      "the card's focus: observed only, never set")
                c = c.replacingOccurrences(of: "@FocusState private var focusedOption: Int?", with: "").replacingOccurrences(of: ".focused($focusedOption, equals: c.index)", with: "")
            }
            let found = movers.filter { c.contains($0) }
            check(found.isEmpty, "\(n) moves no focus and brings nothing forward (a card's field is focused only by the user's click): \(found)")
        }
        let shell = (try? String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Shared/Shell.swift"), encoding: .utf8)) ?? ""
        check(shell.components(separatedBy: "focusRequest += 1").count == 2, "one place makes a focus request (Esc out of a card)")
        let all = files.map(\.code).joined(separator: "\n")
        check(all.contains("struct CardView") && all.contains("TextField(L(\"Or answer in your own words\""), "the check reads the card's own field's file")
    }

    /// #107 review (item 3): the helper closed an idle session (watched or not): nothing shows as cut off, a watch does
    /// not bring it back, the next send does.
    static func idleReclaimTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_t"], SessionClient.Op.send: ["ok": true]]
        let m = model(mock)
        _ = m.client.open(sessionId: "ses_t", config: "c", lang: "zh")
        for l in SessionTests.lines("chat") { m.client.feed(l) }
        let before = m.states["ses_t"]!
        m.client.feed(["kind": "helper.session_exit", "session_id": "ses_t", "code": 0, "start_seq": 0, "last_seq": before.lastSeq, "idle": true])
        let after = m.states["ses_t"]!
        check(after.exited != nil && after.status == before.status && !after.messages.contains { $0.interrupted } && after.unsent.isEmpty,
              "closed for being idle: the dot as it was (\(after.status)), nothing interrupted, nothing unsent")
        mock.requests = []
        check(!m.client.reopenIfExited("ses_t", onlyOpenedHere: true) && mock.requests.isEmpty, "a watch does not open it again")
        m.selected = "ses_t"; m.draft = "还在吗"; m.submit()
        check(mock.requests.first?["op"] as? String == SessionClient.Op.open && sent(mock)?["type"] as? String == "say", "the next send opens it, then sends")
        // helper.watching's `idle` (closed while this app was not watching) reads the same
        let mock2 = Mock()
        mock2.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_t"]]
        let c = SessionClient(transport: mock2)
        _ = c.open(sessionId: "ses_t")
        mock2.streamLines = [["kind": "helper.watching", "open": [Any](), "idle": ["ses_t"]]]
        mock2.nextStreams = [mock2.streamLines, []]
        _ = c.watch()
        let opens = mock2.requests.filter { $0["op"] as? String == SessionClient.Op.open }.count
        check(c.state("ses_t").exited != nil && opens == 1, "closed idle while away: exited, not opened again by the watch (\(opens) opens)")
    }

    /// #107 re-review (1): cloud models off holds back only what reaches a model. Undo (the session runs it from its
    /// receipts), the way out, Stop and a queue cancel always go; an approve, words, a retry do not.
    static func cloudOffNoModelTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true]]
        let client = SessionClient(transport: mock)
        let u = ShellModel(client: client, defaults: scratchDefaults(), config: { "ds-flash" }, lang: { .zhHans },
                           cloudOn: { false }, work: { $0() }, deliver: { $0() })
        feed(u, "task-undo", upTo: SessionTests.isKind("session.task_end"))
        u.client.reconciling.wait()         // (its null, set_config, first)
        u.selected = "ses_t"
        let t = u.states["ses_t"]!.tasks.last!
        let rc = CardModel(resultCard: t.resultCard!, runId: t.runId)
        u.click(rc.buttons.first { $0.role == .undo }!)
        check(sent(mock)?["type"] as? String == "respond" && sent(mock)?["option"] as? Int == rc.buttons.first { $0.role == .undo }!.index,
              "cloud off: the result card's undo goes (no model): \(String(describing: sent(mock)))")
        // an ask card: its way out goes, its approve does not
        let mock2 = Mock()
        mock2.replies = [SessionClient.Op.send: ["ok": true]]
        let m = ShellModel(client: SessionClient(transport: mock2), defaults: scratchDefaults(), config: { "ds-flash" }, lang: { .zhHans },
                           cloudOn: { false }, work: { $0() }, deliver: { $0() })
        feed(m, "task-card", upTo: SessionTests.isKind("ask"))
        m.selected = "ses_t"
        let s = m.states["ses_t"]!
        let (run, open) = s.openCard!
        let card = CardModel(card: open.card, runId: run, askId: open.askId)
        m.fit(card)
        m.client.reconciling.wait()
        let before = sends(mock2)       // (the session's null, set_config)
        m.click(card.buttons.first { $0.role == .approve }!)
        check(sends(mock2) == before, "cloud off: an approve (the task goes on, the model with it) is held back")
        m.stop()
        check(sent(mock2)?["type"] as? String == "stop", "cloud off: Stop goes: \(String(describing: sent(mock2)))")
        m.queueCancel("q1")
        check(sent(mock2)?["type"] as? String == "queue_cancel", "cloud off: a queue cancel goes: \(String(describing: sent(mock2)))")
        let n = sends(mock2)
        m.retry()
        check(sends(mock2) == n, "cloud off: a retry is held back")
        m.click(card.buttons.first { $0.role == .cancel }!)
        check(sent(mock2)?["type"] as? String == "answer" && sent(mock2)?["option"] as? Int == card.buttons.first { $0.role == .cancel }!.index,
              "cloud off: the way out goes")
        check(CardModel.Role.undo.reachesNoModel && CardModel.Role.cancel.reachesNoModel && !CardModel.Role.approve.reachesNoModel
              && !CardModel.Role.choice.reachesNoModel && !CardModel.Role.delegate.reachesNoModel && !CardModel.Role.skipStep.reachesNoModel,
              "what reaches no model: the way out and undo")
    }

    /// No app activation, ever, unless the user directly acted on DeskMind (its own button, its live card, the Dock, a
    /// notification). The guarantee is a type (Shared/Activation.swift): whatever brings DeskMind forward takes a
    /// UserGesture, which only Activation's factories make. This check holds what the type cannot, over every source
    /// the main app and the helper build from (build.sh): the raw AppKit calls that can activate or order a window
    /// forward appear only inside the funnel and the background launcher (by file and function); the factories appear
    /// only in user-event handlers (a button's action, the AppKit mouse-up, the delegate's reopen); every panel is
    /// non-activating; every `open` of an app is in the background (-g). (rc.15 device check, 10-24: the activation
    /// seen 2 s after a plan card came from the test script standing in for the user — scripts/rc_e2e/answer_asks.py
    /// activates DeskMind before its click — not from the app; #115 review: an indirect call, a config that only looked
    /// like a background one, must not pass either.)
    static func activationTests() {
        let app = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard let build = try? String(contentsOf: app.appendingPathComponent("build.sh"), encoding: .utf8) else { check(false, "build.sh readable"); return }
        let lines = build.components(separatedBy: "\n")
        var files: Set<String> = []
        for marker in ["-o \"$MAIN/Contents/MacOS/DeskMind\"", "-o \"$HELPER/Contents/MacOS/DeskMindHands\""] {
            guard let at = lines.firstIndex(where: { $0.contains(marker) }), at + 1 < lines.count else { check(false, "build.sh: \(marker)"); continue }
            files.formUnion(lines[at + 1].split(separator: " ").map(String.init).filter { $0.hasSuffix(".swift") })
        }
        check(files.contains("Shared/Activation.swift") && files.contains("Helper/LiveCard.swift") && files.count > 40, "every source of both apps, the funnel among them: \(files.count)")
        func enclosing(_ ls: [String], _ i: Int) -> String {
            for j in stride(from: i, through: 0, by: -1) {
                if let r = ls[j].range(of: "func ") { return String(ls[j][r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }) }
            }
            return ""
        }
        // raw calls → where they may be (file:function)
        let raw: [(String, Set<String>)] = [
            ("NSApp.activate", ["Activation.swift:bringForward"]), (".activate(", ["Activation.swift:bringForward"]),
            ("activateWithOptions", []), ("activateIgnoringOtherApps", []), ("NSApp.unhide", []),
            ("makeKeyAndOrderFront", ["Activation.swift:bringForward"]), ("orderFrontRegardless", ["Activation.swift:showPanel"]),
            ("openApplication(", ["Activation.swift:openApp", "Activation.swift:background"]),
            ("/usr/bin/open", ["Activation.swift:bundleInBackground", "HelperInstaller.swift:launch"]),
            ("UserGesture(", ["Activation.swift:onClick", "Activation.swift:mouseUp", "Activation.swift:reopen"]),
        ]
        // factories → the handlers they may be used in (a button's action: the line gives it as one)
        var found: [String] = []
        for f in files.sorted() {
            guard let text = try? String(contentsOf: app.appendingPathComponent(f), encoding: .utf8) else { check(false, "\(f) readable"); continue }
            let ls = text.components(separatedBy: "\n")
            let name = (f as NSString).lastPathComponent
            for (i, l) in ls.enumerated() {
                let code = l.components(separatedBy: "//").first ?? ""
                let at = "\(name):\(enclosing(ls, i))"
                for (api, allowed) in raw where code.contains(api) && !(api == "UserGesture(" && code.contains("fileprivate init")) {
                    if !allowed.contains(at) { found.append("\(f):\(i + 1) \(api) in \(enclosing(ls, i))") }
                }
                // (the launcher's own arguments are checked by what they are, below)
                if code.contains("/usr/bin/open") && name != "Activation.swift" && !ls[i...min(ls.count - 1, i + 2)].joined().contains("-g") { found.append("\(f):\(i + 1): open without -g") }
                if code.contains("Activation.onClick") && name != "Activation.swift" && !(code.contains("Button(") || code.contains("pill(")) {
                    found.append("\(f):\(i + 1): Activation.onClick outside a button's action")
                }
                if code.contains("Activation.mouseUp") && enclosing(ls, i) != "mouseUp" { found.append("\(f):\(i + 1): Activation.mouseUp outside mouseUp") }
                if code.contains("Activation.reopen") && enclosing(ls, i) != "applicationShouldHandleReopen" { found.append("\(f):\(i + 1): Activation.reopen outside the reopen") }
                if code.contains("NSPanel(") && !ls[i...min(ls.count - 1, i + 1)].joined().contains(".nonactivatingPanel") { found.append("\(f):\(i + 1): an NSPanel without .nonactivatingPanel") }
            }
        }
        check(found.isEmpty, "nothing activates an app outside a user's own action: \(found)")
        // the background launcher's own configuration and arguments, as they are passed (#115 review at 6d3aee0: the
        // scan allows the function; this holds what it does)
        let cfg = Launch.backgroundConfig()
        check(cfg.activates == false && cfg.addsToRecentItems == false && cfg.createsNewApplicationInstance == false,
              "a background launch: activates false, no recent item, the running instance")
        check(Launch.bundleArguments("x.y").first == "-g" && Launch.bundleArguments("x.y") == ["-g", "-b", "x.y"], "a background reopen: open -g -b")
        let src = (try? String(contentsOf: app.appendingPathComponent("Shared/Activation.swift"), encoding: .utf8)) ?? ""
        check(src.contains("openApplication(at: url, configuration: backgroundConfig())") && src.contains("open.arguments = bundleArguments(bundle)"),
              "the launcher passes them as they are")
    }

    /// #107 re-review (2): 0.5.0 has no local-only mode. The 0.5 window's model settings show the cloud switch on and
    /// fixed (with a line why); the window as it was keeps its choice.
    static func modelChoiceTests() {
        check(!ModelChoice.offersLocalOnly(inShell: true) && ModelChoice.offersLocalOnly(inShell: false), "local-only offered only outside the 0.5 window")
        check(ModelChoice.startsCloud(inShell: false, saved: true) && !ModelChoice.startsCloud(inShell: false, saved: false),
              "the old window's settings show what is stored")
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func code(_ f: String) -> String {
            let t = (try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) ?? ""
            return t.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        }
        let main = code("Main/MainSplitView.swift"), sheet = code("Main/CloudModel.swift")
        check(main.contains("CloudModelSheet(inShell: true)") && !main.contains("CloudModelSheet()"), "the 0.5 window opens the settings as its own")
        check(sheet.contains("Conversations in DeskMind 0.5 need a cloud model."), "the sheet: the 0.5 window's line why")
    }

    /// The card's own words (never read): A2 lays the field out after the card's content, which no longer scrolls inside,
    /// so on every card the field takes words at once (#107 re-review (4)'s wait was for a scrolled body), held for the
    /// take-back as a click is.
    static func cardWordsTests() {
        let card: [String: Any] = ["kind": "action", "text": "这会把内容发出去：在 Mail 里点「发送」", "blocking": true, "free_text": true,
                                   "options": [["kind": "approve", "text": "可以"], ["kind": "cancel", "text": "先别做了"]]]
        let lines: [[String: Any]] = [
            ["kind": "session.message", "session_id": "ses_w", "seq": 1, "msg_id": "u1", "role": "user", "text": "/cua 发周报", "via": "cua"],
            ["kind": "session.task", "session_id": "ses_w", "seq": 2, "msg_id": "u1", "run_id": "r1", "raw": "发周报", "by": "slash"],
            ["kind": "start", "session_id": "ses_w", "run_id": "r1", "seq": 1, "raw": "发周报"],
            ["kind": "ask", "session_id": "ses_w", "run_id": "r1", "seq": 2, "ask_id": "a1", "card": card]]
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true]]
        let timers = Timers()
        let m = model(mock, timers: timers)
        for l in lines { m.client.feed(l) }
        m.selected = "ses_w"
        guard let (run, open) = m.states["ses_w"]?.openCard else { check(false, "the card is open"); return }
        let c = CardModel(card: open.card, runId: run, askId: open.askId)
        check(c.allowsFreeText && c.buttons.contains { $0.role == .approve }, "a card with an approve and its own field")
        check(m.wordsEnabled(c, in: m.states["ses_w"]!), "its field: on as the card shows")
        m.answer(c, text: "好的")
        check(sends(mock) == 0, "held for the take-back first")
        timers.advance(CardStore.takeBack)
        check(sent(mock)?["text"] as? String == "好的", "then sent: \(String(describing: sent(mock)))")
        // a card with no approve-type option takes words at once
        var plain = card
        // (a reading: a kind the app knows takes no wait; an unknown kind would — it fails closed, #111 review)
        plain["options"] = [["kind": "reading", "text": "周一"], ["kind": "cancel", "text": "先别做了"]]
        var pl = lines
        pl[3]["card"] = plain
        let mock2 = Mock()
        mock2.replies = [SessionClient.Op.send: ["ok": true]]
        let qt = Timers()
        let q = model(mock2, timers: qt)
        for l in pl { q.client.feed(l) }
        q.selected = "ses_w"
        guard let (run2, open2) = q.states["ses_w"]?.openCard else { check(false, "the plain card is open"); return }
        let c2 = CardModel(card: open2.card, runId: run2, askId: open2.askId)
        q.answer(c2, text: "周二")
        qt.advance(CardStore.takeBack)
        check(sent(mock2)?["text"] as? String == "周二" && q.wordsEnabled(c2, in: q.states["ses_w"]!) == false,
              "no approve-type option: words go without waiting for the body (\(sends(mock2)) sent)")
    }

    /// #107 re-review (3): remembered settings never mark a session opened here. After a settings save and a helper
    /// restart, a reconnecting watch reopens only the sessions this client opened (with the new settings).
    static func settingsReopenTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_a"], SessionClient.Op.end: ["ok": true, "deferred": true]]
        let config = Locked("provider-a")
        let m = ShellModel(client: SessionClient(transport: mock), defaults: scratchDefaults(), config: { config.value }, lang: { .zhHans },
                           work: { $0() }, deliver: { $0() })
        _ = m.client.open(sessionId: "ses_a", config: "provider-a", lang: "zh")
        m.client.feed(["kind": "session.start", "session_id": "ses_a", "resumed": false, "last_seq": 0])
        m.client.reconciling.wait()          // (the reconcile its start sets off, done first)
        // two sessions this client only saw (the list, a watch): one running, one read from its history
        for l in SessionTests.lines("chat") { m.client.feed(l) }
        m.client.feed(["kind": "session.message", "session_id": "ses_r", "seq": 1, "msg_id": "u", "role": "user", "text": "旧的"])
        m.client.feed(["kind": "helper.session_exit", "session_id": "ses_r", "code": 0])
        config.value = "provider-b"
        m.settingsChanged()
        // the helper restarts: every process gone
        for id in ["ses_a", "ses_t"] { m.client.feed(["kind": "helper.session_exit", "session_id": id, "code": 0]) }
        mock.requests = []
        mock.streamLines = [["kind": "helper.watching", "open": [Any]()]]
        _ = m.client.watch()
        let opens = mock.requests.filter { $0["op"] as? String == SessionClient.Op.open }
        check(opens.compactMap { $0["session_id"] as? String } == ["ses_a"],
              "the watch reopens only the session opened here: \(opens.compactMap { $0["session_id"] as? String })")
        check(opens.first?["config"] as? String == "provider-b", "with the saved settings: \(String(describing: opens.first?["config"]))")
        // and a send to one only seen opens it with them too
        mock.requests = []
        mock.replies[SessionClient.Op.open] = ["ok": true, "session_id": "ses_r"]
        mock.replies[SessionClient.Op.send] = ["ok": true]
        m.selected = "ses_r"; m.draft = "再问"; m.submit()
        check(mock.requests.first { $0["op"] as? String == SessionClient.Op.open }?["config"] as? String == "provider-b", "a send opens a seen one with the new settings")
    }

    /// #107 re-review (5): an end the helper refused (not_idle) leaves the session free to open again; one it did end
    /// is not opened again by itself.
    static func endRefusedTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_t"], SessionClient.Op.end: ["ok": false, "code": "not_idle"]]
        let c = SessionClient(transport: mock)
        _ = c.open(sessionId: "ses_t")
        for l in SessionTests.lines("chat") { c.feed(l) }
        check(!c.end("ses_t"), "not idle: the end refused")
        c.feed(["kind": "helper.session_exit", "session_id": "ses_t", "code": 1])
        mock.requests = []
        check(c.reopenIfExited("ses_t", onlyOpenedHere: true) && mock.requests.contains { $0["op"] as? String == SessionClient.Op.open },
              "its process gone later: opened again (the refused end left no mark)")
        mock.replies[SessionClient.Op.end] = ["ok": true]
        check(c.end("ses_t"), "idle: ended")
        c.feed(["kind": "helper.session_exit", "session_id": "ses_t", "code": 0])
        mock.requests = []
        check(!c.reopenIfExited("ses_t", onlyOpenedHere: true) && mock.requests.isEmpty, "ended by the app: not opened again by itself")
    }

    /// #107 re-review (bug A): the cloud switch is a privacy setting. It shows what is stored (in the 0.5 window too);
    /// there it can only go from off to on; Save writes the engine only if the user moved it (Enter on a sheet left as
    /// it opened, or a key edited, writes none). The 0.5 sheet does not point to a local model it does not offer.
    static func privacySwitchTests() {
        check(!ModelChoice.startsCloud(inShell: true, saved: false), "the 0.5 window: a stored off shows off")
        check(ModelChoice.startsCloud(inShell: true, saved: true), "and a stored on, on")
        check(!ModelChoice.switchLocked(inShell: true, saved: false) && ModelChoice.switchLocked(inShell: true, saved: true)
              && !ModelChoice.switchLocked(inShell: false, saved: true), "the 0.5 window: movable only while off (to turn it on); the old window: always")
        check(ModelChoice.engineToWrite(saved: false, shown: false) == nil && ModelChoice.engineToWrite(saved: true, shown: true) == nil,
              "Save with the switch as it opened: the engine not written")
        check(ModelChoice.engineToWrite(saved: false, shown: true) == true && ModelChoice.engineToWrite(saved: true, shown: false) == false,
              "Save after the user moved it: written as moved")
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let raw = (try? String(contentsOf: dir.appendingPathComponent("Main/CloudModel.swift"), encoding: .utf8)) ?? ""
        let sheet = raw.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        check(sheet.contains("if let engine = ModelChoice.engineToWrite(saved: savedCloud, shown: useCloud) { CloudModelSettings.engineIsCloud = engine }")
              && !sheet.contains("CloudModelSettings.engineIsCloud = useCloud"), "the sheet's Save writes the engine through engineToWrite only")
        check(sheet.contains(".disabled(ModelChoice.switchLocked(inShell: inShell, saved: savedCloud))")
              && sheet.contains("useCloud = ModelChoice.startsCloud(inShell: inShell, saved: savedCloud)"), "the sheet's switch: stored state, locked as ModelChoice says")
        let note = sheet.components(separatedBy: "Text(inShell").dropFirst().first ?? ""
        check(!note.isEmpty && !(note.components(separatedBy: ":").first ?? "").contains("local model"),
              "the 0.5 sheet's note does not send sensitive tasks to a local model it does not offer")
        // the row stays while cloud is off (the switch never turned on behind the user's back)
        let m = ShellModel(client: SessionClient(transport: Mock()), defaults: scratchDefaults(), config: { "c" }, lang: { .zhHans },
                           cloudOn: { false }, work: { $0() }, deliver: { $0() })
        m.refreshSettings()
        check(m.cloudOff, "cloud off: the chat's row stays")
    }

    /// A2: a card never scrolls inside and nothing on it waits to be scrolled to -- no ScrollView in the card, no "read
    /// the whole card first" hint; what goes out is laid out before the buttons.
    static func cardHintTests() {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Main/CardViews.swift")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let card = (text.components(separatedBy: "struct CardView").dropFirst().first ?? "").components(separatedBy: "struct KeyCap").first ?? ""
        let code = card.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        check(!code.contains("ScrollView") && !code.contains("Read the whole card first"), "no scrolling inside the card, nothing to scroll to")
        let consent = code.range(of: "ConsentFields(consent: c)"), buttons = code.range(of: "ForEach(layout.buttons")
        check(consent != nil && buttons != nil && consent!.lowerBound < buttons!.lowerBound, "what goes out is laid out before the buttons")
    }

    /// #107 re-review (effect): an end's exit line can come before its reply: the session is marked ended by the app
    /// before the request (a watch then does not reopen it), and unmarked if the helper refused.
    static func endMarkTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_t"], SessionClient.Op.end: ["ok": true]]
        let c = SessionClient(transport: mock)
        _ = c.open(sessionId: "ses_t")
        for l in SessionTests.lines("chat") { c.feed(l) }
        var reopenedMeanwhile: Bool? = nil
        mock.onRequest = { op in
            guard op == SessionClient.Op.end else { return }
            c.feed(["kind": "helper.session_exit", "session_id": "ses_t", "code": 0])     // the exit first
            reopenedMeanwhile = c.reopenIfExited("ses_t", onlyOpenedHere: true)            // a watch's reconnect then
        }
        check(c.end("ses_t"), "ended")
        mock.onRequest = nil
        check(reopenedMeanwhile == false && mock.requests.filter { $0["op"] as? String == SessionClient.Op.open }.count == 1,
              "its exit before the reply: not reopened by a watch (\(String(describing: reopenedMeanwhile)))")
    }

    /// #107 external review (P2 1): a reply that finished while the window was closed (its first words seen, then the
    /// session reclaimed idle) is read back whole — on the watch's reconnect and on a select — never left as its first
    /// words marked interrupted. The stored message outranks the provisional cut-off, whichever comes first.
    static func backfillTests() {
        let all = SessionTests.lines("chat")
        let cut = SessionTests.raw("chat").firstIndex { $0.contains(#""text":"第1句。","offset":4"#) }!
        let stored = SessionTests.raw("chat").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            .filter { ($0["seq"] as? Int) == 6 }.prefix(1)
        func partial(_ mock: Mock) -> ShellModel {
            let m = model(mock)
            _ = m.client.open(sessionId: "ses_t", config: "c", lang: "zh")
            for l in all[...cut] { m.client.feed(l) }
            check(m.states["ses_t"]?.messages.last?.text == "第0句。第1句。", "the reply's first words came: \(m.states["ses_t"]?.messages.last?.text ?? "")")
            return m
        }
        let whole = "第0句。第1句。第2句。第3句。第4句。"
        // the watch reconnects (the window opened again): the session was closed idle meanwhile
        let mock = Mock()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_t"],
                        SessionClient.Op.history: ["ok": true, "open": false, "last_seq": 6, "lines": Array(stored)]]
        let m = partial(mock)
        mock.requests = []
        mock.streamLines = [["kind": "helper.watching", "open": [Any](), "idle": ["ses_t"]]]
        _ = m.client.watch()
        m.client.backfilling.wait()
        let h = mock.requests.first { $0["op"] as? String == SessionClient.Op.history }
        check(h?["after_seq"] as? Int == 5, "the reconnect reads what was stored after its cursor: \(String(describing: h))")
        let r = m.states["ses_t"]!.messages.last!
        check(r.text == whole && !r.interrupted && !r.streaming, "the reply whole, not interrupted: \(r.text.count) chars, interrupted \(r.interrupted)")
        check(m.states["ses_t"]!.status != .error("interrupted"), "the dot: not an interruption (\(m.states["ses_t"]!.status))")
        // the exit heard first (its first words marked interrupted), then the user opens it: the select reads the rest
        let mock2 = Mock()
        mock2.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_t"],
                         SessionClient.Op.history: ["ok": true, "open": false, "last_seq": 6, "lines": Array(stored)]]
        let m2 = partial(mock2)
        m2.client.feed(["kind": "helper.session_exit", "session_id": "ses_t", "code": 0])
        check(m2.states["ses_t"]!.messages.last!.interrupted, "its process gone unheard-from: provisionally interrupted")
        m2.select("ses_t")
        let r2 = m2.states["ses_t"]!.messages.last!
        check(r2.text == whole && !r2.interrupted, "selected: the stored reply outranks the cut-off: \(r2.text.count) chars, interrupted \(r2.interrupted)")
        // a delta of it coming after the stored message changes nothing
        m2.client.feed(all[cut])
        check(m2.states["ses_t"]!.messages.last!.text == whole, "a late delta after the stored message: nothing")
    }

    /// Final round (4): settings reach live sessions in place (set_config); cloud models off: set_config null to every
    /// live session, remembered for its next process.
    static func modelOffConfigTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true]]
        let on = Locked(true)
        let m = ShellModel(client: SessionClient(transport: mock), defaults: scratchDefaults(), config: { "ds-flash" }, lang: { .zhHans },
                           cloudOn: { on.value }, work: { $0() }, deliver: { $0() })
        for l in SessionTests.lines("chat") { m.client.feed(l) }
        m.client.reconciling.wait()
        mock.requests = []                  // (its first line here converged it to ds-flash)
        on.value = false
        m.settingsChanged()
        let lines = mock.requests.compactMap { $0["line"] as? [String: Any] }
        check(lines.count == 1 && lines[0]["type"] as? String == "set_config" && lines[0]["config"] is NSNull && lines[0]["client_id"] is String,
              "cloud off: set_config null to the live session: \(lines)")
        check(!mock.requests.contains { $0["op"] as? String == SessionClient.Op.end }, "no restart for it")
    }

    /// Final round (4): with cloud models off an open never carries a configuration (it would outrank the stored null)
    /// and set_config null is its first control, before any other; an automatic reopen after an exit the same.
    static func modelOffOpenTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_t"], SessionClient.Op.send: ["ok": true]]
        let c = SessionClient(transport: mock)
        c.modelOff = true
        _ = c.open(sessionId: "ses_t", config: "ds-flash", lang: "zh")
        check(mock.requests.count == 2 && mock.requests[0]["op"] as? String == SessionClient.Op.open && mock.requests[0]["config"] == nil
              && (mock.requests[1]["line"] as? [String: Any])?["type"] as? String == "set_config" && (mock.requests[1]["line"] as? [String: Any])?["config"] is NSNull,
              "model off: open without a config, then set_config null first: \(mock.requests)")
        for l in SessionTests.lines("chat") { c.feed(l) }
        c.feed(["kind": "helper.session_exit", "session_id": "ses_t", "code": 1])
        c.reconciling.wait()            // (the reconciles the lines set off, done before the requests are read afresh)
        mock.requests = []
        _ = c.reopenIfExited("ses_t", onlyOpenedHere: true)
        check(mock.requests.first?["op"] as? String == SessionClient.Op.open && mock.requests.first?["config"] == nil
              && (mock.requests.dropFirst().first?["line"] as? [String: Any])?["config"] is NSNull,
              "an automatic reopen after an exit: the same: \(mock.requests)")
        // back on: the open carries the configuration (the settings stored) again; the set_config after it (a new process:
        // its settings sent again — the accepted cost) is the same
        c.adoptSettings(config: "ds-flash", lang: "zh")
        c.modelOff = false
        c.feed(["kind": "helper.session_exit", "session_id": "ses_t", "code": 1])
        mock.requests = []
        _ = c.reopenIfExited("ses_t", onlyOpenedHere: true)
        check(mock.requests.first?["config"] as? String == "ds-flash"
              && mock.requests.dropFirst().allSatisfy { ($0["line"] as? [String: Any])?["config"] as? String == "ds-flash" },
              "model on: opened with its configuration: \(mock.requests)")
    }

    /// Final round (4): set_config is never taken as applied: a `busy` refusal (it took effect, was not stored) is sent
    /// once more; a second busy, or bad_config, shows the settings did not reach it; its session.config clears that.
    static func configBusyTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true]]
        let steps = Steps()                                  // (its reconciles: run before each check, deskmind#112)
        let c = steps.client(mock)
        c.adoptSettings(config: "ds-flash", lang: "en")
        for l in SessionTests.lines("chat") { c.feed(l) }
        steps.drain(); mock.requests = []
        c.setConfig("ses_t", config: "ds-flash", lang: "en")
        func sentConfigs() -> [[String: Any]] { mock.requests.compactMap { $0["line"] as? [String: Any] }.filter { $0["type"] as? String == "set_config" } }
        let first = sentConfigs().last?["client_id"] as? String ?? ""
        c.feed(["kind": "session.error", "session_id": "ses_t", "code": "busy", "control": "set_config", "client_id": first, "text": "x"])
        steps.drain()
        let second = sentConfigs().last
        check(sentConfigs().count == 2 && second?["config"] as? String == "ds-flash" && second?["client_id"] as? String != first,
              "busy (not stored): sent once more: \(sentConfigs())")
        check(c.state("ses_t").settingsRefused == nil, "not shown yet")
        c.feed(["kind": "session.error", "session_id": "ses_t", "code": "busy", "control": "set_config", "client_id": second?["client_id"] as? String ?? "", "text": "x"])
        check(c.state("ses_t").settingsRefused == "busy", "busy again: shown, never assumed applied")
        c.setConfig("ses_t", config: "ds-flash", lang: "en")
        c.feed(["kind": "session.config", "session_id": "ses_t", "seq": 7, "config": "ds-flash", "lang": "en", "by": "set_config",
                "client_id": sentConfigs().last?["client_id"] as? String ?? ""])
        check(c.state("ses_t").settingsRefused == nil && c.state("ses_t").settings?.config == "ds-flash", "stored: cleared, the session's settings")
        c.setConfig("ses_t", config: "openai:nope|x", lang: "en")
        c.feed(["kind": "session.error", "session_id": "ses_t", "code": "bad_config", "control": "set_config", "client_id": sentConfigs().last?["client_id"] as? String ?? "", "text": "x"])
        check(c.state("ses_t").settingsRefused == "bad_config" && sentConfigs().count == 4, "bad_config: shown at once, not sent again")
    }

    /// Final round (4): no_model — the words are not sent (the bubble says the cloud model is off) and the chat's row
    /// shows, whatever this app's switch says.
    static func noModelTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true]]
        let m = model(mock)
        for l in SessionTests.lines("chat") { m.client.feed(l) }
        m.selected = "ses_t"; m.draft = "你好"; m.submit()
        let cid = sent(mock)?["client_id"] as? String ?? ""
        m.client.feed(["kind": "session.error", "session_id": "ses_t", "code": "no_model", "control": "say", "client_id": cid, "text": "x"])
        let s = m.states["ses_t"]!
        check(s.unsent.first?.refused == "no_model" && ShellText.unsent("no_model", lang: .zhHans) == "没发出去：云端模型关着",
              "no_model: not sent, the bubble says why: \(String(describing: s.unsent.first?.refused))")
        check(!m.cloudOff && m.showsCloudOff(s), "the cloud-off row shows for it")
    }

    /// Final round (5): a pasted model name is saved and sent without its spaces.
    static func modelNameTests() {
        check(ModelChoice.modelName("  deepseek-chat \n") == "deepseek-chat" && ModelChoice.modelName("a b") == "a b", "trimmed at its ends only")
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Main/CloudModel.swift")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let persist = text.components(separatedBy: "private func persist()").dropFirst().first?.components(separatedBy: "private func save()").first ?? ""
        check(persist.contains("ModelChoice.modelName(modelID)") && !persist.contains("model: modelID") && !persist.contains("= modelID"),
              "persist saves the trimmed name")
    }

    /// Final round (6, E1): the stored lines a watch reconnect reads come off the stream's thread (the live lines go on
    /// meanwhile), and not for a session whose last stored seq the helper says is the cursor already.
    static func backfillOffStreamTests() {
        final class Slow: SessionTransport {
            let lock = NSLock()
            var ops: [String] = []
            let release = DispatchSemaphore(value: 0)
            func request(_ body: [String: Any]) -> [String: Any]? {
                let op = body["op"] as? String ?? ""
                lock.lock(); ops.append(op + ":" + (body["session_id"] as? String ?? "")); lock.unlock()
                if op == SessionClient.Op.history { release.wait(); return ["ok": true, "open": false, "lines": [Any]()] }
                return ["ok": true]
            }
            var lines: [[String: Any]] = []
            func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool {
                for l in lines where !onLine(l) { return true }
                return true
            }
        }
        let t = Slow()
        let c = SessionClient(transport: t)
        for l in SessionTests.lines("chat") { c.feed(l) }                    // ses_t at 6
        c.feed(["kind": "session.message", "session_id": "ses_u", "seq": 1, "msg_id": "u", "role": "user", "text": "x"])
        t.lines = [["kind": "helper.watching", "open": [Any](), "last_seq": ["ses_t": 6]],
                   ["kind": "session.message", "session_id": "ses_v", "seq": 1, "msg_id": "v", "role": "user", "text": "live"]]
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = c.watch(); done.signal() }
        let returned = done.wait(timeout: .now() + 2) == .success
        check(returned && c.state("ses_v").messages.first?.text == "live", "the live lines go on while the history is read")
        t.release.signal(); t.release.signal()
        c.backfilling.wait()
        t.lock.lock(); let ops = t.ops; t.lock.unlock()
        check(ops.filter { $0.hasPrefix(SessionClient.Op.history) } == [SessionClient.Op.history + ":ses_u"],
              "read: only the session the helper's last_seq does not match: \(ops)")
    }

    /// Final round (6, E2): a history read while the watch is down (a helper restarting has no process yet) does not
    /// mark the session closed for being idle: the watch, back, says what ran, and the session opened here reopens.
    static func historyWatchDownTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_t"],
                        SessionClient.Op.history: ["ok": true, "open": false, "last_seq": 6, "lines": [Any]()]]
        let c = SessionClient(transport: mock)
        _ = c.open(sessionId: "ses_t", config: "c", lang: "zh")
        for l in SessionTests.lines("chat") { c.feed(l) }
        mock.streamLines = []
        _ = c.watch()                                          // the stream ended: the watch is down
        _ = c.history("ses_t")                                 // the user selects it meanwhile
        check(c.state("ses_t").exited == nil, "the watch down: open: false is not read as its process ended")
        mock.streamLines = [["kind": "helper.watching", "open": [Any]()]]
        _ = c.watch()                                          // back: the helper runs none
        c.backfilling.wait()
        mock.requests = []
        check(c.state("ses_t").exited != nil && c.reopenIfExited("ses_t", onlyOpenedHere: true)
              && mock.requests.contains { $0["op"] as? String == SessionClient.Op.open },
              "the watch back: not running, not idle-closed: opened again (\(mock.requests.map { $0["op"] ?? "" }))")
    }

    /// #107 review of 21d06c8 (P2): after the app restarts, a session read through its history (never opened here)
    /// whose process runs a reply; the watch drops, the process crashes; the watch comes back and the helper does not
    /// list it. It reads as exited all the same — the reply interrupted, the composer on — and a send opens it again.
    static func historyOpenedCrashTests() {
        let mock = Mock()
        let raw = SessionTests.raw("chat")
        let stored = raw.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            .filter { ($0["seq"] as? Int).map { $0 <= 5 } ?? false }.prefix(5)
        mock.replies = [SessionClient.Op.history: ["ok": true, "open": true, "last_seq": 5, "lines": Array(stored)],
                        SessionClient.Op.open: ["ok": true, "session_id": "ses_t"], SessionClient.Op.send: ["ok": true]]
        let m = model(mock)
        m.select("ses_t")                                           // the app again: read, a process runs it
        check(mock.requests.map { $0["op"] as? String ?? "" } == [SessionClient.Op.history], "read from its history, not opened here")
        // its live reply through the watch
        let lines = SessionTests.lines("chat")
        let from = raw.firstIndex { $0.contains(#""msg_id":"msg_51abfa55","text":"","offset":0"#) }!
        let to = raw.firstIndex { $0.contains(#""text":"第1句。","offset":4"#) }!
        for l in lines[from...to] { m.client.feed(l) }
        check(m.states["ses_t"]?.streamingMessage != nil && m.composer.replying, "a reply streams: the composer waits")
        // the watch drops; the process crashes meanwhile; the watch comes back: the helper runs none
        mock.replies[SessionClient.Op.history] = ["ok": true, "open": false, "last_seq": 5, "lines": [Any]()]
        mock.streamLines = [["kind": "helper.watching", "open": [Any]()]]
        _ = m.client.watch()
        m.client.backfilling.wait()
        let s = m.states["ses_t"]!
        check(s.exited != nil && s.streamingMessage == nil && s.messages.last?.interrupted == true,
              "not in the helper's list: exited, the reply interrupted (\(String(describing: s.messages.last?.text)))")
        check(s.composerEnabled && !m.composer.replying, "the composer on")
        mock.requests = []
        m.selected = "ses_t"; m.draft = "还在吗"; m.submit()
        let ops = mock.requests.map { $0["op"] as? String ?? "" }
        check(ops.contains(SessionClient.Op.open) && sent(mock)?["text"] as? String == "还在吗", "a send opens it again and goes: \(ops)")
    }

    /// #107 review of aa232eb (bug 1): cloud turned off while a session is being opened. The open went out with the
    /// configuration; its reply is in after the switch: the client re-checks the model, sends set_config null before
    /// anything else, and the first words are not written (no say, no task, no turn on the cloud). The reverse: turned
    /// on while it opened without one — the configuration follows at once.
    static func modelOffMidOpenTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_n"], SessionClient.Op.send: ["ok": true]]
        let on = Locked(true)
        let m = ShellModel(client: SessionClient(transport: mock), defaults: scratchDefaults(), config: { "ds-flash" }, lang: { .zhHans },
                           cloudOn: { on.value }, work: { $0() }, deliver: { $0() })
        mock.onRequest = { op in if op == SessionClient.Op.open && on.value { on.value = false; m.settingsChanged() } }
        m.newConversation(); m.draft = "你好"; m.submit()
        mock.onRequest = nil
        let lines = mock.requests.compactMap { $0["line"] as? [String: Any] }
        check(mock.requests.first?["config"] as? String == "ds-flash", "(the open went out with the configuration)")
        check(lines.map { $0["type"] as? String ?? "" } == ["set_config"] && lines.first?["config"] is NSNull,
              "turned off mid-open: set_config null after the reply, no say: \(lines.map { $0["type"] ?? "" })")
        check(m.client.state("ses_n").outbox.first?.refused == "no_model", "the words: not sent (the cloud model is off)")
        // a reopen while the switch turns: the client's list has the session being opened (a reconcile reaches it)
        let c = SessionClient(transport: mock)
        c.adoptSettings(config: "ds-flash", lang: "zh")
        mock.requests = []
        c.modelOff = true
        mock.onRequest = { op in if op == SessionClient.Op.open { c.modelOff = false } }
        _ = c.open(sessionId: "ses_n", config: "ds-flash", lang: "zh")
        mock.onRequest = nil
        let back = mock.requests.compactMap { $0["line"] as? [String: Any] }
        check(mock.requests.first?["config"] == nil && back.first?["type"] as? String == "set_config" && back.first?["config"] as? String == "ds-flash",
              "turned on mid-open (opened with none): its configuration at once: \(back)")
        // (sync points, not sleeps — deskmind#112: the open is in the helper when its request arrives; done when it returns)
        let gate = DispatchSemaphore(value: 0), inOpen = DispatchSemaphore(value: 0), opened = DispatchSemaphore(value: 0)
        mock.onRequest = { op in if op == SessionClient.Op.open { inOpen.signal(); gate.wait() } }
        DispatchQueue.global().async { _ = c.open(sessionId: "ses_o", config: "ds-flash", lang: "zh"); opened.signal() }
        check(inOpen.wait(timeout: .now() + 10) == .success, "(the open reached the helper)")
        check(c.liveIds().contains("ses_o"), "a session being opened is in the client's list (a reconcile reaches it)")
        gate.signal()
        check(opened.wait(timeout: .now() + 10) == .success, "(the open returned)")
        c.reconciling.wait()
        mock.onRequest = nil
    }

    /// #107 review of aa232eb (bug 2): the helper restarted while a session had just started a task (its session.task
    /// stored while the watch was down). Back, the helper runs none: the exit is marked only after the stored lines are
    /// in, at the history's last seq — the task cut off, not running.
    static func exitAfterBackfillTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_t"],
                        SessionClient.Op.history: ["ok": true, "open": false, "last_seq": 7, "lines": [
                            ["kind": "session.task", "session_id": "ses_t", "seq": 7, "msg_id": "m9", "run_id": "r9", "raw": "整理桌面", "by": "slash"],
                            ["kind": "start", "session_id": "ses_t", "run_id": "r9", "seq": 1, "raw": "整理桌面"]]]]
        let c = SessionClient(transport: mock)
        _ = c.open(sessionId: "ses_t", config: "c", lang: "zh")
        for l in SessionTests.lines("chat") { c.feed(l) }
        mock.streamLines = [["kind": "helper.watching", "open": [Any]()]]
        _ = c.watch()
        c.backfilling.wait()
        let s = c.state("ses_t")
        check(s.task("r9") != nil && s.runningTask == nil && s.task("r9")?.cutOff == true && s.exited != nil,
              "the task its gone process had started: cut off, not running (\(String(describing: s.runningTask?.runId)))")
    }

    /// #107 review of aa232eb (E4): the "not stored" banner says what busy means (applied now, may not last), and
    /// clears once the session opens again with the settings now.
    static func settingsBannerTests() {
        check(ShellText.settingsRefused("busy", lang: .zhHans).contains("已生效") && ShellText.settingsRefused("bad_config", lang: .zhHans).contains("没接受"),
              "busy: applied now, may not last; bad_config: refused")
        let mock = Mock()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_t"], SessionClient.Op.send: ["ok": true]]
        let c = SessionClient(transport: mock)
        _ = c.open(sessionId: "ses_t", config: "c", lang: "zh")
        for l in SessionTests.lines("chat") { c.feed(l) }
        c.setConfig("ses_t", config: "c", lang: "zh")
        let cid = (mock.requests.last?["line"] as? [String: Any])?["client_id"] as? String ?? ""
        c.feed(["kind": "session.error", "session_id": "ses_t", "code": "bad_config", "control": "set_config", "client_id": cid, "text": "x"])
        check(c.state("ses_t").settingsRefused == "bad_config", "shown")
        c.feed(["kind": "helper.session_exit", "session_id": "ses_t", "code": 0, "idle": true])
        _ = c.open(sessionId: "ses_t", config: "c", lang: "zh")
        check(c.state("ses_t").settingsRefused == nil, "opened again with the settings now: cleared")
    }

    /// #107 review of aa232eb (E5): the cloud-off row follows the settings now: an exited session whose last stored
    /// settings had no model does not show it once cloud is on (its next process opens with them); a live one does.
    static func cloudOffRowNowTests() {
        let mock = Mock()
        let m = ShellModel(client: SessionClient(transport: mock), defaults: scratchDefaults(), config: { "c" }, lang: { .zhHans },
                           cloudOn: { true }, work: { $0() }, deliver: { $0() })
        for l in SessionTests.lines("chat") { m.client.feed(l) }
        m.client.feed(["kind": "session.config", "session_id": "ses_t", "seq": 7, "config": NSNull(), "lang": "zh", "by": "set_config"])
        m.refreshSettings()
        check(m.showsCloudOff(m.states["ses_t"]), "live, its process with no model: the row")
        m.client.feed(["kind": "helper.session_exit", "session_id": "ses_t", "code": 0, "idle": true])
        check(!m.showsCloudOff(m.states["ses_t"]), "exited, cloud on now: no row")
    }

    /// #107 review of aa232eb (E6): a new key asks for new processes whatever the switch says (turned on later, no
    /// session may run on the old key).
    static func keyChangeOffTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true], SessionClient.Op.end: ["ok": true, "deferred": true]]
        let m = ShellModel(client: SessionClient(transport: mock), defaults: scratchDefaults(), config: { "c" }, lang: { .zhHans },
                           cloudOn: { false }, work: { $0() }, deliver: { $0() })
        for l in SessionTests.lines("chat") { m.client.feed(l) }
        m.settingsChanged(keyChanged: true)
        check(mock.requests.contains { $0["op"] as? String == SessionClient.Op.end && $0["when_idle"] as? Bool == true },
              "a new key with cloud off: a new process asked for (when idle)")
    }

    /// Re-review of cb01397 (G1, the reviewer's probe): a set_config null that never arrived (no answer; not_open while
    /// the process runs) is not taken as applied — the next reconcile sends it again. And a configuration decided
    /// before the switch turned off goes as null (re-read under the session's lock).
    static func lostNullTests() {
        func nulls(_ m: Mock) -> Int {
            m.requests.compactMap { $0["line"] as? [String: Any] }.filter { $0["type"] as? String == "set_config" && $0["config"] is NSNull }.count
        }
        // no answer
        let mock = Mock()
        let c = SessionClient(transport: mock)
        c.adoptSettings(config: "ds-flash", lang: "zh"); c.modelOff = true
        mock.streamLines = [["kind": "helper.watching", "open": ["ses_a"]],
                            ["kind": "session.config", "session_id": "ses_a", "seq": 1, "config": "ds-flash", "lang": "zh", "by": "open"],
                            ["kind": "session.message", "session_id": "ses_a", "seq": 2, "msg_id": "u1", "role": "user", "text": "/cua x", "via": "cua"],
                            ["kind": "session.task", "session_id": "ses_a", "seq": 3, "msg_id": "u1", "run_id": "r1", "raw": "x", "by": "slash"]]
        _ = c.watch(); c.reconciling.wait()
        check(nulls(mock) >= 1, "a null was tried")
        mock.replies[SessionClient.Op.send] = ["ok": true]
        mock.requests = []
        mock.streamLines = [["kind": "helper.watching", "open": ["ses_a"]]]
        _ = c.watch(); c.reconciling.wait()
        c.reconcile(config: "ds-flash", lang: "zh", off: true)
        check(nulls(mock) >= 1, "no answer: not taken as applied, sent again (\(nulls(mock)))")
        // not_open while the watch says it runs
        let mock2 = Mock()
        mock2.replies = [SessionClient.Op.send: ["ok": false, "code": "not_open"]]
        let c2 = SessionClient(transport: mock2)
        c2.adoptSettings(config: "ds-flash", lang: "zh"); c2.modelOff = true
        mock2.streamLines = [["kind": "helper.watching", "open": ["ses_b"]],
                             ["kind": "session.config", "session_id": "ses_b", "seq": 1, "config": "ds-flash", "lang": "zh", "by": "open"]]
        _ = c2.watch(); c2.reconciling.wait()
        mock2.replies[SessionClient.Op.send] = ["ok": true]
        mock2.requests = []
        mock2.streamLines = [["kind": "helper.watching", "open": ["ses_b"]],
                             ["kind": "session.message", "session_id": "ses_b", "seq": 2, "msg_id": "a1", "role": "assistant", "text": "hi"]]
        _ = c2.watch(); c2.reconciling.wait()
        c2.reconcile(config: "ds-flash", lang: "zh", off: true)
        check(nulls(mock2) >= 1 && c2.state("ses_b").exited == nil, "not_open on a running process's null: sent again (\(nulls(mock2)))")
        // a configuration queued before the switch: null
        let mock3 = Mock()
        mock3.replies = [SessionClient.Op.send: ["ok": true]]
        let c3 = SessionClient(transport: mock3)
        c3.modelOff = true
        c3.setConfig("ses_c", config: "ds-flash", lang: "zh")
        check((mock3.requests.last?["line"] as? [String: Any])?["config"] is NSNull, "a configuration decided before the switch turned off: sent as null")
        // acked; a second reconcile (a trigger) may send again — sending is idempotent — but only null
        let cid = (mock3.requests.last?["line"] as? [String: Any])?["client_id"] as? String ?? ""
        c3.feed(["kind": "session.config", "session_id": "ses_c", "seq": 1, "config": NSNull(), "lang": "zh", "by": "set_config", "client_id": cid])
        mock3.requests = []
        c3.reconcile(config: "ds-flash", lang: "zh", off: true)
        check(!mock3.requests.contains { ($0["line"] as? [String: Any])?["config"] is String }, "acked: again at most null, never a configuration")
    }

    /// Re-review of cb01397: the helper's own answers. `busy_ending` (it is deciding whether the session ends, the process
    /// is there) is sent again, never read as an exit; `no_model` (the helper holds cloud models off, from another
    /// window or app) leaves the words the app's, not sent — and once cloud is on again they read plainly "not sent".
    static func helperRefusalTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true]]
        let on = Locked(true)
        let m = ShellModel(client: SessionClient(transport: mock), defaults: scratchDefaults(), config: { "c" }, lang: { .zhHans },
                           cloudOn: { on.value }, work: { $0() }, deliver: { $0() })
        for l in SessionTests.lines("chat") { m.client.feed(l) }
        m.client.reconciling.wait()          // (its first line converged it: that set_config answered first)
        mock.queued = [SessionClient.Op.send: [["ok": false, "code": "busy_ending"]]]
        m.selected = "ses_t"; m.draft = "你好"; m.submit()
        check(sends(mock) == 2 && m.states["ses_t"]?.exited == nil && m.states["ses_t"]?.outbox.first?.sending == true,
              "busy_ending: sent again, no exit (\(sends(mock)) sends)")
        mock.queued = [SessionClient.Op.send: [["ok": false, "code": "no_model", "control": "say"]]]
        m.draft = "在吗"; m.submit()
        let item = m.states["ses_t"]?.outbox.last
        check(item?.refused == "no_model" && item?.sending == false, "no_model from the helper: not sent, the app's")
        on.value = false; m.refreshSettings()
        check(m.unsentText(item?.refused) == "没发出去：云端模型关着", "while off: the cloud model is off")
        on.value = true; m.refreshSettings()
        check(m.unsentText(item?.refused) == ShellText.unsent(nil, lang: .zhHans), "on again: plainly not sent (\(m.unsentText(item?.refused)))")
        // a reopen with cloud off clears a "not stored" banner too
        let mock2 = Mock()
        mock2.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_t"], SessionClient.Op.send: ["ok": true]]
        let c = SessionClient(transport: mock2)
        for l in SessionTests.lines("chat") { c.feed(l) }
        c.setConfig("ses_t", config: "c", lang: "zh")
        let cid = (mock2.requests.last?["line"] as? [String: Any])?["client_id"] as? String ?? ""
        c.feed(["kind": "session.error", "session_id": "ses_t", "code": "bad_config", "control": "set_config", "client_id": cid, "text": "x"])
        c.feed(["kind": "helper.session_exit", "session_id": "ses_t", "code": 0, "idle": true])
        c.modelOff = true
        _ = c.open(sessionId: "ses_t", config: "c", lang: "zh")
        check(c.state("ses_t").settingsRefused == nil, "reopened with cloud off: the banner cleared")
    }

    /// Re-review of cb01397 (G2): the helper is told whether cloud models are off wherever the engine setting is
    /// written (either window) and when the app connects to it.
    static func modelsOffHookTests() {
        check(SessionClient.Request.modelsOff(true) as NSDictionary == ["op": "models.off", "off": true] as NSDictionary, "the op")
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sheet = (try? String(contentsOf: dir.appendingPathComponent("Main/CloudModel.swift"), encoding: .utf8)) ?? ""
        let setter = sheet.components(separatedBy: "static var engineIsCloud: Bool {").dropFirst().first?.components(separatedBy: "\n    }\n").first ?? ""
        check(setter.contains("forKey: \"engine\")") && setter.contains("ModelsOffSync.shared.push()"), "the engine setter tells the helper")
        let app = (try? String(contentsOf: dir.appendingPathComponent("Main/DeskMindApp.swift"), encoding: .utf8)) ?? ""
        check(app.contains("if self.connected && (!was ||") && app.contains("ModelsOffSync.shared.push()"), "connecting tells the helper")
        let mock = Mock()
        mock.replies = ["models.off": ["ok": true, "off": true]]
        check(SessionClient.setModelsOff(true, via: mock) && mock.requests.first?["off"] as? Bool == true, "sent to the helper")
    }

    /// Re-review of b0ff614 (bug): the helper holds cloud models off, the app's switch says on (a models.off lost).
    /// The client hears it (helper.watching's models_off, a no_model refusal), asserts its switch again, and once the
    /// helper has it reconciles every session — the one the helper nulled gets its configuration back.
    static func helperDisagreesTests() {
        // the helper as it is: holding models off, it refuses a configuration (no_model) until models.off false comes —
        // a set_config the client's reconcile sends before its own push lands is refused, never taken as applied (the
        // client then pushes and reconciles again). A mock that took it made this test depend on the order the two
        // threads ran in (a flake under load at c2997ba).
        final class OffHelper: SessionTransport {
            let inner = Mock()
            private let lock = NSLock()
            private var off = true
            func request(_ body: [String: Any]) -> [String: Any]? {
                let op = body["op"] as? String ?? ""
                lock.lock()
                if op == "models.off" { off = body["off"] as? Bool ?? off }
                let refuse = off && op == SessionClient.Op.send && (body["line"] as? [String: Any])?["type"] as? String == "set_config"
                    && !((body["line"] as? [String: Any])?["config"] is NSNull)
                lock.unlock()
                let r = inner.request(body)
                return refuse ? ["ok": false, "code": "no_model", "control": "set_config"] : r
            }
            func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool {
                inner.stream(body, onLine: onLine, onIdle: onIdle)
            }
        }
        let helper = OffHelper()
        let mock = helper.inner
        mock.replies = [SessionClient.Op.send: ["ok": true], "models.off": ["ok": true, "off": false]]
        let steps = Steps()                 // (the client's reconciles and pushes: run here, in turn — deskmind#112)
        let c = steps.client(helper)
        c.adoptSettings(config: "ds-flash", lang: "zh")
        mock.streamLines = [["kind": "helper.watching", "open": ["ses_k"], "models_off": true],
                            ["kind": "session.config", "session_id": "ses_k", "seq": 1, "config": NSNull(), "lang": "zh", "by": "set_config"]]
        _ = c.watch()
        // (until the helper has the switch and the session its configuration: the refused one is repaired by a push and a
        // reconcile of its own)
        c.backfilling.wait()
        check(steps.drain() && !c.modelsSync.isPending, "(the switch pushed and acked, every reconcile run)")
        let ops = mock.requests.map { r -> String in
            let t = (r["line"] as? [String: Any])?["type"] as? String
            return (r["op"] as? String ?? "") + (t.map { ":" + $0 } ?? "")
        }
        let off = mock.requests.first { $0["op"] as? String == "models.off" }
        let cfg = mock.requests.compactMap { $0["line"] as? [String: Any] }.last { $0["type"] as? String == "set_config" }
        check(off?["off"] as? Bool == false && cfg?["config"] as? String == "ds-flash"
              && (mock.requests.firstIndex { $0["op"] as? String == "models.off" } ?? Int.max) < (mock.requests.lastIndex { ($0["line"] as? [String: Any])?["type"] as? String == "set_config" } ?? -1),
              "the helper off, the app on: models.off false asserted, then the nulled session gets its configuration: \(ops)")
        // a no_model refusal while the app is on says the same
        let mock2 = Mock()
        mock2.replies = [SessionClient.Op.send: ["ok": false, "code": "no_model", "control": "say"], "models.off": ["ok": true, "off": false]]
        let c2 = SessionClient(transport: mock2)
        for l in SessionTests.lines("chat") { c2.feed(l) }
        _ = c2.send(.say("你好"), to: "ses_t")
        c2.modelsSync.settle()
        check(mock2.requests.contains { $0["op"] as? String == "models.off" && $0["off"] as? Bool == false }, "a no_model with the app on: the switch asserted again")
    }

    /// Re-review of b0ff614: assertions reach the helper in order (two quick toggles), and one not acked is sent again
    /// until it is (a newer one supersedes it).
    static func modelsOffSyncTests() {
        final class Flaky: SessionTransport {
            let lock = NSLock()
            var seen: [Bool] = []
            var failFirst = 2
            var onSend: ((Bool) -> Void)?
            func request(_ body: [String: Any]) -> [String: Any]? {
                lock.lock()
                seen.append(body["off"] as? Bool ?? false)
                let fail = failFirst > 0
                if fail { failFirst -= 1 }
                let hook = onSend
                lock.unlock()
                hook?(body["off"] as? Bool ?? false)
                return fail ? nil : ["ok": true, "off": body["off"] ?? false]
            }
            func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool { false }
        }
        let t = Flaky()
        let box = NSLock()
        var switchOff = false
        let sync = ModelsOffSync(transport: t, current: { box.lock(); defer { box.unlock() }; return switchOff })
        sync.firstDelay = 0.01
        let acked = DispatchSemaphore(value: 0)
        sync.push { acked.signal() }
        check(acked.wait(timeout: .now() + 3) == .success, "not acked twice: sent again until it is (\(t.seen))")
        // (A) a retry still scheduled while the switch turns: it sends the switch as it is then, never the old value. Its
        // sends are this test's steps (deskmind#112: a 50 ms sleep stood for "its first try failed")
        t.lock.lock(); t.seen = []; t.failFirst = 1; t.lock.unlock()
        let steps = Steps()
        sync.work = steps.lane("off")
        sync.push()
        steps.run("off")                                     // its first try failed; its retry waits
        check(steps.count("off") == 1 && sync.isPending, "(A: the first try failed, its retry queued)")
        box.lock(); switchOff = true; box.unlock()           // the switch turned off meanwhile (another window, say)
        sync.settle()
        t.lock.lock(); let seen = t.seen; t.lock.unlock()
        check(seen.last == true, "a retry sends the switch as it is when it goes (\(seen))")
        // the switch moving while a send is out: sent again with the new one
        t.lock.lock(); t.seen = []; t.onSend = { _ in box.lock(); switchOff = false; box.unlock(); t.onSend = nil }; t.lock.unlock()
        sync.push(); sync.settle()
        t.lock.lock(); let seen2 = t.seen; t.lock.unlock()
        check(seen2.last == false, "moved while it went: sent again (\(seen2))")
    }

    /// Re-review of 62ff17a (bug 1, B): the reconcile after the helper's ack reads the switch as it is then — turned off
    /// while models.off went, the nulled session stays null, never a configuration pushed after it. And one sync per app:
    /// the client takes the one it is given.
    static func oneOwnerTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true], "models.off": ["ok": true]]
        let box = NSLock()
        var engineOff = false                                // the engine setting: where the sync and the client read it
        let shared = ModelsOffSync(transport: mock, current: { box.lock(); defer { box.unlock() }; return engineOff })
        let c = SessionClient(transport: mock, modelsSync: shared)
        check(c.modelsSync === shared, "the client uses the app's one sync, as given")
        c.adoptSettings(config: "ds-flash", lang: "zh")
        mock.onRequest = { op in if op == "models.off" { box.lock(); engineOff = true; box.unlock() } }      // the switch turns off as it goes
        mock.streamLines = [["kind": "helper.watching", "open": ["ses_k"], "models_off": true],
                            ["kind": "session.config", "session_id": "ses_k", "seq": 1, "config": NSNull(), "lang": "zh", "by": "set_config"]]
        _ = c.watch()
        shared.settle(); c.reconciling.wait()
        mock.onRequest = nil
        // (after the switch went off — with the first models.off — not before: the watch's own reconcile may send the
        // configuration while the switch is still on; which comes first depends on the threads, a flake under load)
        let all = mock.requests
        let offAt = all.firstIndex { $0["op"] as? String == "models.off" } ?? all.count
        let configs = all[offAt...].compactMap { $0["line"] as? [String: Any] }.filter { $0["type"] as? String == "set_config" }
        check(offAt < all.count && !configs.contains { $0["config"] as? String == "ds-flash" },
              "no configuration after the switch went off: \(configs.map { $0["config"] ?? "" })")
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let main = (try? String(contentsOf: dir.appendingPathComponent("Main/MainSplitView.swift"), encoding: .utf8)) ?? ""
        let client = (try? String(contentsOf: dir.appendingPathComponent("Shared/SessionClient.swift"), encoding: .utf8)) ?? ""
        check(main.contains("SessionClient(transport: transport, modelsSync: .shared)") && !client.contains("is HelperSessionTransport ?"),
              "the shell's client is given the app's sync; never chosen by the transport's type")
    }

    /// Re-review of c6bc196 (E2, the reviewer's PingPong): cloud turned off in the sheet with a session running. The
    /// engine setting changes at once; the window's settings catch up only when the sheet closes. With one source of
    /// truth (the client reads the switch where the sync reads it) nothing ping-pongs meanwhile: one models.off, no
    /// configuration sent to be refused.
    static func pingPongTests() {
        final class FakeHelper: SessionTransport {
            let lock = NSLock()
            var off = false
            var counts: [String: Int] = [:]
            weak var client: SessionClient?
            private var seq = 100
            func request(_ body: [String: Any]) -> [String: Any]? {
                let op = body["op"] as? String ?? ""
                lock.lock()
                var key = op
                if op == "session.send", let l = body["line"] as? [String: Any] { key += ":" + (l["type"] as? String ?? "") + (l["config"] is NSNull ? "(null)" : "(cfg)") }
                counts[key, default: 0] += 1
                if op == "models.off" { off = body["off"] as? Bool ?? false }
                let isOff = off
                seq += 1
                let n = seq
                lock.unlock()
                if op == "models.off" {
                    // the helper nulls the running session: it stores and streams session.config null
                    if isOff { DispatchQueue.global().async { [weak self] in self?.client?.feed(["kind": "session.config", "session_id": "ses_t", "seq": n, "config": NSNull(), "lang": "zh", "by": "set_config"]) } }
                    return ["ok": true, "off": isOff, "persisted": true]
                }
                if op == "session.send", let l = body["line"] as? [String: Any], l["type"] as? String == "set_config", isOff, !(l["config"] is NSNull) {
                    return ["ok": false, "code": "no_model", "control": "set_config", "error": "cloud models are off"]
                }
                return ["ok": true]
            }
            func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool { false }
        }
        let helper = FakeHelper()
        let box = NSLock()
        var engineOff = false
        let sync = ModelsOffSync(transport: helper, current: { box.lock(); defer { box.unlock() }; return engineOff })
        let c = SessionClient(transport: helper, modelsSync: sync)
        helper.client = c
        c.adoptSettings(config: "ds-flash", lang: "zh")
        c.feed(["t": 1, "session_id": "ses_t", "kind": "session.start", "protocol": ["session": 1], "last_seq": 0, "resumed": false])
        c.reconciling.wait()
        _ = helper.request(["op": "models.off", "off": false])
        helper.lock.lock(); helper.counts = [:]; helper.lock.unlock()
        box.lock(); engineOff = true; box.unlock()             // the sheet saves "off": the engine setter pushes
        sync.push()
        Thread.sleep(forTimeInterval: 0.3)                     // the sheet not closed yet
        helper.lock.lock(); let during = helper.counts; helper.lock.unlock()
        c.modelOff = true                                      // its onDismiss: the window's settings catch up
        Thread.sleep(forTimeInterval: 0.5)
        c.reconciling.wait()
        helper.lock.lock(); let after = helper.counts; helper.lock.unlock()
        check(during["models.off", default: 0] == 1 && during["session.send:set_config(cfg)", default: 0] == 0,
              "the switch flipped with a session running: one models.off, no configuration refused (\(during.sorted { $0.key < $1.key }))")
        check(after["models.off", default: 0] == 1 && after["session.send:set_config(cfg)", default: 0] == 0, "and none after (\(after.sorted { $0.key < $1.key }))")
    }

    /// Re-review of c6bc196 (E7): an open that waits for the helper to take the switch says so meanwhile.
    static func waitingForHelperTests() {
        final class Slow: SessionTransport {
            let release = DispatchSemaphore(value: 0)
            func request(_ body: [String: Any]) -> [String: Any]? {
                if body["op"] as? String == "models.off" { _ = release.wait(timeout: .now() + 2); return ["ok": true] }
                if body["op"] as? String == SessionClient.Op.open { return ["ok": true, "session_id": "ses_w"] }
                return ["ok": true]
            }
            func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool { false }
        }
        let t = Slow()
        let sync = ModelsOffSync(transport: t, current: { false })
        var seen: [Bool] = []
        let seenLock = NSLock()
        let m = ShellModel(client: SessionClient(transport: t, modelsSync: sync), defaults: scratchDefaults(), config: { "c" }, lang: { .zhHans },
                           work: { $0() }, deliver: { f in seenLock.lock(); f(); seenLock.unlock() })
        sync.push()
        // (the watcher reads the flag under the lock `deliver` sets it under, keeps `seen` under it, and always ends)
        let watched = DispatchSemaphore(value: 0)
        let watch = Thread {
            var last = false
            let until = Date().addingTimeInterval(5)
            while Date() < until {
                seenLock.lock()
                let w = m.waitingForHelper
                if w != last { seen.append(w); last = w }
                let n = seen.count
                seenLock.unlock()
                if n >= 2 { break }
                usleep(1_000)
            }
            watched.signal()
        }
        watch.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { t.release.signal() }
        _ = m.client.open(sessionId: "ses_w", config: "c", lang: "zh")
        watched.wait()
        seenLock.lock(); let saw = seen, now = m.waitingForHelper; seenLock.unlock()
        check(saw.first == true && !now, "the open said it waited for the helper, then stopped saying so (\(saw))")
    }

    /// Re-review of 62ff17a (effect 3): a session the helper nulled while the switch is on (unseen as a mismatch here), or
    /// a no_model in the stream, is repaired — reconciled to the switch.
    static func nulledRepairTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true], "models.off": ["ok": true]]
        let c = SessionClient(transport: mock)
        c.adoptSettings(config: "ds-flash", lang: "zh")
        for l in SessionTests.lines("chat") { c.feed(l) }
        c.reconciling.wait()
        mock.requests = []
        c.feed(["kind": "session.config", "session_id": "ses_t", "seq": 7, "config": NSNull(), "lang": "zh", "by": "set_config"])
        c.reconciling.wait()
        check(mock.requests.compactMap { $0["line"] as? [String: Any] }.contains { $0["config"] as? String == "ds-flash" },
              "nulled with the switch on: its configuration sent back")
        mock.requests = []
        c.feed(["kind": "session.error", "session_id": "ses_t", "code": "no_model", "control": "say", "text": "x"])
        c.reconciling.wait(); c.modelsSync.settle(); c.reconciling.wait()     // (the ack's converge too)
        check(mock.requests.contains { $0["op"] as? String == "models.off" }, "a no_model in the stream with the switch on: the helper told again")
        // the echo of a refused set_config is not a new one (no loop)
        mock.requests = []
        c.feed(["kind": "session.error", "session_id": "ses_t", "code": "no_model", "control": "set_config", "text": "x"])
        c.reconciling.wait()
        check(mock.requests.isEmpty, "a refused set_config's echo: nothing")
    }

    /// Re-review of 62ff17a (bug 2): while cloud is off an old-window run's card takes only the way out and undo.
    static func runAnswerGateTests() {
        var st = HarnessEvents.State()
        st.askID = "a1"
        st.askOptions = [["kind": "approve", "text": "可以"], ["kind": "value", "text": "红"], ["kind": "cancel", "text": "先别做了"], ["kind": "undo", "text": "撤销"]]
        typealias B = HarnessEvents.CardButton
        check(HarnessEvents.needsNoModel(.deny, state: st) && HarnessEvents.needsNoModel(.option(2, "先别做了"), state: st)
              && HarnessEvents.needsNoModel(.option(3, "撤销"), state: st), "the way out and undo need no model")
        check(!HarnessEvents.needsNoModel(.approve, state: st) && !HarnessEvents.needsNoModel(.option(1, "红"), state: st)
              && !HarnessEvents.needsNoModel(.words("蓝"), state: st), "approve, a pick and words do")
        // Deny is classified by what it resolves to: on a card with no cancel, its first option that is not approve —
        // here a pick, which lets the run go on (#107 re-review of c6bc196)
        var picks = HarnessEvents.State()
        picks.askID = "a2"
        picks.askOptions = [["kind": "approve", "text": "可以"], ["kind": "value", "text": "红"]]
        check(!HarnessEvents.needsNoModel(.deny, state: picks), "Deny that resolves to a pick needs the model")
        var only = HarnessEvents.State()
        only.askID = "a3"
        only.askOptions = [["kind": "approve", "text": "可以"]]
        check(HarnessEvents.needsNoModel(.deny, state: only), "Deny on an approve-only card (answered with nothing: no) needs none")
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let run = (try? String(contentsOf: dir.appendingPathComponent("Helper/HarnessRun.swift"), encoding: .utf8)) ?? ""
        check(run.contains("if SessionHost.modelsOffNow && !HarnessEvents.needsNoModel(button, state: state)") && run.contains("static func stopForModelsOff()"),
              "the helper's answer gate and its stop for models off")
        let helper = (try? String(contentsOf: dir.appendingPathComponent("Helper/HandsHelper.swift"), encoding: .utf8)) ?? ""
        let main = helper.components(separatedBy: "static func main() {").dropFirst().first?.prefix(400) ?? ""
        check(main.contains("SessionHost.onModelsOff = { HarnessRun.stopForModelsOff() }"), "set when the helper starts")
    }

    /// Re-review of b0ff614 (effects): a set_config sent to a process that is gone is not "under way" (its start or exit
    /// clears it), and "under way" compares the language too.
    static func pendingConfigTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true]]
        let c = SessionClient(transport: mock)
        for l in SessionTests.lines("chat") { c.feed(l) }
        c.reconciling.wait()
        c.modelOff = true
        c.setConfig("ses_t", config: nil, lang: "zh")                       // sent, never answered: its process goes
        c.feed(["kind": "helper.session_exit", "session_id": "ses_t", "code": 1])
        mock.requests = []
        c.feed(["kind": "session.start", "session_id": "ses_t", "resumed": true, "last_seq": 6])
        c.reconciling.wait()
        c.reconcile(config: "ds-flash", lang: "zh", off: true)
        check(mock.requests.contains { ($0["line"] as? [String: Any])?["config"] is NSNull }, "a new process: its null sent (the old one's pending cleared)")
        // the language too
        let mock2 = Mock()
        mock2.replies = [SessionClient.Op.send: ["ok": true]]
        let c2 = SessionClient(transport: mock2)
        for l in SessionTests.lines("chat") { c2.feed(l) }
        c2.reconciling.wait()
        c2.setConfig("ses_t", config: "ds-flash", lang: "zh")
        mock2.requests = []
        c2.reconcile(config: "ds-flash", lang: "en", off: false)
        check((mock2.requests.last?["line"] as? [String: Any])?["lang"] as? String == "en", "a set_config under way in zh does not hide one in en")
    }

    /// Re-review of b0ff614 (effect): a bad_config that arrives while the open's own set_config is out stays shown (the
    /// banner is cleared before it goes, not after).
    static func openBannerTests() {
        final class T: SessionTransport {
            weak var client: SessionClient?
            func request(_ body: [String: Any]) -> [String: Any]? {
                if body["op"] as? String == SessionClient.Op.open { return ["ok": true, "session_id": "ses_t"] }
                if let l = body["line"] as? [String: Any], l["type"] as? String == "set_config", let cid = l["client_id"] as? String {
                    client?.feed(["kind": "session.error", "session_id": "ses_t", "code": "bad_config", "control": "set_config", "client_id": cid, "text": "x"])
                }
                return ["ok": true]
            }
            func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool { false }
        }
        let t = T()
        let c = SessionClient(transport: t)
        t.client = c
        c.modelOff = true
        _ = c.open(sessionId: "ses_t", config: "ds-flash", lang: "zh")
        check(c.state("ses_t").settingsRefused == "bad_config", "refused during the open: still shown (\(String(describing: c.state("ses_t").settingsRefused)))")
    }

    /// Re-review of b0ff614 (effect): the helper's no_model after the not_open reopen path shows as no_model.
    static func reopenNoModelTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_t"], SessionClient.Op.send: ["ok": false, "code": "no_model", "control": "say"],
                        "models.off": ["ok": true, "off": false]]
        mock.queued = [SessionClient.Op.send: [["ok": false, "code": "not_open"]]]
        let c = SessionClient(transport: mock)
        for l in SessionTests.lines("chat") { c.feed(l) }
        c.reconciling.wait()
        _ = c.send(.say("你好"), to: "ses_t")
        check(c.state("ses_t").outbox.last?.refused == "no_model", "reopened, then no_model: shown as no_model (\(String(describing: c.state("ses_t").outbox.last?.refused)))")
    }

    /// Re-review of b0ff614: the engine setter asserts through the ordered sync; the app asserts when the helper's
    /// status disagrees. (The old window's run screen, which said a no_model refusal, went with A10.)
    static func oldWindowRunTests() {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sheet = (try? String(contentsOf: dir.appendingPathComponent("Main/CloudModel.swift"), encoding: .utf8)) ?? ""
        check(sheet.contains("ModelsOffSync.shared.push()"), "the engine setter pushes through the app's one sync")
        let app = (try? String(contentsOf: dir.appendingPathComponent("Main/DeskMindApp.swift"), encoding: .utf8)) ?? ""
        check(app.contains("reply?[\"models_off\"]") && app.contains("ModelsOffSync.shared.push()"), "the helper's status disagreeing: pushed again")
    }

    /// External review of 473fdac (P1): the app starts with cloud off while the helper runs a session whose task runs.
    /// The start's reconcile finds nothing; the session comes into view later (the watch's running list, its lines):
    /// it is reconciled then — set_config null before any other control of the app's, Stop after it.
    static func restartCloudOffTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true]]
        let m = ShellModel(client: SessionClient(transport: mock), defaults: scratchDefaults(), config: { "ds-flash" }, lang: { .zhHans },
                           cloudOn: { false }, work: { $0() }, deliver: { $0() })
        m.client.reconciling.wait()
        check(mock.requests.isEmpty, "(the start: nothing known yet, nothing sent)")
        mock.streamLines = [["kind": "helper.watching", "open": ["ses_k"]],
                            ["kind": "session.message", "session_id": "ses_k", "seq": 1, "msg_id": "u1", "role": "user", "text": "/cua 整理桌面", "via": "cua"],
                            ["kind": "session.task", "session_id": "ses_k", "seq": 2, "msg_id": "u1", "run_id": "r1", "raw": "整理桌面", "by": "slash"],
                            ["kind": "start", "session_id": "ses_k", "run_id": "r1", "seq": 1, "raw": "整理桌面"]]
        _ = m.client.watch()
        m.client.reconciling.wait()
        m.selected = "ses_k"
        check(m.states["ses_k"]?.runningTask?.runId == "r1", "its task runs")
        m.stop()
        let lines = mock.requests.compactMap { $0["line"] as? [String: Any] }
        let types = lines.map { $0["type"] as? String ?? "" }
        check(types.first == "set_config" && lines.first?["config"] is NSNull && types.contains("stop")
              && !types.contains { ["say", "cua", "retry", "steer", "queue_send_now"].contains($0) },
              "found running with cloud off: set_config null first, then Stop, nothing that needs the model: \(types)")
        // the same running list again (a trigger): sent again at most as null — sending is idempotent — never a configuration
        mock.requests = []
        mock.streamLines = [["kind": "helper.watching", "open": ["ses_k"]]]
        _ = m.client.watch()
        m.client.reconciling.wait()
        check(!mock.requests.contains { ($0["line"] as? [String: Any])?["config"] is String }, "idempotent: no configuration while off")
    }

    /// External review of 473fdac (P2): a reconnect's backfill reads a session's log; meanwhile the user reopens it and
    /// starts a task. The backfill's exit is not marked for that new process (the history says one runs; an open came
    /// since): the task runs, Stop is there.
    static func backfillReopenTests() {
        final class T: SessionTransport {
            let lock = NSLock()
            var requests: [[String: Any]] = []
            let release = DispatchSemaphore(value: 0), inHistory = DispatchSemaphore(value: 0)
            var lines: [[String: Any]] = []
            func request(_ body: [String: Any]) -> [String: Any]? {
                lock.lock(); requests.append(body); lock.unlock()
                switch body["op"] as? String {
                case SessionClient.Op.history?: inHistory.signal(); release.wait(); return ["ok": true, "open": true, "last_seq": 7, "lines": [Any]()]
                case SessionClient.Op.open?: return ["ok": true, "session_id": "ses_t", "resumed": true, "last_seq": 6]
                default: return ["ok": true]
                }
            }
            func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool {
                for l in lines where !onLine(l) { return true }
                return true
            }
        }
        let t = T()
        let m = ShellModel(client: SessionClient(transport: t), defaults: scratchDefaults(), config: { "c" }, lang: { .zhHans },
                           work: { $0() }, deliver: { $0() })
        _ = m.client.open(sessionId: "ses_t", config: "c", lang: "zh")
        for l in SessionTests.lines("chat") { m.client.feed(l) }
        t.lines = [["kind": "helper.watching", "open": [Any]()]]
        _ = m.client.watch()                                   // the backfill starts, and blocks in its read
        t.inHistory.wait()
        // meanwhile: opened again, a task started
        _ = m.client.open(sessionId: "ses_t", config: "c", lang: "zh")
        m.client.feed(["kind": "session.start", "session_id": "ses_t", "resumed": true, "last_seq": 6])
        m.client.feed(["kind": "session.task", "session_id": "ses_t", "seq": 7, "msg_id": "m9", "run_id": "r10", "raw": "整理桌面", "by": "slash"])
        m.client.feed(["kind": "start", "session_id": "ses_t", "run_id": "r10", "seq": 1, "raw": "整理桌面"])
        t.release.signal()
        m.client.backfilling.wait()
        m.selected = "ses_t"
        let s = m.states["ses_t"]!
        check(s.exited == nil && s.runningTask?.runId == "r10" && m.composer.canStop,
              "the new process's task runs, Stop is there (exited \(String(describing: s.exited)), running \(String(describing: s.runningTask?.runId)))")
    }

    /// #107 review of aa232eb (E7): a busy set_config is sent again with the settings as they are now, not as that line
    /// had them.
    static func configRetryLatestTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true]]
        let steps = Steps()                                  // (its reconciles: run before the check, deskmind#112)
        let c = steps.client(mock)
        c.adoptSettings(config: "openai:deepseek|a", lang: "zh")
        for l in SessionTests.lines("chat") { c.feed(l) }
        steps.drain(); mock.requests = []
        c.setConfig("ses_t", config: "openai:deepseek|a", lang: "zh")
        let first = (mock.requests.last?["line"] as? [String: Any])?["client_id"] as? String ?? ""
        c.adoptSettings(config: "openai:deepseek|b", lang: "en")      // saved since: the store has b
        c.setConfig("ses_t", config: "openai:deepseek|b", lang: "en")
        c.feed(["kind": "session.error", "session_id": "ses_t", "code": "busy", "control": "set_config", "client_id": first, "text": "x"])
        func configs() -> [[String: Any]] { mock.requests.compactMap { $0["line"] as? [String: Any] }.filter { $0["type"] as? String == "set_config" } }
        steps.drain()
        check(configs().count == 3 && configs().last?["config"] as? String == "openai:deepseek|b" && configs().last?["lang"] as? String == "en",
              "the retry carries the latest settings: \(configs().map { $0["config"] ?? "" })")
    }

    /// #107 external review (P2 2): the language is a session setting like the model's: one value for both. A switch
    /// reaches every session's next process (as a key does), whatever was remembered for it before.
    static func languageTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_x"], SessionClient.Op.send: ["ok": true],
                        SessionClient.Op.end: ["ok": true, "deferred": true]]
        let config = Locked("provider-a"), lang = Locked(ResolvedLang.zhHans)   // (read on the reconcile queue: locked, deskmind#112)
        let m = ShellModel(client: SessionClient(transport: mock), defaults: scratchDefaults(), config: { config.value }, lang: { lang.value },
                           work: { $0() }, deliver: { $0() })
        m.newConversation(); m.draft = "你好"; m.submit()
        m.client.feed(["kind": "session.start", "session_id": "ses_x", "resumed": false, "last_seq": 0])
        m.client.reconciling.wait()             // (the reconcile its start sets off, done before the settings move)
        config.value = "provider-b"
        m.settingsChanged()                     // remembered for ses_x: provider-b, zh
        lang.value = .en
        m.applySettings()                       // what the window as it was did on a language switch
        m.client.feed(["kind": "helper.session_exit", "session_id": "ses_x", "code": 0, "idle": true])
        mock.requests = []
        m.selected = "ses_x"; m.draft = "again"; m.submit()
        let reopen = mock.requests.first { $0["op"] as? String == SessionClient.Op.open }
        check(reopen?["lang"] as? String == "en" && reopen?["config"] as? String == "provider-b",
              "after a language switch, the reclaimed session reopens in it: \(String(describing: reopen?["lang"])) \(String(describing: reopen?["config"]))")
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let main = (try? String(contentsOf: dir.appendingPathComponent("Main/MainSplitView.swift"), encoding: .utf8)) ?? ""
        check(main.contains(".onChange(of: lang) { _, _ in shell.syncSettings() }"),
              "the window: a language switch goes the settings' way (the language is in the shell's settings print)")
    }

    /// #107 review (item 3): reading a session needs no process — its history from the helper's stored log.
    static func historyTests() {
        let mock = Mock()
        let stored = SessionTests.raw("chat").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }.filter { $0["seq"] != nil }
        mock.replies = [SessionClient.Op.history: ["ok": true, "open": false, "last_seq": stored.compactMap { $0["seq"] as? Int }.max() ?? 0, "lines": stored]]
        let m = model(mock)
        m.select("ses_t")
        check(mock.requests.map { $0["op"] as? String ?? "" } == [SessionClient.Op.history], "opened to read: history only, no process: \(mock.requests.map { $0["op"] ?? "" })")
        check(m.states["ses_t"]?.messages.isEmpty == false && m.states["ses_t"]?.exited != nil, "its messages are here; it reads as not running")
        mock.requests = []
        mock.replies[SessionClient.Op.history] = ["ok": true, "open": false, "last_seq": 6, "lines": [Any]()]
        m.select("ses_t")
        check(mock.requests.map { $0["op"] as? String ?? "" } == [SessionClient.Op.history] && mock.requests.first?["after_seq"] as? Int == 6,
              "known: opened again, what came after its cursor read (never the cache as whole), no process: \(mock.requests)")
        // an older helper without the op: opened (the reclaim closes it once idle)
        let old = Mock()
        old.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_o"]]
        let o = model(old)
        o.select("ses_o")
        check(old.requests.filter { !(($0["line"] as? [String: Any])?["type"] as? String == "set_config") }.map { $0["op"] as? String ?? "" }
              == [SessionClient.Op.history, SessionClient.Op.open], "no history op: opened instead")
        // a task left running by a process that is gone: interrupted, not running, not done
        let cut = Mock()
        cut.replies = [SessionClient.Op.history: ["ok": true, "open": false, "last_seq": 3, "lines": [
            ["kind": "session.message", "session_id": "ses_k", "seq": 1, "msg_id": "u1", "role": "user", "text": "整理桌面"],
            ["kind": "session.message", "session_id": "ses_k", "seq": 2, "msg_id": "m1", "role": "assistant", "text": "好的", "reply_to": "u1"],
            ["kind": "session.task", "session_id": "ses_k", "seq": 3, "msg_id": "m1", "run_id": "r1", "raw": "整理桌面", "by": "model"],
            ["kind": "start", "session_id": "ses_k", "run_id": "r1", "seq": 1, "raw": "整理桌面"]]]]
        let k = model(cut)
        k.client.feed(["kind": "session.message", "session_id": "ses_z", "seq": 1, "msg_id": "x", "role": "user", "text": "x"])
        _ = k.client.history("ses_k")
        let ks = k.client.state("ses_k")
        check(ks.runningTask == nil && ks.status == .error("interrupted"), "a task its gone process left: interrupted (\(ks.status))")
    }

    /// The helper as the key rounds see it (sessions.list's digests, session.end when_idle, session.open), with the
    /// file's digest read from the test's key file: a process records the digest at its start, as SessionHost.spawn
    /// does. `failEnd`: the next N asks of a session unanswered; `refuseEnd`: answered with an error; `failList`: the
    /// next N lists unanswered; `busy`: sessions whose ask is deferred (ending at their next idle moment); `old`: a
    /// helper that says no digests; `starting`: processes spawned (their keys read) whose session.start has not come
    /// (listed `starting`, not `open`; an end finds them not open, as SessionHost.end does).
    final class FakeHelper: SessionTransport {
        let lock = NSLock()
        var key: String
        var procs: [String: (keys: String, ending: Bool)] = [:]
        var requests: [[String: Any]] = []
        var failEnd: [String: Int] = [:], refuseEnd: [String: Int] = [:]
        var failList = 0
        var busy: Set<String> = []
        var starting: Set<String> = []
        /// Being spawned, its keys not read yet: listed `starting` with no digest, `new` (no stored history).
        var unread: Set<String> = []
        /// Started, nothing stored yet: in the process table, not in the stored list.
        var unstored: Set<String> = []
        var old = false
        init(key: String, running: [String] = []) {
            self.key = key
            for id in running { procs[id] = (ModelKeys.digest(key), false) }
        }
        var now: String { ModelKeys.digest(key) }
        func spawn(_ id: String, started: Bool = true) {
            lock.lock(); procs[id] = (now, false); if !started { starting.insert(id) }; lock.unlock()
        }
        func start(_ id: String) { lock.lock(); starting.remove(id); lock.unlock() }
        /// A spawn listed before its read of the keys (SessionHost.spawning), then that one read (the file then).
        func spawnUnread(_ id: String) { lock.lock(); procs[id] = ("", false); starting.insert(id); unread.insert(id); lock.unlock() }
        func readKeys(_ id: String) { lock.lock(); procs[id] = (now, false); unread.remove(id); lock.unlock() }
        /// A busy session goes idle: the helper ends it if a restart was asked.
        func idle(_ id: String) { lock.lock(); busy.remove(id); if procs[id]?.ending == true { procs[id] = nil }; lock.unlock() }
        func request(_ body: [String: Any]) -> [String: Any]? {
            lock.lock(); defer { lock.unlock() }
            requests.append(body)
            let op = body["op"] as? String ?? "", id = body["session_id"] as? String ?? ""
            switch op {
            case SessionClient.Op.list:
                if failList > 0 { failList -= 1; return nil }
                // the stored list (rows): processes whose session has something stored; an older helper says `open` only
                let stored = procs.keys.filter { !unread.contains($0) && !unstored.contains($0) }.sorted()
                var r: [String: Any] = ["ok": true, "sessions": stored.map { id -> [String: Any] in
                    var i: [String: Any] = ["session_id": id, "title": "", "open": !starting.contains(id), "ending": procs[id]!.ending]
                    if starting.contains(id) { i["starting"] = true }
                    if !old { i["keys"] = procs[id]!.keys }
                    return i
                }]
                if !old {
                    r["keys"] = now
                    // the helper's own process table: every process, stored or not, its digest once read
                    r["processes"] = procs.keys.sorted().map { id -> [String: Any] in
                        var p: [String: Any] = ["session_id": id, "open": !starting.contains(id), "ending": procs[id]!.ending]
                        if starting.contains(id) { p["starting"] = true }
                        if !unread.contains(id) { p["keys"] = procs[id]!.keys }
                        return p
                    }
                }
                return r
            case SessionClient.Op.end:
                if let n = failEnd[id], n > 0 { failEnd[id] = n - 1; return nil }
                if let n = refuseEnd[id], n > 0 { refuseEnd[id] = n - 1; return ["ok": false, "code": "bad_request", "error": "x"] }
                guard procs[id] != nil, !starting.contains(id) else { return ["ok": false, "code": "not_open"] }
                if busy.contains(id) { procs[id]!.ending = true; return ["ok": true, "deferred": true] }
                procs[id] = nil
                return ["ok": true]
            case SessionClient.Op.open:
                let sid = id.isEmpty ? "ses_new" : id
                procs[sid] = (now, false)
                return ["ok": true, "session_id": sid]
            default:
                return ["ok": true]
            }
        }
        func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool { false }
        func ends() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return requests.filter { $0["op"] as? String == SessionClient.Op.end && $0["when_idle"] as? Bool == true }.compactMap { $0["session_id"] as? String }
        }
        func configs() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return requests.compactMap { $0["line"] as? [String: Any] }.filter { $0["type"] as? String == "set_config" }.compactMap { $0["config"] as? String }
        }
        func lists() -> Int { lock.lock(); defer { lock.unlock() }; return requests.filter { $0["op"] as? String == SessionClient.Op.list }.count }
        /// Every process runs on the file's keys now.
        var allCurrent: Bool { lock.lock(); defer { lock.unlock() }; return procs.values.allSatisfy { $0.keys == now } }
        func runsOn(_ id: String) -> String? { lock.lock(); defer { lock.unlock() }; return procs[id].map { $0.keys == now ? "now" : $0.keys } }
        func clear() { lock.lock(); requests = []; lock.unlock() }
    }

    /// The retry clock, run by hand.
    final class Clock {
        var waiting: [(delay: TimeInterval, f: () -> Void)] = []
        func fire() { let w = waiting; waiting = []; for x in w { x.f() } }
    }

    /// The app's one shell on a fake helper: the configuration and the key file read where they are saved.
    final class Saved { var config = "ds-flash" }
    static func keyShell(_ h: FakeHelper, _ saved: Saved = Saved(), center: NotificationCenter? = nil, clock: Clock? = nil) -> ShellModel {
        ShellModel(client: SessionClient(transport: h), defaults: scratchDefaults(), config: { saved.config }, lang: { .zhHans },
                   keyFile: { h.lock.lock(); defer { h.lock.unlock() }; return h.key }, savedSettings: center,
                   retryAfter: clock.map { c in { d, f in c.waiting.append((d, f)) } }, work: { $0() }, deliver: { $0() })
    }

    /// #107 review at 5999bd9 (P2): what the sessions run with does not depend on which window saved. A key changed
    /// in the window as it was (its sheet's Save: CloudModelSettings.write, never this window's settingsChanged) asks
    /// every process on the old key for a new one; a save made while this window was not shown is told when it is shown
    /// again; this window's own sheet (its writes' notice, then its close) restarts nothing twice; a model change alone
    /// goes in place (set_config), no restart.
    static func savedAnywhereTests() {
        // 1. the old window's Save (its write posts; this window's settingsChanged never called)
        do {
            let h = FakeHelper(key: "K=old", running: ["ses_t"]), center = NotificationCenter()
            let m = keyShell(h, center: center)
            for l in SessionTests.lines("chat") { m.client.feed(l) }
            m.syncSettings()                                     // (shown: nothing owed)
            m.stopWatching()                                     // (the 0.5 window off: ui05.shell turned off)
            h.key = "K=new"
            ModelSettingsSaved.post(center)
            check(h.ends() == ["ses_t"] && h.runsOn("ses_t") == nil, "a key saved in the old window: the live session asked for a new process: \(h.ends())")
            m.client.feed(["kind": "helper.session_exit", "session_id": "ses_t", "code": 0, "idle": true])
            m.selected = "ses_t"; m.draft = "again"; m.submit()
            check(h.runsOn("ses_t") == "now", "its next message opens a new process, on the new key")
        }

        // 2. saved while nothing observed (this window not shown; no notice reached the shell): told when it is shown
        do {
            let h = FakeHelper(key: "K=old", running: ["ses_t"])
            let m = keyShell(h)
            m.syncSettings()
            h.key = "K=new"
            check(h.ends().isEmpty, "nothing told yet")
            m.syncSettings()                                     // (MainSplitView.onAppear)
            check(h.ends() == ["ses_t"], "shown again: the live session asked for a new process: \(h.ends())")
            h.clear()
            m.syncSettings()
            check(h.requests.isEmpty, "shown once more, nothing new: nothing sent: \(h.requests.map { $0["op"] ?? "" })")
            // ... or before this launch: a new shell, a process the helper runs that this client has never seen
            h.spawn("ses_bg"); h.key = "K=newer"; h.clear()
            let m2 = keyShell(h)
            m2.syncSettings()
            check(h.ends() == ["ses_bg"] && h.allCurrent, "a new launch: the helper's running session on the old key asked: \(h.ends())")
        }

        // 3. this window's own sheet: its writes post (the key file, the service, the configuration), then it closes
        do {
            let h = FakeHelper(key: "K=old", running: ["ses_t"]), saved = Saved(), center = NotificationCenter()
            let m = keyShell(h, saved, center: center)
            for l in SessionTests.lines("chat") { m.client.feed(l) }
            m.syncSettings()
            h.key = "OPENROUTER_API_KEY=k"; ModelSettingsSaved.post(center)
            saved.config = "or-luna"; ModelSettingsSaved.post(center); ModelSettingsSaved.post(center)
            m.syncSettings()                                     // (settingsClosed)
            check(h.ends() == ["ses_t"], "the window's own save: one restart, not two: \(h.ends())")
            check(h.configs().last == "or-luna", "and the session has the new configuration: \(h.configs())")
        }

        // 4. a model change alone (same key file): in place, no restart
        do {
            let h = FakeHelper(key: "K=old", running: ["ses_t"]), saved = Saved(), center = NotificationCenter()
            let m = keyShell(h, saved, center: center)
            for l in SessionTests.lines("chat") { m.client.feed(l) }
            m.syncSettings(); m.client.reconciling.wait(); h.clear()      // (in view: converged to ds-flash)
            saved.config = "or-luna"
            ModelSettingsSaved.post(center)
            check(h.configs() == ["or-luna"] && h.ends().isEmpty, "a model change from any window: set_config only, no restart: \(h.configs()) \(h.ends())")
            h.clear()
            m.syncSettings()
            check(h.requests.isEmpty, "the sheet's close after it: nothing again")
        }

        // 5. the in-place settings' dedupe (re-review E2): a language switch reported twice is sent once
        do {
            let h = FakeHelper(key: "K=old", running: ["ses_t"])
            var lang = ResolvedLang.zhHans
            let m = ShellModel(client: SessionClient(transport: h), defaults: scratchDefaults(), config: { "ds-flash" }, lang: { lang },
                               keyFile: { "K=old" }, work: { $0() }, deliver: { $0() })
            for l in SessionTests.lines("chat") { m.client.feed(l) }
            m.syncSettings(); m.client.reconciling.wait(); h.clear()
            func langs() -> [String] {
                h.requests.compactMap { $0["line"] as? [String: Any] }.filter { $0["type"] as? String == "set_config" }.compactMap { $0["lang"] as? String }
            }
            lang = .en
            m.syncSettings(); m.syncSettings()
            check(langs() == ["en"] && h.ends().isEmpty, "a language switch told twice: one set_config, no restart: \(langs())")
            lang = .zhHans
            m.syncSettings(); m.syncSettings()
            check(langs() == ["en", "zh"], "switched back: one more: \(langs())")
        }

        // the app's writers post, and the app's one shell observes them; the window compares through the shell only
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let cloud = (try? String(contentsOf: dir.appendingPathComponent("Main/CloudModel.swift"), encoding: .utf8)) ?? ""
        // (the keys: written through the helper, keys.set -- A11)
        let write = cloud.components(separatedBy: "static func set(_ pairs:").dropFirst().first?.components(separatedBy: "static var provider").first ?? ""
        let provider = cloud.components(separatedBy: "static var provider: CloudProvider {").dropFirst().first?.components(separatedBy: "\n    }").first ?? ""
        let engineConfig = cloud.components(separatedBy: "static var engineConfig: String? {").dropFirst().first?.components(separatedBy: "\n    }").first ?? ""
        check(write.contains("ModelSettingsSaved.post()") && provider.contains("ModelSettingsSaved.post()") && engineConfig.contains("ModelSettingsSaved.post()"),
              "every writer of the model settings posts (the key file, the service, the configuration)")
        let others = ["Main", "Shared"].flatMap { d in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(d).path)) ?? []).filter { $0.hasSuffix(".swift") }.map { "\(d)/\($0)" }
        }
        // (re-review E4) any mention of their keys, read or written, outside CloudModelSettings: none
        let others2 = others + ((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Helper").path)) ?? [])
            .filter { $0.hasSuffix(".swift") }.map { "Helper/\($0)" }
        let rawMentions = others2.filter { f in
            let t = (try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) ?? ""
            return f != "Main/CloudModel.swift" && (t.contains("\"engine.config\"") || t.contains("\"cloud.provider\""))
        }
        check(others2.count > 10 && rawMentions.isEmpty && cloud.components(separatedBy: "forKey: \"engine.config\")").count == 3,
              "the configuration and the service are named (read or written) through CloudModelSettings only: \(rawMentions)")
        let main = (try? String(contentsOf: dir.appendingPathComponent("Main/MainSplitView.swift"), encoding: .utf8)) ?? ""
        check(main.contains("keyFile: { MainSplitView.envFingerprint() }, savedSettings: .default"), "the app's shell observes every save")
        let appear = main.components(separatedBy: ".onAppear {").dropFirst().first?.components(separatedBy: "}").first ?? ""
        let closed = main.components(separatedBy: "private func settingsClosed()").dropFirst().first?.components(separatedBy: "\n    }").first ?? ""
        check(appear.contains("shell.syncSettings()") && closed.contains("shell.syncSettings()") && !main.contains("shell.settingsChanged("),
              "the window shown and its sheet closed compare through the shell, never call settingsChanged itself")
    }

    /// #107 review at 0a5af02 and at b3b8464 (P2): which processes still run on keys no longer saved is the helper's to
    /// say (each process's digest at its start, the file's now). A lost or refused ask stays owed: asked again on the
    /// next syncSettings and after a backoff with no user action, only the processes still on old keys; a quit, a
    /// helper that is not read, a busy session (asked, ending at its next idle moment) and A→B→A all end with every
    /// process on the keys saved now.
    static func keyAckTests() {
        func live(_ m: ShellModel) {
            for l in SessionTests.lines("chat") { m.client.feed(l) }                                 // ses_t
            m.client.feed(["kind": "session.task", "session_id": "ses_busy", "seq": 1, "msg_id": "m", "run_id": "r9", "raw": "x", "by": "slash"])
        }

        // an ask unanswered twice: the clock asks again (no user action), then the next trigger; the one taken not again
        do {
            let h = FakeHelper(key: "K=old", running: ["ses_busy", "ses_t"]), clock = Clock(), center = NotificationCenter()
            let m = keyShell(h, center: center, clock: clock)
            live(m)
            m.syncSettings()
            check(!m.keysPending && h.ends().isEmpty, "shown: nothing owed")
            h.failEnd["ses_busy"] = 2
            h.key = "K=new"
            ModelSettingsSaved.post(center)
            check(h.ends() == ["ses_busy", "ses_t"] && m.keysPending && h.runsOn("ses_busy") != "now",
                  "one ask unanswered: still owed, its process on the old key: \(h.ends())")
            check(clock.waiting.map(\.delay) == [2], "a retry after 2 s: \(clock.waiting.map(\.delay))")
            clock.fire()
            check(h.ends() == ["ses_busy", "ses_t", "ses_busy"] && m.keysPending, "the retry asks only the one owed (unanswered again): \(h.ends())")
            check(clock.waiting.map(\.delay) == [4], "the next after 4 s: \(clock.waiting.map(\.delay))")
            m.syncSettings()                                   // (the window shown, a save, the sheet's close)
            check(h.ends() == ["ses_busy", "ses_t", "ses_busy", "ses_busy"] && !m.keysPending && h.allCurrent,
                  "the next trigger: taken; nothing owed: \(h.ends())")
            clock.fire(); m.syncSettings(); ModelSettingsSaved.post(center)
            check(h.ends().count == 4 && clock.waiting.isEmpty, "then nothing asked again: \(h.ends())")
            m.client.feed(["kind": "helper.session_exit", "session_id": "ses_busy", "code": 0, "idle": true])
            m.selected = "ses_busy"; m.draft = "again"; m.submit()
            check(h.runsOn("ses_busy") == "now", "its next message: a new process, on the new key")
        }

        // an ask answered with an error (the helper refused it): owed too
        do {
            let h = FakeHelper(key: "K=old", running: ["ses_busy", "ses_t"]), clock = Clock()
            let m = keyShell(h, clock: clock)
            live(m)
            m.syncSettings()
            h.refuseEnd["ses_busy"] = 1
            h.key = "K=new"
            m.syncSettings()
            check(m.keysPending && clock.waiting.count == 1 && h.runsOn("ses_busy") != nil, "a refused ask: owed")
            clock.fire()
            check(!m.keysPending && h.ends() == ["ses_busy", "ses_t", "ses_busy"] && h.allCurrent, "retried: none owed: \(h.ends())")
        }

        // the list unread: the client's own live sessions asked (what they run on unknown); a process it has not seen is
        // owed until the list is read
        do {
            let h = FakeHelper(key: "K=old", running: ["ses_bg", "ses_t"]), clock = Clock()
            let m = keyShell(h, clock: clock)
            for l in SessionTests.lines("chat") { m.client.feed(l) }
            m.syncSettings()
            h.failList = 2                                    // (the round's list, and its read after the asks)
            h.key = "K=new"
            m.syncSettings()
            check(h.ends() == ["ses_t"] && m.keysPending && clock.waiting.count == 1, "the list unread: the known one asked, still owed: \(h.ends())")
            clock.fire()
            check(h.ends() == ["ses_t", "ses_bg"] && !m.keysPending && h.allCurrent, "retried: the helper's other process asked, ses_t not again: \(h.ends())")
        }

        // quit while owed: the next launch reads the helper and asks what is still on the old keys
        do {
            let h = FakeHelper(key: "K=old", running: ["ses_busy", "ses_t"])
            do {
                let m1 = keyShell(h)
                live(m1)
                m1.syncSettings()
                h.failEnd["ses_busy"] = 1
                h.key = "K=new"
                m1.syncSettings()
                check(h.ends() == ["ses_busy", "ses_t"] && m1.keysPending, "before the quit: ses_busy owed")
                m1.stopWatching()
            }
            h.clear()
            let m2 = keyShell(h)
            check(m2.keysPending, "the next launch: owed until read")
            m2.syncSettings()
            check(h.ends() == ["ses_busy"] && !m2.keysPending && h.allCurrent, "it asks only the one still on the old key: \(h.ends())")
        }

        // A→B→A (the review's case): B saved, one ask lost, the other session restarted on B; back to A: the one on B is
        // asked, the one still on A is not
        do {
            let h = FakeHelper(key: "K=A", running: ["ses_busy", "ses_t"]), clock = Clock()
            let m = keyShell(h, clock: clock)
            live(m)
            m.syncSettings()
            check(!m.keysPending, "A applied")
            h.failEnd["ses_t"] = 1
            h.key = "K=B"
            m.syncSettings()
            check(h.ends() == ["ses_busy", "ses_t"] && m.keysPending, "B: ses_busy taken, ses_t lost: \(h.ends())")
            h.spawn("ses_busy")                                // (its next message: a process on B)
            h.key = "K=A"
            h.clear()
            m.syncSettings()
            check(h.ends() == ["ses_busy"] && h.allCurrent && !m.keysPending, "back to A: the process on B asked, the one on A not: \(h.ends())")
        }

        // a busy session: its ask deferred (ending at its next idle moment) — not asked again, owed until it goes
        do {
            let h = FakeHelper(key: "K=old", running: ["ses_busy"]), clock = Clock()
            let m = keyShell(h, clock: clock)
            m.syncSettings()
            h.busy = ["ses_busy"]
            h.key = "K=new"
            m.syncSettings()
            check(h.ends() == ["ses_busy"] && m.keysPending && clock.waiting.count == 1, "busy: asked once, owed while it runs")
            clock.fire()
            check(h.ends() == ["ses_busy"] && m.keysPending, "the retry: not asked again (ending)")
            h.idle("ses_busy")
            clock.fire()
            check(!m.keysPending && h.ends() == ["ses_busy"] && clock.waiting.isEmpty, "gone at its idle moment: none owed")
        }

        // a process spawned on A, its session.start not come, when B is saved (#107 review at 85d81f6): owed, not asked
        // while it starts (the helper's end finds it not open); asked once started, by the backoff alone
        do {
            let h = FakeHelper(key: "K=A", running: ["ses_t"]), clock = Clock()
            let m = keyShell(h, clock: clock)
            m.syncSettings()
            h.spawn("ses_new", started: false)                 // (it read A)
            h.key = "K=B"
            m.syncSettings()
            check(h.ends() == ["ses_t"] && m.keysPending && h.runsOn("ses_new") != "now" && clock.waiting.count == 1,
                  "starting: owed, not asked yet: \(h.ends()) pending=\(m.keysPending)")
            clock.fire()
            check(h.ends() == ["ses_t"] && m.keysPending && clock.waiting.count == 1, "still starting: still owed, read again later")
            h.start("ses_new")
            clock.fire()
            check(h.ends() == ["ses_t", "ses_new"] && !m.keysPending && h.allCurrent, "started: asked; none owed: \(h.ends())")
        }

        // a spawn listed before its one read of the keys (#107 review at 36c5737): unknown → owed, not asked, and never a
        // row; A→B→A around its read (it read B): owed while starting, asked once started
        do {
            let h = FakeHelper(key: "K=A", running: ["ses_t"]), clock = Clock()
            let m = keyShell(h, clock: clock)
            m.syncSettings()
            h.spawnUnread("ses_new")
            h.key = "K=B"
            m.syncSettings()
            check(h.ends() == ["ses_t"] && m.keysPending && clock.waiting.count == 1, "being spawned, keys not read: owed, not asked: \(h.ends())")
            check(m.client.list()?.contains { $0.sessionId == "ses_new" } == false && m.client.listWithKeys()?.processes?.contains { $0.sessionId == "ses_new" } == true,
                  "and not a row of the list (the keys round sees it): \(String(describing: m.client.list()?.map(\.sessionId)))")
            // a starting session with no stored message that this app does not hold (a watch reconnect while it starts,
            // a helper that does not mark it new): no row either; once it has a message or the app holds it, a row
            var starting = SessionSummary(sessionId: "ses_s", title: "", updatedAt: nil, lastMessage: nil)
            starting.starting = true
            let old = SessionSummary(sessionId: "ses_o", title: "旧的", updatedAt: 1, lastMessage: nil)
            let rows = ShellList.rows(summaries: [starting, old], states: [:], names: [:], deleted: [], untitled: "New conversation")
            check(rows.map(\.id) == ["ses_o"], "a starting entry with nothing stored, not held here: no row: \(rows.map(\.id))")
            var stored = starting; stored.updatedAt = 2
            check(ShellList.rows(summaries: [stored, old], states: [:], names: [:], deleted: [], untitled: "x").map(\.id) == ["ses_s", "ses_o"],
                  "one with stored messages (a reopen): a row")
            let held = ShellList.rows(summaries: [starting, old], states: ["ses_s": SessionState(sessionId: "ses_s")], names: [:], deleted: [], untitled: "x")
            check(held.map(\.id).contains("ses_s"), "one this app holds (its new conversation): a row")
            h.readKeys("ses_new")                               // (its one read: B — the environment and the digest)
            h.key = "K=A"
            clock.fire()
            check(m.keysPending && h.ends() == ["ses_t"], "read B, the file back to A: owed while it starts")
            h.start("ses_new")
            clock.fire()
            check(!m.keysPending && h.allCurrent && h.ends() == ["ses_t", "ses_new"], "started: asked; all on A: \(h.ends())")
        }

        // started, nothing stored yet (#107 review at 588dbad): not in the stored list, in the helper's process table —
        // B saved: it is asked like any other
        do {
            let h = FakeHelper(key: "K=A", running: ["ses_t"]), clock = Clock()
            let m = keyShell(h, clock: clock)
            m.syncSettings()
            h.spawn("ses_u"); h.unstored = ["ses_u"]
            h.key = "K=B"
            m.syncSettings()
            check(h.ends() == ["ses_t", "ses_u"] && !m.keysPending && h.allCurrent, "started, nothing stored: asked onto B: \(h.ends()) pending=\(m.keysPending)")
            check(m.client.list()?.contains { $0.sessionId == "ses_u" } == false, "(and no row until something is stored)")
        }

        // an older helper: an ask not taken stays owed (#107 review at 588dbad: the next pass cleared it and the round
        // committed); the retry asks it again, and only then is nothing owed
        do {
            let h = FakeHelper(key: "K=old", running: ["ses_o"]), clock = Clock()
            h.old = true
            let m = keyShell(h, clock: clock)
            h.failEnd["ses_o"] = 1
            h.key = "K=new"
            m.syncSettings()
            check(h.ends() == ["ses_o"] && m.keysPending && clock.waiting.count == 1 && h.runsOn("ses_o") != nil,
                  "older helper, the ask lost: owed, a retry waits: pending=\(m.keysPending) retries=\(clock.waiting.count)")
            clock.fire()
            check(h.ends() == ["ses_o", "ses_o"] && !m.keysPending && h.runsOn("ses_o") == nil, "the retry asks it again; then none owed: \(h.ends())")
        }

        // an older helper (no digests): its open sessions asked once per key file; not again for the same file
        do {
            let h = FakeHelper(key: "K=old", running: ["ses_o"]), clock = Clock()
            h.old = true
            let m = keyShell(h, clock: clock)
            h.key = "K=new"
            m.syncSettings()
            check(h.ends() == ["ses_o"] && !m.keysPending, "unknown: asked once")
            h.spawn("ses_o")
            m.syncSettings()
            h.key = "K=newer"
            m.syncSettings()
            check(h.ends() == ["ses_o", "ses_o"], "again only for a new key file: \(h.ends())")
        }

        // asked while a round is under way: no session asked twice, never two rounds at once, the round's end not lost
        do {
            final class Slow: SessionTransport {
                let lock = NSLock()
                var ends: [String] = []
                var inEnd = 0, most = 0
                var gone = false
                let gate = DispatchSemaphore(value: 0)
                var holdFirst = true
                func request(_ body: [String: Any]) -> [String: Any]? {
                    let op = body["op"] as? String ?? ""
                    if op == SessionClient.Op.list {
                        lock.lock(); defer { lock.unlock() }
                        return ["ok": true, "keys": "now", "sessions": gone ? [] : [["session_id": "ses_q", "title": "", "open": true, "keys": "old"]]]
                    }
                    guard op == SessionClient.Op.end else { return ["ok": true] }
                    lock.lock(); inEnd += 1; most = max(most, inEnd); ends.append(body["session_id"] as? String ?? ""); let hold = holdFirst; holdFirst = false; lock.unlock()
                    if hold { gate.wait() }
                    lock.lock(); inEnd -= 1; gone = true; lock.unlock()
                    return ["ok": true]
                }
                func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool { false }
            }
            let slow = Slow()
            let m = ShellModel(client: SessionClient(transport: slow), defaults: scratchDefaults(), config: { "ds-flash" }, lang: { .zhHans },
                               keyFile: { "K" }, work: { f in DispatchQueue.global().async(execute: f) }, deliver: { $0() })
            let done = DispatchGroup()
            done.enter(); DispatchQueue.global().async { m.syncSettings(); done.leave() }
            usleep(100_000)
            m.syncSettings(); m.syncSettings()                 // (while the first ask waits on the helper)
            usleep(100_000)
            slow.gate.signal()
            done.wait()
            var ok = false
            for _ in 0..<100 { if !m.keysPending { ok = true; break }; usleep(20_000) }
            slow.lock.lock(); let e = slow.ends, most = slow.most; slow.lock.unlock()
            check(ok && e == ["ses_q"] && most == 1, "asked meanwhile: no second ask, never two at once: \(e) most=\(most)")
        }

        // each ask carries the settings as they are when it goes (a newer save's never overwritten by an older round's)
        do {
            let h = FakeHelper(key: "K=old", running: ["ses_t"]), saved = Saved()
            let m = keyShell(h, saved)
            for l in SessionTests.lines("chat") { m.client.feed(l) }
            m.syncSettings()
            h.key = "K=new"
            saved.config = "or-luna"
            m.syncSettings()
            m.client.feed(["kind": "helper.session_exit", "session_id": "ses_t", "code": 0, "idle": true])
            h.clear()
            m.selected = "ses_t"; m.draft = "again"; m.submit()
            let reopen = h.requests.first { $0["op"] as? String == SessionClient.Op.open }
            check(reopen?["config"] as? String == "or-luna", "the restarted session reopens with the settings now: \(String(describing: reopen?["config"]))")
        }

        // the helper records each process's digest at its start (before its environment is read) and reports both
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let host = (try? String(contentsOf: dir.appendingPathComponent("Helper/SessionHost.swift"), encoding: .utf8)) ?? ""
        let spawn = host.components(separatedBy: "private static func spawn(").dropFirst().first?.components(separatedBy: "static func send(").first ?? ""
        check(spawn.contains("s.keysDigest = keys"), "spawn: the digest kept with the process")
        let list = host.components(separatedBy: "static func list() -> [String: Any] {").dropFirst().first ?? ""
        check(list.contains("reply[\"keys\"] = keysNow") && list.contains("i[\"keys\"] = k") && list.contains("i[\"ending\"] = r.ending"),
              "sessions.list: the file's digest now, each open process's, and whether it is ending")
        check(list.contains("(s.started || s.process.isRunning)") && list.contains("i[\"starting\"] = true"),
              "sessions.list: a process spawned, not started yet, is reported (starting) with its digest")
        // (#107 review at 36c5737) listed from before its one read of the keys file; the environment and the digest of it
        let listedAt = spawn.range(of: "spawning[id] = .some(nil)")?.lowerBound
        let readAt = spawn.range(of: "let keysEnv = HarnessRun.modelEnv()")?.lowerBound
        check(listedAt != nil && readAt != nil && listedAt! < readAt! && spawn.components(separatedBy: "modelEnv()").count == 2
              && spawn.contains("let keys = ModelKeys.digest(env: keysEnv)") && spawn.contains("p.environment = setup.environment(keysEnv)")
              && spawn.contains("defer { lock.lock(); spawning[id] = nil; lock.unlock() }"),
              "spawn: listed before its single read of the keys; the environment and the digest from that read; unlisted on every way out")
        check(list.contains("for (id, k) in spawning where running[id] == nil") && list.contains("\"processes\": processes")
              && list.contains("let processes = running.keys.sorted()"),
              "sessions.list: the process table — every process held (spawning, started with nothing stored, running) — apart from the stored list")
    }

    /// Delta review of a09c632: a reconcile never waits for the switch's push. Run from ModelsOffSync's own callback
    /// (helperSays → push → reconcile), a wait there waited on itself: each session's set_config went out after the
    /// 3 s timeout, and a models.off(true) the user asked for meanwhile reached the helper seconds late. The first
    /// set_config of that reconcile refused no_model (the helper went off again): the others still go out at once.
    static func reconcileNoWaitTests() {
        final class T: SessionTransport {
            let lock = NSLock(), t0 = Date()
            var sent: [(id: String, at: Double)] = []
            var refuseFirst = false
            func request(_ body: [String: Any]) -> [String: Any]? {
                let op = body["op"] as? String ?? ""
                guard op == SessionClient.Op.send, (body["line"] as? [String: Any])?["type"] as? String == "set_config" else { return ["ok": true] }
                lock.lock(); defer { lock.unlock() }
                sent.append((body["session_id"] as? String ?? "", Date().timeIntervalSince(t0)))
                if refuseFirst { refuseFirst = false; return ["ok": false, "code": "no_model", "control": "set_config"] }
                return ["ok": true]
            }
            func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool { false }
        }
        let t = T()
        let c = SessionClient(transport: t)
        c.adoptSettings(config: "c", lang: "zh")
        for id in ["s1", "s2", "s3"] { c.feed(["kind": "session.start", "session_id": id, "resumed": false, "last_seq": 0]) }
        c.reconciling.wait()
        t.lock.lock(); t.sent = []; t.refuseFirst = true; t.lock.unlock()
        c.adoptSettings(config: "c2", lang: "zh")           // (saved since: each session owes the new settings)
        let start = Date()
        c.helperSays(modelsOff: true)                       // (the app's switch is on: pushed, then every session converged)
        let until = Date().addingTimeInterval(8)
        while Date() < until {
            t.lock.lock(); let ids = Set(t.sent.map(\.id)); t.lock.unlock()
            if ids.isSuperset(of: ["s1", "s2", "s3"]) { break }
            usleep(10_000)
        }
        t.lock.lock(); let sent = t.sent; t.lock.unlock()
        let firstOf = { (id: String) in sent.first { $0.id == id }?.at }
        let late = ["s1", "s2", "s3"].filter { (firstOf($0) ?? .infinity) - start.timeIntervalSince(t.t0) > 1 }
        check(late.isEmpty, "the first set_config refused no_model: every session's still goes out within 1 s: \(sent.map { "\($0.id)@\(String(format: "%.2f", $0.at))" })")
        c.modelsSync.settle(); c.reconciling.wait()
    }

    /// #107 review at c0dbe96 — the invariant: every submitted message ends up in exactly one place, taken by the
    /// session (outbox, queue, history) or an unsent bubble with its reason (send again or remove); never dropped, and
    /// never put back over a newer draft. Each way a send can fail before the session takes it, with a new draft typed
    /// between Enter and the send.
    static func messageNeverLostTests() {
        let msg = "把周报发给老板"
        func places(_ s: SessionState) -> Int {
            s.outbox.filter { $0.text == msg }.count + s.messages.filter { $0.role == "user" && $0.text == msg }.count
                + s.queue.filter { $0.text == msg }.count
        }
        enum After { case none, card, refusal(String), accepted }
        let cases: [(name: String, send: [String: Any]?, open: [String: Any]?, after: After, unsent: String?)] = [
            ("a card came between Enter and the send", ["ok": true], nil, .card, "card_open"),
            ("the session refused it busy", ["ok": true], nil, .refusal("busy"), "busy"),
            ("the session refused it too_long", ["ok": true], nil, .refusal("too_long"), "too_long"),
            ("the session refused it computer_busy", ["ok": true], nil, .refusal("computer_busy"), "computer_busy"),
            ("the helper holds the model off", ["ok": false, "code": "no_model"], nil, .none, "no_model"),
            ("not open, and the reopen failed", ["ok": false, "code": "not_open"], nil, .none, "exited"),
            ("a transport error", ["ok": false, "error": "broken pipe"], nil, .none, "unavailable"),
            ("no reply at all", nil, nil, .none, "unavailable"),
            ("taken by the session", ["ok": true], nil, .accepted, nil),
        ]
        for c in cases {
            let mock = Mock()
            if let r = c.send { mock.replies[SessionClient.Op.send] = r }
            if let r = c.open { mock.replies[SessionClient.Op.open] = r }
            var later: [() -> Void] = []
            let client = SessionClient(transport: mock)
            client.makeClientId = { "c_msg" }
            let m = ShellModel(client: client, defaults: scratchDefaults(), config: { "ds-flash" }, lang: { .zhHans },
                               work: { later.append($0) }, deliver: { $0() })
            let fixture = SessionTests.lines("task-card")
            let askAt = fixture.firstIndex { $0.event.kind == "ask" } ?? 0
            for l in fixture.prefix(askAt) { m.client.feed(l) }          // (a task runs; no card yet)
            m.selected = "ses_t"
            m.draft = msg
            m.submit()                                                   // Enter: the send is under way (not run yet)
            m.draft = "新的草稿"                                          // the user types the next one meanwhile
            if case .card = c.after { m.client.feed(fixture[askAt]) }    // a card comes before the send goes
            for f in later { f() }; later = []
            switch c.after {
            case .card:
                // (A9: the steer goes; a harness before H5 refuses it card_open)
                m.client.feed(["kind": "session.error", "session_id": "ses_t", "code": "card_open", "control": "steer", "client_id": "c_msg", "text": "x"])
            case .refusal(let code):
                m.client.feed(["kind": "session.error", "session_id": "ses_t", "code": code, "control": "steer", "client_id": "c_msg", "text": "x"])
            case .accepted:
                m.client.feed(["kind": "session.message", "session_id": "ses_t", "seq": 99, "msg_id": "u_msg", "role": "user", "text": msg, "client_id": "c_msg"])
            default: break
            }
            m.client.reconciling.wait()
            let s = m.client.state("ses_t")
            let bubble = s.unsent.first { $0.text == msg }
            check(places(s) == 1, "\(c.name): the message in exactly one place (\(places(s)))")
            check(m.draft == "新的草稿", "\(c.name): the new draft untouched (\(m.draft))")
            if let why = c.unsent {
                check(bubble?.refused == why, "\(c.name): an unsent bubble, \(why) (\(String(describing: bubble?.refused)))")
            } else {
                check(bubble == nil, "\(c.name): taken, no bubble")
            }
        }
        // a steer (⌘Enter) refused for a card that came before it went: once the card is answered and the task still
        // runs, send again goes to that task (#107 delta review of 7f09c1b: it said "task ended" for good)
        do {
            let mock = Mock()
            mock.replies[SessionClient.Op.send] = ["ok": true]
            var later: [() -> Void] = []
            let m = ShellModel(client: SessionClient(transport: mock), defaults: scratchDefaults(), config: { "ds-flash" }, lang: { .zhHans },
                               work: { later.append($0) }, deliver: { $0() })
            let fixture = SessionTests.lines("task-card")
            let askAt = fixture.firstIndex { $0.event.kind == "ask" } ?? 0
            let resumedAt = fixture.firstIndex { $0.event.kind == "resumed" } ?? 0
            for l in fixture.prefix(askAt) { m.client.feed(l) }
            let run = m.client.state("ses_t").runningTask?.runId ?? ""
            m.selected = "ses_t"
            m.client.makeClientId = { "c_steer" }
            m.draft = "改成蓝色"
            m.submit()                                                   // Return: a steer of the running task (A9)
            m.client.feed(fixture[askAt])                                // a card comes before it goes
            for f in later { f() }; later = []
            // (it goes; a harness before H5 refuses it card_open -- shown not delivered, never sent again by itself)
            m.client.feed(["kind": "session.error", "session_id": "ses_t", "code": "card_open", "control": "steer", "client_id": "c_steer", "text": "x"])
            let bubble = m.client.state("ses_t").unsent.first
            check(bubble?.refused == "card_open", "the steer: an unsent bubble, card_open")
            for l in fixture[(askAt + 1)...resumedAt] { m.client.feed(l) }   // the card answered; the task goes on
            check(m.client.state("ses_t").runningTask?.runId == run && m.composer.enabled, "(the task still runs, the composer takes words)")
            mock.requests = []
            m.resend(bubble?.id ?? "")
            for f in later { f() }; later = []
            let line = sent(mock)
            check(line?["type"] as? String == "steer" && line?["run_id"] as? String == run && line?["text"] as? String == "改成蓝色",
                  "send again: the steer goes to its task: \(String(describing: line))")
        }

        // a card waits: the bubble's send again waits too (answered on the card first — M1 decision 1)
        do {
            let mock = Mock()
            mock.replies[SessionClient.Op.send] = ["ok": true]
            let m = ShellModel(client: SessionClient(transport: mock), defaults: scratchDefaults(), config: { "ds-flash" }, lang: { .zhHans },
                               work: { $0() }, deliver: { $0() })
            let fixture = SessionTests.lines("task-card")
            let askAt = fixture.firstIndex { $0.event.kind == "ask" } ?? 0
            for l in fixture.prefix(askAt + 1) { m.client.feed(l) }
            m.selected = "ses_t"
            _ = m.client.send(.say(msg), to: "ses_t")
            let id = m.client.state("ses_t").unsent.first?.id ?? ""
            let n = sends(mock)
            m.resend(id)
            check(!id.isEmpty && sends(mock) == n && m.client.state("ses_t").unsent.count == 1, "a card waits: send again does nothing yet")
            let main = (try? String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Main/MainSplitView.swift"), encoding: .utf8)) ?? ""
            check(main.contains("Button(L(\"Send again\", lang: lang)) { shell.resend(item.id) }.buttonStyle(.link)\n                            .disabled(!shell.composer.enabled)"),
                  "the bubble's Send again is off while a card waits")
        }
    }

    /// #107 review at 00969e8 — the invariant (SessionClient, "settings"): for every live session process, the
    /// configuration and language it has applied converge to the settings stored now; no stale value is carried by async
    /// work. The oracle is the sequence of saves: at quiescence, every live process (as the helper below runs it) has
    /// applied the last saved, and a next process opens with it — whatever order the saves' work, the open replies,
    /// the processes' starts and the session's answers came in.
    final class SimHelper: SessionTransport {
        let lock = NSLock()
        /// What each live process applies (the harness's own state), and each session's last stored settings.
        var procs: [String: (config: String?, lang: String?)] = [:]
        var stored: [String: (config: String?, lang: String?)] = [:]
        var lines: [[String: Any]] = []                 // the stream, in order, not delivered yet
        var delivered: [[String: Any]] = []             // stored lines already delivered (replayed as duplicates)
        var seq: [String: Int] = [:]
        var opens: [[String: Any]] = []
        var n = 0
        /// The helper's models-off bit (models.off): it nulls every process, starts new ones with null, refuses a
        /// configuration (no_model) while it holds it — as SessionHost does.
        var off = false
        /// Inside an open request, before its reply (the stream's lines may come first).
        var duringOpen: ((String) -> Void)?
        /// Inside a set_config request, before it is applied (a slow helper).
        var duringConfig: (() -> Void)?
        /// Per set_config: 0 as asked, 1 busy (applied, not stored: session.error busy), 2 no answer (not applied),
        /// 3 no answer but applied and stored (the reply lost).
        var chaos: (() -> Int)?
        /// Inside each set_config request, before it is applied (the switch turned while it is in flight, say).
        var whileConfig: (() -> Void)?
        /// Configurations that reached it while it held cloud models off (must stay 0).
        var offViolations = 0
        /// set_config requests that reached it; ones that came while another to the same session was still out (must
        /// stay 0: one in flight per session).
        var configSends = 0, overlaps = 0
        private var configsOut: [String: Int] = [:]
        private func emit(_ id: String, _ l: [String: Any], stored s: Bool) {
            var l = l; l["session_id"] = id
            if s { seq[id, default: 0] += 1; l["seq"] = seq[id]! }
            lines.append(l)
        }
        private func nullOut(_ id: String) {
            let lang = procs[id]?.lang
            procs[id] = (nil, lang); stored[id] = (nil, lang)
            emit(id, ["kind": "session.config", "config": NSNull(), "lang": lang ?? "zh", "by": "set_config"], stored: true)
        }
        func request(_ body: [String: Any]) -> [String: Any]? {
            let op = body["op"] as? String ?? ""
            lock.lock()
            switch op {
            case SessionClient.Op.open:
                let id: String
                if let s = body["session_id"] as? String { id = s } else { n += 1; id = "ses_\(n)" }
                // the harness: the open's settings, else the last stored, else its default
                let cfg = (body["config"] as? String) ?? stored[id]?.config ?? "ds-flash"
                let lang = (body["lang"] as? String) ?? stored[id]?.lang ?? "zh"
                procs[id] = (cfg, lang)
                let at = seq[id, default: 0]
                emit(id, ["kind": "session.start", "resumed": at > 0, "last_seq": at], stored: false)
                // (the harness normalises a config before it applies or stores it)
                let ncfg = harnessNormalize(cfg)
                procs[id] = (ncfg, lang)
                if let last = stored[id], last.config != ncfg || last.lang != lang {
                    stored[id] = (ncfg, lang)
                    emit(id, ["kind": "session.config", "config": ncfg, "lang": lang, "by": "open"], stored: true)
                }
                if off { nullOut(id) }                  // (the helper's first control to a process it starts while off)
                opens.append(body)
                let hook = duringOpen
                lock.unlock()
                hook?(id)
                return ["ok": true, "session_id": id, "last_seq": at]
            case SessionClient.Op.modelsOff:
                off = body["off"] as? Bool ?? off
                if off { for id in procs.keys.sorted() where procs[id]?.config != nil { nullOut(id) } }
                lock.unlock()
                return ["ok": true]
            case SessionClient.Op.send:
                let id = body["session_id"] as? String ?? ""
                guard procs[id] != nil else { lock.unlock(); return ["ok": false, "code": "not_open"] }
                let line = body["line"] as? [String: Any] ?? [:]
                if line["type"] as? String == "set_config" {
                    configSends += 1
                    if configsOut[id, default: 0] > 0 { overlaps += 1 }
                    configsOut[id, default: 0] += 1                  // (out while its hooks run: a slow helper)
                    let hook = duringConfig, during = whileConfig
                    lock.unlock(); hook?(); during?(); lock.lock()
                    configsOut[id, default: 0] -= 1
                    guard procs[id] != nil else { lock.unlock(); return ["ok": false, "code": "not_open"] }
                    let cfg = (line["config"] as? String).map(harnessNormalize), lang = line["lang"] as? String ?? procs[id]?.lang
                    if off && cfg != nil { offViolations += 1; lock.unlock(); return ["ok": false, "code": "no_model"] }
                    let mode = chaos?() ?? 0
                    if mode == 2 { lock.unlock(); return nil }
                    procs[id] = (cfg, lang)
                    if mode == 3 {
                        stored[id] = (cfg, lang)
                        emit(id, ["kind": "session.config", "config": cfg as Any? ?? NSNull(), "lang": lang ?? "zh", "by": "set_config",
                                  "client_id": line["client_id"] ?? ""], stored: true)
                        lock.unlock(); return nil
                    }
                    if mode == 1 {
                        lines.append(["kind": "session.error", "session_id": id, "code": "busy", "control": "set_config",
                                      "client_id": line["client_id"] ?? "", "text": "busy"])
                    } else {
                        stored[id] = (cfg, lang)
                        emit(id, ["kind": "session.config", "config": cfg as Any? ?? NSNull(), "lang": lang ?? "zh", "by": "set_config",
                                  "client_id": line["client_id"] ?? ""], stored: true)
                    }
                }
                lock.unlock()
                return ["ok": true]
            default:
                lock.unlock()
                return ["ok": true]
            }
        }
        func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool { false }
        /// The next line of the stream to the client; false when none. `swap`: the one after it first, when both are
        /// stored lines of one session (out of order: held until the gap fills). `duplicate`: a stored line delivered
        /// before, again (a history read overlapping the watch).
        @discardableResult
        func deliver(_ c: SessionClient, swap: Bool = false, duplicate: Bool = false) -> Bool {
            lock.lock()
            if duplicate, !delivered.isEmpty {
                let l = delivered[delivered.count / 2]
                lock.unlock(); c.feed(l); return true
            }
            guard !lines.isEmpty else { lock.unlock(); return false }
            var i = 0
            if swap, lines.count > 1, lines[0]["seq"] != nil, lines[1]["seq"] != nil,
               lines[0]["session_id"] as? String == lines[1]["session_id"] as? String { i = 1 }
            let l = lines.remove(at: i)
            if l["seq"] != nil { delivered.append(l) }
            lock.unlock()
            c.feed(l)
            return true
        }
        func deliverAll(_ c: SessionClient) { while deliver(c) {} }
        /// The helper restarts: every process gone (their exits), the models-off bit kept (it is persisted).
        func restart() {
            lock.lock()
            for id in procs.keys.sorted() { lines.append(["kind": "helper.session_exit", "session_id": id, "code": 0]) }
            procs = [:]
            lock.unlock()
        }
        /// A process ends (idle): the helper's exit line.
        func exit(_ id: String) {
            lock.lock(); procs[id] = nil; lines.append(["kind": "helper.session_exit", "session_id": id, "code": 0, "idle": true]); lock.unlock()
        }
        var live: [String: (config: String?, lang: String?)] { lock.lock(); defer { lock.unlock() }; return procs }
        var lastOpen: [String: Any]? { lock.lock(); defer { lock.unlock() }; return opens.last }
    }

    /// The settings as stored (the app's UserDefaults, here a box read from any thread): the configuration, the
    /// language, cloud models on or off.
    final class Store {
        private let lock = NSLock()
        private var value: (config: String, lang: ResolvedLang) = ("A", .zhHans)
        private var on = true
        var config: String { lock.lock(); defer { lock.unlock() }; return value.config }
        var lang: ResolvedLang { lock.lock(); defer { lock.unlock() }; return value.lang }
        var cloud: Bool { lock.lock(); defer { lock.unlock() }; return on }
        func save(_ c: String, _ l: ResolvedLang) { lock.lock(); value = (c, l); lock.unlock() }
        func setCloud(_ v: Bool) { lock.lock(); on = v; lock.unlock() }
        /// What every live process must apply: the configuration (none while cloud is off) and the language.
        var expected: (config: String?, lang: String) { (cloud ? harnessNormalize(config) : nil, lang == .zhHans ? "zh" : "en") }
    }

    /// A test's deferred work (SessionClient's and ModelsOffSync's `DeferredWork`): nothing runs until the test runs it,
    /// on the test's thread — an interleaving is the seed's, never the machine's timing (deskmind#112). Each lane keeps a
    /// serial queue's order; the timers' lane (`after`) runs in whatever order the test picks (its time is the test's).
    final class Steps {
        private let lock = NSLock()
        private var lanes: [String: [() -> Void]] = [:]
        /// A lane: its `soon` and `after` queue here; a wait for it (`drain`) runs everything queued.
        func lane(_ name: String) -> DeferredWork {
            DeferredWork(soon: { f in self.add(name, f) }, after: { _, f in self.add(name, f) }, drain: { self.drain() })
        }
        private func add(_ name: String, _ f: @escaping () -> Void) { lock.lock(); lanes[name, default: []].append(f); lock.unlock() }
        func count(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return lanes[name]?.count ?? 0 }
        var pending: Int { lock.lock(); defer { lock.unlock() }; return lanes.values.reduce(0) { $0 + $1.count } }
        /// Runs one step of `name` — its `i`-th (0: the head, as its queue would); false when it has none.
        @discardableResult
        func run(_ name: String, at i: Int = 0) -> Bool {
            lock.lock()
            guard var q = lanes[name], !q.isEmpty else { lock.unlock(); return false }
            let f = q.remove(at: min(i, q.count - 1)); lanes[name] = q
            lock.unlock()
            f()
            return true
        }
        /// Runs everything queued (what it queues too), the lanes in turn; false when `limit` steps did not empty it.
        @discardableResult
        func drain(limit: Int = 10_000) -> Bool {
            for _ in 0..<limit {
                lock.lock(); let name = lanes.keys.sorted().first { !(lanes[$0]?.isEmpty ?? true) }; lock.unlock()
                guard let name else { return true }
                run(name)
            }
            return pending == 0
        }
        /// Runs one lane until it is empty (what it queues on others stays queued).
        func drain(_ name: String, limit: Int = 10_000) { var n = 0; while n < limit, run(name) { n += 1 } }
        /// A sync of the test's own whose sends are this test's steps.
        func sync(_ t: SessionTransport, current: @escaping () -> Bool) -> ModelsOffSync {
            let s = ModelsOffSync(transport: t, current: current); s.work = lane("off"); return s
        }
        /// A client whose reconciles, retries and switch pushes run as this test's steps.
        func client(_ t: SessionTransport, modelsSync: ModelsOffSync? = nil) -> SessionClient {
            let c = SessionClient(transport: t, modelsSync: modelsSync)
            c.reconcileWork = lane("reconcile"); c.retryWork = lane("retry"); c.modelsSync.work = lane("off")
            return c
        }
    }

    /// A lock-guarded value a test shares with work on another thread.
    final class Locked<T> {
        private let lock = NSLock()
        private var v: T
        init(_ v: T) { self.v = v }
        var value: T { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
    }

    /// A shell on the simulated helper whose background work runs when the test says (in any order): the shell's work,
    /// and the client's reconciles, retries and switch pushes (`steps`).
    final class Rig {
        let h = SimHelper(), store = Store(), steps = Steps()
        var work: [() -> Void] = []
        let workLock = NSLock()
        var m: ShellModel!
        init() {
            m = ShellModel(client: steps.client(h), defaults: scratchDefaults(), config: { [store] in store.config },
                           lang: { [store] in store.lang }, cloudOn: { [store] in store.cloud },
                           work: { [weak self] f in self?.workLock.lock(); self?.work.append(f); self?.workLock.unlock() },
                           deliver: { $0() })
        }
        func runWork(at i: Int) { workLock.lock(); let f = work.remove(at: i); workLock.unlock(); f() }
        var pending: Int { workLock.lock(); defer { workLock.unlock() }; return work.count }
        /// A save: the store written, then the window told (its work queued).
        func save(_ c: String, _ l: ResolvedLang) { store.save(c, l); m.settingsChanged() }
        /// Cloud models turned on or off: the store, the window told, the switch pushed to the helper (the engine setter).
        func cloud(_ on: Bool) { store.setCloud(on); m.settingsChanged(); m.client.modelsSync.push() }
        /// A new conversation's first message (its open is queued work).
        func newConversation() { m.newConversation(); m.draft = "你好"; m.submit() }
        /// Everything that is left: work (in order), the stream, the client's own converges, the switch's push and the
        /// retries — until nothing moves. False when it never stops moving (a loop: itself a failure).
        @discardableResult
        func settle() -> Bool {
            for _ in 0..<400 {
                while pending > 0 { runWork(at: 0) }
                h.deliverAll(m.client)
                steps.drain()
                h.lock.lock(); let more = !h.lines.isEmpty; h.lock.unlock()
                if pending == 0 && !more && steps.pending == 0 { return true }
            }
            return false
        }
        func converged() -> Bool {
            let want = store.expected
            return h.live.values.allSatisfy { $0.config == want.config && $0.lang == want.lang }
        }
    }

    static func settingsConvergeTests() {
        // Codex 1: B saved, then C; their work runs C then B — the sessions end on C
        do {
            let r = Rig()
            r.newConversation(); r.settle()
            r.save("B", .en); r.save("C", .zhHans)
            r.runWork(at: 1); r.runWork(at: 0)                 // (C's work, then B's)
            r.settle()
            check(r.converged(), "saves B then C, their work run C then B: every process on C: \(r.h.live)")
        }
        // Codex 2: a new session opens with A; B is saved (its work run) while the open is out; the process's start
        // comes before the open's reply — the process gets B
        do {
            let r = Rig()
            r.h.duringOpen = { [unowned r] _ in
                r.h.duringOpen = nil
                r.save("B", .en); while r.pending > 0 { r.runWork(at: 0) }     // (B saved, its convergeAll ran: nothing knew the session)
                r.h.deliverAll(r.m.client)                                   // (session.start before the reply)
                r.steps.drain()
            }
            r.newConversation()
            r.settle()
            check(r.h.lastOpen?["config"] as? String == "A", "(it opened with A)")
            check(r.converged(), "B saved during the open, the start before the reply: the process on B: \(r.h.live)")
        }
        // the CI flake made deterministic: a set_config of A held in the helper while B is saved and told — the
        // process ends on B (desired is read when each set_config goes, one at a time per session)
        do {
            let r = Rig()
            r.newConversation(); r.settle()
            r.store.save("A2", .zhHans)
            let held = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0)
            r.h.duringConfig = { [unowned r] in r.h.duringConfig = nil; held.signal(); go.wait() }
            let sender = DispatchGroup()
            sender.enter()
            DispatchQueue.global().async { r.m.client.convergeAll(); sender.leave() }     // (A2 on its way, held in the helper)
            let wasHeld = held.wait(timeout: .now() + 5) == .success
            check(wasHeld, "(the set_config of A2 went, and is held)")
            r.save("B", .en)                                              // (saved and told while it is held)
            r.settle()                                                    // (its converge: one in flight — the sender's to redo)
            go.signal()
            _ = sender.wait(timeout: .now() + 10)                         // (the held send answered: the sender sends B)
            r.settle()
            check(r.converged(), "a set_config held while B is saved: the process ends on B: \(r.h.live)")
        }
        // random interleavings: saves, their work in any order, opens (the start before or after the reply), the stream's
        // lines whenever — some out of order (held until the gap fills), some again (a history read overlapping the
        // watch) — processes ending, cloud turned off and on (the helper nulls and refuses), set_configs answered busy or
        // not at all, and the client's own reconciles, retries and switch pushes run when the seed says. At quiescence
        // every live process has the last saved, and a next one opens with it. The oracle is the simulated helper's own
        // state. Each round is its seed alone, on one thread (deskmind#112: the steps were timed with threads and usleep,
        // and failed about 1 in 16 parallel runs). SHELL_CONVERGE_SEEDS="a b …" reruns given seeds;
        // SHELL_CONVERGE_ROUNDS=n runs n rounds (1000 by default: cheap now that nothing sleeps).
        let env = ProcessInfo.processInfo.environment
        let seeds: [UInt64] = env["SHELL_CONVERGE_SEEDS"].map { $0.split(separator: " ").compactMap { UInt64($0) } }
            ?? (0..<UInt64(env["SHELL_CONVERGE_ROUNDS"].flatMap { Int($0) } ?? 1000)).map { 107_000 + $0 }
        var failures = 0, offViolations = 0, overlaps = 0
        for seed in seeds {
            let out = convergeRound(seed: seed)
            offViolations += out.offViolations; overlaps += out.overlaps
            if let why = out.failure {
                failures += 1
                if failures <= 3 { print("  (seed \(seed): \(why)\n   steps: \(out.steps.joined(separator: " "))") }
            }
        }
        check(failures == 0, "\(seeds.count) random interleavings: every live process on the last saved, and a next one opens with it (\(failures) not)")
        check(offViolations == 0, "\(seeds.count) random interleavings: no configuration ever reached the helper while it held cloud models off (\(offViolations))")
        check(overlaps == 0, "\(seeds.count) random interleavings: never two set_configs in flight to one session (\(overlaps))")
    }

    /// The seed's dice (one thread: the round's).
    final class Dice {
        private var rng: SplitMix
        init(_ seed: UInt64) { rng = SplitMix(seed: seed) }
        func roll(_ n: UInt64) -> UInt64 { rng.next() % n }
    }

    /// One round of settingsConvergeTests' interleavings, from `seed` alone: the steps taken (named), and the first
    /// check that failed, naming where it stood.
    static func convergeRound(seed: UInt64) -> (failure: String?, steps: [String], offViolations: Int, overlaps: Int) {
        let dice = Dice(seed)
        let roll = dice.roll
        let values: [(String, ResolvedLang)] = [("A", .zhHans), ("B", .en), ("C", .zhHans), ("openai:custom| D ", .en)]
        let r = Rig()
        var steps: [String] = []
        var saves = 0
        r.h.duringOpen = { [unowned r] _ in if roll(2) == 0 { steps.append("(start before reply)"); r.h.deliverAll(r.m.client) } }
        // (set_configs: now and then busy, or no answer — the client retries)
        r.h.chaos = { switch roll(12) { case 0: return 1; case 1: return 2; case 2: return 3; default: return 0 } }
        // (now and then the switch turns off while a set_config is in flight: the store, the client, the push — queued
        // as the switch's next step, so models.off reaches the helper after it)
        r.h.whileConfig = { [unowned r] in
            // (now and then a save whose work runs while a set_config is out: its converge finds one in flight)
            if saves < 6, roll(8) == 0 {
                let v = values[Int(roll(UInt64(values.count)))]
                steps.append("(save(\(v.0.trimmingCharacters(in: .whitespaces))) mid-send)")
                r.save(v.0, v.1); saves += 1
                if r.pending > 0 { r.runWork(at: r.pending - 1) }
            }
            guard r.store.cloud, roll(8) == 0 else { return }
            steps.append("(off mid-send)")
            r.store.setCloud(false); r.m.client.modelOff = true; r.m.client.modelsSync.push()
        }
        for _ in 0..<24 {
            switch roll(13) {
            case 0 where saves < 6:
                let v = values[Int(roll(UInt64(values.count)))]; steps.append("save(\(v.0.trimmingCharacters(in: .whitespaces)),\(v.1 == .en ? "en" : "zh"))")
                r.save(v.0, v.1); saves += 1
            case 1 where r.pending > 0: let i = Int(roll(UInt64(r.pending))); steps.append("work[\(i)]"); r.runWork(at: i)
            case 2: if !r.m.opening && r.store.cloud { steps.append("new"); r.newConversation() }
            case 3: steps.append("deliver"); r.h.deliver(r.m.client)
            case 4:
                let ids = r.h.live.keys.sorted()
                if !ids.isEmpty { let id = ids[Int(roll(UInt64(ids.count)))]; steps.append("exit(\(id))"); r.h.exit(id) }
            case 5: steps.append("deliver-swapped"); r.h.deliver(r.m.client, swap: true)
            case 6: steps.append("deliver-again"); r.h.deliver(r.m.client, duplicate: true)
            case 7: steps.append(r.store.cloud ? "cloud-off" : "cloud-on"); r.cloud(!r.store.cloud)
            case 8 where roll(3) == 0:
                steps.append("helper-restart")
                r.h.restart()                                        // (the helper restarts; the watch comes back)
                r.h.deliverAll(r.m.client)
                for id in r.m.client.liveIds() { _ = r.m.client.reopenIfExited(id) }
            case 9: if r.steps.run("off") { steps.append("models.off") }
            case 10:
                let n = r.steps.count("retry")
                if n > 0 { let i = Int(roll(UInt64(n))); steps.append("retry[\(i)]"); r.steps.run("retry", at: i) }
            default: if r.steps.run("reconcile") { steps.append("reconcile") }
            }
        }
        r.h.whileConfig = nil                                        // (the oracle's own steps below: no flips)
        if !r.store.cloud && roll(2) == 0 { steps.append("cloud-on"); r.cloud(true) }
        func fail(_ why: String) -> (failure: String?, steps: [String], offViolations: Int, overlaps: Int) {
            (why, steps, r.h.offViolations, r.h.overlaps)
        }
        guard r.settle() else { return fail("never settled (a loop): live \(r.h.live)") }
        if !r.converged() { return fail("after settle: live \(r.h.live), saved \(r.store.expected)") }
        if !r.m.client.settingsStranded.isEmpty { return fail("stranded: \(r.m.client.settingsStranded)") }
        // converged: nothing more goes (no set_config after convergence); a save then sends each process one, answered
        // as asked (no chaos from here: a busy or a lost reply is owed one more)
        r.h.lock.lock(); r.h.chaos = nil; r.h.lock.unlock()
        let sent = r.h.configSends
        r.m.client.convergeAll(); r.settle()
        let live = r.h.live.count
        if r.h.configSends - sent > live { return fail("after convergence, a save's converge sent \(r.h.configSends - sent) set_configs to \(live) processes") }
        let after = r.h.configSends
        r.settle()
        if r.h.configSends != after { return fail("converged, and still sending: \(r.h.configSends - after) set_configs with no trigger") }
        // a next process: one that ended opens again with the last saved
        if let id = r.m.client.liveIds().first(where: { r.h.live[$0] != nil }) {
            r.h.exit(id); r.h.deliverAll(r.m.client)
            _ = r.m.client.reopenIfExited(id)
            r.settle()
            let want = r.store.expected
            if !((r.h.lastOpen?["config"] as? String) == want.config && r.h.lastOpen?["lang"] as? String == want.lang) {
                return fail("reopen line \(String(describing: r.h.lastOpen)), saved \(want)")
            }
            if !r.converged() { return fail("after the reopen: live \(r.h.live), saved \(want)") }
        }
        return (nil, steps, r.h.offViolations, r.h.overlaps)
    }

    /// #107 delta review of a9117a7: what a session applies is held only from evidence about its current process, and
    /// unknown whenever that is missing or contradicted.
    static func evidenceTests() {
        func configs(_ mock: Mock) -> [[String: Any]] {
            mock.requests.compactMap { $0["line"] as? [String: Any] }.filter { $0["type"] as? String == "set_config" }
        }
        // B1: a late duplicate of an old session.config is no evidence: A, B saved (and taken), config(A)@1 again, A
        // saved — A is sent
        do {
            let mock = Mock()
            mock.replies = [SessionClient.Op.send: ["ok": true]]
            let c = SessionClient(transport: mock)
            c.adoptSettings(config: "A", lang: "zh")
            c.feed(["kind": "session.start", "session_id": "s", "resumed": false, "last_seq": 0])
            c.feed(["kind": "session.config", "session_id": "s", "seq": 1, "config": "A", "lang": "zh", "by": "open"])
            c.reconciling.wait()
            c.adoptSettings(config: "B", lang: "zh"); c.convergeAll()
            c.feed(["kind": "session.config", "session_id": "s", "seq": 1, "config": "A", "lang": "zh", "by": "open"])   // (a replay)
            mock.requests = []
            c.adoptSettings(config: "A", lang: "zh"); c.convergeAll()
            check(configs(mock).last?["config"] as? String == "A", "B1: a duplicate config(A) is no evidence: saving A again sends A: \(configs(mock))")
        }
        // B2: held equal to desired (wrongly), then a no_model refusal: unknown — the configuration is sent
        do {
            let mock = Mock()
            mock.replies = [SessionClient.Op.send: ["ok": true], "models.off": ["ok": true]]
            let steps = Steps()                                   // (its push and reconciles run before the check)
            let c = steps.client(mock)
            c.adoptSettings(config: "A", lang: "zh")
            c.feed(["kind": "session.start", "session_id": "s", "resumed": false, "last_seq": 0])
            c.feed(["kind": "session.config", "session_id": "s", "seq": 1, "config": "A", "lang": "zh", "by": "open"])
            steps.drain()
            mock.requests = []
            c.feed(["kind": "session.error", "session_id": "s", "code": "no_model", "control": "say", "text": "x"])
            steps.drain()
            check(configs(mock).contains { $0["config"] as? String == "A" }, "B2: after no_model, the configuration is sent again: \(configs(mock))")
        }
        // E1: newer evidence while a set_config is out (another's set_config, stored) is not overwritten by its reply
        do {
            final class Held: SessionTransport {
                let gate = DispatchSemaphore(value: 0), inConfig = DispatchSemaphore(value: 0)
                let lock = NSLock()
                var hold = false, log: [[String: Any]] = []
                func request(_ body: [String: Any]) -> [String: Any]? {
                    lock.lock(); log.append(body)
                    let h = hold && (body["line"] as? [String: Any])?["type"] as? String == "set_config"; if h { hold = false }
                    lock.unlock()
                    if h { inConfig.signal(); gate.wait() }
                    return ["ok": true]
                }
                func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool { false }
            }
            let t = Held()
            let c = SessionClient(transport: t)
            c.adoptSettings(config: "A", lang: "zh")
            c.feed(["kind": "session.start", "session_id": "s", "resumed": false, "last_seq": 0])
            c.feed(["kind": "session.config", "session_id": "s", "seq": 1, "config": "A", "lang": "zh", "by": "open"])
            c.reconciling.wait()
            c.adoptSettings(config: "B", lang: "zh")
            t.lock.lock(); t.hold = true; t.lock.unlock()
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { c.convergeAll(); done.signal() }        // (B on its way, held)
            t.inConfig.wait()
            c.feed(["kind": "session.config", "session_id": "s", "seq": 2, "config": "C", "lang": "zh", "by": "set_config"])  // (set by another, meanwhile)
            t.gate.signal(); done.wait(); c.reconciling.wait()
            t.lock.lock(); t.log = []; t.lock.unlock()
            c.convergeAll()
            t.lock.lock(); let again = t.log.compactMap { $0["line"] as? [String: Any] }.filter { $0["type"] as? String == "set_config" }; t.lock.unlock()
            check(again.last?["config"] as? String == "B", "E1: the C that came while B went stands (not overwritten by B's reply): B sent again: \(again)")
        }
        // E2: the switch on its way to the helper (turning off): a session with no evidence that comes into view gets no
        // configuration while it goes; after the ack, null
        do {
            final class SlowOff: SessionTransport {
                let lock = NSLock(), gate = DispatchSemaphore(value: 0), inOff = DispatchSemaphore(value: 0)
                var log: [[String: Any]] = []
                func request(_ body: [String: Any]) -> [String: Any]? {
                    lock.lock(); log.append(body); lock.unlock()
                    if body["op"] as? String == "models.off" { inOff.signal(); gate.wait() }
                    return ["ok": true]
                }
                func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool { false }
            }
            let t = SlowOff()
            let box = NSLock()
            var engineOff = false
            let sync = ModelsOffSync(transport: t, current: { box.lock(); defer { box.unlock() }; return engineOff })
            let c = SessionClient(transport: t, modelsSync: sync)
            c.adoptSettings(config: "ds-flash", lang: "zh")
            sync.push()                                                   // (the switch going, still on)
            t.inOff.wait()
            c.feed(["kind": "session.start", "session_id": "k", "resumed": true, "last_seq": 0])    // (in view, nothing known)
            c.reconciling.wait()
            box.lock(); engineOff = true; box.unlock()                     // (turned off while it goes)
            t.gate.signal()
            DispatchQueue.global().async { while true { if t.inOff.wait(timeout: .now() + 3) == .timedOut { break }; t.gate.signal() } }
            sync.settle(timeout: 5); c.reconciling.wait()
            t.lock.lock(); let cfgs = t.log.compactMap { $0["line"] as? [String: Any] }.filter { $0["type"] as? String == "set_config" }; t.lock.unlock()
            check(!cfgs.contains { $0["config"] is String } && cfgs.last?["config"] is NSNull,
                  "E2: no configuration while the switch went (it turned off), then null: \(cfgs.map { $0["config"] ?? "" })")
        }
        // the start trigger: a session this client knew (exited) is opened elsewhere with the last stored (A); B was
        // saved while it had no process — its start converges it to B
        do {
            let mock = Mock()
            mock.replies = [SessionClient.Op.send: ["ok": true]]
            let c = SessionClient(transport: mock)
            c.adoptSettings(config: "A", lang: "zh")
            c.feed(["kind": "session.start", "session_id": "s", "resumed": false, "last_seq": 0])
            c.feed(["kind": "session.config", "session_id": "s", "seq": 1, "config": "A", "lang": "zh", "by": "open"])
            c.feed(["kind": "helper.session_exit", "session_id": "s", "code": 0])
            c.reconciling.wait()
            c.adoptSettings(config: "B", lang: "zh"); c.convergeAll()     // (no process: nothing to send)
            mock.requests = []
            c.feed(["kind": "session.start", "session_id": "s", "resumed": true, "last_seq": 1])    // (opened elsewhere)
            c.reconciling.wait()
            check(configs(mock).last?["config"] as? String == "B", "a start of a known session (opened elsewhere): converged to B: \(configs(mock))")
        }
    }

    /// #107 review at 00df2f8: the four ways racing evidence left a process on old settings, each now a deterministic
    /// test. The oracle is what a one-process helper below runs (every set_config it is written, busy or not, takes
    /// effect), never the client's own bookkeeping.
    final class OneProcess: SessionTransport {
        let lock = NSLock()
        var value: (config: String?, lang: String?) = (nil, nil)
        var sent: [[String: Any]] = []
        /// Per set_config, by its number (1, 2, …): nil = no answer (not applied).
        var noAnswer: Set<Int> = []
        func request(_ body: [String: Any]) -> [String: Any]? {
            lock.lock(); defer { lock.unlock() }
            guard let l = body["line"] as? [String: Any], l["type"] as? String == "set_config" else { return ["ok": true] }
            sent.append(l)
            if noAnswer.contains(sent.count) { return nil }
            value = (l["config"] as? String, l["lang"] as? String)
            return ["ok": true]
        }
        func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool { false }
        var runs: (config: String?, lang: String?) { lock.lock(); defer { lock.unlock() }; return value }
        var lastId: String { lock.lock(); defer { lock.unlock() }; return sent.last?["client_id"] as? String ?? "" }
        var sentConfigs: [String] { lock.lock(); defer { lock.unlock() }; return sent.map { ($0["config"] as? String) ?? "null" } }
    }

    static func dirtyFlagTests() {
        // Each client's reconciles, retries and switch pushes are this test's steps, and settle runs every one of them on
        // this thread — a retry's send included — before any check (deskmind#112: a poll of retriesPending reached zero
        // while a retry was still sending, and P3 read B).
        let steps = Steps()
        func newClient(_ t: SessionTransport) -> SessionClient { steps.client(t) }
        func settle(_ c: SessionClient) {
            let done = steps.drain()
            check(done && steps.pending == 0 && c.retriesPending == 0 && c.settingsStranded.isEmpty,
                  "(settled: nothing queued, no retry waiting, none stranded)")
        }
        // P1: a null held past a gap, applied when the gap fills (the switch on): the configuration is sent
        do {
            let t = OneProcess()
            let c = newClient(t)
            c.adoptSettings(config: "A", lang: "zh")
            c.feed(["kind": "session.start", "session_id": "s", "resumed": false, "last_seq": 0])
            c.feed(["kind": "session.config", "session_id": "s", "seq": 1, "config": "A", "lang": "zh", "by": "open"])
            settle(c)
            c.feed(["kind": "session.config", "session_id": "s", "seq": 3, "config": NSNull(), "lang": "zh", "by": "set_config"])  // (held)
            settle(c)
            t.lock.lock(); t.value = (nil, "zh"); t.lock.unlock()                // (the helper nulled it: what @3 says)
            c.feed(["kind": "session.config", "session_id": "s", "seq": 2, "config": "A", "lang": "zh", "by": "set_config", "client_id": "other"])
            settle(c)
            check(t.runs.config == "A", "P1: a held null applied when its gap fills: the configuration sent again (\(t.sentConfigs))")
        }
        // P3: busy on the first send; C saved; the second send gets no answer — retried until it is taken
        do {
            let t = OneProcess()
            t.noAnswer = [3]
            let c = newClient(t)
            c.adoptSettings(config: "A", lang: "zh")
            c.feed(["kind": "session.start", "session_id": "s", "resumed": false, "last_seq": 0])
            settle(c)                                                           // (1: A)
            c.adoptSettings(config: "B", lang: "zh"); c.convergeAll()            // (2: B, answered busy below)
            let cid = t.lastId
            c.adoptSettings(config: "C", lang: "zh")                             // (C saved)
            c.feed(["kind": "session.error", "session_id": "s", "code": "busy", "control": "set_config", "client_id": cid, "text": "busy"])
            settle(c)                                                           // (3: C, no answer; then again)
            check(t.runs.config == "C" && c.retriesPending == 0, "P3: busy, then a send with no answer: retried until C is taken (\(t.sentConfigs))")
            // (#107's invariant, exactly: one send per trigger, the unanswered one retried once, nothing after C is taken)
            check(t.sentConfigs == ["A", "B", "C", "C"], "P3: A, B (busy), C (no answer), C again — and no more (\(t.sentConfigs))")
            c.convergeAll(); settle(c); settle(c)
            check(t.sentConfigs == ["A", "B", "C", "C", "C"], "P3: converged, a save sends once and nothing follows (\(t.sentConfigs))")
        }
        // P3, the retry held (deskmind#112, Codex at 1dabf22): the 4th attempt — the retry of the unanswered C — held at
        // afterSnapshot, between its read and its send. Settle must not return before it is sent: C is what runs.
        do {
            let t = OneProcess()
            t.noAnswer = [3]
            let c = newClient(t)
            c.afterSnapshot = { _ in if t.sentConfigs.count == 3 { usleep(50_000) } }      // (held: the retry, read, not sent)
            c.adoptSettings(config: "A", lang: "zh")
            c.feed(["kind": "session.start", "session_id": "s", "resumed": false, "last_seq": 0])
            settle(c)
            c.adoptSettings(config: "B", lang: "zh"); c.convergeAll()
            let cid = t.lastId
            c.adoptSettings(config: "C", lang: "zh")
            c.feed(["kind": "session.error", "session_id": "s", "code": "busy", "control": "set_config", "client_id": cid, "text": "busy"])
            settle(c)
            check(t.runs.config == "C" && t.sentConfigs == ["A", "B", "C", "C"],
                  "P3 held: the retry held between its read and its send — settled only after it went: C runs (\(t.sentConfigs))")
        }
        // P4: stored A; B saved and a reopen with B; A saved back while the open is out, its start heard before the reply;
        // then the harness's by:open B — the process ends on A
        do {
            final class Reopen: SessionTransport {
                let p = OneProcess()
                var during: (() -> Void)?
                func request(_ body: [String: Any]) -> [String: Any]? {
                    if body["op"] as? String == SessionClient.Op.open {
                        p.lock.lock(); p.value = (body["config"] as? String, body["lang"] as? String); p.lock.unlock()
                        let d = during; during = nil; d?()
                        return ["ok": true, "session_id": "s", "last_seq": 1]
                    }
                    return p.request(body)
                }
                func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool { false }
            }
            let t = Reopen()
            let c = newClient(t)
            c.adoptSettings(config: "A", lang: "zh")
            c.feed(["kind": "session.start", "session_id": "s", "resumed": false, "last_seq": 0])
            c.feed(["kind": "session.config", "session_id": "s", "seq": 1, "config": "A", "lang": "zh", "by": "open"])
            c.feed(["kind": "helper.session_exit", "session_id": "s", "code": 0])
            settle(c)
            c.adoptSettings(config: "B", lang: "zh")
            t.during = {
                c.adoptSettings(config: "A", lang: "zh"); c.convergeAll()
                c.feed(["kind": "session.start", "session_id": "s", "resumed": true, "last_seq": 1])
                steps.drain()
            }
            _ = c.open(sessionId: "s")
            settle(c)
            c.feed(["kind": "session.config", "session_id": "s", "seq": 2, "config": "B", "lang": "zh", "by": "open"])
            settle(c)
            check(t.p.runs.config == "A", "P4: opened with B, A saved back during the open, its start before the reply: the process on A (\(t.p.sentConfigs))")
        }
        // the 150 interleavings' trace (bug 3): cloud off, (null, en) sent and answered busy (it runs en); a late start; the
        // open-time (null, zh) row; the busy reply; zh saved — the process ends on (null, zh)
        do {
            let t = OneProcess()
            let c = newClient(t)
            c.modelOff = true
            c.adoptSettings(config: "A", lang: "en")
            c.feed(["kind": "session.start", "session_id": "s", "resumed": false, "last_seq": 0])
            settle(c)                                                           // ((null, en) sent: it runs en)
            let cid = t.lastId
            c.feed(["kind": "session.start", "session_id": "s", "resumed": false, "last_seq": 0])   // (its start, late)
            settle(c)
            c.feed(["kind": "session.config", "session_id": "s", "seq": 1, "config": NSNull(), "lang": "zh", "by": "set_config"])
            c.feed(["kind": "session.error", "session_id": "s", "code": "busy", "control": "set_config", "client_id": cid, "text": "busy"])
            settle(c)
            c.adoptSettings(config: "A", lang: "zh"); c.convergeAll()            // (zh saved)
            settle(c)
            check(t.runs.config == nil && t.runs.lang == "zh", "bug 3: a late start, an old row, a busy reply, zh saved: the process on (null, zh) (\(t.runs))")
        }
    }

    /// A helper as the review of 187ae8e probed it: its set_configs and models.offs in order; optionally trimming a model
    /// name as the harness does (normalizeConfig), slow set_configs, a models.off held until released.
    final class GateHelper: SessionTransport {
        let lock = NSLock()
        var lines: [[String: Any]] = []
        var seq = 0
        var configs: [String] = []
        var events: [String] = []
        /// What the helper does to a config before it applies and stores it (the harness: harnessNormalize; nil: nothing).
        var normalize: ((String) -> String)?
        var holdModelsOff: DispatchSemaphore?
        let modelsOffEntered = DispatchSemaphore(value: 0)
        var configDelayUs: UInt32 = 0
        /// Signalled when a set_config reaches it (before its delay): a test's sync point, not a sleep (deskmind#112).
        let configEntered = DispatchSemaphore(value: 0)
        var offAt: Date?
        func request(_ body: [String: Any]) -> [String: Any]? {
            let op = body["op"] as? String ?? ""
            if op == SessionClient.Op.modelsOff {
                modelsOffEntered.signal()
                holdModelsOff?.wait()
                lock.lock(); events.append("models.off(\(body["off"] as? Bool ?? false))"); offAt = Date(); lock.unlock()
                return ["ok": true]
            }
            guard let l = body["line"] as? [String: Any], l["type"] as? String == "set_config" else { return ["ok": true] }
            configEntered.signal()
            if configDelayUs > 0 { usleep(configDelayUs) }
            lock.lock(); defer { lock.unlock() }
            var cfg = l["config"] as? String
            configs.append(cfg ?? "null"); events.append("set_config(\(cfg ?? "null"))")
            if let n = normalize, let c = cfg { cfg = n(c) }
            seq += 1
            lines.append(["kind": "session.config", "session_id": body["session_id"] as? String ?? "s", "seq": seq,
                          "config": cfg as Any? ?? NSNull(), "lang": l["lang"] ?? "zh", "by": "set_config", "client_id": l["client_id"] ?? ""])
            return ["ok": true]
        }
        func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool { false }
        func deliverAll(_ c: SessionClient) {
            while true {
                lock.lock(); guard !lines.isEmpty else { lock.unlock(); return }; let l = lines.removeFirst(); lock.unlock()
                c.feed(l)
            }
        }
        var sent: [String] { lock.lock(); defer { lock.unlock() }; return configs }
        var order: [String] { lock.lock(); defer { lock.unlock() }; return events }
    }

    /// #107 review at 187ae8e: the echo of a model name saved with spaces (R1), the switch gate's window (R2), a models.off
    /// after a configuration in flight (R5), the helper's last ack of "off" (R6).
    static func switchGateTests() {
        // R1: desired keeps the spaces an older version saved; the harness trims before it stores: its echo equals desired
        // once normalised — no set_config every round
        do {
            let h = GateHelper(); h.normalize = harnessNormalize
            let steps = Steps()
            let c = steps.client(h)
            c.adoptSettings(config: "openai:custom| gpt-4o ", lang: "zh")
            c.feed(["kind": "session.start", "session_id": "s", "resumed": false, "last_seq": 0])
            for _ in 0..<200 { steps.drain(); h.deliverAll(c); steps.drain() }
            check(h.sent.count <= 2 && h.sent.first == "openai:custom|gpt-4o",
                  "R1: an untrimmed model name: sent normalised, its echo no trigger — \(h.sent.count) sends in 200 rounds")
        }
        // R2: a converge blocked by a pending push; the push's ack (and its converge) lands between the gate's check and
        // the blocked branch's cleanup — the session is not left dirty with nothing scheduled
        do {
            let h = GateHelper()
            let steps = Steps()                    // (reconciles and retries: steps; the switch's push: its real queue)
            let c = SessionClient(transport: h)
            c.reconcileWork = steps.lane("reconcile"); c.retryWork = steps.lane("retry")
            final class Box { let lock = NSLock(); var value = "A"; var hook: (() -> Void)? }
            let box = Box()
            c.settingsSource = {
                box.lock.lock(); let v = box.value; let f = box.hook; box.hook = nil; box.lock.unlock()
                f?()
                return (v, "zh")
            }
            c.feed(["kind": "session.start", "session_id": "s", "resumed": false, "last_seq": 0])
            c.modelsSync.settle(timeout: 5); steps.drain(); h.deliverAll(c); steps.drain()
            h.holdModelsOff = DispatchSemaphore(value: 0)
            c.modelsSync.push()
            h.modelsOffEntered.wait()                                     // (the push pending, held in the helper)
            box.lock.lock()
            box.value = "B"
            box.hook = {                                                  // (read by the blocked converge: the ack lands now)
                h.holdModelsOff?.signal()
                c.modelsSync.settle(timeout: 10)                          // (acked: its converge queued)
                steps.drain("reconcile")                                  // (and run now: it finds this send in flight)
            }
            box.lock.unlock()
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { c.convergeAll(); done.signal() }     // (B saved while the push is pending)
            done.wait()
            steps.drain()
            check(h.sent.last == "B", "R2: the ack in the gate's window: B still sent (\(h.sent))")
        }
        // R5: a configuration in flight (a slow helper) when cloud is turned off: models.off reaches the helper after it
        do {
            let h = GateHelper(); h.configDelayUs = 300_000
            let c = SessionClient(transport: h)
            c.adoptSettings(config: "A", lang: "zh")
            c.feed(["kind": "session.start", "session_id": "s", "resumed": false, "last_seq": 0])
            c.reconciling.wait()
            h.lock.lock(); h.events = []; h.lock.unlock()
            while h.configEntered.wait(timeout: .now()) == .success {}    // (the start's own set_config: answered)
            let g = DispatchGroup(); g.enter()
            DispatchQueue.global().async { c.convergeAll(); g.leave() }
            check(h.configEntered.wait(timeout: .now() + 10) == .success, "(R5: the set_config reached the helper, slow)")
            c.modelOff = true; c.modelsSync.push()
            g.wait(); c.modelsSync.settle(timeout: 2); c.reconciling.wait()
            let o = h.order
            check(o.firstIndex(of: "set_config(A)").map { i in o.firstIndex(of: "models.off(true)").map { i < $0 } ?? false } == true,
                  "R5: cloud off while a configuration is in flight: models.off after it (\(o))")
        }
        // R5b: the bound — a configuration still out when it passes: models.off goes anyway (the helper keeps the order)
        do {
            let h = GateHelper(); h.configDelayUs = 1_200_000
            let c = SessionClient(transport: h)
            c.modelsSync.offWaitBound = 0.3
            c.adoptSettings(config: "A", lang: "zh")
            c.feed(["kind": "session.start", "session_id": "s", "resumed": false, "last_seq": 0])
            let g = DispatchGroup(); g.enter()
            DispatchQueue.global().async { c.reconciling.wait(); g.leave() }
            check(h.configEntered.wait(timeout: .now() + 10) == .success, "(R5b: the set_config reached the helper, slow)")
            let pushed = Date()
            c.modelOff = true; c.modelsSync.push()
            c.modelsSync.settle(timeout: 3)
            let waited = (h.offAt ?? .distantFuture).timeIntervalSince(pushed)
            check(waited >= 0.25 && waited < 1.0 && h.order.first == "models.off(true)",
                  "R5b: models.off waits for a configuration in flight up to its bound, then goes (\(String(format: "%.2f", waited)) s, \(h.order))")
            g.wait()
        }
        // R6: the helper acked off; the app's switch reads on before its push begins: no configuration until that push's ack
        do {
            let h = GateHelper()
            let steps = Steps()                                           // (its pushes, reconciles, retries: run in turn)
            let c = steps.client(h)
            c.adoptSettings(config: "A", lang: "zh")
            c.modelOff = true; c.modelsSync.push(); steps.drain()
            c.feed(["kind": "session.start", "session_id": "s", "resumed": false, "last_seq": 0])
            steps.drain()
            h.lock.lock(); h.configs = []; h.lock.unlock()
            c.modelOff = false; c.convergeAll()
            steps.drain("reconcile")
            let before = h.sent
            c.modelsSync.push(); steps.drain()
            check(!before.contains { $0 != "null" } && h.sent.contains("A"),
                  "R6: the helper holds off, the app's switch on before its push: nothing sent, then A after the ack (\(before) → \(h.sent))")
        }
    }

    /// The harness's normalizeConfig, ported here by hand and apart from the app's (SessionClient.normalizeConfig), so
    /// that the fake helpers do not check the app against itself: /^openai:([a-z]+)\|([\s\S]*)$/, the model String.trim()'d
    /// — JavaScript's WhiteSpace and LineTerminator code points, listed below.
    static func harnessNormalize(_ spec: String) -> String {
        let scalars = Array(spec.unicodeScalars)
        let head = Array("openai:".unicodeScalars)
        guard scalars.count > head.count, Array(scalars[..<head.count]) == head else { return spec }
        var i = head.count
        while i < scalars.count, scalars[i].value >= 0x61, scalars[i].value <= 0x7A { i += 1 }
        guard i > head.count, i < scalars.count, scalars[i] == "|" else { return spec }
        func jsSpace(_ s: Unicode.Scalar) -> Bool {
            switch s.value {
            case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
            default: return false
            }
        }
        var model = Array(scalars[(i + 1)...])
        while let f = model.first, jsSpace(f) { model.removeFirst() }
        while let l = model.last, jsSpace(l) { model.removeLast() }
        var out = String.UnicodeScalarView(); out.append(contentsOf: scalars[...i]); out.append(contentsOf: model)
        return String(out)
    }

    /// #107 review at 32c458b: normalisation as the harness does it, from its own code (a table node generated from
    /// harness 0bbabd4: tests/fixtures/normalize-config.json); a U+FEFF that looped; the guard that keeps any normalisation
    /// the app does not share from looping, while a real change still triggers.
    static func normalizeTests() {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tests/fixtures/normalize-config.json")
        let table = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any])?["cases"] as? [[String: String]] ?? []
        let appWrong = table.filter { SessionClient.normalizeConfig($0["input"]!) != $0["output"]! }
        let portWrong = table.filter { harnessNormalize($0["input"]!) != $0["output"]! }
        check(table.count >= 50 && appWrong.isEmpty && portWrong.isEmpty,
              "normalizeConfig as the harness's own (\(table.count) cases; the app's wrong on \(appWrong.map { $0["input"]!.unicodeScalars.map { String($0.value, radix: 16) } }), the test port on \(portWrong.count))")
        // a saved name: trimmed of JavaScript's set and Foundation's (U+0085 too) — clean, and the harness's normalisation
        // (the table's own function, here its port) leaves it as it is (#107 review at b8d2acf: a kept U+0085 failed the
        // harness's model-id check)
        for typed in ["\u{FEFF}gpt-4o\u{00A0}", "\u{0085}gpt-4o", "gpt-4o\u{0085}\u{FEFF}", " gpt-4o\n"] {
            let saved = ModelChoice.modelName(typed)
            check(saved == "gpt-4o" && harnessNormalize("openai:custom|" + saved) == "openai:custom|" + saved,
                  "a model name saved clean (\(typed.unicodeScalars.map { String($0.value, radix: 16) })): \(saved.unicodeScalars.map { String($0.value, radix: 16) })")
        }
        let zw = ModelChoice.modelName("gpt-4o\u{200B}")       // (Foundation takes a zero-width space; trim() would not)
        check(harnessNormalize("openai:custom|" + zw) == "openai:custom|" + zw, "a zero-width space: the saved name, as the harness reads it, unchanged")
        check(SessionClient.normalizeConfig("openai:custom|\u{0085}x") == "openai:custom|\u{0085}x", "normalizeConfig stays JavaScript's set (U+0085 kept)")
        // the FEFF loop: a name pasted with U+FEFF, a harness that trims it — its echo is no trigger
        do {
            let h = GateHelper(); h.normalize = harnessNormalize
            let steps = Steps()
            let c = steps.client(h)
            c.adoptSettings(config: "openai:custom|gpt-4o\u{FEFF}", lang: "zh")
            c.feed(["kind": "session.start", "session_id": "s", "resumed": false, "last_seq": 0])
            for _ in 0..<200 { steps.drain(); h.deliverAll(c); steps.drain() }
            check(h.sent.count <= 2 && h.sent.first == "openai:custom|gpt-4o", "a U+FEFF in the model name: \(h.sent.count) sends in 200 rounds")
        }
        // the guard: a helper that normalises what the app does not (drops a trailing "!") — its echo is ours and not
        // desired: at most one more send, no loop; a real null from it (not ours) still repaired
        do {
            let h = GateHelper()
            h.normalize = { $0.hasSuffix("!") ? String($0.dropLast()) : $0 }
            let steps = Steps()
            let c = steps.client(h)
            c.adoptSettings(config: "openai:custom|M!", lang: "zh")
            c.feed(["kind": "session.start", "session_id": "s", "resumed": false, "last_seq": 0])
            for _ in 0..<200 { steps.drain(); h.deliverAll(c); steps.drain() }
            let looped = h.sent.count
            h.lock.lock(); h.seq += 1; let n = h.seq; h.lock.unlock()
            c.feed(["kind": "session.config", "session_id": "s", "seq": n, "config": NSNull(), "lang": "zh", "by": "set_config"])  // (the helper's)
            steps.drain()
            check(looped <= 2 && h.sent.count == looped + 1 && h.sent.last == "openai:custom|M!",
                  "a normalisation the app does not share: \(looped) sends in 200 rounds (no loop); a real null after it: sent again (\(h.sent))")
        }
    }

    /// #107 review at 9c59a1f (Codex): the switch read while off for the value, then on; the on-ack's converge ran while
    /// this send held the session — a configuration still reaches it (one read of settings and switch; one release path).
    static func oneReadTests() {
        final class T: SessionTransport {
            let lock = NSLock(); var configs: [String] = []
            func request(_ body: [String: Any]) -> [String: Any]? {
                if let l = body["line"] as? [String: Any], l["type"] as? String == "set_config" {
                    lock.lock(); configs.append((l["config"] as? String) ?? "null"); lock.unlock()
                }
                return ["ok": true]
            }
            func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool { false }
            var sent: [String] { lock.lock(); defer { lock.unlock() }; return configs }
        }
        final class Switch { let lock = NSLock(); var off = true; func read() -> Bool { lock.lock(); defer { lock.unlock() }; return off } }
        let t = T(), sw = Switch()
        let steps = Steps()                    // (the sync's sends and the client's reconciles: run in turn, deskmind#112)
        let sync = steps.sync(t, current: { sw.read() })
        let c = steps.client(t, modelsSync: sync)
        c.adoptSettings(config: "A", lang: "zh")
        sync.push(); steps.drain()                                             // (the helper holds off)
        c.feed(["kind": "session.start", "session_id": "s", "resumed": false, "last_seq": 0])
        steps.drain()
        // a save: its converge reads the settings and the switch (off) — then, before it sends, the switch turns on, its
        // push is acked and the ack's converge runs, finding this session in flight
        let fired = NSLock(); var once = true
        c.afterSnapshot = { _ in
            fired.lock(); let go = once; once = false; fired.unlock()
            guard go else { return }
            sw.lock.lock(); sw.off = false; sw.lock.unlock()
            sync.push(); sync.settle()                  // (the push acked, and the ack's converge run: it finds this send)
        }
        c.convergeAll()
        steps.drain()
        c.afterSnapshot = nil
        check(t.sent.last == "A" && c.settingsStranded.isEmpty,
              "the switch read off, then on and acked during the send: A still reaches the session (\(t.sent); stranded \(c.settingsStranded))")
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    // MARK: words

    static func textTests() {
        let e = SessionErrorEvent(code: "no_key", text: "DEEPSEEK_API_KEY is not set", replyTo: "m1")
        let row = ErrorRowModel(e, latest: true, idle: true, lang: .zhHans)
        check(row.showsSettings && row.showsRetry && row.headline == "模型没有 API 密钥", "no key: settings and retry")
        check(!ErrorRowModel(e, latest: false, idle: true, lang: .en).showsRetry, "an older error: no retry")
        check(!ErrorRowModel(SessionErrorEvent(code: "network", text: "", replyTo: "m1"), latest: true, idle: true, lang: .en).showsSettings, "network: no settings button")
        // a task's end says its status, never more
        var t = TaskState(runId: "r")
        t.done = TaskDone(status: "unconfirmed", reason: "", summary: "")
        check(ShellText.task(t, lang: .zhHans) == "做了，没能确认，请你看一下", "unconfirmed is not done")
        t.done = TaskDone(status: "stopped", reason: "", summary: "", cause: .lastStepUnknown)
        check(ShellText.task(t, lang: .en) == "Stopped. The last step may or may not have happened", "stopped mid-step")
        t.done = TaskDone(status: "succeeded", reason: "", summary: "")
        check(ShellText.task(t, lang: .en) == "Done", "succeeded: done")
        check(ShellText.status(.acting(step: 2, of: 5), lang: .zhHans) == "执行中 · 第 2 步，共 5 步", "acting with a plan")
    }
}
