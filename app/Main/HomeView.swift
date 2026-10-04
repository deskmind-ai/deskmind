// The home screen: say what to do, optionally attach a folder, and start. Like a chat that may or may not have a
// folder attached -- with one, file work stays inside it; without one, DeskMind only operates apps and changes no
// files. The apps come from the instruction itself (AppScope), and a sheet shows them, the folder and what may
// happen before anything runs (ConfirmSheet). Setup (helper, permissions, models) sits below, folded away once it is
// all in place, and the last runs below that.

import Combine
import SwiftUI
import UniformTypeIdentifiers

/// An example instruction, of one of the three kinds the home screen offers.
struct GoalExample: Identifiable {
    enum Kind { case files, app, question }
    let kind: Kind
    let text: String   // an English key, shown through L()
    var id: String { text }

    /// The file example names the files the helper seeds in the sample folder, which differ by language (the zh
    /// table holds the Chinese one with the Chinese file names). The app ones use NetEase Cloud Music where it is
    /// installed -- the app vision mode was built on -- and Safari, which every Mac has, elsewhere.
    static var all: [GoalExample] {
        let netease = AppScope.isInstalled("com.netease.163music")
        return [
            GoalExample(kind: .files, text: "Make a folder called Receipts and move expenses.csv into it"),
            GoalExample(kind: .app, text: netease ? "Open NetEase Cloud Music, search 张悬 宝贝 and play it"
                                                  : "Open Safari and search for the weather in Singapore"),
            GoalExample(kind: .question, text: netease ? "In NetEase Cloud Music, search 夜空中最亮的星 — who sings the first song?"
                                                       : "In Safari, search for the height of Mount Everest — how tall is it?"),
        ]
    }

    var symbol: String {
        switch kind {
        case .files: "doc.on.doc"
        case .app: "macwindow"
        case .question: "questionmark.circle"
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var model: HelperModel
    @EnvironmentObject var history: RunHistory
    @Binding var goal: String
    @Binding var folder: String?
    let onRun: (GoalRequest) -> Void
    let onOpen: (RunRecord) -> Void
    let onExamples: () -> Void

    @EnvironmentObject var eyes: EyesDownloader
    @State private var showDev = false
    @State private var showSetup = false
    @State private var dropping = false
    @State private var folderNote = ""
    @State private var confirming: GoalRequest?
    @State private var confirmReset = false
    @State private var samplePath = ""
    /// What the sample folder holds (the helper lists it): which expenses file the file example names.
    @State private var sampleFiles: [String] = []
    /// The files directly in the attached folder: the file example names one of them, or is not offered.
    @State private var folderFiles: [String] = []
    @State private var confirmClear = false
    @State private var hovered: UUID?
    @FocusState private var promptFocused: Bool
    @Environment(\.lang) private var lang

    private var trimmed: String { goal.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var apps: [ResolvedApp] { AppScope.resolve(trimmed) }
    /// Nothing named and no folder: there is nothing to work in yet.
    private var needsApp: Bool { !trimmed.isEmpty && apps.isEmpty && folder == nil }
    /// Files the instruction names with no folder attached: said before the run, with the way to attach one. Not a
    /// block -- the files may already be open in their app.
    private var filesWithoutFolder: [String] { folder == nil ? FileMention.named(in: trimmed) : [] }
    private var canStart: Bool { !trimmed.isEmpty && !needsApp && model.requiredDone }
    private var isSample: Bool { folder != nil && folder == samplePath }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                XiaoFang(mood: model.requiredDone ? (trimmed.isEmpty ? .rest : .idle) : .notice, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("What should DeskMind do?", lang: lang))
                        .font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Brand.ink)
                    Text(model.requiredDone ? L("Everything runs on this Mac, offline.", lang: lang)
                                            : L("Finish the setup below first.", lang: lang))
                        .font(.system(size: 12)).foregroundStyle(Brand.sage)
                }
                Spacer()
            }
            .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 14)

            prompt.padding(.horizontal, 28)
            scopeLine.padding(.horizontal, 32).padding(.top, 6)
            examples.padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SetupCard(expanded: $showSetup)
                    if !history.records.isEmpty { recent }
                }
                .padding(.horizontal, 28).padding(.vertical, 14)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Button(showDev ? L("Hide developer tools", lang: lang) : L("Developer tools", lang: lang)) { withAnimation { showDev.toggle() } }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Brand.sage)
                // The licences of everything shipped, one text file in the bundle (tools/make_notices.py).
                Button(L("Open-source notices", lang: lang)) {
                    if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Brand.sage)
                // The project, always one click away (issues, the source, a star).
                Button("GitHub") { NSWorkspace.shared.open(URL(string: IssueReport.repo)!) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Brand.sage)
                    .help(L("DeskMind on GitHub", lang: lang))
                Spacer()
                // The mock desktop's smoke set and the sandbox tasks: open once the permissions are in place.
                Button(L("Self-test", lang: lang)) { onExamples() }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.ink)
                    .disabled(!model.permissionsDone).opacity(model.permissionsDone ? 1 : 0.4)
            }
            .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, showDev ? 8 : 20)

            if showDev { DevTools().padding(.horizontal, 28).padding(.bottom, 16) }
        }
        .frame(width: 560, height: 720)
        .background(Brand.paper)
        .overlay(alignment: .topTrailing) { LanguagePicker().padding(.top, 14).padding(.trailing, 18) }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in attach(url) }
            }
            return true
        }
        .onAppear {
            // Folded away once everything is ready; open while something still needs the user.
            showSetup = !model.requiredDone
            loadSample()
            folderFiles = folder.map(FileExample.files(at:)) ?? []
        }
        .onChange(of: folder) { _, f in folderFiles = f.map(FileExample.files(at:)) ?? [] }
        // Status arrives a second after launch: fold the card when everything turns out ready, open it again if
        // something stops being so (a permission revoked, the model server failed).
        .onChange(of: model.requiredDone) { _, done in withAnimation { showSetup = !done } }
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
        // The instruction names its apps as it is typed: the helper starts loading what they need (the vision model
        // for an app it can only see) while the user finishes typing and reads the confirmation.
        .onChange(of: apps.map(\.bundleID)) { _, bundles in prewarm(bundles) }
        .alert(L("Clear the recent tasks?", lang: lang), isPresented: $confirmClear) {
            Button(L("Clear all", lang: lang), role: .destructive) {
                withAnimation { history.clear() }
                DispatchQueue.global().async { _ = DeskMindIPC.request(["op": "clear_runs"]) }
            }
            Button(L("Cancel", lang: lang), role: .cancel) {}
        } message: {
            Text(L("This also deletes their step screenshots and records from this Mac. Recordings stay in Movies › DeskMind.", lang: lang))
        }
        .alert(L("Put the sample folder back to its sample files? Everything else in it is removed.", lang: lang),
               isPresented: $confirmReset) {
            Button(L("Reset folder", lang: lang), role: .destructive) { loadSample(reset: true) }
            Button(L("Cancel", lang: lang), role: .cancel) {}
        }
    }

    // MARK: prompt

    @ViewBuilder var prompt: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Return starts; Option-Return makes a new line (a vertical TextField's own behaviour).
            TextField(L("Describe a task in your own words…", lang: lang), text: $goal, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .rounded)).foregroundStyle(Brand.ink)
                .padding(12)
                .focused($promptFocused)
                .onSubmit(start)
            Rectangle().fill(Brand.line).frame(height: 1)
            HStack(spacing: 8) {
                if let folder {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(Brand.sage)
                        Text(isSample ? L("Sample folder", lang: lang) : (folder as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11).monospaced()).foregroundStyle(Brand.ink)
                            .lineLimit(1).truncationMode(.middle)
                        Button { self.folder = nil } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Brand.mist)
                        }
                        .buttonStyle(.plain).help(L("Remove the folder", lang: lang))
                        // Without a label VoiceOver (and our own UI tests) read the system symbol's Chinese name, "关闭".
                        .accessibilityLabel(L("Remove the folder", lang: lang))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Brand.paper))
                    if isSample {
                        Button(L("Show in Finder", lang: lang)) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
                        }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.ink)
                        Button(L("Reset", lang: lang)) { confirmReset = true }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.dot)
                    }
                } else {
                    Button { pickFolder() } label: {
                        Label(L("Attach folder", lang: lang), systemImage: "folder.badge.plus").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(Brand.ink)
                    Button(L("Use the sample folder", lang: lang)) { useSample() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Brand.sage)
                        .disabled(!model.helperReady)
                }
                Spacer()
                Button(L("Start", lang: lang), action: start)
                    .buttonStyle(InkButtonStyle())
                    .disabled(!canStart).opacity(canStart ? 1 : 0.45)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(dropping ? Brand.dot : Brand.line, lineWidth: dropping ? 2 : 1))
    }

    /// What the instruction will use, or what is missing, in one line under the prompt.
    @ViewBuilder var scopeLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if !folderNote.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.dot)
                Text(folderNote).fixedSize(horizontal: false, vertical: true)
            } else if !filesWithoutFolder.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.dot)
                Text(L("The instruction names %@, but no folder is attached. Attach the folder they're in, or open them first.",
                       filesWithoutFolder.joined(separator: ", "), lang: lang))
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Attach folder", lang: lang)) { pickFolder() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.ink)
                Spacer(minLength: 0)
            } else if needsApp {
                Image(systemName: "questionmark.circle.fill").foregroundStyle(Brand.dot)
                Text(L("Which app should it use? Name it in the instruction, or attach a folder.", lang: lang))
                    .fixedSize(horizontal: false, vertical: true)
            } else if !trimmed.isEmpty {
                let shown = apps.isEmpty ? [AppScope.finder] : apps
                Text(L("Uses", lang: lang)).foregroundStyle(Brand.sage)
                ForEach(shown, id: \.bundleID) { a in
                    HStack(spacing: 3) {
                        Image(nsImage: a.icon).resizable().frame(width: 13, height: 13).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                        Text(a.displayName(lang))
                    }
                }
                Text(folder == nil ? L("· no files will be changed", lang: lang) : L("· files only in the attached folder", lang: lang))
                    .foregroundStyle(Brand.sage)
                Spacer(minLength: 0)
            } else {
                Text(" ")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11)).foregroundStyle(Brand.ink)
    }

    /// One per row, so every example is seen: side by side in a sideways scroller, the second was cut off and the
    /// third off screen, and a mouse wheel does not scroll sideways.
    @ViewBuilder var examples: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(GoalExample.all.filter { $0.kind != .files || label(e: $0) != nil }) { e in
                Button { use(e) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: e.symbol).font(.system(size: 10)).foregroundStyle(Brand.sage)
                        Text(label(e: e) ?? "").font(.system(size: 11)).foregroundStyle(Brand.ink).lineLimit(1).truncationMode(.tail)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Brand.card))
                    .overlay(Capsule().strokeBorder(Brand.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(label(e: e) ?? "")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
    }

    /// An example's words. The file example names a file the folder it works in really holds (FileExample): the
    /// attached folder's, or with none attached the sample folder's (seeded once, in the language of the moment --
    /// the language may have changed since). nil: the attached folder has no file to name, and the example is not
    /// offered.
    private func label(e: GoalExample) -> String? {
        guard e.kind == .files else { return L(e.text, lang: lang) }
        let file: String?
        if let folder, folder != samplePath {
            file = FileExample.file(in: folderFiles)
        } else {
            // The sample folder's listing comes from the helper a moment after launch; until then, the language's.
            file = FileExample.file(in: folder == nil ? sampleFiles : folderFiles)
                ?? (sampleFiles.isEmpty ? (lang == .zhHans ? "报销单.csv" : "expenses.csv") : nil)
        }
        return file.map { L("Make a folder called Receipts and move %@ into it", $0, lang: lang) }
    }

    @ViewBuilder var recent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Recent", lang: lang)).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Brand.sage)
                Spacer()
                Button(L("Clear all", lang: lang)) { confirmClear = true }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Brand.sage)
            }
            VStack(spacing: 0) {
                ForEach(Array(history.records.enumerated()), id: \.element.id) { i, r in
                    if i > 0 { Divider().overlay(Brand.line) }
                    // A past instruction is put back in the box, to run again as it is or edited first; what that
                    // run did is in its context menu.
                    Button { goal = r.goal; promptFocused = true } label: {
                        HStack(spacing: 10) {
                            Circle().fill(r.errored ? Brand.mist : (r.finished ? Brand.dot : Brand.mist)).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.goal).font(.system(size: 13, design: .rounded)).foregroundStyle(Brand.ink).lineLimit(1)
                                Text(r.answer.isEmpty ? r.summary : L("Answer: %@", r.answer, lang: lang))
                                    .font(.system(size: 11)).foregroundStyle(Brand.sage).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            if hovered == r.id {
                                // Forgets the run only; a recording of it stays in Movies › DeskMind.
                                Button { withAnimation { history.remove([r.id]) } } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Brand.mist)
                                }
                                .buttonStyle(.plain).help(L("Remove from the list", lang: lang))
                                .accessibilityLabel(L("Remove from the list", lang: lang))
                            } else {
                                Text(r.date.formatted(.relative(presentation: .named).locale(Locale(identifier: lang == .zhHans ? "zh-Hans" : "en"))))   // the app's language, not the system's
                                    .font(.system(size: 11)).foregroundStyle(Brand.mist)
                            }
                        }
                        .padding(.vertical, 7).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { h in hovered = h ? r.id : (hovered == r.id ? nil : hovered) }
                    .contextMenu {
                        Button(L("Show What It Did", lang: lang)) { onOpen(r) }
                        Button(L("Remove from the list", lang: lang)) { withAnimation { history.remove([r.id]) } }
                        if let m = r.movie, FileManager.default.fileExists(atPath: m) {
                            Button(L("Show Recording in Finder", lang: lang)) {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: m)])
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.card))
        }
    }

    // MARK: actions

    private func start() {
        guard canStart else { return }
        let r = GoalRequest(goal: trimmed, folder: folder, apps: apps)
        prewarm(r.displayApps.map(\.bundleID))
        if ConfirmSheet.canSkip(r) { onRun(r) } else { confirming = r }
    }

    /// See Runner.prewarm in the helper. Fire and forget: nothing waits on it.
    private func prewarm(_ bundles: [String]) {
        guard !bundles.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { _ = DeskMindIPC.request(["op": "prewarm", "bundles": bundles], timeout: 5) }
    }

    private func use(_ e: GoalExample) {
        switch e.kind {
        // The file example is about the sample files: attach the sample folder unless a folder is attached, and word
        // it from what that folder holds once it is attached (its listing comes with it).
        case .files:
            if folder == nil {
                loadSample { path in folder = path; folderNote = ""; folderFiles = FileExample.files(at: path); goal = label(e: e) ?? "" }
            } else {
                goal = label(e: e) ?? ""
            }
            return
        // An app example changes no files: the sample folder, if it was attached for the file example, goes.
        case .app, .question: if isSample { folder = nil }
        }
        goal = label(e: e) ?? ""
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = L("Attach", lang: lang)
        panel.message = L("DeskMind will only change files inside this folder.", lang: lang)
        if panel.runModal() == .OK, let url = panel.url { attach(url) }
    }

    /// Attach a folder, unless it is one hands refuses to work in (a home folder, a system root): said here, not
    /// after the run has started.
    private func attach(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            folderNote = L("That isn't a folder. Drop or choose a folder.", lang: lang); return
        }
        let path = url.standardizedFileURL.path
        let refused: Set<String> = ["/", "/Users", "/System", "/Library", "/Applications", "/Volumes", "/private",
                                    "/usr", "/bin", "/etc", NSHomeDirectory()]
        if refused.contains(path) || path.hasPrefix("/System/") {
            folderNote = L("Pick a folder inside your home folder, not the whole home folder or a system folder.", lang: lang)
            return
        }
        folderNote = ""
        folder = path
    }

    private func useSample() {
        loadSample { path in folder = path; folderNote = "" }
    }

    /// Ask the helper for the sample folder (it creates and seeds it if needed), or reset it to the samples.
    private func loadSample(reset: Bool = false, then: ((String) -> Void)? = nil) {
        Task.detached {
            let r = DeskMindIPC.request(["op": "playground", "reset": reset])
            await MainActor.run {
                guard let r, r["ok"] as? Bool == true, let path = r["path"] as? String else { return }
                samplePath = path
                sampleFiles = r["files"] as? [String] ?? []
                then?(path)
            }
        }
    }
}

/// Before each run: the apps it will use, the folder (or that there is none), and what may happen on screen. Each
/// app can be ticked "don't ask again"; the sheet is skipped when every app of a run is ticked for the same kind of
/// run (with a folder, or without one) -- a folder task and an app-only task are different promises.
struct ConfirmSheet: View {
    let request: GoalRequest
    let onStart: (Bool) -> Void
    let onCancel: () -> Void
    @EnvironmentObject var eyes: EyesDownloader
    @State private var remember: Set<String> = []
    @AppStorage("record.default") private var record = false
    @Environment(\.lang) private var lang

    static let key = "confirm.skip"
    static func rememberKey(_ bundle: String, folder: Bool) -> String { "\(bundle)|\(folder ? "folder" : "none")" }
    static var remembered: Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }

    static func canSkip(_ r: GoalRequest) -> Bool {
        // Never skipped when it would hide that the vision model is missing for a task that may need it.
        if r.mayNeedVision && DeskMindModels.eyesDir() == nil { return false }
        let have = remembered
        return r.displayApps.allSatisfy { have.contains(rememberKey($0.bundleID, folder: r.folder != nil)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Before DeskMind starts", lang: lang)).font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.ink)
            Text(request.goal).font(.system(size: 13, design: .rounded)).foregroundStyle(Brand.sage).lineLimit(3)

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Apps it will use", lang: lang)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.sage)
                ForEach(request.displayApps, id: \.bundleID) { a in
                    HStack(spacing: 10) {
                        Image(nsImage: a.icon).resizable().frame(width: 28, height: 28)
                        Text(a.displayName(lang)).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(Brand.ink)
                        Spacer()
                        // Not while the vision model is missing: the sheet is shown for that anyway (see skip), and a
                        // box that changes nothing is a broken promise.
                        if !(request.mayNeedVision && DeskMindModels.eyesDir() == nil) {
                            Toggle(L("Don't ask again for this app", lang: lang), isOn: Binding(
                                get: { remember.contains(a.bundleID) },
                                set: { on in if on { remember.insert(a.bundleID) } else { remember.remove(a.bundleID) } }))
                                .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(Brand.sage)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Folder", lang: lang)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.sage)
                HStack(spacing: 8) {
                    Image(systemName: request.folder == nil ? "folder.badge.minus" : "folder.fill").foregroundStyle(Brand.sage)
                    Text(request.folder.map { ($0 as NSString).abbreviatingWithTildeInPath }
                         ?? L("No folder — no files will be changed", lang: lang))
                        .font(.system(size: 12).monospaced()).foregroundStyle(Brand.ink).lineLimit(1).truncationMode(.middle)
                }
            }

            Toggle(isOn: $record) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Record this run", lang: lang)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.ink)
                    Text(L("Only the apps this task uses are recorded, other apps stay out; it goes to Movies › DeskMind.", lang: lang))
                        .font(.system(size: 11)).foregroundStyle(Brand.sage)
                }
            }
            .toggleStyle(.checkbox)

            note("hand.raised",
                 L("Sending, deleting, paying, publishing or sharing waits for your approval first.", lang: lang))
            note("cursorarrow.motionlines",
                 L("Apps that can't be read through accessibility may be brought to the front for a moment. Touching the mouse or keyboard pauses DeskMind.", lang: lang))
            if request.mayNeedVision && DeskMindModels.eyesDir() == nil { eyesNote }

            HStack {
                Spacer()
                Button(L("Cancel", lang: lang), action: onCancel).buttonStyle(InkButtonStyle(prominent: false))
                    .keyboardShortcut(.cancelAction)
                Button(L("Start", lang: lang)) {
                    var have = Self.remembered
                    for a in request.displayApps {
                        let k = Self.rememberKey(a.bundleID, folder: request.folder != nil)
                        if remember.contains(a.bundleID) { have.insert(k) } else { have.remove(k) }
                    }
                    UserDefaults.standard.set(Array(have).sorted(), forKey: Self.key)
                    onStart(record)
                }
                .buttonStyle(InkButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Brand.paper)
        .onAppear {
            let have = Self.remembered
            remember = Set(request.displayApps.map(\.bundleID)
                .filter { have.contains(Self.rememberKey($0, folder: request.folder != nil)) })
        }
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Brand.dot)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12)).foregroundStyle(Brand.ink)
    }

    /// The vision model is not here yet: say so, and offer the download right here.
    @ViewBuilder var eyesNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Optional, and said so: the Safari example showed this as if a second big download stood between the user
            // and their first task.
            note("eye", L("Optional: for an app whose window can't be read through accessibility (NetEase Cloud Music and the like), DeskMind uses a vision model, a one-time 3.3 GB download. You can start without it.", lang: lang))
            HStack(spacing: 8) {
                EyesProgress()
                Spacer()
                EyesButton()
            }
            .padding(.leading, 22)
        }
    }
}

// MARK: - Setup

/// Everything a run needs, in one card: the helper, the models and the permissions. Folded into one line once the
/// required ones are all in place.
struct SetupCard: View {
    @EnvironmentObject var model: HelperModel
    @Binding var expanded: Bool
    @Environment(\.lang) private var lang

    var body: some View {
        VStack(spacing: 0) {
            if model.requiredDone {
                HStack(spacing: 8) {
                    Circle().fill(Brand.dot).frame(width: 7, height: 7)
                    Text(L("Setup · everything is ready", lang: lang))
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Brand.ink)
                    Spacer()
                    Button(expanded ? L("Hide setup", lang: lang) : L("Show setup", lang: lang)) {
                        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                    }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.sage)
                }
                .padding(.vertical, 10)
                if expanded { Divider().overlay(Brand.line) }
            }
            if expanded || !model.requiredDone {
                PermissionRow(symbol: "person.badge.clock", title: L("Background helper", lang: lang),
                              subtitle: model.helperReady
                                  ? L("DeskMind Hands is standing by. Restarting it won't close this window.", lang: lang)
                                  : (model.launching ? L("Starting DeskMind Hands…", lang: lang)
                                                     : L("DeskMind Hands isn't running", lang: lang)),
                              done: model.helperReady, actionTitle: L("Launch", lang: lang)) {
                    model.register()
                }
                Divider().overlay(Brand.line)
                BrainRow()
                Divider().overlay(Brand.line)
                EyesRow()
                ForEach(Grant.allCases) { g in
                    Divider().overlay(Brand.line)
                    PermissionRow(symbol: g.symbol, title: g.title(lang), subtitle: g.subtitle(lang),
                                  done: model.granted(g), optional: !g.required) { model.grant(g) }
                        .disabled(!model.helperReady)
                        .opacity(model.helperReady ? 1 : 0.45)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.card)
            .shadow(color: Brand.ink.opacity(0.06), radius: 10, y: 3))
    }
}

/// The vision model's own downloader: the Eyes role only, started by the user (its row, or the confirmation sheet).
@MainActor
final class EyesDownloader: ObservableObject {
    let downloader = ModelDownloader(roles: [.eyes])
    private var sink: Any?
    init() {
        // Re-publish the inner downloader's changes, so views observing this object follow the progress.
        sink = downloader.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

/// The vision model's row: optional, downloaded on demand, 3.3 GB.
struct EyesRow: View {
    @EnvironmentObject var model: HelperModel
    @EnvironmentObject var eyes: EyesDownloader
    @Environment(\.lang) private var lang

    var body: some View {
        let d = eyes.downloader
        VStack(alignment: .leading, spacing: 6) {
            PermissionRow(symbol: "eye", title: L("Vision model", lang: lang),
                          subtitle: model.eyesPresent ? L("For apps without accessibility. Loaded only while a task needs it.", lang: lang)
                                                      : EyesProgress.subtitle(d, lang: lang),
                          done: model.eyesPresent, optional: true,
                          actionTitle: EyesButton.title(d, lang: lang)) {
                EyesButton.act(d, model: model)
            }
            .disabled(d.phase == .verifying)
            if [.downloading, .verifying, .paused].contains(d.phase) && !model.eyesPresent {
                EyesProgress().padding(.leading, 50).padding(.bottom, 6)
            }
        }
    }
}

/// The download's bar and numbers.
struct EyesProgress: View {
    @EnvironmentObject var eyes: EyesDownloader
    @Environment(\.lang) private var lang

    static func subtitle(_ d: ModelDownloader, lang: ResolvedLang) -> String {
        switch d.phase {
        case .downloading: return L("Downloading %@", d.currentFile, lang: lang)
        case .paused: return L("Paused. Progress is saved.", lang: lang)
        case .verifying: return L("Verifying %@…", d.currentFile, lang: lang)
        case .failed(let why): return why
        default: return L("For apps without accessibility (NetEase Cloud Music and the like). Download 3.3 GB", lang: lang)
        }
    }

    var body: some View {
        let d = eyes.downloader
        if [.downloading, .verifying, .paused].contains(d.phase) {
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: Double(d.bytesDone), total: Double(max(d.bytesTotal, 1))).tint(Brand.dot)
                Text(d.phase == .downloading
                     ? L("%.2f / %.2f GB · %.1f MB/s · %@ left", Double(d.bytesDone) / 1e9, Double(d.bytesTotal) / 1e9,
                         d.speed / 1e6, BrainRow.eta(d.eta, lang: lang), lang: lang)
                     : String(format: "%.2f / %.2f GB", Double(d.bytesDone) / 1e9, Double(d.bytesTotal) / 1e9))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Brand.sage)
            }
        } else if case .failed(let why) = d.phase {
            Text(why).font(.system(size: 11)).foregroundStyle(Brand.dot).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Download / Pause / Resume for the vision model.
struct EyesButton: View {
    @EnvironmentObject var model: HelperModel
    @EnvironmentObject var eyes: EyesDownloader
    @Environment(\.lang) private var lang

    static func title(_ d: ModelDownloader, lang: ResolvedLang) -> String {
        switch d.phase {
        case .downloading: L("Pause", lang: lang)
        case .paused: L("Resume", lang: lang)
        default: L("Download 3.3 GB", lang: lang)
        }
    }

    static func act(_ d: ModelDownloader, model: HelperModel) {
        switch d.phase {
        case .downloading: d.pause()
        default:
            d.onDone = { model.poll() }
            d.start()
        }
    }

    var body: some View {
        let d = eyes.downloader
        if model.eyesPresent || d.phase == .done {
            Text(L("Ready", lang: lang)).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Brand.ink)
        } else {
            Button(Self.title(d, lang: lang)) { Self.act(d, model: model) }
                .buttonStyle(InkButtonStyle(prominent: false))
                .disabled(d.phase == .verifying)
        }
    }
}
