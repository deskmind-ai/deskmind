// The main window, the float and the island drawn offscreen, each state to a PNG in light and dark (tests/snapshot.sh
// builds and runs it): the window idle, running, waiting with a card, answered, the 「过程」 tab; the float working, on a
// confirm card, a choice card, a plan's summary, an answer held for its take-back, an expired card, collapsed; the
// island's bar in each of its kinds, at a notch and as the capsule. The states come from protocol lines fed to a ShellModel on a
// transport that answers nothing (as the decision tests do), the 过程 tab from a run folder in a temp dir; the live view
// shows a drawn stand-in, never a real app's window. Nothing is brought forward: the window is ordered in off every
// screen in an accessory process, never made key, and rendered from its layers.
//
// Usage: MainWindowSnapshot <out dir>

import AppKit
import SwiftUI

@main
enum MainWindowSnapshot {
    static let sid = "ses_mail", rid = "run_mail"
    static let t0 = 1_792_900_000.0

    /// A transport with no helper behind it: every write taken, no stream; `sessions.list` answers `sessions`.
    final class Wire: SessionTransport {
        var sessions: [[String: Any]] = []
        func request(_ body: [String: Any]) -> [String: Any]? {
            body["op"] as? String == SessionClient.Op.list ? ["ok": true, "sessions": sessions] : ["ok": true]
        }
        func stream(_ body: [String: Any], onLine: @escaping ([String: Any]) -> Bool, onIdle: @escaping () -> Bool) -> Bool { false }
    }

    /// Defaults kept in memory (as the decision tests' scratchDefaults): nothing reaches cfprefsd or the disk.
    final class MemoryDefaults: UserDefaults {
        private var store: [String: Any] = [:]
        init() { super.init(suiteName: "ai.deskmind.snapshot.memory")! }
        override func object(forKey k: String) -> Any? { store[k] }
        override func set(_ v: Any?, forKey k: String) { store[k] = v }
        override func removeObject(forKey k: String) { store[k] = nil }
        override func set(_ v: Bool, forKey k: String) { set(v as Any?, forKey: k) }
        override func set(_ v: Int, forKey k: String) { set(v as Any?, forKey: k) }
        override func set(_ v: Double, forKey k: String) { set(v as Any?, forKey: k) }
        override func set(_ v: Float, forKey k: String) { set(v as Any?, forKey: k) }
        override func set(_ v: URL?, forKey k: String) { set(v as Any?, forKey: k) }
        override func dictionaryRepresentation() -> [String: Any] { store }
        override func synchronize() -> Bool { true }
    }

    struct Scene {
        let name: String
        let lines: [[String: Any]]
        let now: Double
        var selected: String? = sid
        var process = false
        /// The helper's list (`sessions list`), the rows' only source when no lines are fed (the window as it opens).
        var summaries: [[String: Any]] = []
        var size = NSSize(width: 1440, height: 900)
        /// What the user did after the lines (a message typed and sent, a queued one taken back).
        var act: (@MainActor (ShellModel) -> Void)? = nil
    }

    static func main() {
        let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // (the 过程 tab reads a run folder: a temp one, never the real Application Support)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("deskmind-snapshot-\(UUID().uuidString)")
        DeskMindIPC.supportOverride = support
        defer { try? FileManager.default.removeItem(at: support) }

        let others = otherSessions()
        let scenes = [
            // (U4 §2.6: the window as it opens -- no conversation at all; the list from the helper's summaries alone, as the
            // real window has it before one is opened; the same at the least size)
            Scene(name: "idle-fresh", lines: [], now: t0 + 38, selected: nil),
            Scene(name: "idle", lines: [], now: t0 + 38, selected: nil, summaries: summaries()),
            Scene(name: "idle-min", lines: [], now: t0 + 38, selected: nil, summaries: summaries(), size: NSSize(width: 1098, height: 600)),
            Scene(name: "running", lines: others + running(), now: t0 + 38),
            Scene(name: "waiting", lines: others + running() + waiting(), now: t0 + 58),
            Scene(name: "waiting-uncertain", lines: others + running() + waiting(uncertain: true), now: t0 + 58),
            Scene(name: "answered", lines: others + running() + waiting() + answered(), now: t0 + 66),
            // (U3: the answered lines after a reopen -- the stored session.task_answer only -- and from an older log)
            Scene(name: "answered-replay", lines: others + strip(running() + waiting() + answered()) + stored(), now: t0 + 66),
            Scene(name: "answered-oldlog", lines: others + strip(running() + waiting() + answered()), now: t0 + 66),
            Scene(name: "undone", lines: others + running() + waiting() + answered() + undone(), now: t0 + 90),
            Scene(name: "process", lines: others + running() + waiting() + answered(), now: t0 + 66, process: true),
            // (#133: what the boards draw that had no picture -- the list's every mark, the task paused or the screen locked,
            // a queued message, one taken back, one on its way)
            Scene(name: "sidebar-states", lines: stateSessions() + running(), now: t0 + 38),
            Scene(name: "paused", lines: others + running() + [line("waiting", 9, 30, [:])], now: t0 + 38),
            Scene(name: "locked", lines: others + running() + [line("task_done", 9, 30, ["status": "environment", "reason": "", "summary": "", "cause": "screen_locked"])], now: t0 + 38),
            Scene(name: "queued", lines: others + running() + queue(), now: t0 + 38),
            Scene(name: "withdrawn", lines: others + running() + queue(), now: t0 + 38, act: { shell in
                shell.queueCancel("q_1")
                shell.client.feed(["kind": "session.queue", "session_id": sid, "items": [[String: Any]]()])
            }),
            Scene(name: "sending", lines: others + running(), now: t0 + 38, act: { $0.draft = "发完以后，把明天上午的会议提醒也看一下"; $0.submit() }),
        ] + cardScenes(others)
        writeRunFolder(support, run: running() + waiting() + answered())
        let only = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
        for dark in [false, true] {
            let tag = dark ? "dark" : "light"
            if only == nil || only == "window" {
                for scene in scenes { render(scene, dark: dark, to: out.appendingPathComponent("\(scene.name)-\(tag).png")) }
            }
            if only == nil || only == "float" {
                for (name, lines, phase, fits, collapsed) in floatScenes() {
                    renderFloat(lines, phase: phase, fits: fits, collapsed: collapsed, dark: dark, to: out.appendingPathComponent("float-\(name)-\(tag).png"))
                }
                // (CardStates: hovered -- its 放大 / 收起 / Stop -- and its window off the screen)
                renderFloat(running(), phase: nil, fits: true, collapsed: false, hover: true, dark: dark, to: out.appendingPathComponent("float-hover-\(tag).png"))
                renderFloat(running(), phase: nil, fits: true, collapsed: false, hidden: true, dark: dark, to: out.appendingPathComponent("float-hidden-\(tag).png"))
                // (QuestionCard's English board: the confirm card with an English request -- the card's words are the harness's)
                renderFloat(running() + waitingEnglish(), phase: nil, fits: true, collapsed: false, lang: .en, dark: dark,
                            to: out.appendingPathComponent("float-confirm-en-\(tag).png"))
            }
            if only == nil || only == "firstrun" {
                for (name, step, key, granted) in firstRunScenes() {
                    renderFirstRun(step, key: key, granted: granted, dark: dark, to: out.appendingPathComponent("firstrun-\(name)-\(tag).png"))
                }
            }
            if only == nil || only == "island" {
                for (name, lines, app) in islandScenes() {
                    for notched in [true, false] {
                        renderIsland(lines, app: app, notched: notched, dark: dark,
                                     to: out.appendingPathComponent("island-\(name)-\(notched ? "notch" : "capsule")-\(tag).png"))
                    }
                }
            }
        }
    }

    // MARK: the first run, the float and the island

    /// (name, step, the key's state, permissions granted)
    static func firstRunScenes() -> [(String, FirstRun.Step, FirstRun.KeyState, Bool)] {
        [
            ("1-language", .language, .empty, false),
            ("2-permissions", .permissions, .empty, false),
            ("2-permissions-granted", .permissions, .empty, true),
            ("3-key-empty", .key, .empty, true),
            ("3-key-set", .key, .set(last4: "a1b2"), true),
            ("3-key-checking", .key, .checking, true),
            ("3-key-ok", .key, .ok(model: "deepseek-chat"), true),
            ("3-key-bad", .key, .bad(why: "401 Unauthorized: the key was not accepted"), true),
            ("3-key-unreadable", .key, .unreadable, true),
            ("4-examples", .examples, .empty, true),
        ]
    }

    @MainActor static func renderFirstRun(_ step: FirstRun.Step, key: FirstRun.KeyState, granted: Bool, dark: Bool, to file: URL) {
        var flow = FirstRun(step: step)
        flow.facts.accessibility = granted; flow.facts.screen = granted
        // (a key set, being tried or that works: the key is there, so 继续 is drawn on -- as it is in the app)
        switch key { case .set, .checking, .ok: flow.facts.keySet = true; default: break }
        // (the bad key saved, its check failed: the case 稍后 must still show -- #130 Codex review)
        if case .bad = key { flow.facts.keySet = true; flow.facts.saveOK = true; flow.facts.checkOK = false }
        let page = FirstRunPage(flow: flow, language: .constant(AppLanguage.zhHans.rawValue),
                                form: .constant(ModelForm(provider: CloudProvider.all[0], settings: [:])), keyState: key,
                                granted: { _ in granted }, grant: { _ in }, act: { _ in }, example: { _ in })
        renderView(page.environment(\.lang, .zhHans), size: NSSize(width: 1080, height: 780), dark: dark, wait: 0.5, to: file)
    }

    /// (name, lines, the card's phase if not as the lines leave it, whether the card fits the float, collapsed)
    static func floatScenes() -> [(String, [[String: Any]], CardPhase?, Bool, Bool)] {
        let held = CardPhase.pending(.option(runId: rid, askId: "ask_send", option: 0), until: t0 + 58 + 2)
        return [
            ("working", running(), nil, true, false),
            ("confirm", running() + waiting(), nil, true, false),
            ("choice", running() + choice(), nil, true, false),
            ("plan-summary", Array(running().prefix(6)), nil, false, false),
            ("held", running() + waiting(), held, true, false),
            ("expired", running() + waiting() + [line("ask_void", 14, 700, ["ask_id": "ask_send", "why": "timeout"])], nil, true, false),
            ("capsule", running(), nil, true, true),
            ("free", running() + typed(), nil, false, false),
            ("done", running() + waiting() + answered() + [line("step_result", 18, 70, ["step_id": "st_4", "status": "ok"]),
                      line("task_done", 19, 82, ["status": "succeeded", "reason": "", "summary": "回复了许诺：我看一下再说"])], nil, true, false),
            ("failed", running() + [line("task_done", 9, 57, ["status": "failed", "reason": "", "summary": "同一步反复失败，没能写入回复"])], nil, true, false),
        ]
    }

    /// A card that takes the user's own words (free_text): the main window's -- the float says so.
    static func typed() -> [[String: Any]] {
        let card: [String: Any] = [
            "kind": "missing", "blocking": true, "free_text": true, "headline": "回复里署什么名字？", "text": "回复里署什么名字？",
            "options": [["kind": "cancel", "text": "先别做了"]],
        ]
        return [line("ask", 9, 52, ["ask_id": "ask_name", "card": card]), line("waiting", 10, 52, ["ask_id": "ask_name"])]
    }

    /// A card with two readings and 「由你决定」.
    static func choice() -> [[String: Any]] {
        let card: [String: Any] = [
            "kind": "ambiguity", "blocking": true, "headline": "许诺有两封没回的邮件，回哪一封？", "text": "许诺有两封没回的邮件，回哪一封？",
            "options": [["kind": "reading", "text": "10 月 20 日 · 下周的方案评审", "detail": "最近一封"],
                        ["kind": "reading", "text": "10 月 18 日 · 报价单 v2"], ["kind": "delegate", "text": "由你决定"]],
        ]
        return [line("ask", 9, 52, ["ask_id": "ask_which", "card": card]), line("waiting", 10, 52, ["ask_id": "ask_which"])]
    }

    /// (name, lines, the app its step acts in)
    static func islandScenes() -> [(String, [[String: Any]], String?)] {
        let start = Array(running().prefix(3))
        func end(_ status: String) -> [[String: Any]] { running() + [line("task_done", 9, 57, ["status": status, "reason": "", "summary": "s"])] }
        return [
            ("preparing", start, nil),
            ("working", running(), "Safari"),
            ("needs-you", running() + waiting(), "Safari"),
            ("paused", running() + [line("waiting", 9, 40, [:])], "Safari"),
            ("done", end("succeeded"), nil),
            ("failed", end("failed"), nil),
            ("stopped", end("stopped"), nil),
        ]
    }

    @MainActor static func state(_ lines: [[String: Any]], now: Double, lang: ResolvedLang = .zhHans) -> (ShellModel, SessionState) {
        let shell = ShellModel(client: SessionClient(transport: Wire()), defaults: MemoryDefaults(), config: { "openai:local|fake" },
                               lang: { lang }, now: { now }, work: { $0() }, deliver: { $0() })
        for l in lines { shell.client.feed(l) }
        shell.select(sid)
        return (shell, shell.states[sid] ?? SessionState())
    }

    @MainActor static func renderFloat(_ lines: [[String: Any]], phase: CardPhase?, fits: Bool, collapsed: Bool, hover: Bool = false, hidden: Bool = false,
                                       lang: ResolvedLang = .zhHans, dark: Bool, to file: URL) {
        let (shell, s) = state(lines, now: t0 + 58, lang: lang)
        guard let task = s.tasks.last else { return }
        let pinned = shell.pinned(s)
        let card = pinned.map { CardModel(card: $0.card.card, runId: $0.runId, askId: $0.card.askId) }
        let ph = phase ?? pinned?.phase
        let placement = ph.map { CardPlacement.place($0, fitsFloat: fits, window: .behindVisible, frontNow: false, float: .visible) }
        let f = FloatController.shared
        f.userCollapsed = collapsed
        f.preview(FloatController.Now(sessionId: sid, status: s.status, task: task, card: card, phase: ph, placement: placement,
                                      askedAt: pinned?.card.askedAt))
        let view = ZStack(alignment: .bottomTrailing) {
            Color(red: 0.89, green: 0.91, blue: 0.92)
            FloatView(shell: shell, float: f, still: still(), stillHidden: hidden, stillHover: hover).padding(16)
        }
        renderView(view.environment(\.lang, lang), size: NSSize(width: 340, height: 640), dark: dark, wait: 0.6, to: file)
        f.preview(nil)
    }

    @MainActor static func renderIsland(_ lines: [[String: Any]], app: String?, notched: Bool, dark: Bool, to file: URL) {
        let (shell, s) = state(lines, now: t0 + 58)
        guard let task = s.tasks.last else { return }
        let model = OverlayModel()
        let ended = task.ended
        model.phase = ended ? (task.status == "succeeded" ? .passed : .failed) : .running
        model.frame = IslandFeed.frame(task, pinned: shell.pinned(s).map { ($0.card, $0.phase) }, app: app, floatShows: true, lang: .zhHans)
        let h: CGFloat = notched ? 37 : Island.barHeight
        let view = ZStack(alignment: .top) {
            Color(red: 0.36, green: 0.40, blue: 0.45)
            VStack(spacing: 0) {
                Color(red: 0.16, green: 0.17, blue: 0.19).frame(height: notched ? 37 : 24)     // (the menu bar)
            }
            IslandView(model: model, height: h, notched: notched, notchWidth: notched ? 200 : nil, onStop: {}, onTap: { _ in }, now: { t0 + 58 })
                .frame(width: Island.barWideWidth, height: h)
                .padding(.top, notched ? 0 : 24)
            // (the notch itself, 200 pt as on a 14" MacBook Pro, drawn over the bar as the hardware hides what is under it)
            if notched { Color.black.frame(width: 200, height: h) }
        }
        renderView(view.environment(\.lang, .zhHans), size: NSSize(width: 560, height: notched ? 60 : 84), dark: dark, wait: 0.3, to: file)
    }

    // MARK: the states, as the harness would send them

    static func line(_ kind: String, _ seq: Int, _ t: Double, _ f: [String: Any]) -> [String: Any] {
        var l = f
        l["kind"] = kind; l["session_id"] = sid; l["run_id"] = rid; l["seq"] = seq; l["t"] = t0 + t
        return l
    }

    /// The helper's list as `sessions list` gives it (no messages fed): a task this morning, chats from yesterday and
    /// last week.
    static func summaries() -> [[String: Any]] {
        [["session_id": sid, "title": "回复许诺说我看一下再说", "updated_at": t0 + 30 - 600],
         ["session_id": "ses_folder", "title": "整理下载文件夹", "updated_at": t0 - 3600 * 5],
         ["session_id": "ses_week", "title": "汇总这周的周报数据", "updated_at": t0 - 3600 * 30],
         ["session_id": "ses_trip", "title": "查一下下周去杭州的高铁", "updated_at": t0 - 3600 * 24 * 9]]
    }

    static func otherSessions() -> [[String: Any]] {
        [
            ["kind": "session.message", "session_id": "ses_folder", "seq": 1, "t": t0 - 3600, "msg_id": "m_f1", "role": "user", "text": "整理下载文件夹"],
            ["kind": "session.message", "session_id": "ses_folder", "seq": 2, "t": t0 - 3500, "msg_id": "m_f2", "role": "assistant", "text": "整理好了：按类型分进了 5 个文件夹。"],
            ["kind": "session.message", "session_id": "ses_week", "seq": 1, "t": t0 - 7200, "msg_id": "m_w1", "role": "user", "text": "汇总这周的周报数据"],
            ["kind": "session.message", "session_id": "ses_week", "seq": 2, "t": t0 - 7100, "msg_id": "m_w2", "role": "assistant", "text": "这周一共 12 条记录，已经按项目汇总。"],
        ]
    }

    /// A message typed while the task works, waiting in the queue (session.queue).
    static func queue() -> [[String: Any]] {
        [["kind": "session.queue", "session_id": sid, "items": [["id": "q_1", "text": "发完以后，把明天上午的会议提醒也看一下"]]]]
    }

    /// One conversation in each of the list's states (P1Main, P3States 「对话的状态点」): waiting for you, thinking, done
    /// yesterday, failed, paused, the screen locked, looking only.
    static func stateSessions() -> [[String: Any]] {
        func task(_ s: String, _ title: String, _ t: Double, _ run: [[String: Any]]) -> [[String: Any]] {
            let r = "run_" + s
            var out: [[String: Any]] = [
                ["kind": "session.message", "session_id": s, "seq": 1, "t": t, "msg_id": s + "_m1", "role": "user", "text": title],
                ["kind": "session.task", "session_id": s, "seq": 2, "t": t + 1, "msg_id": s + "_m2", "run_id": r, "raw": title, "goal": title, "by": "model", "reply_to": s + "_m1"],
                ["kind": "start", "session_id": s, "run_id": r, "seq": 1, "t": t + 1, "raw": title, "lang": "zh"],
            ]
            for (i, l) in run.enumerated() { var l = l; l["session_id"] = s; l["run_id"] = r; l["seq"] = i + 2; l["t"] = t + 2 + Double(i); out.append(l) }
            return out
        }
        let step: [String: Any] = ["kind": "step", "step_id": "st_1", "text": "{\"kind\":\"read\"}", "human": "看一眼", "object": "window:com.example.Files#7", "consequence": "read"]
        let choose: [String: Any] = ["kind": "ambiguity", "blocking": true, "headline": "放进哪个文件夹？", "text": "放进哪个文件夹？",
                                     "options": [["kind": "choice", "text": "文稿"], ["kind": "choice", "text": "下载"]]]
        return task("ses_folder", "整理下载文件夹", t0 - 600, [step, ["kind": "ask", "ask_id": "a1", "card": choose], ["kind": "waiting", "ask_id": "a1"]])
            + task("ses_week", "汇总这周的周报数据", t0 - 300, [["kind": "preparing"]])
            + task("ses_trip", "比较下周去上海的机票", t0 - 3600 * 30, [step, ["kind": "task_done", "status": "succeeded", "reason": "", "summary": "比较好了"]])
            + task("ses_invoice", "导出 9 月的发票", t0 - 3600 * 2, [step, ["kind": "task_done", "status": "failed", "reason": "网站要求重新登录", "summary": ""]])
            + task("ses_pause", "整理桌面截图", t0 - 900, [step, ["kind": "waiting"]])
            + task("ses_lock", "备份照片", t0 - 1200, [step, ["kind": "task_done", "status": "environment", "reason": "", "summary": "", "cause": "screen_locked"]])
            + task("ses_look", "核对报销单", t0 - 1500, [step, ["kind": "verify", "verdict": "unknown", "reason": "r", "missing_kind": "evidence"]])
    }

    /// Asked in chat, a task by DeskMind: its plan agreed, step 1 done, step 2 under way in a (drawn) mail window.
    static func running() -> [[String: Any]] {
        let plan: [[String: Any]] = [
            ["purpose": "找到许诺 10 月 20 日的邮件", "objects": ["window:mail"], "consequence": "read"],
            ["purpose": "点「回复」，写入「我看一下再说」", "objects": ["window:mail"], "consequence": "modify_user"],
            ["purpose": "点「发送」", "objects": ["window:mail"], "consequence": "external"],
            ["purpose": "确认已经发出", "objects": ["window:mail"], "consequence": "read"],
        ]
        let planCard: [String: Any] = [
            "kind": "plan", "blocking": true, "headline": "回复许诺：4 步，1 步往外发，到时再确认",
            "plan": ["steps": [["purpose": "找到许诺 10 月 20 日的邮件", "class": "read", "objects": [], "sites": []],
                               ["purpose": "点「回复」，写入「我看一下再说」", "class": "modify_user", "objects": [], "sites": []],
                               ["purpose": "点「发送」", "class": "external", "objects": [], "sites": [["host": "mail.example.com", "sends": "「我看一下再说」"]]],
                               ["purpose": "确认已经发出", "class": "read", "objects": [], "sites": []]]],
            "text": "我打算这样做：\n1. 找到许诺 10 月 20 日的邮件\n2. 点「回复」，写入「我看一下再说」\n3. 点「发送」——往外发，到时再确认\n4. 确认已经发出",
            "options": [["kind": "approve", "text": "可以，就这样做"], ["kind": "cancel", "text": "先别做了"]],
        ]
        return [
            ["kind": "session.message", "session_id": sid, "seq": 1, "t": t0, "msg_id": "m_1", "role": "user", "text": "回复许诺说我看一下再说"],
            ["kind": "session.task", "session_id": sid, "seq": 2, "t": t0 + 1, "msg_id": "m_2", "run_id": rid, "raw": "回复许诺说我看一下再说",
             "goal": "回复许诺：我看一下再说", "by": "model", "reply_to": "m_1"],
            line("start", 1, 1, ["raw": "回复许诺说我看一下再说", "lang": "zh"]),
            line("plan", 2, 3, ["steps": plan]),
            line("ask", 3, 4, ["ask_id": "ask_plan", "card": planCard]),
            line("waiting", 4, 4, ["ask_id": "ask_plan"]),
            line("resumed", 5, 9, ["ask_id": "ask_plan", "answer": ["option": 0]]),
            line("step", 6, 12, ["step_id": "st_1", "plan_step": 1, "text": "{\"kind\":\"click\"}", "human": "打开许诺 10 月 20 日的邮件",
                                 "object": "window:com.apple.Safari#4242", "consequence": "read"]),
            line("step_result", 7, 18, ["step_id": "st_1", "status": "ok"]),
            line("step", 8, 22, ["step_id": "st_2", "plan_step": 2, "text": "{\"kind\":\"set_value\"}", "human": "正在输入「我看一下再说」",
                                 "object": "window:com.apple.Safari#4242", "consequence": "modify_user", "object_label": "Safari 窗口「Re: 下周的方案评审」",
                                 "target": ["id": "body", "label": "正文", "role": "textarea", "rect_norm": [0.22, 0.30, 0.74, 0.16]]]),
        ]
    }

    /// Step 2 done; step 3 sends: the action card waits, pinned above the composer.
    /// `uncertain`: an earlier send of this run has an unknown result -- the card names it, and the yes is for this once.
    static func waiting(uncertain: Bool = false) -> [[String: Any]] {
        var card: [String: Any] = [
            "kind": "action", "blocking": true, "headline": "要在网页邮箱里点「发送」吗？",
            "text": "要在网页邮箱里点「发送」吗？这会把回复发给许诺。",
            "consent": ["action": "click", "action_text": "点「发送」", "target": "发送", "object": "window:com.apple.Safari#4242",
                        "object_label": "Safari 窗口「Re: 下周的方案评审」", "consequence": "external", "site": "mail.example.com",
                        "outgoing": [["kind": "field", "label": "收件人", "value": "许诺 <xu.nuo@example.com>"],
                                     ["kind": "field", "label": "主题", "value": "Re: 下周的方案评审"],
                                     ["kind": "typed", "label": "", "value": "我看一下再说"],
                                     ["kind": "text", "label": "", "value": "10月20日 许诺 写道：方案初稿在附件里。"]],
                        "target_box": ["rect_norm": [0.22, 0.87, 0.12, 0.075], "frame": [100, 600, 84, 36]]],
            "options": [["kind": "approve", "text": "可以"], ["kind": "skip_step", "text": "这一步不要"], ["kind": "cancel", "text": "先别做了"]],
        ]
        if uncertain, var c = card["consent"] as? [String: Any] {
            c["uncertain"] = [["consequence": "external", "object": "window:com.apple.Safari#4242", "text": "点「发送」",
                               "outgoing": [["kind": "typed", "label": "内容", "value": "「我看一下」"]]]]
            c["uncertain_total"] = 1
            c["model_says_unchecked"] = "上一次点「发送」后页面没有变化，可能没发出去"
            card["consent"] = c
            card["headline"] = "要在网页邮箱里点「发送」吗？（之前有 1 步结果不确定，先看一眼）"
        }
        return [
            line("step_result", 9, 40, ["step_id": "st_2", "status": "ok"]),
            line("changes", 10, 40, ["created": [], "modified": [], "deleted": [], "external": [], "unconfirmed": [], "created_windows": []]),
            line("step", 11, 48, ["step_id": "st_3", "plan_step": 3, "text": "{\"kind\":\"click\"}", "human": "准备点「发送」，等你确认",
                                  "object": "window:com.apple.Safari#4242", "consequence": "external", "object_label": "Safari 窗口「Re: 下周的方案评审」",
                                  "target": ["id": "send", "label": "发送", "role": "button", "rect_norm": [0.22, 0.86, 0.12, 0.08]]]),
            line("ask", 12, 52, ["ask_id": "ask_send", "card": card]),
            line("waiting", 13, 52, ["ask_id": "ask_send"]),
        ]
    }

    /// The same card from an English request: its words in English, as the harness writes them for one.
    static func waitingEnglish() -> [[String: Any]] {
        waiting().map { l in
            guard l["kind"] as? String == "ask", var card = l["card"] as? [String: Any], var c = card["consent"] as? [String: Any] else { return l }
            card["headline"] = "Click “Send” in the web mail?"
            card["text"] = "Click “Send” in the web mail? This sends the reply to Xu Nuo."
            card["options"] = [["kind": "approve", "text": "OK"], ["kind": "skip_step", "text": "Not this step"], ["kind": "cancel", "text": "Stop for now"]]
            c["action_text"] = "Click “Send”"; c["target"] = "Send"; c["object_label"] = "Safari window “Re: Next week's review”"
            c["outgoing"] = [["kind": "field", "label": "To", "value": "Xu Nuo <xu.nuo@example.com>"],
                             ["kind": "field", "label": "Subject", "value": "Re: Next week's review"],
                             ["kind": "typed", "label": "", "value": "Let me take a look first"]]
            card["consent"] = c
            var out = l; out["card"] = card
            return out
        }
    }

    /// Answered 「可以」: sent, step 4 under way.
    static func answered() -> [[String: Any]] {
        [
            line("resumed", 14, 60, ["ask_id": "ask_send", "answer": ["option": 0]]),
            line("step_result", 15, 61, ["step_id": "st_3", "status": "ok"]),
            line("changes", 16, 61, ["created": ["/Users/demo/Desktop/回复草稿.txt"], "modified": [], "deleted": [], "external": [], "unconfirmed": []]),
            line("step", 17, 63, ["step_id": "st_4", "plan_step": 4, "text": "{\"kind\":\"read\"}", "human": "确认已经发出",
                                  "object": "window:com.apple.Safari#4242", "consequence": "read"]),
        ]
    }

    /// The task done, then all of it undone (its result card's undo).
    static func undone() -> [[String: Any]] {
        let result: [String: Any] = ["kind": "result", "text": "做完了：回复许诺「我看一下再说」",
                                     "options": [["kind": "approve", "text": "好的"], ["kind": "undo", "text": "撤回"]], "free_text": false, "blocking": false]
        return [
            line("step_result", 18, 70, ["step_id": "st_4", "status": "ok"]),
            line("task_done", 19, 72, ["status": "succeeded", "reason": "", "summary": "回复了许诺", "result_card": result, "answer": NSNull(),
                                       "changes": ["created": ["/Users/demo/Desktop/回复草稿.txt"], "modified": [], "deleted": [], "external": [], "unconfirmed": []]]),
            ["kind": "session.task_end", "session_id": sid, "seq": 3, "t": t0 + 73, "run_id": rid, "status": "succeeded", "summary": "回复了许诺",
             "undo": "open", "reason": "", "changes": ["created": ["/Users/demo/Desktop/回复草稿.txt"], "modified": [], "deleted": [], "external": []]],
            line("result_response", 20, 80, ["picked": "undo", "effect": "undone 1/1", "undone": 1, "total": 1, "refused": NSNull()]),
            ["kind": "session.task_undo", "session_id": sid, "seq": 4, "t": t0 + 81, "run_id": rid, "undone": 1, "total": 1, "refused": NSNull()],
        ]
    }

    // MARK: cards (#133): each card and result state the boards draw (P3States 「卡片 × 状态」, 「结果卡」; P1Main)

    static func cardScenes(_ others: [[String: Any]]) -> [Scene] {
        var out: [Scene] = []
        func scene(_ name: String, _ run: [[String: Any]], session: [[String: Any]] = [], now: Double = 90) {
            out.append(Scene(name: "card-" + name, lines: others + taskStart() + run + session, now: t0 + now))
        }
        let kinds: [(String, [String: Any], [String: Any])] = [
            ("plan", planCard(), planCard(changed: true)), ("action", actionCard(), actionCard(changed: true)),
            ("choice", choiceCard(2), choiceCard(2, changed: true)), ("missing", missingCard(), missingCard(changed: true)),
        ]
        // 未回答
        for (k, c, _) in kinds { scene(k + "-open", asked("a_\(k)", c, seq: 3, t: 4)) }
        scene("choice6-open", asked("a_six", choiceCard(6), seq: 3, t: 4))
        // 已回答: whole while no card waits (P1Main), a line each while one does (P1Waiting)
        let answered = asked("a_plan", planCard(), seq: 3, t: 4) + [line("resumed", 5, 9, ["ask_id": "a_plan", "answer": ["option": 0]])]
            + asked("a_choice", choiceCard(2), seq: 6, t: 10) + [line("resumed", 8, 14, ["ask_id": "a_choice", "answer": ["option": 0]])]
            + asked("a_missing", missingCard(), seq: 9, t: 16) + [line("resumed", 11, 20, ["ask_id": "a_missing", "answer": ["text": "reimburse.example.com"]])]
            + asked("a_action", actionCard(), seq: 12, t: 22) + [line("resumed", 14, 26, ["ask_id": "a_action", "answer": ["option": 0]])]
            + [line("step", 15, 30, ["step_id": "st_9", "plan_step": 4, "text": "{\"kind\":\"read\"}", "human": "确认已经发出",
                                     "object": "window:com.apple.Safari#4242", "consequence": "read"])]
        scene("answered", answered)
        scene("answered-rows", answered + asked("a_next", actionCard(), seq: 16, t: 40))
        // 改主意后作废重问: the user's change, the old card voided by it, the new one
        for (k, c, changed) in kinds {
            scene(k + "-reasked", asked("a_\(k)", c, seq: 3, t: 4) + [
                line("steered", 5, 8, ["text": "改成回复：明天给你答复"]),
                line("ask_void", 6, 8, ["ask_id": "a_\(k)", "why": "steer"]),
            ] + asked("a_\(k)2", changed, seq: 7, t: 10), session: [
                ["kind": "session.steer", "session_id": sid, "seq": 3, "t": t0 + 7, "run_id": rid, "text": "改成回复：明天给你答复"],
            ])
        }
        // 过期或已停止: the action card expired (the task waits on it), the others stopped with the task
        scene("action-expired", asked("a_action", actionCard(), seq: 3, t: 4) + [line("ask_void", 5, 604, ["ask_id": "a_action", "why": "timeout"])], now: 610)
        for (k, c, _) in kinds where k != "action" {
            scene(k + "-stopped", asked("a_\(k)", c, seq: 3, t: 4) + [
                line("ask_void", 5, 30, ["ask_id": "a_\(k)", "why": "stop"]),
                line("task_done", 6, 31, ["status": "stopped", "reason": "stopped by the app", "cause": "user_stopped", "summary": "", "result_card": NSNull(),
                                          "answer": NSNull(), "changes": ["created": [], "modified": [], "deleted": [], "external": [], "unconfirmed": []]]),
            ], session: [["kind": "session.task_end", "session_id": sid, "seq": 3, "t": t0 + 32, "run_id": rid, "status": "stopped", "summary": "",
                          "undo": "none", "reason": "stopped by the app", "cause": "user_stopped"]])
        }
        // 结果卡
        func done(_ status: String, text: String, summary: String, changes: [String: Any], undo: Bool) -> [[String: Any]] {
            var options: [[String: Any]] = [["kind": "approve", "text": "好的"]]
            if undo { options.append(["kind": "undo", "text": "撤回"]) }
            var f: [String: Any] = ["status": status, "reason": "", "summary": summary, "answer": NSNull(), "changes": changes,
                                    "result_card": ["kind": "result", "text": text, "options": options, "free_text": false, "blocking": false]]
            if undo { f["undo_until"] = t0 + 3600 }
            return [line("task_done", 3, 72, f)]
        }
        func end(_ status: String, undo: Bool) -> [[String: Any]] {
            [["kind": "session.task_end", "session_id": sid, "seq": 3, "t": t0 + 73, "run_id": rid, "status": status, "summary": "",
              "undo": undo ? "open" : "none", "reason": "", "undo_until": t0 + 3600]]
        }
        let none: [String: Any] = ["created": [], "modified": [], "deleted": [], "external": [], "unconfirmed": []]
        scene("result-sent", done("succeeded", text: "做了：回复许诺「我看一下再说」", summary: "回复了许诺",
                                  changes: ["created": [], "modified": [], "deleted": [], "external": ["1 封 → 许诺"], "unconfirmed": []], undo: false),
              session: end("succeeded", undo: false))
        scene("result-partial", done("succeeded", text: "做了：把 9 月的发票放回「下载」", summary: "整理了发票",
                                     changes: ["created": [], "modified": [], "deleted": ["安装包 (1).dmg"], "external": [], "unconfirmed": []], undo: true),
              session: end("succeeded", undo: true) + [
                ["kind": "session.task_undo", "session_id": sid, "seq": 4, "t": t0 + 81, "run_id": rid, "undone": 1, "total": 2,
                 "refused": "安装包 (1).dmg：废纸篓已经清空"]])
        scene("result-nothing", done("succeeded", text: "做了：查了许诺上周发来的报价单", summary: "查了报价单", changes: none, undo: false),
              session: end("succeeded", undo: false))
        scene("result-unconfirmed", done("unconfirmed", text: "做了：点了「发送」，邮箱提示「已发送」", summary: "点了发送",
                                         changes: ["created": [], "modified": [], "deleted": [], "external": [], "unconfirmed": ["已发送列表没刷新，没看到这封"]], undo: false),
              session: end("unconfirmed", undo: false))
        return out
    }

    /// The task as it starts (the user's words, the session's task, its plan).
    static func taskStart() -> [[String: Any]] {
        let r = running()
        return Array(r.prefix(4))
    }

    /// A card asked (`ask`, then `waiting`) at run seq `seq`.
    static func asked(_ id: String, _ card: [String: Any], seq: Int, t: Double) -> [[String: Any]] {
        [line("ask", seq, t, ["ask_id": id, "card": card]), line("waiting", seq + 1, t, ["ask_id": id])]
    }

    static func planCard(changed: Bool = false) -> [String: Any] {
        let reply = changed ? "「明天给你答复」" : "「我看一下再说」"
        return [
            "kind": "plan", "blocking": true, "headline": "计划 · 4 步",
            "plan": ["steps": [["purpose": "在后台打开网页邮箱，找到许诺 10 月 20 日的邮件", "class": "read", "objects": [], "sites": []],
                               ["purpose": "点「回复」，写入" + reply, "class": "modify_user", "objects": ["网页邮箱里的回复草稿"], "sites": []],
                               ["purpose": "点「发送」", "class": "external", "objects": ["发给许诺的一封邮件"], "sites": [["host": "mail.example.com", "sends": reply + " → 许诺"]]],
                               ["purpose": "确认已经发出", "class": "read", "objects": [], "sites": []]],
                     "foreground": ["apps": []]],
            "text": "我打算这样做：回复许诺" + reply,
            "options": [["kind": "approve", "text": "可以，就这样做"], ["kind": "cancel", "text": "先别做了"]], "free_text": false,
        ]
    }

    static func actionCard(changed: Bool = false) -> [String: Any] {
        var out: [[String: Any]] = [["kind": "field", "label": "收件人", "value": "许诺 <xu.nuo@example.com>"],
                                    ["kind": "field", "label": "主题", "value": "Re: 下周的方案评审"],
                                    ["kind": "typed", "label": "", "value": "我看一下再说"]]
        if changed { out.insert(["kind": "field", "label": "抄送", "value": "王磊"], at: 1) }
        return [
            "kind": "action", "blocking": true, "headline": "要在网页邮箱里点「发送」吗？", "text": "要在网页邮箱里点「发送」吗？这会把回复发给许诺。",
            "consent": ["action": "click", "action_text": "点「发送」", "target": "发送", "object": "window:com.apple.Safari#4242",
                        "object_label": "Safari 窗口「Re: 下周的方案评审」", "consequence": "external", "site": "mail.example.com", "outgoing": out],
            "options": [["kind": "approve", "text": "可以"], ["kind": "skip_step", "text": "这一步不要"], ["kind": "cancel", "text": "先别做了"]],
        ]
    }

    static func choiceCard(_ n: Int, changed: Bool = false) -> [String: Any] {
        let two: [[String: Any]] = changed
            ? [["kind": "reading", "text": "都写「我看一下再说」"], ["kind": "reading", "text": "分开写"]]
            : [["kind": "reading", "text": "10 月 20 日 ·「下周的方案评审」", "detail": "最近一封"], ["kind": "reading", "text": "10 月 18 日 ·「报价单 v2」"]]
        let six: [[String: Any]] = ["新建「2026-09 发票」放进去", "放进已有的「发票」文件夹", "放进「报销」文件夹", "按月份分到各自的文件夹", "只改名，不移动", "放到桌面"]
            .map { ["kind": "proposal", "text": $0] }
        return [
            "kind": "ambiguity", "blocking": true,
            "headline": n > 2 ? "9 月的发票放到哪？" : (changed ? "两封都回，用同一句话吗？" : "许诺有两封没回的邮件，回哪一封？"),
            "text": n > 2 ? "「下载」里有 [N] 个 9 月的发票 PDF。" : "许诺有两封没回的邮件。",
            "options": (n > 2 ? six : two) + [["kind": "delegate", "text": "由你决定"], ["kind": "cancel", "text": "先别做了"]], "free_text": true,
        ]
    }

    static func missingCard(changed: Bool = false) -> [String: Any] {
        [
            "kind": "missing", "blocking": true, "headline": changed ? "新的报销系统网址是？" : "要传到哪个报销网站？",
            "text": changed ? "你说传到新的报销系统，但不知道它的网址。" : "计划第 6 步要上传发票，但不知道网址。它不会去猜。",
            "options": [["kind": "cancel", "text": "先别做了"]], "free_text": true,
        ]
    }

    /// The run lines without the answers they carried (a reopen replays the session's stored copy; an older log has none).
    static func strip(_ lines: [[String: Any]]) -> [[String: Any]] {
        lines.map { l in var l = l; l.removeValue(forKey: "answer"); return l }
    }
    /// The session's stored copies of the applied answers (session.task_answer).
    static func stored() -> [[String: Any]] {
        [["kind": "session.task_answer", "session_id": sid, "seq": 3, "t": t0 + 9, "run_id": rid, "ask_id": "ask_plan", "option": 0],
         ["kind": "session.task_answer", "session_id": sid, "seq": 4, "t": t0 + 60, "run_id": rid, "ask_id": "ask_send", "option": 0]]
    }

    /// The run's own record (sessions/<session>/runs/<run>/events.jsonl), as the harness writes it, for 「过程」.
    static func writeRunFolder(_ support: URL, run: [[String: Any]]) {
        let dir = support.appendingPathComponent("sessions/\(sid)/runs/\(rid)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = run.filter { $0["run_id"] as? String == rid }.map { l -> String in
            var e = l; e.removeValue(forKey: "session_id"); e.removeValue(forKey: "run_id")
            return String(decoding: try! JSONSerialization.data(withJSONObject: e, options: [.sortedKeys]), as: UTF8.self)
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
    }

    // MARK: drawing

    @MainActor static func render(_ scene: Scene, dark: Bool, to file: URL) {
        let defaults = MemoryDefaults()
        let wire = Wire()
        wire.sessions = scene.summaries
        let shell = ShellModel(client: SessionClient(transport: wire), defaults: defaults, config: { "openai:local|fake" },
                               lang: { .zhHans }, now: { scene.now }, work: { $0() }, deliver: { $0() })
        if !scene.summaries.isEmpty { shell.refreshList() }
        for l in scene.lines { shell.client.feed(l) }
        if let s = scene.selected { shell.select(s) }
        if scene.process { shell.pickTab(.process) }
        scene.act?(shell)
        let size = scene.size
        let root = MainColumns(shell: shell, openSettings: {}, cloud: SidebarCloud(on: true, ready: true, provider: "DeepSeek"),
                               mac: MacFacts(missing: []), still: scene.selected == nil ? nil : still())
            .environment(\.lang, .zhHans)
        renderView(root, size: size, dark: dark, wait: scene.process ? 2.0 : 0.8, to: file)
    }

    @MainActor static func renderView(_ view: some View, size: NSSize, dark: Bool, wait: Double, to file: URL) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = host
        w.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))     // (off every screen; never key, never front)
        w.orderFrontRegardless()
        // (the 过程 tab reads its folder off the main queue: let it land)
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        host.layoutSubtreeIfNeeded()
        w.displayIfNeeded()
        let scale = 2
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        (host.superview ?? host).layer?.render(in: ctx)
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        w.orderOut(nil)
        print(file.path)
    }

    /// The live view's stand-in: a drawn mail-compose window (no real app), window number 4242 as the steps say.
    static func still() -> LiveDock.Picture {
        let size = NSSize(width: 720, height: 480)
        let img = NSImage(size: size, flipped: true) { r in
            NSColor.white.setFill(); r.fill()
            NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: r.width, height: 44).fill()
            NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: 16, y: 10, width: r.width - 32, height: 24), xRadius: 12, yRadius: 12).fill()
            NSColor(white: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: 44, width: 124, height: r.height - 44).fill()
            NSColor(white: 0.87, alpha: 1).setFill()
            for (i, w) in [0.8, 0.6, 0.7, 0.5].enumerated() { NSBezierPath(roundedRect: NSRect(x: 14.0, y: 70.0 + Double(i) * 28, width: 96 * w, height: 10), xRadius: 5, yRadius: 5).fill() }
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor(white: 0.4, alpha: 1)]
            let b: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor(white: 0.13, alpha: 1)]
            ("mail.example.com" as NSString).draw(at: NSPoint(x: 32, y: 13), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.35, alpha: 1)])
            ("收件人   许诺" as NSString).draw(at: NSPoint(x: 160, y: 64), withAttributes: a)
            ("主题   Re: 下周的方案评审" as NSString).draw(at: NSPoint(x: 160, y: 102), withAttributes: a)
            ("我看一下再说" as NSString).draw(at: NSPoint(x: 168, y: 160), withAttributes: b)
            ("10月20日 许诺 写道：方案初稿在附件里。" as NSString).draw(at: NSPoint(x: 168, y: 230), withAttributes: a)
            NSColor(red: 0.23, green: 0.44, blue: 0.85, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 160, y: 418, width: 84, height: 36), xRadius: 6, yRadius: 6).fill()
            ("发送" as NSString).draw(at: NSPoint(x: 184, y: 425), withAttributes: [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.white])
            return true
        }
        return LiveDock.Picture(image: img, window: 4242, epoch: 1, visible: [0, 0, 1, 1])
    }
}
