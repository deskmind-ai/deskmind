// The 0.5 main window (M1 S3, behind `ui05.shell`): three columns — the conversations, the chat, and the right column
// (a placeholder until M3: 小方 and the session's state). Its logic is ShellModel (Shared/Shell.swift); these are
// views only.
//
// Focus (handoff §3.1): nothing here activates the app or brings a window forward. Only the user's own clicks and
// keys act; the composer never takes the keyboard by itself when a card arrives, and nothing here ever moves the
// keyboard focus anywhere — no @FocusState, no .focused, no defaultFocus, no makeFirstResponder (ShellTests checks
// this file): a card that arrives while the user types must never get the typing (its own field's Return would send
// it as the answer).

import AppKit
import SwiftUI

/// The handoff's text colours (§3.10): secondary text and orange text at 4.5:1 or better on paper.
enum ShellColor {
    static let secondary = Color(hex: 0x5E675F)
    static let orangeText = Color(hex: 0xA3402A)
}

struct MainSplitView: View {
    @ObservedObject var shell: ShellModel
    @EnvironmentObject var model: HelperModel
    @Environment(\.lang) private var lang
    @State private var settingsOpen = false
    @State private var settingsBefore = ""
    @State private var envBefore = ""

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
            shell.start()
        }
        .onChange(of: lang) { _, _ in shell.settingsChanged() }     // (the language is a session setting like the model's)
    }

    /// The model settings as saved now (the key file, the configuration, the service, and cloud models on or off), to
    /// tell whether the sheet changed them.
    static func settingsFingerprint() -> String {
        return envFingerprint() + "|" + (UserDefaults.standard.string(forKey: "engine.config") ?? "") + "|" + CloudModelSettings.provider.id
            + "|" + (UserDefaults.standard.string(forKey: "engine") ?? "") + "|" + ResolvedLang.current.rawValue
    }

    /// The key file (keys, a custom service's URL and model): a session process reads it when it starts, so only a
    /// change here needs a new process (set_config carries the rest in place).
    static func envFingerprint() -> String {
        CloudModelSettings.read().sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    private func openSettings() {
        settingsBefore = Self.settingsFingerprint()
        envBefore = Self.envFingerprint()
        settingsOpen = true
    }

    private func settingsClosed() {
        model.refreshCloud()
        if Self.settingsFingerprint() != settingsBefore { shell.settingsChanged(keyChanged: Self.envFingerprint() != envBefore) }
    }

    /// The configuration sessions open with: the one the settings saved, else the chosen service's.
    static func modelConfig() -> String {
        if let c = UserDefaults.standard.string(forKey: "engine.config"), !c.isEmpty { return c }
        let p = CloudModelSettings.provider
        return CloudModelSettings.config(for: p, model: CloudModelSettings.read()["CUSTOM_MODEL"] ?? "")
    }
}

extension ShellModel {
    /// The app's one: the helper's sessions, opened with the model settings and the UI language as they are.
    static let live: ShellModel = {
        let transport = StoppableTransport(HelperSessionTransport())
        // the language as the setting has it now (not ResolvedLang.current, which the window updates in its own time)
        // (the app's one ModelsOffSync: the engine setter and the helper's connect push through the same one)
        let m = ShellModel(client: SessionClient(transport: transport, modelsSync: .shared), config: { MainSplitView.modelConfig() },
                           lang: { (AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? AppLanguage.system.rawValue) ?? .en).resolved },
                           cloudOn: { CloudModelSettings.engineIsCloud })
        transport.isStopped = { [weak m] in m?.stopped ?? true }
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
            .background(shell.selected == nil ? Brand.mist.opacity(0.25) : Color.clear)
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
        .background(Brand.card.opacity(0.6))
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
        .accessibilityLabel("\(row.title), \(status)")
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

    var body: some View {
        GeometryReader { g in column(height: g.size.height) }
            .background(Brand.paper)
            .onChange(of: shell.current?.openCard?.card.askId) { _, id in announce(shell.current, id) }
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
                .onChange(of: s?.lastSeq) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") } }
                .onChange(of: s?.streamingMessage?.text.count) { _, _ in proxy.scrollTo("bottom") }
                .onChange(of: shell.selected) { _, _ in proxy.scrollTo("bottom") }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            .layoutPriority(0)
            if let s { pinned(s, bodyCap: CardBody.cap(columnHeight: height)).layoutPriority(1) }
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
        ForEach(s.outbox, id: \.id) { o in OutgoingRow(shell: shell, item: o) }
    }

    /// Above the composer: the open card (handoff §3.3, pinned while it waits; its body scrolls within `bodyCap`) and
    /// the queue (scrolls past a few).
    @ViewBuilder private func pinned(_ s: SessionState, bodyCap: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let (run, card) = s.openCard {
                let m = CardModel(card: card.card, runId: run, askId: card.askId)
                CardView(shell: shell, card: m, outcome: card.outcome, askedAt: card.askedAt, session: s, bodyCap: bodyCap)
                    .id(ShellModel.cardKey(m))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !s.queue.isEmpty { QueueList(shell: shell, session: s, cap: min(150, bodyCap)) }
        }
        .padding(.horizontal, 22)
        .animation(.easeOut(duration: 0.2), value: s.openCard?.card.askId)
    }

    /// A new card is said aloud, without moving the focus (handoff §3.10).
    private func announce(_ s: SessionState?, _ id: String?) {
        guard let id, id != announced, let (run, card) = s?.openCard else { return }
        announced = id
        let m = CardModel(card: card.card, runId: run, askId: card.askId)
        AccessibilityNotification.Announcement(CardView.voiceOverLabel(m, outcome: .open, lang: lang)).post()
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
        .background(Brand.dot.opacity(0.10))
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
            .background(Brand.dot.opacity(0.10))
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

/// A computer task as one row: what was asked, where it is (or how it ended), the step it is on, Stop; its cards that
/// are answered or gone; its result and its result card. Styled cards and steps are M2.
struct TaskRow: View {
    @ObservedObject var shell: ShellModel
    let task: TaskState
    let session: SessionState
    @Environment(\.lang) private var lang

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "macwindow").foregroundStyle(Brand.ink).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.raw.isEmpty ? L("Computer task", lang: lang) : task.raw)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.ink).lineLimit(3)
                    Text(ShellText.task(task, lang: lang)).font(.system(size: 12)).foregroundStyle(task.running ? ShellColor.orangeText : ShellColor.secondary)
                }
                Spacer()
                if task.running {
                    Button(L("Stop", lang: lang)) { shell.stop() }
                        .buttonStyle(InkButtonStyle(prominent: false))
                        .disabled(task.stopping)
                        .accessibilityHint(L("Stops the computer task", lang: lang))
                }
            }
            if task.running, let step = task.steps.last {
                Text(step.displayText).font(.system(size: 12)).foregroundStyle(ShellColor.secondary).lineLimit(2)
                    .accessibilityLabel(L("Current step: %@", step.displayText, lang: lang))
            }
            ForEach(task.cards.filter { $0.outcome != .open }, id: \.askId) { c in
                Text(cardLine(c)).font(.system(size: 11)).foregroundStyle(ShellColor.secondary).lineLimit(2)
            }
            if !task.running {
                let summary = task.done?.summary ?? task.end?.summary ?? ""
                if !summary.isEmpty { Text(summary).font(.system(size: 13)).foregroundStyle(Brand.ink).textSelection(.enabled) }
                if let a = task.answer, !a.isEmpty, a != summary { Text(a).font(.system(size: 13)).foregroundStyle(Brand.ink).textSelection(.enabled) }
                if let rc = task.resultCard, !(rc.options.isEmpty) {
                    let m = CardModel(resultCard: rc, runId: task.runId)
                    CardView(shell: shell, card: m, outcome: .open, askedAt: nil, session: session, bodyCap: CardBody.maxHeight)
                        .id(ShellModel.cardKey(m))
                }
                if let u = ShellText.undo(task.undo, lang: lang) {
                    Text(u).font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(task.running ? Brand.dot.opacity(0.6) : Brand.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Computer task: %@", task.raw, lang: lang))
    }

    private func cardLine(_ c: CardState) -> String {
        let kind = ShellText.cardKind(c.card.kind, lang: lang)
        switch c.outcome {
        case .answered: return L("Answered: %@", kind, lang: lang)
        case .void(let why):
            switch why {
            case "steer": return L("No longer needed (you changed the request): %@", kind, lang: lang)
            case "stop": return L("No longer needed (the task stopped): %@", kind, lang: lang)
            default: return L("No longer needed (the task ended): %@", kind, lang: lang)
            }
        case .open: return kind
        }
    }
}

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
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.dot.opacity(0.07)))
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

/// A card, plainly (styled cards are M2): its text, a button per option by the option's kind, and its own field when
/// it takes the user's words. A click sends that option's index with the card's ask_id; nothing is decided by the
/// words on the card.
///
/// Its header (what it asks) and its buttons stay put; its body — the text and the picks, which the harness does not
/// cap (a send list can be long) — scrolls inside `bodyCap`. An approve-type option (CardModel.Role.needsWholeBody)
/// takes a click only once the body's end has been on screen (it fits, or it was scrolled to the end): never approve
/// what was never shown (ShellModel.cardBody, from the scroll geometry alone).
struct CardView: View {
    @ObservedObject var shell: ShellModel
    let card: CardModel
    let outcome: CardState.Outcome
    let askedAt: Double?
    let session: SessionState
    let bodyCap: Double
    @Environment(\.lang) private var lang
    @State private var words = ""
    @State private var visible: Double = 0
    @State private var content: Double = 0
    @State private var offset: Double = 0

    private var enabled: Bool { shell.answerable(card, in: session) }
    private var wordsEnabled: Bool { shell.wordsEnabled(card, in: session) }
    private var seen: Bool { shell.bodySeen.contains(ShellModel.cardKey(card)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if card.blocking && outcome == .open {
                    Text(L("Waiting for you", lang: lang)).font(.system(size: 11, weight: .semibold)).foregroundStyle(ShellColor.orangeText)
                }
                Text(ShellText.cardKind(card.kind.name, lang: lang)).font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(card.text).font(.system(size: 13)).foregroundStyle(Brand.ink).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    let choices = card.buttons.filter { $0.role == .choice }
                    if !choices.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(choices, id: \.index) { b in button(b) }
                        }
                    }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: CardBodyGeometry.self,
                                           value: [g.size.height, -g.frame(in: .named(coordinateSpace)).minY])
                })
            }
            .coordinateSpace(name: coordinateSpace)
            .frame(minHeight: min(CardBody.minHeight, content), maxHeight: min(bodyCap, max(content, 1)))
            .background(GeometryReader { g in Color.clear.preference(key: CardBodyVisible.self, value: g.size.height) })
            .onPreferenceChange(CardBodyGeometry.self) { v in
                if v.count == 2 { content = v[0]; offset = v[1]; reportBody() }
            }
            .onPreferenceChange(CardBodyVisible.self) { h in visible = h; reportBody() }
            HStack(spacing: 8) {
                ForEach(card.buttons.filter { $0.role != .choice }, id: \.index) { b in button(b) }
            }
            .fixedSize(horizontal: false, vertical: true)
            if outcome == .open && !seen && card.buttons.contains(where: { $0.role.needsWholeBody }) {
                // (neutral: it holds the card's own field too, for someone who wants to type)
                Text(L("Read the whole card first: scroll to its end", lang: lang))
                    .font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
            }
            if card.allowsFreeText {
                HStack(spacing: 8) {
                    // (on a card with an approve-type option, words wait for the whole body as its approve does)
                    TextField(L("Or answer in your own words", lang: lang), text: $words, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendWords)
                        .disabled(!wordsEnabled)
                        .accessibilityHint(!wordsEnabled && ShellModel.wordsWaitForBody(card) && !seen
                                           ? L("Read the whole card first: scroll to its end", lang: lang) : "")
                    Button(L("Send", lang: lang), action: sendWords).buttonStyle(InkButtonStyle(prominent: false))
                        .disabled(!wordsEnabled || words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(outcome == .open && card.blocking ? Brand.dot : Brand.line, lineWidth: 1.2))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.voiceOverLabel(card, outcome: outcome, lang: lang))
    }

    @ViewBuilder private func button(_ b: CardModel.Button) -> some View {
        let action = { shell.click(b) }
        Group {
            switch b.style {
            case .prominent: Button(b.text, action: action).buttonStyle(InkButtonStyle(prominent: true))
            case .radio:
                Button(action: action) {
                    Label(b.text, systemImage: "circle").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Brand.line))
            case .destructive: Button(b.text, role: .destructive, action: action).buttonStyle(InkButtonStyle(prominent: false))
            case .bordered: Button(b.text, action: action).buttonStyle(InkButtonStyle(prominent: false))
            }
        }
        .disabled(!shell.buttonEnabled(b, card: card, in: session))
        .opacity(shell.buttonEnabled(b, card: card, in: session) ? 1 : 0.4)    // (InkButtonStyle does not dim: the card's own)
        .accessibilityLabel(b.text)
        .accessibilityHint(b.role.needsWholeBody && !seen ? L("Read the whole card first: scroll to its end", lang: lang) : Self.hint(b.role, lang: lang))
    }

    private var coordinateSpace: String { "cardBody/" + ShellModel.cardKey(card) }

    private func reportBody() {
        shell.cardBody(card, contentHeight: content, visibleHeight: visible, offset: offset)
    }

    private func sendWords() {
        guard wordsEnabled else { return }
        shell.answer(card, text: words)
        words = ""
    }

    /// 「<状态>：<卡的种类>。<正文第一句>。<n> 个选项」 (handoff §3.10).
    static func voiceOverLabel(_ card: CardModel, outcome: CardState.Outcome, lang: ResolvedLang) -> String {
        let state: String
        switch outcome {
        case .open: state = L("Waiting for your answer", lang: lang)
        case .answered: state = L("Answered", lang: lang)
        case .void: state = L("No longer needed", lang: lang)
        }
        let kind = ShellText.cardKind(card.kind.name, lang: lang)
        return L("%@: %@. %@. %d options", state, kind, firstSentence(card.text), card.buttons.count, lang: lang)
    }

    /// The text up to its first sentence end (for VoiceOver; the whole card stays readable inside).
    static func firstSentence(_ text: String) -> String {
        let ends: Set<Character> = ["。", "！", "？", ".", "!", "?", "\n"]
        guard let i = text.firstIndex(where: { ends.contains($0) }) else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(text[..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hint(_ role: CardModel.Role, lang: ResolvedLang) -> String {
        switch role {
        case .approve: return L("Agrees; the task goes on", lang: lang)
        case .choice: return L("Picks this one", lang: lang)
        case .skipStep: return L("Skips this step; the task goes on", lang: lang)
        case .delegate: return L("Lets DeskMind decide", lang: lang)
        case .cancel: return L("Answers no; the task ends cancelled", lang: lang)
        case .undo: return L("Undoes what the task changed", lang: lang)
        case .other: return ""
        }
    }
}

/// The card body's content height and how far it is scrolled ([height, offset]).
struct CardBodyGeometry: PreferenceKey {
    static let defaultValue: [Double] = []
    static func reduce(value: inout [Double], nextValue: () -> [Double]) { let n = nextValue(); if !n.isEmpty { value = n } }
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

    var body: some View {
        let mode = shell.composer
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder(mode), text: Binding(get: { shell.draft }, set: { shell.draft = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .lineLimit(1...8)
                .disabled(!mode.enabled || shell.opening)
                // Return: the field's own submit, which waits for an input method to commit what is being composed
                // (pinyin's Return confirms the letters, never sends). ⌘Return sends now; ⇧Return / ⌥Return: a new line.
                .onSubmit { shell.submit() }
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) { shell.submit(sendNow: mode.taskRunning); return .handled }
                    if press.modifiers.contains(.shift) { shell.draft += "\n"; return .handled }
                    return .ignored
                }
                .accessibilityLabel(L("Message", lang: lang))
                .accessibilityHint(mode.taskRunning ? L("Return queues it for after the task; Command-Return sends it to the task now", lang: lang)
                                                    : L("Return sends; start with /cua to run a computer task", lang: lang))
            if mode.canStop {
                Button(L("Stop", lang: lang)) { shell.stop() }
                    .buttonStyle(InkButtonStyle(prominent: false))
                    .accessibilityHint(mode.taskRunning ? L("Stops the computer task", lang: lang) : L("Stops the reply", lang: lang))
            }
            if !mode.replying {
                Button(mode.taskRunning ? L("Queue", lang: lang) : L("Send", lang: lang)) { shell.submit() }
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

    var body: some View {
        let status = shell.current?.status ?? .idle
        VStack(spacing: 14) {
            XiaoFang(mood: Self.mood(status), size: 84)
                .accessibilityHidden(true)
            Text(ShellText.status(status, lang: lang))
                .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(Brand.ink)
                .multilineTextAlignment(.center)
                .accessibilityLabel(L("Status: %@", ShellText.status(status, lang: lang), lang: lang))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Brand.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .overlay(Text(L("The live view of the task's window and its steps will show here.", lang: lang))
                            .font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
                            .multilineTextAlignment(.center).padding(14))
                .frame(height: 180)
            Spacer()
        }
        .padding(18)
        .frame(maxHeight: .infinity)
        .background(Brand.card.opacity(0.6))
    }

    /// 小方's face for the state (LiveView.face): looking while it works, up when it waits for you, happy when done,
    /// flat when it stopped or went wrong.
    static func mood(_ s: SessionStatus) -> Brand.Mood {
        switch s {
        case .waitingForYou: return .notice
        case .done(_, let stopped): return stopped ? .rest : .done
        case .error, .locked, .stopping: return .rest
        case .acting, .thinking, .paused, .lookOnly, .idle: return .idle
        }
    }
}
