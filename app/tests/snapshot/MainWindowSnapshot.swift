// The main window drawn offscreen, each state to a PNG in light and dark (tests/snapshot.sh builds and runs it): idle,
// running, waiting with a card, answered, the 「过程」 tab. The states come from protocol lines fed to a ShellModel on a
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

    /// A transport with no helper behind it: every write taken, no stream.
    final class Wire: SessionTransport {
        func request(_ body: [String: Any]) -> [String: Any]? { ["ok": true] }
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
            Scene(name: "idle", lines: others + running(), now: t0 + 38, selected: nil),
            Scene(name: "running", lines: others + running(), now: t0 + 38),
            Scene(name: "waiting", lines: others + running() + waiting(), now: t0 + 58),
            Scene(name: "answered", lines: others + running() + waiting() + answered(), now: t0 + 66),
            Scene(name: "process", lines: others + running() + waiting() + answered(), now: t0 + 66, process: true),
        ]
        writeRunFolder(support, run: running() + waiting() + answered())
        for scene in scenes {
            for dark in [false, true] {
                let file = out.appendingPathComponent("\(scene.name)-\(dark ? "dark" : "light").png")
                render(scene, dark: dark, to: file)
                print(file.path)
            }
        }
    }

    // MARK: the states, as the harness would send them

    static func line(_ kind: String, _ seq: Int, _ t: Double, _ f: [String: Any]) -> [String: Any] {
        var l = f
        l["kind"] = kind; l["session_id"] = sid; l["run_id"] = rid; l["seq"] = seq; l["t"] = t0 + t
        return l
    }

    static func otherSessions() -> [[String: Any]] {
        [
            ["kind": "session.message", "session_id": "ses_folder", "seq": 1, "t": t0 - 3600, "msg_id": "m_f1", "role": "user", "text": "整理下载文件夹"],
            ["kind": "session.message", "session_id": "ses_folder", "seq": 2, "t": t0 - 3500, "msg_id": "m_f2", "role": "assistant", "text": "整理好了：按类型分进了 5 个文件夹。"],
            ["kind": "session.message", "session_id": "ses_week", "seq": 1, "t": t0 - 7200, "msg_id": "m_w1", "role": "user", "text": "汇总这周的周报数据"],
            ["kind": "session.message", "session_id": "ses_week", "seq": 2, "t": t0 - 7100, "msg_id": "m_w2", "role": "assistant", "text": "这周一共 12 条记录，已经按项目汇总。"],
        ]
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
            line("resumed", 5, 9, ["ask_id": "ask_plan"]),
            line("step", 6, 12, ["step_id": "st_1", "plan_step": 1, "text": "{\"kind\":\"click\"}", "human": "打开许诺 10 月 20 日的邮件",
                                 "object": "window:com.apple.Safari#4242", "consequence": "read"]),
            line("step_result", 7, 18, ["step_id": "st_1", "status": "ok"]),
            line("step", 8, 22, ["step_id": "st_2", "plan_step": 2, "text": "{\"kind\":\"set_value\"}", "human": "正在输入「我看一下再说」",
                                 "object": "window:com.apple.Safari#4242", "consequence": "modify_user",
                                 "target": ["id": "body", "label": "正文", "role": "textarea", "rect_norm": [0.22, 0.30, 0.74, 0.16]]]),
        ]
    }

    /// Step 2 done; step 3 sends: the action card waits, pinned above the composer.
    static func waiting() -> [[String: Any]] {
        let card: [String: Any] = [
            "kind": "action", "blocking": true, "headline": "要在网页邮箱里点「发送」吗？",
            "text": "要在网页邮箱里点「发送」吗？这会把回复发给许诺。",
            "consent": ["action": "click", "action_text": "点「发送」", "target": "发送", "object": "button:send", "object_label": "发送",
                        "consequence": "external", "site": "mail.example.com",
                        "outgoing": [["kind": "to", "label": "收件人", "value": "许诺 <xu.nuo@example.com>"],
                                     ["kind": "body", "label": "内容", "value": "「我看一下再说」"]]],
            "options": [["kind": "approve", "text": "可以"], ["kind": "skip_step", "text": "这一步不要"], ["kind": "cancel", "text": "先别做了"]],
        ]
        return [
            line("step_result", 9, 40, ["step_id": "st_2", "status": "ok"]),
            line("step", 10, 48, ["step_id": "st_3", "plan_step": 3, "text": "{\"kind\":\"click\"}", "human": "准备点「发送」，等你确认",
                                  "object": "window:com.apple.Safari#4242", "consequence": "external",
                                  "target": ["id": "send", "label": "发送", "role": "button", "rect_norm": [0.22, 0.86, 0.12, 0.08]]]),
            line("ask", 11, 52, ["ask_id": "ask_send", "card": card]),
            line("waiting", 12, 52, ["ask_id": "ask_send"]),
        ]
    }

    /// Answered 「可以」: sent, step 4 under way.
    static func answered() -> [[String: Any]] {
        [
            line("resumed", 13, 60, ["ask_id": "ask_send"]),
            line("step_result", 14, 61, ["step_id": "st_3", "status": "ok"]),
            line("changes", 15, 61, ["created": [], "modified": [], "deleted": [], "external": ["发给许诺的邮件"], "unconfirmed": []]),
            line("step", 16, 63, ["step_id": "st_4", "plan_step": 4, "text": "{\"kind\":\"read\"}", "human": "确认已经发出",
                                  "object": "window:com.apple.Safari#4242", "consequence": "read"]),
        ]
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
        let shell = ShellModel(client: SessionClient(transport: Wire()), defaults: defaults, config: { "openai:local|fake" },
                               lang: { .zhHans }, now: { scene.now }, work: { $0() }, deliver: { $0() })
        for l in scene.lines { shell.client.feed(l) }
        if let s = scene.selected { shell.select(s) }
        if scene.process { shell.pickTab(.process) }
        let size = NSSize(width: 1440, height: 900)
        let root = MainColumns(shell: shell, openSettings: {}, cloud: SidebarCloud(on: true, ready: true, provider: "DeepSeek"),
                               mac: MacFacts(missing: []), still: scene.selected == nil ? nil : still())
            .environment(\.lang, .zhHans)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = host
        w.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))     // (off every screen; never key, never front)
        w.orderFrontRegardless()
        // (the 过程 tab reads its folder off the main queue: let it land)
        RunLoop.main.run(until: Date().addingTimeInterval(scene.process ? 2.0 : 0.8))
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
