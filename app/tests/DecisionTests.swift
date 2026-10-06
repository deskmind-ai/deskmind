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
        runErrorTests()
        fileExampleTests()
        selfTestTests()
        notInstalledTests()
        folderPolicyTests()
        diagnosticsTests()
        recordingCaptureTests()
        helperLocationTests()
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

        // Statuses.
        check([LV.Status.done, .failed, .stopped].allSatisfy(\.isEnding), "endings")
        check(![LV.Status.starting, .working, .waitingForUser, .paused, .hidden].contains(where: \.isEnding), "not endings")
        let allStatuses: [LV.Status] = [.starting, .working, .waitingForUser, .paused, .hidden, .done, .failed, .stopped]
        for st in allStatuses {
            check(L(LV.word(st), lang: .zhHans) != LV.word(st), "a Chinese word for \(LV.word(st))")
        }
    }


    /// A report as a GitHub issue (Shared/IssueReport.swift): what goes in, and that a long run still fits a URL.
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

    /// Which helper copy runs (Shared/HelperLocation.swift): the nested copy hands over to the installed one.
    static func helperLocationTests() {
        let support = "/Users/u/Library/Application Support/DeskMind"
        let installed = HelperLocation.installedPath(supportDir: support)
        check(installed == support + "/DeskMind Hands.app", "installed copy path: \(installed)")
        let nested = "/Applications/DeskMind.app/Contents/Library/LoginItems/DeskMind Hands.app"
        check(HelperLocation.handOverTarget(bundlePath: nested, installedPath: installed) == installed,
              "the copy inside DeskMind.app hands over (rc.1: macOS's Quit & Reopen started it)")
        check(HelperLocation.handOverTarget(bundlePath: installed, installedPath: installed) == nil,
              "the installed copy keeps running")
        check(HelperLocation.handOverTarget(bundlePath: installed + "/", installedPath: installed) == nil,
              "the same path written differently is the same copy")
        check(HelperLocation.handOverTarget(bundlePath: "/Users/u/build/DeskMind Hands.app", installedPath: installed) == nil,
              "a standalone build (not inside another app) is left alone")
        // The installed copy is remade from the shipped one whenever they differ, older or newer.
        let a = HelperLocation.Stamp(version: "0.4.1", build: "70", runtime: "89be730+f8e4702+ocr", executable: "aa")
        check(!HelperLocation.needsInstall(shipped: a, installed: a), "the same copy: left as it is")
        check(HelperLocation.needsInstall(shipped: a, installed: nil), "none installed: install")
        check(HelperLocation.needsInstall(shipped: a, installed: .init(version: "0.4.0", build: "36", runtime: "11368c6+f8e4702+ocr", executable: "bb")),
              "an older copy after an update: replace")
        check(HelperLocation.needsInstall(shipped: a, installed: .init(version: "0.5.0", build: "80", runtime: "x", executable: "cc")),
              "a newer copy (an older DeskMind.app put back): replace with what this app ships")
        check(HelperLocation.needsInstall(shipped: a, installed: .init(version: "0.4.1", build: "70", runtime: "89be730+f8e4702+ocr", executable: "dd")),
              "same version, different executable (a development rebuild): replace")
        check(!HelperLocation.needsInstall(shipped: nil, installed: a), "nothing shipped to install from: left")
        // Restart so a Screen Recording grant takes effect: only when a new process sees it and this one doesn't.
        check(HelperLocation.restartForGrant(live: false, probe: true, taskRunning: false, alreadyScheduled: false),
              "granted, not yet seen: restart")
        check(!HelperLocation.restartForGrant(live: true, probe: true, taskRunning: false, alreadyScheduled: false), "already seen")
        check(!HelperLocation.restartForGrant(live: false, probe: false, taskRunning: false, alreadyScheduled: false), "not granted")
        check(!HelperLocation.restartForGrant(live: false, probe: true, taskRunning: true, alreadyScheduled: false),
              "never in the middle of a task")
        check(!HelperLocation.restartForGrant(live: false, probe: true, taskRunning: false, alreadyScheduled: true), "once")
        // The app replaces a connected helper that runs from anywhere else.
        check(HelperLocation.isWrongCopy(runningPath: nested, installedPath: installed), "nested copy connected: wrong")
        check(!HelperLocation.isWrongCopy(runningPath: installed, installedPath: installed), "installed copy: right")
        check(!HelperLocation.isWrongCopy(runningPath: nil, installedPath: installed), "an older helper that doesn't say: left")
        check(!HelperLocation.isWrongCopy(runningPath: "/Users/u/build/DeskMind Hands.app", installedPath: installed),
              "a development helper started elsewhere is not terminated (review of #32)")
        // One helper at a time: a second one waits for the first to go, and gives up if it stays (rc.2 e2e: a restart
        // with the app open left two helpers, the second holding the socket).
        let lockPath = NSTemporaryDirectory() + "hands-\(getpid()).lock"
        let first = HelperLock.acquire(lockPath, wait: 0)
        check((first ?? -1) >= 0, "the first helper takes the lock")
        check(HelperLock.acquire(lockPath, wait: 0.3) == nil, "a second one, while the first stays: gives up")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { close(first ?? -1) }
        let successor = HelperLock.acquire(lockPath, wait: 5)
        check((successor ?? -1) >= 0, "a successor waits for the first to go, then takes it")
        close(successor ?? -1); unlink(lockPath)
        check(HelperLock.acquire("/nonexistent-dir/hands.lock", wait: 0) == -1, "no lock file: the helper still runs")
        // A helper that is alive but silent is quit after 30 s, killed 10 s later (review of #32: a hung helper held
        // its socket and nothing replaced it -- the app's launch only brought it forward).
        check(HelperLocation.hungAction(silentFor: 5, running: true, quitAskedFor: nil) == .none, "a short silence: a restart, a busy moment")
        check(HelperLocation.hungAction(silentFor: 30, running: true, quitAskedFor: nil) == .terminate, "30 s silent: quit it")
        check(HelperLocation.hungAction(silentFor: 300, running: false, quitAskedFor: nil) == .none, "nothing running: the app starts one")
        check(HelperLocation.hungAction(silentFor: 35, running: true, quitAskedFor: 4) == .none, "asked to quit: give it time")
        check(HelperLocation.hungAction(silentFor: 45, running: true, quitAskedFor: 10) == .kill, "still there: kill it")
        // Opening a hung helper again showed "DeskMind Hands is not responding", once per poll (10-06).
        check(!HelperLocation.shouldLaunch(running: true), "a helper is running, silent: not opened again")
        check(HelperLocation.shouldLaunch(running: false), "none running: start one")
        // The language follows the system unless the user picked one (0.4.1-rc.1 opened in English on a Chinese Mac).
        check(AppLanguage(rawValue: AppLanguage.system.rawValue)?.resolved == ResolvedLang.fromSystem(), "system language")
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
