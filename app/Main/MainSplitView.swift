// The 0.5 main window (M1 S3, behind `ui05.shell`): three columns — the conversations, the chat, and the right column
// (a placeholder until M3: 小方 and the session's state). Its logic is ShellModel (Shared/Shell.swift); these are
// views only.
//
// Focus (handoff §3.1): nothing here activates the app or brings a window forward. Only the user's own clicks and
// keys act; the composer never takes the keyboard by itself when a card arrives, and nothing here ever moves the
// keyboard focus by itself — no defaultFocus, no makeFirstResponder (ShellTests checks this file): a card that arrives
// while the user types must never get the typing (its own field's Return would send it as the answer). The one focus
// move is the user's own: Esc out of a card in card mode puts the typing back in the composer (ShellModel.focusRequest,
// taken once by Composer: its one @FocusState, the only one the check allows).

import AppKit
import Combine
import SwiftUI

/// The handoff's text colours (§3.10): secondary text and orange text at 4.5:1 or better on paper.
enum ShellColor {
    static let secondary = Color(ShellPalette.secondary)
    static let orangeText = Color(ShellPalette.orangeText)
    static let panel = Color(ShellPalette.panel)
    static let panelSelected = Color(ShellPalette.panelSelected)
    static let banner = Color(ShellPalette.banner)
    static let problem = Color(ShellPalette.problem)
    static let error = Color(ShellPalette.error)
}

struct MainSplitView: View {
    @ObservedObject var shell: ShellModel

    @EnvironmentObject var model: HelperModel
    @Environment(\.lang) private var lang
    @State private var settingsOpen = false

    var body: some View {
        NavigationSplitView {
            SessionList(shell: shell)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            HStack(spacing: 0) {
                ChatColumn(shell: shell, openSettings: openSettings)
                    .frame(minWidth: 420, maxWidth: .infinity)
                Divider()
                AgentPanel(shell: shell)
                    .frame(width: 260)
            }
        }
        .frame(minWidth: 980, idealWidth: 1180, minHeight: 600, idealHeight: 760)
        .background(Brand.paper)
        .sheet(isPresented: $settingsOpen, onDismiss: settingsClosed) {
            CloudModelSheet(inShell: true).environmentObject(model).environment(\.lang, lang)
        }
        .onAppear {
            ShellModel.shared = shell
            shell.refreshSettings()
            // what was saved while this window was not shown (the window as it was, before this launch): told now,
            // before the watch (ShellModel.syncSettings; #107 review at 5999bd9)
            shell.syncSettings()
            shell.start()
        }
        .onChange(of: lang) { _, _ in shell.syncSettings() }     // (the language is a session setting like the model's)
        // the float, the island and the notifications: the app's one, started once, whatever the window does
        .onAppear { FloatController.shared.start(shell) }
    }

    /// The key file (keys, a custom service's URL and model): a session process reads it when it starts, so only a
    /// change here needs a new process (set_config carries the rest in place). The shell keeps what it last gave
    /// (ShellModel.keyFile, syncSettings).
    static func envFingerprint() -> String {
        ModelKeys.fingerprint(CloudModelSettings.read())
    }

    private func openSettings() { settingsOpen = true }

    /// The sheet's Save already told the shell (ModelSettingsSaved); this compares again, and acts only on what it has
    /// not given its sessions yet (never a second restart for the same save: #107 review at 5999bd9).
    private func settingsClosed() {
        model.refreshCloud()
        shell.syncSettings()
    }

    /// The configuration sessions open with: the one the settings saved, else the chosen service's.
    static func modelConfig() -> String {
        // (as the harness reads it: a model name saved with spaces around it by an older version, without them)
        if let c = CloudModelSettings.engineConfig, !c.isEmpty { return SessionClient.normalizeConfig(c) }
        let p = CloudModelSettings.provider
        return SessionClient.normalizeConfig(CloudModelSettings.config(for: p, model: CloudModelSettings.read()["CUSTOM_MODEL"] ?? ""))
    }
}

extension ShellModel {
    /// The app's one: the helper's sessions, opened with the model settings and the UI language as they are.
    static let live: ShellModel = {
        let transport = StoppableTransport(HelperSessionTransport())
        // the language as the setting has it now (not ResolvedLang.current, which the window updates in its own time)
        // (the app's one ModelsOffSync: the engine setter and the helper's connect push through the same one)
        let m = ShellModel(client: SessionClient(transport: transport, modelsSync: .shared), config: { MainSplitView.modelConfig() },
                           lang: { AppLanguage.current() },
                           cloudOn: { CloudModelSettings.engineIsCloud },
                           // every save of the model settings, from whichever window (ModelSettingsSaved), while the app runs
                           keyFile: { MainSplitView.envFingerprint() }, savedSettings: .default,
                           // a new key's asks the helper did not take: tried again on the main queue's clock
                           retryAfter: { delay, f in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: f) },
                           // steer and answer lines: one after another, in the order they were put in (A9)
                           lane: ShellModel.serialLane())
        transport.isStopped = { [weak m] in m?.stopped ?? true }
        m.client.liveView = false      // (the window draws the float itself: the helper starts no live card for its tasks)
        m.uiWindow = { MainActor.assumeIsolated { MainWindow.uiState() } }   // (read where flush runs: the main queue)
        // a task ended here: the run records' rule (M5: 30 days / 1 GB), off the main queue, the live runs kept
        m.onTaskEnded = { [weak m] in
            let live = m?.liveRuns ?? []
            DispatchQueue.global(qos: .utility).async { RunRetention.prune(live: live) }
        }
        return m
    }()
}

/// The 0.5 window's menu keys (handoff §3.7): ⌘N, ⌘., ⌘↑ ⌘↓.
struct ShellCommands: Commands {
    let lang: ResolvedLang
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("New Conversation", lang: lang)) { ShellModel.shared?.newConversation() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu(L("Conversation", lang: lang)) {
            Button(L("Stop", lang: lang)) { ShellModel.shared?.stop() }
                .keyboardShortcut(".", modifiers: .command)
            Button(L("Pop Out the Live View", lang: lang)) { ShellModel.shared?.togglePopOut() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button(L("Previous Conversation", lang: lang)) { ShellModel.shared?.move(-1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button(L("Next Conversation", lang: lang)) { ShellModel.shared?.move(1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
        }
    }
}

// MARK: - Left: the conversations

struct SessionList: View {
    @ObservedObject var shell: ShellModel
    @Environment(\.lang) private var lang
    @State private var renaming: String?
    @State private var newName = ""
    @State private var deleting: String?

    var body: some View {
        VStack(spacing: 0) {
            Button {
                shell.newConversation()
            } label: {
                Label(L("New conversation", lang: lang), systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Brand.ink)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(shell.selected == nil ? ShellColor.panelSelected : Color.clear)
            .help(L("New conversation (⌘N)", lang: lang))
            .accessibilityHint(L("Starts a new conversation", lang: lang))
            List(selection: Binding(get: { shell.selected }, set: { id in if let id { shell.select(id) } })) {
                ForEach(shell.rows) { row in
                    SessionRowView(row: row)
                        .tag(Optional(row.id))
                        .contextMenu {
                            Button(L("Rename…", lang: lang)) { newName = shell.name(row.id) ?? row.title; renaming = row.id }
                            Button(L("Delete…", lang: lang), role: .destructive) { deleting = row.id }
                                .disabled(!shell.canDelete(row.id))
                        }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(ShellColor.panel)
        .alert(L("Rename conversation", lang: lang), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Name", lang: lang), text: $newName)
            Button(L("Cancel", lang: lang), role: .cancel) { renaming = nil }
            Button(L("Rename", lang: lang)) { if let id = renaming { shell.rename(id, to: newName) }; renaming = nil }
        } message: {
            Text(L("An empty name goes back to the first message.", lang: lang))
        }
        .confirmationDialog(L("Delete this conversation?", lang: lang),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L("Delete", lang: lang), role: .destructive) { if let id = deleting { shell.delete(id) }; deleting = nil }
            Button(L("Cancel", lang: lang), role: .cancel) { deleting = nil }
        } message: {
            Text(L("Its messages and its tasks' records are removed from this Mac. This can't be undone.", lang: lang)
                 + (deleting.map(shell.undoOpen) == true ? " " + L("Its last task's changes can still be undone; deleting the conversation gives that up.", lang: lang) : ""))
        }
    }
}

struct SessionRowView: View {
    let row: ShellRow
    @Environment(\.lang) private var lang

    var body: some View {
        let status = ShellText.status(row.status, lang: lang)
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            StatusDot(status: row.status, label: status)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Brand.ink).lineLimit(2)
                Text(status).font(.system(size: 11)).foregroundStyle(ShellColor.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("%@, %@", row.title, status, lang: lang))
    }
}

/// The session's state as a shape (never by colour alone, handoff §1.5): a ring (thinking), a dot (working), a dot with
/// a halo (waiting for you), a check (done), "!" (a problem), a mist dot (idle).
struct StatusDot: View {
    let status: SessionStatus
    let label: String

    var body: some View {
        ZStack {
            switch status.shape {
            case .haloDot:
                Circle().stroke(Brand.dot.opacity(0.35), lineWidth: 3).frame(width: 13, height: 13)
                Circle().fill(Brand.dot).frame(width: 8, height: 8)
            case .bang:
                Circle().fill(ShellColor.orangeText).frame(width: 13, height: 13)
                Text("!").font(.system(size: 10, weight: .heavy)).foregroundStyle(Brand.paper)
            case .solidDot:
                Circle().fill(Brand.dot).frame(width: 8, height: 8)
            case .hollowRing:
                Circle().stroke(Brand.dot, lineWidth: 1.6).frame(width: 9, height: 9)
            case .check:
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.ink)
            case .mistDot:
                Circle().fill(Brand.mist).frame(width: 7, height: 7)
            }
        }
        .frame(width: 14, height: 14)
        .animation(.easeInOut(duration: 0.15), value: status.shape)
        .accessibilityElement()
        .accessibilityLabel(label)
    }
}

// MARK: - Centre: the chat

struct ChatColumn: View {
    @ObservedObject var shell: ShellModel
    let openSettings: () -> Void
    @Environment(\.lang) private var lang
    @State private var announced: String?
    /// 「跳到卡片」: the card to scroll the chat to (one too tall to pin stays in place there).
    @State private var jumpTo: String?

    var body: some View {
        GeometryReader { g in column(height: g.size.height) }
            .background(PinRoomReporter(shell: shell))
            .background(Brand.paper)
            // 1–9 pick the pinned card's options (only while this window is the key one and no field is typed in)
            .background(CardKeyMonitor(shell.cardKeyHandlers))
            .onChange(of: shell.current.flatMap { shell.pinned($0) }?.card.askId) { _, id in announce(shell.current, id) }
    }

    /// Top to bottom: the header, the chat (which gives up height first), the pinned card and queue (bounded: their
    /// bodies scroll), the notice and the composer — the header, the card's question and buttons, and the composer with
    /// its Stop always on screen, down to the window's least height (#107 review).
    private func column(height: Double) -> some View {
        let s = shell.current
        return VStack(spacing: 0) {
            header(s)
                .fixedSize(horizontal: false, vertical: true)
            if !shell.reachable {
                Banner(text: L("DeskMind's helper isn't answering. Conversations come back when it does.", lang: lang))
            }
            if shell.waitingForHelper {
                Banner(text: L("Waiting for DeskMind's helper…", lang: lang))
            }
            if shell.showsCloudOff(s) {
                CloudOffRow(openSettings: openSettings)
            }
            if let code = s?.settingsRefused {
                Banner(text: ShellText.settingsRefused(code, lang: lang))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let s { timeline(s) } else { EmptyChat(opening: shell.opening) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 22).padding(.vertical, 16)
                }
                // (not while a card too tall to pin waits in place in the chat: the chat would pull away from it)
                .onChange(of: s?.lastSeq) { _, _ in if !inlineCard(s) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") } } }
                .onChange(of: s?.streamingMessage?.text.count) { _, _ in proxy.scrollTo("bottom") }
                .onChange(of: shell.selected) { _, _ in proxy.scrollTo("bottom") }
                .onChange(of: jumpTo) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }; jumpTo = nil }
                }
                // (an option of a card in place here took the keyboard focus: into view)
                .onChange(of: shell.scrollRequest?.n) { _, _ in if let id = shell.scrollRequest?.id { proxy.scrollTo(id) } }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .layoutPriority(0)
            if let s { pinned(s, queueCap: CardBody.cap(columnHeight: height)).layoutPriority(1) }
            if let n = shell.notice {
                Text(n).font(.system(size: 12)).foregroundStyle(ShellColor.orangeText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.bottom, 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(2)
            }
            Composer(shell: shell)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
        }
        .frame(height: height)
    }

    private func header(_ s: SessionState?) -> some View {
        HStack {
            Text(shell.rows.first { $0.id == shell.selected }?.title ?? L("New conversation", lang: lang))
                .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Brand.ink).lineLimit(1)
            Spacer()
            if let t = s?.runningTask {
                Button(L("Stop task", lang: lang)) { shell.stop() }
                    .buttonStyle(InkButtonStyle(prominent: false))
                    .disabled(t.stopping)
                    .help(L("Stop the task (⌘.)", lang: lang))
                    .accessibilityHint(L("Stops the computer task; what it changed can be undone where the result offers it", lang: lang))
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
    }

    @ViewBuilder private func timeline(_ s: SessionState) -> some View {
        let last = s.timeline.last
        let idle = s.runningTask == nil && s.streamingMessage == nil
        ForEach(Array(s.timeline.enumerated()), id: \.offset) { _, item in
            switch item {
            case .message(let id):
                if let m = s.message(id) { MessageRow(message: m) }
            case .task(let run):
                if let t = s.task(run) { TaskRow(shell: shell, task: t, session: s) }
            case .error(let seq):
                if let e = s.errors.first(where: { $0.seq == seq }) {
                    ErrorRow(row: ErrorRowModel(e.error, latest: last == item, idle: idle, lang: lang),
                             openSettings: openSettings, retry: shell.retry)
                }
            }
        }
        ForEach(s.shownOutbox, id: \.id) { o in OutgoingRow(shell: shell, item: o) }
    }

    /// Above the composer: the open card (handoff §3.3, pinned while it waits) -- whole when it fits the pinned place
    /// (ShellModel.cardPinnedWhole), else one line, its title and 「跳到卡片」, the card itself in place in the chat (A2) --
    /// and the queue (scrolls past a few).
    @ViewBuilder private func pinned(_ s: SessionState, queueCap: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let p = shell.pinned(s) {
                let m = CardModel(card: p.card.card, runId: p.runId, askId: p.card.askId)
                PinnedCard(shell: shell, card: m, phase: p.phase, askedAt: p.card.askedAt, session: s) { jumpTo = $0 }
            }
            if !s.queue.isEmpty { QueueList(shell: shell, session: s, cap: min(150, queueCap)) }
        }
        .padding(.horizontal, 22)
        .animation(.easeOut(duration: 0.2), value: shell.pinned(s)?.card.askId)
    }

    /// The open card is drawn whole in place in the chat (too tall to pin).
    private func inlineCard(_ s: SessionState?) -> Bool {
        guard let s, let p = shell.pinned(s) else { return false }
        return !shell.cardPinnedWhole(CardModel(card: p.card.card, runId: p.runId, askId: p.card.askId))
    }

    /// A new card is said aloud, without moving the focus (handoff §3.10).
    private func announce(_ s: SessionState?, _ id: String?) {
        guard let id, id != announced, let s, let p = shell.pinned(s) else { return }
        announced = id
        let m = CardModel(card: p.card.card, runId: p.runId, askId: p.card.askId)
        // (and how to reach it by keys: Tab moves into the card, its options' keys work then -- fable 10-25; from a field
        // being typed in, Tab is the field's first)
        let how = shell.editingText ? L("Leave the text field, then press Tab to move into the card.", lang: lang) : L("Press Tab to move into the card.", lang: lang)
        AccessibilityNotification.Announcement(CardView.voiceOverLabel(m, phase: p.phase, lang: lang) + " " + how).post()
    }
}

/// The queue above the composer: as tall as its bubbles, scrolling past `cap`.
struct QueueList: View {
    @ObservedObject var shell: ShellModel
    let session: SessionState
    let cap: Double
    @State private var content: Double = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(session.queue, id: \.id) { q in QueuedBubble(shell: shell, item: q, cardOpen: !session.composerEnabled) }
            }
            .background(GeometryReader { g in Color.clear.preference(key: CardBodyVisible.self, value: g.size.height) })
        }
        .frame(height: min(cap, max(content, 1)))
        .onPreferenceChange(CardBodyVisible.self) { content = $0 }
    }
}

/// Cloud models are off: a conversation needs one (0.5 has no local-only conversation), so nothing is sent; the
/// settings are one click away.
struct CloudOffRow: View {
    let openSettings: () -> Void
    @Environment(\.lang) private var lang
    var body: some View {
        HStack(spacing: 10) {
            Label(L("Cloud models are off. Conversations need one: nothing is sent until it is on.", lang: lang), systemImage: "cloud.slash")
                .font(.system(size: 12)).foregroundStyle(Brand.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("Open model settings", lang: lang), action: openSettings).buttonStyle(InkButtonStyle(prominent: true))
        }
        .padding(.horizontal, 22).padding(.vertical, 8)
        .background(ShellColor.banner)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }
}

struct Banner: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Brand.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22).padding(.vertical, 8)
            .background(ShellColor.banner)
    }
}

struct EmptyChat: View {
    let opening: Bool
    @Environment(\.lang) private var lang
    var body: some View {
        VStack(spacing: 10) {
            XiaoFang(mood: .idle, size: 72)
            Text(opening ? L("Starting the conversation…", lang: lang) : L("What can I do for you?", lang: lang))
                .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Brand.ink)
            Text(L("Chat, or start a computer task with /cua followed by what to do.", lang: lang))
                .font(.system(size: 12)).foregroundStyle(ShellColor.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }
}

struct MessageRow: View {
    let message: ChatMessage
    @Environment(\.lang) private var lang

    var body: some View {
        let user = message.role == "user"
        HStack {
            if user { Spacer(minLength: 60) }
            VStack(alignment: user ? .trailing : .leading, spacing: 4) {
                Text(message.text.isEmpty && message.streaming ? "…" : message.text)
                    .font(.system(size: 13.5)).foregroundStyle(Brand.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, user ? 12 : 0).padding(.vertical, user ? 8 : 0)
                    .background(user ? RoundedRectangle(cornerRadius: 12).fill(Brand.card) : nil)
                    .opacity(message.retracted ? 0.5 : 1)
                if let note = note {
                    Text(note).font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
                }
            }
            if !user { Spacer(minLength: 60) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel((user ? L("You", lang: lang) : L("DeskMind", lang: lang)) + ": " + message.text + (note.map { ". " + $0 } ?? ""))
    }

    private var note: String? {
        if message.streaming { return message.gap ? L("Catching up…", lang: lang) : L("Writing…", lang: lang) }
        if message.interrupted { return L("Interrupted: the conversation restarted before the reply finished", lang: lang) }
        if message.stopped { return L("Stopped", lang: lang) }
        if message.truncated { return L("Cut off: the reply reached its length limit", lang: lang) }
        if message.retracted { return L("Asked again", lang: lang) }
        if message.via == "cua" { return L("Computer task", lang: lang) }
        if message.via == "queue" { return L("Sent after the task", lang: lang) }
        return nil
    }
}

// (TaskRow, a computer task and its result card: Main/TaskViews.swift)

struct ErrorRow: View {
    let row: ErrorRowModel
    let openSettings: () -> Void
    let retry: () -> Void
    @Environment(\.lang) private var lang

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(row.headline, systemImage: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(ShellColor.orangeText)
            if !row.detail.isEmpty {
                Text(row.detail).font(.system(size: 12)).foregroundStyle(ShellColor.secondary).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if row.showsSettings {
                    Button(L("Open model settings", lang: lang), action: openSettings).buttonStyle(InkButtonStyle(prominent: true))
                }
                if row.showsRetry {
                    Button(L("Try again", lang: lang), action: retry).buttonStyle(InkButtonStyle(prominent: false))
                        .accessibilityHint(L("Asks the model to answer your last message again", lang: lang))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(ShellColor.problem))
        .accessibilityElement(children: .contain)
    }
}

/// The user's words the app holds: on their way (sending), or not sent (with why, 「重新发送」 and remove).
struct OutgoingRow: View {
    @ObservedObject var shell: ShellModel
    let item: Outgoing
    @Environment(\.lang) private var lang

    var body: some View {
        HStack {
            Spacer(minLength: 60)
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.text).font(.system(size: 13.5)).foregroundStyle(Brand.ink)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Brand.card))
                    .opacity(item.sending ? 0.6 : 1)
                if item.sending {
                    Text(L("Sending…", lang: lang)).font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
                } else {
                    HStack(spacing: 8) {
                        Text(shell.unsentText(item.refused)).font(.system(size: 11)).foregroundStyle(ShellColor.orangeText)
                        Button(L("Send again", lang: lang)) { shell.resend(item.id) }.buttonStyle(.link)
                            .disabled(!shell.composer.enabled)      // (a card waits: answered on the card first)
                        Button(L("Remove", lang: lang)) { shell.dropUnsent(item.id) }.buttonStyle(.link)
                    }
                    .font(.system(size: 11))
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A message typed while the task runs (handoff §3.4): it waits in the session's queue until the task is done; it can
/// be edited, removed, or sent to the task now. A task that was stopped holds it: sent only if the user says so.
struct QueuedBubble: View {
    @ObservedObject var shell: ShellModel
    let item: QueueItem
    let cardOpen: Bool
    @Environment(\.lang) private var lang
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock").foregroundStyle(ShellColor.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if editing {
                    TextField(L("Queued message", lang: lang), text: $text, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                } else {
                    Text(item.text).font(.system(size: 13)).foregroundStyle(Brand.ink)
                }
                Text(item.note ?? (item.held == true ? L("The task stopped. Send it?", lang: lang) : L("Queued: sent when the task is done", lang: lang)))
                    .font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
            }
            Spacer()
            if editing {
                Button(L("Save", lang: lang), action: save).buttonStyle(.link)
                Button(L("Cancel", lang: lang)) { editing = false }.buttonStyle(.link)
            } else {
                Button(L("Edit", lang: lang)) { text = item.text; editing = true }.buttonStyle(.link)
                Button(L("Send now", lang: lang)) { shell.queueSendNow(item.id) }.buttonStyle(.link)
                    .disabled(cardOpen)
                    .accessibilityHint(L("Sends it to the running task now", lang: lang))
                Button(L("Remove", lang: lang)) { shell.queueCancel(item.id) }.buttonStyle(.link)
            }
        }
        .font(.system(size: 12))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Queued message: %@", item.text, lang: lang))
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty && t != item.text { shell.queueEdit(item.id, text: t) }
        editing = false
    }
}

// (CardView, the card by its kind: Main/CardViews.swift)

/// A card's height as laid out (ShellModel.cardLaidOut).
struct CardHeight: PreferenceKey {
    static let defaultValue: Double = 0
    static func reduce(value: inout Double, nextValue: () -> Double) { value = max(value, nextValue()) }
}

/// The card body's visible height.
struct CardBodyVisible: PreferenceKey {
    static let defaultValue: Double = 0
    static func reduce(value: inout Double, nextValue: () -> Double) { value = max(value, nextValue()) }
}

// MARK: - The composer

struct Composer: View {
    @ObservedObject var shell: ShellModel
    @Environment(\.lang) private var lang
    /// The focus funnel's one consumer (ShellModel.focusRequest: the user's Esc out of a card).
    @FocusState private var focused: Bool

    var body: some View {
        let mode = shell.composer
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder(mode), text: Binding(get: { shell.draft }, set: { shell.draft = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .lineLimit(1...8)
                .disabled(!mode.enabled || shell.opening)
                .focused($focused)
                .onChange(of: shell.focusRequest) { _, n in if shell.takeFocus(n) { focused = true } }
                // Return: the field's own submit, which waits for an input method to commit what is being composed
                // (pinyin's Return confirms the letters, never sends). ⌘Return sends now; ⇧Return / ⌥Return: a new line.
                .onSubmit { shell.submit() }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) { shell.submit(sendNow: mode.taskRunning); return .handled }
                    if press.modifiers.contains(.shift) { shell.draft += "\n"; return .handled }
                    return .ignored
                }
                .accessibilityLabel(L("Message", lang: lang))
                .accessibilityHint(mode.taskRunning ? L("Return sends it to the task now", lang: lang)
                                                    : L("Return sends; start with /cua to run a computer task", lang: lang))
            if mode.canStop {
                Button(L("Stop", lang: lang)) { shell.stop() }
                    .buttonStyle(InkButtonStyle(prominent: false))
                    .accessibilityHint(mode.taskRunning ? L("Stops the computer task", lang: lang) : L("Stops the reply", lang: lang))
            }
            if !mode.replying {
                Button(L("Send", lang: lang)) { shell.submit() }
                    .buttonStyle(InkButtonStyle(prominent: true))
                    .disabled(mode.control(shell.draft, sendNow: false) == nil || shell.opening)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Brand.line))
        .padding(.horizontal, 18).padding(.bottom, 16).padding(.top, 6)
        .opacity(mode.enabled ? 1 : 0.7)
    }

    private func placeholder(_ m: ComposerMode) -> String {
        if !m.enabled { return L("Answer the card above to go on", lang: lang) }
        if m.taskRunning { return L("Add something: Return queues it, ⌘Return sends it to the task now", lang: lang) }
        if m.replying { return L("Wait for the reply, or stop it", lang: lang) }
        return L("Message DeskMind, or /cua and a task for the computer", lang: lang)
    }
}

// MARK: - Right: the agent (a placeholder until M3)

struct AgentPanel: View {
    @ObservedObject var shell: ShellModel
    @Environment(\.lang) private var lang
    /// The live view (A4): watched only while a task runs here and this window is on screen.
    @StateObject private var dock = LiveDock()
    @ObservedObject private var monitor = FloatController.shared.monitor      // (the app's one)

    /// The run the dock should watch now (nil: none).
    private var watched: String? {
        // (in front only: behind, the float has the picture -- §3.2; popped out, too)
        guard monitor.window == .front, let sid = shell.selected, !shell.poppedOut.contains(sid), let t = shell.current?.runningTask else { return nil }
        return t.runId
    }

    @AppStorage(ProcessTabs.key) private var traceOn = false

    /// The column's blocks (RightColumn.model: only what the events said), each second while a task runs; with the
    /// 过程 tab on (ui05.trace), 「现在」 and 「过程」 above it (ProcessTabs: switching sends nothing).
    var body: some View {
        VStack(spacing: 8) {
            if traceOn {
                Picker("", selection: Binding(get: { shell.currentTabs.tab }, set: { shell.pickTab($0) })) {
                    Text(L("Now", lang: lang)).tag(ProcessTabs.Tab.now)
                    Text(L("Process", lang: lang)).tag(ProcessTabs.Tab.process)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            if shell.currentTabs.shown(traceOn: traceOn) == .process, let sid = shell.selected,
               let run = shell.currentTabs.run ?? shell.current?.tasks.last?.runId {
                ProcessPane(sessionId: sid, runId: run, trigger: ProcessPane.trigger(shell.states[sid]?.task(run))).equatable().id(sid + "/" + run)
            } else if shell.currentTabs.shown(traceOn: traceOn) == .process {
                Text(L("No record", lang: lang)).foregroundStyle(ShellColor.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { _ in content(column) }
            }
        }
        .onChange(of: watched, initial: true) { _, run in dock.watch(run) }
        .onDisappear { dock.watch(nil) }
    }

    private var column: RightColumn {
        let other = shell.rows.first { $0.id != shell.selected && $0.taskRunning }
        return RightColumn.model(shell.current, otherRunning: other?.title, otherId: other?.id, now: shell.now())
    }

    private func content(_ c: RightColumn) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 6) {
                    XiaoFang(mood: Self.mood(c.status), size: 84).accessibilityHidden(true)
                    Text(ShellText.status(c.status, lang: lang))
                        .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Brand.ink)
                        .multilineTextAlignment(.center)
                        .accessibilityLabel(L("Status: %@", ShellText.status(c.status, lang: lang), lang: lang))
                    if let p = c.progress {
                        Text(L("Step %d · %d:%02d", p.step, p.seconds / 60, p.seconds % 60, lang: lang))
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(ShellColor.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                // the live view of the task's window (A4), while one runs here
                if let t = shell.current?.runningTask, watched != nil {
                    let last = t.steps.last
                    LiveDockView(dock: dock, stepWindow: LiveFeed.windowNumber(last?.object), target: last?.target?.rectNorm)
                } else if shell.current?.runningTask != nil {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Brand.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .overlay(Text(L("The live view is in the float", lang: lang)).font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
                                    .multilineTextAlignment(.center).padding(14))
                        .frame(height: 150)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Brand.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .overlay(Text(L("The live view of the task's window and its steps will show here.", lang: lang))
                                    .font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
                                    .multilineTextAlignment(.center).padding(14))
                        .frame(height: 150)
                }
                if let who = c.computerUsedBy {
                    Button(L("The computer is being used by 「%@」", who, lang: lang)) { if let id = c.computerUsedById { shell.select(id) } }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(ShellColor.orangeText)
                        .accessibilityHint(L("Shows that conversation", lang: lang))
                }
                if c.youAreUsingIt || c.screenLocked {
                    section(L("This Mac", lang: lang)) {
                        if c.youAreUsingIt { line(L("You're using it: the task waits for you to stop", lang: lang)) }
                        if c.screenLocked { line(L("The screen was locked, so the task stopped", lang: lang)) }
                    }
                }
                if !c.plan.isEmpty {
                    section(L("Steps", lang: lang)) {
                        ForEach(c.plan, id: \.n) { r in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(Self.markSymbol(r.mark)).font(.system(size: 11, weight: .semibold)).foregroundStyle(r.mark == .current ? ShellColor.orangeText : ShellColor.secondary)
                                    .accessibilityHidden(true)
                                Text(r.purpose).font(.system(size: 12)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
                                if r.asksFirst { Text(L("asks before sending", lang: lang)).font(.system(size: 10)).foregroundStyle(ShellColor.secondary) }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(L("Step %d: %@, %@", r.n, r.purpose, Self.markWord(r.mark, lang: lang), lang: lang))
                        }
                    }
                }
                if !c.changes.isEmpty {
                    section(L("Changes and outputs", lang: lang)) {
                        if c.changes.undone { line(L("All undone", lang: lang)) }
                        list(L("Created", lang: lang), c.changes.created)
                        list(L("Modified", lang: lang), c.changes.modified)
                        list(L("Deleted", lang: lang), c.changes.deleted)
                        list(L("Sent out", lang: lang), c.changes.external)
                        if !c.changes.unconfirmed.isEmpty {
                            line(L("Files that appeared or changed while the task worked in apps; not known to be this task's (not undone)", lang: lang))
                            ForEach(c.changes.unconfirmed, id: \.self) { line($0) }
                        }
                    }
                }
            }
            .padding(18)
        }
        .frame(maxHeight: .infinity)
        .background(ShellColor.panel)
    }

    @ViewBuilder private func section(_ title: String, @ViewBuilder _ body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(ShellColor.secondary)
            body()
        }
    }
    @ViewBuilder private func list(_ label: String, _ items: [String]) -> some View {
        if !items.isEmpty { line(L("%@: %@", label, items.joined(separator: L(", ", lang: lang)), lang: lang)) }
    }
    private func line(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    static func markSymbol(_ m: RightColumn.PlanRow.Mark) -> String {
        switch m { case .done: "✓"; case .current: "▶"; case .todo: "·" }
    }
    static func markWord(_ m: RightColumn.PlanRow.Mark, lang: ResolvedLang) -> String {
        switch m { case .done: L("done", lang: lang); case .current: L("doing now", lang: lang); case .todo: L("not yet", lang: lang) }
    }

    /// 小方's face for the state (LiveView.face): looking while it works, up when it waits for you, happy when done,
    /// flat when it stopped or went wrong.
    static func mood(_ s: SessionStatus) -> Brand.Mood {
        switch s {
        case .waitingForYou, .cardExpired: return .notice
        case .done(_, let stopped): return stopped ? .rest : .done
        case .error, .locked, .stopping: return .rest
        case .acting, .thinking, .paused, .lookOnly, .idle: return .idle
        }
    }
}
