// The cloud model's settings: which service thinks for the harness engine and the key for it. The provider list is
// the harness's provider table (src/gateway/index.ts PROVIDERS); a custom entry takes any OpenAI-compatible
// service (URL, key, model id). Keys live in the helper's keychain item (A11: Shared/ModelStore.swift): this app
// writes them through the helper (keys.set) and is told only whether each is set and its last 4 characters
// (keys.status) -- it never reads a key back; never in defaults, never logged.

import Foundation
import SwiftUI

/// What the helper says of the model settings (keys.status): each key by its last 4 characters, the settings that are
/// no secret (a custom service's URL and model), the digest the helper computes over all of it. Read from any thread.
final class KeyStatus: ObservableObject {
    static let shared = KeyStatus()
    struct Snapshot: Equatable {
        /// Key name -> its last 4 characters.
        var keys: [String: String] = [:]
        var settings: [String: String] = [:]
        var digest: String?
        /// False: the helper could not read them (the keychain refused, no file) -- not "none set".
        var readable = true
        /// The helper has answered once.
        var known = false
    }
    @Published private(set) var snapshot = Snapshot()
    private let lock = NSLock()
    private var current = Snapshot()

    var now: Snapshot { lock.lock(); defer { lock.unlock() }; return current }

    /// Asks the helper (off the main thread; the answer applied on it).
    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let r = DeskMindIPC.request(["op": "keys.status"], timeout: 5), r["ok"] as? Bool == true else { return }
            self?.apply(r)
        }
    }

    /// A keys.status or keys.set answer.
    func apply(_ r: [String: Any]) {
        var s = Snapshot(known: true)
        s.readable = r["readable"] as? Bool ?? false
        s.keys = r["keys"] as? [String: String] ?? [:]
        s.settings = r["settings"] as? [String: String] ?? [:]
        s.digest = r["digest"] as? String
        lock.lock(); let changed = current != s; current = s; lock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { self.snapshot = s }
    }
}

/// What is saved: the provider, its key and (custom) URL + model -- the helper's keychain item (keys.set) and two
/// defaults.
enum CloudModelSettings {
    enum SaveError: Error, LocalizedError {
        case refused(String)
        var errorDescription: String? { if case .refused(let why) = self { return why }; return nil }
    }

    /// A change, merged by the helper into what it keeps (other services' keys stay: switching providers loses
    /// nothing). Synchronous (the helper answers at once); off the main thread or from a sheet's save.
    /// `replace`: the user's own save over keys the helper cannot read (another build's keychain item, a locked
    /// keychain): that item is replaced. Off the main thread.
    static func set(_ pairs: [String: String], unset: [String] = [], replace: Bool = false) throws {
        guard let r = DeskMindIPC.request(["op": "keys.set", "set": pairs, "unset": unset, "replace": replace], timeout: 10) else {
            throw SaveError.refused("no answer from the helper")
        }
        guard r["ok"] as? Bool == true else {
            let why = r["error"] as? String
            throw SaveError.refused(why == "old_file" ? "the old models.env could not be removed"
                                    : why == "unreadable" ? "the keys in the keychain can't be read" : (why ?? "not saved"))
        }
        KeyStatus.shared.apply(r)
        // each writer of the model settings says so (the keys here, the service and the configuration below): the
        // app's sessions take them whichever window saved (ShellModel.syncSettings; #107 review at 5999bd9)
        ModelSettingsSaved.post()
    }

    static var provider: CloudProvider {
        get { CloudProvider.named(UserDefaults.standard.string(forKey: "cloud.provider") ?? "deepseek") }
        set { UserDefaults.standard.set(newValue.id, forKey: "cloud.provider"); ModelSettingsSaved.post() }
    }
    /// The configuration saved (`engine.config`: the runs of the window as it was send it, History.swift; sessions
    /// open with it, MainSplitView.modelConfig). Read and written through here only (ShellTests checks no other file
    /// names its key).
    static var engineConfig: String? {
        get { UserDefaults.standard.string(forKey: "engine.config") }
        set { UserDefaults.standard.set(newValue, forKey: "engine.config"); ModelSettingsSaved.post() }
    }
    /// The harness configuration the main app sends with every run (History.swift reads `engine.config`).
    static func config(for p: CloudProvider, model: String) -> String { p.configuration(model: model) }

    /// A form's save (ModelForm.plan), the sheet's and the first run's alike: the keys through the helper -- off the
    /// main thread (keys.set's merge; `replace` only over keys the helper cannot read) --
    static func save(_ plan: ModelForm.Plan, replace: Bool) throws {
        if !plan.pairs.isEmpty { try set(plan.pairs, replace: replace) }
    }
    /// -- then, on the main queue once they are kept, the service, its configuration and the engine.
    @MainActor static func apply(_ plan: ModelForm.Plan) {
        if let p = plan.provider { provider = p }
        if let c = plan.engineConfig { engineConfig = c }
        if let e = plan.engine { engineIsCloud = e }
    }

    /// Whether the chosen provider has what it needs: a key (and, custom, a URL and a model) -- as the helper says.
    static var configured: Bool { configured(KeyStatus.shared.now, provider) }
    static func configured(_ s: KeyStatus.Snapshot, _ p: CloudProvider) -> Bool {
        guard !(s.keys[p.keyEnv] ?? "").isEmpty else { return false }
        return !p.custom || (!(s.settings["CUSTOM_URL"] ?? "").isEmpty && !(s.settings["CUSTOM_MODEL"] ?? "").isEmpty)
    }
    static var engineIsCloud: Bool {
        get { UserDefaults.standard.string(forKey: "engine") == "harness" }
        set {
            UserDefaults.standard.set(newValue ? "harness" : "hands", forKey: "engine")
            // the helper holds "cloud models off" for every session it runs (models.off): told wherever the setting
            // is written — either window's sheet, any path — so no session keeps the cloud behind it
            ModelsOffSync.shared.push()      // (the switch as it is when it goes, in order, again until the helper has it)
        }
    }
}

/// The setup card's row: which model thinks. Local (DeskMind Brain) needs the download; cloud needs a key.
struct CloudModelRow: View {
    @EnvironmentObject var model: HelperModel
    @Environment(\.lang) private var lang
    @State private var editing = false

    var body: some View {
        let cloud = model.cloudEngine, p = CloudModelSettings.provider, ok = model.cloudConfigured
        PermissionRow(symbol: "cloud", title: L("Cloud model", lang: lang),
                      subtitle: cloud ? (ok ? L("%@ thinks for your tasks; what it looks at is sent to it.", p.title, lang: lang)
                                            : L("Add the API key for %@.", p.title, lang: lang))
                                      : L("Off. The local model thinks; turn it on to use DeepSeek, OpenRouter or another service.", lang: lang),
                      done: cloud && ok, optional: !cloud, actionTitle: L("Set up…", lang: lang),
                      doneActionTitle: L("Change", lang: lang), doneAction: { editing = true }) { editing = true }
            .sheet(isPresented: $editing) { CloudModelSheet().environmentObject(model).environment(\.lang, lang) }
    }
}

/// Provider, key, (custom) URL and model; Test asks the helper to reach the model once; Save writes models.env and
/// switches the engine.
struct CloudModelSheet: View {
    /// Opened from the 0.5 window: its conversations need a cloud model (0.5.0 has no local-only mode), so the switch
    /// can only be turned on there; it shows what is stored, and Save writes it only if the user moved it
    /// (ModelChoice). The window as it was keeps its choice.
    var inShell = false
    @EnvironmentObject var model: HelperModel
    @Environment(\.lang) private var lang
    @Environment(\.dismiss) private var dismiss
    /// The engine as stored when the sheet opened: Save writes it only if the switch was moved from it.
    @State private var savedCloud = CloudModelSettings.engineIsCloud
    /// What is typed (ModelForm: the first run's key step holds the same).
    @State private var form = ModelForm(provider: CloudModelSettings.provider, settings: KeyStatus.shared.now.settings,
                                        useCloud: CloudModelSettings.engineIsCloud)
    @State private var testing = false
    @State private var result: String? = nil
    @State private var resultOK = false
    @ObservedObject private var keys = KeyStatus.shared
    @State private var saving = false
    private var status: KeyStatus.Snapshot { keys.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Which model thinks", lang: lang)).font(.system(size: 16, weight: .semibold, design: .rounded))
            Toggle(L("Use a cloud model (the harness engine)", lang: lang), isOn: $form.useCloud)
                .disabled(ModelChoice.switchLocked(inShell: inShell, saved: savedCloud))
            if !ModelChoice.offersLocalOnly(inShell: inShell) {
                Text(L("Conversations in DeskMind 0.5 need a cloud model.", lang: lang))
                    .font(.system(size: 11)).foregroundStyle(ShellColor.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if form.useCloud {
                Picker(L("Service", lang: lang), selection: Binding(get: { form.provider }, set: { p in form.select(p, settings: status.settings); result = nil })) {
                    ForEach(CloudProvider.all) { p in Text(p.title).tag(p) }
                }
                // (the key as the helper knows it: set or not, its last 4 -- never shown, never read back)
                if status.known && !status.readable {
                    // (the truth, and the way out: the user's own save replaces them -- #127 review)
                    Text(L("The keys in the keychain can't be read (another build of DeskMind saved them, or the keychain is locked). Enter the key again and save: it replaces them.", lang: lang))
                        .font(.system(size: 11)).foregroundStyle(ShellColor.error).fixedSize(horizontal: false, vertical: true)
                } else if let last4 = status.keys[form.provider.keyEnv], !last4.isEmpty {
                    Text(L("Set · ends in %@", last4, lang: lang)).font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
                }
                SecureField(status.keys[form.provider.keyEnv] == nil ? L("API key", lang: lang) : L("New API key (empty: keep it)", lang: lang), text: $form.key)
                if form.provider.custom {
                    TextField(L("Base URL (…/v1)", lang: lang), text: $form.url)
                    TextField(L("Model id", lang: lang), text: $form.model)
                }
                HStack(spacing: 10) {
                    Button(L("Test", lang: lang)) { test() }.disabled(testing || (form.key.isEmpty && status.keys[form.provider.keyEnv] == nil))
                    if testing { ProgressView().controlSize(.small) }
                    if let result {
                        Text(result).font(.system(size: 12)).foregroundStyle(resultOK ? ShellColor.secondary : ShellColor.error)
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                // (the 0.5 window offers no local model: its note says what is sent, not to use one)
                Text(inShell
                     ? L("With a cloud model, each task's words, the windows it looks at, folder listings and the file contents it reads are sent to this service to think. The key is kept in your keychain, by DeskMind's helper only.", lang: lang)
                     : L("With a cloud model, each task's words, the windows it looks at, folder listings and the file contents it reads are sent to this service to think — keep tasks with sensitive content on the local model. The key is kept in your keychain, by DeskMind's helper only.", lang: lang))
                    .font(.system(size: 11)).foregroundStyle(ShellColor.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("Cancel", lang: lang)) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save", lang: lang)) { save() }.keyboardShortcut(.defaultAction).disabled(saving)
                    .disabled(!form.canSave(keySet: status.keys[form.provider.keyEnv] != nil))
            }
        }
        .padding(22).frame(width: 440)
        // (the custom service's URL and model as the helper keeps them, once its answer comes)
        .onChange(of: keys.snapshot) { _, s in form.settingsCame(s.settings) }
        .onAppear {
            savedCloud = CloudModelSettings.engineIsCloud
            form.useCloud = ModelChoice.startsCloud(inShell: inShell, saved: savedCloud)
            form.load(status.settings); result = nil
            KeyStatus.shared.refresh()
        }
    }

    /// Ask the helper to reach the model once with what is typed — sent for this check only, nothing written:
    /// Cancel after a test leaves the saved settings as they were.
    private func test() {
        testing = true; result = nil
        let config = form.provider.configuration(model: form.model)
        // (a key typed now is checked; none typed: the helper checks with the one it keeps)
        var env: [String: String] = form.key.isEmpty ? [:] : [form.provider.keyEnv: form.key]
        if form.provider.custom { env["CUSTOM_URL"] = form.url; env["CUSTOM_MODEL"] = form.model }
        Task.detached {
            let reply = DeskMindIPC.request(["op": "model_check", "config": config, "env": env, "lang": ResolvedLang.current.rawValue], timeout: 60)
            await MainActor.run {
                testing = false
                if reply?["ok"] as? Bool == true {
                    resultOK = true
                    result = L("Reached %@ in %d ms", reply?["model"] as? String ?? config, reply?["ms"] as? Int ?? 0, lang: lang)
                } else {
                    resultOK = false
                    result = (reply?["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? L("No answer from the helper", lang: lang)
                }
            }
        }
    }

    /// The form's save (ModelForm.plan, CloudModelSettings.save / apply): the engine only if the user moved the
    /// switch (a privacy setting, shared with the window as it was).
    private func save() {
        let plan = form.plan(engine: ModelChoice.engineToWrite(saved: savedCloud, shown: form.useCloud))
        // (keys the helper cannot read: the user's save replaces them -- the sheet said so)
        let replace = status.known && !status.readable
        saving = true
        Task.detached {
            var failure: String?
            do { try CloudModelSettings.save(plan, replace: replace) } catch { failure = error.localizedDescription }
            await MainActor.run {
                saving = false
                if let failure { result = failure; resultOK = false; return }
                CloudModelSettings.apply(plan)
                self.model.refreshCloud()
                dismiss()
            }
        }
    }
}
