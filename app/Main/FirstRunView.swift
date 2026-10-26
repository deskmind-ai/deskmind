// The first launch's four steps (A12, Shared/FirstRun.swift; the P1Setup board, U2): the language, the two
// permissions, privacy and the cloud model (its key typed in place, then tried), a first task's examples. The window's
// whole content while it runs: an ink column on the left (what goes to the cloud, three promises), the step on the
// right with one main button. It asks the helper only for what a step is about (request_permission through the grant
// panel, keys.set as the model sheet saves, model_check) and opens no conversation; "已授权" is shown only when the
// helper's status says so.
//
// FirstRunView wires the helper and the keychain to FirstRunPage, which only draws (the offscreen render draws it too).

import SwiftUI

struct FirstRunView: View {
    @ObservedObject var shell: ShellModel
    @EnvironmentObject var model: HelperModel
    @ObservedObject private var keys = KeyStatus.shared
    @AppStorage(AppLanguage.key) private var language = AppLanguage.system.rawValue
    @Environment(\.lang) private var lang
    @State var flow: FirstRun
    let done: () -> Void
    @State private var form = FirstRunPage.KeyForm(provider: CloudModelSettings.provider)
    @State private var busy = false
    @State private var checkOK: Bool?
    @State private var why: String?
    @State private var reached: String?

    /// The facts as the helper says them now.
    private var facts: FirstRun.Facts {
        var f = flow.facts
        f.accessibility = model.granted(.accessibility)
        f.screen = model.granted(.screen)
        f.keySet = CloudModelSettings.configured(keys.snapshot, form.provider)
        return f
    }

    var body: some View {
        var shown = flow
        shown.facts = facts
        return FirstRunPage(flow: shown, language: $language, form: $form,
                            keyState: FirstRun.keyState(known: keys.snapshot.known, readable: keys.snapshot.readable,
                                                        last4: keys.snapshot.keys[form.provider.keyEnv], busy: busy, checkOK: checkOK,
                                                        why: why, model: reached),
                            granted: { model.granted($0) }, grant: { model.grant($0) },
                            act: act, example: { e in shell.draft = L(e, lang: lang); finish() })
            .onAppear { KeyStatus.shared.refresh() }
    }

    private func act(_ e: FirstRunPage.Action) {
        switch e {
        case .skipAll: finish()
        case .back: flow.apply(.back)
        case .later: move(.later)
        case .next:
            if flow.step == .key { continueKey() } else { move(.next) }
        }
    }

    private func move(_ e: FirstRun.Event) {
        flow.facts = facts
        flow.apply(e)
        if flow.step == .done { finish() }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: FirstRun.doneKey)
        done()
    }

    /// 「继续」 on the key step: a typed key saved as the model sheet saves it -- keys.set's merge, replacing only keys
    /// the helper can't read (A11: the key in effect is the last one set) -- then tried with the key the helper keeps;
    /// one that works moves on by itself, one that doesn't stays (稍后 still goes on).
    private func continueKey() {
        let p = form.provider
        let modelName = ModelChoice.modelName(form.model)
        var pairs: [String: String] = [:]
        if !form.key.isEmpty { pairs[p.keyEnv] = form.key }
        if p.custom && !form.key.isEmpty { pairs["CUSTOM_URL"] = form.url; pairs["CUSTOM_MODEL"] = modelName }
        let replace = keys.snapshot.known && !keys.snapshot.readable
        busy = true; why = nil; checkOK = nil
        Task.detached {
            var failure: String?
            if !pairs.isEmpty {
                do { try CloudModelSettings.set(pairs, replace: replace) } catch { failure = error.localizedDescription }
            }
            await MainActor.run {
                if !pairs.isEmpty { flow.apply(.saved(ok: failure == nil)) }
                if let failure { busy = false; why = failure; return }
                CloudModelSettings.provider = p
                CloudModelSettings.engineConfig = CloudModelSettings.config(for: p, model: modelName)
                form.key = ""
                model.refreshCloud()
                check()
            }
        }
    }

    /// One tiny question to the model with the key the helper keeps (model_check): its answer, said as it is.
    private func check() {
        busy = true
        let config = CloudModelSettings.config(for: form.provider, model: keys.snapshot.settings["CUSTOM_MODEL"] ?? ModelChoice.modelName(form.model))
        Task.detached {
            let reply = DeskMindIPC.request(["op": "model_check", "config": config, "lang": ResolvedLang.current.rawValue], timeout: 60)
            await MainActor.run {
                busy = false
                let ok = reply?["ok"] as? Bool == true
                checkOK = ok
                if ok {
                    reached = reply?["model"] as? String ?? config
                    // (「能用」 seen for a moment, then on)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { flow.apply(.checked(ok: true)) }
                } else {
                    why = (reply?["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? L("No answer from the helper", lang: lang)
                    flow.apply(.checked(ok: false))
                }
            }
        }
    }
}

/// The first run as drawn (P1Setup): what it is given, nothing it asks for itself.
struct FirstRunPage: View {
    enum Action { case next, later, back, skipAll }
    struct KeyForm: Equatable {
        var provider: CloudProvider
        var key = ""
        var url = ""
        var model = ""
    }
    let flow: FirstRun
    @Binding var language: String
    @Binding var form: KeyForm
    let keyState: FirstRun.KeyState
    let granted: (Grant) -> Bool
    let grant: (Grant) -> Void
    let act: (Action) -> Void
    let example: (String) -> Void
    @Environment(\.lang) private var lang

    var body: some View {
        HStack(spacing: 0) {
            promises.frame(width: 340).frame(maxHeight: .infinity, alignment: .top).background(Color(ShellPalette.inkSurface))
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(Brand.ink).accessibilityAddTraits(.isHeader)
                    Text(L("First run · Step %d of %d", min(flow.step.rawValue + 1, 4), 4, lang: lang)).font(.system(size: 14)).foregroundStyle(ShellColor.secondary)
                }
                ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) }
                bar
            }
            .padding(.top, 44).padding(.horizontal, 48).padding(.bottom, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Brand.paper)
        }
    }

    // MARK: the ink column

    private var promises: some View {
        VStack(alignment: .leading, spacing: 22) {
            Color.clear.frame(height: 28)      // (the window's own buttons)
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color(ShellPalette.onInk), lineWidth: 5).frame(width: 64, height: 64)
                Circle().fill(Brand.dot).frame(width: 18, height: 18).offset(x: 9, y: 9)
            }
            .frame(width: 73, height: 73, alignment: .topLeading)
            .accessibilityHidden(true)
            Text(L("First, what goes to the cloud", lang: lang)).font(.system(size: 32, weight: .bold)).foregroundStyle(Color(ShellPalette.onInk))
                .fixedSize(horizontal: false, vertical: true)
            Text(L("DeskMind talks and plans with a cloud model; seeing the screen and finding buttons happen on this Mac.", lang: lang))
                .font(.system(size: 16)).lineSpacing(3).foregroundStyle(Color(ShellPalette.onInkMuted)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                ForEach([FirstRunPage.shotPromise,
                         "It reads no file you didn't point it at",
                         "It asks before changing your things or sending anything out"], id: \.self) { p in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "·").font(.system(size: 14, weight: .bold)).foregroundStyle(Color(ShellPalette.onInkPromise))
                        Text(L(p, lang: lang)).font(.system(size: 14)).lineSpacing(2).foregroundStyle(Color(ShellPalette.onInkMuted))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, 32).padding(.bottom, 28)
    }

    /// What is true of the pixels and of the words (checked 10-26 against harness and hands: no screenshot goes to a
    /// cloud model; what is read off the screen goes as text).
    static let shotPromise = "Screenshots are read on this Mac and the images are not uploaded; the words read from them go to the cloud model to decide the next step"

    // MARK: the step

    private var title: String {
        switch flow.step {
        case .language: L("Language", lang: lang)
        case .permissions: L("Permissions", lang: lang)
        case .key: L("Privacy and the cloud model", lang: lang)
        case .examples, .done: L("A first task", lang: lang)
        }
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .language:
            VStack(spacing: 10) {
                choice(AppLanguage.system.rawValue, L("Follow system", lang: lang), L("As macOS is set", lang: lang))
                choice(AppLanguage.zhHans.rawValue, "中文", L("Simplified Chinese", lang: lang))
                choice(AppLanguage.en.rawValue, "English", L("English", lang: lang))
            }
        case .permissions:
            VStack(alignment: .leading, spacing: 14) {
                Text(L("DeskMind's helper needs two permissions to see and use your apps. You can grant them later too.", lang: lang))
                    .font(.system(size: 14)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
                ForEach([Grant.accessibility, .screen]) { g in permission(g) }
            }
        case .key:
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    privacyCard(L("What goes to the cloud", lang: lang),
                                ["Your conversations with it", "Window text a task reads", "File contents a task reads, only files you pointed it at"],
                                foot: L("Sent to the service you choose below.", lang: lang))
                    privacyCard(L("What stays on this Mac", lang: lang),
                                ["Screenshots: read on this Mac, the images not uploaded", "Files you didn't point it at"],
                                foot: L("The screen is read by a local model.", lang: lang))
                }
                keyFields
            }
        case .examples:
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Try a first task. It goes into the message box; nothing is sent until you press Return.", lang: lang))
                    .font(.system(size: 14)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
                ForEach(FirstRun.examples, id: \.self) { e in
                    Button { example(e) } label: {
                        Text(L(e, lang: lang)).font(.system(size: 14)).foregroundStyle(Brand.ink)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.card))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.line))
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        case .done:
            EmptyView()
        }
    }

    /// The bottom line: 「全部跳过」「上一步」 on the left; 「稍后」 and the one main button on the right.
    private var bar: some View {
        let typed = !form.key.isEmpty
        let on = flow.canContinue(typed: typed) && keyState != .checking
        return HStack(spacing: 18) {
            Button(L("Skip all", lang: lang)) { act(.skipAll) }.buttonStyle(.plain)
            if flow.step != .language { Button(L("Back", lang: lang)) { act(.back) }.buttonStyle(.plain) }
            Spacer()
            if flow.canLater && !flow.canContinue(typed: false) { Button(L("Later", lang: lang)) { act(.later) }.buttonStyle(.plain) }
            Button(flow.step == .examples ? L("Finish", lang: lang) : L("Continue", lang: lang)) { act(.next) }
                .buttonStyle(InkButtonStyle(prominent: true))
                .frame(minWidth: 120)
                .disabled(!on).opacity(on ? 1 : 0.4)
                .keyboardShortcut(.defaultAction)
        }
        .font(.system(size: 13)).foregroundStyle(ShellColor.secondary)
    }

    // MARK: the pieces

    private func choice(_ tag: String, _ title: String, _ sub: String) -> some View {
        let on = language == tag
        return Button { language = tag } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Brand.ink)
                Text(sub).font(.system(size: 13)).foregroundStyle(ShellColor.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Brand.ink : Brand.line, lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func permission(_ g: Grant) -> some View {
        HStack(spacing: 14) {
            Image(systemName: g.symbol).font(.system(size: 20)).foregroundStyle(Brand.ink).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(g.title(lang)).font(.system(size: 16, weight: .bold)).foregroundStyle(Brand.ink)
                Text(g.subtitle(lang)).font(.system(size: 14)).foregroundStyle(ShellColor.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted(g) {
                HStack(spacing: 6) {
                    Circle().fill(ShellColor.ok).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(L("Granted", lang: lang)).font(.system(size: 13)).foregroundStyle(Brand.ink)
                }
            } else {
                Button(L("Allow", lang: lang)) { grant(g) }.buttonStyle(InkButtonStyle(prominent: false, small: true))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 16).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.line))
    }

    private func privacyCard(_ title: String, _ items: [String], foot: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(Brand.ink)
            ForEach(items, id: \.self) { i in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: "·").foregroundStyle(ShellColor.secondary)
                    Text(L(i, lang: lang)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 14))
            }
            Text(foot).font(.system(size: 12)).foregroundStyle(ShellColor.secondary).padding(.top, 2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.line))
    }

    /// 「用哪个云端模型」: the service, the key (typed here), a custom service's URL and model, and how the key is.
    private var keyFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Which cloud model", lang: lang)).font(.system(size: 16, weight: .bold)).foregroundStyle(Brand.ink)
            HStack(alignment: .top, spacing: 14) {
                field(L("Provider", lang: lang)) {
                    Picker("", selection: $form.provider) {
                        ForEach(CloudProvider.all) { p in Text(verbatim: p.title).tag(p) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                }
                field(L("API key", lang: lang)) {
                    SecureField(isSet ? L("New API key (empty: keep it)", lang: lang) : L("API key", lang: lang), text: $form.key)
                        .textFieldStyle(.plain).font(.system(size: 14))
                        .padding(.horizontal, 12).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Brand.card))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isBad ? ShellColor.error : Brand.ink, lineWidth: 1.5))
                }
            }
            if form.provider.custom {
                HStack(spacing: 14) {
                    field(L("Base URL (…/v1)", lang: lang)) { TextField("", text: $form.url).textFieldStyle(.roundedBorder) }
                    field(L("Model id", lang: lang)) { TextField("", text: $form.model).textFieldStyle(.roundedBorder) }
                }
            }
            status
            Text(L("The key stays in this Mac's keychain; only DeskMind's helper can read it", lang: lang))
                .font(.system(size: 12)).foregroundStyle(ShellColor.secondary)
            HStack { Spacer(); Text(L("You can change this later in the cloud model settings", lang: lang)).font(.system(size: 13)).foregroundStyle(ShellColor.secondary) }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 18)
        .background(RoundedRectangle(cornerRadius: 16).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.line))
    }

    private var isSet: Bool { if case .set = keyState { true } else { false } }
    private var isBad: Bool { if case .bad = keyState { true } else if case .unreadable = keyState { true } else { false } }

    private func field(_ label: String, @ViewBuilder _ control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.ink)
            control()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The key's line (FirstRun.KeyState): a dot and its words.
    private var status: some View {
        let (dot, text, strong): (Color, String, Bool) = switch keyState {
        case .empty: (Brand.mist, L("It will be tried once; you go on when it works", lang: lang), false)
        case .set(let l): (ShellColor.ok, L("Set · ends in %@", l, lang: lang), false)
        case .checking: (Brand.dot, L("Trying this key…", lang: lang), false)
        case .ok(let m): (ShellColor.ok, L("Works · reached %@", m, lang: lang), true)
        case .bad(let why): (ShellColor.error, L("This key doesn't work: %@", why, lang: lang), true)
        case .unreadable: (ShellColor.error, L("The keys in the keychain can't be read", lang: lang), true)
        }
        return HStack(spacing: 8) {
            if keyState == .checking { ProgressView().controlSize(.small) }
            Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(text).font(.system(size: 12, weight: strong ? .semibold : .regular))
                .foregroundStyle(isBad ? ShellColor.error : strong ? Brand.ink : ShellColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                    Text(u == .permissions ? L("The helper's permissions aren't granted yet.", lang: lang)
                         : u == .keyUnreadable ? L("The keys in the keychain can't be read", lang: lang) : L("No model key yet.", lang: lang))
                        .font(.system(size: 12)).foregroundStyle(Brand.ink)
                    // (unreadable keys: the key step too, where a save replaces them)
                    Button(L("Finish setup", lang: lang)) { open(u == .permissions ? .permissions : .key) }
                        .buttonStyle(InkButtonStyle(prominent: false, small: true))
                }
            }
        }
    }
}
