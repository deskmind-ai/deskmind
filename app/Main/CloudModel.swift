// The cloud model's settings: which service thinks for the harness engine and the key for it. The provider list is
// the harness's provider table (src/gateway/index.ts PROVIDERS); a custom entry takes any OpenAI-compatible
// service (URL, key, model id). Keys live in Application Support/DeskMind/models.env (owner-only), the file the
// helper hands the harness as environment; never in defaults, never logged.

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

/// What is saved: the provider, its key and (custom) URL + model, as the models.env file and two defaults.
enum CloudModelSettings {
    static var fileURL: URL { DeskMindIPC.supportDir.appendingPathComponent("models.env") }

    /// KEY=VALUE lines → dictionary (the helper reads the same format: HarnessRun.modelEnv).
    static func read() -> [String: String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            out[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] = v
        }
        return out
    }

    /// Write the whole file back, owner-only. Other services' keys are kept: switching providers loses nothing.
    static func write(_ env: [String: String]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = env.keys.sorted().compactMap { k in env[k].map { "\(k)=\($0)" } }.joined(separator: "\n") + "\n"
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static var provider: CloudProvider {
        get { CloudProvider.named(UserDefaults.standard.string(forKey: "cloud.provider") ?? "deepseek") }
        set { UserDefaults.standard.set(newValue.id, forKey: "cloud.provider") }
    }
    /// The harness configuration the main app sends with every run (History.swift reads `engine.config`).
    static func config(for p: CloudProvider, model: String) -> String { p.custom ? p.config + model : p.config }

    /// Whether the chosen provider has what it needs: a key (and, custom, a URL and a model).
    static var configured: Bool {
        let env = read(), p = provider
        guard !(env[p.keyEnv] ?? "").isEmpty else { return false }
        return !p.custom || (!(env["CUSTOM_URL"] ?? "").isEmpty && !(env["CUSTOM_MODEL"] ?? "").isEmpty)
    }
    static var engineIsCloud: Bool {
        get { UserDefaults.standard.string(forKey: "engine") == "harness" }
        set { UserDefaults.standard.set(newValue ? "harness" : "hands", forKey: "engine") }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Which model thinks", lang: lang)).font(.system(size: 16, weight: .semibold, design: .rounded))
            Toggle(L("Use a cloud model (the harness engine)", lang: lang), isOn: $useCloud)
                .disabled(ModelChoice.switchLocked(inShell: inShell, saved: savedCloud))
            if !ModelChoice.offersLocalOnly(inShell: inShell) {
                Text(L("Conversations in DeskMind 0.5 need a cloud model.", lang: lang))
                    .font(.system(size: 11)).foregroundStyle(Brand.sage).fixedSize(horizontal: false, vertical: true)
            }
            if useCloud {
                Picker(L("Service", lang: lang), selection: $provider) {
                    ForEach(CloudProvider.all) { p in Text(p.title).tag(p) }
                }
                .onChange(of: provider) { _, p in load(p) }
                SecureField(L("API key", lang: lang), text: $key)
                if provider.custom {
                    TextField(L("Base URL (…/v1)", lang: lang), text: $url)
                    TextField(L("Model id", lang: lang), text: $modelID)
                }
                HStack(spacing: 10) {
                    Button(L("Test", lang: lang)) { test() }.disabled(testing || key.isEmpty)
                    if testing { ProgressView().controlSize(.small) }
                    if let result {
                        Text(result).font(.system(size: 12)).foregroundStyle(resultOK ? Brand.dot : Color.red)
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                // (the 0.5 window offers no local model: its note says what is sent, not to use one)
                Text(inShell
                     ? L("With a cloud model, each task's words, the windows it looks at, folder listings and the file contents it reads are sent to this service to think. The key is stored in models.env in Application Support, readable by you only.", lang: lang)
                     : L("With a cloud model, each task's words, the windows it looks at, folder listings and the file contents it reads are sent to this service to think — keep tasks with sensitive content on the local model. The key is stored in models.env in Application Support, readable by you only.", lang: lang))
                    .font(.system(size: 11)).foregroundStyle(Brand.sage).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("Cancel", lang: lang)) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save", lang: lang)) { save() }.keyboardShortcut(.defaultAction)
                    .disabled(useCloud && (key.isEmpty || (provider.custom && (url.isEmpty || modelID.isEmpty))))
            }
        }
        .padding(22).frame(width: 440)
        .onAppear {
            savedCloud = CloudModelSettings.engineIsCloud
            useCloud = ModelChoice.startsCloud(inShell: inShell, saved: savedCloud)
            load(provider)
        }
    }

    private func load(_ p: CloudProvider) {
        let env = CloudModelSettings.read()
        key = env[p.keyEnv] ?? ""
        url = env["CUSTOM_URL"] ?? ""
        modelID = env["CUSTOM_MODEL"] ?? ""
        result = nil
    }

    /// Ask the helper to reach the model once with what is typed — sent for this check only, nothing written:
    /// Cancel after a test leaves the saved settings as they were.
    private func test() {
        testing = true; result = nil
        let config = CloudModelSettings.config(for: provider, model: modelID)
        var env = [provider.keyEnv: key]
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
        var env = CloudModelSettings.read()
        env[provider.keyEnv] = key
        if provider.custom { env["CUSTOM_URL"] = url; env["CUSTOM_MODEL"] = model }
        try CloudModelSettings.write(env)
        CloudModelSettings.provider = provider
        UserDefaults.standard.set(CloudModelSettings.config(for: provider, model: model), forKey: "engine.config")
    }

    private func save() {
        do { if useCloud { try persist() } } catch { result = error.localizedDescription; resultOK = false; return }
        // the engine only if the user moved the switch (a privacy setting, shared with the window as it was)
        if let engine = ModelChoice.engineToWrite(saved: savedCloud, shown: useCloud) { CloudModelSettings.engineIsCloud = engine }
        model.refreshCloud()
        dismiss()
    }
}
