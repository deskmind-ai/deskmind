import Combine
// DeskMind.app: the window the user keeps open. It holds no special permission; it registers the helper with
// launchd, walks the user through granting the helper's permissions (the first run, Main/FirstRun.swift), and
// reconnects whenever the helper restarts.

import ServiceManagement
import SwiftUI

@MainActor
final class HelperModel: ObservableObject {
    @Published var connected = false
    @Published var status: [String: Any] = [:]
    @Published var registration: SMAppService.Status = .notRegistered
    @Published var log: [String] = []
    /// The vision model is downloaded (checked off the main thread with every poll: it reads a dozen files).
    @Published var eyesPresent = false
    private var timer: Timer?
    private var watching: Grant?

    static weak var shared: HelperModel?
    private var service: SMAppService { SMAppService.agent(plistName: DeskMindIPC.agentPlist) }

    init() {
        // The helper must be started by LaunchServices to be its own TCC client: as an SMAppService agent tied to
        // this app, macOS counted its permissions against DeskMind, and the switch the user turned on for
        // "DeskMind Hands" did nothing (AXIsProcessTrusted stayed false). The old agent, if any, is removed.
        if service.status == .enabled || service.status == .requiresApproval { try? service.unregister() }
        registration = service.status
        HelperModel.shared = self
        followKeys()
        // A newer helper ships with this app: replace the installed copy and restart it before connecting.
        if (try? installHelper()) == true {
            note(L("Helper updated", lang: ResolvedLang.current))
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: "ai.deskmind.hands") {
                app.terminate()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in HelperModel.shared?.poll() }
        }
    }

    func note(_ s: String) {
        let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        log.insert("\(t)  \(s)", at: 0)
        if log.count > 60 { log.removeLast() }
    }

    func granted(_ g: Grant) -> Bool { status[g.statusKey] as? Bool == true }
    var helperReady: Bool { connected }
    private var lastLaunch = Date.distantPast
    /// How long a running helper has been silent, and whether it was asked to quit (HelperLocation.HungWatch).
    private var hungWatch = HelperLocation.HungWatch()
    @Published var launching = false

    /// Start the helper if it is not answering; it is also how a restart completes (the helper exits, we relaunch).
    func ensureHelper() {
        guard !connected, Date().timeIntervalSince(lastLaunch) > 3 else { return }
        // A helper process is there and silent -- starting, waiting for its predecessor, or hung. Opening it again
        // starts nothing, and for a hung one macOS shows "DeskMind Hands is not responding" every time: a stack
        // of them, one per poll (10-06). replaceIfHung deals with it; a new one is started once it has gone.
        guard HelperLocation.shouldLaunch(running: NSRunningApplication.runningApplications(
            withBundleIdentifier: "ai.deskmind.hands").contains { !$0.isTerminated }) else { return }
        lastLaunch = Date()
        launching = true
        do {
            if try installHelper() {
                note(L("Installed the helper in %@", helperURL.deletingLastPathComponent().path, lang: ResolvedLang.current))
                // An older copy may still be running under the same bundle id: let it go before starting ours.
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: "ai.deskmind.hands") {
                    app.terminate()
                }
            }
        } catch {
            note(L("Couldn't install the helper: %@", error.localizedDescription, lang: ResolvedLang.current))
        }
        Launch.background(helperURL) { error in
            Task { @MainActor in
                HelperModel.shared?.launching = false
                if let error {
                    HelperModel.shared?.note(L("Couldn't start the helper: %@", error.localizedDescription,
                                               lang: ResolvedLang.current))
                }
            }
        }
    }
    var permissionsDone: Bool { helperReady && Grant.allCases.filter(\.required).allSatisfy(granted) }
    var brainReady: Bool { status["brain"] as? String == "ready" }
    /// The cloud model's settings (Main/CloudModel.swift), read once and after the sheet saves.
    @Published var cloudEngine = CloudModelSettings.engineIsCloud
    @Published var cloudConfigured = CloudModelSettings.configured
    func refreshCloud() { cloudEngine = CloudModelSettings.engineIsCloud; cloudConfigured = CloudModelSettings.configured }
    /// The helper's word on the keys (A11), as it comes: whether the chosen service has its key follows it.
    private var keysSeen: AnyCancellable?
    func followKeys() {
        keysSeen = KeyStatus.shared.$snapshot.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshCloud() }
        KeyStatus.shared.refresh()
    }
    /// "Ready" means a real task can run: permissions, and whichever model thinks — the local one downloaded and
    /// running, or the cloud one with its key.
    var requiredDone: Bool { permissionsDone && (cloudEngine ? cloudConfigured : brainReady) }

    func watchGrant(_ g: Grant?) { watching = g }

    func poll() {
        // While a grant panel is open, ask the helper for a fresh probe: Screen Recording only shows up in a new
        // process, so the helper checks it in a short-lived child of its own.
        let probe = watching != nil || !(status["screen_recording_granted"] as? Bool ?? false)
        Task.detached {
            let reply = DeskMindIPC.request(["op": "status", "probe": probe], timeout: 3)
            let eyes = DeskMindModels.eyesDir() != nil
            await MainActor.run {
                if self.eyesPresent != eyes { self.eyesPresent = eyes }
                let was = self.connected
                self.connected = reply?["ok"] as? Bool == true
                if let reply { self.status = reply }
                // connected (the app's start, a helper restarted): the helper hears whether cloud models are off
                // and whenever it says otherwise (a lost assertion): the app's switch is the truth
                let off = !CloudModelSettings.engineIsCloud
                if self.connected && (!was || (reply?["models_off"] as? Bool).map({ $0 != off }) == true) {
                    ModelsOffSync.shared.push()
                }
                if was != self.connected {
                    let lang = ResolvedLang.current
                    self.note(self.connected ? L("Helper connected (pid %@)", "\(reply?["pid"] ?? "?")", lang: lang)
                                             : L("Helper disconnected. Waiting to reconnect…", lang: lang))
                }
                self.replaceIfHung()
                if !self.connected { self.ensureHelper() }
                // A helper still running from inside DeskMind.app (started before the hand-over existed, or by
                // something that bypassed it): its Screen Recording counts as DeskMind's. Replace it with the
                // installed copy.
                if self.connected, HelperLocation.isWrongCopy(runningPath: reply?["path"] as? String,
                                                              installedPath: helperURL.path) {
                    self.note(L("Restarting the helper from its installed copy", lang: ResolvedLang.current))
                    // Only the nested copy: the installed one may already be starting, and stays.
                    for app in NSRunningApplication.runningApplications(withBundleIdentifier: "ai.deskmind.hands")
                    where HelperLocation.isWrongCopy(runningPath: app.bundleURL?.path, installedPath: helperURL.path) {
                        app.terminate()
                    }
                }
            }
        }
    }

    /// A helper that is running but has stopped answering is quit, then killed (HelperLocation.hungAction).
    private func replaceIfHung() {
        let helpers = NSRunningApplication.runningApplications(withBundleIdentifier: "ai.deskmind.hands").filter { !$0.isTerminated }
        switch hungWatch.step(now: Date(), connected: connected, running: !helpers.isEmpty) {
        case .terminate:
            note(L("The helper stopped answering. Restarting it", lang: ResolvedLang.current))
            helpers.forEach { $0.terminate() }
        case .kill:
            // SIGKILL itself: forceTerminate() returned true and left a stopped helper where it was (10-06, e2e).
            helpers.forEach { kill($0.processIdentifier, SIGKILL) }
        case .none:
            break
        }
    }

    func register() { lastLaunch = .distantPast; ensureHelper() }

    func send(_ body: [String: Any], label: String) {
        Task.detached {
            let reply = DeskMindIPC.request(body)
            await MainActor.run {
                let lang = ResolvedLang.current
                self.note(L("%@: %@", label, reply.map { "\($0)" } ?? L("no response", lang: lang), lang: lang))
            }
        }
    }

    func grant(_ g: Grant) {
        if g.byDrag {
            GrantPanelController.shared.show(g, model: self)
        } else {
            // The first request shows the system prompt; once refused, macOS never asks again and the switch is
            // only in System Settings, so send the user there.
            Task.detached {
                let reply = DeskMindIPC.request(["op": "request_permission", "which": "automation"], timeout: 60)
                await MainActor.run {
                    let result = reply?["automation"] as? String ?? L("no response", lang: ResolvedLang.current)
                    self.note(L("Automation: %@", result, lang: ResolvedLang.current))
                    if result != "granted" { NSWorkspace.shared.open(Grant.automation.settingsURL) }
                }
            }
        }
    }
}

// MARK: - Language

private struct LangKey: EnvironmentKey { static let defaultValue = ResolvedLang.en }

extension EnvironmentValues {
    /// The language views speak; set by LocalizedRoot from the "language" setting.
    var lang: ResolvedLang {
        get { self[LangKey.self] }
        set { self[LangKey.self] = newValue }
    }
}

/// The root of every window and panel: reads the language setting, hands it to the views below, and keeps
/// ResolvedLang.current (log lines, run messages, the "lang" of every request to the helper) in step with it.
/// A change re-renders everything under it at once.
struct LocalizedRoot<Content: View>: View {
    @AppStorage(AppLanguage.key) private var language = AppLanguage.system.rawValue
    @ViewBuilder let content: Content

    var body: some View {
        let lang = AppLanguage.resolve(language)
        content
            .environment(\.lang, lang)
            .onChange(of: lang, initial: true) { _, now in ResolvedLang.current = now }
    }
}

/// A compact menu: English, 中文, or follow the system. Each language is named in itself; "follow system" is
/// in the current one.
struct LanguagePicker: View {
    @AppStorage(AppLanguage.key) private var language = AppLanguage.system.rawValue
    @Environment(\.lang) private var lang

    func name(_ l: AppLanguage) -> String {
        switch l {
        case .en: "English"
        case .zhHans: "中文"
        case .system: L("Follow system", lang: lang)
        }
    }

    var body: some View {
        Menu {
            Picker(L("Language", lang: lang), selection: $language) {
                ForEach([AppLanguage.en, .zhHans, .system]) { Text(name($0)).tag($0.rawValue) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            Label(name(AppLanguage.choice(language)), systemImage: "globe")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(ShellColor.secondary)
        .help(L("Language", lang: lang))
    }
}

// MARK: - Onboarding

struct PermissionRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let done: Bool
    var optional = false
    var actionTitle: String? = nil   // "Allow" unless given
    var busy = false                 // something is under way: a spinner, not a button that invites a click
    var doneActionTitle: String? = nil   // a small action beside "Ready" (the helper's Restart)
    var doneAction: (() -> Void)? = nil
    let action: () -> Void
    @Environment(\.lang) private var lang

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(done ? Brand.dot.opacity(0.12) : Brand.mist.opacity(0.25)).frame(width: 36, height: 36)
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                    .foregroundStyle(done ? Brand.dot : Brand.sage)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Brand.ink)
                    if optional {
                        Text(L("Optional", lang: lang)).font(.system(size: 10, weight: .semibold)).foregroundStyle(ShellColor.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Brand.mist.opacity(0.3)))
                    }
                }
                // Two lines when needed: English copy runs longer than Chinese and was cut off mid-sentence.
                Text(subtitle).font(.system(size: 12)).foregroundStyle(ShellColor.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if busy && !done {
                ProgressView().controlSize(.small)
            } else if done {
                if let doneActionTitle, let doneAction {
                    Button(doneActionTitle, action: doneAction).buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(ShellColor.secondary).underline()
                }
                HStack(spacing: 6) {
                    Circle().fill(Brand.dot).frame(width: 7, height: 7)
                    Text(L("Ready", lang: lang)).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Brand.ink)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Brand.dot.opacity(0.10)))
                .transition(.scale.combined(with: .opacity))
            } else {
                Button(actionTitle ?? L("Allow", lang: lang), action: action).buttonStyle(InkButtonStyle(prominent: false))
            }
        }
        .padding(.vertical, 8)
    }
}

/// The local planner: DeskMind Brain served by the helper from the downloaded models.
struct BrainRow: View {
    @EnvironmentObject var model: HelperModel
    @EnvironmentObject var downloader: ModelDownloader
    @Environment(\.lang) private var lang

    var state: String { model.status["brain"] as? String ?? "stopped" }
    var transferring: Bool { [.downloading, .verifying, .paused].contains(downloader.phase) }
    var brainAction: String { model.status["brain_action"] as? String ?? "" }

    var subtitle: String {
        switch downloader.phase {
        case .verifying: return L("Verifying %@…", downloader.currentFile, lang: lang)
        case .failed(let why) where state != "ready": return why
        default: break
        }
        return switch state {
        case "ready": model.cloudEngine ? L("DeskMind Brain is running on this Mac and judges first; the cloud model sees what the task looks at.", lang: lang)
                                        : L("DeskMind Brain is running on this Mac. Nothing leaves it.", lang: lang)
        case "loading": L("Loading the model into memory… %d s so far (usually about 30 s)",
                          model.status["brain_uptime_s"] as? Int ?? 0, lang: lang)
        case "missing": L("Needs a model download: 0.8B + 4B, about 5.3 GB", lang: lang)
        // The hint comes from the helper, already in the language of the last status poll.
        case "failed": (model.status["brain_hint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? L("The model server didn't start. Click “Retry”.", lang: lang)
        default: L("Waiting for the helper to start", lang: lang)
        }
    }

    static func eta(_ t: TimeInterval?, lang: ResolvedLang) -> String {
        guard let t else { return L("estimating", lang: lang) }
        return t < 60 ? L("under a minute", lang: lang) : L("about %d min", Int(t / 60) + 1, lang: lang)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PermissionRow(symbol: "cpu", title: L("Local model", lang: lang),
                          subtitle: transferring && downloader.phase != .verifying
                            ? (downloader.phase == .paused ? L("Paused. Progress is saved.", lang: lang)
                                                           : L("Downloading %@", downloader.currentFile, lang: lang))
                            : subtitle,
                          done: state == "ready",
                          actionTitle: L(downloader.phase == .downloading ? "Pause"
                              : (downloader.phase == .paused ? "Resume"
                                 : (state == "missing" ? "Download" : (brainAction == "redownload" ? "Re-download" : "Retry"))),
                                         lang: lang),
                          busy: state == "loading" && !transferring) {
                switch downloader.phase {
                case .downloading: downloader.pause()
                case .paused: downloader.start()
                default:
                    if state == "failed" && brainAction == "redownload" {
                        downloader.onDone = { model.send(["op": "brain_status", "start": true], label: L("Local model", lang: lang)) }
                        downloader.repair()
                        return
                    }
                    if state == "missing" {
                        downloader.onDone = { model.send(["op": "brain_status", "start": true], label: L("Local model", lang: lang)) }
                        downloader.start()
                    } else {
                        model.send(["op": "brain_status", "start": true], label: L("Local model", lang: lang))
                    }
                }
            }
            .disabled(!model.helperReady || state == "loading" || downloader.phase == .verifying)
            .opacity(model.helperReady ? 1 : 0.45)
            HardwareNotes(modelsMissing: state == "missing")
            if state == "loading" && !transferring {
                ProgressView().progressViewStyle(.linear).tint(Brand.dot)
                    .padding(.leading, 50).padding(.bottom, 6)
            }
            if transferring {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: Double(downloader.bytesDone), total: Double(max(downloader.bytesTotal, 1)))
                        .tint(Brand.dot)
                    Text(downloader.phase == .downloading
                         ? L("%.2f / %.2f GB · %.1f MB/s · %@ left", Double(downloader.bytesDone) / 1e9,
                             Double(downloader.bytesTotal) / 1e9, downloader.speed / 1e6,
                             Self.eta(downloader.eta, lang: lang), lang: lang)
                         : String(format: "%.2f / %.2f GB", Double(downloader.bytesDone) / 1e9,
                                  Double(downloader.bytesTotal) / 1e9))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(ShellColor.secondary)
                }
                .padding(.leading, 50).padding(.bottom, 6)
            }
        }
    }
}

/// A first look at whether this Mac can run the models, said before the user waits for a download or a load that
/// will not work out. The OS already refuses the app on an Intel Mac or an older macOS (arm64 only,
/// LSMinimumSystemVersion); memory and disk are what is left to check.
enum Hardware {
    /// Physical memory in GB. DESKMIND_FAKE_MEM_GB stands in for it during development.
    static var memoryGB: Double {
        if let fake = ProcessInfo.processInfo.environment["DESKMIND_FAKE_MEM_GB"], let v = Double(fake) { return v }
        return Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }
    static var freeDiskGB: Double {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let v = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return Double(v) / 1e9
    }
    /// The two models and the runtime take about 7 GB of memory while they run; 16 GB leaves room for everything
    /// else. Below that the load can fail or swap, which looks like a hang.
    static func notes(lang: ResolvedLang, modelsMissing: Bool) -> [String] {
        var out: [String] = []
        let mem = memoryGB
        if mem < 12 {
            out.append(L("This Mac has %.0f GB of memory. The local model needs about 7 GB while it runs, so it may be slow or fail to load; quit other apps before starting.", mem, lang: lang))
        }
        let disk = freeDiskGB
        if modelsMissing && disk < 7.5 {
            out.append(L("Only %.1f GB of disk space is free. The download needs about 7.5 GB free; free up some space first.", disk, lang: lang))
        }
        return out
    }
}

struct HardwareNotes: View {
    let modelsMissing: Bool
    @Environment(\.lang) private var lang
    var body: some View {
        ForEach(Hardware.notes(lang: lang, modelsMissing: modelsMissing), id: \.self) { note in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ShellColor.orangeText)
                Text(note).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11)).foregroundStyle(Brand.ink)
            .padding(.leading, 50).padding(.bottom, 4)
        }
    }
}

struct DevTools: View {
    @EnvironmentObject var model: HelperModel
    @Environment(\.lang) private var lang
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(L("Capture test", lang: lang)) { model.send(["op": "capture_test"], label: L("Capture test", lang: lang)) }
                Button(L("Restart helper", lang: lang)) { model.send(["op": "restart"], label: L("Restart helper", lang: lang)) }
                Button(L("Open log", lang: lang)) {
                    NSWorkspace.shared.activateFileViewerSelecting([DeskMindIPC.supportDir.appendingPathComponent("brain.log")])
                }
                Text(L("Helper pid %@ · up %@ s", model.status["pid"].map { "\($0)" } ?? "—",
                       model.status["uptime_s"].map { "\($0)" } ?? "—", lang: lang))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(ShellColor.secondary)
                Spacer()
                LanguagePicker()
            }.buttonStyle(InkButtonStyle(prominent: false))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.log, id: \.self) {
                        Text($0).font(.system(size: 11).monospaced()).foregroundStyle(Brand.ink)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Brand.card))
        }
    }
}

/// The window's content: the main window (conversations, chat, the agent's column) -- the one window (A10).
struct AppRoot: View {
    @EnvironmentObject var downloader: ModelDownloader

    var body: some View {
        MainSplitView(shell: ShellModel.live)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                downloader.stashForQuit()
            }
    }
}

@main
struct DeskMindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = HelperModel()
    @StateObject private var downloader = ModelDownloader()
    @AppStorage(AppLanguage.key) private var language = AppLanguage.system.rawValue

    init() {
        // Before the helper model logs anything or sends its first request.
        ResolvedLang.current = AppLanguage.current()
        // The UI event log, this Mac only (Shared/UIEvents.swift); the switch is read from its file.
        UIEvents.log = UIEventLog(dir: DeskMindIPC.supportDir, file: UIEventLog.mainFile)
        _uiLogOn = State(initialValue: UIEvents.enabled)
        ActivationRecorder.start()
    }
    @State private var uiLogOn = true

    @AppStorage(DecisionPanel.alwaysKey) private var showDecisions = false
    @AppStorage(RunRecorder.includeMainKey) private var recordMainWindow = false
    @AppStorage(RunRecorder.wholeScreenKey) private var recordWholeScreen = false
    @AppStorage(RunRecorder.smoothKey) private var recordSmooth = false
    var body: some Scene {
        WindowGroup(L("DeskMind", lang: AppLanguage.resolve(language))) {
            LocalizedRoot {
                AppRoot().environmentObject(model).environmentObject(downloader)
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .toolbar) {
                // The decision panel outside recordings too: what the agent chose at each step and how sure it was.
                Toggle(L("Show Decisions While Running", lang: AppLanguage.resolve(language)),
                       isOn: $showDecisions)
                // A recording shows the task's apps and DeskMind's island; these add DeskMind's window, or everything.
                Toggle(L("Include DeskMind's Window in Recordings", lang: AppLanguage.resolve(language)),
                       isOn: $recordMainWindow)
                Toggle(L("Record the Whole Screen", lang: AppLanguage.resolve(language)),
                       isOn: $recordWholeScreen)
                // 30 fps for footage where motion matters; the default 10 fps barely slows the run.
                Toggle(L("Smooth Recordings (30 fps, Slows Tasks About 10%)", lang: AppLanguage.resolve(language)),
                       isOn: $recordSmooth)
                // What the interface did (cards, answers, activations), in a file on this Mac only: never uploaded.
                Toggle(L("Record Interface Use on This Mac", lang: AppLanguage.resolve(language)),
                       isOn: Binding(get: { uiLogOn }, set: { UIEvents.setEnabled($0) { now in uiLogOn = now } }))   // (as it is: a folder that refuses the switch's file keeps it)
                Button(L("Clear Interface Use Records", lang: AppLanguage.resolve(language))) {
                    // (done, or the user is told: the helper may hold the log's lock for a while)
                    UIEvents.clear { ok in
                        guard !ok else { return }
                        let a = NSAlert()
                        a.messageText = L("Couldn't clear the interface use records. Try again in a moment.", lang: AppLanguage.resolve(language))
                        a.runModal()
                    }
                }
                // The language of every screen and of what the session writes: the system's (default), or forced.
                Picker(L("Language", lang: AppLanguage.resolve(language)), selection: $language) {
                    Text(L("Follow system", lang: AppLanguage.resolve(language))).tag(AppLanguage.system.rawValue)
                    Text(verbatim: "中文").tag(AppLanguage.zhHans.rawValue)
                    Text(verbatim: "English").tag(AppLanguage.en.rawValue)
                }
            }
            // The window's keys (handoff §3.7).
            ShellCommands(lang: AppLanguage.resolve(language))
            // Help: where to report a problem, and the project.
            CommandGroup(replacing: .help) {
                Button(L("Report an Issue…", lang: AppLanguage.resolve(language))) {
                    NSWorkspace.shared.open(URL(string: IssueReport.repo + "/issues/new")!)
                }
                Button(L("DeskMind on GitHub", lang: AppLanguage.resolve(language))) {
                    NSWorkspace.shared.open(URL(string: IssueReport.repo)!)
                }
            }
        }
    }
}
