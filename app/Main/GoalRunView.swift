// One run of the user's own instruction, from the home screen: its steps as they happen, the question it may stop
// to ask (AskCard), and how it ended -- the answer for a question, the change list for a folder task. A past run from
// the recent list opens here too, as it ended. Once it has ended, the next instruction can be typed right here.

import SwiftUI

struct GoalRunView: View {
    /// A new run to start, or nil when showing `record`.
    let request: GoalRequest?
    var record: RunRecord? = nil
    let onBack: () -> Void
    /// Put the instruction back in the home screen's prompt, to change it and run it again.
    var onEdit: (GoalRequest) -> Void = { _ in }
    /// Start another run (confirmed): "Run again", or the next instruction typed below the result.
    var onRun: (GoalRequest) -> Void = { _ in }

    @EnvironmentObject var model: HelperModel
    @EnvironmentObject var eyes: EyesDownloader
    @StateObject private var run = RunModel()
    /// A harness-engine goal runs as a session task (M2: one result card for every surface): the app's one ShellModel,
    /// its new session selected; the task shows with the chat's TaskRow / CardView / ResultSection.
    @ObservedObject private var shell = ShellModel.live
    @State private var sessionRun = false
    @State private var sessionRecorded = false
    @State private var sessionMovie: URL?
    @State private var pickingRecording = false
    /// A past session task opened from the recent runs (or the island's Show Details): its run; nil — the newest.
    @State private var focusRun: String?
    /// The session task's island and notifications (IslandFeed's frames applied to RunOverlay); nil for a past one.
    @State private var island: SessionIsland?
    @State private var recordID: UUID?

    /// The session task shown: the selected session's run `focusRun`, else its newest.
    private var goalTask: (session: SessionState, task: TaskState)? {
        guard let s = shell.current else { return nil }
        if let r = focusRun { return s.task(r).map { (s, $0) } }
        return s.tasks.last.map { (s, $0) }
    }

    /// The island's frame for it, from its one state (IslandFeed).
    private var islandFrame: IslandFrame? {
        guard let (s, t) = goalTask else { return nil }
        let p = shell.pinned(s).map { (card: $0.card, phase: $0.phase) }
        return IslandFeed.frame(t, pinned: p, lang: ResolvedLang.current)
    }
    @State private var started = false
    @State private var confirming: GoalRequest?
    @State private var next = ""
    /// The folder the next instruction runs in: this run's, unless the user takes it off.
    @State private var nextFolder: String??
    @Environment(\.lang) private var lang

    private var goal: String { request?.goal ?? record?.goal ?? "" }
    private var folder: String? { request != nil ? request?.folder : record?.folder }
    private var apps: [ResolvedApp] {
        if let request { return request.displayApps }
        let a = (record?.apps ?? []).map(\.resolved)
        return a.isEmpty && !GoalRequest.harnessEngine ? [AppScope.finder] : a
    }

    var mood: Brand.Mood {
        if sessionRun {
            guard let (s, t) = goalTask else { return .idle }
            if shell.pinned(s) != nil { return .notice }
            if t.running { return .idle }
            return t.status == "succeeded" ? .done : .notice
        }
        switch run.phase {
        case .done: return run.result.passed > 0 ? .done : .notice
        case .failed: return .notice
        case .running: return run.ask != nil ? .notice : .idle
        case .idle: return .rest
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                XiaoFang(mood: mood, size: 56)
                VStack(alignment: .leading, spacing: 6) {
                    Text(goal).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(Brand.ink)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    RunScope(apps: apps, folder: folder)
                    if let record {
                        Text(record.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11)).foregroundStyle(Brand.mist)
                    }
                }
                Spacer(minLength: 8)
                if sessionRun {
                    if let (_, t) = goalTask {
                        Text(ShellText.task(t, lang: lang)).font(.system(size: 11, weight: .semibold)).foregroundStyle(ShellColor.secondary)
                    }
                } else {
                    StatusChip(run: run)
                }
            }
            .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 14)

            if sessionRun {
                sessionContent.frame(maxHeight: .infinity)
            } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 10) {
                        if run.tasks.isEmpty {
                            Text(placeholder).font(.system(size: 13)).foregroundStyle(Brand.sage).padding(.top, 60)
                        }
                        ForEach(run.tasks) { TaskCard(task: $0).id($0.id) }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 12)
                }
                .onChange(of: run.tasks.last?.steps.count) { _, _ in
                    if let last = run.tasks.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                // The result (answer, change list, verdict buttons) lands below the steps: bring it into view.
                .onChange(of: run.tasks.last?.strict) { _, _ in
                    if let last = run.tasks.last {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            }

            if !sessionRun && run.phase == .running && (run.waitingForUser || RunOverlay.shared.model.takenOver) {
                WaitingCard(what: run.waitingWhat)
                    .padding(.horizontal, 28).padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !sessionRun, let ask = run.ask {
                AskCard(ask: ask) { button in run.answer(button) }
                    .padding(.horizontal, 28).padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !sessionRun { RunFailure(run: run) }

            if let movie = sessionRun ? sessionMovie : run.movie {
                HStack(spacing: 10) {
                    Image(systemName: "record.circle").foregroundStyle(Brand.dot)
                    Text(L("Recorded", lang: lang)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.ink)
                    Spacer()
                    Button(L("Watch", lang: lang)) { NSWorkspace.shared.open(movie) }.buttonStyle(InkButtonStyle(prominent: false))
                    Button(L("Show in Finder", lang: lang)) { NSWorkspace.shared.activateFileViewerSelecting([movie]) }
                        .buttonStyle(InkButtonStyle(prominent: false))
                }
                .padding(.horizontal, 28).padding(.bottom, 6)
            }

            if ended {
                nextPrompt.padding(.horizontal, 28).padding(.top, 4)
            }

            HStack {
                Button(L("Back", lang: lang)) { onBack() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Brand.sage)
                    .disabled(running || run.pickingRecording || pickingRecording)
                Spacer()
                if running {
                    Button(L("Stop", lang: lang)) { if sessionRun { shell.stop() } else { run.stop() } }.buttonStyle(InkButtonStyle(prominent: false))
                        .keyboardShortcut(".", modifiers: .command)
                } else if run.pickingRecording || pickingRecording {
                    EmptyView()
                } else if let request {
                    Button(L("Edit", lang: lang)) { onEdit(request) }.buttonStyle(InkButtonStyle(prominent: false))
                    // Through the confirmation like any start: the record choice and the approvals are offered again.
                    Button(L("Run again", lang: lang)) {
                        confirming = GoalRequest(goal: request.goal, folder: request.folder, apps: request.apps)
                    }
                    .buttonStyle(InkButtonStyle())
                } else if let record {
                    // A past run goes back through the home screen (and its confirmation): the apps may have changed.
                    Button(L("Use this instruction", lang: lang)) {
                        onEdit(GoalRequest(goal: record.goal, folder: record.folder, apps: record.apps.map(\.resolved)))
                    }
                    .buttonStyle(InkButtonStyle())
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 20)
        }
        .frame(width: 560, height: 720)
        .background(Brand.paper)
        .onAppear {
            guard !started else { return }
            started = true
            if let request { begin(request) }
            else if let record, let sid = record.sessionId {
                // a session task kept in the recent runs: shown as the session has it (its result card included)
                sessionRun = true; sessionRecorded = true; focusRun = record.runId
                shell.start(); shell.select(sid)
            }
            else if let record { run.show(record) }
        }
        // the island and the notifications follow the session task's state (one adapter, no second state)
        .onChange(of: islandFrame) { _, f in if let f, let island { island.apply(f, title: goal, onStop: { shell.stop() }) } }
        // a session task that ended: kept in the recent runs (once), its recording finished
        .onChange(of: goalTask?.task.ended) { _, ended in if sessionRun, ended == true { sessionEnded() } }
        .sheet(item: $confirming) { r in
            ConfirmSheet(request: r, onStart: { record in
                confirming = nil
                var r = r
                r.record = record
                onRun(r)
            }, onCancel: { confirming = nil })
            // Said explicitly: a sheet is its own window, and not every macOS passed the environment down to it.
            .environmentObject(eyes).environmentObject(model).environment(\.lang, lang)
        }
    }

    private var placeholder: String {
        if run.pickingRecording { return L("Starting the recording…", lang: lang) }
        if run.phase == .running {
            // Which stage, for how long: a bare "starting…" for half a minute read as frozen.
            let stage = run.stage ?? (run.preparing == "eyes" ? .eyes : .starting)
            return stage.line(seconds: Int(Date().timeIntervalSince(run.stageSince)), typical: RunModel.typical(stage),
                              lang: lang)
        }
        return run.phase == .failed ? "" : L("No steps", lang: lang)
    }

    // MARK: the next instruction

    private var nextTrimmed: String { next.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var carriedFolder: String? { nextFolder ?? folder }
    /// The old engine only: under the new one the runtime decides which apps to use (owner, 10-20).
    private var nextApps: [ResolvedApp] { GoalRequest.harnessEngine ? [] : AppScope.resolve(nextTrimmed) }
    private var nextNeedsApp: Bool { !GoalRequest.harnessEngine && !nextTrimmed.isEmpty && nextApps.isEmpty && carriedFolder == nil }
    private var canStartNext: Bool { !nextTrimmed.isEmpty && !nextNeedsApp && model.requiredDone }

    /// After a run: the next instruction, in the same folder unless it is taken off, without going back home first.
    @ViewBuilder private var nextPrompt: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField(L("Next task…", lang: lang), text: $next)
                    .textFieldStyle(.plain).font(.system(size: 13, design: .rounded)).foregroundStyle(Brand.ink)
                    .onSubmit(startNext)
                if let f = carriedFolder {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill").font(.system(size: 10)).foregroundStyle(Brand.sage)
                        Text((f as NSString).lastPathComponent).font(.system(size: 11).monospaced()).foregroundStyle(Brand.ink)
                            .lineLimit(1)
                        Button { nextFolder = .some(nil) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Brand.mist)
                        }
                        .buttonStyle(.plain).help(L("Remove the folder", lang: lang))
                        .accessibilityLabel(L("Remove the folder", lang: lang))
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Brand.paper))
                }
                Button(L("Start", lang: lang), action: startNext).buttonStyle(InkButtonStyle())
                    .disabled(!canStartNext).opacity(canStartNext ? 1 : 0.45)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.line, lineWidth: 1))
            if nextNeedsApp {
                Text(L("Which app should it use? Name it in the instruction, or attach a folder.", lang: lang))
                    .font(.system(size: 11)).foregroundStyle(Brand.dot)
            }
        }
    }

    private func startNext() {
        guard canStartNext else { return }
        let r = GoalRequest(goal: nextTrimmed, folder: carriedFolder, apps: nextApps)
        if ConfirmSheet.canSkip(r) { next = ""; onRun(r) } else { confirming = r }
    }

    private func begin(_ r: GoalRequest) {
        // the harness engine: a session task (the chat's); the old engine (hands) keeps its own run
        if r.harness {
            sessionRun = true
            island = SessionIsland()
            shell.start()
            guard r.record else { shell.startTask(r.goal, scope: r.folder); return }
            pickingRecording = true
            RunRecorder.shared.begin(goal: r.goal, bundles: []) { _ in
                pickingRecording = false
                shell.startTask(r.goal, scope: r.folder)
            }
            return
        }
        run.goalRequest = r
        run.start(request: r.body)
    }

    /// (the session opening counts as running; not opened — the helper down, cloud off — it does not: Back works)
    private var running: Bool { sessionRun ? (goalTask?.task.running ?? (shell.opening || pickingRecording)) : run.phase == .running }
    private var ended: Bool { sessionRun ? (goalTask?.task.ended ?? false) : (run.phase == .done || run.phase == .failed) }

    /// The session task as the chat shows it: its row (steps, cards that are no longer pinned, its end, its result
    /// card with undo — ResultSection), the pinned card, and — once it ended — the answer, the changes and 👍👎.
    @ViewBuilder private var sessionContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let (s, t) = goalTask {
                    TaskRow(shell: shell, task: t, session: s)
                    if t.ended { FreeResult(task: Self.runTask(t, folder: request?.folder)) }
                } else {
                    Text(shell.notice ?? (pickingRecording ? L("Starting the recording…", lang: lang) : L("Getting ready…", lang: lang)))
                        .font(.system(size: 13)).foregroundStyle(ShellColor.secondary).padding(.top, 60)
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 12)
        }
        if let s = shell.current, let p = shell.pinned(s) {
            let m = CardModel(card: p.card.card, runId: p.runId, askId: p.card.askId)
            CardView(shell: shell, card: m, phase: p.phase, askedAt: p.card.askedAt, session: s, bodyCap: CardBody.maxHeight)
                .id(ShellModel.cardKey(m))
                .padding(.horizontal, 28).padding(.bottom, 10)
        }
    }

    /// What FreeResult reads of an ended session task (its answer, its changes): display only — the result card is
    /// TaskRow's, from the session's state.
    static func runTask(_ t: TaskState, folder: String?) -> RunTask {
        var r = RunTask(id: t.runId, title: t.raw)
        r.free = true
        r.strict = t.status == "succeeded"
        r.folder = folder
        r.answer = t.answer ?? ""
        r.created = t.changes.created; r.modified = t.changes.modified; r.deleted = t.changes.deleted
        r.steps = t.steps.map { RunStep(n: $0.n, human: $0.displayText, app: "", shot: $0.shot ?? "", describe: $0.text, detail: $0.why ?? "", ok: $0.status == .ok) }
        return r
    }

    private func sessionEnded() {
        guard !sessionRecorded, let r = request, let (_, t) = goalTask else { return }
        sessionRecorded = true
        let id = UUID()
        recordID = id
        // the island's Show Details opens this task's GoalRunView (its record keeps the session and the run)
        RunOverlay.shared.detailsRecord = id
        RunHistory.shared.add(RunRecord(
            id: id, date: Date(), goal: r.goal, folder: r.folder, apps: [],
            finished: t.status == "succeeded", errored: t.status == nil || t.status == "failed",
            summary: ShellText.task(t, lang: lang), answer: t.answer ?? "",
            steps: t.steps.map { RunRecord.Step(n: $0.n, human: $0.displayText, app: "", shot: $0.shot ?? "", describe: $0.text, detail: $0.why ?? "", ok: $0.status == .ok) },
            created: t.changes.created, modified: t.changes.modified, deleted: t.changes.deleted,
            sessionId: shell.selected, runId: t.runId))
        if r.record {
            RunRecorder.shared.stop { url in
                sessionMovie = url
                if let url { RunHistory.shared.setMovie(url.path, for: id) }
            }
        }
    }
}

/// The apps a run uses (icon and name) and its folder, or that it has none.
struct RunScope: View {
    let apps: [ResolvedApp]
    let folder: String?
    @Environment(\.lang) private var lang

    var body: some View {
        HStack(spacing: 10) {
            ForEach(apps, id: \.bundleID) { a in
                HStack(spacing: 4) {
                    Image(nsImage: a.icon).resizable().frame(width: 16, height: 16)
                    Text(a.displayName(lang)).font(.system(size: 11, weight: .medium)).foregroundStyle(Brand.ink)
                }
            }
            HStack(spacing: 4) {
                Image(systemName: folder == nil ? "folder.badge.minus" : "folder").font(.system(size: 11))
                    .foregroundStyle(Brand.sage)
                Text(folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? L("No folder", lang: lang))
                    .font(.system(size: 11).monospaced()).foregroundStyle(Brand.sage)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }
}

/// The task stopped to ask something: a question to answer in words, or an action to approve before it happens
/// (sending a message, paying, deleting, publishing). It waits up to ten minutes, then carries on without an answer.
struct AskCard: View {
    let ask: PendingAsk
    /// Which button was used: each sends itself (HarnessEvents.CardButton), whatever the card's kind.
    let send: (HarnessEvents.CardButton) -> Void
    @State private var reply = ""
    @FocusState private var focused: Bool
    @Environment(\.lang) private var lang

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: ask.approval ? "hand.raised.fill" : "questionmark.bubble.fill").foregroundStyle(Brand.dot)
                Text(ask.approval ? L("DeskMind needs your approval", lang: lang) : L("DeskMind has a question", lang: lang))
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Brand.ink)
            }
            Text(ask.question).font(.system(size: 14, design: .rounded)).foregroundStyle(Brand.ink)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            let buttons = HarnessEvents.buttons(approval: ask.approval, options: ask.options)
            if ask.approval {
                HStack {
                    Spacer()
                    // No words with a verdict: hands tells the planner "approved" or "denied" itself.
                    ForEach(buttons, id: \.self) { b in
                        Button(b == .approve ? L("Approve", lang: lang) : L("Deny", lang: lang)) { send(b) }
                            .buttonStyle(InkButtonStyle(prominent: b == .approve))
                    }
                }
            } else {
                // The alternatives the question lists, one click each: the D4 shoot had the answer typed out in full.
                // Each sends its own option (deskmind#102: they all used to be sent as "approve").
                ForEach(buttons, id: \.self) { b in
                    if case .option(_, let option) = b {
                        Button { send(b) } label: {
                            Text(option).font(.system(size: 13, design: .monospaced)).foregroundStyle(Brand.ink)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.paper))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Brand.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("Use %@", option, lang: lang))
                    }
                }
                HStack(spacing: 8) {
                    TextField(L(ask.options.isEmpty ? "Your answer" : "Or type an answer", lang: lang), text: $reply)
                        .textFieldStyle(.plain).font(.system(size: 13, design: .rounded))
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.paper))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Brand.line, lineWidth: 1))
                        .focused($focused)
                        .onSubmit(submit)
                    Button(L("Send", lang: lang), action: submit).buttonStyle(InkButtonStyle())
                        .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.card)
            .shadow(color: Brand.ink.opacity(0.08), radius: 8, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.dot.opacity(0.5), lineWidth: 1))
        // The field takes the keys only when DeskMind is the active app and the user is not typing elsewhere: their
        // keys meant for another app must not become the answer.
        .onAppear { focused = !ask.approval && NSApp.isActive && !MainWindow.userTypedRecently() }
    }

    private func submit() {
        let r = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return }
        send(.words(r))
        reply = ""
    }
}

/// Shown while a step needs the screen and the user is using it: what it will do next, and the choice -- it goes
/// ahead after a short countdown unless the user keeps the Mac for 5 minutes. Without it a paused run showed only a
/// spinner and read as frozen.
struct WaitingCard: View {
    let what: String
    @Environment(\.lang) private var lang
    @ObservedObject private var overlay = RunOverlay.shared.model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: overlay.takenOver ? "cursorarrow.motionlines" : "hand.raised.fill")
                .font(.system(size: 18)).foregroundStyle(Brand.dot)
            VStack(alignment: .leading, spacing: 4) {
                Text(ScreenShareButtons.status(overlay, lang: lang) ?? L("DeskMind needs the screen for a moment", lang: lang))
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Brand.ink)
                if !what.isEmpty {
                    Text(L("Next: %@", what, lang: lang)).font(.system(size: 12)).foregroundStyle(Brand.sage)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L("This app only responds when it is in front. DeskMind brings it forward for a second or two per step and then gives your app back.", lang: lang))
                    .font(.system(size: 11)).foregroundStyle(Brand.sage).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            ScreenShareButtons(model: overlay)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.dot.opacity(0.4), lineWidth: 1))
    }
}
