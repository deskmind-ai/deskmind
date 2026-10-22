// The 0.5 main window's model (Shared/Shell.swift: ShellModel, on the app's SessionClient) against the real helper:
// SessionE2E `serve` (Helper/SessionHost.swift on its own socket) with `harness.mjs session` processes and the fake
// model service (fake_model.py). Run by tests/e2e/session_e2e.py in two phases, the helper restarted between them (the
// sessions' processes go with it; their history stays on disk):
//
//   ShellE2E a <socket> <config> <defaults suite> <support dir> <state file>
//       a new conversation: a message, its streamed reply; a long reply streaming (Enter sends nothing meanwhile);
//       a rename; a /cua task's card answered by option index (the composer off while it waits); then the app quits
//   ShellE2E b <socket> <config> <defaults suite> <support dir> <state file>
//       the app again (a new client): the list has the session, under the user's name; a message to it opens it again
//       with the app's settings (defaultConfig) and its history comes back; a conversation with no key for its model
//       shows session.error no_key with the settings button, and after the settings change a retry is answered;
//       delete removes it from the list and from the disk
//
// No window, no real model, nothing driven on this Mac (the simulated computer). Prints PASS or FAIL per check; the
// exit status is the number of failures. Built with PathTransport.swift.

import Foundation

@main
enum ShellE2E {
    nonisolated(unsafe) static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL") shell: \(what)")
        fflush(stdout)
        if !ok { failures += 1 }
    }
    static func until(_ timeout: Double = 30, _ f: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if f() { return true }; usleep(20_000) }
        return f()
    }

    /// The model's own queue: every delivery and every action of the test runs on it, one at a time (the main thread's
    /// part in the app).
    static let ui = DispatchQueue(label: "shell.e2e.main")
    nonisolated(unsafe) static var config = ""

    static func makeModel(socket: String, suite: String) -> ShellModel {
        let transport = StoppableTransport(PathTransport(path: socket))
        let m = ShellModel(client: SessionClient(transport: transport), defaults: UserDefaults(suiteName: suite)!,
                           config: { config }, lang: { .zhHans },
                           work: { DispatchQueue.global().async(execute: $0) }, deliver: { ui.async(execute: $0) })
        transport.isStopped = { [weak m] in m?.stopped ?? true }
        return m
    }

    static func on<T>(_ f: () -> T) -> T { ui.sync(execute: f) }

    static func quit(_ m: ShellModel) {
        m.stopWatching()
        usleep(600_000)    // the watch ends at its next quiet tick
    }

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let a = CommandLine.arguments
        guard a.count == 7, a[1] == "a" || a[1] == "b" else {
            print("usage: ShellE2E a|b <socket> <config> <defaults suite> <support dir> <state file>"); exit(2)
        }
        config = a[3]
        if a[1] == "a" { phaseA(socket: a[2], suite: a[4], stateFile: a[6]) } else { phaseB(socket: a[2], suite: a[4], dir: a[5], stateFile: a[6]) }
        exit(Int32(failures))
    }

    static func assistant(_ m: ShellModel, _ id: String) -> [ChatMessage] {
        on { m.states[id]?.messages.filter { $0.role == "assistant" && !$0.streaming } ?? [] }
    }

    // MARK: a

    static func phaseA(socket: String, suite: String, stateFile: String) {
        let m = makeModel(socket: socket, suite: suite)
        on { m.start() }
        check(until { on { m.reachable && m.rows.isEmpty } }, "the list: reachable, no conversation yet")

        // a new conversation: its first message opens the session, then the reply
        on { m.newConversation(); m.draft = "你好"; m.submit() }
        check(until { on { m.selected != nil } }, "the new conversation opened and selected")
        let sid = on { m.selected } ?? ""
        check(until { assistant(m, sid).first?.text == "你好，我是测试模型。" }, "the reply: \(assistant(m, sid).map(\.text))")
        check(on { m.states[sid]?.messages.first?.text == "你好" && m.states[sid]?.outbox.isEmpty == true }, "the message is the session's (taken from the outbox)")
        check(until { on { m.rows.first?.id == sid && m.rows.first?.title == "你好" } }, "in the list, titled by its first message: \(on { m.rows.map(\.title) })")
        if case .done = on({ m.rows.first?.status ?? .idle }) {} else { check(false, "its dot: done (\(on { String(describing: m.rows.first?.status) }))") }

        // a long reply, streamed: seen growing; meanwhile Enter sends nothing (the text stays); then the whole of it
        on { m.draft = "讲个长故事"; m.submit() }
        check(until { on { (m.states[sid]?.streamingMessage?.text.count ?? 0) > 0 } }, "the reply streams (deltas, before its final message)")
        check(on { m.composer.replying && m.composer.canStop }, "while it streams: the composer waits, Stop is there")
        on { m.draft = "插一句"; m.submit() }
        check(on { m.draft == "插一句" }, "Enter while it streams: nothing sent, the text stays")
        on { m.draft = "" }
        let long = (0..<40).map { "第\($0)段。" }.joined()
        check(until(60) { assistant(m, sid).last?.text == long }, "the long reply, whole")

        // the user's name for it
        on { m.rename(sid, to: "问候") }
        check(on { m.rows.first { $0.id == sid }?.title == "问候" }, "renamed")

        // a computer task: /cua through the same composer; its card answered by option index; the composer off meanwhile
        on { m.draft = "/cua 给笔记换个颜色"; m.submit() }
        check(until { on { m.states[sid]?.openCard != nil } }, "the task's card is open")
        let (run, card) = on { m.states[sid]!.openCard! }
        let model = CardModel(card: card.card, runId: run, askId: card.askId)
        check(on { !m.composer.enabled && m.composer.canStop }, "a card waits: the composer off, Stop there")
        check(on { if case .waitingForYou = m.rows.first(where: { $0.id == sid })!.status { return true }; return false }, "the dot: waiting for you")
        let pick = model.buttons.first { $0.role == .choice } ?? model.buttons[0]
        on { m.click(pick) }
        check(until { on { m.states[sid]?.task(run)?.cards.first?.outcome == .answered } }, "answered (resumed)")
        check(until(60) { on { m.states[sid]?.task(run)?.ended == true } }, "the task ended: \(on { m.states[sid]?.task(run)?.status ?? "-" })")
        let st = on { m.states[sid]!.task(run)! }
        check(st.status != "succeeded" || ShellText.task(st, lang: .zhHans) == "完成", "its line says its status: \(ShellText.task(st, lang: .zhHans))")
        check(until { on { m.composer.enabled } }, "the composer back on")
        check(until(30) { assistant(m, sid).contains { $0.text == "任务结束了。" } }, "the model's line after the task")

        // idle while watched: the helper closes its process (#107 review: ~80 MB each); nothing reads as cut off, the
        // watch goes on, and the next message opens it again
        let shown = on { m.states[sid]! }
        check(until(30) { on { m.states[sid]?.exited != nil } }, "idle and watched: its process closed by the helper")
        let closed = on { m.states[sid]! }
        check(closed.status == shown.status && !closed.messages.contains { $0.interrupted } && closed.unsent.isEmpty
              && !closed.tasks.contains { $0.cutOff } && on({ m.notice }) == nil,
              "not shown as an interruption: the dot as it was (\(closed.status)), nothing cut off, nothing unsent")
        on { m.draft = "还在吗"; m.submit() }
        check(until(60) { assistant(m, sid).last?.text == "收到。" }, "the next message opens it again: answered")
        check(on { m.states[sid]?.exited == nil }, "running again")
        let count = on { m.states[sid]!.messages.count }
        try? "\(sid)\n\(count)\n".write(toFile: stateFile, atomically: true, encoding: .utf8)
        quit(m)
    }

    // MARK: b

    static func phaseB(socket: String, suite: String, dir: String, stateFile: String) {
        let saved = ((try? String(contentsOfFile: stateFile, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        let sid = saved.first ?? "", before = Int(saved.dropFirst().first ?? "") ?? 0
        let good = config
        let m = makeModel(socket: socket, suite: suite)
        on { m.start() }
        // the app again: the session from the list, under the user's name
        check(until { on { m.rows.contains { $0.id == sid } } }, "after a quit and a helper restart: the session is in the list")
        check(on { m.rows.first { $0.id == sid }?.title == "问候" }, "under the name the user gave it: \(on { m.rows.map(\.title) })")

        // opened to read: its history from the stored log, no process (#107 review)
        on { m.select(sid) }
        check(until { on { (m.states[sid]?.messages.count ?? 0) == before } }, "opened to read: its history (\(on { m.states[sid]?.messages.count ?? 0 }) of \(before))")
        let listed = PathTransport(path: socket).request(["op": "sessions.list"])?["sessions"] as? [[String: Any]] ?? []
        check(listed.first { $0["session_id"] as? String == sid }?["open"] as? Bool == false, "and no process for it")

        // a message to it, not opened by this client and not running: opened again with the app's settings, then sent
        on { m.selected = sid; m.draft = "你好"; m.submit() }
        check(until(60) { assistant(m, sid).filter { $0.text == "你好，我是测试模型。" }.count == 2 },
              "reopened with the app's model (defaultConfig): answered: \(assistant(m, sid).map(\.text).suffix(2))")
        let msgs = on { m.states[sid]?.messages ?? [] }
        check(msgs.count == before + 2 && msgs.first?.text == "你好" && msgs.contains { $0.text.hasPrefix("第0段") },
              "the history came back, in order, then the new pair: \(msgs.count) after \(before)")
        check(on { (m.states[sid]?.tasks.count ?? 0) == 1 && m.states[sid]?.tasks.first?.ended == true }, "the task too, ended")

        // no key for the model: session.error no_key, with the settings button and a retry; after the settings change
        // (a key, here the service that has one) the retry is answered by a new process
        config = "openai:deepseek|fake"
        on { m.applySettings(); m.newConversation(); m.draft = "你好"; m.submit() }
        check(until { on { m.selected != nil && m.selected != sid } }, "a second conversation")
        let nokey = on { m.selected } ?? ""
        check(until { on { m.states[nokey]?.errors.last?.error.code == "no_key" } }, "session.error no_key: \(on { m.states[nokey]?.errors.map(\.error.code) ?? [] })")
        let row = on { () -> ErrorRowModel? in
            guard let s = m.states[nokey], let e = s.errors.last else { return nil }
            return ErrorRowModel(e.error, latest: s.timeline.last == .error(e.seq), idle: s.runningTask == nil && s.streamingMessage == nil, lang: .zhHans)
        }
        check(row?.showsSettings == true && row?.showsRetry == true && row?.headline == "模型没有 API 密钥", "its row: the settings button and a retry: \(String(describing: row))")
        config = good
        on { m.settingsChanged() }
        check(until { on { m.states[nokey]?.exited != nil } }, "the settings changed: its idle process ended, to start again with them")
        on { m.retry() }
        check(until(60) { assistant(m, nokey).first?.text == "你好，我是测试模型。" }, "retried with the new settings: answered")

        // delete: gone from the list and from the disk; the other one stays
        on { m.delete(nokey) }
        check(until { on { !m.rows.contains { $0.id == nokey } && m.selected == nil } }, "deleted: gone from the list")
        check(!FileManager.default.fileExists(atPath: dir + "/sessions/" + nokey), "and from the disk")
        on { m.refreshList() }
        check(until { on { m.rows.map(\.id) == [sid] } }, "the helper's list agrees: \(on { m.rows.map(\.id) })")
        quit(m)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}
