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
        m.settingsChanged()
        // the helper decides when each can end (now if idle, else once it is): this app only asks, for every session
        // with a process, and never a bare end (#107 review: the app's own view missed a /cua in flight)
        let ends = mock.requests.filter { $0["op"] as? String == SessionClient.Op.end }
        check(ends.compactMap { $0["session_id"] as? String } == ["ses_busy", "ses_t", "ses_undo"] && ends.allSatisfy { $0["when_idle"] as? Bool == true },
              "a restart asked of the helper for each live session, when idle: \(ends)")
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
        m.settingsChanged()
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
        m.select("ses_t")
        check(mock.requests.isEmpty, "known: opened again without asking anything")
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
