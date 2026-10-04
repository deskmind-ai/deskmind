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
    @State private var started = false
    @State private var confirming: GoalRequest?
    @State private var replaying = false
    @State private var gifNote = ""
    /// The finished run's frames, worked out once when it ends (each is a file check).
    @State private var frames: [ReplayFrame] = []
    @State private var exporting = false

    private func refreshFrames(_ p: RunModel.Phase) {
        frames = p == .done || p == .failed ? Replay.frames(run.tasks.flatMap(\.steps)) : []
    }
    @State private var next = ""
    /// The folder the next instruction runs in: this run's, unless the user takes it off.
    @State private var nextFolder: String??
    @Environment(\.lang) private var lang

    private var goal: String { request?.goal ?? record?.goal ?? "" }
    private var folder: String? { request != nil ? request?.folder : record?.folder }
    private var apps: [ResolvedApp] {
        if let request { return request.displayApps }
        let a = (record?.apps ?? []).map(\.resolved)
        return a.isEmpty ? [AppScope.finder] : a
    }

    var mood: Brand.Mood {
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
                StatusChip(run: run)
            }
            .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 14)

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

            if run.phase == .running && (run.waitingForUser || RunOverlay.shared.model.takenOver) {
                WaitingCard(what: run.waitingWhat)
                    .padding(.horizontal, 28).padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let ask = run.ask {
                AskCard(ask: ask) { reply, approve in run.answer(reply, approve: approve) }
                    .padding(.horizontal, 28).padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            RunFailure(run: run)

            if let movie = run.movie {
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

            if run.phase == .done || run.phase == .failed {
                // What it did, from its step screenshots: replayed here, or as a GIF to share (no recording needed).
                if !frames.isEmpty {
                    HStack(spacing: 10) {
                        Button { refreshFrames(run.phase); replaying = !frames.isEmpty } label: { Label(L("Replay", lang: lang), systemImage: "play.fill") }
                            .buttonStyle(InkButtonStyle(prominent: false))
                        Button(L("Export GIF", lang: lang)) {
                            // Off the main thread: up to 17 frames to decode and draw.
                            refreshFrames(run.phase)   // screenshots may have been cleared since the run ended
                            guard !frames.isEmpty else { return }
                            exporting = true; gifNote = L("Making the GIF…", lang: lang)
                            let (title, all, lang) = (goal, frames, lang)
                            Task.detached {
                                let url = ReplayGIF.exportGIF(title: title, frames: all, lang: lang)
                                await MainActor.run {
                                    exporting = false
                                    if let url {
                                        gifNote = L("Saved in Movies › DeskMind", lang: lang)
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    } else {
                                        gifNote = L("Couldn't make the GIF", lang: lang)
                                    }
                                }
                            }
                        }
                        .buttonStyle(InkButtonStyle(prominent: false))
                        .disabled(exporting)
                        if !gifNote.isEmpty { Text(gifNote).font(.system(size: 11)).foregroundStyle(Brand.sage) }
                        Spacer()
                    }
                    .padding(.horizontal, 28).padding(.bottom, 4)
                    .sheet(isPresented: $replaying) {
                        ReplayView(title: goal, frames: frames) { replaying = false }.environment(\.lang, lang)
                    }
                }
                nextPrompt.padding(.horizontal, 28).padding(.top, 4)
            }

            HStack {
                Button(L("Back", lang: lang)) { onBack() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Brand.sage)
                    .disabled(run.phase == .running || run.pickingRecording)
                Spacer()
                if run.phase == .running {
                    Button(L("Stop", lang: lang)) { run.stop() }.buttonStyle(InkButtonStyle(prominent: false))
                        .keyboardShortcut(".", modifiers: .command)
                } else if run.pickingRecording {
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
            if let request { begin(request) } else if let record { run.show(record) }
            refreshFrames(run.phase)
        }
        .onChange(of: run.phase) { _, p in refreshFrames(p) }
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
    private var nextApps: [ResolvedApp] { AppScope.resolve(nextTrimmed) }
    private var nextNeedsApp: Bool { !nextTrimmed.isEmpty && nextApps.isEmpty && carriedFolder == nil }
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
        run.goalRequest = r
        run.start(request: r.body)
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
    let send: (String, Bool) -> Void
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
            if ask.approval {
                HStack {
                    Spacer()
                    // No words with a verdict: hands tells the planner "approved" or "denied" itself.
                    Button(L("Deny", lang: lang)) { send("", false) }
                        .buttonStyle(InkButtonStyle(prominent: false))
                    Button(L("Approve", lang: lang)) { send("", true) }
                        .buttonStyle(InkButtonStyle())
                }
            } else {
                // The alternatives the question lists, one click each: the D4 shoot had the answer typed out in full.
                ForEach(ask.options, id: \.self) { option in
                    Button { send(option, true) } label: {
                        Text(option).font(.system(size: 13, design: .monospaced)).foregroundStyle(Brand.ink)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.paper))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Brand.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Use %@", option, lang: lang))
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
        send(r, true)
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
