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
        DecisionTests.group("shell.flagTests"); flagTests()
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
        DecisionTests.group("shell.hintOpenOnlyTests"); hintOpenOnlyTests()
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
        DecisionTests.group("shell.settingsOrderingTests"); settingsOrderingTests()
        DecisionTests.group("shell.textTests"); textTests()
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
        var config = "provider-a"
        let m2 = ShellModel(client: SessionClient(transport: mock2), defaults: scratchDefaults(), config: { config }, lang: { .zhHans },
                            work: { $0() }, deliver: { $0() })
        m2.newConversation(); m2.draft = "你好"; m2.submit()
        check(mock2.requests.first { $0["op"] as? String == SessionClient.Op.open }?["config"] as? String == "provider-a", "opened with provider a")
        m2.client.feed(["kind": "session.start", "session_id": "ses_x", "resumed": false, "last_seq": 0])
        m2.client.reconciling.wait()          // (the reconcile its start sets off, done first)
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
        m.client.reconciling.wait()
        let types = mock.requests.compactMap { ($0["line"] as? [String: Any])?["type"] as? String }
        check(types.allSatisfy { $0 == "set_config" } && !mock.requests.contains { $0["op"] as? String == SessionClient.Op.open },
              "an open session: no say, no cua, no retry (only its null, set_config): \(types)")
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
        m.cardBody(card, contentHeight: 10, visibleHeight: 10, offset: 0)
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
        m.client.reconciling.wait()          // (the reconcile its start sets off, done first)
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
        m.client.reconciling.wait()
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
        c.reconciling.wait()            // (the reconciles the lines set off, done before the requests are read afresh)
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

    /// #107 review of aa232eb (bug 1): cloud turned off while a session is being opened. The open went out with the
    /// configuration; its reply is in after the switch: the client re-checks the model, sends set_config null before
    /// anything else, and the first words are not written (no say, no task, no turn on the cloud). The reverse: turned
    /// on while it opened without one — the configuration follows at once.
    static func modelOffMidOpenTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_n"], SessionClient.Op.send: ["ok": true]]
        var on = true
        let m = ShellModel(client: SessionClient(transport: mock), defaults: scratchDefaults(), config: { "ds-flash" }, lang: { .zhHans },
                           cloudOn: { on }, work: { $0() }, deliver: { $0() })
        mock.onRequest = { op in if op == SessionClient.Op.open && on { on = false; m.settingsChanged() } }
        m.newConversation(); m.draft = "你好"; m.submit()
        mock.onRequest = nil
        let lines = mock.requests.compactMap { $0["line"] as? [String: Any] }
        check(mock.requests.first?["config"] as? String == "ds-flash", "(the open went out with the configuration)")
        check(lines.map { $0["type"] as? String ?? "" } == ["set_config"] && lines.first?["config"] is NSNull,
              "turned off mid-open: set_config null after the reply, no say: \(lines.map { $0["type"] ?? "" })")
        check(m.client.state("ses_n").outbox.first?.refused == "no_model", "the words: not sent (the cloud model is off)")
        // a reopen while the switch turns: the client's list has the session being opened (a reconcile reaches it)
        let c = SessionClient(transport: mock)
        mock.requests = []
        c.modelOff = true
        mock.onRequest = { op in if op == SessionClient.Op.open { c.modelOff = false } }
        _ = c.open(sessionId: "ses_n", config: "ds-flash", lang: "zh")
        mock.onRequest = nil
        let back = mock.requests.compactMap { $0["line"] as? [String: Any] }
        check(mock.requests.first?["config"] == nil && back.first?["type"] as? String == "set_config" && back.first?["config"] as? String == "ds-flash",
              "turned on mid-open (opened with none): its configuration at once: \(back)")
        let gate = DispatchSemaphore(value: 0)
        mock.onRequest = { op in if op == SessionClient.Op.open { gate.wait() } }
        DispatchQueue.global().async { _ = c.open(sessionId: "ses_o", config: "ds-flash", lang: "zh") }
        let deadline = Date().addingTimeInterval(2)
        while !c.liveIds().contains("ses_o") && Date() < deadline { usleep(5_000) }
        check(c.liveIds().contains("ses_o"), "a session being opened is in the client's list (a reconcile reaches it)")
        gate.signal()
        usleep(100_000)
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
        // acked: applied; a second reconcile sends nothing
        let cid = (mock3.requests.last?["line"] as? [String: Any])?["client_id"] as? String ?? ""
        c3.feed(["kind": "session.config", "session_id": "ses_c", "seq": 1, "config": NSNull(), "lang": "zh", "by": "set_config", "client_id": cid])
        mock3.requests = []
        c3.reconcile(config: "ds-flash", lang: "zh", off: true)
        check(nulls(mock3) == 0, "acked: not sent again")
    }

    /// Re-review of cb01397: the helper's own answers. `busy_ending` (it is deciding whether the session ends, the process
    /// is there) is sent again, never read as an exit; `no_model` (the helper holds cloud models off, from another
    /// window or app) leaves the words the app's, not sent — and once cloud is on again they read plainly "not sent".
    static func helperRefusalTests() {
        let mock = Mock()
        mock.replies = [SessionClient.Op.send: ["ok": true]]
        mock.queued = [SessionClient.Op.send: [["ok": false, "code": "busy_ending"]]]
        var on = true
        let m = ShellModel(client: SessionClient(transport: mock), defaults: scratchDefaults(), config: { "c" }, lang: { .zhHans },
                           cloudOn: { on }, work: { $0() }, deliver: { $0() })
        for l in SessionTests.lines("chat") { m.client.feed(l) }
        m.selected = "ses_t"; m.draft = "你好"; m.submit()
        check(sends(mock) == 2 && m.states["ses_t"]?.exited == nil && m.states["ses_t"]?.outbox.first?.sending == true,
              "busy_ending: sent again, no exit (\(sends(mock)) sends)")
        mock.queued = [SessionClient.Op.send: [["ok": false, "code": "no_model", "control": "say"]]]
        m.draft = "在吗"; m.submit()
        let item = m.states["ses_t"]?.outbox.last
        check(item?.refused == "no_model" && item?.sending == false, "no_model from the helper: not sent, the app's")
        on = false; m.refreshSettings()
        check(m.unsentText(item?.refused) == "没发出去：云端模型关着", "while off: the cloud model is off")
        on = true; m.refreshSettings()
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
        let c = SessionClient(transport: helper)
        c.adoptSettings(config: "ds-flash", lang: "zh")
        mock.streamLines = [["kind": "helper.watching", "open": ["ses_k"], "models_off": true],
                            ["kind": "session.config", "session_id": "ses_k", "seq": 1, "config": NSNull(), "lang": "zh", "by": "set_config"]]
        _ = c.watch()
        // (until the helper has the switch and the session its configuration: the refused one is repaired by a push and a
        // reconcile of its own)
        let until = Date().addingTimeInterval(5)
        while Date() < until {
            c.modelsSync.settle(); c.reconciling.wait()
            if mock.requests.compactMap({ $0["line"] as? [String: Any] }).last(where: { $0["type"] as? String == "set_config" })?["config"] as? String == "ds-flash"
                && !c.modelsSync.isPending, (mock.requests.firstIndex { $0["op"] as? String == "models.off" } ?? Int.max)
                < (mock.requests.lastIndex { ($0["line"] as? [String: Any])?["type"] as? String == "set_config" } ?? -1) { break }
            usleep(20_000)
        }
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
        // (A) a retry still scheduled while the switch turns: it sends the switch as it is then, never the old value
        t.lock.lock(); t.seen = []; t.failFirst = 1; t.lock.unlock()
        sync.firstDelay = 0.2
        sync.push()
        usleep(50_000)                                       // its first try failed; its retry waits
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
        c.reconciling.wait(); c.modelsSync.settle()
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

    /// Re-review of b0ff614 (old window): the engine setter asserts through the ordered sync; the app asserts when the
    /// helper's status disagrees; a refused run (no_model) is said as it is.
    static func oldWindowRunTests() {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sheet = (try? String(contentsOf: dir.appendingPathComponent("Main/CloudModel.swift"), encoding: .utf8)) ?? ""
        check(sheet.contains("ModelsOffSync.shared.push()"), "the engine setter pushes through the app's one sync")
        let app = (try? String(contentsOf: dir.appendingPathComponent("Main/DeskMindApp.swift"), encoding: .utf8)) ?? ""
        check(app.contains("reply?[\"models_off\"]") && app.contains("ModelsOffSync.shared.push()"), "the helper's status disagreeing: pushed again")
        let run = (try? String(contentsOf: dir.appendingPathComponent("Main/RunView.swift"), encoding: .utf8)) ?? ""
        check(run.contains("[\"brain_not_ready\", \"no_model\"].contains"), "a run refused no_model: said as it is")
        check(L("The cloud model is off. Turn it on in the model settings to run this task.", lang: .zhHans).contains("云端模型关着"), "translated")
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
        // reconciled once: the same running list again sends nothing more
        mock.requests = []
        mock.streamLines = [["kind": "helper.watching", "open": ["ses_k"]]]
        _ = m.client.watch()
        m.client.reconciling.wait()
        check(!mock.requests.contains { ($0["line"] as? [String: Any])?["type"] as? String == "set_config" }, "idempotent: no second null")
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
        let c = SessionClient(transport: mock)
        for l in SessionTests.lines("chat") { c.feed(l) }
        c.setConfig("ses_t", config: "openai:deepseek|a", lang: "zh")
        let first = (mock.requests.last?["line"] as? [String: Any])?["client_id"] as? String ?? ""
        c.setConfig("ses_t", config: "openai:deepseek|b", lang: "en")
        c.feed(["kind": "session.error", "session_id": "ses_t", "code": "busy", "control": "set_config", "client_id": first, "text": "x"])
        let deadline = Date().addingTimeInterval(2)
        func configs() -> [[String: Any]] { mock.requests.compactMap { $0["line"] as? [String: Any] }.filter { $0["type"] as? String == "set_config" } }
        while configs().count < 3 && Date() < deadline { usleep(10_000) }
        check(configs().count == 3 && configs().last?["config"] as? String == "openai:deepseek|b" && configs().last?["lang"] as? String == "en",
              "the retry carries the latest settings: \(configs().map { $0["config"] ?? "" })")
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
        m.client.reconciling.wait()             // (the reconcile its start sets off, done before the settings move)
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
            m.syncSettings()
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
        let write = cloud.components(separatedBy: "static func write(").dropFirst().first?.components(separatedBy: "static var provider").first ?? ""
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
        check(list.contains("\"keys\": keysNow") && list.contains("i[\"keys\"] = k") && list.contains("i[\"ending\"] = r.ending"),
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
        let start = Date()
        c.helperSays(modelsOff: true)                       // (the app's switch is on: pushed, then every session reconciled)
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
            client.newClientId = { "c_msg" }
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
            case .refusal(let code):
                m.client.feed(["kind": "session.error", "session_id": "ses_t", "code": code, "control": "say", "client_id": "c_msg", "text": "x"])
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

    /// #107 review at 7f09c1b — the invariant: what a session's next process opens with and the last set_config it was
    /// sent are never older than the newest settings the client has. A reconcile that read A, held up behind the
    /// session's lock (a send under way), while B is adopted (as the watch's applySettings does, with no reconcile of
    /// its own): it must not write A over B, nor send A last.
    static func settingsOrderingTests() {
        final class Slow: SessionTransport {
            let lock = NSLock()
            var log: [[String: Any]] = []
            var holdSay = false
            let inSay = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
            func request(_ body: [String: Any]) -> [String: Any]? {
                lock.lock(); log.append(body); let hold = holdSay && (body["line"] as? [String: Any])?["type"] as? String == "say"; if hold { holdSay = false }; lock.unlock()
                if hold { inSay.signal(); gate.wait() }
                if body["op"] as? String == SessionClient.Op.open { return ["ok": true, "session_id": body["session_id"] as? String ?? "ses_x"] }
                return ["ok": true]
            }
            func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool { false }
            func lastConfig() -> [String: Any]? {
                lock.lock(); defer { lock.unlock() }
                return log.compactMap { $0["line"] as? [String: Any] }.last { $0["type"] as? String == "set_config" }
            }
            func lastOpen() -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return log.last { $0["op"] as? String == SessionClient.Op.open } }
        }
        /// A send holds the session's lock; a reconcile reads the settings and waits behind it; `change` runs; the send
        /// goes on.
        func interleave(_ c: SessionClient, _ t: Slow, _ id: String, change: () -> Void) {
            t.lock.lock(); t.holdSay = true; t.lock.unlock()
            let sent = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { _ = c.send(.say("在吗"), to: id); sent.signal() }
            t.inSay.wait()
            c.reconcileSession(id)                       // (reads the settings now, then waits for the session's lock)
            usleep(200_000)
            change()
            t.gate.signal()
            sent.wait(); c.reconciling.wait()
        }

        // the client: A read, B adopted meanwhile
        do {
            let t = Slow(), c = SessionClient(transport: t)
            c.adoptSettings(config: "A", lang: "zh")
            c.feed(["kind": "session.start", "session_id": "s", "resumed": false, "last_seq": 0])
            c.feed(["kind": "session.config", "session_id": "s", "seq": 1, "config": "old", "lang": "zh", "by": "open"])
            c.reconciling.wait()
            interleave(c, t, "s") { c.adoptSettings(config: "B", lang: "en") }
            check(t.lastConfig()?["config"] as? String == "B" && t.lastConfig()?["lang"] as? String == "en",
                  "the last set_config sent: B, not the A the reconcile read: \(String(describing: t.lastConfig()))")
            c.feed(["kind": "helper.session_exit", "session_id": "s", "code": 0])
            _ = c.reopenIfExited("s")
            check(t.lastOpen()?["config"] as? String == "B" && t.lastOpen()?["lang"] as? String == "en",
                  "its next process opens with B: \(String(describing: t.lastOpen()))")
        }

        // languageTests made deterministic: the shell's session, a reconcile that read (provider-b, zh) held up while
        // the language switches to en: its next process opens in en
        do {
            let t = Slow()
            var config = "provider-a", lang = ResolvedLang.zhHans
            let m = ShellModel(client: SessionClient(transport: t), defaults: scratchDefaults(), config: { config }, lang: { lang },
                               work: { $0() }, deliver: { $0() })
            m.newConversation(); m.draft = "你好"; m.submit()
            m.client.feed(["kind": "session.start", "session_id": "ses_x", "resumed": false, "last_seq": 0])
            m.client.reconciling.wait()
            config = "provider-b"
            m.applySettings()                    // (adopted, not sent yet: it runs provider-a, the reconcile has one to send)
            interleave(m.client, t, "ses_x") { lang = .en; m.applySettings() }
            check(t.lastConfig()?["lang"] as? String == "en", "the last set_config: in en: \(String(describing: t.lastConfig()))")
            m.client.feed(["kind": "helper.session_exit", "session_id": "ses_x", "code": 0, "idle": true])
            m.selected = "ses_x"; m.draft = "again"; m.submit()
            check(t.lastOpen()?["lang"] as? String == "en" && t.lastOpen()?["config"] as? String == "provider-b",
                  "the reclaimed session reopens in en with provider-b: \(String(describing: t.lastOpen()))")
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
