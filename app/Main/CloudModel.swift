// The cloud model's settings: which service thinks for the harness engine and the key for it. The provider list is
// the harness's provider table (src/gateway/index.ts PROVIDERS); a custom entry takes any OpenAI-compatible
// service (URL, key, model id). Keys live in the helper's keychain item (A11: Shared/ModelStore.swift): this app
// writes them through the helper (keys.set) and is told only whether each is set and its last 4 characters
// (keys.status) -- it never reads a key back; never in defaults, never logged.

import Foundation
import SwiftUI

/// One cloud service the harness can use. `config` is the harness's model configuration for it.
struct CloudProvider: Identifiable, Hashable {
    let id: String          // the harness's provider name (its PROVIDERS key)
    let title: String       // shown as is: a brand name, not translated
    let keyEnv: String      // the environment variable the key goes in
    let config: String      // the harness configuration (a CONFIGS name, or built for custom)
    let custom: Bool        // needs a URL and a model id too

    static let all: [CloudProvider] = [
        CloudProvider(id: "deepseek", title: "DeepSeek", keyEnv: "DEEPSEEK_API_KEY", config: "ds-flash", custom: false),
        CloudProvider(id: "openrouter", title: "OpenRouter", keyEnv: "OPENROUTER_API_KEY", config: "or-luna", custom: false),
        CloudProvider(id: "volcengine", title: "火山引擎 (doubao)", keyEnv: "VOLCENGINE_API_KEY", config: "ark-evolving", custom: false),
        CloudProvider(id: "custom", title: "OpenAI-compatible", keyEnv: "CUSTOM_API_KEY", config: "openai:custom|", custom: true),
    ]
    static func named(_ id: String) -> CloudProvider { all.first { $0.id == id } ?? all[0] }
}

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
    static func set(_ pairs: [String: String], unset: [String] = []) throws {
        guard let r = DeskMindIPC.request(["op": "keys.set", "set": pairs, "unset": unset], timeout: 10) else {
            throw SaveError.refused("no answer from the helper")
        }
        guard r["ok"] as? Bool == true else {
            let why = r["error"] as? String
            throw SaveError.refused(why == "old_file" ? "the old models.env could not be removed" : (why ?? "not saved"))
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
    static func config(for p: CloudProvider, model: String) -> String { p.custom ? p.config + model : p.config }

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
    @State private var useCloud = CloudModelSettings.engineIsCloud
    /// The engine as stored when the sheet opened: Save writes it only if the switch was moved from it.
    @State private var savedCloud = CloudModelSettings.engineIsCloud
    @State private var provider = CloudModelSettings.provider
    @State private var key = ""
    @State private var url = ""
    @State private var modelID = ""
    @State private var testing = false
    @State private var result: String? = nil
    @State private var resultOK = false
    @ObservedObject private var keys = KeyStatus.shared
    private var status: KeyStatus.Snapshot { keys.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Which model thinks", lang: lang)).font(.system(size: 16, weight: .semibold, design: .rounded))
            Toggle(L("Use a cloud model (the harness engine)", lang: lang), isOn: $useCloud)
                .disabled(ModelChoice.switchLocked(inShell: inShell, saved: savedCloud))
            if !ModelChoice.offersLocalOnly(inShell: inShell) {
                Text(L("Conversations in DeskMind 0.5 need a cloud model.", lang: lang))
                    .font(.system(size: 11)).foregroundStyle(ShellColor.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if useCloud {
                Picker(L("Service", lang: lang), selection: $provider) {
                    ForEach(CloudProvider.all) { p in Text(p.title).tag(p) }
                }
                .onChange(of: provider) { _, p in load(p) }
                // (the key as the helper knows it: set or not, its last 4 -- never shown, never read back)
                if let last4 = status.keys[provider.keyEnv], !last4.isEmpty {
                    Text(L("Set · ends in %@", last4, lang: lang)).font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
                }
                SecureField(status.keys[provider.keyEnv] == nil ? L("API key", lang: lang) : L("New API key (empty: keep it)", lang: lang), text: $key)
                if provider.custom {
                    TextField(L("Base URL (…/v1)", lang: lang), text: $url)
                    TextField(L("Model id", lang: lang), text: $modelID)
                }
                HStack(spacing: 10) {
                    Button(L("Test", lang: lang)) { test() }.disabled(testing || (key.isEmpty && status.keys[provider.keyEnv] == nil))
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
                Button(L("Save", lang: lang)) { save() }.keyboardShortcut(.defaultAction)
                    .disabled(useCloud && ((key.isEmpty && status.keys[provider.keyEnv] == nil) || (provider.custom && (url.isEmpty || modelID.isEmpty))))
            }
        }
        .padding(22).frame(width: 440)
        .onAppear {
            savedCloud = CloudModelSettings.engineIsCloud
            useCloud = ModelChoice.startsCloud(inShell: inShell, saved: savedCloud)
            load(provider)
            KeyStatus.shared.refresh()
        }
    }

    /// The service's fields: its key field empty (a key is never read back), the custom URL and model as kept.
    private func load(_ p: CloudProvider) {
        key = ""
        url = status.settings["CUSTOM_URL"] ?? ""
        modelID = status.settings["CUSTOM_MODEL"] ?? ""
        result = nil
    }

    /// Ask the helper to reach the model once with what is typed — sent for this check only, nothing written:
    /// Cancel after a test leaves the saved settings as they were.
    private func test() {
        testing = true; result = nil
        let config = CloudModelSettings.config(for: provider, model: modelID)
        // (a key typed now is checked; none typed: the helper checks with the one it keeps)
        var env: [String: String] = key.isEmpty ? [:] : [provider.keyEnv: key]
        if provider.custom { env["CUSTOM_URL"] = url; env["CUSTOM_MODEL"] = modelID }
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

    private func persist() throws {
        let model = ModelChoice.modelName(modelID)         // (a pasted name's spaces never saved)
        var pairs: [String: String] = [:]
        if !key.isEmpty { pairs[provider.keyEnv] = key }   // (empty: the key kept as it is)
        if provider.custom { pairs["CUSTOM_URL"] = url; pairs["CUSTOM_MODEL"] = model }
        if !pairs.isEmpty { try CloudModelSettings.set(pairs) }
        CloudModelSettings.provider = provider
        CloudModelSettings.engineConfig = CloudModelSettings.config(for: provider, model: model)
    }

    private func save() {
        do { if useCloud { try persist() } } catch { result = error.localizedDescription; resultOK = false; return }
        // the engine only if the user moved the switch (a privacy setting, shared with the window as it was)
        if let engine = ModelChoice.engineToWrite(saved: savedCloud, shown: useCloud) { CloudModelSettings.engineIsCloud = engine }
        model.refreshCloud()
        dismiss()
    }
}
