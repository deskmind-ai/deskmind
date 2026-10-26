// The model settings as typed (the model sheet's and the first run's one form, #130 review): which service, a new key
// (never read back), a custom service's URL and model, whether the cloud is on -- and what saving it writes. Both the
// sheet and the first run's key step hold this and save through CloudModelSettings.save, so neither drops a part of
// it (the first run once did: no engine switch, an empty custom URL, a key kept across a service change).
//
// | event                 | the form                                                                         |
// |-----------------------|----------------------------------------------------------------------------------|
// | load / a new service  | key empty, its check's result gone; a custom URL and model as the helper keeps them|
// | can save              | cloud off; else a key typed or one set, and for custom a URL and a model          |
// | save (its plan)       | the key if typed; custom: URL and model always; the service; its configuration;  |
// |                       |   the engine as the caller says (the sheet: only if the switch moved; the first   |
// |                       |   run: on -- its conversations need it)                                          |

import Foundation

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
    /// The harness configuration with `model` (a custom service's model id goes on its configuration).
    func configuration(model: String) -> String { custom ? config + model : config }
}

struct ModelForm: Equatable {
    var provider: CloudProvider
    var key = ""
    var url = ""
    var model = ""
    var useCloud = true
    /// The last check of what is saved (model_check): nil none yet; the model it reached, or why it failed.
    var checkOK: Bool?
    var reached: String?
    var why: String?
    /// Counts the user's edits (edit): a save or check is tagged with the version it was made from, and its result is
    /// taken only while the form is still that version (#130 Codex review: a provider switched mid-check took the old
    /// one's 「能用」 and moved on).
    var version = 0

    init(provider: CloudProvider, settings: [String: String], useCloud: Bool = true) {
        self.provider = provider
        self.useCloud = useCloud
        load(settings)
    }

    /// The service's fields: its key empty (a key is never read back), its check gone, the custom URL and model as kept.
    mutating func load(_ settings: [String: String]) {
        key = ""; checkOK = nil; reached = nil; why = nil
        url = settings["CUSTOM_URL"] ?? ""
        model = settings["CUSTOM_MODEL"] ?? ""
    }

    /// Another service: as loaded anew -- a key typed for one never goes in another's place.
    mutating func select(_ p: CloudProvider, settings: [String: String]) {
        guard p != provider else { return }
        provider = p
        load(settings)
    }

    /// What the user changed on the page: another service is loaded anew (select), anything else taken as typed; the
    /// version moves when what would be saved changes.
    mutating func edit(_ new: ModelForm, settings: [String: String]) {
        let before = (provider.id, key, url, model, useCloud)
        if new.provider != provider { select(new.provider, settings: settings) } else { let v = version; self = new; version = v }
        if (provider.id, key, url, model, useCloud) != before { version += 1 }
    }

    /// A save made from `version` finished: nil (it is stale -- dropped), or whether it went through (`why` set if not).
    mutating func saved(version v: Int, failure: String?) -> Bool? {
        guard v == version else { return nil }
        if let failure { why = failure }
        return failure == nil
    }

    /// A check made from `version` answered: nil (stale -- dropped, nothing said), or its result, kept on the form.
    mutating func checked(version v: Int, ok: Bool, reached r: String?, why w: String?) -> Bool? {
        guard v == version else { return nil }
        checkOK = ok
        if ok { reached = r } else { why = w }
        return ok
    }

    /// The helper's answer about the custom settings came: filled in, unless the user typed some already.
    mutating func settingsCame(_ settings: [String: String]) {
        if url.isEmpty && model.isEmpty { url = settings["CUSTOM_URL"] ?? ""; model = settings["CUSTOM_MODEL"] ?? "" }
    }

    /// `keySet`: the helper has a key for this service.
    func canSave(keySet: Bool) -> Bool {
        guard useCloud else { return true }
        return (!key.isEmpty || keySet) && (!provider.custom || (!url.isEmpty && !ModelChoice.modelName(model).isEmpty))
    }

    struct Plan: Equatable {
        /// What keys.set merges (empty: nothing to send).
        var pairs: [String: String]
        var provider: CloudProvider?
        var engineConfig: String?
        /// The engine switch to write (nil: left as it is).
        var engine: Bool?
    }

    /// What saving writes; `engine`, the switch the caller writes (nil: none).
    func plan(engine: Bool?) -> Plan {
        guard useCloud else { return Plan(pairs: [:], provider: nil, engineConfig: nil, engine: engine) }
        let name = ModelChoice.modelName(model)
        var pairs: [String: String] = [:]
        if !key.isEmpty { pairs[provider.keyEnv] = key }      // (empty: the key kept as it is)
        if provider.custom { pairs["CUSTOM_URL"] = url; pairs["CUSTOM_MODEL"] = name }
        return Plan(pairs: pairs, provider: provider, engineConfig: provider.configuration(model: name), engine: engine)
    }
}
