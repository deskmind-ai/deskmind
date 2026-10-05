// Unit tests for what needs no screen: the decision panel's reading of a step event, and a recording's file name.
// Built and run by build.sh (a failure stops the build):
//
//   swiftc -parse-as-library Shared/L10n.swift Shared/Decision.swift tests/DecisionTests.swift -o /tmp/t && /tmp/t

import Foundation

@main
enum DecisionTests {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        if !ok { failures += 1; print("FAIL \(line): \(what)") }
    }

    static func main() {
        let decision = #"{"top": [["OPEN", 0.82], ["CLICK", 0.12], ["DONE", 0.03]], "operation": "OPEN", "#
            + #""confidence": 0.82, "routing": {"by": "strong", "reason": "low_conf", "fast_conf": 0.61}}"#
        let step: [String: Any] = ["n": 4, "describe": "double_click #ocr:31", "target": "贝加尔湖畔（Live） · 李健\n原唱",
                                   "latency": 0.654, "detail": "clicked", "decision": decision]

        // A step in Chinese: headline, bars, tier, time.
        let zh = DecisionStep.parse(step, lang: .zhHans)
        check(zh.n == 4, "n")
        check(zh.headline == "打开 · 贝加尔湖畔（Live） · 李健 原唱", "zh headline: \(zh.headline)")
        check(zh.top == [.init(name: "打开", p: 0.82), .init(name: "点击", p: 0.12), .init(name: "完成", p: 0.03)],
              "zh top: \(zh.top)")
        check(zh.tier == "4B · 0.8B 不确定", "zh tier: \(zh.tier)")
        check(zh.ms == 654, "ms: \(zh.ms)")
        check(zh.question.isEmpty && zh.answer.isEmpty, "no question on an ordinary step")

        // The same step in English.
        let en = DecisionStep.parse(step, lang: .en)
        check(en.headline.hasPrefix("Open · "), "en headline: \(en.headline)")
        check(en.tier == "4B · 0.8B unsure", "en tier: \(en.tier)")

        // The fast model; a DONE check.
        let fast = DecisionStep.parse(["n": 5, "decision": #"{"operation": "DONE", "routing": {"by": "fast"}}"#],
                                      lang: .en)
        check(fast.tier == "0.8B" && fast.headline == "Done", "fast: \(fast)")
        let risky = DecisionStep.parse(["decision": #"{"routing": {"by": "strong", "reason": "risky_DONE"}}"#],
                                       lang: .zhHans, previous: 6)
        check(risky.tier == "4B · 完成前复核" && risky.n == 7, "risky: \(risky)")

        // A question and its answer; the dialogue step has no decision record.
        let ask = DecisionStep.parse(["n": 2, "describe": "ask_user",
                                      "detail": "「李娜的那笔订单」在屏幕上不止一处：…。应该用哪一个？ → 用 R-3307 那笔。"],
                                     lang: .zhHans)
        check(ask.headline == "提问", "ask headline: \(ask.headline)")
        check(ask.question.hasSuffix("应该用哪一个？") && ask.answer == "用 R-3307 那笔。", "ask: \(ask)")
        // An arrow in an ordinary step's detail is not a question.
        let arrow = DecisionStep.parse(["describe": "click #x", "detail": "moved a → b"], lang: .en)
        check(arrow.question.isEmpty, "arrow is not a question")

        // Missing or broken records: no crash, empty fields.
        let bare = DecisionStep.parse(["describe": "scroll #icon:scroll_down", "decision": "{not json"], lang: .en)
        check(bare.headline == "Scroll" && bare.top.isEmpty && bare.tier.isEmpty && bare.ms == 0, "bare: \(bare)")
        check(DecisionStep.opName("WHATEVER", .zhHans) == "Whatever", "unknown op")

        // A recording's name: the time, then the instruction's start, nothing a path could trip on.
        var c = DateComponents(); c.year = 2030; c.month = 1; c.day = 2; c.hour = 3; c.minute = 4; c.second = 5
        let date = Calendar(identifier: .gregorian).date(from: c)!
        check(MovieName.file(goal: "打开备忘录，新建一条购物清单", date: date)
              == "2030-01-02 03.04.05 打开备忘录，新建一条购物清单.mov", "movie name")
        let odd = MovieName.file(goal: "a/b:c\nd " + String(repeating: "x", count: 50), date: date)
        check(!odd.contains("/") && !odd.contains(":") && !odd.contains("\n"), "no path characters: \(odd)")
        check(odd.count == "2030-01-02 03.04.05 ".count + 30 + ".mov".count, "30 characters of the goal: \(odd)")
        check(MovieName.file(goal: "  ", date: date) == "2030-01-02 03.04.05.mov", "empty goal")
        check(MovieName.folder(goal: "打开备忘录，新建一条购物清单", date: date) == "2030-01-02 03.04.05 打开备忘录，新建一条购物清单",
              "recording folder")

        // steps.json from a trace: times in ms from the first frame, the target on the screen, the planner's weights.
        let trace = [
            #"{"t": "obs", "ts": 1000.500}"#,
            #"{"t": "step", "n": 1, "action": {"kind": "double_click"}, "target_label": "纸船\n林夏", "#
                + #""target_rect": [110.0, 220.0, 30.0, 40.0], "t_obs_start": 1000.000, "t_decide_start": 1000.600, "#
                + #""t_decide_end": 1001.250, "t_act_start": 1001.300, "t_act_end": 1002.000, "ok": true, "#
                + #""decision": "{\"top\": [[\"OPEN\", 0.9]], \"operation\": \"OPEN\", \"routing\": {\"by\": \"strong\", \"reason\": \"low_conf\"}}"}"#,
            #"{"t": "step", "n": 2, "kind": "done", "t_obs_start": 1003.0, "t_decide_start": 1003.5, "t_decide_end": 1003.8}"#,
            #"{"t": "step", "n": 3, "kind": "ask_user", "question": "Which one?", "reply": "R-3307", "t_obs_start": 1004.0, "#
                + #""t_decide_start": 1004.2, "t_decide_end": 1005.0, "t_reply": 1009.5, "#
                + #""decision": "{\"top\": [[\"ASK\", 0.8]], \"operation\": \"ASK\", \"routing\": {\"by\": \"fast\"}}"}"#,
            "not json",
            #"{"t": "summary", "state": "completed"}"#,
        ].joined(separator: "\n")
        let (rs, state) = RecordingSteps.from(trace: trace, t0: 999.0)
        check(state == "completed" && rs.count == 3, "steps and state: \(rs.count) \(state)")
        let s1 = rs[0]
        check(s1["operation"] as? String == "OPEN" && s1["target"] as? String == "纸船 林夏", "op, target: \(s1)")
        check(s1["t_obs_ms"] as? Int == 1000 && s1["t_seen_ms"] as? Int == 1500 && s1["t_act_end_ms"] as? Int == 3000,
              "times: \(s1)")
        check(s1["wall_ms"] as? Int == 2000 && s1["tier"] as? String == "4B" && s1["reason"] as? String == "low_conf",
              "wall, tier: \(s1)")
        check((s1["target_rect"] as? [Double]) == [110, 220, 30, 40], "rect: \(s1)")
        check(rs[1]["operation"] as? String == "DONE" && rs[1]["wall_ms"] as? Int == 800 && rs[1]["t_act_start_ms"] is NSNull,
              "done step: \(rs[1])")
        // The question: the planner's own decision (0.8B asked), the question and reply, and when the reply came.
        check(rs[2]["question"] as? String == "Which one?" && rs[2]["reply"] as? String == "R-3307"
              && rs[2]["t_reply_ms"] as? Int == 10500 && rs[2]["tier"] as? String == "0.8B", "ask step: \(rs[2])")

        // A recording's size: a Retina screen kept to 1920 on its longer side, or full; small content untouched.
        let retina = RecordingSize.pixels(width: 1728, height: 1117, scale: 2, maxLong: 1920)
        check(retina == (1920, 1240), "retina capped: \(retina)")
        check(RecordingSize.pixels(width: 1728, height: 1117, scale: 2, maxLong: nil) == (3456, 2234), "full")
        let tall = RecordingSize.pixels(width: 800, height: 1600, scale: 2, maxLong: 1920)
        check(tall == (960, 1920), "portrait capped on its height: \(tall)")
        check(RecordingSize.pixels(width: 801, height: 601, scale: 1, maxLong: 1920) == (800, 600), "small: even, not scaled up")

        // The notch: the gap between the menu bar's two areas, as tall as the safe-area inset (a 16" MacBook Pro).
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let notch = Island.notch(screen: screen, safeTop: 32, left: CGRect(x: 0, y: 1085, width: 764, height: 32),
                                 right: CGRect(x: 964, y: 1085, width: 764, height: 32))
        check(notch == CGRect(x: 764, y: 1085, width: 200, height: 32), "notch: \(String(describing: notch))")
        check(Island.notch(screen: screen, safeTop: 0, left: nil, right: nil) == nil, "no notch on an external screen")
        check(Island.notch(screen: screen, safeTop: 32, left: CGRect(x: 0, y: 0, width: 900, height: 32),
                           right: CGRect(x: 800, y: 0, width: 900, height: 32)) == nil, "overlapping areas: no notch")
        if let n = notch {
            let c = Island.collapsedFrame(notch: n)
            check(c.midX == n.midX && c.width == n.width + 2 * Island.wing && c.maxY == screen.maxY, "collapsed: \(c)")
            let e = Island.expandedFrame(notch: n, screen: screen)
            check(e.midX == n.midX && e.maxY == screen.maxY && e.width >= c.width && e.height > c.height, "expanded: \(e)")
        }
        let pill = Island.pillFrame(visible: CGRect(x: 0, y: 0, width: 1920, height: 1050), size: CGSize(width: 560, height: 64))
        check(pill == CGRect(x: 680, y: 976, width: 560, height: 64), "pill: \(pill)")

        // A starting run's stage: the seconds once counting, the usual time when known and not long past.
        check(RunStage.eyes.line(seconds: 0, lang: .en) == "Loading the vision model…", "stage, no seconds")
        check(RunStage.eyes.line(seconds: 12, typical: 20, lang: .en) == "Loading the vision model… 12 s (usually about 20 s)",
              "stage with typical: \(RunStage.eyes.line(seconds: 12, typical: 20, lang: .en))")
        check(RunStage.eyes.line(seconds: 70, typical: 20, lang: .en) == "Loading the vision model… 70 s", "long past the usual")
        check(RunStage.brain.line(seconds: 5, typical: 2, lang: .en) == "Loading the local model… 5 s", "too short to quote")
        // The collapsed wing: the stage in a word and its seconds.
        check(RunStage.eyes.wing(seconds: 12, lang: .en) == "Vision 12s", "wing: \(RunStage.eyes.wing(seconds: 12, lang: .en))")
        check(RunStage.looking.wing(seconds: 0, lang: .zhHans) == "观察屏幕", "wing zh, no seconds")
        check(RunStage.eyes.wing(seconds: 8, lang: .zhHans) == "加载视觉 8 秒", "wing zh: \(RunStage.eyes.wing(seconds: 8, lang: .zhHans))")
        let zhLine = RunStage.brain.line(seconds: 5, typical: 30, lang: .zhHans)
        check(zhLine.hasPrefix("正在载入本地模型") && zhLine.contains("5 秒") && zhLine.contains("30"), "zh stage: \(zhLine)")
        check(RunStage.allCases.allSatisfy { L($0.key, lang: .zhHans) != $0.key }, "every stage has its zh")

        // How a run ended, in the collapsed island: a word for each ending, each with a zh translation.
        let endings: [Island.Ending] = [.done, .failed, .stopped]
        check(Set(endings.map(Island.endWord)).count == 3, "three distinct ending words")
        for e in endings {
            check(L(Island.endWord(e), lang: .zhHans) != Island.endWord(e), "zh for \(Island.endWord(e))")
        }
        check(Island.resultOpenSeconds < Island.resultLingerSeconds, "open, then collapsed, then gone")

        // Which display a recording shows: asked for; else where the task's windows are (a virtual display); else main.
        check(RecordingDisplay.pick(displays: [1, 4], taskArea: [4: 5000], requested: nil, main: 1, wholeScreen: false) == 4,
              "task on the virtual display")
        check(RecordingDisplay.pick(displays: [1, 4], taskArea: [1: 10, 4: 5000], requested: nil, main: 1, wholeScreen: false) == 4,
              "most of the task's windows")
        check(RecordingDisplay.pick(displays: [1, 4], taskArea: [:], requested: nil, main: 1, wholeScreen: false) == 1,
              "no task window yet: main")
        check(RecordingDisplay.pick(displays: [1, 4], taskArea: [4: 5000], requested: 1, main: 1, wholeScreen: false) == 1,
              "requested wins")
        check(RecordingDisplay.pick(displays: [1, 4], taskArea: [4: 5000], requested: 9, main: 1, wholeScreen: false) == 4,
              "a requested display that is gone is ignored")
        check(RecordingDisplay.pick(displays: [1, 4], taskArea: [4: 5000], requested: nil, main: 1, wholeScreen: true) == 1,
              "whole screen: main")
        check(RecordingDisplay.pick(displays: [4], taskArea: [:], requested: nil, main: 1, wholeScreen: false) == 4,
              "main gone: the one there is")
        // Moving the recording: only when the task opened elsewhere and none of it is left where it was.
        check(RecordingDisplay.shouldMove(current: 1, candidate: 4, taskArea: [4: 5000]), "task opened on the virtual display")
        check(!RecordingDisplay.shouldMove(current: 1, candidate: 4, taskArea: [1: 100, 4: 5000]), "part still here: stay")
        check(!RecordingDisplay.shouldMove(current: 4, candidate: 4, taskArea: [4: 5000]), "same display")
        check(!RecordingDisplay.shouldMove(current: 1, candidate: 4, taskArea: [:]), "no task window anywhere")

        // Naming an app (AppScope, via AppMention): the English goals that ran in Finder on 09-30, and what is not one.
        func names(_ goal: String, _ app: String = "textedit") -> Bool {
            AppMention.range(of: app, isAlias: false, in: goal.lowercased(), original: goal) != nil
        }
        check(names("Find Lisa Wong's order in records.txt and add it to ledger.csv, then save ledger.csv. Both files "
                    + "are in the attached folder; open them in TextEdit."), "a sentence-final full stop")
        check(names("TextEdit has records.txt and ledger.csv open. Add Lisa Wong's order to ledger.csv."), "X has …")
        check(names("Safari shows a parts table. Copy it into parts.csv.", "safari"), "X shows …")
        check(names("In TextEdit, records.txt and ledger.csv are open."), "in X (as before)")
        check(names("TextEdit 里打开着 records.txt", "textedit"), "X 里 (as before)")
        check(!names("rename notes.txt to done.txt", "notes"), "a file name is not the app")
        check(!names("the file notes has 3 lines, copy them", "notes"), "a lowercase word before has is not the app")
        check(!names("open textedit.app.bak in Finder", "textedit"), "an extension after the name")
        check(names("Open NetEase Cloud Music and play it.", "netease cloud music"), "open X")

        // The routing threshold: the override, then the manifest, then 0.94; nonsense ignored.
        check(RoutingThreshold.pick(override: "0.96", manifest: 0.95) == 0.96, "override wins")
        check(RoutingThreshold.pick(override: nil, manifest: 0.96) == 0.96, "manifest")
        check(RoutingThreshold.pick(override: nil, manifest: nil) == 0.94, "default")
        check(RoutingThreshold.pick(override: "high", manifest: 1.5) == 0.94, "nonsense ignored")
        check(RoutingThreshold.pick(override: nil, model: 0.96, manifest: 0.95) == 0.96, "the model's own over the manifest")
        check(RoutingThreshold.pick(override: "0.97", model: 0.96, manifest: nil) == 0.97, "override over the model's")
        check(RoutingThreshold.fromModelConfig(Data(#"{"format":"x","router_threshold":0.96}"#.utf8)) == 0.96, "read from deskmind.json")
        check(RoutingThreshold.fromModelConfig(Data(#"{"format":"x"}"#.utf8)) == nil, "absent in deskmind.json")
        check(FileMention.named(in: "Find Lisa Wong's order in records.txt and add it to ledger.csv, then save ledger.csv.")
              == ["records.txt", "ledger.csv"], "files named")
        check(FileMention.named(in: "把 报销单.xlsx 里的金额改成 3.5") == ["报销单.xlsx"], "a Chinese file name")
        check(FileMention.named(in: "Open https://example.com, read v0.1 notes in 3.5 s; open TextEdit.app").isEmpty,
              "addresses, versions, numbers and apps are not files")
        check(DownloadSource.url(primary: "hf", mirror: "ms", usingMirror: false) == "hf", "Hugging Face first")
        check(DownloadSource.url(primary: "hf", mirror: "ms", usingMirror: true) == "ms", "the mirror once switched")
        check(DownloadSource.url(primary: "hf", mirror: nil, usingMirror: true) == "hf", "no mirror: Hugging Face")
        check(DownloadSource.shouldSwitch(hasMirror: true, usingMirror: false), "a failure on Hugging Face switches")
        check(!DownloadSource.shouldSwitch(hasMirror: true, usingMirror: true), "a failure on the mirror is a failure")
        check(!DownloadSource.shouldSwitch(hasMirror: false, usingMirror: false), "no mirror, no switch")
        check(DownloadSource.stalled(elapsed: 30, bytes: 1_000_000, fileSize: 5_000_000_000), "a trickle is a stall")
        check(!DownloadSource.stalled(elapsed: 30, bytes: 20_000_000, fileSize: 5_000_000_000), "6 MB in 30 s is not")
        check(!DownloadSource.stalled(elapsed: 30, bytes: 4_000, fileSize: 4_000), "a small file done is not")
        check(!DownloadSource.stalled(elapsed: 10, bytes: 0, fileSize: 5_000_000_000), "too early to tell")

        liveViewTests()
        issueReportTests()
        setupStepsTests()
        exportNameTests()
        xiaoFangMotionTests()
        askFlowTests()
        replayPlanTests()
        markPathTests()
        questionGateTests()
        runErrorTests()
        fileExampleTests()
        selfTestTests()
        notInstalledTests()
        folderPolicyTests()
        diagnosticsTests()
        recordingCaptureTests()
        // An app running with no window gets it back; document-based apps (an Open panel on reopen) and Finder don't.
        check(AppWindow.shouldReopen(bundle: "com.netease.163music", running: true, ordinaryWindows: 0, documentBased: false), "a music app with its window closed")
        check(!AppWindow.shouldReopen(bundle: "com.netease.163music", running: true, ordinaryWindows: 1, documentBased: false), "it has a window")
        check(!AppWindow.shouldReopen(bundle: "com.netease.163music", running: false, ordinaryWindows: 0, documentBased: false), "not running: hands launches it")
        check(!AppWindow.shouldReopen(bundle: "com.apple.TextEdit", running: true, ordinaryWindows: 0, documentBased: false), "TextEdit, listed")
        check(!AppWindow.shouldReopen(bundle: "com.apple.Preview", running: true, ordinaryWindows: 0, documentBased: false), "Preview, listed")
        check(!AppWindow.shouldReopen(bundle: "com.apple.finder", running: true, ordinaryWindows: 0, documentBased: false), "Finder: hands opens the folder")
        check(!AppWindow.shouldReopen(bundle: "com.example.editor", running: true, ordinaryWindows: 0, documentBased: true), "any document-based app")
        check(AppWindow.documentBased(info: ["CFBundleDocumentTypes": [["CFBundleTypeName": "Image"], ["NSDocumentClass": "PVDocument"]]]), "an NSDocumentClass")
        check(!AppWindow.documentBased(info: ["CFBundleDocumentTypes": [["CFBundleTypeName": "MP3", "LSHandlerRank": "Owner"]]]), "types without a document class")
        check(!AppWindow.documentBased(info: nil) && !AppWindow.documentBased(info: [:]), "no Info.plist, no types")
        check(AppWindow.shouldLaunch(bundle: "com.netease.163music", running: false), "not running: launched first")
        check(AppWindow.shouldLaunch(bundle: "com.apple.Safari", running: false), "Safari too (it opens its start page)")
        check(!AppWindow.shouldLaunch(bundle: "com.netease.163music", running: true), "running: no launch")
        check(!AppWindow.shouldLaunch(bundle: "com.apple.TextEdit", running: false) && !AppWindow.shouldLaunch(bundle: "com.apple.finder", running: false),
              "TextEdit and Finder: hands opens their documents and folders")

        print(failures == 0 ? "DecisionTests: all passed" : "DecisionTests: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// The live view (Shared/LiveView.swift): which window, the card's size and corner, the cursor, the capture.
    static func liveViewTests() {
        typealias LV = LiveView
        // What the picture leaves out: other apps, and the same app's other documents; not the target's own sheet or menus.
        let target = LV.Shown(id: 1, pid: 50, layer: 0, title: "records.txt", frame: CGRect(x: 100, y: 100, width: 600, height: 400))
        let others: [LV.Shown] = [
            target,
            LV.Shown(id: 2, pid: 50, layer: 0, title: "secret.rtf", frame: CGRect(x: 150, y: 150, width: 300, height: 200)),
            LV.Shown(id: 3, pid: 50, layer: 0, title: "", frame: CGRect(x: 200, y: 128, width: 400, height: 220)),
            LV.Shown(id: 4, pid: 50, layer: 101, title: "", frame: CGRect(x: 120, y: 90, width: 180, height: 300)),
            LV.Shown(id: 5, pid: 50, layer: 0, title: "", frame: CGRect(x: 650, y: 150, width: 300, height: 200)),
            LV.Shown(id: 6, pid: 77, layer: 0, title: "Mail", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
            LV.Shown(id: 7, pid: nil, layer: 25, title: "", frame: CGRect(x: 0, y: 0, width: 1728, height: 33)),
        ]
        let out = Set(LV.leaveOut(others, target: target))
        check(!out.contains(1), "never the target itself")
        check(out.contains(2), "another document of the same app on top: left out")
        check(!out.contains(3), "its sheet (untitled, within it): kept")
        check(!out.contains(4), "its menu or popover (above the normal level): kept")
        check(out.contains(5), "an untitled same-app window reaching outside it: left out")
        check(out.contains(6) && out.contains(7), "other apps, and windows with no app: left out")
        // Why a run didn't finish, from hands' summary.
        check(LV.endingNote(state: "completed", failure: "") == nil, "finished: no reason")
        check(LV.endingNote(state: "cancelled", failure: "") == nil, "stopped: no reason")
        check(LV.endingNote(state: "budget_exhausted", failure: "")?.contains("steps") == true, "out of steps")
        check(LV.endingNote(state: "errored", failure: "no_progress_loop")?.hasPrefix("Got stuck") == true, "stuck")
        check(LV.endingNote(state: "errored", failure: "crash") == "It stopped on an error", "an error")
        check(LV.endingNote(state: "gave_up", failure: "") != nil, "gave up")
        check(LV.endingNote(state: "", failure: "") == nil, "no summary: nothing more than Didn't finish")
        for k in ["gave_up", "budget_exhausted", "errored"] {
            if let key = LV.endingNote(state: k, failure: k == "errored" ? "no_progress_loop" : "") {
                check(L(key, lang: .zhHans) != key, "zh for \(key)")
            }
        }
        check(L("Double-click to enlarge · drag to a corner", lang: .zhHans) != "Double-click to enlarge · drag to a corner", "zh hint")
        // The window hands observes.
        check(LV.activeWindowID([["id": "812", "title": "a"], ["id": "77", "active": true]]) == 77, "the active window, a string id")
        check(LV.activeWindowID([["id": 9, "active": true]]) == 9, "an int id")
        check(LV.activeWindowID([["id": "x", "active": true], ["id": "3"]]) == nil, "no usable active id")
        check(LV.activeWindowID([["id": "3", "active": false]]) == nil, "none active")
        check(LV.activeWindowID([]) == nil, "no windows")

        // Which window to show.
        func w(_ id: Int, _ app: String, _ bundle: String, layer: Int = 0, on: Bool = true, _ wd: CGFloat, _ ht: CGFloat) -> LV.Candidate {
            LV.Candidate(id: id, appName: app, bundle: bundle, layer: layer, onScreen: on, frame: CGRect(x: 0, y: 0, width: wd, height: ht))
        }
        let te = "com.apple.TextEdit"
        let wins = [w(1, "TextEdit", te, 400, 300), w(2, "TextEdit", te, 800, 600), w(3, "Safari", "com.apple.Safari", 1200, 800),
                    w(4, "TextEdit", te, on: false, 900, 900), w(5, "TextEdit", te, layer: 3, 990, 990),
                    w(6, "TextEdit", te, 60, 40)]
        check(LV.pick(wins, active: 1, app: "TextEdit", bundles: []) == 1, "the observed window first")
        check(LV.pick(wins, active: 3, app: "TextEdit", bundles: []) == 3, "the observed window even in another app")
        check(LV.pick(wins, active: 4, app: "TextEdit", bundles: [te]) == nil,
              "observed but off screen (minimized, another Space): none, never another window of the app")
        check(LV.pick(wins, active: 99, app: "TextEdit", bundles: [te]) == nil, "observed but gone (closed): none")
        check(LV.pick(wins, active: nil, app: "TextEdit (no window open)", bundles: []) == 2, "the app's name before the note")
        check(LV.pick(wins, active: nil, app: "textedit", bundles: []) == 2, "names compared without case")
        check(LV.pick(wins, active: nil, app: "", bundles: ["com.apple.safari"]) == 3, "no observation yet: the task's apps")
        check(LV.pick(wins, active: nil, app: "", bundles: [te, "com.apple.Safari"]) == 3, "the largest of the task's apps")
        check(LV.pick(wins, active: nil, app: "Music", bundles: []) == nil, "nothing to show")
        check(LV.pick(wins, active: nil, app: "文本编辑", bundles: [te]) == 2, "another language's name: by bundle")
        check(LV.pick([w(6, "TextEdit", te, 60, 40)], active: nil, app: "TextEdit", bundles: []) == nil, "a sliver is not a window to show")
        check(LV.pick([w(5, "TextEdit", te, layer: 3, 990, 990)], active: nil, app: "TextEdit", bundles: [te]) == nil,
              "a floating panel or menu is not the window")
        check(LV.pick([], active: 1, app: "TextEdit", bundles: [te]) == nil, "no windows at all")
        check(LV.pick([], active: nil, app: "", bundles: []) == nil, "nothing known")
        check(LV.pick(wins, active: nil, app: "TextEdit", bundles: [te], observed: false) == nil,
              "before hands has looked: nothing, not a guess that could be the user's own window")
        check(LV.pick(wins, active: 1, app: "", bundles: [], observed: false) == 1, "a window hands named is shown at once")

        // The picture and the card.
        check(LV.pictureSize(window: CGSize(width: 1200, height: 800)) == CGSize(width: 360, height: 240), "wide fits the width")
        check(LV.pictureSize(window: CGSize(width: 1200, height: 800), box: LV.maxPictureLarge) == CGSize(width: 720, height: 480), "larger")
        check(LV.pictureSize(window: CGSize(width: 600, height: 1200)) == CGSize(width: 220, height: 240),
              "tall fits the height, the card not narrower than its header")
        check(LV.pictureSize(window: CGSize(width: 300, height: 100)) == CGSize(width: 300, height: 100), "never enlarged")
        check(LV.pictureSize(window: .zero) == CGSize(width: 360, height: 225), "no window yet: a placeholder shape")
        check(LV.cardSize(picture: CGSize(width: 360, height: 240)) == CGSize(width: 360, height: 240 + LV.headerHeight + LV.lineHeight),
              "header + picture + line")

        // Corners.
        let vis = CGRect(x: 0, y: 80, width: 1512, height: 870)   // above a Dock, below the menu bar
        let size = CGSize(width: 360, height: 302)
        check(LV.frame(size: size, corner: .bottomRight, visible: vis) == CGRect(x: 1512 - 16 - 360, y: 96, width: 360, height: 302), "bottom-right")
        check(LV.frame(size: size, corner: .topLeft, visible: vis) == CGRect(x: 16, y: 80 + 870 - 16 - 302, width: 360, height: 302), "top-left")
        check(LV.nearestCorner(center: CGPoint(x: 1400, y: 900), visible: vis) == .topRight, "dropped top-right")
        check(LV.nearestCorner(center: CGPoint(x: 100, y: 100), visible: vis) == .bottomLeft, "dropped bottom-left")
        check(LV.nearestCorner(center: CGPoint(x: 756, y: 515), visible: vis) == .topRight, "the exact middle goes up and right")
        check(Set([LV.Corner.bottomRight] + LV.neighbours(.bottomRight)) == Set(LV.Corner.allCases), "every corner is tried")
        for c in LV.Corner.allCases { check(!LV.neighbours(c).contains(c) && LV.neighbours(c).count == 3, "neighbours of \(c)") }

        // Out of the window's way.
        check(LV.place(size: size, preferred: .bottomRight, visible: vis, avoid: nil) == (.bottomRight, false), "nothing to avoid")
        let leftHalf = CGRect(x: 0, y: 80, width: 700, height: 870)
        check(LV.place(size: size, preferred: .bottomLeft, visible: vis, avoid: leftHalf) == (.bottomRight, false),
              "a window on the left: across the bottom edge")
        let bottomHalf = CGRect(x: 0, y: 80, width: 1512, height: 400)
        check(LV.place(size: size, preferred: .bottomRight, visible: vis, avoid: bottomHalf) == (.topRight, false),
              "a window along the bottom: up the same side")
        let full = CGRect(x: 0, y: 0, width: 1512, height: 982)
        check(LV.place(size: size, preferred: .topLeft, visible: vis, avoid: full) == (.topLeft, true),
              "a window filling the screen: the user's corner, letting clicks through")
        check(LV.place(size: size, preferred: .bottomRight, visible: vis, avoid: .zero) == (.bottomRight, false), "an empty rect is nothing")
        // A full-screen window: the corner farthest from where the run has acted, else the user's.
        check(LV.place(size: size, preferred: .bottomRight, visible: vis, avoid: full, recent: [CGPoint(x: 1400, y: 150)]) == (.topLeft, true),
              "acting near the bottom-right: the card goes top-left")
        check(LV.place(size: size, preferred: .bottomRight, visible: vis, avoid: full, recent: [CGPoint(x: 700, y: 900)]).corner == .bottomRight,
              "acting at the top middle: the bottom corners are as far, the user's stays")
        check(LV.place(size: size, preferred: .topLeft, visible: vis, avoid: full, recent: [CGPoint(x: 100, y: 900), CGPoint(x: 120, y: 880)]).corner == .bottomRight,
              "acting near the top-left: the opposite corner")
        // Clicks: through the card over the window, unless the pointer rests on it.
        check(LV.interactive(covers: false, pointerOnCardFor: nil), "clear of the window: clickable")
        check(!LV.interactive(covers: true, pointerOnCardFor: nil), "over the window: clicks pass through")
        check(!LV.interactive(covers: true, pointerOnCardFor: 0.05), "a pointer passing over (a run's click is instant): still through")
        check(LV.interactive(covers: true, pointerOnCardFor: 0.6), "resting on it: clickable")

        // Coordinates: top-left global (ScreenCaptureKit, hands) to AppKit.
        check(LV.toAppKit(CGRect(x: 10, y: 20, width: 100, height: 50), mainHeight: 982) == CGRect(x: 10, y: 912, width: 100, height: 50), "flipped")
        check(LV.toAppKit(CGRect(x: 1600, y: -100, width: 100, height: 50), mainHeight: 982) == CGRect(x: 1600, y: 1032, width: 100, height: 50),
              "a display above the main one")

        // The agent's cursor in the picture.
        let win = CGRect(x: 100, y: 200, width: 800, height: 600)
        check(LV.cursor(at: CGPoint(x: 500, y: 500), window: win, picture: CGSize(width: 400, height: 300)) == CGPoint(x: 200, y: 150), "the middle")
        check(LV.cursor(at: CGPoint(x: 100, y: 200), window: win, picture: CGSize(width: 400, height: 300)) == CGPoint(x: 0, y: 300),
              "the window's top-left is the picture's top-left (a layer counts y up)")
        check(LV.cursor(at: CGPoint(x: 50, y: 500), window: win, picture: CGSize(width: 400, height: 300)) == nil, "outside the window: no cursor")
        check(LV.cursor(at: CGPoint(x: 1, y: 1), window: .zero, picture: CGSize(width: 400, height: 300)) == nil, "no window")
        check(LV.targetCenter([100, 200, 40, 20]) == CGPoint(x: 120, y: 210), "a target_rect's centre")
        check(LV.targetCenter([100.5, 200, 41, 20.0] as [Any]) == CGPoint(x: 121, y: 210), "floats")
        check(LV.targetCenter(nil) == nil && LV.targetCenter([1, 2, 3]) == nil && LV.targetCenter("x") == nil, "no target")
        check(LV.targetCenter([1, 2, -3, 4]) == nil, "a negative size is nonsense")

        // The capture.
        check(LV.capturePixels(picture: CGSize(width: 360, height: 240), window: CGSize(width: 1200, height: 800), scale: 2) == (720, 480), "twice the card")
        check(LV.capturePixels(picture: CGSize(width: 201, height: 101), window: CGSize(width: 201, height: 101), scale: 1) == (200, 100),
              "the window's own pixels, even")
        check(LV.capturePixels(picture: CGSize(width: 1, height: 1), window: CGSize(width: 1, height: 1), scale: 1) == (2, 2), "never empty")
        check(LV.sourceRect(window: CGRect(x: 1600, y: 100, width: 400, height: 300), display: CGRect(x: 1512, y: 0, width: 1920, height: 1080))
              == CGRect(x: 88, y: 100, width: 400, height: 300), "in the display's coordinates")
        check(LV.sourceRect(window: CGRect(x: -100, y: 0, width: 400, height: 300), display: CGRect(x: 0, y: 0, width: 1512, height: 982))
              == CGRect(x: 0, y: 0, width: 300, height: 300), "clipped to the display")
        check(LV.sourceRect(window: CGRect(x: 5000, y: 0, width: 10, height: 10), display: CGRect(x: 0, y: 0, width: 1512, height: 982)) == .zero,
              "off the display")

        // 小方's face in the title bar.
        check(LV.face(.working) == .look && LV.face(.starting) == .look, "at work: looking at the cursor")
        check(LV.face(.waitingForUser) == .up, "needs you: eyes up")
        check(LV.face(.done) == .happy, "done: ^ ^")
        check([LV.Status.paused, .hidden, .failed, .stopped].allSatisfy { LV.face($0) == .flat }, "paused, hidden, unfinished, stopped: – –")
        check(LV.gaze(cursor: nil, picture: CGSize(width: 360, height: 240)) == CGPoint(x: 0, y: 0.6), "no cursor: ahead, a little down")
        check(LV.gaze(cursor: CGPoint(x: 0, y: 0), picture: CGSize(width: 360, height: 240)) == CGPoint(x: -1.2, y: 1.2), "bottom-left: left and down")
        check(LV.gaze(cursor: CGPoint(x: 360, y: 240), picture: CGSize(width: 360, height: 240)) == CGPoint(x: 1.2, y: 0.4), "top-right: right, barely down")
        check(LV.gaze(cursor: CGPoint(x: 900, y: -50), picture: CGSize(width: 360, height: 240)).x == 1.2, "clamped to the picture")
        check(LV.gaze(cursor: CGPoint(x: 10, y: 10), picture: .zero) == CGPoint(x: 0, y: 0.6), "no picture yet")

        // A question in the card.
        check(LV.askKind(options: ["a", "b"], approval: false) == .choose, "options: pick one")
        check(LV.askKind(options: [], approval: true) == .approve && LV.askKind(options: ["x"], approval: true) == .approve, "an approval")
        check(LV.askKind(options: ["  ", ""], approval: false) == .free, "no usable options: it needs typing")
        check(LV.askOptions([" 2026-09-05 ", "2026-09-05", "b", "", "c", "d", "e"]) == ["2026-09-05", "b", "c", "d"], "trimmed, deduplicated, four at most")

        // Statuses.
        check([LV.Status.done, .failed, .stopped].allSatisfy(\.isEnding), "endings")
        check(![LV.Status.starting, .working, .waitingForUser, .paused, .hidden].contains(where: \.isEnding), "not endings")
        let allStatuses: [LV.Status] = [.starting, .working, .waitingForUser, .paused, .hidden, .done, .failed, .stopped]
        for st in allStatuses {
            check(L(LV.word(st), lang: .zhHans) != LV.word(st), "a Chinese word for \(LV.word(st))")
        }
    }


    /// A report as a GitHub issue (Shared/IssueReport.swift): what goes in, and that a long run still fits a URL.
    /// The first setup's three steps (Shared/SetupSteps.swift).
    static func setupStepsTests() {
        typealias S = SetupSteps
        // Step 1: the helper and each required permission.
        check(S.grants(helperReady: false, required: [false, false]) == (0, 3), "nothing yet: 0/3")
        check(S.grants(helperReady: true, required: [true, false]) == (2, 3), "helper + one: 2/3")
        check(S.grants(helperReady: true, required: [true, true]) == (3, 3), "all: 3/3")
        check(S.grants(helperReady: false, required: [true, true]) == (2, 3), "permissions without the helper: not done")
        // Step 2 follows the real state; it never says the download runs when it waits for a click.
        for lang in [ResolvedLang.en, .zhHans] {
            check(S.download(brain: "ready", transfer: .idle, lang: lang) == L("Ready", lang: lang), "ready (\(lang))")
            check(S.download(brain: "ready", transfer: .downloading(done: 1, total: 2), lang: lang) == L("Ready", lang: lang),
                  "ready wins over a stale transfer (\(lang))")
            let idle = S.download(brain: "missing", transfer: .idle, lang: lang)
            check(idle == L("about 5.3 GB — press Download", lang: lang), "missing and idle: asks for Download (\(lang)): \(idle)")
            check(S.download(brain: "missing", transfer: .paused, lang: lang) == L("paused", lang: lang), "paused (\(lang))")
            check(S.download(brain: "missing", transfer: .failed, lang: lang) == L("didn't finish — try again below", lang: lang), "failed (\(lang))")
            check(S.download(brain: "missing", transfer: .verifying, lang: lang) == L("checking the files", lang: lang), "verifying (\(lang))")
            check(S.download(brain: "loading", transfer: .done, lang: lang) == L("loading", lang: lang), "downloaded, loading (\(lang))")
            check(S.download(brain: "stopped", transfer: .idle, lang: lang).isEmpty, "the helper not up: nothing claimed (\(lang))")
            let unlocked = S.firstTask(unlocked: true, lang: lang), locked = S.firstTask(unlocked: false, lang: lang)
            check(unlocked.progress == L("Ready", lang: lang) && locked.progress == L("unlocks when 1 and 2 are done", lang: lang),
                  "step 3 locked until 1 and 2 (\(lang))")
            check(unlocked.hint != locked.hint && !unlocked.hint.isEmpty, "step 3's line says what to do (\(lang))")
        }
        check(S.download(brain: "missing", transfer: .downloading(done: 1_250_000_000, total: 5_300_000_000), lang: .en) == "1.2 / 5.3 GB"
              || S.download(brain: "missing", transfer: .downloading(done: 1_250_000_000, total: 5_300_000_000), lang: .en) == "1.3 / 5.3 GB",
              "downloading: GB so far")
        // Every key the setup shows has its Chinese.
        for key in ["Allow DeskMind to work this Mac", "Download the local models", "Try your first task",
                    "about 5.3 GB — press Download", "paused", "checking the files", "didn't finish — try again below", "loading",
                    "unlocks when 1 and 2 are done", "Pick one of the examples above, or type your own.",
                    "The examples above start working as soon as the first two steps are done.",
                    "Most of the first setup is the model download: start it first, and allow the permissions while it runs.", "Making the GIF…",
                    "Answer it in the card in the corner of the screen."] {
            check(L(key, lang: .zhHans) != key, "zh for “\(key)”")
        }
    }

    /// Export file names (Shared/ExportName.swift): never over a file already there.
    static func exportNameTests() {
        let dir = URL(fileURLWithPath: "/x/DeskMind")
        check(ExportName.title("a/b:c") == "a b c", "no / or : in the name")
        check(ExportName.title("Open Music / play: the live\nversion") == "Open Music play the live version", "single spaces, one line")
        check(ExportName.title(String(repeating: "长", count: 60)).count == 40, "40 characters at most")
        let free = ExportName.unique(dir: dir, stamp: "10-4-26 14.05", title: "Open Music", ext: "gif", exists: { _ in false })
        check(free.lastPathComponent == "10-4-26 14.05 Open Music.gif", "free: \(free.lastPathComponent)")
        var taken: Set<String> = ["10-4-26 14.05 Open Music.gif"]
        let second = ExportName.unique(dir: dir, stamp: "10-4-26 14.05", title: "Open Music", ext: "gif",
                                       exists: { taken.contains($0.lastPathComponent) })
        check(second.lastPathComponent == "10-4-26 14.05 Open Music 2.gif", "same minute, same task: “ 2” (\(second.lastPathComponent))")
        taken.insert(second.lastPathComponent)
        let third = ExportName.unique(dir: dir, stamp: "10-4-26 14.05", title: "Open Music", ext: "gif",
                                      exists: { taken.contains($0.lastPathComponent) })
        check(third.lastPathComponent == "10-4-26 14.05 Open Music 3.gif", "and “ 3”")
        check(third.deletingLastPathComponent().path == dir.path, "in the folder asked for")
        let untitled = ExportName.unique(dir: dir, stamp: "10-4-26 14.05", title: " / ", ext: "gif", exists: { _ in false })
        check(untitled.lastPathComponent == "10-4-26 14.05.gif", "no title: the stamp alone, no trailing space")
    }

    /// 小方 listening (Shared/XiaoFangMotion.swift).
    static func xiaoFangMotionTests() {
        typealias X = XiaoFangMotion
        check(X.rise(understood: false, dozing: true) == 46, "dozing: only the head shows")
        check(X.rise(understood: false, dozing: false) == 18, "typing: head up on the edge")
        check(X.rise(understood: true, dozing: true) == 0 && X.rise(understood: true, dozing: false) == 0, "understood: standing")
        check(X.gaze(dozing: true, understood: true, unsure: true, characters: 9) == .zero, "dozing: eyes closed, straight")
        check(X.gaze(dozing: false, understood: true, unsure: true, characters: 9).height == 7, "understood: down at the line below")
        check(X.gaze(dozing: false, understood: false, unsure: true, characters: 9).width < 0, "unsure: toward Attach folder")
        let start = X.gaze(dozing: false, understood: false, unsure: false, characters: 0)
        let end = X.gaze(dozing: false, understood: false, unsure: false, characters: 200)
        check(start.width == -5 && end.width == 5 && X.gaze(dozing: false, understood: false, unsure: false, characters: 14).width == 0,
              "eyes follow the sentence, left to right, then stay")
        check(X.sway.count == 4 && X.sway.last?.angle == 0 && X.sway.map(\.angle).map(abs).max() == 3, "one ±3° sway, back to upright")
        check(abs(X.sway.map(\.seconds).reduce(0, +) - 0.64) < 0.001, "the sway takes 640 ms (the design's spec)")
        check(X.blinkAfter == 1.2 && X.dozeAfter == 8, "blink after 1.2 s, doze after 8 s")
        check(X.typed(old: "Ope", new: "Open"), "a key: typing")
        check(X.typed(old: "Open", new: "Ope"), "a delete: typing")
        check(X.typed(old: "你", new: "你好"), "an input-method word: typing")
        check(X.typed(old: "", new: "我想打开网易"), "拼音 committing six characters at once: typing")
        check(X.typed(old: "打开", new: "打开网易云音乐播放"), "seven more: typing")
        check(!X.typed(old: "", new: "Open NetEase Cloud Music and play it"), "an example put in: not typing (no sway)")
        check(!X.typed(old: "Open NetEase Cloud Music", new: ""), "cleared after Start: not typing")
        // The dot: 156, 155 of the 200-wide mark, scaled by the drawn width.
        let d = X.dot(in: CGRect(x: 100, y: 40, width: 76, height: 82))
        check(abs(d.x - (100 + 156 * 0.38)) < 0.001 && abs(d.y - (40 + 155 * 0.38)) < 0.001, "the dot's centre: \(d)")
        // SwiftUI global (the window's, top-left) to window base (bottom-left): only y flips, x stays.
        let b = X.windowBase(CGPoint(x: 50, y: 132), contentHeight: 300)
        check(b == CGPoint(x: 50, y: 168), "window base: \(b)")
    }

    /// What the window and the island do when the run asks and is answered (Shared/AskFlow.swift).
    static func askFlowTests() {
        typealias A = AskFlow
        let card = A.asked(inCard: true, approval: false, appActive: false, userTyping: true)
        check(card.needsYou == true && !card.comeBack && !card.notify && card.remind, "in the card: needs you, window stays, a reminder later")
        check(card.say == "Needs you — answer in the card", "the island says where to answer")
        let away = A.asked(inCard: false, approval: false, appActive: false, userTyping: false)
        check(away.comeBack && away.activate && away.notify && !away.remind, "in the window, DeskMind behind: it comes back active, a notification")
        let typing = A.asked(inCard: false, approval: true, appActive: true, userTyping: true)
        check(typing.comeBack && !typing.activate && typing.notify, "the user typing elsewhere: back, not key (their keys stay theirs)")
        check(typing.say == "Waiting for your approval in DeskMind", "an approval says so")
        let front = A.asked(inCard: false, approval: false, appActive: true, userTyping: false)
        check(front.activate && !front.notify && front.say == "Waiting for your answer in DeskMind", "DeskMind in front: no notification")
        for (name, fx) in [("answered in the window", A.answeredInWindow), ("answered in the card", A.answeredInCard), ("a step", A.stepped)] {
            check(fx.needsYou == false && fx.cancelReminder, "\(name): needs-you off, the reminder cancelled")
        }
        check(A.answeredInWindow.say == "Got your answer. Carrying on…" && A.answeredInCard.say == "Answered — carrying on", "each answer says so")
        check(A.typeInWindow.comeBack && A.typeInWindow.activate && A.typeInWindow.needsYou == nil && A.typeInWindow.cancelReminder,
              "Neither — let me type it: the window, active; still waiting, no reminder to answer in the card")
        check(A.answerApplies(answered: 3, waiting: 3), "an answer to the question waiting: applies")
        check(!A.answerApplies(answered: 3, waiting: 4), "a late answer to the previous question: the newer one stays")
        check(A.answerApplies(answered: nil, waiting: 4) && A.answerApplies(answered: 3, waiting: nil), "no id to compare: applies")
        check(A.reminderAfter == 20, "the reminder after 20 s")
        for key in [card.say, away.say, typing.say, front.say, A.answeredInWindow.say, A.answeredInCard.say].compactMap({ $0 }) {
            check(L(key, lang: .zhHans) != key, "zh for “\(key)”")
        }
    }

    /// Which steps a replay and its GIF show (Shared/ReplayPlan.swift).
    static func replayPlanTests() {
        let steps = (1...20).map { (n: $0, shot: $0 == 3 ? "" : "/shots/\($0).png", words: "step \($0)") }
        let gone: Set<String> = ["/shots/5.png"]
        let frames = ReplayPlan.frames(steps, exists: { !gone.contains($0) })
        check(frames.count == 18 && !frames.contains { $0.n == 3 || $0.n == 5 }, "no screenshot, or deleted: left out (\(frames.count))")
        check(frames.map(\.n) == frames.map(\.n).sorted() && frames.first?.words == "step 1", "in order, with their words")
        let gif = ReplayPlan.gifFrames(frames)
        check(gif.count == 16 && gif.first?.n == 4 && gif.last?.n == 20, "the GIF: the last 16 steps")
        check(ReplayPlan.gifFrames(Array(frames.prefix(4))).count == 4, "fewer than 16: all of them")
        check(ReplayPlan.frames(steps, exists: { _ in false }).isEmpty, "\"Clear all\": nothing to replay (no buttons)")
        check(ReplayPlan.playFrom(index: 17, count: 18) == 0, "Play at the last step: from the first")
        check(ReplayPlan.playFrom(index: 5, count: 18) == 5, "Play mid-way: from where it is")
        check(ReplayPlan.playFrom(index: 0, count: 1) == 0, "one frame")
    }

    /// The brand mark's path commands (Shared/MarkPath.swift).
    static func markPathTests() {
        check(MarkPath.cgPath("M0 0H10V5H0Z").boundingBoxOfPath == CGRect(x: 0, y: 0, width: 10, height: 5), "M, H, V, Z: a 10 × 5 box")
        let q = MarkPath.cgPath("M0 0Q10 10 20 0").boundingBoxOfPath
        check(abs(q.width - 20) < 0.01 && abs(q.height - 5) < 0.01, "Q: a quadratic curve peaks halfway (\(q))")
        let head = MarkPath.cgPath("M45 28H153Q166 28 166 41V127H147V65H53V104H34V41Q34 28 45 28Z").boundingBoxOfPath
        check(head == CGRect(x: 34, y: 28, width: 132, height: 99), "小方's frame: 34…166 × 28…127 (\(head))")
        check(MarkPath.cgPath("M1,2 H3").currentPoint == CGPoint(x: 3, y: 2), "commas as separators")
        check(MarkPath.cgPath("").isEmpty, "empty")
    }

    /// The order of a run's questions and steps (Shared/QuestionGate.swift).
    static func questionGateTests() {
        let gate = QuestionGate()
        var trace = ["step 1"], read = 0, log: [String] = []
        func poll() { while read < trace.count { log.append(trace[read]); read += 1 } }
        gate.cycle(timeout: 0.01, poll: poll, pass: { _ in log.append("ask") })
        check(log == ["step 1"], "a turn with no question: the steps")
        // hands flushes step 2, then asks; the question is seen before the trace is read again.
        trace.append("step 2")
        gate.asked(["question": "Which order?"])
        let t0 = Date()
        gate.cycle(timeout: 2, poll: poll, pass: { q in log.append("ask \(q["question"] as? String ?? "")") })
        check(log == ["step 1", "step 2", "ask Which order?"], "the step before the question comes first: \(log)")
        check(Date().timeIntervalSince(t0) < 0.5, "a question wakes the loop at once")
        // The answer, then step 3: a step after the question (it closes it), and the question is not passed again.
        trace.append("step 3")
        gate.cycle(timeout: 0.01, poll: poll, pass: { _ in log.append("ask again") })
        check(log.last == "step 3" && !log.contains("ask again"), "then the step after it, once")
        // A question that comes while the trace is being read waits for the next turn, after the steps before it.
        log = []
        gate.cycle(timeout: 0.01, poll: { trace.append("step 4"); gate.asked(["question": "Q2"]); poll() },
                   pass: { _ in log.append("ask Q2 early") })
        check(log == ["step 4"], "a question during the read: not this turn")
        // (hands waits on the answer meanwhile, so no later step can be written before the question is shown.)
        gate.cycle(timeout: 0.5, poll: { poll() }, pass: { q in log.append("ask \(q["question"] as? String ?? "")") })
        check(log == ["step 4", "ask Q2"], "next turn: read, then the question (\(log))")
    }

    /// A failed run in one sentence (Shared/RunErrorText.swift), against real messages.
    static func runErrorTests() {
        let apps = "errored  0 actions  1s  $0.00\nTraceback (most recent call last):\n  File \"/x/apps.py\", line 90, in <module>\n    APPS = load()\nValueError: /Users/alice/.config/deskmind/apps.yaml: unknown keys: groundings; known keys: grounding, deep_ax, vision, chat, chords"
        let a = RunErrorText.friendly(apps, lang: .en)
        check(a.hasPrefix("Your apps file (~/.config/deskmind/apps.yaml) has a problem: unknown keys: groundings; known keys:"),
              "a bad apps file says what is wrong in it: \(a)")
        check(!a.contains("alice"), "and not the path with the user's name")
        let other = RunErrorText.friendly("errored\nValueError: snapshot apps list is empty", lang: .en)
        check(!other.hasPrefix("Your apps file"), "another ValueError that mentions apps is not the apps file: \(other)")
        check(RunErrorText.friendly(apps, lang: .zhHans).contains("unknown keys: groundings"), "in Chinese too, with the key")
        let refused = "errored  0 actions  6s  $0.00\nprovider_unavailable: system one endpoint http://127.0.0.1:18850 failed: HTTP Error 400: Bad Request -- choice criteria must be a map with 1..255 options\ntrace runs/do-20261005-022054"
        let en = RunErrorText.friendly(refused, lang: .en)
        check(en.hasPrefix("The local model couldn't handle this step (choice criteria must be a map with 1..255 options)"),
              "a 400 says the model refused the step, and why: \(en)")
        check(!en.contains("in time"), "a refusal is not called a timeout")
        let old = "provider_unavailable: system one endpoint http://127.0.0.1:18850 failed: HTTP Error 400: Bad Request"
        check(RunErrorText.friendly(old, lang: .en) == L("The local model couldn't handle this step. Please report it on GitHub so it can be fixed.", lang: .en),
              "a 400 with no message (an older hands)")
        let timeout = "provider_unavailable: system one endpoint http://127.0.0.1:18850 failed: <urlopen error timed out>"
        check(RunErrorText.friendly(timeout, lang: .en).contains("didn't answer in time"), "a timeout is still a timeout")
        check(RunErrorText.friendly("provider_unavailable: ... failed: <urlopen error [Errno 61] Connection refused>", lang: .en)
                .contains("didn't answer in time"), "connection refused: not ready")
        check(RunErrorText.friendly(refused, lang: .zhHans).hasPrefix("本地模型处理不了这一步（choice criteria"), "zh")
        check(RunErrorText.friendly("see failed: capture failed", lang: .en).hasPrefix("Couldn't see the window"), "capture")
        check(RunErrorText.friendly("something else", lang: .en).hasPrefix("This run hit an error"), "anything else")
    }

    /// The file example names a file the folder really holds (Shared/FileExample.swift).
    static func fileExampleTests() {
        typealias F = FileExample
        check(F.file(in: ["待办.txt", "报销单.csv", "草稿.txt"]) == "报销单.csv", "the sample folder, Chinese")
        check(F.file(in: ["todo.txt", "expenses.csv"]) == "expenses.csv", "the sample folder, English")
        check(F.file(in: ["todo.txt", "draft.txt"]) == "draft.txt", "no expenses file: a document it really holds")
        check(F.file(in: ["IMG_0042.jpg", "setup.dmg", "Q3 report.pdf", "data.csv"]) == "data.csv", "documents first (csv, then pdf…)")
        check(F.file(in: ["IMG_0042.jpg", "setup.dmg"]) == "IMG_0042.jpg", "no document: any visible file, in name order")
        check(F.file(in: [".DS_Store", ".hidden.csv", "~$draft.docx", "Makefile"]) == nil, "nothing to name: the example is not offered")
        check(F.file(in: []) == nil, "an empty folder")
        // files(at:) lists files only, no folders, nothing hidden.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fileexample-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("Receipts"), withIntermediateDirectories: true)
        for n in ["a.pdf", ".DS_Store"] { FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data()) }
        check(F.files(at: dir.path) == ["a.pdf"], "files only: \(F.files(at: dir.path))")
        try? FileManager.default.removeItem(at: dir)
        check(L("Make a folder called Receipts and move %@ into it", "a.pdf", lang: .zhHans) != "Make a folder called Receipts and move a.pdf into it", "zh")
    }

    /// The Self-test screen's titles and Start button (Shared/SelfTest.swift).
    static func selfTestTests() {
        for (id, key) in SelfTest.titles {
            check(SelfTest.title(id: id, fallback: "任务文件标题", lang: .en) == key, "en title for \(id)")
            let zh = SelfTest.title(id: id, fallback: "任务文件标题", lang: .zhHans)
            check(zh != key && zh.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }, "zh title for \(id): \(zh)")
        }
        check(SelfTest.title(id: "Z99-unknown", fallback: "From the task file", lang: .en) == "From the task file", "an unknown task: its file's title")
        check(SelfTest.startLabel(selected: "G07-finder-newfolder", lastRun: nil) == "Start", "nothing run yet: Start")
        check(SelfTest.startLabel(selected: "G07-finder-newfolder", lastRun: "G07-finder-newfolder") == "Run again", "the one just run: Run again")
        check(SelfTest.startLabel(selected: "G08-finder-move-one", lastRun: "G07-finder-newfolder") == "Start", "another one picked after a run: Start")
        // Every task the screen offers has a title of ours.
        for id in ["G07-finder-newfolder", "G08-finder-move-one", "G01-finder-sort", "G04-chinese-exact",
                   "S01-rename", "S02-edit-save", "S03-zh-text", "S04-clipboard-protect", "S05-cancel", "S06-stale-binding"] {
            check(SelfTest.titles[id] != nil, "a title for \(id)")
        }
    }

    /// Apps an instruction names that the Mac does not have (Shared/AppMention.notInstalled).
    static func notInstalledTests() {
        let known: [String: (shown: String, names: [String])] = [
            "com.netease.163music": ("NetEase Cloud Music", ["NetEase Cloud Music", "网易云音乐", "网易云"]),
            "com.tencent.xinWeChat": ("WeChat", ["WeChat", "微信"]),
        ]
        let none: Set<String> = []
        check(AppMention.notInstalled(in: "Open NetEase Cloud Music, search 张悬 宝贝 and play it", known: known, installed: none)
              == ["NetEase Cloud Music"], "not installed: said")
        check(AppMention.notInstalled(in: "打开网易云音乐，搜索最好的时光并播放", known: known, installed: none) == ["NetEase Cloud Music"], "zh name")
        check(AppMention.notInstalled(in: "Open NetEase Cloud Music and play it", known: known, installed: ["com.netease.163music"]).isEmpty,
              "installed: nothing to say")
        check(AppMention.notInstalled(in: "用微信把网易云里的歌发给我", known: known, installed: none) == ["WeChat", "NetEase Cloud Music"],
              "two, in the order named")
        check(AppMention.notInstalled(in: "Make a folder called Receipts and move expenses.csv into it", known: known, installed: none).isEmpty,
              "a file task names no app")
        check(AppMention.notInstalled(in: "Rename wechat-export.txt to notes.txt", known: known, installed: none).isEmpty,
              "a file named like an app is not the app")
        check(L("%@ isn't installed on this Mac. Install it, or name an app you have.", "WeChat", lang: .zhHans).contains("微信") == false
              && L("%@ isn't installed on this Mac. Install it, or name an app you have.", "微信", lang: .zhHans).contains("没有安装"), "zh text")
    }

    /// Renames wait for approval in a person's own folder, not the sample one (Shared/FolderPolicy.swift).
    static func folderPolicyTests() {
        let sample = "/Users/someone/DeskMind Playground"
        check(!FolderPolicy.confirmRenames(folder: sample, sample: sample), "the sample folder: renames unasked")
        check(!FolderPolicy.confirmRenames(folder: sample + "/", sample: sample), "with a trailing slash")
        check(!FolderPolicy.confirmRenames(folder: sample + "/Receipts", sample: sample), "a folder inside it")
        check(FolderPolicy.confirmRenames(folder: "/Users/someone/Downloads", sample: sample), "Downloads: asked")
        check(FolderPolicy.confirmRenames(folder: "/Users/someone/DeskMind Playground 2", sample: sample), "a look-alike name: asked")
        check(FolderPolicy.confirmRenames(folder: "/Users/someone/DeskMind Playground/../Documents", sample: sample), "a path that leaves it: asked")
    }

    /// What a report carries besides the user's words (Shared/Diagnostics.swift): numbers and kinds, nothing named.
    static func diagnosticsTests() {
        let raw = """
        target   /Users/alice/Downloads   (150 files)
        goal     整理目录
        these files are real and there is no undo. ctrl-c now if the target is wrong.
        no files changed
        errored  0 actions  75s  $0.00
        provider_unavailable: system one endpoint http://127.0.0.1:18850 failed: HTTP Error 500: Internal Server Error -- RuntimeError: [metal::malloc] Attempting to allocate 98725039088 bytes which is greater than the maximum allowed buffer size
        trace runs/do-20261005-015752
        """
        let s = Diagnostics.sanitize(raw, user: "alice")
        check(s.contains("98725039088 bytes") && s.contains("HTTP Error 500"), "the error itself stays: \(s)")
        check(!s.contains("alice") && !s.contains("/Users") && !s.contains("整理目录") && !s.contains("Downloads"),
              "no user, path, goal or folder name: \(s)")
        check(!s.contains("trace runs/"), "only the error lines")
        let quoted = Diagnostics.sanitize("errored: could not rename '合同扫描件.pdf' to 'file-8.pdf'; KeyError: 'window_id' failed", user: "x")
        check(!quoted.contains("合同") && !quoted.contains("file-8") && quoted.contains("'window_id'"),
              "quoted names out, identifiers in: \(quoted)")
        check(Diagnostics.sanitize("failed at ~/Documents/secret plan/notes.txt", user: "x") == "failed at <path> plan/notes.txt"
              || !Diagnostics.sanitize("failed at ~/Documents/secret plan/notes.txt", user: "x").contains("Documents"), "~ paths")
        let d = Diagnostics(error: raw, stepSeconds: [6.5, 41.3, 38.2], failedRequest: ["select_target": ("choice", 40), "operation": ("choice", 8)],
                            folder: (150, 12), system: [("DeskMind", "0.4.0 (33)"), ("chip", "Apple M4")])
        let md = d.markdown()
        check(md.hasPrefix("<details>") && md.contains("6.5, 41.3, 38.2") && md.contains("select_target (choice, 40)")
              && md.contains("150 files, 12 folders") && md.contains("chip: Apple M4"), "the section: \(md)")
        check(!md.contains("alice") && !md.contains("整理目录"), "and nothing named in it")
        check(Diagnostics().markdown().isEmpty, "nothing to say: no section")
        // In a report, the section stays whole; a long instruction is what is shortened.
        let long = String(repeating: "整理目录并把所有截图移到截图文件夹，", count: 200)
        let u = IssueReport.url(kind: .error, goal: long, outcome: "It stopped.", steps: ["click"], appVersion: "0.4.0", macOS: "27.2",
                                diagnostics: md)
        let body = u.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "what-happened" }?.value } ?? ""
        check((u?.absoluteString.count ?? 99999) <= IssueReport.maxURL && body.contains("150 files, 12 folders"),
              "within the URL limit, diagnostics kept (\(u?.absoluteString.count ?? 0))")
        // Counting a folder lists no names.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.pdf").path, contents: Data())
        let c = Diagnostics.count(folder: dir.path)
        check(c?.files == 1 && c?.folders == 1, "folder counted: \(String(describing: c))")
        try? FileManager.default.removeItem(at: dir)
        check(Diagnostics.mac().contains { $0.0 == "memory" }, "the Mac's memory")
    }

    /// How a run is recorded (Shared/RecordingCapture.swift): which capture, the pacing, which pictures are written.
    static func recordingCaptureTests() {
        let def = RecordingCapture.mode(smooth: false), smooth = RecordingCapture.mode(smooth: true)
        check(def == .init(fps: 10, stream: false) && def.name == "one-shot screenshots", "default: one-shot at 10 fps")
        check(smooth == .init(fps: 30, stream: true) && smooth.name == "stream", "Smooth Recordings: the stream at 30 fps")
        // Pacing: one interval on when on time; from now when behind, never a burst to catch up.
        check(abs(RecordingCapture.nextDue(after: 5.0, now: 5.02, fps: 10) - 5.1) < 1e-9, "on time: the next is 0.1 s on")
        check(RecordingCapture.nextDue(after: 5.0, now: 5.3, fps: 10) == 5.3, "behind: the next is now, not 5.1")
        // A loop whose pictures take 80 ms (a full-resolution one-shot): 10 fps holds, 30 is out of reach (about 12).
        // The first picture is taken at 0 by begin(), before the loop.
        func pictures(fps: Double, cost: Double, seconds: Double) -> Int {
            var clock = 0.0, due = 0.0, n = 1
            while true {
                due = RecordingCapture.nextDue(after: due, now: clock, fps: fps)
                clock = max(clock, due) + cost
                if clock > seconds { return n }
                n += 1
            }
        }
        check(pictures(fps: 10, cost: 0.08, seconds: 10) == 100, "10 fps at 80 ms a picture: \(pictures(fps: 10, cost: 0.08, seconds: 10)) in 10 s")
        let fast = pictures(fps: 30, cost: 0.08, seconds: 10)
        check(fast >= 115 && fast <= 125, "30 fps asked at 80 ms a picture: about 12 a second (\(fast) in 10 s)")
        // Written only later than the last, while accepting, when the writer is ready.
        check(RecordingCapture.shouldAppend(at: 0.2, last: 0.1, accepting: true, ready: true), "a later picture is written")
        check(!RecordingCapture.shouldAppend(at: 0.1, last: 0.1, accepting: true, ready: true), "not one at the same time")
        check(!RecordingCapture.shouldAppend(at: 0.05, last: 0.1, accepting: true, ready: true), "not an earlier one")
        check(!RecordingCapture.shouldAppend(at: 0.2, last: 0.1, accepting: false, ready: true), "not after the movie is finishing")
        check(!RecordingCapture.shouldAppend(at: 0.2, last: 0.1, accepting: true, ready: false), "not while the writer is busy")
    }

    static func issueReportTests() {
        let u = IssueReport.url(kind: .guessed, goal: "Add Lisa Wong's order to ledger.csv\nthen save", outcome: "It said it finished.",
                                steps: ["double_click", "type_text", "type_text", "save"], appVersion: "0.4.0", macOS: "Version 27.2")
        let q = URLComponents(url: u!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let field = { (name: String) in q.first { $0.name == name }?.value ?? "" }
        let title = field("title"), happened = field("what-happened")
        check(u!.absoluteString.hasPrefix("https://github.com/deskmind-ai/deskmind/issues/new?"), "the hub's new-issue page")
        check(field("template") == "app_problem.yml", "the app problem form, not a blank issue")
        check(title == "Guessed instead of asking: Add Lisa Wong's order to ledger.csv then save", "title: \(title)")
        check(field("goal") == "Add Lisa Wong's order to ledger.csv\nthen save", "the instruction, as typed")
        check(happened.hasPrefix("It said it finished."), "how it ended, first")
        check(happened.contains("**Steps**: 4 (type_text ×2, double_click, save)"), "steps as a count and kinds only: \(happened)")
        check(happened.contains("What it should have asked") && happened.contains("deskmind/issues/10"), "the guessed prompt links the ambiguous-tasks issue")
        check(field("version") == "0.4.0" && field("mac") == "macOS Version 27.2", "versions")
        check(!IssueReport.whatHappened(kind: .stuck, outcome: "", steps: []).contains("Steps"), "no steps: no Steps line")
        let d = IssueReport.url(kind: .error, goal: "g", outcome: "o", steps: [], appVersion: "1", macOS: "2",
                                diagnostics: "<details><summary>Diagnostics</summary>\n\nx\n\n</details>\n")
        let dq = URLComponents(url: d!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        check(dq.first { $0.name == "what-happened" }?.value?.contains("<details>") == true, "diagnostics go under what happened")
        check(IssueReport.stepSummary([]) == "0" && IssueReport.stepSummary(["", ""]) == "2", "no kinds")
        let long = IssueReport.url(kind: .stuck, goal: String(repeating: "很长的指令 ", count: 2000), outcome: "o", steps: ["click"], appVersion: "1", macOS: "2")
        check(long != nil && long!.absoluteString.count <= IssueReport.maxURL, "a very long instruction is cut to fit: \(long?.absoluteString.count ?? -1)")
        check(IssueReport.oneLine("a\nb", max: 10) == "a b" && IssueReport.oneLine("abcdefghijk", max: 5) == "abcd…", "one line, cut with …")
        for k in IssueReport.Kind.allCases { check(L(k.label, lang: .zhHans) != k.label, "a Chinese label for \(k.label)") }
    }

}
