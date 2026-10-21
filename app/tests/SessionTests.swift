// The session data model (M1 S2): ProtocolEvent, SessionReducer, SessionStatus, CardModel, SessionClient. The streams in
// tests/fixtures/session/*.jsonl are recorded from the harness's own session (see record-s2.test.ts there): what the
// session process writes to stdout, executor events forwarded. Run from DecisionTests.main (build.sh).

import Foundation

enum SessionTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, what, file: file, line: line)
    }

    static func run() {
        decodeTests()
        chatTests()
        chatErrorTests()
        cardTaskTests()
        undoTests()
        stopTests()
        steerQueueTests()
        questionTests()
        pausedLookOnlyTests()
        lockedTests()
        replayTests()
        unknownTests()
        deltaTests()
        cardModelTests()
        staleAnswerTests()
        clientTests()
    }

    // MARK: fixtures

    static let fixtureDir: URL = {
        if let d = ProcessInfo.processInfo.environment["SESSION_FIXTURES"] { return URL(fileURLWithPath: d) }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return URL(fileURLWithPath: "\(#filePath)", relativeTo: cwd).deletingLastPathComponent().appendingPathComponent("fixtures/session")
    }()

    static let names = ["chat", "chat-error", "task-card", "task-undo", "task-stop", "task-steer", "task-question", "task-paused-unconfirmed", "task-locked"]

    static func raw(_ name: String) -> [String] {
        let url = fixtureDir.appendingPathComponent("\(name).jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { check(false, "fixture \(url.path) readable"); return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    static func lines(_ name: String) -> [ProtocolLine] {
        raw(name).compactMap { l in
            let p = ProtocolLine.parse(l)
            check(p != nil, "\(name): a line parses: \(l.prefix(80))")
            return p
        }
    }

    /// The state after each line, with the line.
    static func steps(_ name: String) -> [(line: ProtocolLine, state: SessionState)] {
        var s = SessionState()
        return lines(name).map { l in s = SessionReducer.reduce(s, l); return (l, s) }
    }

    /// The state right after the first line that matches.
    static func after(_ name: String, _ match: (ProtocolLine) -> Bool) -> SessionState? {
        steps(name).first { match($0.line) }?.state
    }

    static func final(_ name: String) -> SessionState { SessionReducer.reduce(SessionState(), lines(name)) }

    static func isKind(_ k: String) -> (ProtocolLine) -> Bool { { $0.event.kind == k } }

    // MARK: decoding

    static func decodeTests() {
        for n in names {
            let ls = lines(n)
            check(ls.count == raw(n).count && !ls.isEmpty, "\(n): every line read")
            for l in ls {
                if case .unknown(let k, _) = l.event { check(false, "\(n): the recorded kind \(k) is known") }
                check(l.sessionId == "ses_t", "\(n): session_id on every line")
                // what is encoded reads back the same
                if let d = try? JSONEncoder().encode(l), let back = ProtocolLine.parse(d) { check(back == l, "\(n): \(l.event.kind) round-trips") }
                else { check(false, "\(n): \(l.event.kind) encodes") }
            }
        }
        // the envelope: an executor event carries its run and its own seq
        let card = lines("task-card")
        if let ask = card.first(where: isKind("ask")) {
            check(ask.runId?.hasPrefix("run_") == true && ask.seq == 7, "ask: run_id and its run's seq")
            if case .ask(let a) = ask.event {
                check(a.card.kind == "plan" && a.card.options.map(\.kind) == ["approve", "cancel"] && a.card.freeText && a.card.blocking, "ask card fields")
                check(a.card.plan?.steps.first?.objects.first?.label == "编辑器「笔记.txt」" && a.card.plan?.steps.first?.class == "modify_user", "card.plan fields")
            } else { check(false, "ask decodes as .ask") }
        }
        if let step = card.first(where: isKind("step")), case .step(let s) = step.event {
            check(s.stepId?.hasPrefix("st_") == true && s.planStep == 1 && s.target?.label == "正文" && s.human?.contains("正文") == true, "step fields: \(s)")
        } else { check(false, "a step") }
    }

    // MARK: chat

    static func chatTests() {
        let all = steps("chat")
        // while the first reply streams: one bubble, assembled from the offsets, thinking
        let firstFinal = all.firstIndex { if case .message(let m) = $0.line.event { return m.role == "assistant" }; return false }!
        let streaming = all[firstFinal - 1].state
        check(streaming.streamingMessage?.text == "你好，我是 DeskMind。有什么可以帮你？", "deltas assemble: \(String(describing: streaming.streamingMessage?.text))")
        check(streaming.status == .thinking, "a streaming reply is thinking: \(streaming.status)")
        check(streaming.lastRefusal?.code == "busy" && streaming.lastRefusal?.control == "say", "a say during a reply: busy")
        check(streaming.composerEnabled, "no card: the composer is on")
        // the replaced final: the offset-0 full delta replaces what streamed, before the message
        let xyzDelta = all.first { if case .delta(let d) = $0.line.event { return d.text == "xyz" }; return false }!
        check(xyzDelta.state.streamingMessage?.text == "xyz", "an offset-0 full delta replaces: \(String(describing: xyzDelta.state.streamingMessage?.text))")
        let s = final("chat")
        check(s.messages.map { "\($0.role):\($0.text)" } == ["user:你好", "assistant:你好，我是 DeskMind。有什么可以帮你？", "user:hi", "assistant:xyz",
                                                              "user:讲个长故事", "assistant:第0句。第1句。第2句。第3句。第4句。"], "messages: \(s.messages.map(\.text))")
        check(s.messages.allSatisfy { !$0.streaming && !$0.gap }, "all final")
        check(s.messages.last?.stopped == true && s.messages[1].model == "test|scripted" && s.messages[1].replyTo == s.messages[0].id, "message fields")
        check(s.lastSeq == 6 && s.sessionId == "ses_t", "lastSeq \(s.lastSeq)")
        check(s.status == .done(at: s.messages.last?.t, stopped: true), "a stopped reply last: done, stopped: \(s.status)")
        check(s.timeline.count == 6, "timeline: six messages")
        // the attach at the end replayed seq 1…6: nothing changed
        let beforeAttach = all[all.count - 7].state
        check(beforeAttach == s, "attach replay changes nothing")
        check(SessionState().status == .idle, "an empty session is idle")
    }

    static func chatErrorTests() {
        let s = final("chat-error")
        check(s.errors.map(\.error.code) == ["no_key"] && s.errors.first?.seq == 2 && s.errors.first?.error.text.contains("CUSTOM_API_KEY") == true, "no_key stored")
        check(s.timeline.last == .error(2), "the error is in the chat")
        check(s.status == .error("no_key"), "the model's error makes the error dot: \(s.status)")
        var seen = s
        seen.markSeen()
        check(seen.status == .idle, "seen: the error dot clears: \(seen.status)")
    }

    // MARK: tasks

    static func cardTaskTests() {
        let n = "task-card"
        check(after(n, isKind("session.delta"))?.status == .thinking, "the reply opens: thinking")
        let task = after(n, isKind("session.task"))!
        check(task.messages.map(\.role) == ["user"], "the empty bubble leaves when the model goes straight to a task")
        check(task.status == .thinking && task.runningTask?.preparing == true, "a task preparing: thinking")
        // the card
        let asked = after(n, isKind("ask"))!
        check(asked.status == .waitingForYou(cardKind: "plan"), "an open card: waiting for you: \(asked.status)")
        check(!asked.composerEnabled, "the composer is off while a card waits")
        let open = asked.openCard
        check(open?.card.askId.hasPrefix("ask_") == true && open?.card.outcome == .open, "the open card")
        let refused = after(n, isKind("session.error"))!
        check(refused.lastRefusal?.code == "card_open" && !refused.composerEnabled, "a say while the card waits: card_open, still off")
        let resumed = after(n, isKind("resumed"))!
        check(resumed.composerEnabled && resumed.openCard == nil, "answered: the composer is back")
        check(resumed.tasks[0].cards.first?.outcome == .answered, "the card is answered")
        // the step
        let stepped = after(n, isKind("step"))!
        let st = stepped.tasks[0].steps.first!
        check(st.status == .running && st.displayText == "在 编辑器「笔记.txt」 把「正文」设为「新的」" && st.planStep == 1 && st.target?.role == "textArea",
              "the step, in the user's words: \(st)")
        check(stepped.status == .acting(step: 1, of: 1), "acting: step 1 of 1: \(stepped.status)")
        let result = after(n, isKind("step_result"))!
        check(result.tasks[0].steps.first?.status == .ok && result.tasks[0].steps.first?.executorStatus == "ok", "step_result: ok")
        // the end
        let done = after(n, isKind("task_done"))!
        let t = done.tasks[0]
        check(t.status == "succeeded" && !t.running && t.resultCard?.options.map(\.kind) == ["approve"], "task_done")
        check(t.undo == .none, "a result card with no undo: no undo")
        check(done.status == .done(at: t.doneAt, stopped: false), "a task that succeeded last: done: \(done.status)")
        let s = final(n)
        check(s.timeline.map { if case .task = $0 { return "task" }; if case .message(let id) = $0 { return s.message(id)!.role }; return "error" }
              == ["user", "task", "assistant"], "timeline: \(s.timeline)")
        check(s.tasks[0].end?.status == "succeeded" && s.tasks[0].end?.undo == "none" && s.tasks[0].by == "model" && s.tasks[0].goal == "把笔记正文改成「新的」", "task_end and the task's origin")
        check(s.status == .done(at: s.messages.last?.t, stopped: false), "the model's last word: done")
        check(s.tasks[0].lastSeq == 21, "the run's last seq: \(s.tasks[0].lastSeq)")
    }

    static func undoTests() {
        let n = "task-undo"
        let s0 = after(n, isKind("session.task"))!
        check(s0.messages.first?.via == "cua" && s0.tasks[0].by == "slash", "/cua: via cua, by slash")
        let done = after(n, isKind("task_done"))!
        let t = done.tasks[0]
        check(t.undo == .available && t.changes.created == ["a.txt"], "undo offered: \(t.undo)")
        let card = CardModel(resultCard: t.resultCard!, runId: t.runId)
        check(card.isResult && card.askId == nil && !card.allowsFreeText && card.kind == .result, "the result card")
        check(card.buttons.map(\.role) == [.approve, .undo] && card.buttons.map(\.style) == [.prominent, .destructive], "result buttons by kind")
        let undo = card.buttons.first { $0.role == .undo }!
        check(card.answer(undo) == .respond(runId: t.runId, option: 1), "undo sends respond with its index")
        check(card.answer(undo).control as NSDictionary == ["type": "respond", "run_id": t.runId, "option": 1] as NSDictionary, "respond line")
        check(SessionClient.refusal(card.answer(undo), in: done) == nil, "the result card can be answered")
        let undone = after(n, isKind("result_response"))!
        check(undone.tasks[0].undo == .done(undone: 1, total: 1, refused: nil), "undone 1/1: \(undone.tasks[0].undo)")
        check(SessionClient.refusal(card.answer(undo), in: undone) != nil, "answered once: no second answer")
        let s = final(n)
        check(s.tasks[0].undo == .done(undone: 1, total: 1, refused: nil) && s.tasks[0].closed == "linger", "closed after undo keeps the result")
        // a lingering result card whose executor closes unanswered: expired
        var expired = done
        expired = SessionReducer.reduce(expired, ProtocolLine(seq: 99, sessionId: "ses_t", event: .taskClosed(SessionTaskClosed(runId: t.runId, why: "new_task"))))
        check(expired.tasks[0].undo == .expired("new_task"), "a new task elsewhere: undo expired")
        check(SessionClient.refusal(card.answer(undo), in: expired) != nil, "an expired result card is not answered")
    }

    static func stopTests() {
        let n = "task-stop"
        let queued = after(n, isKind("session.queue"))!
        check(queued.queue.map(\.text) == ["三"] && queued.queue.first?.held == nil, "typing during the task is queued")
        check(after(n, isKind("ask"))?.status == .waitingForYou(cardKind: "plan"), "the card")
        let stopping = after(n, isKind("refused"))!
        check(stopping.tasks[0].stopping && stopping.status == .waitingForYou(cardKind: "plan"), "stop asked, card still open: waiting first")
        let voided = after(n, isKind("ask_void"))!
        check(voided.tasks[0].cards.first?.outcome == .void("stop") && voided.composerEnabled, "the card is voided by the stop")
        check(voided.status == .stopping, "then: stopping: \(voided.status)")
        let done = after(n, isKind("task_done"))!
        check(done.tasks[0].status == "stopped" && !done.tasks[0].stopping, "stopped")
        check(done.status == .done(at: done.tasks[0].doneAt, stopped: true), "a stopped task last: done, stopped: \(done.status)")
        let held = steps(n).last { $0.line.event.kind == "session.queue" && !$0.state.queue.isEmpty }!.state
        check(held.queue.first?.held == true && held.queue.first?.note == "任务已停，要发吗？", "after a stop the queue is held")
        let s = final(n)
        check(s.queue.isEmpty && s.messages.map(\.text) == ["把笔记的正文改成「新的」", "停下了", "三", "好的，三"], "send now: \(s.messages.map(\.text))")
    }

    static func steerQueueTests() {
        let n = "task-steer"
        let edited = steps(n).filter { $0.line.event.kind == "session.queue" }.map { $0.state.queue.map(\.text) }
        check(edited == [["一"], ["一", "二"], ["一", "二改"], []], "the queue, as sent whole each time: \(edited)")
        let s = final(n)
        check(s.tasks[0].steersSent == ["内容就写 hi 吧"] && s.tasks[0].steered == ["内容就写 hi 吧"], "the steer: sent and taken")
        check(s.tasks[0].end?.steers == ["内容就写 hi 吧"], "task_end lists it")
        check(s.messages.filter { $0.via == "queue" }.map(\.text) == ["一", "二改"], "the queue went to the model after the task")
        check(s.tasks[0].steps.count == 1 && s.tasks[0].steps[0].status == .ok, "one step, ok")
    }

    static func questionTests() {
        let n = "task-question"
        let asked = after(n, isKind("ask"))!
        let (runId, open) = asked.openCard!
        check(open.card.kind == "missing" && !asked.composerEnabled, "a question card waits")
        let card = CardModel(card: open.card, runId: runId, askId: open.askId)
        check(card.kind == .missing && card.allowsFreeText && card.buttons.map(\.role) == [.choice, .choice, .delegate, .cancel], "question buttons: \(card.buttons.map(\.role))")
        check(card.answerableInFloat && !card.freeTextInFloat, "two values: in the float, words only in the main window")
        check(card.answer(text: " 叫 c.txt ") == .text(runId: runId, askId: open.askId, text: "叫 c.txt"), "words are sent as words")
        check(card.answer(text: "a.txt") == .text(runId: runId, askId: open.askId, text: "a.txt"), "words that match an option are still words")
        check(card.answer(text: "  ") == nil, "empty words: nothing")
        check(card.answer(card.buttons[1]).control as NSDictionary == ["type": "answer", "run_id": runId, "ask_id": open.askId, "option": 1] as NSDictionary, "option line")
        let s = final(n)
        check(s.tasks[0].cards.first?.outcome == .answered && s.composerEnabled, "answered")
        check(s.tasks[0].changes.created == ["c.txt"], "changes from task_done")
    }

    static func pausedLookOnlyTests() {
        let n = "task-paused-unconfirmed"
        let all = steps(n)
        let paused = all.first { if case .waiting(let w) = $0.line.event { return w.askId == nil }; return false }!.state
        check(paused.status == .paused && paused.tasks[0].userActive, "the user at the keyboard: paused: \(paused.status)")
        let resumed = all.first { if case .resumed(let r) = $0.line.event { return r.askId == nil }; return false }!.state
        check(resumed.status == .acting(step: 1, of: 1), "resumed: acting again: \(resumed.status)")
        let look = after(n, isKind("verify"))!
        check(look.status == .lookOnly && look.tasks[0].verify?.missingKind == "evidence", "the verdict wants evidence: look only: \(look.status)")
        let done = after(n, isKind("task_done"))!
        check(done.status == .error("unconfirmed") && !done.tasks[0].lookOnly, "unconfirmed: the error dot before task_end: \(done.status)")
        let s = final(n)
        check(s.status == .error("unconfirmed"), "still, after the model spoke, until seen: \(s.status)")
        var seen = s
        seen.markSeen()
        check(seen.status == .done(at: s.messages.last?.t, stopped: false), "seen: done: \(seen.status)")
    }

    static func lockedTests() {
        let n = "task-locked"
        check(after(n, isKind("task_done"))?.status == .locked, "the screen is locked: locked")
        let s = final(n)
        check(s.status == .locked && s.tasks[0].steps.isEmpty, "locked until seen")
        var seen = s
        seen.markSeen()
        check(seen.status != .locked, "seen: no longer locked")
        check(SessionStatus.locked.shape == .bang && SessionStatus.thinking.shape == .hollowRing && SessionStatus.waitingForYou(cardKind: "plan").shape == .haloDot
              && SessionStatus.done(at: nil, stopped: false).shape == .check && SessionStatus.idle.shape == .mistDot && SessionStatus.paused.shape == .solidDot, "a shape for each")
    }

    // MARK: replay

    static func replayTests() {
        for n in names {
            let ls = lines(n)
            let once = SessionReducer.reduce(SessionState(), ls)
            check(SessionReducer.reduce(once, ls) == once, "\(n): the whole stream again changes nothing")
            check(SessionReducer.reduce(SessionState(), ls.flatMap { [$0, $0] }) == once, "\(n): every line twice is the same")
            // a reconnect halfway: the app has the first half, the helper replays from the start
            let half = SessionReducer.reduce(SessionState(), Array(ls.prefix(ls.count / 2)))
            check(SessionReducer.reduce(half, ls) == once, "\(n): a replay from the start after half")
        }
    }

    static func unknownTests() {
        let future = ProtocolLine.parse(#"{"seq":2,"t":1,"session_id":"s","kind":"session.future","x":{"y":[1,true,null]}}"#)!
        check(future.event == .unknown(kind: "session.future", raw: .object(["seq": .number(2), "t": .number(1), "session_id": .string("s"), "kind": .string("session.future"),
                                                                            "x": .object(["y": .array([.number(1), .bool(true), .null])])])), "an unknown session kind is kept whole")
        var s = SessionReducer.reduce(SessionState(), future)
        check(s.unknownKinds == ["session.future"] && s.lastSeq == 2, "it is noted, and its seq counts")
        let exec = ProtocolLine.parse(#"{"seq":4,"run_id":"r1","session_id":"s","kind":"hover","where":"x"}"#)!
        s = SessionReducer.reduce(s, exec)
        check(s.unknownKinds == ["session.future", "hover"] && s.task("r1")?.lastSeq == 4, "an unknown executor kind: noted, its seq counts")
        check(SessionReducer.reduce(s, exec) == s, "replayed: nothing")
        if let d = try? JSONEncoder().encode(future), let back = ProtocolLine.parse(d) { check(back == future, "unknown round-trips") } else { check(false, "unknown encodes") }
        // a known kind missing what it cannot do without: kept as unknown, not thrown
        let noCard = ProtocolLine.parse(#"{"seq":5,"run_id":"r1","kind":"ask","ask_id":"a"}"#)!
        check(noCard.event.kind == "ask", "kind kept")
        if case .unknown = noCard.event {} else { check(false, "an ask with no card is unknown") }
        // extra fields are ignored, missing ones take their empty value, a field of the wrong type too
        let extra = ProtocolLine.parse(#"{"seq":1,"session_id":"s","kind":"session.message","msg_id":"m1","role":"user","text":"hi","future":{"a":1}}"#)!
        if case .message(let m) = extra.event { check(m.text == "hi" && m.via == nil && m.stopped == nil, "extra fields ignored") } else { check(false, "message with extra fields") }
        let sparse = ProtocolLine.parse(#"{"run_id":"r1","kind":"step_result","step_id":7}"#)!
        if case .stepResult(let r) = sparse.event { check(r.stepId == "" && r.status == "" && r.shot == nil, "missing and mistyped fields: empty") } else { check(false, "a sparse step_result") }
        let preparing = ProtocolLine.parse(#"{"seq":2,"run_id":"r1","kind":"preparing"}"#)!
        check(preparing.event == .preparing, "a kind with no fields")
        check(ProtocolLine.parse("not json") == nil && ProtocolLine.parse("[1]") == nil && ProtocolLine.parse("") == nil, "not an object: no line")
    }

    // MARK: deltas

    static func deltaTests() {
        func d(_ text: String, _ offset: Int?, id: String = "m") -> ProtocolLine {
            ProtocolLine(sessionId: "s", event: .delta(SessionDelta(msgId: id, text: text, offset: offset)))
        }
        var s = SessionReducer.reduce(SessionState(), [d("", 0), d("a😀", 0), d("b", 3)])   // 😀 is two UTF-16 units
        check(s.streamingMessage?.text == "a😀b", "offsets count UTF-16 units: \(String(describing: s.streamingMessage?.text))")
        s = SessionReducer.reduce(s, d("a😀", 0))
        check(s.message("m")?.text == "a😀b", "an earlier delta again: kept")
        s = SessionReducer.reduce(s, d("", 0))
        check(s.message("m")?.text == "a😀b", "an empty offset-0 delta clears nothing")
        s = SessionReducer.reduce(s, d("zz", 10))
        check(s.message("m")?.text == "a😀b" && s.message("m")?.gap == true, "a gap: nothing appended, marked")
        s = SessionReducer.reduce(s, d("a😀bcd", 0))
        check(s.message("m")?.text == "a😀bcd" && s.message("m")?.gap == false, "a full offset-0 delta fills it")
        s = SessionReducer.reduce(s, d("X", 4))
        check(s.message("m")?.text == "a😀bX", "a different text at an offset replaces from there")
        s = SessionReducer.reduce(s, d("Y", nil))
        check(s.message("m")?.text == "a😀bXY", "no offset: appended")
        // a failed reply: its bubble leaves
        let failed = SessionReducer.reduce(s, ProtocolLine(seq: 1, sessionId: "s", event: .sessionError(SessionErrorEvent(code: "network", text: "x", msgId: "m"))))
        check(failed.message("m") == nil && failed.errors.count == 1 && failed.timeline == [.error(1)], "session.error with msg_id: the bubble goes, the error stays")
        // the final message ends the stream; later deltas change nothing
        let fin = SessionReducer.reduce(s, [ProtocolLine(seq: 1, sessionId: "s", event: .message(SessionMessage(msgId: "m", role: "assistant", text: "final"))), d("late", 5)])
        check(fin.message("m")?.text == "final" && fin.message("m")?.streaming == false, "final wins")
        // retry: the earlier answer leaves the context
        let retried = SessionReducer.reduce(fin, ProtocolLine(seq: 2, sessionId: "s", event: .retry(SessionRetry(replyTo: "u1"))))
        check(retried.message("m")?.retracted == false, "retry of another message: untouched")
    }

    // MARK: cards

    /// deskmind#102 / #103's cases: every card kind the harness sends and one it does not (yet). Each button sends its own
    /// option's index with the card's ask_id; nothing collapses into "approve".
    static func cardModelTests() {
        let opt = { (kind: String, text: String) in CardOption(kind: kind, text: text) }
        let cases: [(kind: String, options: [CardOption], free: Bool, roles: [CardModel.Role], float: Bool)] = [
            ("plan", [opt("approve", "可以，就这样做"), opt("cancel", "先别做了")], true, [.approve, .cancel], false),
            ("action", [opt("approve", "可以"), opt("skip_step", "这一步不要，其余照做"), opt("cancel", "先别做了")], false, [.approve, .skipStep, .cancel], true),
            ("result_check", [opt("approve", "对"), opt("undo", "不对，撤回刚才做的")], true, [.approve, .undo], true),
            ("missing", [opt("value", "a.txt"), opt("value", "b.txt"), opt("delegate", "由你决定"), opt("cancel", "先别做了")], true, [.choice, .choice, .delegate, .cancel], true),
            ("ambiguity", [opt("reading", "改 a.txt"), opt("reading", "改 b.txt"), opt("delegate", "由你决定"), opt("cancel", "先别做了")], true, [.choice, .choice, .delegate, .cancel], true),
            ("cannot", [opt("cancel", "好的，先这样")], false, [.cancel], true),
            ("cannot", [opt("cancel", "好的，先这样")], true, [.cancel], false),     // nothing to pick but the way out, and words: main window
            ("reconcile", [opt("approve", "继续"), opt("cancel", "先停下")], false, [.approve, .cancel], true),
            ("some_new_kind", [opt("other", "甲"), opt("approve", "乙"), opt("value", "丙")], true, [.other, .approve, .choice], true),
            ("missing", (1...4).map { opt("value", "f\($0).txt") } + [opt("cancel", "先别做了")], true, [.choice, .choice, .choice, .choice, .cancel], false),   // a long list
        ]
        for c in cases {
            let ev = CardEvent(kind: c.kind, text: "?", options: c.options, freeText: c.free, blocking: true)
            let card = CardModel(card: ev, runId: "run_1", askId: "ask_\(c.kind)")
            check(card.buttons.map(\.role) == c.roles, "\(c.kind): roles \(card.buttons.map(\.role))")
            check(card.answerableInFloat == c.float, "\(c.kind) (free \(c.free)): float \(card.answerableInFloat)")
            check(card.allowsFreeText == c.free, "\(c.kind): free text")
            for (i, b) in card.buttons.enumerated() {
                check(b.index == i && b.text == c.options[i].text, "\(c.kind): button \(i) is option \(i)")
                check(card.answer(b) == .option(runId: "run_1", askId: "ask_\(c.kind)", option: i), "\(c.kind): button \(i) sends option \(i)")
                check(card.answer(b).control as NSDictionary == ["type": "answer", "run_id": "run_1", "ask_id": "ask_\(c.kind)", "option": i] as NSDictionary, "\(c.kind): the line for \(i)")
            }
            let approveAt = c.options.firstIndex { $0.kind == "approve" }
            for b in card.buttons where b.kind != "approve" {
                if case .option(_, _, let o) = card.answer(b) { check(o != approveAt, "\(c.kind): \(b.kind) never sends the approve option") }
            }
            check(card.answer(option: c.options.count) == nil, "\(c.kind): an option the card does not have: nothing")
            check((card.answer(text: "都不是，用 c.txt") != nil) == c.free, "\(c.kind): words only where the card takes them")
        }
        // styles by kind
        check(CardModel.style("approve") == .prominent && CardModel.style("value") == .radio && CardModel.style("undo") == .destructive
              && CardModel.style("cancel") == .bordered && CardModel.style("skip_step") == .bordered && CardModel.style("whatever") == .bordered, "styles")
        // an option with no words gets no button; the others keep the card's own index
        let gap = CardModel(card: CardEvent(kind: "missing", text: "?", options: [opt("value", "a"), opt("value", ""), opt("value", "c")], freeText: true, blocking: true), runId: "r", askId: "q")
        check(gap.buttons.map(\.index) == [0, 2] && gap.answer(gap.buttons[1]) == .option(runId: "r", askId: "q", option: 2) && gap.answer(option: 1) == nil, "shown 1 → card 2")
        // a consent card with a long list of what goes out: main window
        var consent = CardEvent(kind: "action", text: "?", options: [opt("approve", "可以"), opt("cancel", "先别做了")], freeText: false, blocking: true)
        consent.consent = ConsentFacts(action: "click", actionText: "点「发送」", target: "发送", object: "window:mail#1", objectLabel: "邮件", consequence: "external",
                                       outgoing: (1...4).map { ConsentFacts.Outgoing(kind: "field", label: "L\($0)", value: "v") }, site: nil)
        check(!CardModel(card: consent, runId: "r", askId: "a").answerableInFloat, "four outgoing lines: main window")
        consent.consent?.outgoing.removeLast()
        check(CardModel(card: consent, runId: "r", askId: "a").answerableInFloat, "three: the float")
        // a plan card from a real stream
        if let asked = after("task-card", isKind("ask")), let (runId, open) = asked.openCard {
            let card = CardModel(card: open.card, runId: runId, askId: open.askId)
            check(card.kind == .plan && !card.answerableInFloat && card.plan?.steps.count == 1, "the recorded plan card: main window only")
            check(card.answer(card.buttons[0]) == .option(runId: runId, askId: open.askId, option: 0), "approve sends 0 with the ask_id")
        } else { check(false, "the recorded plan card") }
    }

    /// Review of #103: a click on a card that is no longer open must not answer the open one.
    static func staleAnswerTests() {
        let plan = CardEvent(kind: "plan", text: "?", options: [CardOption(kind: "approve", text: "可以"), CardOption(kind: "cancel", text: "先别做了")], freeText: true, blocking: true)
        let ask = { (id: String, seq: Int) in ProtocolLine(seq: seq, runId: "r", sessionId: "s", event: .ask(AskEvent(askId: id, card: plan))) }
        var s = SessionReducer.reduce(SessionState(), [ask("ask_A", 1), ProtocolLine(seq: 2, runId: "r", sessionId: "s", event: .resumed(ResumedEvent(askId: "ask_A", voided: "steer"))),
                                                       ProtocolLine(seq: 3, runId: "r", sessionId: "s", event: .askVoid(AskVoid(askId: "ask_A", why: "steer")))])
        check(s.task("r")?.cards.first?.outcome == .void("steer") && s.composerEnabled, "A voided by a steer")
        check(SessionClient.refusal(.option(runId: "r", askId: "ask_A", option: 0), in: s) != nil, "nothing open: refused")
        s = SessionReducer.reduce(s, ask("ask_B", 4))
        let a = CardAnswer.option(runId: "r", askId: "ask_A", option: 0)
        check(SessionClient.refusal(a, in: s)?.hasPrefix("stale card") == true, "approve on A while B is open: refused")
        check(SessionClient.refusal(.text(runId: "r", askId: "ask_A", text: "x"), in: s)?.hasPrefix("stale card") == true, "words on A: refused")
        check(SessionClient.refusal(.option(runId: "r", askId: "ask_B", option: 0), in: s) == nil, "B: sent")
        check(SessionClient.refusal(.option(runId: "other", askId: "ask_B", option: 0), in: s) != nil, "another run: refused")
        // a new card while one is open (should not happen): the old one is closed as replaced
        let replaced = SessionReducer.reduce(s, ask("ask_C", 5))
        check(replaced.task("r")?.cards.first { $0.askId == "ask_B" }?.outcome == .void("replaced") && replaced.openCard?.card.askId == "ask_C", "replaced")
        // task_done with a card open: the card can no longer be answered
        let ended = SessionReducer.reduce(s, ProtocolLine(seq: 5, runId: "r", sessionId: "s", event: .taskDone(TaskDone(status: "stopped", reason: TaskDone.stepInProgressReason, summary: ""))))
        check(ended.openCard == nil && ended.task("r")?.cards.last?.outcome == .void("task_done"), "task_done voids the open card")
        // steps with no result when the task ends: the one with the driver is unknown, earlier ones not finished
        let step = { (id: String, seq: Int) in ProtocolLine(seq: seq, runId: "q", sessionId: "s", event: .step(StepEvent(text: "{}", stepId: id))) }
        let cut = SessionReducer.reduce(SessionState(), [step("s1", 1), step("s2", 2),
                                                         ProtocolLine(seq: 3, runId: "q", sessionId: "s", event: .taskDone(TaskDone(status: "stopped", reason: TaskDone.stepInProgressReason, summary: "")))])
        check(cut.task("q")?.steps.map(\.status) == [.notFinished, .unknown], "the step in progress: unknown: \(String(describing: cut.task("q")?.steps.map(\.status)))")
        let clean = SessionReducer.reduce(SessionState(), [step("s1", 1), ProtocolLine(seq: 2, runId: "q", sessionId: "s", event: .taskDone(TaskDone(status: "stopped", reason: "stopped by the app", summary: "")))])
        check(clean.task("q")?.steps.map(\.status) == [.notFinished], "a clean stop: not finished")
        // shots come late
        let shot = SessionReducer.reduce(SessionState(), [step("s1", 1),
            ProtocolLine(seq: 2, runId: "q", sessionId: "s", event: .stepResult(StepResultEvent(stepId: "s1", status: "ok", shot: "shots/s1.png", shotPending: true, targetFrame: Frame(x: 1, y: 2, w: 3, h: 4)))),
            ProtocolLine(seq: 3, runId: "q", sessionId: "s", event: .taskDone(TaskDone(status: "succeeded", reason: "ok", summary: ""))),
            ProtocolLine(seq: 4, runId: "q", sessionId: "s", event: .shotReady(ShotReady(stepId: "s1", shot: "shots/s1.png")))])
        let s1 = shot.task("q")?.steps.first
        check(s1?.status == .ok && s1?.shot == "shots/s1.png" && s1?.shotPending == false && s1?.targetFrame == Frame(x: 1, y: 2, w: 3, h: 4), "shot_ready after task_done")
    }

    // MARK: the client

    final class MockTransport: SessionTransport {
        var requests: [[String: Any]] = []
        var replies: [String: [String: Any]] = [:]
        var streamLines: [[String: Any]] = []
        func request(_ body: [String: Any]) -> [String: Any]? {
            requests.append(body)
            return replies[body["op"] as? String ?? ""]
        }
        func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Void) -> Bool {
            requests.append(body)
            streamLines.forEach(onLine)
            return true
        }
    }

    static func clientTests() {
        let mock = MockTransport()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "ses_t"], SessionClient.Op.send: ["ok": true], SessionClient.Op.end: ["ok": true],
                        SessionClient.Op.list: ["ok": true, "sessions": [["session_id": "ses_t", "title": "把笔记的正文改成…", "updated_at": 1.5,
                                                                          "last_message": ["role": "assistant", "text": "改好了"]], ["title": "no id"]]]]
        let client = SessionClient(transport: mock)
        check(client.open(lang: "zh") == "ses_t", "open: the session's id")
        check(mock.requests.last as NSDictionary? == ["op": "session.open", "lang": "zh"] as NSDictionary, "open request")
        check(client.list() == [SessionSummary(sessionId: "ses_t", title: "把笔记的正文改成…", updatedAt: 1.5, lastMessage: ("assistant", "改好了"))], "list")
        var changes = 0
        client.onChange = { _, _ in changes += 1 }
        // the stream, fed through watch: the same state as the reducer's
        let recorded = raw("task-card").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        let askAt = recorded.firstIndex { $0["kind"] as? String == "ask" }!
        mock.streamLines = Array(recorded[...askAt])
        check(client.watch(), "watch")
        check(mock.requests.last?["op"] as? String == "sessions.watch", "watch request")
        check(client.state("ses_t") == SessionReducer.reduce(SessionState(), lines("task-card").prefix(askAt + 1).map { $0 }), "the client's state is the reducer's")
        check(changes > 0, "onChange called")
        // a card waits: typing is not sent; a stale answer is not sent; the open card's answer is
        let n = mock.requests.count
        check(client.send(.say("顺便说一句"), to: "ses_t") == .refused("card_open") && mock.requests.count == n, "say while a card waits: not sent")
        check(client.send(.steer("改成别的"), to: "ses_t") == .refused("card_open"), "steer too")
        check(client.send(.stop(), to: "ses_t") == .sent, "stop is always sent")
        let (runId, open) = client.state("ses_t").openCard!
        check(client.answer(.option(runId: runId, askId: "ask_old", option: 0), in: "ses_t") != .sent, "a stale answer: not sent")
        check(client.answer(.option(runId: runId, askId: open.askId, option: 0), in: "ses_t") == .sent, "the open card's answer: sent")
        check(mock.requests.last as NSDictionary? == ["op": "session.send", "session_id": "ses_t",
                                                      "line": ["type": "answer", "run_id": runId, "ask_id": open.askId, "option": 0]] as NSDictionary, "the answer line, by index with ask_id")
        // the rest of the stream: the card is answered, typing goes again
        mock.streamLines = Array(recorded[(askAt + 1)...])
        client.watch()
        let watch = mock.requests.last!
        check((watch["after"] as? [String: Int])?["ses_t"] == 2 && (watch["runs"] as? [String: Int])?[runId] == 7, "watch says what the app has: \(watch)")
        check(client.state("ses_t") == final("task-card"), "the whole stream: the reducer's final state")
        check(client.send(.say("好"), to: "ses_t") == .sent, "no card: say is sent")
        check(mock.requests.last as NSDictionary? == ["op": "session.send", "session_id": "ses_t", "line": ["type": "say", "text": "好"]] as NSDictionary, "say line")
        // a line from another session goes to that session; one with none is left
        client.feed(["kind": "session.queue", "session_id": "ses_2", "items": [["id": "q1", "text": "x"]]])
        client.feed(["kind": "session.queue", "items": [["id": "q1", "text": "x"]]])
        check(client.state("ses_2").queue.map(\.text) == ["x"] && Set(client.sessionIds) == ["ses_t", "ses_2"], "per session")
        check(client.end("ses_t") && mock.requests.last as NSDictionary? == ["op": "session.end", "session_id": "ses_t"] as NSDictionary, "end")
        // the helper not answering
        mock.replies = [:]
        check(client.send(.retry, to: "ses_t") == .unavailable && client.open() == nil && client.list() == nil, "no helper: unavailable")
        // the control lines
        check(SessionControl.cua("新建 a.txt", scope: "/tmp/x").line as NSDictionary == ["type": "cua", "text": "新建 a.txt", "scope": "/tmp/x"] as NSDictionary, "cua line")
        check(SessionControl.stop(runId: "r").line as NSDictionary == ["type": "stop", "run_id": "r"] as NSDictionary, "stop line")
        check(SessionControl.attach(afterSeq: 3).line as NSDictionary == ["type": "attach", "after_seq": 3] as NSDictionary, "attach line")
        check(SessionControl.queueSendNow(id: "q").line as NSDictionary == ["type": "queue_send_now", "id": "q"] as NSDictionary, "queue_send_now line")
        // markSeen clears the error dot through the client
        let errClient = SessionClient(transport: MockTransport())
        lines("chat-error").forEach(errClient.feed)
        check(errClient.state("ses_t").status == .error("no_key"), "error via the client")
        errClient.markSeen("ses_t")
        check(errClient.state("ses_t").status == .idle, "seen via the client")
    }
}
