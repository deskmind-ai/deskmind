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
        orderTests()
        undoOrderTests()
        resentAskTests()
        causeTests()
        sessionExitTests()
        clientGapTests()
        cardIdentityTests()
        steerLookOnlyTests()
        wireNeverCrashesTests()
        crossStreamTests()
        exitLeftoversTests()
        interleavingPropertyTests()
        rereviewTests()
        processInterleavingTests()
        ownershipTests()
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
        check(card.answer(undo)!.control as NSDictionary == ["type": "respond", "run_id": t.runId, "option": 1] as NSDictionary, "respond line")
        check(SessionClient.refusal(card.answer(undo)!, in: done) == nil, "the result card can be answered")
        let undone = after(n, isKind("result_response"))!
        check(undone.tasks[0].undo == .done(undone: 1, total: 1, refused: nil), "undone 1/1: \(undone.tasks[0].undo)")
        check(SessionClient.refusal(card.answer(undo)!, in: undone) != nil, "answered once: no second answer")
        let s = final(n)
        check(s.tasks[0].undo == .done(undone: 1, total: 1, refused: nil) && s.tasks[0].closed == "linger", "closed after undo keeps the result")
        // a lingering result card whose executor closes unanswered: expired
        var expired = done
        expired = SessionReducer.reduce(expired, ProtocolLine(seq: done.lastSeq + 1, sessionId: "ses_t", event: .taskClosed(SessionTaskClosed(runId: t.runId, why: "new_task"))))
        check(expired.tasks[0].undo == .expired("new_task"), "a new task elsewhere: undo expired")
        check(SessionClient.refusal(card.answer(undo)!, in: expired) != nil, "an expired result card is not answered")
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
        check(!card.answerableInFloat && !card.freeTextInFloat, "a card that takes words: the whole card in the main window (owner 10-22)")
        check(card.answer(text: " 叫 c.txt ") == .text(runId: runId, askId: open.askId, text: "叫 c.txt"), "words are sent as words")
        check(card.answer(text: "a.txt") == .text(runId: runId, askId: open.askId, text: "a.txt"), "words that match an option are still words")
        check(card.answer(text: "  ") == nil, "empty words: nothing")
        check(card.answer(card.buttons[1])!.control as NSDictionary == ["type": "answer", "run_id": runId, "ask_id": open.askId, "option": 1] as NSDictionary, "option line")
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
        check(final(n).tasks[0].done?.cause == .screenLocked && final(n).tasks[0].end?.cause == .screenLocked, "recorded with cause (harness ed96440)")
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
        let future = ProtocolLine.parse(#"{"seq":1,"t":1,"session_id":"s","kind":"session.future","x":{"y":[1,true,null]}}"#)!
        check(future.event == .unknown(kind: "session.future", raw: .object(["seq": .number(1), "t": .number(1), "session_id": .string("s"), "kind": .string("session.future"),
                                                                            "x": .object(["y": .array([.number(1), .bool(true), .null])])])), "an unknown session kind is kept whole")
        var s = SessionReducer.reduce(SessionState(), future)
        check(s.unknownKinds == ["session.future"] && s.lastSeq == 1, "it is noted, and its seq counts")
        let exec = ProtocolLine.parse(#"{"seq":1,"run_id":"r1","session_id":"s","kind":"hover","where":"x"}"#)!
        s = SessionReducer.reduce(s, exec)
        check(s.unknownKinds == ["session.future", "hover"] && s.task("r1")?.lastSeq == 1, "an unknown executor kind: noted, its seq counts")
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
            ("result_check", [opt("approve", "对"), opt("undo", "不对，撤回刚才做的")], true, [.approve, .undo], false),    // free text: main window (owner 10-22)
            ("result_check", [opt("approve", "对"), opt("undo", "不对，撤回刚才做的")], false, [.approve, .undo], true),
            ("missing", [opt("value", "a.txt"), opt("value", "b.txt"), opt("delegate", "由你决定"), opt("cancel", "先别做了")], true, [.choice, .choice, .delegate, .cancel], false),
            ("missing", [opt("value", "a.txt"), opt("value", "b.txt"), opt("delegate", "由你决定"), opt("cancel", "先别做了")], false, [.choice, .choice, .delegate, .cancel], true),
            ("ambiguity", [opt("reading", "改 a.txt"), opt("reading", "改 b.txt"), opt("delegate", "由你决定"), opt("cancel", "先别做了")], true, [.choice, .choice, .delegate, .cancel], false),
            ("cannot", [opt("cancel", "好的，先这样")], false, [.cancel], true),
            ("cannot", [opt("cancel", "好的，先这样")], true, [.cancel], false),     // nothing to pick but the way out, and words: main window
            ("reconcile", [opt("approve", "继续"), opt("cancel", "先停下")], false, [.approve, .cancel], true),
            ("some_new_kind", [opt("other", "甲"), opt("approve", "乙"), opt("value", "丙")], true, [.other, .approve, .choice], false),
            ("some_new_kind", [opt("other", "甲"), opt("approve", "乙"), opt("value", "丙")], false, [.other, .approve, .choice], true),
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
                check(card.answer(b)!.control as NSDictionary == ["type": "answer", "run_id": "run_1", "ask_id": "ask_\(c.kind)", "option": i] as NSDictionary, "\(c.kind): the line for \(i)")
            }
            let approveAt = c.options.firstIndex { $0.kind == "approve" }
            for b in card.buttons where b.kind != "approve" {
                if case .option(_, _, let o)? = card.answer(b) { check(o != approveAt, "\(c.kind): \(b.kind) never sends the approve option") }
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
        let ended = SessionReducer.reduce(s, ProtocolLine(seq: 5, runId: "r", sessionId: "s", event: .taskDone(TaskDone(status: "stopped", reason: "a step was in progress; its result is unknown", summary: "", cause: .lastStepUnknown))))
        check(ended.openCard == nil && ended.task("r")?.cards.last?.outcome == .void("task_done"), "task_done voids the open card")
        // steps with no result when the task ends: the one with the driver is unknown, earlier ones not finished
        let step = { (id: String, seq: Int) in ProtocolLine(seq: seq, runId: "q", sessionId: "s", event: .step(StepEvent(text: "{}", stepId: id))) }
        let cut = SessionReducer.reduce(SessionState(), [step("s1", 1), step("s2", 2),
                                                         ProtocolLine(seq: 3, runId: "q", sessionId: "s", event: .taskDone(TaskDone(status: "stopped", reason: "a step was in progress; its result is unknown", summary: "", cause: .lastStepUnknown)))])
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
        /// Replies given once each, before `replies`, per op.
        var queued: [String: [[String: Any]]] = [:]
        /// Called with each request's op before it is answered (a line the helper streams meanwhile).
        var onRequest: ((String) -> Void)? = nil
        func request(_ body: [String: Any]) -> [String: Any]? {
            requests.append(body)
            let op = body["op"] as? String ?? ""
            onRequest?(op)
            if var q = queued[op], !q.isEmpty { let r = q.removeFirst(); queued[op] = q; return r }
            return replies[op]
        }
        /// Each watch's lines from its number (1, 2, …), when set; a guard ends a run-away loop.
        var gen: ((Int) -> [[String: Any]])? = nil
        var watches = 0
        /// Each watch takes the next of these, if any; else `streamLines`.
        var nextStreams: [[[String: Any]]] = []
        /// The clock the client reads (SessionClient.now): a quiet stream moves it on by `quiet` before asking onIdle.
        var clock = Date(timeIntervalSince1970: 0)
        var quiet: TimeInterval = 5
        func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool {
            requests.append(body)
            watches += 1
            if watches > 50 { return true }
            let lines = gen.map { $0(watches) } ?? (nextStreams.isEmpty ? streamLines : nextStreams.removeFirst())
            for l in lines where !onLine(l) { return true }
            clock += quiet
            _ = onIdle()
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
        client.newClientId = { "c_fixed" }
        check(client.send(.say("好"), to: "ses_t") == .sent, "no card: say is sent")
        check(mock.requests.last as NSDictionary? == ["op": "session.send", "session_id": "ses_t", "line": ["type": "say", "text": "好", "client_id": "c_fixed"]] as NSDictionary, "say line, with its client_id")
        check(client.state("ses_t").outbox == [Outgoing(id: "c_fixed", text: "好", control: "say", sending: true)] && client.state("ses_t").unsent.isEmpty, "sent: held as sending, not unsent")
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
        lines("chat-error").forEach { errClient.feed($0) }
        check(errClient.state("ses_t").status == .error("no_key"), "error via the client")
        errClient.markSeen("ses_t")
        check(errClient.state("ses_t").status == .idle, "seen via the client")
    }

    // MARK: order, gaps, duplicates (review of #104, B1–B5; #105's session_exit and replay order)

    static let sid = "\"session_id\":\"s\""
    static func L(_ json: String) -> ProtocolLine { ProtocolLine.parse(json)! }
    /// An executor line of run r1.
    static func ex(_ seq: Int?, _ body: String, run: String = "r1") -> ProtocolLine {
        L("{\(seq.map { "\"seq\":\($0)," } ?? "")\"run_id\":\"\(run)\",\(sid),\(body)}")
    }
    /// A session line.
    static func se(_ seq: Int?, _ body: String) -> ProtocolLine { L("{\(seq.map { "\"seq\":\($0)," } ?? "")\(sid),\(body)}") }
    static let actionCard = #""card":{"kind":"action","text":"t","options":[{"kind":"approve","text":"ok"},{"kind":"skip_step","text":"skip"},{"kind":"cancel","text":"no"}],"free_text":false,"blocking":true}"#
    static let taskR1 = se(1, #""kind":"session.task","msg_id":"m","run_id":"r1","raw":"x","by":"slash""#)

    /// The run lines of a recorded stream moved so that its seq 1 and 2 come right after its seq 8 (#105 review).
    static func reorderedRun(_ ls: [ProtocolLine]) -> [ProtocolLine] {
        let isRun = { (l: ProtocolLine) in !l.event.isSessionEvent && l.seq != nil }
        let early = ls.filter { isRun($0) && $0.seq! <= 2 }
        var out = ls.filter { !(isRun($0) && $0.seq! <= 2) }
        let at = out.firstIndex { isRun($0) && $0.seq == 8 }!
        out.insert(contentsOf: early, at: at + 1)
        return out
    }

    static func orderTests() {
        // the run's replay out of order, [3…8, 1, 2]: held, then all applied in order
        let ls = lines("task-card")
        let moved = reorderedRun(ls)
        check(moved.filter { !$0.event.isSessionEvent }.compactMap(\.seq).prefix(8) == [3, 4, 5, 6, 7, 8, 1, 2], "the order [3…8, 1, 2]")
        var s = SessionState()
        var held = false
        for l in moved {
            let r = SessionReducer.apply(&s, l)
            if l.seq.map({ $0 >= 3 && $0 <= 8 }) == true && !l.event.isSessionEvent { held = held || r == .held }
            if !l.event.isSessionEvent && l.seq == 2 { check(r == .applied && !s.hasGap && s.tasks[0].lastSeq == 8, "seq 2 fills the gap: all of 1…8 applied") }
        }
        check(held, "3…8 held back first")
        check(s == final("task-card"), "the same state as in order")
        // a gap: an ask (seq 2) after the run's seq 3; then it comes
        let start = ex(1, #""kind":"start","raw":"x""#), ask = ex(2, #""kind":"ask","ask_id":"a1","# + actionCard)
        let waiting = ex(3, #""kind":"waiting","ask_id":"a1""#)
        s = SessionReducer.reduce(SessionState(), [taskR1, start, waiting])
        check(s.hasGap && s.pendingRuns["r1"]?.keys.sorted() == [3] && s.task("r1")?.lastSeq == 1, "seq 3 past a gap: held, cursor 1")
        check(SessionReducer.apply(&s, waiting) == .held && s.pendingRuns["r1"]?.count == 1, "held again: kept once")
        check(SessionReducer.apply(&s, ask) == .applied && !s.hasGap && s.task("r1")?.lastSeq == 3, "the late ask applies, then the held line")
        check(s.openCard?.card.askId == "a1", "the late card is open, not lost")
        check(SessionReducer.apply(&s, ask) == .duplicate && SessionReducer.apply(&s, waiting) == .duplicate, "replays of either: duplicates")
        // a late resumed (seq 3) after a step (seq 4): the card closes once it comes
        let step = ex(4, #""kind":"step","text":"x","step_id":"st""#), resumed = ex(3, #""kind":"resumed","ask_id":"a1""#)
        s = SessionReducer.reduce(SessionState(), [taskR1, start, ask, step])
        check(s.openCard != nil && s.hasGap && s.task("r1")?.steps.isEmpty == true, "the step waits for the resumed")
        s = SessionReducer.reduce(s, resumed)
        check(s.openCard == nil && s.composerEnabled && s.task("r1")?.steps.count == 1 && s.task("r1")?.cards.first?.outcome == .answered, "resumed then step: closed, composer on")
        // the session stream: seq 3 before 2
        let m2 = se(2, #""kind":"session.message","msg_id":"u2","role":"user","text":"b""#), m3 = se(3, #""kind":"session.message","msg_id":"u3","role":"user","text":"c""#)
        let m1 = se(1, #""kind":"session.message","msg_id":"u1","role":"user","text":"a""#)
        s = SessionReducer.reduce(SessionState(), [m1, m3])
        check(s.lastSeq == 1 && s.pendingSession.keys.sorted() == [3] && s.messages.map(\.text) == ["a"], "session seq 3 held")
        s = SessionReducer.reduce(s, [m2, m3, m1])
        check(s.lastSeq == 3 && !s.hasGap && s.messages.map(\.text) == ["a", "b", "c"], "then in order, replays dropped")
        // the cursor names a run known from session.task with nothing of it yet, and a run known only from held lines
        let c = SessionClient(transport: MockTransport())
        c.feed(se(1, #""kind":"session.task","msg_id":"m","run_id":"r9","raw":"x","by":"slash""#))
        c.feed(ex(3, #""kind":"preparing""#, run: "r8"))
        c.feed(se(3, #""kind":"session.task","msg_id":"m","run_id":"r7","raw":"y","by":"slash""#))
        let cur = c.cursor()
        check(cur.after["s"] == 1 && cur.runs["r9"] == 0 && cur.runs["r8"] == 0 && cur.runs["r7"] == 0, "cursor: runs at 0: \(cur)")
    }

    static func undoOrderTests() {
        let start = ex(1, #""kind":"start","raw":"x""#)
        let done = ex(2, #""kind":"task_done","status":"succeeded","reason":"","summary":"","result_card":{"kind":"result","text":"r","options":[{"kind":"approve","text":"ok"},{"kind":"undo","text":"undo"}]}"#)
        let endNone = se(2, #""kind":"session.task_end","run_id":"r1","status":"succeeded","summary":"","undo":"none""#)
        let endOpen = se(2, #""kind":"session.task_end","run_id":"r1","status":"succeeded","summary":"","undo":"open""#)
        let closed = se(3, #""kind":"session.task_closed","run_id":"r1","why":"session_end""#)
        var s = SessionReducer.reduce(SessionState(), [taskR1, start, endNone, closed, done])
        check(s.task("r1")?.undo == UndoState.none && s.task("r1")?.closed == "session_end", "task_end (none) + closed before task_done: no undo: \(String(describing: s.task("r1")?.undo))")
        check(SessionClient.refusal(.respond(runId: "r1", option: 1), in: s) != nil, "and the result card is not answered")
        s = SessionReducer.reduce(SessionState(), [taskR1, start, done, endNone])
        check(s.task("r1")?.undo == UndoState.none, "task_done then task_end (none): no undo")
        s = SessionReducer.reduce(SessionState(), [taskR1, start, done])
        check(s.task("r1")?.undo == .available, "task_done alone, an undo option: available")
        s = SessionReducer.reduce(SessionState(), [taskR1, start, endOpen, closed, done])
        check(s.task("r1")?.undo == .expired("session_end"), "task_end (open) + closed before task_done: expired")
        s = SessionReducer.reduce(SessionState(), [taskR1, start, closed, done, endOpen].map { $0 })
        check(s.task("r1")?.undo != .available, "closed first in any order: never available")
    }

    static func resentAskTests() {
        let start = ex(1, #""kind":"start","raw":"x""#), ask = ex(2, #""kind":"ask","ask_id":"a1","# + actionCard)
        let answered = SessionReducer.reduce(SessionState(), [taskR1, start, ask, ex(3, #""kind":"resumed","ask_id":"a1""#)])
        let again = SessionReducer.reduce(answered, ex(nil, #""kind":"ask","ask_id":"a1","# + actionCard))
        check(again.openCard == nil && again.composerEnabled && again.task("r1")?.cards.map(\.outcome) == [.answered], "an ask re-sent after its answer: stays answered")
        check(SessionClient.refusal(.option(runId: "r1", askId: "a1", option: 0), in: again) != nil, "and is not answered again")
        // a different card asked while another is open still replaces it; a voided card re-sent stays voided
        let voided = SessionReducer.reduce(answered, [ex(4, #""kind":"ask","ask_id":"a2","# + actionCard), ex(5, #""kind":"ask_void","ask_id":"a2","why":"steer""#),
                                                      ex(nil, #""kind":"ask","ask_id":"a2","# + actionCard)])
        check(voided.openCard == nil && voided.task("r1")?.cards.last?.outcome == .void("steer"), "a voided card re-sent: stays voided")
        // B4: a button from another card answers nothing
        let a = CardModel(card: CardEvent(kind: "action", text: "?", options: [CardOption(kind: "approve", text: "ok")], freeText: false, blocking: true), runId: "r1", askId: "a1")
        let b = CardModel(card: CardEvent(kind: "missing", text: "?", options: [CardOption(kind: "value", text: "x"), CardOption(kind: "value", text: "y"), CardOption(kind: "cancel", text: "no")],
                                          freeText: false, blocking: true), runId: "r1", askId: "a2")
        check(a.answer(b.buttons[2]) == nil && a.answer(b.buttons[0]) == nil && b.answer(b.buttons[2]) == .option(runId: "r1", askId: "a2", option: 2), "another card's button: nil, no crash")
    }

    static func causeTests() {
        let start = ex(1, #""kind":"start","raw":"x""#)
        let fold = { (more: [ProtocolLine]) in SessionReducer.reduce(SessionState(), [taskR1, start] + more) }
        // locked from cause, whatever the reason says
        var s = fold([ex(2, #""kind":"task_done","status":"environment","reason":"timed out; the screen is locked","summary":"","cause":"screen_locked""#)])
        check(s.status == .locked && s.task("r1")?.cause == .screenLocked, "cause screen_locked: locked: \(s.status)")
        let novel = ex(2, #""kind":"task_done","status":"environment","reason":"the screen is locked","summary":"","cause":"something_new""#)
        if case .taskDone(let d) = novel.event { check(d.cause == nil && d.status == "environment", "an unknown cause reads as none, the line still reads") }
        else { check(false, "task_done with an unknown cause decodes") }
        s = fold([novel])
        check(s.status == .error("environment"), "an unknown cause, even with the old words: not locked: \(s.status)")
        s = fold([ex(2, #""kind":"task_done","status":"environment","reason":"the screen is locked","summary":"","cause":7"#)])
        check(s.task("r1")?.done?.cause == nil && s.task("r1")?.done != nil, "a cause of another type: none")
        s = fold([se(2, #""kind":"session.task_end","run_id":"r1","status":"environment","summary":"","undo":"none","reason":"x","cause":"screen_locked""#)])
        check(s.status == .locked, "session.task_end's cause, without task_done: locked: \(s.status)")
        s = fold([ex(2, #""kind":"task_done","status":"environment","reason":"the screen is locked","summary":"""#)])
        check(s.status == .error("environment"), "no cause, the very words: not locked (the reason is never read)")
        // the step with the driver: unknown from cause only
        let st = ex(2, #""kind":"step","text":"x","step_id":"s1""#)
        s = fold([st, ex(3, #""kind":"task_done","status":"stopped","reason":"stopped by the app","summary":"","cause":"last_step_unknown""#)])
        check(s.task("r1")?.steps.map(\.status) == [.unknown], "cause last_step_unknown: the step is unknown")
        s = fold([st, ex(3, #""kind":"task_done","status":"stopped","reason":"a step was in progress; its result is unknown","summary":"","cause":"user_stopped""#)])
        check(s.task("r1")?.steps.map(\.status) == [.notFinished], "cause user_stopped, whatever the words: not finished")
        s = fold([st, se(2, #""kind":"session.task_end","run_id":"r1","status":"interrupted","summary":"","undo":"none","cause":"last_step_unknown""#)])
        check(s.task("r1")?.steps.map(\.status) == [.unknown], "task_end's cause too")
        // cause round-trips
        let l = ex(3, #""kind":"task_done","status":"stopped","reason":"","summary":"","cause":"user_stopped""#)
        if let d = try? JSONEncoder().encode(l), let back = ProtocolLine.parse(d) { check(back == l, "cause round-trips") } else { check(false, "cause encodes") }
    }

    static func sessionExitTests() {
        let exit = L(#"{"kind":"helper.session_exit","session_id":"s","code":9}"#)
        check(exit.event == .sessionExit(HelperSessionExit(code: 9)) && exit.event.isSessionEvent, "helper.session_exit decodes")
        let start = ex(1, #""kind":"start","raw":"x""#), ask = ex(2, #""kind":"ask","ask_id":"a1","# + actionCard)
        let waiting = SessionReducer.reduce(SessionState(), [taskR1, start, ask, se(nil, #""kind":"session.delta","msg_id":"d","text":"","offset":0"#)])
        check(!waiting.composerEnabled && waiting.runningTask != nil, "a card waits")
        let s = SessionReducer.reduce(waiting, exit)
        check(s.exited == 9 && s.runningTask == nil && s.openCard == nil && s.composerEnabled, "exited: nothing runs, no card, the composer is on")
        check(s.task("r1")?.cards.first?.outcome == .void("session_exit") && s.streamingMessage == nil, "the card voided, no reply streaming")
        check(SessionClient.refusal(.option(runId: "r1", askId: "a1", option: 0), in: s) != nil, "its card is not answered")
        check(s.status != .waitingForYou(cardKind: "action") && s.status != .thinking, "the dot no longer waits: \(s.status)")
        // a lingering result card goes with the process
        let done = ex(2, #""kind":"task_done","status":"succeeded","reason":"","summary":"","result_card":{"kind":"result","text":"r","options":[{"kind":"undo","text":"undo"}]}"#)
        let lingering = SessionReducer.reduce(SessionState(), [taskR1, start, done, exit])
        check(lingering.task("r1")?.undo == .expired("session_exit") && SessionClient.refusal(.respond(runId: "r1", option: 0), in: lingering) != nil, "undo expired with the process")
        check(SessionReducer.reduce(s, se(nil, #""kind":"session.start","resumed":true"#)).exited == nil, "a new session.start clears it")
        // the client opens it again, as it was opened, on the next send
        let mock = MockTransport()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "s"], SessionClient.Op.send: ["ok": true]]
        let client = SessionClient(transport: mock)
        _ = client.open(sessionId: "s", lang: "zh")
        [taskR1, start, ask, exit].forEach { client.feed($0) }
        check(client.state("s").exited == 9, "the client sees the exit")
        mock.requests = []
        check(client.send(.say("还在吗"), to: "s") == .sent, "say after the exit: sent")
        check(mock.requests.map { $0["op"] as? String ?? "" } == ["session.open", "session.send"] && mock.requests[0]["session_id"] as? String == "s"
              && mock.requests[0]["lang"] as? String == "zh", "session.open with the same id first: \(mock.requests)")
        check(client.state("s").exited == nil, "opened: no longer exited")
        mock.requests = []
        _ = client.send(.say("再一句"), to: "s")
        check(mock.requests.map { $0["op"] as? String ?? "" } == ["session.send"], "open once only")
        // and on a watch
        client.feed(exit)
        mock.requests = []
        mock.streamLines = []
        client.watch()
        check(mock.requests.map { $0["op"] as? String ?? "" } == ["session.open", "sessions.watch"], "watch opens it again first: \(mock.requests.map { $0["op"] ?? "" })")
        // a stop to an exited session opens nothing
        client.feed(exit)
        mock.requests = []
        check(client.send(.stop(), to: "s") != .sent && mock.requests.isEmpty, "stop after the exit: nothing to stop, not opened")
        // the app ended it: its exit (code 0) is expected; neither a watch nor a send brings it back
        mock.replies[SessionClient.Op.end] = ["ok": true]
        _ = client.open(sessionId: "s")
        check(client.end("s"), "end")
        client.feed(L(#"{"kind":"helper.session_exit","session_id":"s","code":0}"#))
        mock.requests = []
        client.watch()
        _ = client.send(.say("x"), to: "s")
        check(!mock.requests.contains { $0["op"] as? String == "session.open" }, "an ended session is not opened again: \(mock.requests.map { $0["op"] ?? "" })")
        // a session this client never opened (seen through the watch) is not opened by a watch
        let seen = SessionClient(transport: mock)
        seen.feed(L(#"{"seq":1,"session_id":"old","kind":"session.message","msg_id":"m","role":"user","text":"a"}"#))
        seen.feed(L(#"{"kind":"helper.session_exit","session_id":"old","code":1}"#))
        mock.requests = []
        seen.watch()
        check(mock.requests.map { $0["op"] as? String ?? "" } == ["sessions.watch"], "a watch does not open a session it only saw")
        // an exit this app never heard: helper.watching does not list a session it opened
        let unheard = SessionClient(transport: mock)
        _ = unheard.open(sessionId: "s")
        unheard.feed(taskR1)
        unheard.feed(ProtocolLine(seq: 1, runId: "r1", sessionId: "s", event: .ask(AskEvent(askId: "a1", card: CardEvent(kind: "action", text: "?", options: [CardOption(kind: "approve", text: "ok")], freeText: false, blocking: true)))))
        check(!unheard.state("s").composerEnabled, "a card waits")
        mock.streamLines = [["kind": "helper.watching", "open": ["other"]]]
        unheard.watch()
        check(unheard.state("s").exited != nil && unheard.state("s").composerEnabled, "not in helper.watching's open: exited, its card voided")
        mock.streamLines = [["kind": "helper.watching", "open": ["s"]]]
        let listed = SessionClient(transport: mock)
        _ = listed.open(sessionId: "s")
        listed.watch()
        check(listed.state("s").exited == nil, "listed in open: running")
        mock.streamLines = []
        // … or the exit line was missed altogether: send gets not_open, opens it again once, sends
        let fresh = SessionClient(transport: mock)
        _ = fresh.open(sessionId: "s")
        mock.queued = [SessionClient.Op.send: [["ok": false, "code": "not_open", "error": "session s is not open"]]]
        mock.requests = []
        check(fresh.send(.say("在吗"), to: "s") == .sent, "not_open: opened again and sent")
        check(mock.requests.map { $0["op"] as? String ?? "" } == ["session.send", "session.open", "session.send"], "send, open, send: \(mock.requests.map { $0["op"] ?? "" })")
    }

    static func clientGapTests() {
        let recorded = raw("task-card").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        let isRun = { (o: [String: Any]) in !(o["kind"] as? String ?? "").hasPrefix("session.") && o["seq"] != nil }
        let runId = recorded.first(where: isRun)!["run_id"] as! String
        // [3…8, 1, 2] in one replay: no watch again
        do {
            let mock = MockTransport()
            let client = SessionClient(transport: mock)
            client.now = { mock.clock }
            let early = recorded.filter { isRun($0) && ($0["seq"] as! Int) <= 2 }
            var order = recorded.filter { !(isRun($0) && ($0["seq"] as! Int) <= 2) }
            order.insert(contentsOf: early, at: order.firstIndex { isRun($0) && $0["seq"] as? Int == 8 }! + 1)
            mock.streamLines = order
            check(client.watch(), "watch")
            check(mock.requests.filter { $0["op"] as? String == "sessions.watch" }.count == 1, "an out-of-order replay within the grace: one watch")
            check(client.state("ses_t") == final("task-card"), "and the same state")
        }
        // a run's seq 5 missing from the stream: held, the stream goes quiet past the grace, watched again from the cursor
        do {
            let mock = MockTransport()
            let client = SessionClient(transport: mock)
            client.now = { mock.clock }
            let first = recorded.filter { !(isRun($0) && $0["seq"] as? Int == 5) }
            mock.nextStreams = [first, recorded.filter { isRun($0) && ($0["seq"] as! Int) >= 5 }]
            check(client.watch(), "watch with a gap")
            let watches = mock.requests.filter { $0["op"] as? String == "sessions.watch" }
            check(watches.count == 2, "watched again once: \(watches.count)")
            check((watches.last?["runs"] as? [String: Int])?[runId] == 4, "from the run's contiguous cursor 4: \(String(describing: watches.last))")
            check(client.state("ses_t") == final("task-card"), "the replay filled it: the whole stream's state")
        }
        // a gap that the helper cannot fill: a few tries, then the stream is kept
        do {
            let mock = MockTransport()
            let client = SessionClient(transport: mock)
            client.now = { mock.clock }
            mock.streamLines = recorded.filter { !(isRun($0) && $0["seq"] as? Int == 5) }
            check(client.watch(), "watch, gap never filled")
            // the first watch (from nothing), the first again (from the cursor it reached), then the stalled ones, the
            // last of which keeps its stream
            check(mock.requests.filter { $0["op"] as? String == "sessions.watch" }.count == 2 + SessionClient.maxStalledRewatches,
                  "bounded: \(mock.requests.count) watches")
            check(client.hasGap && client.state("ses_t").task(runId)?.lastSeq == 4, "the held lines wait")
        }
        let j = { (s: String) in (try! JSONSerialization.jsonObject(with: Data(s.utf8))) as! [String: Any] }
        // an unfillable gap in one session while another moves on each watch: still bounded (re-review)
        do {
            let mock = MockTransport()
            let client = SessionClient(transport: mock)
            client.now = { mock.clock }
            mock.gen = { n in
                var ls: [[String: Any]] = []
                if n == 1 {
                    ls.append(j(#"{"kind":"session.task","msg_id":"m","run_id":"r1","raw":"x","session_id":"s1","seq":1}"#))
                    ls.append(j(#"{"kind":"step","text":"x","step_id":"a","run_id":"r1","session_id":"s1","seq":5}"#))
                }
                ls.append(j("{\"kind\":\"session.message\",\"msg_id\":\"m\(n)\",\"role\":\"user\",\"text\":\"hi\",\"session_id\":\"s2\",\"seq\":\(n)}"))
                return ls
            }
            client.watch()
            check(mock.watches == 2 + SessionClient.maxStalledRewatches, "progress elsewhere is not progress: \(mock.watches) watches")
        }
        // two gaps, the second opening later: each gets its own grace (s1's at 0 s, s2's at 0.8 s; s1's fills at 0.9 s;
        // at 1.1 s s2's is 0.3 s old: no watch again)
        do {
            let mock = MockTransport()
            let client = SessionClient(transport: mock)
            client.now = { mock.clock }
            let times: [TimeInterval] = [0, 0.8, 0.85, 0.9]
            var k = 0
            client.onChange = { _, _ in mock.clock = Date(timeIntervalSince1970: times[min(k, times.count - 1)]); k += 1 }
            mock.quiet = 0.2
            mock.gen = { n in
                guard n == 1 else { return [] }
                return [j(#"{"kind":"session.message","msg_id":"a","role":"user","text":"a","session_id":"s1","seq":3}"#),
                        j(#"{"kind":"session.message","msg_id":"b","role":"user","text":"b","session_id":"s2","seq":3}"#),
                        j(#"{"kind":"session.message","msg_id":"c","role":"user","text":"c","session_id":"s1","seq":1}"#),
                        j(#"{"kind":"session.message","msg_id":"d","role":"user","text":"d","session_id":"s1","seq":2}"#)]
            }
            client.watch()
            check(mock.watches == 1 && client.state("s1").lastSeq == 3 && client.state("s2").hasGap, "a later gap's own grace: \(mock.watches) watches")
        }
    }

    // MARK: external review of e1ea7fc

    /// A stale card's button never answers a new card, even with the very same options.
    static func cardIdentityTests() {
        let same = [CardOption(kind: "approve", text: "可以"), CardOption(kind: "cancel", text: "先别做了")]
        let ev = CardEvent(kind: "action", text: "?", options: same, freeText: false, blocking: true)
        let old = CardModel(card: ev, runId: "r1", askId: "a1"), new = CardModel(card: ev, runId: "r1", askId: "a2")
        check(old.buttons[0].askId == "a1" && old.buttons[0].runId == "r1" && old.buttons[0] != new.buttons[0], "a button carries its card")
        check(new.answer(old.buttons[0]) == nil && new.answer(old.buttons[1]) == nil, "the old card's button on the new card: nothing")
        check(new.answer(new.buttons[0]) == .option(runId: "r1", askId: "a2", option: 0), "its own button: its ask_id")
        check(CardModel.answer(old.buttons[0]) == .option(runId: "r1", askId: "a1", option: 0), "a button answers its own card")
        let otherRun = CardModel(card: ev, runId: "r2", askId: "a1")
        check(otherRun.answer(old.buttons[0]) == nil, "same ask_id, another run: nothing")
        let result = CardEvent(kind: "result", text: "r", options: [CardOption(kind: "approve", text: "好"), CardOption(kind: "undo", text: "撤回")])
        let res1 = CardModel(resultCard: result, runId: "r1"), res2 = CardModel(resultCard: result, runId: "r2")
        check(res2.answer(res1.buttons[1]) == nil && CardModel.answer(res1.buttons[1]) == .respond(runId: "r1", option: 1), "result cards: by run")
        // through the client: a1 answered, a2 open with the same options; a click on a1's button is refused
        let mock = MockTransport()
        mock.replies = [SessionClient.Op.send: ["ok": true]]
        let client = SessionClient(transport: mock)
        let card = #""card":{"kind":"action","text":"?","options":[{"kind":"approve","text":"可以"},{"kind":"cancel","text":"先别做了"}],"free_text":false,"blocking":true}"#
        [taskR1, ex(1, #""kind":"start","raw":"x""#), ex(2, #""kind":"ask","ask_id":"a1","# + card), ex(3, #""kind":"resumed","ask_id":"a1""#),
         ex(4, #""kind":"ask","ask_id":"a2","# + card)].forEach { client.feed($0) }
        mock.requests = []
        check(client.click(old.buttons[0], in: "s") == .refused("stale card: a1 is not the open card a2") && mock.requests.isEmpty, "the old card's approve: refused, not sent")
        check(client.click(new.buttons[1], in: "s") == .sent, "the open card's button: sent")
        check((mock.requests.last?["line"] as? [String: Any]).map { $0 as NSDictionary } == ["type": "answer", "run_id": "r1", "ask_id": "a2", "option": 1] as NSDictionary, "with its own ask_id")
    }

    /// The executor drops "only look for evidence" when it applies a steer (harness ed96440, applySteers).
    static func steerLookOnlyTests() {
        let s = SessionReducer.reduce(SessionState(), [taskR1, ex(1, #""kind":"start","raw":"x""#), ex(2, #""kind":"step","text":"x","step_id":"s1""#),
                                                       ex(3, #""kind":"step_result","step_id":"s1","status":"ok""#),
                                                       ex(4, #""kind":"verify","verdict":"unknown","reason":"r","missing_kind":"evidence""#)])
        check(s.status == .lookOnly, "look only after the verdict")
        let steered = SessionReducer.reduce(s, [se(2, #""kind":"session.steer","run_id":"r1","text":"改成 b""#), ex(5, #""kind":"steered","text":"改成 b""#)])
        check(!steered.task("r1")!.lookOnly && steered.status == .acting(step: 1, of: nil), "a steer taken: acting again: \(steered.status)")
        let sentOnly = SessionReducer.reduce(s, se(2, #""kind":"session.steer","run_id":"r1","text":"改成 b""#))
        check(sentOnly.status == .lookOnly, "sent but not yet taken: still look only")
    }

    /// Whatever comes over the wire, the app does not crash.
    static func wireNeverCrashesTests() {
        // a negative delta offset: a gap, nothing sliced
        var s = SessionReducer.reduce(SessionState(), [se(nil, #""kind":"session.delta","msg_id":"m","text":"abc","offset":0"#),
                                                       se(nil, #""kind":"session.delta","msg_id":"m","text":"x","offset":-1"#)])
        check(s.message("m")?.text == "abc" && s.message("m")?.gap == true, "offset -1: a gap, the text kept")
        s = SessionReducer.reduce(SessionState(), se(nil, #""kind":"session.delta","msg_id":"n","text":"x","offset":-5"#))
        check(s.message("n")?.text == "" && s.message("n")?.gap == true, "offset -5 on a new reply: a gap")
        s = SessionReducer.reduce(s, se(nil, #""kind":"session.delta","msg_id":"n","text":"x","offset":9223372036854775807"#))
        check(s.message("n")?.gap == true, "offset Int.max: a gap")
        let huge = ProtocolLine.parse(#"{"session_id":"s","kind":"session.delta","msg_id":"n","text":"x","offset":1e30}"#)
        check(huge != nil, "offset out of Int's range: still a line")
        _ = SessionReducer.reduce(s, huge!)
        // the helper's exit with an odd code is still an exit
        check(ProtocolLine.parse(#"{"kind":"helper.session_exit","session_id":"s","code":"x"}"#)?.event == .sessionExit(HelperSessionExit(code: nil)), "exit with a code of another type")
        // every recorded line with each number in it replaced by -1, 0, a huge value, a fraction, or a string: no crash
        func mutate(_ v: Any, _ to: Any) -> Any {
            if let o = v as? [String: Any] { return o.mapValues { mutate($0, to) } }
            if let a = v as? [Any] { return a.map { mutate($0, to) } }
            if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return to }
            return v
        }
        var fed = 0
        for n in names {
            // in place of the line, on the state just before it (a delta while its reply streams, …), and on the end state
            let before = [SessionState()] + steps(n).map(\.state)
            for (k, l) in raw(n).enumerated() {
                guard let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) else { continue }
                for to in [-1, 0, Int.max, Int.min, 1.5, 1e300, "7"] as [Any] {
                    guard let m = mutate(o, to) as? [String: Any], let d = try? JSONSerialization.data(withJSONObject: m), let pl = ProtocolLine.parse(d) else { continue }
                    var st = before[k]
                    SessionReducer.apply(&st, pl)
                    var end = before.last!
                    SessionReducer.apply(&end, pl)
                    _ = st.status; _ = st.composerEnabled
                    if let (r, c) = st.openCard {
                        let cm = CardModel(card: c.card, runId: r, askId: c.askId)
                        _ = cm.answerableInFloat; cm.buttons.forEach { _ = cm.answer($0) }
                    }
                    fed += 1
                }
            }
        }
        check(fed > 100, "mutated lines fed: \(fed)")
    }

    // MARK: the order of different streams (review of e1ea7fc, "上次 5 项")

    /// A reconnect replays the session's events before the runs': the session's end must not decide what the run says.
    static func crossStreamTests() {
        let start = ex(1, #""kind":"start","raw":"x""#), ask = ex(2, #""kind":"ask","ask_id":"a1","# + actionCard)
        let resumed = ex(3, #""kind":"resumed","ask_id":"a1""#)
        let step1 = ex(4, #""kind":"step","text":"x","step_id":"s1""#), res1 = ex(5, #""kind":"step_result","step_id":"s1","status":"ok""#)
        let step2 = ex(6, #""kind":"step","text":"y","step_id":"s2""#)
        let endInterrupted = se(2, #""kind":"session.task_end","run_id":"r1","status":"interrupted","summary":"","undo":"none","cause":"last_step_unknown""#)
        let live = SessionReducer.reduce(SessionState(), [taskR1, start, ask, resumed, step1, res1, step2, endInterrupted])
        let replay = SessionReducer.reduce(SessionState(), [taskR1, endInterrupted, start, ask, resumed, step1, res1, step2])
        check(live.task("r1")?.cards.map(\.outcome) == [.answered] && replay.task("r1")?.cards.map(\.outcome) == [.answered], "1: an answered card stays answered after a replay")
        check(live.task("r1")?.steps.map(\.status) == [.ok, .unknown], "2 live: the step in progress: unknown: \(String(describing: live.task("r1")?.steps.map(\.status)))")
        check(replay.task("r1")?.steps.map(\.status) == [.ok, .unknown], "2 replay: the same, never running: \(String(describing: replay.task("r1")?.steps.map(\.status)))")
        check(live == replay, "live and replay: the same state")
        // without a cause: not finished, still never running
        let plain = se(2, #""kind":"session.task_end","run_id":"r1","status":"interrupted","summary":"","undo":"none""#)
        let r2 = SessionReducer.reduce(SessionState(), [taskR1, plain, start, ask, resumed, step1, res1, step2])
        check(r2.task("r1")?.steps.map(\.status) == [.ok, .notFinished] && r2.status != .acting(step: 2, of: nil), "no cause: not finished")
        // a card the run never answered: void by the end, in either order; a later explicit word still wins
        let open1 = SessionReducer.reduce(SessionState(), [taskR1, plain, start, ask])
        check(open1.task("r1")?.cards.map(\.outcome) == [.void("task_done")] && open1.composerEnabled && open1.openCard == nil, "the end first: the card void, provisionally")
        let voided = SessionReducer.reduce(open1, ex(3, #""kind":"ask_void","ask_id":"a1","why":"stop""#))
        check(voided.task("r1")?.cards.map(\.outcome) == [.void("stop")], "the run's own word wins")
        // a step result after task_done (or the end) still takes its place
        let late = SessionReducer.reduce(SessionState(), [taskR1, start, ex(2, #""kind":"step","text":"x","step_id":"s1""#),
                                                          ex(3, #""kind":"task_done","status":"stopped","reason":"","summary":"","cause":"last_step_unknown""#)])
        check(late.task("r1")?.steps.map(\.status) == [.unknown], "task_done with the step open: unknown")
        let after = SessionReducer.reduce(late, ex(4, #""kind":"step_result","step_id":"s1","status":"ok""#))
        check(after.task("r1")?.steps.map(\.status) == [.ok], "its result after task_done still takes its place")
    }

    /// What the process held when it went away: a half reply, the queue; a stop that finds no process.
    static func exitLeftoversTests() {
        let exit = L(#"{"kind":"helper.session_exit","session_id":"s","code":9}"#)
        let user = se(1, #""kind":"session.message","msg_id":"u","role":"user","text":"讲个故事""#)
        let half = SessionReducer.reduce(SessionState(), [user, se(nil, #""kind":"session.delta","msg_id":"m","text":"从前","offset":0"#), exit])
        check(half.message("m")?.interrupted == true && half.message("m")?.streaming == false && half.message("m")?.text == "从前", "3: the half reply is kept, marked interrupted")
        if case .done = half.status { check(false, "3: a cut-off reply is not done: \(half.status)") }
        let fin = SessionReducer.reduce(half, se(2, #""kind":"session.message","msg_id":"m","role":"assistant","text":"从前有座山""#))
        check(fin.message("m")?.interrupted == false && fin.status == .done(at: nil, stopped: false), "its final message (if one comes) makes it done")
        // 4: the queue goes to unsent, never pending
        let q = se(nil, #""kind":"session.queue","items":[{"id":"q1","text":"一"},{"id":"q2","text":"二"}]"#)
        let gone = SessionReducer.reduce(SessionState(), [user, q, exit])
        check(gone.queue.isEmpty && gone.unsent.map(\.text) == ["一", "二"], "4: queued at the exit: unsent, not pending")
        let restarted = SessionReducer.reduce(gone, se(nil, #""kind":"session.start","resumed":true"#))
        check(restarted.queue.isEmpty && restarted.unsent.count == 2, "a new process: still unsent")
        let mock = MockTransport()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "s"], SessionClient.Op.send: ["ok": true]]
        let client = SessionClient(transport: mock)
        _ = client.open(sessionId: "s")
        [user, q, exit].forEach { client.feed($0) }
        mock.requests = []
        check(client.resend("q1", in: "s") == .sent, "重新发送: sent")
        check(mock.requests.map { $0["op"] as? String ?? "" } == ["session.open", "session.send"]
              && (mock.requests.last?["line"] as? [String: Any]).map { $0 as NSDictionary } == ["type": "say", "text": "一", "client_id": "q1"] as NSDictionary, "opened again, said with its id")
        check(client.state("s").unsent.map(\.id) == ["q2"] && client.state("s").outbox.first { $0.id == "q1" }?.sending == true, "q1 sending: not unsent, still held")
        // two resends in a row: the first taken (its stored message), the second refused busy → back in unsent
        check(client.resend("q2", in: "s") == .sent, "the second sent too")
        client.feed(se(nil, #""kind":"session.start","last_seq":1,"resumed":true"#))
        client.feed(se(2, #""kind":"session.message","msg_id":"x1","role":"user","text":"一","client_id":"q1""#))
        client.feed(se(nil, #""kind":"session.error","code":"busy","text":"a reply is still coming","control":"say","client_id":"q2""#))
        let after2 = client.state("s")
        check(after2.outbox.map(\.id) == ["q2"] && after2.unsent.first?.refused == "busy" && after2.messages.filter { $0.text == "一" }.count == 1, "q1 taken once, q2 back in unsent: \(after2.outbox)")
        // a transport failure never loses words
        mock.replies[SessionClient.Op.send] = ["ok": false]
        check(client.resend("q2", in: "s") == .unavailable && client.state("s").unsent.map(\.id) == ["q2"], "not sent: still unsent")
        mock.replies[SessionClient.Op.send] = ["ok": true]
        client.dropUnsent("q2", in: "s")
        check(client.state("s").unsent.isEmpty, "dropped")
        // 5: not_open on a stop: nothing opened, the session reads as exited
        let quiet = SessionClient(transport: mock)
        _ = quiet.open(sessionId: "s")
        quiet.feed(taskR1); quiet.feed(ex(1, #""kind":"start","raw":"x""#))
        mock.queued = [SessionClient.Op.send: [["ok": false, "code": "not_open", "error": "session s is not open"]]]
        mock.requests = []
        check(quiet.send(.stop(), to: "s") != .sent, "5: stop on a dead session: not sent")
        check(mock.requests.map { $0["op"] as? String ?? "" } == ["session.send"], "5: no session.open for a stop: \(mock.requests.map { $0["op"] ?? "" })")
        check(quiet.state("s").exited != nil && quiet.state("s").runningTask == nil, "5: exited locally, the task cut off")
        // deep nesting on a background thread's stack (512 KB): no crash
        var ok = false
        let deep = #"{"session_id":"s","kind":"session.queue","items":[],"x":"# + String(repeating: "[", count: 510) + "1" + String(repeating: "]", count: 510) + "}"
        let deepUnknown = #"{"session_id":"s","kind":"session.zzz","x":"# + String(repeating: #"{"a":"#, count: 500) + "1" + String(repeating: "}", count: 500) + "}"
        let fine = #"{"session_id":"s","kind":"session.zzz","x":"# + String(repeating: #"{"a":"#, count: 90) + "1" + String(repeating: "}", count: 90) + "}"
        let th = Thread {
            let c = SessionClient(transport: MockTransport())
            for text in [deep, deepUnknown] {
                // as the watch reads a line (DeskMindIPC.streamWhile), and as a string
                if let o = DeskMindIPC.lineObject(Data(text.utf8)) { c.feed(o) }
                _ = ProtocolLine.parse(text)
            }
            let tooDeep = c.state("s").unknownKinds.isEmpty && ProtocolLine.parse(deep) == nil
            if let o = DeskMindIPC.lineObject(Data(fine.utf8)) { c.feed(o) }
            ok = tooDeep && c.state("s").unknownKinds == ["session.zzz"]
        }
        th.stackSize = 512 * 1024
        let done = DispatchSemaphore(value: 0)
        let wrapped = Thread { th.start(); while !th.isFinished { usleep(1000) }; done.signal() }
        wrapped.start()
        done.wait()
        check(ok, "lines nested 500 deep on a 512 KB stack: left, no crash; 90 deep: read")
        check(DeskMindIPC.nestingWithin(Data(#"{"a":"[[[[[[","b":"\"[[["}"#.utf8), limit: 1), "brackets in strings do not count")
    }

    /// The final state does not depend on how the streams interleave, as long as each keeps its own order.
    static func interleavingPropertyTests() {
        func streams(_ ls: [ProtocolLine]) -> [[ProtocolLine]] {
            var keys: [String] = [], by: [String: [ProtocolLine]] = [:]
            for l in ls {
                let k = l.event.isSessionEvent ? "" : (l.runId ?? "")
                if by[k] == nil { keys.append(k) }
                by[k, default: []].append(l)
            }
            return keys.map { by[$0]! }
        }
        struct RNG { var x: UInt64; mutating func next(_ n: Int) -> Int { x = x &* 6364136223846793005 &+ 1442695040888963407; return Int((x >> 33) % UInt64(n)) } }
        func merges(_ ss: [[ProtocolLine]], seeds: Int) -> [(String, [ProtocolLine])] {
            let session = ss.first { $0.first?.event.isSessionEvent == true } ?? []
            let runs = ss.filter { $0.first?.event.isSessionEvent != true }
            var out: [(String, [ProtocolLine])] = [("session first", session + runs.flatMap { $0 }), ("runs first", runs.flatMap { $0 } + session),
                                                   ("runs first, reversed", runs.reversed().flatMap { $0 } + session)]
            for seed in 1...seeds {
                var rng = RNG(x: UInt64(seed)), idx = Array(repeating: 0, count: ss.count), m: [ProtocolLine] = []
                while m.count < ss.reduce(0, { $0 + $1.count }) {
                    let live = ss.indices.filter { idx[$0] < ss[$0].count }
                    let k = live[rng.next(live.count)]
                    m.append(ss[k][idx[k]]); idx[k] += 1
                }
                out.append(("seed \(seed)", m))
            }
            return out
        }
        func summary(_ s: SessionState) -> String {
            s.tasks.map { t in "\(t.runId) cards \(t.cards.map(\.outcome)) steps \(t.steps.map(\.status)) undo \(t.undo)" }.joined(separator: "; ")
                + " dot \(s.status) composer \(s.composerEnabled)"
        }
        // hand-built: two tasks (the first done, the second waiting on a card), an interrupted one, an open card at an end
        let card = actionCard
        let r = { (run: String, seq: Int, body: String) in ex(seq, body, run: run) }
        let multi: [ProtocolLine] = [
            se(1, #""kind":"session.message","msg_id":"u1","role":"user","text":"a""#),
            se(2, #""kind":"session.task","msg_id":"m1","run_id":"r1","raw":"a","by":"model""#),
            r("r1", 1, #""kind":"start","raw":"a""#), r("r1", 2, #""kind":"plan","steps":[{"purpose":"p"}]"#), r("r1", 3, #""kind":"ask","ask_id":"a1","# + card),
            r("r1", 4, #""kind":"resumed","ask_id":"a1""#), r("r1", 5, #""kind":"consent","picked":"action""#), r("r1", 6, #""kind":"step","text":"x","step_id":"s1","plan_step":1"#),
            r("r1", 7, #""kind":"step_result","step_id":"s1","status":"ok""#), r("r1", 8, #""kind":"changes","created":["a.txt"],"created_windows":["w1"]"#),
            r("r1", 9, #""kind":"answer_given","text":"好了""#),
            r("r1", 10, #""kind":"task_done","status":"succeeded","reason":"","summary":"s","result_card":{"kind":"result","text":"r","options":[{"kind":"approve","text":"ok"},{"kind":"undo","text":"undo"}]},"changes":{"created":["a.txt"]}"#),
            se(3, #""kind":"session.task_end","run_id":"r1","status":"succeeded","summary":"s","undo":"open","changes":{"created":["a.txt"]},"answer":"好了""#),
            r("r1", 11, #""kind":"result_response","picked":"undo","undone":1,"total":1"#),
            se(4, #""kind":"session.task_undo","run_id":"r1","undone":1,"total":1"#),
            se(5, #""kind":"session.message","msg_id":"m2","role":"assistant","text":"好了","reply_to":"u1""#),
            se(6, #""kind":"session.message","msg_id":"u2","role":"user","text":"b""#),
            se(7, #""kind":"session.task","msg_id":"m3","run_id":"r2","raw":"b","by":"slash""#),
            se(8, #""kind":"session.task_closed","run_id":"r1","why":"new_task""#),
            r("r2", 1, #""kind":"start","raw":"b""#), r("r2", 2, #""kind":"step","text":"y","step_id":"s1""#), r("r2", 3, #""kind":"step_result","step_id":"s1","status":"refused""#),
            r("r2", 4, #""kind":"waiting""#), r("r2", 5, #""kind":"resumed""#), r("r2", 6, #""kind":"verify","verdict":"unknown","reason":"r","missing_kind":"evidence""#),
            se(9, #""kind":"session.steer","run_id":"r2","text":"改""#), r("r2", 7, #""kind":"steered","text":"改""#), r("r2", 8, #""kind":"ask","ask_id":"a1","# + card),
        ]
        let interrupted: [ProtocolLine] = [
            se(1, #""kind":"session.task","msg_id":"m1","run_id":"r1","raw":"a","by":"slash""#),
            r("r1", 1, #""kind":"start","raw":"a""#), r("r1", 2, #""kind":"ask","ask_id":"a1","# + card), r("r1", 3, #""kind":"resumed","ask_id":"a1""#),
            r("r1", 4, #""kind":"step","text":"x","step_id":"s1""#), r("r1", 5, #""kind":"step_result","step_id":"s1","status":"ok""#),
            r("r1", 6, #""kind":"step","text":"y","step_id":"s2""#), r("r1", 7, #""kind":"refused","by":"user","reason":"stop""#),
            se(2, #""kind":"session.task_end","run_id":"r1","status":"interrupted","summary":"","undo":"none","cause":"last_step_unknown""#),
            se(3, #""kind":"session.task_closed","run_id":"r1","why":"session_end""#),
            se(4, #""kind":"session.task","msg_id":"m2","run_id":"r2","raw":"b","by":"slash""#),
            r("r2", 1, #""kind":"start","raw":"b""#), r("r2", 2, #""kind":"ask","ask_id":"a9","# + card),
            se(5, #""kind":"session.task_end","run_id":"r2","status":"interrupted","summary":"","undo":"none""#),
        ]
        var cases: [(String, [ProtocolLine])] = names.map { ($0, lines($0)) }
        cases.append(("multi", multi))
        cases.append(("interrupted", interrupted))
        var runs = 0
        for (name, ls) in cases {
            let live = SessionReducer.reduce(SessionState(), ls)
            check(!live.hasGap, "\(name): the live order applies whole")
            for (how, order) in merges(streams(ls), seeds: 12) {
                let got = SessionReducer.reduce(SessionState(), order)
                runs += 1
                if got != live {
                    check(false, "\(name), \(how): \(summary(got)) ≠ live \(summary(live))")
                    if summary(got) == summary(live) { dumpDiff(got, live) }
                }
            }
        }
        check(runs >= cases.count * 15, "orders tried: \(runs)")
        // what the hand-built ones should show
        let m = SessionReducer.reduce(SessionState(), multi)
        check(m.status == .waitingForYou(cardKind: "action") && m.openCard?.runId == "r2" && m.task("r1")?.undo == .done(undone: 1, total: 1, refused: nil)
              && m.task("r1")?.changes.createdWindows == ["w1"] && m.task("r1")?.answer == "好了" && m.task("r2")?.lookOnly == false && m.task("r1")?.cards.first?.picked == "action",
              "multi: \(summary(m))")
        let i = SessionReducer.reduce(SessionState(), interrupted)
        check(i.task("r1")?.steps.map(\.status) == [.ok, .unknown] && i.task("r1")?.cards.map(\.outcome) == [.answered] && i.task("r2")?.cards.map(\.outcome) == [.void("task_done")]
              && i.composerEnabled, "interrupted: \(summary(i))")
    }

    static func dumpDiff(_ a: SessionState, _ b: SessionState) {
        let ma = Mirror(reflecting: a), mb = Mirror(reflecting: b)
        for (x, y) in zip(ma.children, mb.children) where "\(x.value)" != "\(y.value)" {
            print("  field \(x.label ?? "?"):\n    got  \(x.value)\n    live \(y.value)")
        }
    }

    // MARK: re-review of 74e5d4b

    static func rereviewTests() {
        let exit = L(#"{"kind":"helper.session_exit","session_id":"s","code":9}"#)
        let start = ex(1, #""kind":"start","raw":"x""#)
        let done = ex(2, #""kind":"task_done","status":"succeeded","reason":"","summary":"","result_card":{"kind":"result","text":"r","options":[{"kind":"approve","text":"ok"},{"kind":"undo","text":"undo"}]}"#)
        let end = se(2, #""kind":"session.task_end","run_id":"r1","status":"succeeded","summary":"","undo":"open""#)
        // 1. the exit closes every task's result card, whether its task_done came before or comes after
        for (how, order) in [("done, end, exit", [taskR1, start, done, end, exit]), ("end, exit, done", [taskR1, start, end, exit, done]),
                             ("exit, done, end", [taskR1, start, exit, done, end])] {
            let st = SessionReducer.reduce(SessionState(), order)
            check(st.task("r1")?.undo == .expired("session_exit") && SessionClient.refusal(.respond(runId: "r1", option: 1), in: st) != nil, "1 \(how): undo gone with the process: \(String(describing: st.task("r1")?.undo))")
        }
        // 2. a cut-off reply keeps its place; the chat goes on after it and the dot can be done again
        let st = SessionReducer.reduce(SessionState(), [se(1, #""kind":"session.message","msg_id":"u1","role":"user","text":"a""#),
            se(nil, #""kind":"session.delta","msg_id":"m1","text":"从前","offset":0"#), exit, se(nil, #""kind":"session.start","resumed":true"#),
            se(2, #""kind":"session.message","msg_id":"u2","role":"user","text":"b""#), se(nil, #""kind":"session.delta","msg_id":"m2","text":"好","offset":0"#),
            se(3, #""kind":"session.message","msg_id":"m2","role":"assistant","text":"好""#)])
        check(st.timeline == [.message("u1"), .message("m1"), .message("u2"), .message("m2")], "2: the cut-off reply where it began: \(st.timeline)")
        check(st.status == .done(at: nil, stopped: false), "2: the next reply done: \(st.status)")
        // 3. not_open on a card's answer or a steer: the card went with the process; nothing opened, nothing sent
        let mock = MockTransport()
        mock.replies = [SessionClient.Op.open: ["ok": true, "session_id": "s"], SessionClient.Op.send: ["ok": true]]
        for control in [SessionControl.answer(.option(runId: "r1", askId: "a1", option: 0)), .steer("改", runId: "r1")] {
            let c = SessionClient(transport: mock)
            _ = c.open(sessionId: "s")
            [taskR1, start, ex(2, #""kind":"step","text":"x","step_id":"s1""#), ex(3, #""kind":"ask","ask_id":"a1","# + actionCard)].forEach { c.feed($0) }
            if case .steer = control { c.feed(ex(4, #""kind":"resumed","ask_id":"a1""#)) }
            mock.queued = [SessionClient.Op.send: [["ok": false, "code": "not_open"]]]
            mock.requests = []
            check(c.send(control, to: "s") != .sent && mock.requests.map { $0["op"] as? String ?? "" } == ["session.send"], "3: \(control) after an unheard exit: not opened again, not re-sent: \(mock.requests.map { $0["op"] ?? "" })")
            mock.requests = []
            check(c.send(control, to: "s") != .sent && mock.requests.isEmpty, "3: and while exited: refused here")
        }
        // tasks first heard of after the exit: a session that is not running gets no replay, so they come with the next
        // process's replay, after its session.start, whose last_seq says they are older: gone with their process
        let late = SessionClient(transport: mock)
        _ = late.open(sessionId: "s")
        mock.streamLines = [["kind": "helper.watching", "open": []]]
        late.watch()
        mock.streamLines = []
        [se(nil, #""kind":"session.start","last_seq":3,"resumed":true"#), taskR1, start, done, end,
         se(3, #""kind":"session.task","msg_id":"m2","run_id":"r2","raw":"y","by":"slash""#),
         ex(1, #""kind":"start","raw":"y""#, run: "r2"), ex(2, #""kind":"step","text":"x","step_id":"s1""#, run: "r2")].forEach { late.feed($0) }
        let ls0 = late.state("s")
        check(ls0.task("r1")?.undo == .expired("session_exit") && ls0.runningTask == nil && ls0.task("r2")?.steps.map(\.status) == [.unknown], "replayed after the exit: closed, cut off: \(ls0.status)")
        late.feed(L(#"{"kind":"helper.session_exit","session_id":"s","code":9}"#))   // (so the sends below find it exited)
        mock.requests = []
        check(late.send(.answer(.respond(runId: "r1", option: 1)), to: "s") != .sent && late.send(.steer("改"), to: "s") != .sent && mock.requests.isEmpty, "nothing sent for them")
        // a cut-off reply's place counts stored lines held behind a gap
        let held = SessionReducer.reduce(SessionState(), [se(1, #""kind":"session.message","msg_id":"u1","role":"user","text":"a""#),
            se(3, #""kind":"session.task","msg_id":"m","run_id":"r1","raw":"x","by":"slash""#), se(nil, #""kind":"session.delta","msg_id":"a1","text":"好","offset":0"#),
            se(2, #""kind":"session.message","msg_id":"u2","role":"user","text":"b""#), exit])
        check(held.timeline == [.message("u1"), .message("u2"), .task("r1"), .message("a1")], "anchor past held lines: \(held.timeline)")
        // 4. a long session: replaying it through the client stays cheap (300 tasks × 20 steps, 40 deltas a reply)
        var ls: [ProtocolLine] = [], q = 0
        for k in 1...300 {
            q += 1; ls.append(se(q, "\"kind\":\"session.message\",\"msg_id\":\"u\(k)\",\"role\":\"user\",\"text\":\"hi\""))
            for d in 0..<40 { ls.append(se(nil, "\"kind\":\"session.delta\",\"msg_id\":\"a\(k)\",\"text\":\"x\",\"offset\":\(d)")) }
            q += 1; ls.append(se(q, "\"kind\":\"session.message\",\"msg_id\":\"a\(k)\",\"role\":\"assistant\",\"text\":\"\(String(repeating: "x", count: 40))\""))
            q += 1; ls.append(se(q, "\"kind\":\"session.task\",\"msg_id\":\"m\(k)\",\"run_id\":\"r\(k)\",\"raw\":\"a\",\"by\":\"model\""))
            var r = 0
            func R(_ body: String) { r += 1; ls.append(ex(r, body, run: "r\(k)")) }
            R(#""kind":"start","raw":"a""#)
            for n in 1...20 { R("\"kind\":\"step\",\"text\":\"x\",\"step_id\":\"s\(n)\""); R("\"kind\":\"step_result\",\"step_id\":\"s\(n)\",\"status\":\"ok\"") }
            R(#""kind":"task_done","status":"succeeded","reason":"","summary":"s""#)
            q += 1; ls.append(se(q, "\"kind\":\"session.task_end\",\"run_id\":\"r\(k)\",\"status\":\"succeeded\",\"summary\":\"s\",\"undo\":\"none\""))
        }
        let c = SessionClient(transport: MockTransport())
        let t0 = Date()
        ls.forEach { c.feed($0) }
        let took = Date().timeIntervalSince(t0)
        check(took < 3 && c.state("s").tasks.count == 300 && c.state("s").tasks.last?.steps.count == 20, "4: \(ls.count) lines in \(took) s (debug build)")
    }

    // MARK: processes (review of 15cc6f6)

    /// A session whose process A dies (helper.session_exit with last_seq and pid) and is replaced by B, with a stored
    /// line delayed (a gap) and the runs of both: whatever the order — the exit before or after the gap fill, before or
    /// after B's session.start and its runs' lines — the final state is the live order's.
    static func processInterleavingTests() {
        let card = actionCard
        let r = { (run: String, seq: Int, body: String) in ex(seq, body, run: run) }
        let live: [ProtocolLine] = [
            se(nil, #""kind":"session.start","last_seq":0,"resumed":false,"pid":100"#),                         // 0  A starts
            se(1, #""kind":"session.message","msg_id":"u1","role":"user","text":"a""#),                          // 1
            se(nil, #""kind":"session.delta","msg_id":"m0","text":"","offset":0"#),                               // 2
            se(2, #""kind":"session.task","msg_id":"m0","run_id":"r1","raw":"a","by":"model""#),                 // 3
            r("r1", 1, #""kind":"start","raw":"a""#), r("r1", 2, #""kind":"ask","ask_id":"a1","# + card),          // 4 5
            se(nil, #""kind":"session.queue","items":[{"id":"q1","text":"排队的"}]"#),                             // 6
            r("r1", 3, #""kind":"resumed","ask_id":"a1""#), r("r1", 4, #""kind":"step","text":"x","step_id":"s1""#), // 7 8
            se(3, #""kind":"session.message","msg_id":"u2","role":"user","text":"b""#),                          // 9  (late: L1)
            se(nil, #""kind":"session.delta","msg_id":"m1","text":"","offset":0"#),                               // 10
            se(nil, #""kind":"session.delta","msg_id":"m1","text":"从前","offset":0"#),                           // 11 A's last live-only line
            se(4, #""kind":"session.steer","run_id":"r1","text":"改""#),                                          // 12 (late: L2)
            L(#"{"kind":"helper.session_exit","session_id":"s","code":9,"last_seq":4,"pid":100}"#),              // 13 the exit
            se(nil, #""kind":"session.start","last_seq":4,"resumed":true,"pid":200"#),                          // 14 B starts
            se(5, #""kind":"session.task_end","run_id":"r1","status":"interrupted","summary":"","undo":"none","cause":"last_step_unknown""#), // 15
            se(6, #""kind":"session.task_closed","run_id":"r1","why":"session_end""#),                            // 16
            se(7, #""kind":"session.message","msg_id":"u3","role":"user","text":"c""#),                          // 17
            se(nil, #""kind":"session.delta","msg_id":"m2","text":"","offset":0"#),                               // 18
            se(nil, #""kind":"session.delta","msg_id":"m2","text":"好","offset":0"#),                             // 19
            se(8, #""kind":"session.message","msg_id":"m2","role":"assistant","text":"好","reply_to":"u3""#),     // 20
            se(9, #""kind":"session.task","msg_id":"m3","run_id":"r2","raw":"c","by":"slash""#),                 // 21
            r("r2", 1, #""kind":"start","raw":"c""#), r("r2", 2, #""kind":"step","text":"y","step_id":"s1""#),     // 22 23
            r("r2", 3, #""kind":"step_result","step_id":"s1","status":"ok""#), r("r2", 4, #""kind":"ask","ask_id":"a2","# + card), // 24 25
        ]
        let exitAt = 13, startA = 0, startB = 14, aLastLive = 11
        let late: [Int: Int] = [9: 10, 12: 18]          // a delayed stored line → the live-only line it must come before
        let session = live.indices.filter { !live[$0].event.isSessionEvent ? false : $0 != exitAt && late[$0] == nil }
        let runs = ["r1", "r2"].map { id in live.indices.filter { !live[$0].event.isSessionEvent && live[$0].runId == id } }
        var streams: [[Int]] = [session] + runs + late.keys.sorted().map { [$0] } + [[exitAt]]
        streams.removeAll { $0.isEmpty }
        func allowed(_ i: Int, _ done: Set<Int>) -> Bool {
            if i == exitAt { return done.contains(aLastLive) }
            if live[i].runId == "r1" && !live[i].event.isSessionEvent { return done.contains(startA) }
            if live[i].runId == "r2" && !live[i].event.isSessionEvent { return done.contains(startB) }
            for (l, before) in late where i == before && !done.contains(l) { return false }
            // a delayed line is late, never early: not before the live-only lines the process wrote before it
            if late[i] != nil { return live[..<i].indices.allSatisfy { live[$0].seq != nil || !live[$0].event.isSessionEvent || $0 == exitAt || done.contains($0) } }
            return true
        }
        struct RNG { var x: UInt64; mutating func next(_ n: Int) -> Int { x = x &* 6364136223846793005 &+ 1442695040888963407; return Int((x >> 33) % UInt64(n)) } }
        func merge(_ pick: ([Int]) -> Int) -> [Int] {
            var idx = Array(repeating: 0, count: streams.count), out: [Int] = [], done: Set<Int> = []
            while out.count < live.count {
                let ready = streams.indices.filter { idx[$0] < streams[$0].count && allowed(streams[$0][idx[$0]], done) }
                guard !ready.isEmpty else { return [] }
                let k = pick(ready)
                let i = streams[k][idx[k]]; idx[k] += 1; out.append(i); done.insert(i)
            }
            return out
        }
        let sIdx = 0, exitIdx = streams.count - 1
        let lateIdx = Set(streams.indices.filter { streams[$0].count == 1 && late[streams[$0][0]] != nil })
        var orders: [(String, [Int])] = [
            ("session first", merge { $0.contains(sIdx) ? sIdx : $0[0] }),
            ("runs first", merge { $0.first { $0 != sIdx && $0 != exitIdx && !lateIdx.contains($0) } ?? $0[0] }),
            ("exit early, fills late", merge { r in r.contains(exitIdx) ? exitIdx : (r.first { !lateIdx.contains($0) } ?? r[0]) }),
            ("exit last, fills early", merge { r in r.first { lateIdx.contains($0) } ?? (r.first { $0 != exitIdx } ?? r[0]) }),
            ("exit after B's start, runs last", merge { r in r.first { $0 == sIdx } ?? (r.first { $0 != exitIdx } ?? r[0]) }),
        ]
        for seed in 1...40 { var g = RNG(x: UInt64(seed)); orders.append(("seed \(seed)", merge { $0[g.next($0.count)] })) }
        let want = SessionReducer.reduce(SessionState(), live)
        check(want.status == .waitingForYou(cardKind: "action") && want.openCard?.runId == "r2" && want.exited == nil && want.goneUpTo == 4
              && want.unsent.map(\.id) == ["q1"] && want.queue.isEmpty, "live: \(want.status)")
        check(want.task("r1")?.steps.map(\.status) == [.unknown] && want.task("r1")?.cards.map(\.outcome) == [.answered] && want.task("r1")?.closed == "session_end"
              && want.task("r2")?.gone == false && want.task("r2")?.steps.map(\.status) == [.ok], "live: r1 gone, r2 alive")
        check(want.timeline == [.message("u1"), .task("r1"), .message("u2"), .message("m1"), .message("u3"), .message("m2"), .task("r2")]
              && want.message("m1")?.interrupted == true, "live: the chat, the cut-off reply in its place: \(want.timeline)")
        var tried = 0
        for (how, o) in orders {
            check(o.count == live.count, "\(how): a full order")
            guard o.count == live.count else { continue }
            let got = SessionReducer.reduce(SessionState(), o.map { live[$0] })
            tried += 1
            if got != want {
                check(false, "\(how) \(o): differs")
                dumpDiff(got, want)
            }
        }
        check(tried == orders.count, "orders: \(tried)")
        // and the orders cover what the review asked for
        func before(_ a: Int, _ b: Int, _ o: [Int]) -> Bool { (o.firstIndex(of: a) ?? 0) < (o.firstIndex(of: b) ?? 0) }
        let os = orders.map(\.1)
        check(os.contains { before(exitAt, 12, $0) } && os.contains { before(12, exitAt, $0) }, "exit before and after the gap fill")
        check(os.contains { before(exitAt, startB, $0) } && os.contains { before(startB, exitAt, $0) }, "exit before and after B's start")
        check(os.contains { before(22, exitAt, $0) } && os.contains { before(22, 21, $0) }, "B's run lines before the exit, and before their session.task")
        // the reviewer's cases, one by one
        let exitA = live[exitAt], startBLine = live[startB]
        // a stale exit (after B's start) does not touch B: not exited, B's run alive even before its session.task
        let b = SessionReducer.reduce(SessionState(), Array(live[0...12]) + [startBLine, live[22], live[23], exitA] + Array(live[15...21]) + [live[24], live[25]])
        check(b == want, "a stale exit after B's start and B's run lines: the same state")
        // without pid on the start: by start_seq (another start: another process; the same start and something stored:
        // the latest; the same start and nothing stored: ambiguous, taken for an older one), else by last_seq past it
        let st4 = se(nil, #""kind":"session.start","last_seq":4"#)
        let exitOf = { (json: String) in SessionReducer.reduce(SessionState(), [st4, L(json)]).exited }
        check(exitOf(#"{"kind":"helper.session_exit","session_id":"s","code":1,"pid":7,"start_seq":4,"last_seq":6}"#) == 1, "same start_seq, stored: the latest")
        check(exitOf(#"{"kind":"helper.session_exit","session_id":"s","code":1,"pid":7,"start_seq":2,"last_seq":4}"#) == nil, "another start_seq: an older one")
        check(exitOf(#"{"kind":"helper.session_exit","session_id":"s","code":1,"pid":7,"start_seq":4,"last_seq":4}"#) == nil, "same start, nothing stored: ambiguous, older")
        check(exitOf(#"{"kind":"helper.session_exit","session_id":"s","code":1,"last_seq":5}"#) == 1, "no start_seq: last_seq past the start: the latest")
        check(exitOf(#"{"kind":"helper.session_exit","session_id":"s","code":1,"pid":8,"start_seq":6,"last_seq":7}"#) == 1, "a later start_seq: a process whose start was missed: the latest")
        // the reopened process's session.start was missed (the watch was not connected when it started): its exit still counts
        let reopen = MockTransport()
        reopen.replies = [SessionClient.Op.open: ["ok": true, "session_id": "s"]]
        let mc = SessionClient(transport: reopen)
        [st4, se(5, #""kind":"session.message","msg_id":"u5","role":"user","text":"x""#),
         L(#"{"kind":"helper.session_exit","session_id":"s","code":9,"pid":101,"start_seq":4,"last_seq":5}"#)].forEach { mc.feed($0) }
        _ = mc.open(sessionId: "s")                            // the new process; its session.start is not seen
        check(mc.state("s").exited == nil, "reopened")
        [se(6, #""kind":"session.message","msg_id":"u6","role":"user","text":"y""#), se(nil, #""kind":"session.delta","msg_id":"a6","text":"嗯","offset":0"#),
         se(nil, #""kind":"session.queue","items":[{"id":"q1","text":"z"}]"#),
         L(#"{"kind":"helper.session_exit","session_id":"s","code":7,"pid":102,"start_seq":5,"last_seq":6}"#)].forEach { mc.feed($0) }
        let missed = mc.state("s")
        // the same with pids on the starts (should the helper add them): a missed start's exit has another pid but a later start_seq
        let pidStart = SessionReducer.reduce(SessionState(), [se(nil, #""kind":"session.start","last_seq":0,"pid":1"#), se(1, #""kind":"session.message","msg_id":"u1","role":"user","text":"a""#),
            se(nil, #""kind":"session.queue","items":[{"id":"q9","text":"z"}]"#), L(#"{"kind":"helper.session_exit","session_id":"s","code":3,"pid":2,"start_seq":1,"last_seq":1}"#)])
        check(pidStart.exited == 3 && pidStart.unsent.map(\.id) == ["q9"], "another pid, a later start_seq: the latest")
        check(missed.exited == 7 && missed.unsent.map(\.id) == ["q1"] && missed.message("a6")?.interrupted == true && missed.status != .thinking, "a missed start: the exit still counts: \(missed.status)")
        let stale = SessionReducer.reduce(SessionState(), [se(nil, #""kind":"session.start","last_seq":6"#), L(#"{"kind":"helper.session_exit","session_id":"s","code":1,"last_seq":4}"#)])
        check(stale.exited == nil && stale.goneUpTo == 6, "no pid: an exit below the latest start is an older process's")
        // a finished task is never "cut off"
        let fin = SessionReducer.reduce(SessionState(), [taskR1, ex(1, #""kind":"start","raw":"x""#), ex(2, #""kind":"task_done","status":"succeeded","reason":"","summary":"""#),
                                                        L(#"{"kind":"helper.session_exit","session_id":"s","code":0,"last_seq":1}"#)])
        check(fin.task("r1")?.cutOff == false && fin.task("r1")?.gone == true && fin.task("r1")?.closed == "session_exit", "done before its process went: not cut off, its card closed")
        // the same 45 orders as the helper writes them today: session.start without pid, the exit with start_seq
        let stripped = live.map { l -> ProtocolLine in
            if case .sessionStart(var e) = l.event { e.pid = nil; return ProtocolLine(sessionId: "s", event: .sessionStart(e)) }
            if case .sessionExit(var e) = l.event { e.startSeq = 0; return ProtocolLine(sessionId: "s", event: .sessionExit(e)) }
            return l
        }
        let want2 = SessionReducer.reduce(SessionState(), stripped)
        check(want2.status == want.status && want2.timeline == want.timeline && want2.unsent == want.unsent && want2.exited == nil, "no pid on starts: the same live state")
        for (how, o) in orders where o.count == live.count {
            if SessionReducer.reduce(SessionState(), o.map { stripped[$0] }) != want2 { check(false, "no pid on starts, \(how): differs") }
        }
        // re-review of 9480c89, one by one (each against its live order)
        let sA = se(nil, #""kind":"session.start","last_seq":0,"pid":100"#), u1 = se(1, #""kind":"session.message","msg_id":"u1","role":"user","text":"a""#)
        let eq = { (name: String, liveOrder: [ProtocolLine], other: [ProtocolLine]) in
            let a = SessionReducer.reduce(SessionState(), liveOrder), b = SessionReducer.reduce(SessionState(), other)
            check(a == b, "\(name): the same state in either order"); if a != b { dumpDiff(b, a) }
        }
        // 1. a reply's stored error after the exit still removes the cut-off reply
        let d1 = se(nil, #""kind":"session.delta","msg_id":"m1","text":"从前","offset":0"#)
        let err = se(2, #""kind":"session.error","code":"network","text":"x","msg_id":"m1""#)
        let ex2 = L(#"{"kind":"helper.session_exit","session_id":"s","code":9,"pid":100,"start_seq":0,"last_seq":2}"#)
        eq("error after the exit", [sA, u1, d1, err, ex2], [sA, u1, d1, ex2, err])
        check(SessionReducer.reduce(SessionState(), [sA, u1, d1, ex2, err]).timeline == [.message("u1"), .error(2)], "the failed reply is gone")
        // 2. A's exit after B's start (starts without pid): B keeps its queue and its reply
        let sA0 = se(nil, #""kind":"session.start","last_seq":0"#), sB1 = se(nil, #""kind":"session.start","last_seq":1"#)
        let dB = se(nil, #""kind":"session.delta","msg_id":"m2","text":"嗯","offset":0"#), qB = se(nil, #""kind":"session.queue","items":[{"id":"qb","text":"x"}]"#)
        let exA = L(#"{"kind":"helper.session_exit","session_id":"s","code":9,"pid":100,"start_seq":0,"last_seq":1}"#)
        eq("a late exit of A", [sA0, u1, exA, sB1, dB, qB], [sA0, u1, sB1, dB, qB, exA])
        let late2 = SessionReducer.reduce(SessionState(), [sA0, u1, sB1, dB, qB, exA])
        check(late2.exited == nil && late2.queue.map(\.id) == ["qb"] && late2.status == .thinking, "B untouched: \(late2.status)")
        // 3. an exit with pid but no last_seq for an older process does not touch B's runs
        let u2 = se(2, #""kind":"session.message","msg_id":"u2","role":"user","text":"b""#)
        let sB2 = se(nil, #""kind":"session.start","last_seq":2,"pid":200"#)
        let r2t = se(3, #""kind":"session.task","msg_id":"m","run_id":"r2","raw":"y","by":"slash""#)
        let r2s = ex(1, #""kind":"start","raw":"y""#, run: "r2"), r2a = ex(2, #""kind":"ask","ask_id":"a2","# + card, run: "r2")
        let exPidOnly = L(#"{"kind":"helper.session_exit","session_id":"s","code":9,"pid":100}"#)
        eq("an older pid without last_seq", [sA, u1, u2, exPidOnly, sB2, r2t, r2s, r2a], [sA, u1, u2, sB2, r2t, r2s, r2a, exPidOnly])
        // 4. an empty first delta, the exit, then the reply's delayed final message
        let d0 = se(nil, #""kind":"session.delta","msg_id":"m1","text":"","offset":0"#)
        let m1 = se(2, #""kind":"session.message","msg_id":"m1","role":"assistant","text":"好""#)
        eq("the final message after the exit", [sA, u1, d0, m1, ex2], [sA, u1, d0, ex2, m1])
        // a session.start fed twice (a replay of the whole stream) is the same process
        let twice = SessionReducer.reduce(SessionState(), [live[0], live[1], live[6], live[0]])
        check(twice.queue.map(\.id) == ["q1"] && twice.unsent.isEmpty, "the same start again: nothing gone")
    }

    // MARK: one owner for the user's words (review of 8b7f77d)

    static func ownershipTests() {
        // a reconnect after the queue was sent to the model (task-steer): the replay brings the stored messages and the
        // whole queue, empty (harness#57 attach); nothing stays queued, a later exit leaves nothing unsent
        let ls = lines("task-steer")
        let cut = ls.firstIndex { if case .queue(let q) = $0.event { return q.items.count == 2 }; return false }! + 2   // both queued, the edit in
        var app = SessionReducer.reduce(SessionState(), Array(ls[..<cut]))
        check(app.queue.map(\.text) == ["一", "二改"], "queued while connected: \(app.queue.map(\.text))")
        let replay = ls[cut...].filter { $0.seq != nil }                       // what attach replays: the stored lines
        app = SessionReducer.reduce(app, Array(replay) + [L(#"{"session_id":"ses_t","kind":"session.queue","items":[]}"#)])
        check(app.queue.isEmpty && app.messages.filter { $0.text == "一" || $0.text == "二改" }.count == 2, "after the reconnect: the queue empty, each message once")
        app = SessionReducer.reduce(app, L(#"{"kind":"helper.session_exit","session_id":"ses_t","code":0}"#))
        check(app.unsent.isEmpty && app.queue.isEmpty, "a later exit: nothing unsent, nothing sent twice")
        // without the snapshot (an older harness) but with client_ids: the stored message takes its entry out of the queue
        let q = se(nil, #""kind":"session.queue","items":[{"id":"q1","text":"一","client_id":"k1"},{"id":"q2","text":"二","client_id":"k2"}]"#)
        let st = SessionReducer.reduce(SessionState(), [q, se(1, #""kind":"session.message","msg_id":"m1","role":"user","text":"一","via":"queue","client_id":"k1""#),
                                                         L(#"{"kind":"helper.session_exit","session_id":"s","code":0}"#)])
        check(st.queue.isEmpty && st.unsent.map(\.id) == ["k2"], "k1 stored: out of the queue; k2 unsent at the exit: \(st.unsent.map(\.id))")
        // the composer's words: sending until taken; queued by the session: the queue's; refused: back
        let mock = MockTransport()
        mock.replies = [SessionClient.Op.send: ["ok": true]]
        let c = SessionClient(transport: mock)
        var n = 0
        c.newClientId = { n += 1; return "k\(n)" }
        _ = c.send(.say("先"), to: "s")
        c.feed(se(nil, #""kind":"session.queue","items":[{"id":"q9","text":"先","client_id":"k1"}]"#))
        check(c.state("s").outbox.isEmpty && c.state("s").queue.first?.clientId == "k1", "queued: the queue's, not the outbox's")
        _ = c.send(.cua("开个文件"), to: "s")
        c.feed(se(nil, #""kind":"session.error","code":"computer_busy","text":"x","control":"cua","client_id":"k2""#))
        check(c.state("s").unsent.map { [$0.id, $0.control, $0.refused ?? ""] } == [["k2", "cua", "computer_busy"]], "a refused /cua: back, as a /cua")
        check(c.resend("k2", in: "s") == .sent && (mock.requests.last?["line"] as? [String: Any])?["type"] as? String == "cua", "resent as a /cua")
        c.feed(se(1, #""kind":"session.message","msg_id":"m","role":"user","text":"开个文件","via":"cua","client_id":"k2""#))
        check(c.state("s").outbox.isEmpty, "taken: gone from the outbox")
        // a refusal of a queue entry (queue_send_now) leaves the outbox alone: the entry is the queue's
        c.feed(se(nil, #""kind":"session.error","code":"busy","text":"x","control":"queue_send_now","client_id":"k1""#))
        check(c.state("s").outbox.isEmpty && c.state("s").queue.count == 1, "the queue keeps it")
        // a send to an exited session reopens it: the new process's session.start does not make those words unsent
        let reopen = MockTransport()
        reopen.replies = [SessionClient.Op.open: ["ok": true, "session_id": "s"], SessionClient.Op.send: ["ok": true]]
        let rc = SessionClient(transport: reopen)
        rc.newClientId = { "h1" }
        _ = rc.open(sessionId: "s")
        [se(nil, #""kind":"session.start","last_seq":0"#), se(1, #""kind":"session.message","msg_id":"u","role":"user","text":"a""#),
         L(#"{"kind":"helper.session_exit","session_id":"s","code":0,"pid":1,"start_seq":0,"last_seq":1}"#)].forEach { rc.feed($0) }
        check(rc.send(.say("hello"), to: "s") == .sent, "sent after a reopen")
        rc.feed(se(nil, #""kind":"session.start","last_seq":1,"resumed":true"#))
        check(rc.state("s").outbox.map { [$0.id, "\($0.sending)"] } == [["h1", "true"]] && rc.state("s").unsent.isEmpty, "the new process's start: still sending, not unsent")
        check(rc.resend("h1", in: "s") != .sent, "so it cannot be sent twice")
        check(rc.send(.say("  "), to: "s") == .refused("empty") && rc.state("s").outbox.count == 1, "empty words: not sent, not held")
        rc.feed(se(2, #""kind":"session.message","msg_id":"m","role":"user","text":"hello","client_id":"h1""#))
        check(rc.state("s").outbox.isEmpty && rc.state("s").messages.filter { $0.text == "hello" }.count == 1, "taken once")
        // an exit while the words' stored line is held behind a gap: they stay sending, the gap fill takes them
        var g = SessionReducer.reduce(SessionState(), [se(nil, #""kind":"session.start","last_seq":0"#), se(1, #""kind":"session.message","msg_id":"u","role":"user","text":"a""#)])
        g.outbox = [Outgoing(id: "g1", text: "b", control: "say", sending: true)]
        g = SessionReducer.reduce(g, [se(3, #""kind":"session.message","msg_id":"m3","role":"user","text":"b","client_id":"g1""#),
                                      L(#"{"kind":"helper.session_exit","session_id":"s","code":9,"pid":1,"start_seq":0,"last_seq":3}"#)])
        check(g.outbox.first?.sending == true && g.unsent.isEmpty, "held stored line: still sending at the exit")
        g = SessionReducer.reduce(g, se(2, #""kind":"session.retry","reply_to":"u""#))
        check(g.outbox.isEmpty && g.messages.filter { $0.text == "b" }.count == 1, "the gap filled: taken once")
        // a queue snapshot behind a gap waits for the stored lines before it: the words are never in neither place
        var w = SessionReducer.reduce(SessionState(), [se(1, #""kind":"session.message","msg_id":"u","role":"user","text":"a""#),
                                                       se(nil, #""kind":"session.queue","items":[{"id":"q1","text":"一","client_id":"w1"}]"#)])
        w = SessionReducer.reduce(w, [se(3, #""kind":"session.message","msg_id":"m3","role":"user","text":"一","via":"queue","client_id":"w1""#),
                                      se(nil, #""kind":"session.queue","items":[]"#)])
        check(w.queue.map(\.clientId) == ["w1"] && w.deferredQueue == [], "the empty snapshot waits; the entry is still the queue's")
        w = SessionReducer.reduce(w, se(2, #""kind":"session.retry","reply_to":"u""#))
        check(w.queue.isEmpty && w.deferredQueue == nil && w.messages.filter { $0.text == "一" }.count == 1, "the gap filled: stored once, the queue empty")
        // words sent to a process another one replaced before any exit was heard: the new start makes them unsent
        let e1 = MockTransport()
        e1.replies = [SessionClient.Op.send: ["ok": true]]
        let ec = SessionClient(transport: e1)
        ec.newClientId = { "e1" }
        [se(nil, #""kind":"session.start","last_seq":0,"pid":100"#), se(1, #""kind":"session.message","msg_id":"u","role":"user","text":"a""#)].forEach { ec.feed($0) }
        _ = ec.send(.say("hello"), to: "s")
        [se(nil, #""kind":"session.start","last_seq":1,"pid":200,"resumed":true"#), L(#"{"kind":"helper.session_exit","session_id":"s","code":0,"pid":100,"start_seq":0,"last_seq":1}"#),
         se(nil, #""kind":"session.queue","items":[]"#)].forEach { ec.feed($0) }
        check(ec.state("s").unsent.map(\.id) == ["e1"] && ec.resend("e1", in: "s") == .sent, "sent to A, B started: unsent, can be sent again")
        check(ec.send(.say("\u{FEFF}"), to: "s") == .refused("empty"), "a BOM alone is empty, as the session trims it")
        // a held snapshot applies right after the stored lines before it, not after later ones
        let d1 = SessionReducer.reduce(SessionState(), [se(1, #""kind":"session.message","msg_id":"u","role":"user","text":"a""#),
            se(3, #""kind":"session.retry","reply_to":"u""#), se(nil, #""kind":"session.queue","items":[{"id":"q1","text":"X","client_id":"cX"}]"#),
            se(4, #""kind":"session.message","msg_id":"mx","role":"user","text":"X","via":"queue","client_id":"cX""#),
            se(2, #""kind":"session.retry","reply_to":"u""#)])
        let d1live = SessionReducer.reduce(SessionState(), [se(1, #""kind":"session.message","msg_id":"u","role":"user","text":"a""#),
            se(2, #""kind":"session.retry","reply_to":"u""#), se(3, #""kind":"session.retry","reply_to":"u""#),
            se(nil, #""kind":"session.queue","items":[{"id":"q1","text":"X","client_id":"cX"}]"#),
            se(4, #""kind":"session.message","msg_id":"mx","role":"user","text":"X","via":"queue","client_id":"cX""#)])
        check(d1.queue.isEmpty && d1.queue == d1live.queue && d1.deferredQueue == nil, "the held snapshot, then the stored message after it: the queue empty, as live")
        // a second word sent after the reopen, before the new process's start is heard, is the new process's too
        let p1 = MockTransport()
        p1.replies = [SessionClient.Op.open: ["ok": true, "session_id": "s"], SessionClient.Op.send: ["ok": true]]
        let c1 = SessionClient(transport: p1)
        var k = 0
        c1.newClientId = { k += 1; return "w\(k)" }
        _ = c1.open(sessionId: "s")
        [se(nil, #""kind":"session.start","last_seq":0"#), se(1, #""kind":"session.message","msg_id":"u","role":"user","text":"a""#),
         L(#"{"kind":"helper.session_exit","session_id":"s","code":0,"pid":1,"start_seq":0,"last_seq":1}"#)].forEach { c1.feed($0) }
        _ = c1.send(.say("one"), to: "s")
        _ = c1.send(.say("two"), to: "s")
        c1.feed(se(nil, #""kind":"session.start","last_seq":1,"resumed":true"#))
        check(c1.state("s").outbox.allSatisfy { $0.sending } && c1.resend("w2", in: "s") != .sent, "both the new process's: still sending, no second send")
        // not_open, the new process's start heard while the open request is out: the word is that process's; a later
        // process that replaces it without an exit heard makes it unsent
        let p2 = MockTransport()
        p2.replies = [SessionClient.Op.open: ["ok": true, "session_id": "s"], SessionClient.Op.send: ["ok": true]]
        let c2 = SessionClient(transport: p2)
        c2.newClientId = { "v" }
        _ = c2.open(sessionId: "s")
        [se(nil, #""kind":"session.start","last_seq":0"#), se(1, #""kind":"session.message","msg_id":"u","role":"user","text":"a""#)].forEach { c2.feed($0) }
        p2.queued = [SessionClient.Op.send: [["ok": false, "code": "not_open"]]]
        p2.onRequest = { op in if op == SessionClient.Op.open { c2.feed(se(nil, #""kind":"session.start","last_seq":1,"resumed":true"#)) } }
        _ = c2.send(.say("x"), to: "s")
        p2.onRequest = nil
        c2.feed(se(nil, #""kind":"session.start","last_seq":2,"resumed":true"#))
        check(c2.state("s").unsent.map(\.id) == ["v"], "replaced without an exit: unsent: \(c2.state("s").outbox)")
        // not_open, then the old process's real exit arrives after the reopen: the new process's word stays sending
        let p3 = MockTransport()
        p3.replies = [SessionClient.Op.open: ["ok": true, "session_id": "s"], SessionClient.Op.send: ["ok": true]]
        let c3 = SessionClient(transport: p3)
        c3.newClientId = { "z" }
        _ = c3.open(sessionId: "s")
        [se(nil, #""kind":"session.start","last_seq":0"#), se(1, #""kind":"session.message","msg_id":"u","role":"user","text":"a""#)].forEach { c3.feed($0) }
        p3.queued = [SessionClient.Op.send: [["ok": false, "code": "not_open"]]]
        _ = c3.send(.say("y"), to: "s")
        c3.feed(L(#"{"kind":"helper.session_exit","session_id":"s","code":0,"pid":1,"start_seq":0,"last_seq":1}"#))
        check(c3.state("s").outbox.first?.sending == true && c3.state("s").exited == nil, "the old exit, late: the new process's word untouched, not exited")
        // A: the old process stored nothing, the reopened one starts at the same seq: still a new process; its exit counts
        let pa = MockTransport()
        pa.replies = [SessionClient.Op.open: ["ok": true, "session_id": "s", "last_seq": 0], SessionClient.Op.send: ["ok": true]]
        let ca = SessionClient(transport: pa)
        var ka = 0
        ca.newClientId = { ka += 1; return "a\(ka)" }
        _ = ca.open(sessionId: "s")
        ca.feed(se(nil, #""kind":"session.start","last_seq":0"#))
        pa.queued = [SessionClient.Op.send: [["ok": false, "code": "not_open"]]]
        _ = ca.send(.say("one"), to: "s")
        ca.feed(se(nil, #""kind":"session.start","last_seq":0"#))
        check(!ca.state("s").awaitingStart && ca.state("s").starts == 2, "the reopened process's start at the same seq: a new process")
        ca.feed(se(1, #""kind":"session.message","msg_id":"m","role":"user","text":"one","client_id":"a1""#))
        _ = ca.send(.say("two"), to: "s")
        ca.feed(L(#"{"kind":"helper.session_exit","session_id":"s","code":1,"pid":2,"start_seq":0,"last_seq":1}"#))
        check(ca.state("s").exited == 1 && ca.state("s").unsent.map(\.id) == ["a2"], "its exit: exited, the sent word unsent")
        // B: no start ever heard (missed): an exit with a start_seq still counts
        let pb = MockTransport()
        pb.replies = [SessionClient.Op.open: ["ok": true, "session_id": "s", "last_seq": 0, "pid": 1], SessionClient.Op.send: ["ok": true]]
        let cb = SessionClient(transport: pb)
        cb.newClientId = { "b1" }
        _ = cb.open(sessionId: "s")
        _ = cb.send(.say("x"), to: "s")
        cb.feed(L(#"{"kind":"helper.session_exit","session_id":"s","code":1,"pid":1,"start_seq":0,"last_seq":0}"#))
        check(cb.state("s").exited == 1 && cb.state("s").unsent.map(\.id) == ["b1"], "a missed start: its exit counts")
        // C: an older process's late start, line and exit during the reopen request: the new process's word stays its own
        let pc = MockTransport()
        pc.replies = [SessionClient.Op.open: ["ok": true, "session_id": "s", "last_seq": 0], SessionClient.Op.send: ["ok": true]]
        let cc = SessionClient(transport: pc)
        cc.newClientId = { "c1" }
        _ = cc.open(sessionId: "s")
        pc.queued = [SessionClient.Op.send: [["ok": false, "code": "not_open"]], SessionClient.Op.open: [["ok": true, "session_id": "s", "last_seq": 1]]]
        pc.onRequest = { op in
            guard op == SessionClient.Op.open else { return }
            [se(nil, #""kind":"session.start","last_seq":0"#), se(1, #""kind":"session.message","msg_id":"u","role":"user","text":"a""#),
             L(#"{"kind":"helper.session_exit","session_id":"s","code":1,"pid":1,"start_seq":0,"last_seq":1}"#)].forEach { cc.feed($0) }
        }
        _ = cc.send(.say("w"), to: "s")
        pc.onRequest = nil
        check(cc.state("s").awaitingStart && cc.state("s").awaitedStart == 1, "awaiting the process that starts at 1")
        cc.feed(se(nil, #""kind":"session.start","last_seq":1,"resumed":true"#))
        check(cc.state("s").outbox.first?.sending == true && cc.resend("c1", in: "s") != .sent, "its start: the word still sending, not sent twice")
        // an old process's late exit at the same seq as the awaited one: by pid, the old one's; the new one's word stays
        let pe = MockTransport()
        pe.replies = [SessionClient.Op.open: ["ok": true, "session_id": "s", "last_seq": 0, "pid": 1], SessionClient.Op.send: ["ok": true]]
        let ce = SessionClient(transport: pe)
        ce.newClientId = { "e1" }
        _ = ce.open(sessionId: "s")
        ce.feed(se(nil, #""kind":"session.start","last_seq":0"#))
        pe.queued = [SessionClient.Op.send: [["ok": false, "code": "not_open"]], SessionClient.Op.open: [["ok": true, "session_id": "s", "last_seq": 0, "pid": 2]]]
        _ = ce.send(.say("w"), to: "s")
        ce.feed(L(#"{"kind":"helper.session_exit","session_id":"s","code":1,"pid":1,"start_seq":0,"last_seq":0}"#))
        check(ce.state("s").exited == nil && ce.state("s").outbox.first?.sending == true, "the old pid's exit: not the new process's")
        ce.feed(L(#"{"kind":"helper.session_exit","session_id":"s","code":1,"pid":2,"start_seq":0,"last_seq":0}"#))
        check(ce.state("s").exited == 1 && ce.state("s").unsent.map(\.id) == ["e1"], "the awaited pid's exit: its own")
        // a reopen through reopenIfExited with the old exit heard during the open request: the word is the new process's
        let pf = MockTransport()
        pf.replies = [SessionClient.Op.open: ["ok": true, "session_id": "s", "last_seq": 1, "pid": 3], SessionClient.Op.send: ["ok": true]]
        let cf = SessionClient(transport: pf)
        cf.newClientId = { "f1" }
        _ = cf.open(sessionId: "s")
        [se(nil, #""kind":"session.start","last_seq":0"#), se(1, #""kind":"session.message","msg_id":"u","role":"user","text":"a""#),
         L(#"{"kind":"helper.session_exit","session_id":"s","code":1}"#)].forEach { cf.feed($0) }
        pf.onRequest = { op in if op == SessionClient.Op.open { cf.feed(L(#"{"kind":"helper.session_exit","session_id":"s","code":1}"#)) } }
        check(cf.send(.say("x"), to: "s") == .sent, "sent through a reopen")
        pf.onRequest = nil
        check(cf.state("s").outbox.first?.sending == true && cf.resend("f1", in: "s") != .sent, "still the new process's: sending, not sent twice")
        queueInterleavingTests()
    }

    /// The queue in the interleavings: entries with client_ids, consumed into stored messages (one delayed), a reply
    /// cut off by the exit, and the next process's empty snapshot (attach) — the same final state in every order.
    static func queueInterleavingTests() {
        let live: [ProtocolLine] = [
            se(nil, #""kind":"session.start","last_seq":0,"resumed":false"#),                                     // 0  A
            se(1, #""kind":"session.message","msg_id":"u1","role":"user","text":"新建 a.txt""#),                  // 1
            se(2, #""kind":"session.task","msg_id":"m0","run_id":"r1","raw":"a","by":"model""#),                 // 2
            ex(1, #""kind":"start","raw":"a""#),                                                                   // 3
            se(nil, #""kind":"session.queue","items":[{"id":"q1","text":"一","client_id":"k1"}]"#),                 // 4
            se(nil, #""kind":"session.queue","items":[{"id":"q1","text":"一","client_id":"k1"},{"id":"q2","text":"二","client_id":"k2"}]"#), // 5
            ex(2, #""kind":"step","text":"x","step_id":"s1""#), ex(3, #""kind":"step_result","step_id":"s1","status":"ok""#), // 6 7
            ex(4, #""kind":"task_done","status":"succeeded","reason":"","summary":"""#),                            // 8
            se(3, #""kind":"session.task_end","run_id":"r1","status":"succeeded","summary":"","undo":"none""#),  // 9
            se(nil, #""kind":"session.queue","items":[]"#),                                                         // 10 drained
            se(4, #""kind":"session.message","msg_id":"m1","role":"user","text":"一","via":"queue","client_id":"k1""#), // 11
            se(nil, #""kind":"session.delta","msg_id":"a1","text":"","offset":0"#),                                 // 12
            se(nil, #""kind":"session.delta","msg_id":"a1","text":"收到","offset":0"#),                             // 13 A's last live-only
            se(5, #""kind":"session.message","msg_id":"m2","role":"user","text":"二","via":"queue","client_id":"k2""#), // 14 (late)
            L(#"{"kind":"helper.session_exit","session_id":"s","code":9,"pid":100,"start_seq":0,"last_seq":5}"#),   // 15
            se(nil, #""kind":"session.start","last_seq":5,"resumed":true"#),                                        // 16 B
            se(nil, #""kind":"session.queue","items":[]"#),                                                         // 17 attach's snapshot
        ]
        let exitAt = 15, aLastLive = 13
        let late: [Int: Int] = [14: -1]                 // delayed; no live-only line of A after it
        var streams: [[Int]] = [live.indices.filter { live[$0].event.isSessionEvent && $0 != exitAt && late[$0] == nil },
                                live.indices.filter { !live[$0].event.isSessionEvent }, [14], [exitAt]]
        streams.removeAll { $0.isEmpty }
        func allowed(_ i: Int, _ done: Set<Int>) -> Bool {
            if i == exitAt { return done.contains(aLastLive) }
            if !live[i].event.isSessionEvent { return done.contains(0) }
            for (l, before) in late where i == before && !done.contains(l) { return false }
            if late[i] != nil { return live[..<i].indices.allSatisfy { live[$0].seq != nil || !live[$0].event.isSessionEvent || $0 == exitAt || done.contains($0) } }
            return true
        }
        struct RNG { var x: UInt64; mutating func next(_ n: Int) -> Int { x = x &* 6364136223846793005 &+ 1442695040888963407; return Int((x >> 33) % UInt64(n)) } }
        func merge(_ pick: ([Int]) -> Int) -> [Int] {
            var idx = Array(repeating: 0, count: streams.count), out: [Int] = [], done: Set<Int> = []
            while out.count < live.count {
                let ready = streams.indices.filter { idx[$0] < streams[$0].count && allowed(streams[$0][idx[$0]], done) }
                guard !ready.isEmpty else { return [] }
                let k = pick(ready); let i = streams[k][idx[k]]; idx[k] += 1; out.append(i); done.insert(i)
            }
            return out
        }
        let want = SessionReducer.reduce(SessionState(), live)
        check(want.queue.isEmpty && want.unsent.isEmpty && want.messages.filter { $0.role == "user" }.map(\.text) == ["新建 a.txt", "一", "二"] && want.message("a1")?.interrupted == true,
              "live: the queue consumed, nothing unsent: \(want.unsent)")
        var orders: [[Int]] = [merge { $0[0] }, merge { $0.last! }]
        for seed in 1...40 { var g = RNG(x: UInt64(seed)); orders.append(merge { $0[g.next($0.count)] }) }
        var tried = 0
        for o in orders where o.count == live.count {
            tried += 1
            let got = SessionReducer.reduce(SessionState(), o.map { live[$0] })
            if got != want { check(false, "queue order \(o): differs"); dumpDiff(got, want) }
        }
        check(tried == orders.count && orders.contains { ($0.firstIndex(of: exitAt) ?? 0) < ($0.firstIndex(of: 14) ?? 0) }
              && orders.contains { ($0.firstIndex(of: 14) ?? 0) < ($0.firstIndex(of: exitAt) ?? 0) }, "orders: \(tried), the exit before and after the delayed message")
    }
}
