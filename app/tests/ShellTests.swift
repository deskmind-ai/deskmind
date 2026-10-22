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
        flagTests()
        statusPriorityTests()
        composerTests()
        rowsTests()
        newConversationTests()
        queueTests()
        cardAnswerTests()
        deleteRenameTests()
        settingsTests()
        settingsOrderTests()
        cloudOffTests()
        cardBodyTests()
        focusTests()
        idleReclaimTests()
        historyTests()
        cloudOffNoModelTests()
        modelChoiceTests()
        cardWordsTests()
        settingsReopenTests()
        endRefusedTests()
        privacySwitchTests()
        cardHintTests()
        endMarkTests()
        backfillTests()
        languageTests()
        modelOffConfigTests()
        modelOffOpenTests()
        configBusyTests()
        noModelTests()
        modelNameTests()
        backfillOffStreamTests()
        historyWatchDownTests()
        hintOpenOnlyTests()
        historyOpenedCrashTests()
        textTests()
    }

    typealias Mock = SessionTests.MockTransport

    /// Defaults of a suite of their own, emptied: never the app's.
    static func scratchDefaults() -> UserDefaults {
        let name = "ai.deskmind.tests.shell.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// A model whose work and deliveries run inline, on a mock helper.
    static func model(_ mock: Mock, defaults: UserDefaults = scratchDefaults(), config: String? = "openai:local|fake",
                      lang: ResolvedLang = .zhHans) -> ShellModel {
        let client = SessionClient(transport: mock)
        client.newClientId = { "c_1" }
        return ShellModel(client: client, defaults: defaults, config: { config }, lang: { lang },
                          work: { $0() }, deliver: { $0() })
    }

    static func feed(_ m: ShellModel, _ name: String, upTo match: ((ProtocolLine) -> Bool)? = nil) {
        for l in SessionTests.lines(name) {
            m.client.feed(l)
            if let match, match(l) { break }
        }
    }

    static func sent(_ mock: Mock) -> [String: Any]? { mock.requests.last { $0["op"] as? String == SessionClient.Op.send }?["line"] as? [String: Any] }
    static func sends(_ mock: Mock) -> Int { mock.requests.filter { $0["op"] as? String == SessionClient.Op.send }.count }

    // MARK: the flag

    static func flagTests() {
        let d = scratchDefaults()
        check(!ShellFlag.isOn(d), "off by default")
        d.set(true, forKey: "ui05.shell")
        check(ShellFlag.isOn(d), "on once set (the View menu's switch)")
        d.set(false, forKey: ShellFlag.key)
        check(!ShellFlag.isOn(d), "off again")
    }

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

        // a card waits: no typing, Stop always
        let card = SessionTests.after("task-card", SessionTests.isKind("ask"))!
        let waiting = ComposerMode.of(card)
        check(!waiting.enabled && waiting.taskRunning && waiting.canStop, "a card waits: composer off, Stop on")
        check(waiting.control("顺便", sendNow: false) == nil && waiting.control("顺便", sendNow: true) == nil, "a card waits: neither key sends")

        // a task runs, no card: Enter queues (say), ⌘Enter steers
        let running = SessionTests.after("task-card", SessionTests.isKind("resumed"))!
        let r = ComposerMode.of(running)
        check(r.enabled && r.taskRunning, "a task runs without a card: typing")
        check(r.control("改成蓝色", sendNow: false) == .say("改成蓝色"), "Enter while a task runs: say (the session queues it)")
        check(r.control("改成蓝色", sendNow: true) == .steer("改成蓝色"), "⌘Enter while a task runs: steer")
        check(r.control("/cua 另一件事", sendNow: false) == .say("/cua 另一件事"), "/cua while a task runs: queued as typed (one task per session)")

        // the model: submit while a card waits sends nothing and keeps the text
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true]]
        let m = model(mock)
        feed(m, "task-card", upTo: SessionTests.isKind("ask"))
        m.selected = "ses_t"
        m.draft = "顺便说一句"
        m.submit()
        check(sends(mock) == 0 && m.draft == "顺便说一句", "a card waits: nothing sent, the text stays")
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
        // Enter while a task runs: a say (queued by the session), the composer emptied
        m.draft = "再补一句"
        m.submit()
        check(sent(mock) as NSDictionary? == ["type": "say", "text": "再补一句", "client_id": "c_1"] as NSDictionary && m.draft.isEmpty, "Enter: say, queued by the session")
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
        check(m.answering.isEmpty, "resumed: nothing on its way any more")
        // a card that takes words: its own field, answered with text
        let mock2 = Mock()
        mock2.replies = [SessionClient.Op.send: ["ok": true]]
        let q = model(mock2)
        feed(q, "task-question", upTo: SessionTests.isKind("ask"))
        q.selected = "ses_t"
        let (qrun, qopen) = q.states["ses_t"]!.openCard!
        let qcard = CardModel(card: qopen.card, runId: qrun, askId: qopen.askId)
        check(qcard.allowsFreeText, "the missing card takes words")
        q.cardBody(qcard, contentHeight: 40, visibleHeight: 40, offset: 0)   // (it has "you decide": words wait for its body)
        q.answer(qcard, text: "  明天下午三点  ")
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
        var config = "ds-flash"
        var lang = ResolvedLang.zhHans
        let client = SessionClient(transport: mock)
        let m = ShellModel(client: client, defaults: scratchDefaults(), config: { config }, lang: { lang }, work: { $0() }, deliver: { $0() })
        check(client.defaultConfig == "ds-flash" && client.defaultLang == "zh", "the client's defaults from the settings at once")
        config = "or-luna"; lang = .en
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
        DispatchQueue.global().async { c.restart("ses_t", config: "b", lang: "zh"); restartDone.signal() }
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
        var config = "provider-a"
        let m2 = ShellModel(client: SessionClient(transport: mock2), defaults: scratchDefaults(), config: { config }, lang: { .zhHans },
                            work: { $0() }, deliver: { $0() })
        m2.newConversation(); m2.draft = "你好"; m2.submit()
        check(mock2.requests.first { $0["op"] as? String == SessionClient.Op.open }?["config"] as? String == "provider-a", "opened with provider a")
        m2.client.feed(["kind": "session.start", "session_id": "ses_x", "resumed": false, "last_seq": 0])
        m2.client.feed(["kind": "helper.session_exit", "session_id": "ses_x", "code": 0])
        check(m2.states["ses_x"]?.exited != nil, "its process gone")
        config = "provider-b"
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
        var on = false
        let m = ShellModel(client: SessionClient(transport: mock), defaults: scratchDefaults(), config: { "ds-flash" }, lang: { .zhHans },
                           cloudOn: { on }, work: { $0() }, deliver: { $0() })
        m.refreshSettings()
        check(m.cloudOff, "cloud off: the chat's row says a conversation needs a cloud model")
        m.newConversation(); m.draft = "你好"; m.submit()
        check(mock.requests.isEmpty && m.draft == "你好" && m.notice != nil, "a new conversation: nothing opened, nothing sent, the text stays: \(mock.requests)")
        for l in SessionTests.lines("chat") { m.client.feed(l) }
        m.selected = "ses_t"; m.draft = "/cua 打开备忘录"; m.submit()
        m.retry()
        check(mock.requests.isEmpty, "an open session: no say, no cua, no retry")
        on = true
        m.settingsChanged()
        mock.requests = []
        m.submit()
        check(!m.cloudOff && sent(mock)?["type"] as? String == "cua", "cloud on again: the next send goes: \(String(describing: sent(mock)))")
    }

    /// #107 review (item 1): an approve-type option takes a click only once the card's whole body has been on screen —
    /// it fits, or it was scrolled to its end (the scroll geometry, never the text). The way out always works.
    static func cardBodyTests() {
        check(CardBody.endShown(contentHeight: 100, visibleHeight: 100, offset: 0), "a body that fits: its end is shown")
        check(!CardBody.endShown(contentHeight: 900, visibleHeight: 200, offset: 0), "a long body at its top: not")
        check(!CardBody.endShown(contentHeight: 900, visibleHeight: 200, offset: 650), "nearly at its end: not")
        check(CardBody.endShown(contentHeight: 900, visibleHeight: 200, offset: 700), "scrolled to its end")
        check(!CardBody.endShown(contentHeight: 0, visibleHeight: 0, offset: 0), "not laid out yet: not")
        check(CardBody.cap(columnHeight: 600) >= CardBody.minHeight && CardBody.cap(columnHeight: 600) <= 200 && CardBody.cap(columnHeight: 3000) == CardBody.maxHeight,
              "the body's cap: a share of the column, bounded: \(CardBody.cap(columnHeight: 600))")
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true]]
        let m = model(mock)
        feed(m, "task-card", upTo: SessionTests.isKind("ask"))
        m.selected = "ses_t"
        let s = m.states["ses_t"]!
        let (run, open) = s.openCard!
        let card = CardModel(card: open.card, runId: run, askId: open.askId)
        guard let approve = card.buttons.first(where: { $0.role == .approve }) else { check(false, "the fixture's card has an approve option"); return }
        check(!m.buttonEnabled(approve, card: card, in: s), "approve: off before the body was seen")
        m.click(approve)
        check(sends(mock) == 0, "a click on it then sends nothing")
        m.cardBody(card, contentHeight: 900, visibleHeight: 200, offset: 300)
        check(!m.buttonEnabled(approve, card: card, in: s), "half way down: still off")
        m.cardBody(card, contentHeight: 900, visibleHeight: 200, offset: 700)
        check(m.buttonEnabled(approve, card: card, in: s), "its end on screen: on")
        m.cardBody(card, contentHeight: 900, visibleHeight: 200, offset: 0)
        check(m.buttonEnabled(approve, card: card, in: s), "scrolled back up: stays on (it was all on screen)")
        m.click(approve)
        check(sent(mock)?["option"] as? Int == approve.index, "then the click sends the approve option")
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
    static func focusTests() {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Main/MainSplitView.swift")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { check(false, "Main/MainSplitView.swift readable from \(url.path)"); return }
        let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        let movers = ["@FocusState", ".focused(", "defaultFocus", "makeFirstResponder", "becomeFirstResponder", "prefersDefaultFocus", "focusScope", "FocusedValue"]
        let found = movers.filter { code.contains($0) }
        check(found.isEmpty, "the views set no focus anywhere (a card's field is focused only by the user's click): \(found)")
        check(code.contains("struct CardView") && code.contains("TextField(L(\"Or answer in your own words\""), "the check reads the card's own field's file")
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
        m.cardBody(card, contentHeight: 10, visibleHeight: 10, offset: 0)
        m.click(card.buttons.first { $0.role == .approve }!)
        check(sends(mock2) == 0, "cloud off: an approve (the task goes on, the model with it) is held back")
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

    /// #107 re-review (4): on a card with an approve-type option, the card's own words wait for its whole body as its
    /// approve does (words can approve: 「好的」); never read. A card without one takes words at once.
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
        let m = model(mock)
        for l in lines { m.client.feed(l) }
        m.selected = "ses_w"
        guard let (run, open) = m.states["ses_w"]?.openCard else { check(false, "the card is open"); return }
        let c = CardModel(card: open.card, runId: run, askId: open.askId)
        check(c.allowsFreeText && c.buttons.contains { $0.role == .approve }, "a card with an approve and its own field")
        check(!m.wordsEnabled(c, in: m.states["ses_w"]!), "its field: off before the body was seen")
        m.answer(c, text: "好的")
        check(sends(mock) == 0, "words before the body was seen: not sent")
        m.cardBody(c, contentHeight: 50, visibleHeight: 50, offset: 0)
        check(m.wordsEnabled(c, in: m.states["ses_w"]!), "its field: on once the body was on screen")
        m.answer(c, text: "好的")
        check(sent(mock)?["text"] as? String == "好的", "then sent: \(String(describing: sent(mock)))")
        // a card with no approve-type option takes words at once
        var plain = card
        plain["options"] = [["kind": "choice", "text": "周一"], ["kind": "cancel", "text": "先别做了"]]
        var pl = lines
        pl[3]["card"] = plain
        let mock2 = Mock()
        mock2.replies = [SessionClient.Op.send: ["ok": true]]
        let q = model(mock2)
        for l in pl { q.client.feed(l) }
        q.selected = "ses_w"
        guard let (run2, open2) = q.states["ses_w"]?.openCard else { check(false, "the plain card is open"); return }
        let c2 = CardModel(card: open2.card, runId: run2, askId: open2.askId)
        q.answer(c2, text: "周二")
        check(sent(mock2)?["text"] as? String == "周二" && q.wordsEnabled(c2, in: q.states["ses_w"]!) == false,
              "no approve-type option: words go at once (\(sends(mock2)) sent)")
        let card2 = CardModel(card: open2.card, runId: run2, askId: open2.askId)
        check(!ShellModel.wordsWaitForBody(card2) && ShellModel.wordsWaitForBody(c), "which cards' words wait")
    }

    /// #107 re-review (3): remembered settings never mark a session opened here. After a settings save and a helper
    /// restart, a reconnecting watch reopens only the sessions this client opened (with the new settings).
    static func settingsReopenTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_a"], SessionClient.Op.end: ["ok": true, "deferred": true]]
        var config = "provider-a"
        let m = ShellModel(client: SessionClient(transport: mock), defaults: scratchDefaults(), config: { config }, lang: { .zhHans },
                           work: { $0() }, deliver: { $0() })
        _ = m.client.open(sessionId: "ses_a", config: "provider-a", lang: "zh")
        m.client.feed(["kind": "session.start", "session_id": "ses_a", "resumed": false, "last_seq": 0])
        // two sessions this client only saw (the list, a watch): one running, one read from its history
        for l in SessionTests.lines("chat") { m.client.feed(l) }
        m.client.feed(["kind": "session.message", "session_id": "ses_r", "seq": 1, "msg_id": "u", "role": "user", "text": "旧的"])
        m.client.feed(["kind": "helper.session_exit", "session_id": "ses_r", "code": 0])
        config = "provider-b"
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

    /// #107 re-review (effect): the hint under a card whose approve (and own field) wait for the body is neutral, and
    /// the field says why it is off to VoiceOver.
    static func cardHintTests() {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Main/MainSplitView.swift")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let card = text.components(separatedBy: "struct CardView").dropFirst().first ?? ""
        check(!card.contains("Scroll to the end of the card to approve"), "no approve-only hint under the card")
        check(card.contains("Text(L(\"Read the whole card first: scroll to its end\""), "the neutral hint under it")
        let field = card.components(separatedBy: "TextField(L(\"Or answer in your own words\"").dropFirst().first?.components(separatedBy: "Button(L(\"Send\"").first ?? ""
        check(field.contains(".accessibilityHint(") && field.contains("Read the whole card first: scroll to its end"), "the field's own accessibility hint")
        check(L("Read the whole card first: scroll to its end", lang: .zhHans) != "Read the whole card first: scroll to its end", "translated")
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
        var on = true
        let m = ShellModel(client: SessionClient(transport: mock), defaults: scratchDefaults(), config: { "ds-flash" }, lang: { .zhHans },
                           cloudOn: { on }, work: { $0() }, deliver: { $0() })
        for l in SessionTests.lines("chat") { m.client.feed(l) }
        on = false
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
        mock.requests = []
        _ = c.reopenIfExited("ses_t", onlyOpenedHere: true)
        check(mock.requests.first?["op"] as? String == SessionClient.Op.open && mock.requests.first?["config"] == nil
              && (mock.requests.dropFirst().first?["line"] as? [String: Any])?["config"] is NSNull,
              "an automatic reopen after an exit: the same: \(mock.requests)")
        // back on: the open carries the configuration again, no set_config needed
        c.modelOff = false
        c.feed(["kind": "helper.session_exit", "session_id": "ses_t", "code": 1])
        mock.requests = []
        _ = c.reopenIfExited("ses_t", onlyOpenedHere: true)
        check(mock.requests.count == 1 && mock.requests[0]["config"] as? String == "ds-flash", "model on: opened with its configuration: \(mock.requests)")
    }

    /// Final round (4): set_config is never taken as applied: a `busy` refusal (it took effect, was not stored) is sent
    /// once more; a second busy, or bad_config, shows the settings did not reach it; its session.config clears that.
    static func configBusyTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true]]
        let c = SessionClient(transport: mock)
        for l in SessionTests.lines("chat") { c.feed(l) }
        c.setConfig("ses_t", config: "ds-flash", lang: "en")
        func sentConfigs() -> [[String: Any]] { mock.requests.compactMap { $0["line"] as? [String: Any] }.filter { $0["type"] as? String == "set_config" } }
        let first = sentConfigs().last?["client_id"] as? String ?? ""
        c.feed(["kind": "session.error", "session_id": "ses_t", "code": "busy", "control": "set_config", "client_id": first, "text": "x"])
        let deadline = Date().addingTimeInterval(2)
        while sentConfigs().count < 2 && Date() < deadline { usleep(10_000) }
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

    /// Final round (6): the "read the whole card first" hint only while the card is open.
    static func hintOpenOnlyTests() {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Main/MainSplitView.swift")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let card = text.components(separatedBy: "struct CardView").dropFirst().first ?? ""
        let before = card.components(separatedBy: "Text(L(\"Read the whole card first: scroll to its end\"").first ?? ""
        check(before.split(separator: "\n").suffix(3).contains { $0.contains("if outcome == .open && !seen") }, "the hint shows only while the card is open")
    }

    /// #107 external review (P2 2): the language is a session setting like the model's: one value for both. A switch
    /// reaches every session's next process (as a key does), whatever was remembered for it before.
    static func languageTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_x"], SessionClient.Op.send: ["ok": true],
                        SessionClient.Op.end: ["ok": true, "deferred": true]]
        var config = "provider-a", lang = ResolvedLang.zhHans
        let m = ShellModel(client: SessionClient(transport: mock), defaults: scratchDefaults(), config: { config }, lang: { lang },
                           work: { $0() }, deliver: { $0() })
        m.newConversation(); m.draft = "你好"; m.submit()
        m.client.feed(["kind": "session.start", "session_id": "ses_x", "resumed": false, "last_seq": 0])
        config = "provider-b"
        m.settingsChanged()                     // remembered for ses_x: provider-b, zh
        lang = .en
        m.applySettings()                       // what the window as it was did on a language switch
        m.client.feed(["kind": "helper.session_exit", "session_id": "ses_x", "code": 0, "idle": true])
        mock.requests = []
        m.selected = "ses_x"; m.draft = "again"; m.submit()
        let reopen = mock.requests.first { $0["op"] as? String == SessionClient.Op.open }
        check(reopen?["lang"] as? String == "en" && reopen?["config"] as? String == "provider-b",
              "after a language switch, the reclaimed session reopens in it: \(String(describing: reopen?["lang"])) \(String(describing: reopen?["config"]))")
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let main = (try? String(contentsOf: dir.appendingPathComponent("Main/MainSplitView.swift"), encoding: .utf8)) ?? ""
        check(main.contains(".onChange(of: lang) { _, _ in shell.settingsChanged() }") && main.contains("+ \"|\" + ResolvedLang.current.rawValue"),
              "the window: a language switch goes the settings' way; the language is in the settings' fingerprint")
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
        check(old.requests.map { $0["op"] as? String ?? "" } == [SessionClient.Op.history, SessionClient.Op.open], "no history op: opened instead")
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
