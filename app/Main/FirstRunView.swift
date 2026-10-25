// The first launch's four steps (A12, Shared/FirstRun.swift): the language, the two permissions, the model key with its
// check, a first task's examples. A sheet over the main window, each step skippable. It asks the helper only for what
// a step is about (request_permission through the grant panel, keys.set through the model sheet, model_check) and
// opens no conversation; "已授权" is shown only when the helper's status says so.

import SwiftUI

struct FirstRunView: View {
    @ObservedObject var shell: ShellModel
    @EnvironmentObject var model: HelperModel
    @ObservedObject private var keys = KeyStatus.shared
    @AppStorage(AppLanguage.key) private var language = AppLanguage.system.rawValue
    @Environment(\.lang) private var lang
    @State var flow: FirstRun
    let done: () -> Void
    @State private var settingsOpen = false
    @State private var checking = false
    @State private var checkNote: String?

    /// The facts as the helper says them now.
    private var facts: FirstRun.Facts {
        var f = flow.facts
        f.accessibility = model.granted(.accessibility)
        f.screen = model.granted(.screen)
        f.keySet = CloudModelSettings.configured(keys.snapshot, CloudModelSettings.provider)
        return f
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                XiaoFang(mood: .idle, size: 40).accessibilityHidden(true)
                Text(L("Set up DeskMind", lang: lang)).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(Brand.ink)
                Spacer()
                Text(L("Step %d of %d", flow.step.rawValue + 1, 4, lang: lang)).font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
            }
            step
            Spacer(minLength: 0)
            HStack {
                Button(L("Skip all", lang: lang)) { finish() }.buttonStyle(.link)
                Spacer()
                if flow.step != .language { Button(L("Back", lang: lang)) { flow.apply(.back) } }
                if flow.canLater && !ready { Button(L("Later", lang: lang)) { move(.later) } }
                Button(flow.step == .examples ? L("Finish", lang: lang) : L("Next step", lang: lang)) { move(.next) }
                    .buttonStyle(InkButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 520, height: 400)
        .background(Brand.paper)
        .sheet(isPresented: $settingsOpen) { CloudModelSheet(inShell: true).environmentObject(model).environment(\.lang, lang) }
        .onAppear { KeyStatus.shared.refresh() }
    }

    /// What the step asks for is there (its main button then says 下一步 without a 稍后 beside it).
    private var ready: Bool {
        switch flow.step {
        case .permissions: facts.accessibility && facts.screen
        case .key: facts.keySet
        default: true
        }
    }

    private func move(_ e: FirstRun.Event) {
        flow.apply(e)
        if flow.step == .done { finish() }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: FirstRun.doneKey)
        done()
    }

    @ViewBuilder private var step: some View {
        switch flow.step {
        case .language:
            Text(L("Which language should DeskMind use?", lang: lang)).font(.system(size: 13)).foregroundStyle(Brand.ink)
            Picker(L("Language", lang: lang), selection: $language) {
                Text(L("Follow system", lang: lang)).tag(AppLanguage.system.rawValue)
                Text(verbatim: "中文").tag(AppLanguage.zhHans.rawValue)
                Text(verbatim: "English").tag(AppLanguage.en.rawValue)
            }
            .pickerStyle(.radioGroup)
        case .permissions:
            Text(L("DeskMind's helper needs two permissions to see and use your apps. You can grant them later too.", lang: lang))
                .font(.system(size: 13)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
            ForEach([Grant.accessibility, .screen]) { g in
                PermissionRow(symbol: g.symbol, title: g.title(lang), subtitle: g.subtitle(lang), done: model.granted(g)) { model.grant(g) }
            }
        case .key:
            Text(L("Conversations think with a cloud model: add its API key. It is kept in your keychain, by DeskMind's helper only.", lang: lang))
                .font(.system(size: 13)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                let p = CloudModelSettings.provider
                if keys.snapshot.known && !keys.snapshot.readable {
                    Label(L("The keys in the keychain can't be read", lang: lang), systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(ShellColor.error)
                } else if let last4 = keys.snapshot.keys[p.keyEnv], !last4.isEmpty {
                    Label(L("%@ · Set · ends in %@", p.title, last4, lang: lang), systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(Brand.ink)
                } else {
                    Label(L("No key yet", lang: lang), systemImage: "key").font(.system(size: 12)).foregroundStyle(ShellColor.secondary)
                }
                Spacer()
                Button(L("Set up…", lang: lang)) { settingsOpen = true }
                Button(L("Check", lang: lang)) { check() }.disabled(checking || !facts.keySet)
            }
            if checking { ProgressView().controlSize(.small) }
            if let checkNote {
                Text(checkNote).font(.system(size: 11)).foregroundStyle(flow.facts.checkOK == true ? ShellColor.secondary : ShellColor.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .examples:
            Text(L("Try a first task. It goes into the message box; nothing is sent until you press Return.", lang: lang))
                .font(.system(size: 13)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
            ForEach(FirstRun.examples, id: \.self) { e in
                Button { shell.draft = L(e, lang: lang); finish() } label: {
                    Text(L(e, lang: lang)).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(InkButtonStyle(prominent: false))
            }
        case .done:
            EmptyView()
        }
    }

    /// One tiny question to the model with the key the helper keeps (model_check): its answer, said as it is.
    private func check() {
        checking = true; checkNote = nil
        let config = CloudModelSettings.config(for: CloudModelSettings.provider, model: keys.snapshot.settings["CUSTOM_MODEL"] ?? "")
        Task.detached {
            let reply = DeskMindIPC.request(["op": "model_check", "config": config, "lang": ResolvedLang.current.rawValue], timeout: 60)
            await MainActor.run {
                checking = false
                let ok = reply?["ok"] as? Bool == true
                flow.apply(.checked(ok: ok))
                checkNote = ok ? L("Reached %@ in %d ms", reply?["model"] as? String ?? config, reply?["ms"] as? Int ?? 0, lang: lang)
                    : ((reply?["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? L("No answer from the helper", lang: lang))
            }
        }
    }
}

/// A row in the empty chat for what the first run left unmet (FirstRun.unmet): its step again.
struct SetupRow: View {
    let unmet: [FirstRun.Unmet]
    let open: (FirstRun.Step) -> Void
    @Environment(\.lang) private var lang
    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(unmet.enumerated()), id: \.offset) { _, u in
                HStack(spacing: 8) {
                    Text(u == .permissions ? L("The helper's permissions aren't granted yet.", lang: lang) : L("No model key yet.", lang: lang))
                        .font(.system(size: 12)).foregroundStyle(Brand.ink)
                    Button(L("Finish setup", lang: lang)) { open(u == .permissions ? .permissions : .key) }
                        .buttonStyle(InkButtonStyle(prominent: false))
                }
            }
        }
    }
}
