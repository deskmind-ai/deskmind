// Runs, watched step by step: the model behind every run (RunModel), the step cards, and the examples screen -- the
// mock desktop's smoke set (no real app is touched: it proves the chain main app -> helper -> Python runtime ->
// deskmind-hands) and a few real sandbox tasks. The user's own instructions run in GoalRunView, from the home screen.

import SwiftUI

struct RunStep: Identifiable {
    let id = UUID()
    let n: Int
    let human: String
    let app: String
    let shot: String
    let describe: String
    let detail: String
    let ok: Bool
    /// The operation alone ("type_text"), with nothing read from the screen: what a public report may carry.
    var operation: String { String(describe.split(separator: " ").first ?? "") }
}

/// What the examples screen offers. The real ones are diag tasks: each runs in a fresh sandbox folder copied from
/// its fixture, never in the user's own files. Titles and app names are English keys, shown through L().
struct PlayChoice: Identifiable, Hashable {
    let id: String
    let title: String
    let app: String
    let real: Bool

    static let mock = PlayChoice(id: "smoke", title: "6 smoke tests", app: "Mock desktop", real: false)
    static let real: [PlayChoice] = [
        PlayChoice(id: "G07-finder-newfolder", title: "Make a new folder", app: "Finder", real: true),
        PlayChoice(id: "G08-finder-move-one", title: "Move a file into a folder", app: "Finder", real: true),
        PlayChoice(id: "G01-finder-sort", title: "Sort files by type", app: "Finder", real: true),
        PlayChoice(id: "G04-chinese-exact", title: "Type exact Chinese text and save", app: "TextEdit", real: true),
    ]
}

struct RunTask: Identifiable {
    let id: String
    var title: String
    var steps: [RunStep] = []
    var strict: Bool?
    /// The user's own instruction: no grader, so the result is what changed in the attached folder, or the answer.
    var free = false
    /// The folder the run worked in; nil when none was attached (then there is no change list at all).
    var folder: String?
    /// A question's answer ("who sings the first song?"), from the DONE that ended the run.
    var answer = ""
    var created: [String] = []
    var modified: [String] = []
    var deleted: [String] = []
}

/// A question the running task asked, waiting for the user: a reply to type, or an approval to give.
struct PendingAsk: Equatable {
    let question: String
    let approval: Bool
    /// Answers to pick from: the alternatives the question lists (two orders for one customer). Typing stays open.
    var options: [String] = []
}

@MainActor
final class RunModel: ObservableObject {
    enum Phase { case idle, running, done, failed }
    @Published var phase: Phase = .idle
    @Published var tasks: [RunTask] = []
    @Published var summary = ""
    @Published var elapsed: TimeInterval = 0
    private var started = Date()
    private var tick: Timer?

    var passed: Int { tasks.filter { $0.strict == true }.count }
    @Published var rawError = ""
    /// The last finished run's count, so the status chip can word it in the current language.
    @Published var result = (passed: 0, total: 0)

    /// A failed run in one sentence the user can act on; the raw text stays available under "Details".
    /// (The helper's "local model not ready" error is already such a sentence: apply() shows it as it is.)
    static func friendly(_ raw: String) -> String {
        let r = raw.lowercased()
        let lang = ResolvedLang.current
        if r.contains("screen recording") || r.contains("tcc") || r.contains("accessibility") && r.contains("not") {
            return L("The helper seems to have lost its permissions. Check “Accessibility” and “Screen Recording” on the home screen, then run it again.",
                     lang: lang)
        }
        if r.contains("quarantined") || r.contains("capture failed") || r.contains("see failed") {
            return L("Couldn't see the window this time (it happens when the Mac is busy). Wait a moment and run it again.",
                     lang: lang)
        }
        if r.contains("provider_unavailable") || r.contains("timed out") || r.contains("connection refused")
            || r.contains("18850") {
            return L("The local model didn't answer in time. Check that “Local model” is ready on the home screen, then run it again.",
                     lang: lang)
        }
        if r.contains("no folder is attached") {
            return L("The instruction names files, but no folder is attached and none of them is open. Attach the folder they're in, or open them, then run it again.",
                     lang: lang)
        }
        if r.contains("a run is already in progress") {
            return L("The last task is still running. Wait for it to finish, or click “Stop” first.", lang: lang)
        }
        return L("This run hit an error. Run it again; if it keeps happening, report it on GitHub.", lang: lang)
    }

    func start(_ choice: PlayChoice) {
        let req: [String: Any] = choice.real
            ? ["op": "run", "set": "diag", "task": choice.id, "real": true]
            : ["op": "run", "set": "smoke"]
        start(request: req)
    }

    private var real = false
    /// The last run was a free-form instruction (the status chip words its result without a pass count).
    @Published private(set) var free = false
    /// Paused until the user stops using the mouse and keyboard (see the "waiting" event).
    @Published var waitingForUser = false
    /// What the paused step will do once the user stops ("type '张悬 宝贝' into '搜索框'").
    @Published var waitingWhat = ""
    /// The question the task is waiting on, if any (see AskCard).
    @Published var ask: PendingAsk?
    /// Set while the helper loads something before the run can start ("eyes": the vision model).
    @Published var preparing = ""
    /// What the run is doing before its first step, and since when (see RunStage); nil once steps come.
    @Published private(set) var stage: RunStage?
    @Published private(set) var stageSince = Date()
    /// The recording is starting: the run starts once it is (or could not be) started.
    @Published private(set) var pickingRecording = false
    /// What the user's own instruction was run with, to keep it in the recent runs when it ends.
    var goalRequest: GoalRequest?
    /// This run's recording, once it is written (see RunRecorder).
    @Published var movie: URL?
    private var recording = false
    /// This run's entry in the recent runs, once kept.
    private var recordID: UUID?
    private var recorded = false

    func start(request req: [String: Any]) {
        let goal = req["goal"] as? String
        free = goal != nil
        ask = nil; preparing = ""; recorded = false
        real = req["real"] as? Bool ?? false || free
        RunModel.shared = self
        movie = nil
        recording = req["record"] as? Bool ?? false
        if real {
            // The run is in the island from the moment it is started, recording and preparing included; DeskMind's
            // own window steps aside at once (it stayed in the middle of the screen while the helper started).
            RunOverlay.requestNotificationPermission()
            RunOverlay.shared.onStop = { [weak self] in self?.stop() }
            let title = goal.map { $0.count > 40 ? String($0.prefix(39)) + "…" : $0 }
            RunOverlay.shared.show(title: title ?? (req["task"] as? String) ?? L("Task", lang: ResolvedLang.current),
                                   line: goal == nil ? nil : L("Getting ready…", lang: ResolvedLang.current))
            MainWindow.stepAside()
        }
        guard recording else { go(req); return }
        // The recording starts first and the run once it is going: started together, the first steps went by
        // unrecorded. If it cannot start, the run goes ahead unrecorded.
        pickingRecording = true
        // Only the apps the run works in are recorded (a folder task: Finder and TextEdit), besides DeskMind's own.
        let named = (req["apps"] as? [[String: Any]] ?? []).compactMap { $0["bundle"] as? String }
        let bundles = named.isEmpty ? ["com.apple.finder", "com.apple.TextEdit"] : named
        RunRecorder.shared.begin(goal: goal ?? "", bundles: bundles) { [weak self] ok in
            guard let self else { return }
            self.pickingRecording = false
            if !ok { self.recording = false }
            self.go(req)
        }
    }

    /// The run under way: the status at the top of the screen, the clock, and the request to the helper.
    private func go(_ req: [String: Any]) {
        tasks = []; summary = ""; phase = .running; started = Date(); elapsed = 0
        queue = []; streamEnded = false; player?.invalidate(); player = nil
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                guard let m = RunModel.shared, m.phase == .running else { return }
                m.elapsed = Date().timeIntervalSince(m.started)
            }
        }
        setStage(.starting)
        // Only when asked for (View menu): a recording is kept clean -- what each step decided is drawn over it
        // afterwards from steps.json, and the panel in the picture said it twice.
        if DecisionPanel.always { DecisionPanel.shared.show() }
        launch(req)
    }

    /// A stage begins (nil: the steps have started, or the run ended). How long the last one took is kept, to say
    /// "usually about N s" next time.
    private func setStage(_ s: RunStage?) {
        if let old = stage, old != s {
            let took = Int(Date().timeIntervalSince(stageSince).rounded())
            if took > 0 { UserDefaults.standard.set(took, forKey: Self.typicalKey(old)) }
        }
        guard s != stage else { return }
        stage = s; stageSince = Date()
        if real { RunOverlay.shared.setStage(s, since: stageSince, typical: s.flatMap(Self.typical)) }
    }

    private static func typicalKey(_ s: RunStage) -> String { "stage.typical.\(s.rawValue)" }
    static func typical(_ s: RunStage) -> Int? {
        let v = UserDefaults.standard.integer(forKey: typicalKey(s))
        return v > 0 ? v : nil
    }

    /// The run itself: the request to the helper, and its events as they come.
    private func launch(_ req: [String: Any]) {
        Task.detached {
            let ok = DeskMindIPC.stream(req) { e in
                Task { @MainActor in RunModel.shared?.enqueue(e) }
            }
            await MainActor.run {
                guard let m = RunModel.shared else { return }
                if !ok {
                    m.phase = .failed; m.summary = L("Can't reach the helper", lang: ResolvedLang.current)
                    m.wrapUp()
                    if m.real { RunOverlay.shared.finish(passed: false, summary: m.summary) }
                }
                m.streamEnded = true
            }
        }
    }

    static weak var shared: RunModel?

    /// The run is over: the recording is finished and handed over, the decision panel goes after a moment.
    /// The window does not come back by itself: the result is in the island, whose "Show Details" brings it.
    private func wrapUp() {
        setStage(nil)
        reminder?.cancel(); reminder = nil
        if recording {
            recording = false
            RunRecorder.shared.stop { [weak self] url in
                guard let self else { return }
                self.movie = url
                // The run was kept in the recent runs before its movie was finished: add it there now.
                if let url, let id = self.recordID { RunHistory.shared.setMovie(url.path, for: id) }
            }
        }
        DecisionPanel.shared.hide(after: 4)
    }

    // The mock desktop finishes a whole set in about two seconds; shown at that speed nobody sees a step. Events are
    // played back at a readable pace instead (a real desktop is slower than this anyway).
    private var queue: [[String: Any]] = []
    private var player: Timer?
    var streamEnded = false

    func enqueue(_ e: [String: Any]) {
        queue.append(e)
        guard player == nil else { return }
        player = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
            Task { @MainActor in RunModel.shared?.playNext() }
        }
    }

    private func playNext() {
        guard !queue.isEmpty else {
            if streamEnded {
                player?.invalidate(); player = nil
                if phase == .running {
                    wrapUp()
                    phase = .failed; summary = L("The helper cut this run short", lang: ResolvedLang.current)
                    ask = nil; record()
                    if real { RunOverlay.shared.finish(passed: false, summary: summary) }
                }
            }
            return
        }
        // Headers and results go through at once with the step that follows them; steps take one tick each.
        while let e = queue.first {
            queue.removeFirst()
            apply(e)
            if e["event"] as? String == "step" { break }
        }
    }

    func stop() {
        if real && phase == .running { RunOverlay.shared.model.stoppedByUser = true }
        Task.detached { _ = DeskMindIPC.request(["op": "stop"]) }
    }

    /// The user's reply (or verdict, for an approval) to the waiting question, written to the task's stdin by the
    /// helper. The card goes away at once; if the helper had nothing waiting, the next step says what happened.
    func answer(_ reply: String, approve: Bool) {
        ask = nil
        apply(AskFlow.answeredInWindow, question: nil)
        if real { MainWindow.stepAside() }
        Task.detached { _ = DeskMindIPC.request(["op": "answer", "reply": reply, "approve": approve]) }
    }

    /// A reminder for a question in the live view that waits (AskFlow.reminderAfter).
    private var reminder: DispatchWorkItem?
    /// The waiting question's id (the helper's `ask_id`): an `answered` for another question changes nothing.
    private var askID: Int?

    /// Carry out what AskFlow decided for a question event (island, window, notifications), for a real run.
    private func apply(_ fx: AskFlow.Effects, question q: PendingAsk?) {
        guard real else { return }
        let lang = ResolvedLang.current
        if fx.cancelReminder { reminder?.cancel(); reminder = nil }
        if let on = fx.needsYou { RunOverlay.shared.setNeedsYou(on) }
        if let say = fx.say { RunOverlay.shared.say(L(say, lang: lang)) }
        if fx.comeBack { MainWindow.comeBack(activate: fx.activate) }
        guard let q else { return }
        let title = q.approval ? L("DeskMind needs your approval", lang: lang) : L("DeskMind has a question", lang: lang)
        if fx.notify { RunOverlay.notify(title: title, body: q.question) }
        if fx.remind {
            reminder?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.ask != nil else { return }
                RunOverlay.notify(title: title, body: L("Answer it in the card in the corner of the screen.", lang: lang))
            }
            reminder = work
            DispatchQueue.main.asyncAfter(deadline: .now() + AskFlow.reminderAfter, execute: work)
        }
    }

    /// Show a past run as it ended (from the recent runs list): its steps, answer and changes, nothing running.
    func show(_ r: RunRecord) {
        free = true; real = false; ask = nil; preparing = ""; recorded = true
        var t = RunTask(id: "do", title: r.goal)
        t.steps = r.steps.map { RunStep(n: $0.n, human: $0.human, app: $0.app, shot: $0.shot, describe: $0.describe,
                                        detail: $0.detail, ok: $0.ok) }
        t.strict = r.errored ? false : r.finished
        t.free = !r.errored
        t.folder = r.folder; t.answer = r.answer
        t.created = r.created; t.modified = r.modified; t.deleted = r.deleted
        tasks = [t]
        movie = r.movie.map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        result = (r.finished ? 1 : 0, 1)
        summary = r.summary
        rawError = ""
        phase = r.errored ? .failed : .done
    }

    /// Keep a finished run of the user's own instruction in the recent runs (once, whichever way it ended).
    private func record() {
        // A run that never got going (the model not ready, the helper unreachable) is said on the spot, not kept.
        guard free, !recorded, let g = goalRequest, !tasks.isEmpty else { return }
        recorded = true
        let t = tasks.first
        let id = UUID()
        recordID = id
        defer { if let m = movie { RunHistory.shared.setMovie(m.path, for: id) } }   // finished before the run was kept
        RunHistory.shared.add(RunRecord(
            id: id, date: Date(), goal: g.goal, folder: g.folder, apps: g.apps.map(RunRecord.App.init),
            finished: phase == .done && result.passed > 0, errored: phase == .failed,
            summary: summary, answer: t?.answer ?? "",
            steps: (t?.steps ?? []).map { RunRecord.Step(n: $0.n, human: $0.human, app: $0.app, shot: $0.shot,
                                                         describe: $0.describe, detail: $0.detail, ok: $0.ok) },
            created: t?.created ?? [], modified: t?.modified ?? [], deleted: t?.deleted ?? []))
    }

    func apply(_ e: [String: Any]) {
        switch e["event"] as? String {
        case "task":
            let id = e["task"] as? String ?? "?"
            if tasks.isEmpty && stage != nil { setStage(.looking) }
            if !tasks.contains(where: { $0.id == id }) {
                withAnimation(.easeOut(duration: 0.2)) {
                    tasks.append(RunTask(id: id, title: e["title"] as? String ?? id))
                }
            }
        case "preparing":
            preparing = e["what"] as? String ?? ""
            setStage(RunStage(rawValue: preparing) ?? stage)
        case "start":
            if stage != nil { setStage(.hands) }
        case "waiting":
            // A step needs the front and the user is using the Mac: say so, and what it will do, and wait.
            waitingWhat = e["what"] as? String ?? ""
            if real { RunOverlay.shared.setWaiting(true, what: waitingWhat) }
            waitingForUser = true
        case "resumed":
            if real { RunOverlay.shared.setWaiting(false) }
            waitingForUser = false
        case "ask":
            let q = PendingAsk(question: e["question"] as? String ?? "", approval: e["approval"] as? Bool ?? false,
                               options: e["options"] as? [String] ?? [])
            withAnimation(.easeOut(duration: 0.2)) { ask = q }
            askID = e["ask_id"] as? Int
            // In the live view it is answered there; otherwise in this window (AskFlow.asked says what comes back).
            apply(AskFlow.asked(inCard: e["in_card"] as? Bool == true, approval: q.approval, appActive: NSApp.isActive,
                                userTyping: MainWindow.userTypedRecently()), question: q)
        case "answered":
            // Answered in the live view: this window's question card goes -- if it is that question.
            guard AskFlow.answerApplies(answered: e["ask_id"] as? Int, waiting: askID) else { return }
            withAnimation(.easeOut(duration: 0.2)) { ask = nil }
            apply(AskFlow.answeredInCard, question: nil)
        case "answer_in_window":
            // The user chose to type an answer: the window comes back, active (they asked for it), with the question.
            apply(AskFlow.typeInWindow, question: nil)
        case "step":
            let id = e["task"] as? String ?? "?"
            ask = nil   // a step after a question means it was answered (or timed out)
            apply(AskFlow.stepped, question: nil)
            if stage != nil { setStage(nil) }
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
            let step = RunStep(n: e["n"] as? Int ?? tasks[i].steps.count + 1,
                               human: e["human"] as? String ?? (e["describe"] as? String ?? ""),
                               app: e["app"] as? String ?? "",
                               shot: e["shot"] as? String ?? "",
                               describe: e["describe"] as? String ?? "",
                               detail: e["detail"] as? String ?? "",
                               ok: e["ok"] as? Bool ?? true)
            withAnimation(.easeOut(duration: 0.15)) { tasks[i].steps.append(step) }
            DecisionPanel.shared.update(step: e)
            if real { RunOverlay.shared.update(app: step.app, step: step.n, line: step.human) }
        case "task_done":
            let id = e["task"] as? String ?? "?"
            if let i = tasks.firstIndex(where: { $0.id == id }) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                    tasks[i].strict = e["strict"] as? Bool
                    // An errored run changed nothing worth judging; its error is shown instead.
                    // Stuck ("errored" with no_progress_loop) is still a run that ended with a change list.
                    tasks[i].answer = e["answer"] as? String ?? ""
                    if e["free"] as? Bool == true
                        && ((e["state"] as? String) != "errored" || (e["reason"] as? String) == "no_progress_loop") {
                        tasks[i].free = true
                        tasks[i].folder = e["has_folder"] as? Bool == true ? goalRequest?.folder : nil
                        tasks[i].created = e["created"] as? [String] ?? []
                        tasks[i].modified = e["modified"] as? [String] ?? []
                        tasks[i].deleted = e["deleted"] as? [String] ?? []
                    }
                }
            }
        case "done":
            wrapUp()
            let exit = e["exit"] as? Int ?? -1
            let lang = ResolvedLang.current
            phase = exit == 0 ? .done : .failed
            result = (e["passed"] as? Int ?? 0, e["total"] as? Int ?? 0)
            rawError = exit == 0 ? "" : L("Exit code %d\n%@", exit, e["stderr_tail"] as? String ?? "", lang: lang)
            summary = exit == 0 ? L("%d/%d tasks passed", result.passed, result.total, lang: lang) : Self.friendly(rawError)
            ask = nil; preparing = ""
            if free && exit == 0 {
                // No grader: say it finished (or stopped), and send the user to the answer or the change list.
                let completed = result.passed > 0
                let answer = e["answer"] as? String ?? ""
                let folder = goalRequest?.folder != nil
                if !answer.isEmpty {
                    summary = L("Answer: %@", answer, lang: lang)
                } else if folder {
                    summary = completed ? L("Finished. Check what changed in DeskMind.", lang: lang)
                        : (e["reason"] as? String == "no_progress_loop"
                           ? L("Got stuck: the same step kept failing, so DeskMind stopped. Check what changed below.", lang: lang)
                           : L("Stopped before finishing. Check what changed in DeskMind.", lang: lang))
                } else {
                    summary = completed ? L("Finished.", lang: lang)
                        : (e["reason"] as? String == "no_progress_loop"
                           ? L("Got stuck: the same step kept failing, so DeskMind stopped.", lang: lang)
                           : L("Stopped before finishing.", lang: lang))
                }
                RunOverlay.shared.finish(passed: completed, summary: summary)
                // The window stays aside after a run, the result in the island -- which shrinks after a few
                // seconds. An answer, and the first task that finishes, bring it back (not as the active window).
                if MainWindow.isAside && (!answer.isEmpty || (completed && !UserDefaults.standard.bool(forKey: "starNudge.seen"))) {
                    MainWindow.comeBack(activate: false)
                }
            } else if real {
                let passed = exit == 0 && (e["passed"] as? Int ?? 0) == (e["total"] as? Int ?? -1)
                RunOverlay.shared.finish(passed: passed,
                                         summary: passed ? L("Task done, and the result checks out", lang: lang) : summary)
            }
        case "error":
            wrapUp()
            phase = .failed
            ask = nil; preparing = ""
            rawError = e["error"] as? String ?? L("Something went wrong", lang: ResolvedLang.current)
            summary = e["code"] as? String == "brain_not_ready" ? rawError : Self.friendly(rawError)
            if real { RunOverlay.shared.finish(passed: false, summary: summary) }
        default:
            break
        }
        if phase == .done || phase == .failed { record() }
    }
}

/// The examples screen: the mock desktop's smoke set and a few real sandbox tasks, one at a time.
struct RunView: View {
    @StateObject private var run = RunModel()
    @EnvironmentObject var helper: HelperModel
    @State private var choice: PlayChoice = .mock
    @Environment(\.lang) private var lang
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // The title starts where the choices and Back do: 小方 beside it left the words indented from everything
            // below them. The state is the chip's.
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Self-test", lang: lang)).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Brand.ink)
                    Text(choice.real
                         ? L("Real run · the local model works in %@ inside a sandbox folder, never touching your files",
                             L(choice.app, lang: lang), lang: lang)
                         : L("Mock desktop · works on virtual windows in memory, never touching your files", lang: lang))
                        .font(.system(size: 12)).foregroundStyle(Brand.sage)
                }
                Spacer()
                StatusChip(run: run)
            }
            .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 16)

            // Choices: the mock set, or one real sandbox task.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([PlayChoice.mock] + PlayChoice.real) { c in
                        Button { choice = c } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L(c.title, lang: lang)).font(.system(size: 12, weight: .semibold, design: .rounded))
                                Text(L(c.app, lang: lang)).font(.system(size: 10))
                                    .foregroundStyle(choice == c ? Brand.paper.opacity(0.8) : Brand.sage)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(choice == c ? Brand.paper : Brand.ink)
                            .background(RoundedRectangle(cornerRadius: 10).fill(choice == c ? Brand.ink : Brand.card))
                        }
                        .buttonStyle(.plain)
                        .disabled(run.phase == .running || (c.real && !helper.brainReady))
                        .opacity(c.real && !helper.brainReady ? 0.45 : 1)
                        .help(c.real && !helper.brainReady ? L("The local model is still loading. One moment.", lang: lang)
                                                           : L(c.title, lang: lang))
                    }
                }
                .padding(.horizontal, 28)
            }
            .padding(.bottom, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        if run.tasks.isEmpty {
                            Text(run.phase == .running
                                 ? (choice.real ? L("Preparing the sandbox and starting the local model…", lang: lang)
                                                : L("Starting the Python runtime…", lang: lang))
                                 : L("Pick a task and click “Start”", lang: lang))
                                .font(.system(size: 13)).foregroundStyle(Brand.sage).padding(.top, 60)
                        }
                        ForEach(run.tasks) { TaskCard(task: $0).id($0.id) }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 12)
                }
                .onChange(of: run.tasks.last?.steps.count) { _, _ in
                    if let last = run.tasks.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            .frame(height: 420)

            RunFailure(run: run)

            HStack {
                Button(L("Back", lang: lang)) { onBack() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Brand.sage)
                    .disabled(run.phase == .running)
                Spacer()
                if run.phase == .running {
                    Button(L("Stop", lang: lang)) { run.stop() }.buttonStyle(InkButtonStyle(prominent: false))
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button(L(run.phase == .idle ? "Start" : "Run again", lang: lang)) { run.start(choice) }
                        .buttonStyle(InkButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
        }
        .frame(width: 560)
        .background(Brand.paper)
    }
}

/// A failed run in one sentence, with the raw text under "Details".
struct RunFailure: View {
    @ObservedObject var run: RunModel
    @Environment(\.lang) private var lang

    var body: some View {
        if !run.summary.isEmpty && run.phase == .failed {
            VStack(alignment: .leading, spacing: 4) {
                Text(run.summary).font(.system(size: 12, weight: .medium)).foregroundStyle(Brand.dot)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Report on GitHub", lang: lang)) {
                    let steps = run.tasks.flatMap { $0.steps.map(\.operation) }
                    if let url = IssueReport.url(kind: .error, goal: run.goalRequest?.goal ?? run.tasks.first?.title ?? "",
                                                 // The one-line summary, not the raw details: those hold paths with the user's name.
                                                 outcome: run.summary,
                                                 steps: steps,
                                                 appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                                                 macOS: ProcessInfo.processInfo.operatingSystemVersionString) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.ink).underline()
                .help(L("Opens a GitHub issue for you to check and submit. Nothing is sent from DeskMind.", lang: lang))
                if !run.rawError.isEmpty && run.rawError != run.summary {
                    DisclosureGroup(L("Details", lang: lang)) {
                        ScrollView { Text(run.rawError).font(.system(size: 10).monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 80)
                    }
                    .font(.system(size: 11)).foregroundStyle(Brand.sage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28)
        }
    }
}

/// Where the run is: not started, running (with the time), or how it ended.
struct StatusChip: View {
    @ObservedObject var run: RunModel
    @Environment(\.lang) private var lang

    var body: some View {
        let text: String = switch run.phase {
        case .idle: L("Not started", lang: lang)
        case .running: run.ask != nil ? L("Waiting for you", lang: lang) : L("Running %.1fs", run.elapsed, lang: lang)
        case .done: run.free ? L(run.result.passed > 0 ? "Finished" : "Not finished", lang: lang)
                             : L("%d/%d tasks passed", run.result.passed, run.result.total, lang: lang)
        case .failed: L("Not finished", lang: lang)
        }
        HStack(spacing: 6) {
            Circle().fill(run.phase == .running ? Brand.dot : (run.phase == .done ? Brand.ink : Brand.mist))
                .frame(width: 7, height: 7)
                .opacity(run.phase == .running ? (Int(run.elapsed * 2) % 2 == 0 ? 1 : 0.35) : 1)
            Text(text).font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Brand.ink)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Brand.card))
    }
}

struct TaskCard: View {
    let task: RunTask
    @Environment(\.lang) private var lang

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(task.title).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Brand.ink)
                    .lineLimit(2)
                if !task.free && task.id != "do" {
                    Text(task.id).font(.system(size: 10).monospaced()).foregroundStyle(Brand.mist)
                }
                Spacer()
                if let strict = task.strict {
                    HStack(spacing: 5) {
                        Circle().fill(strict ? Brand.dot : Brand.mist).frame(width: 7, height: 7)
                        Text(task.free ? L(strict ? "Finished" : "Not finished", lang: lang)
                                       : (strict ? L("Passed", lang: lang) : L("Failed", lang: lang))).font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Brand.ink)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(strict ? Brand.dot.opacity(0.1) : Brand.mist.opacity(0.25)))
                    .transition(.scale.combined(with: .opacity))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(task.steps) { s in
                    HStack(alignment: .center, spacing: 8) {
                        Text("\(s.n)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Brand.paper).frame(width: 16, height: 16)
                            .background(Circle().fill(s.ok ? Brand.ink : Brand.dot))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.human).font(.system(size: 13, design: .rounded)).foregroundStyle(Brand.ink)
                                .lineLimit(1)
                            Text(s.describe).font(.system(size: 10, design: .monospaced)).foregroundStyle(Brand.mist)
                                .lineLimit(1)
                            if !s.detail.isEmpty {
                                Text(s.detail).font(.system(size: 11)).foregroundStyle(Brand.sage).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        StepShot(path: s.shot)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            if task.free && task.strict != nil {
                FreeResult(task: task).transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.card)
            .shadow(color: Brand.ink.opacity(0.05), radius: 6, y: 2))
    }
}

/// The result of the user's own instruction: its answer, what changed in the attached folder, and the user's verdict
/// (there is no grader).
struct FreeResult: View {
    let task: RunTask
    @State private var sent = false
    @State private var verdict = ""
    /// The GitHub star line: offered once, on the first task that finished (once the window shows it), and after a 👍
    /// until the user has followed it once.
    @AppStorage("starNudge.seen") private var starSeen = false
    @AppStorage("starNudge.followed") private var starFollowed = false
    @State private var showStar = false
    @Environment(\.lang) private var lang

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Brand.line).frame(height: 1)
            if !task.answer.isEmpty {
                // A question's answer is the result: said first, large, and selectable to copy.
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Answer", lang: lang)).font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Brand.sage)
                    Text(task.answer).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(Brand.ink)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.dot.opacity(0.08)))
            }
            if task.folder != nil { changes }
            feedback
            if showStar { star.transition(.opacity) }
        }
        .onAppear {
            // Not while the window is aside: the line was used up by a result nobody saw.
            if task.strict == true && !starSeen && !MainWindow.isAside { starSeen = true; showStar = true }
        }
    }

    /// A link to DeskMind's main repository (every star ask points there), nothing sent: the user's browser opens it.
    @ViewBuilder var star: some View {
        HStack(spacing: 8) {
            Text(L("Found it useful? Star DeskMind on GitHub.", lang: lang))
                .font(.system(size: 12, design: .rounded)).foregroundStyle(Brand.sage)
            Spacer()
            Button(L("Star on GitHub", lang: lang)) {
                starFollowed = true
                NSWorkspace.shared.open(URL(string: IssueReport.repo)!)
                withAnimation(.easeOut(duration: 0.2)) { showStar = false }
            }
            .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.ink).underline()
            Button { withAnimation(.easeOut(duration: 0.2)) { showStar = false } } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.mist)
            }
            .buttonStyle(.plain).help(L("Don't show again", lang: lang))
        }
    }

    /// What changed in the attached folder. A run with no folder changed no files, and says nothing about them.
    @ViewBuilder var changes: some View {
        VStack(alignment: .leading, spacing: 8) {
            let groups = Self.groups(task).filter { !$0.1.isEmpty }
            if groups.isEmpty {
                Text(L("No files changed", lang: lang)).font(.system(size: 12)).foregroundStyle(Brand.sage)
            } else {
                ForEach(groups, id: \.0) { name, files in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(L(name, lang: lang)).font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Brand.sage).frame(width: 72, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(files, id: \.self) { f in
                                Text(f).font(.system(size: 12).monospaced()).foregroundStyle(Brand.ink)
                                    .strikethrough(name == "Deleted", color: Brand.mist)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            Button(L("Show in Finder", lang: lang)) { showInFinder() }
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.ink).underline()
        }
    }

    /// 👍/👎, kept on this Mac. A 👎 asks what went wrong and offers a GitHub issue filled in with the run (opened in
    /// the browser for the user to check and submit; nothing is sent from here) -- "it guessed instead of asking" is
    /// the report the next training round needs. A 👍 offers the star line.
    @ViewBuilder var feedback: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(!sent ? L("Did it do what you asked?", lang: lang)
                     : verdict == "down" ? L("What went wrong?", lang: lang) : L("Saved on this Mac.", lang: lang))
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(Brand.sage)
                Spacer()
                ForEach(["up", "down"], id: \.self) { v in
                    Button { record(v) } label: {
                        Text(v == "up" ? "👍" : "👎").font(.system(size: 14))
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Capsule().fill(Brand.paper))
                            .overlay(Capsule().strokeBorder(verdict == v ? Brand.ink : Brand.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(sent)
                    .opacity(sent && verdict != v ? 0.45 : 1)
                    .accessibilityLabel(v == "up" ? L("It did what I asked", lang: lang) : L("It didn't do what I asked", lang: lang))
                }
            }
            if verdict == "down" {
                HStack(spacing: 6) {
                    ForEach([IssueReport.Kind.guessed, .wrong, .stuck], id: \.self) { k in
                        Button(L(k.label, lang: lang)) { report(k) }.buttonStyle(InkButtonStyle(prominent: false))
                    }
                }
                Text(L("Opens a GitHub issue for you to check and submit. Nothing is sent from DeskMind.", lang: lang))
                    .font(.system(size: 11)).foregroundStyle(Brand.sage)
            }
        }
    }

    private func report(_ kind: IssueReport.Kind) {
        // How it ended, in DeskMind's words only: the answer itself was read from the screen, and stays out.
        let outcome = !task.answer.isEmpty ? "It gave an answer."
            : (task.strict == true ? "It said it finished." : "It stopped before finishing.")
            + (task.folder == nil ? "" : " Files: \(task.created.count) created, \(task.modified.count) modified, \(task.deleted.count) deleted.")
        if let url = IssueReport.url(kind: kind, goal: task.title, outcome: outcome, steps: task.steps.map(\.operation),
                                     appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                                     macOS: ProcessInfo.processInfo.operatingSystemVersionString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// The change report lists files only, so a move is one deletion plus one creation, and a new folder shows
    /// only through the files in it. Pair them up again: same file name gone from one place and new in another is
    /// a move; a folder of a new file that held nothing before is a new folder.
    static func groups(_ task: RunTask) -> [(String, [String])] {
        var created = task.created, deleted = task.deleted
        var moved: [String] = []
        for d in task.deleted {
            let name = (d as NSString).lastPathComponent
            if let i = created.firstIndex(where: { ($0 as NSString).lastPathComponent == name }) {
                moved.append("\(d) → \(created[i])")
                created.remove(at: i); deleted.removeAll { $0 == d }
            }
        }
        // What is left: one file gone and one new in the same folder is a rename (the change report cannot tell,
        // it compares names only; with more than one of each, pairing them would be a guess).
        var renamed: [String] = []
        for dir in Set(deleted.map { ($0 as NSString).deletingLastPathComponent }) {
            let gone = deleted.filter { ($0 as NSString).deletingLastPathComponent == dir }
            let new = created.filter { ($0 as NSString).deletingLastPathComponent == dir }
            if gone.count == 1 && new.count == 1 {
                renamed.append("\(gone[0]) → \(new[0])")
                deleted.removeAll { $0 == gone[0] }; created.removeAll { $0 == new[0] }
            }
        }
        let before = Set((task.deleted + task.modified).map { ($0 as NSString).deletingLastPathComponent })
        var folders: [String] = []
        for f in task.created {
            var dir = (f as NSString).deletingLastPathComponent
            while !dir.isEmpty && !before.contains(dir) {
                if !folders.contains(dir + "/") { folders.append(dir + "/") }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        return [("New folder", folders.sorted()), ("Moved", moved), ("Renamed", renamed), ("Created", created),
                ("Modified", task.modified), ("Deleted", deleted)]
    }

    /// Select what it made or changed, when those are still there; otherwise just open the folder.
    private func showInFinder() {
        guard let folder = task.folder else { return }
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        let touched = (task.created + task.modified).map { dir.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(touched.isEmpty ? [dir] : touched)
    }

    /// One JSON line per verdict, kept on this Mac.
    private func record(_ verdict: String) {
        let row: [String: Any] = ["t": Int(Date().timeIntervalSince1970), "goal": task.title, "verdict": verdict,
                                  "answer": task.answer, "folder": task.folder != nil,
                                  "created": task.created, "modified": task.modified, "deleted": task.deleted]
        let dir = DeskMindIPC.supportDir
        let url = dir.appendingPathComponent("feedback.jsonl")
        guard var line = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
        withAnimation(.easeOut(duration: 0.2)) {
            sent = true; self.verdict = verdict
            if verdict == "up" && !starFollowed { showStar = true }
        }
    }
}

/// What the agent was looking at when it chose this step: a thumbnail, larger on click.
struct StepShot: View {
    let path: String
    @State private var image: NSImage?
    @State private var open = false
    @Environment(\.lang) private var lang

    var body: some View {
        Group {
            if let image {
                // Anchored top-left: that is where a window's content starts (a TextEdit page, a Finder list);
                // centred, most thumbnails were blank paper.
                Image(nsImage: image).resizable().interpolation(.medium).scaledToFill()
                    .frame(width: 64, height: 40, alignment: .topLeading).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Brand.line, lineWidth: 1))
                    .onTapGesture { open = true }
                    .popover(isPresented: $open, arrowEdge: .leading) {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                            .frame(maxWidth: 720, maxHeight: 480).padding(8)
                    }
                    .help(L("What it saw at this step (click to enlarge)", lang: lang))
            } else {
                Color.clear.frame(width: 64, height: 40)
            }
        }
        .task(id: path) {
            guard !path.isEmpty else { return }
            // The file is written a moment before the step is announced; give it a few tries.
            for _ in 0..<10 {
                if let img = NSImage(contentsOfFile: path) { image = img; return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
}
