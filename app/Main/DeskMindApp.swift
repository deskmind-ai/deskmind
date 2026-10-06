// DeskMind.app (prototype): the window the user keeps open. It holds no special permission; it registers the
// helper with launchd, walks the user through granting the helper's permissions (the setup card on the home
// screen, HomeView), and reconnects whenever the helper restarts.

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
    @Published var launching = false

    /// Start the helper if it is not answering; it is also how a restart completes (the helper exits, we relaunch).
    func ensureHelper() {
        guard !connected, Date().timeIntervalSince(lastLaunch) > 3 else { return }
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
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        cfg.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: helperURL, configuration: cfg) { _, error in
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
    /// "Ready" means a real task can run: permissions and the local model both.
    var requiredDone: Bool { permissionsDone && brainReady }

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
                if was != self.connected {
                    let lang = ResolvedLang.current
                    self.note(self.connected ? L("Helper connected (pid %@)", "\(reply?["pid"] ?? "?")", lang: lang)
                                             : L("Helper disconnected. Waiting to reconnect…", lang: lang))
                }
                if !self.connected { self.ensureHelper() }
                // A helper still running from inside DeskMind.app (started before the hand-over existed, or by
                // something that bypassed it): its Screen Recording counts as DeskMind's. Replace it with the
                // installed copy.
                if self.connected, HelperLocation.isWrongCopy(runningPath: reply?["path"] as? String,
                                                              installedPath: helperURL.path) {
                    self.note(L("Restarting the helper from its installed copy", lang: ResolvedLang.current))
                    for app in NSRunningApplication.runningApplications(withBundleIdentifier: "ai.deskmind.hands") {
                        app.terminate()
                    }
                }
            }
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
    @AppStorage("language") private var language = AppLanguage.system.rawValue
    @ViewBuilder let content: Content

    var body: some View {
        let lang = (AppLanguage(rawValue: language) ?? .en).resolved
        content
            .environment(\.lang, lang)
            .onChange(of: lang, initial: true) { _, now in ResolvedLang.current = now }
    }
}

/// A compact menu: English, 简体中文, or follow the system. Each language is named in itself; "follow system" is
/// in the current one.
struct LanguagePicker: View {
    @AppStorage("language") private var language = AppLanguage.system.rawValue
    @Environment(\.lang) private var lang

    func name(_ l: AppLanguage) -> String {
        switch l {
        case .en: "English"
        case .zhHans: "简体中文"
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
            Label(name(AppLanguage(rawValue: language) ?? .en), systemImage: "globe")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(Brand.sage)
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
                        Text(L("Optional", lang: lang)).font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.sage)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Brand.mist.opacity(0.3)))
                    }
                }
                // Two lines when needed: English copy runs longer than Chinese and was cut off mid-sentence.
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Brand.sage)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if busy && !done {
                ProgressView().controlSize(.small)
            } else if done {
                if let doneActionTitle, let doneAction {
                    Button(doneActionTitle, action: doneAction).buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.sage).underline()
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
        case "ready": L("DeskMind Brain is running on this Mac. Nothing leaves it.", lang: lang)
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
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(Brand.sage)
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
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.dot)
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
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Brand.sage)
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

/// Home, a run of the user's own instruction (new, or a past one from the recent list), or the examples screen.
struct RootView: View {
    enum Screen { case home, run(GoalRequest), record(RunRecord), examples }
    @EnvironmentObject var model: HelperModel
    @EnvironmentObject var downloader: ModelDownloader
    @State private var screen: Screen = .home
    // The prompt and its folder live here, not in HomeView: a run's "Edit" brings them back as they were.
    @State private var goal = ""
    @State private var folder: String?

    private func go(_ s: Screen) { withAnimation(.easeInOut(duration: 0.25)) { screen = s } }

    var body: some View {
        ZStack {
            switch screen {
            case .home:
                HomeView(goal: $goal, folder: $folder,
                         onRun: { go(.run($0)) }, onOpen: { go(.record($0)) }, onExamples: { go(.examples) })
                    .transition(.move(edge: .leading).combined(with: .opacity))
            case .run(let r):
                GoalRunView(request: r, onBack: { go(.home) }, onEdit: edit, onRun: { go(.run($0)) })
                    .id(r.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .record(let r):
                GoalRunView(request: nil, record: r, onBack: { go(.home) }, onEdit: edit, onRun: { go(.run($0)) })
                    .id(r.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .examples:
                RunView { go(.home) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(Brand.paper)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            downloader.stashForQuit()
        }
    }

    private func edit(_ r: GoalRequest) {
        goal = r.goal; folder = r.folder
        go(.home)
    }
}

@main
struct DeskMindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = HelperModel()
    @StateObject private var downloader = ModelDownloader()
    @StateObject private var eyes = EyesDownloader()
    @StateObject private var history = RunHistory.shared
    @AppStorage("language") private var language = AppLanguage.system.rawValue

    init() {
        // Before the helper model logs anything or sends its first request.
        let stored = UserDefaults.standard.string(forKey: "language") ?? AppLanguage.system.rawValue
        ResolvedLang.current = (AppLanguage(rawValue: stored) ?? .en).resolved
    }

    @AppStorage(DecisionPanel.alwaysKey) private var showDecisions = false
    @AppStorage(RunRecorder.includeMainKey) private var recordMainWindow = false
    @AppStorage(RunRecorder.wholeScreenKey) private var recordWholeScreen = false
    @AppStorage(RunRecorder.smoothKey) private var recordSmooth = false
    @AppStorage(MainWindow.keepOpenKey) private var keepOpen = false
    @AppStorage(LiveView.enabledKey) private var liveView = true
    var body: some Scene {
        WindowGroup(L("DeskMind", lang: (AppLanguage(rawValue: language) ?? .en).resolved)) {
            LocalizedRoot {
                RootView().environmentObject(model).environmentObject(downloader)
                    .environmentObject(eyes).environmentObject(history)
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .toolbar) {
                // The decision panel outside recordings too: what the agent chose at each step and how sure it was.
                Toggle(L("Show Decisions While Running", lang: (AppLanguage(rawValue: language) ?? .en).resolved),
                       isOn: $showDecisions)
                // A recording shows the task's apps and DeskMind's island; these add DeskMind's window, or everything.
                Toggle(L("Include DeskMind's Window in Recordings", lang: (AppLanguage(rawValue: language) ?? .en).resolved),
                       isOn: $recordMainWindow)
                Toggle(L("Record the Whole Screen", lang: (AppLanguage(rawValue: language) ?? .en).resolved),
                       isOn: $recordWholeScreen)
                // 30 fps for footage where motion matters; the default 10 fps barely slows the run.
                Toggle(L("Smooth Recordings (30 fps, Slows Tasks About 10%)", lang: (AppLanguage(rawValue: language) ?? .en).resolved),
                       isOn: $recordSmooth)
                // By default the window steps aside while a task works in other apps (the status stays at the top).
                Toggle(L("Keep DeskMind Open While a Task Runs", lang: (AppLanguage(rawValue: language) ?? .en).resolved),
                       isOn: $keepOpen)
                // A corner card with the window the task works in, live, and the step it is taking.
                Toggle(L("Show a Live View of the Task", lang: (AppLanguage(rawValue: language) ?? .en).resolved),
                       isOn: $liveView)
            }
            // Help: where to report a problem, and the project.
            CommandGroup(replacing: .help) {
                Button(L("Report an Issue…", lang: (AppLanguage(rawValue: language) ?? .en).resolved)) {
                    NSWorkspace.shared.open(URL(string: IssueReport.repo + "/issues/new")!)
                }
                Button(L("DeskMind on GitHub", lang: (AppLanguage(rawValue: language) ?? .en).resolved)) {
                    NSWorkspace.shared.open(URL(string: IssueReport.repo)!)
                }
            }
        }
    }
}
