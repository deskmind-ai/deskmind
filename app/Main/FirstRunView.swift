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
    /// What is typed: the model sheet's own form (ModelForm), so the step saves all the sheet saves.
    @State private var form = ModelForm(provider: CloudModelSettings.provider, settings: KeyStatus.shared.now.settings)
    @State private var busy = false

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
        return FirstRunPage(flow: shown, language: $language,
                            form: Binding(get: { form }, set: { new in
                                // (another service: as loaded anew -- its key and its check's result go; any edit
                                // moves the version, so a save or check still out for the old form is dropped)
                                form.edit(new, settings: keys.snapshot.settings)
                            }),
                            keyState: FirstRun.keyState(known: keys.snapshot.known, readable: keys.snapshot.readable,
                                                        last4: keys.snapshot.keys[form.provider.keyEnv], busy: busy, checkOK: form.checkOK,
                                                        why: form.why, model: form.reached),
                            granted: { model.granted($0) }, grant: { model.grant($0) },
                            act: act, example: { e in shell.draft = L(e, lang: lang); finish() })
            .onAppear { KeyStatus.shared.refresh() }
            .onChange(of: keys.snapshot) { _, s in form.settingsCame(s.settings) }
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

    /// 「继续」 on the key step: the form saved as the model sheet saves it (ModelForm.plan: the key if typed -- keys.set's
    /// merge, replacing only keys the helper can't read, A11 -- a custom service's URL and model, the service, its
    /// configuration) with the engine on (the conversations need it); then tried with the key the helper keeps. One
    /// that works moves on by itself, one that doesn't stays (稍后 still goes on).
    private func continueKey() {
        let plan = form.plan(engine: true)
        let replace = keys.snapshot.known && !keys.snapshot.readable
        busy = true; form.why = nil; form.checkOK = nil
        let version = form.version
        Task.detached {
            var failure: String?
            do { try CloudModelSettings.save(plan, replace: replace) } catch { failure = error.localizedDescription }
            await MainActor.run {
                // (the form changed meanwhile: this save's result is not the form's -- nothing said, nothing moved)
                guard let ok = form.saved(version: version, failure: failure) else { busy = false; return }
                if !plan.pairs.isEmpty { flow.apply(.saved(ok: ok)) }
                if !ok { busy = false; return }
                CloudModelSettings.apply(plan)
                form.key = ""
                model.refreshCloud()
                check(config: plan.engineConfig ?? "", version: version)
            }
        }
    }

    /// One tiny question to the model with the key the helper keeps (model_check): its answer, said as it is -- if
    /// the form is still the one it was asked for.
    private func check(config: String, version: Int) {
        busy = true
        Task.detached {
            let reply = DeskMindIPC.request(["op": "model_check", "config": config, "lang": ResolvedLang.current.rawValue], timeout: 60)
            await MainActor.run {
                busy = false
                let why = (reply?["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? L("No answer from the helper", lang: lang)
                guard let ok = form.checked(version: version, ok: reply?["ok"] as? Bool == true, reached: reply?["model"] as? String ?? config, why: why)
                else { return }
                if ok {
                    // (「能用」 seen for a moment, then on -- unless the form changed in that moment)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { if form.version == version { flow.apply(.checked(ok: true)) } }
                } else {
                    flow.apply(.checked(ok: false))
                }
            }
        }
    }
}

/// The first run as drawn (P1Setup): what it is given, nothing it asks for itself.
struct FirstRunPage: View {
    enum Action { case next, later, back, skipAll }
    let flow: FirstRun
    @Binding var language: String
    @Binding var form: ModelForm
    let keyState: FirstRun.KeyState
    let granted: (Grant) -> Bool
    let grant: (Grant) -> Void
    let act: (Action) -> Void
    let example: (String) -> Void
    @Environment(\.lang) private var lang

    var body: some View {
        HStack(spacing: 0) {
            promises.frame(width: 340).frame(maxHeight: .infinity).background(Color(ShellPalette.inkSurface))
            VStack(alignment: .leading, spacing: 18) {
                // (the title, and on its baseline at the right where the first run is: the board's 「首次启动」, with
                // the step of the four this one is)
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 22, weight: .bold)).cssLine(22, 1.4).foregroundStyle(Brand.ink).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 12)
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
            // (the window's own buttons, the system's, in the 12 pt row the board draws them in: the title bar is hidden)
            Color.clear.frame(height: 12)
            RoundedRectangle(cornerRadius: 10).strokeBorder(Color(ShellPalette.onInk), lineWidth: 5).frame(width: 64, height: 64)
                .overlay(alignment: .bottomTrailing) { Circle().fill(Brand.dot).frame(width: 18, height: 18).offset(x: 9, y: 9) }
                .padding(.top, 36)
                .accessibilityHidden(true)
            // (tracked 1 pt: the full-width colon keeps its width, as the board's text has it, and the line breaks after 「会」)
            Text(L("First, what goes to the cloud", lang: lang)).font(.system(size: 32, weight: .bold)).kerning(1).cssLine(32, 1.3).foregroundStyle(Color(ShellPalette.onInk))
                .fixedSize(horizontal: false, vertical: true)
            Text(L("DeskMind talks and plans with a cloud model; seeing the screen and finding buttons happen on this Mac.", lang: lang))
                .font(.system(size: 16)).cssLine(16, 1.7).foregroundStyle(Color(ShellPalette.onInkBody)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)       // (the promises at the column's foot)
            VStack(alignment: .leading, spacing: 12) {
                ForEach([FirstRunPage.shotPromise,
                         "It reads no file you didn't point it at",
                         "It asks before changing your things or sending anything out"], id: \.self) { p in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: "·").font(.system(size: 14, weight: .bold)).foregroundStyle(Color(ShellPalette.onInkPromise))
                        Text(L(p, lang: lang)).font(.system(size: 14)).cssLine(14, 1.6).foregroundStyle(Color(ShellPalette.onInkPromiseText))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, 32).padding(.vertical, 28)
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
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    privacyCard(L("What goes to the cloud", lang: lang), icon: .cloud,
                                ["Your conversations with it", "Window text a task reads", "File contents a task reads, only files you pointed it at"],
                                foot: L("Sent to the service you choose below.", lang: lang))
                    privacyCard(L("What stays on this Mac", lang: lang), icon: .laptop,
                                ["Screenshots: read on this Mac, the images not uploaded", "Files you didn't point it at"],
                                foot: L("The screen is read by a local model.", lang: lang))
                }
                .fixedSize(horizontal: false, vertical: true)      // (both as tall as the taller: the grid's row)
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

    /// The bottom line: 「全部跳过」「上一步」 on the left; on the right, on the key step 「以后可以在设置里改」, then
    /// 「稍后」 and the one main button (a 44 pt capsule, its right edge on the cards').
    private var bar: some View {
        // (the key step: what the form can save -- a key typed or set, a custom service's URL and model)
        let on = (flow.step == .key ? form.canSave(keySet: flow.facts.keySet) : flow.canContinue(typed: false)) && keyState != .checking
        return HStack(spacing: 18) {
            Button(L("Skip all", lang: lang)) { act(.skipAll) }.buttonStyle(.plain)
            if flow.step != .language { Button(L("Back", lang: lang)) { act(.back) }.buttonStyle(.plain) }
            Spacer()
            if flow.step == .key { Text(L("You can change this later in settings", lang: lang)) }
            if flow.showsLater(keyState) { Button(L("Later", lang: lang)) { act(.later) }.buttonStyle(.plain) }
            Button(flow.step == .examples ? L("Finish", lang: lang) : L("Continue", lang: lang)) { act(.next) }
                .buttonStyle(SetupMainButtonStyle())
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

    private func privacyCard(_ title: String, icon: SetupIcon.Kind, _ items: [String], foot: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SetupIcon(kind: icon).stroke(Brand.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 22, height: 16).accessibilityHidden(true)
                Text(title).font(.system(size: 16, weight: .bold)).cssLine(16, 1.4).foregroundStyle(Brand.ink)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.self) { i in
                    // (a list's round mark, 18 in from the card's text)
                    Text(L(i, lang: lang)).font(.system(size: 14)).cssLine(14, 1.55).foregroundStyle(Color(ShellPalette.setupBody))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 18)
                        .overlay(alignment: .topLeading) { Circle().fill(Color(ShellPalette.setupBody)).frame(width: 5, height: 5).padding(.top, 10).padding(.leading, 4) }
                }
            }
            // (the note at the card's foot: the taller card's list sets where)
            Text(foot).font(.system(size: 13)).cssLine(13, 1.5).foregroundStyle(ShellColor.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: .infinity, alignment: .bottomLeading)
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.line))
    }

    /// 「用哪个云端模型」 (a fieldset: its legend on the box's top edge): using one's own key -- the one way there is,
    /// shown selected -- then, under it, the service and the key (typed here), a custom service's URL and model, how
    /// the key is, and where it is kept.
    private var keyFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().strokeBorder(Brand.ink, lineWidth: 1.5)
                    Circle().fill(Brand.ink).frame(width: 8, height: 8)
                }
                .frame(width: 18, height: 18).padding(.top, 2).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Use my own key", lang: lang)).font(.system(size: 15, weight: .semibold)).cssLine(15, 1.4).foregroundStyle(Brand.ink)
                    Text(L("Billed to your own account", lang: lang)).font(.system(size: 13)).cssLine(13, 1.4).foregroundStyle(ShellColor.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.ink, lineWidth: 1.5))
            .accessibilityElement(children: .combine).accessibilityAddTraits(.isSelected)
            VStack(alignment: .leading, spacing: 12) {
                // (held while a save or check is out: what it answers is about these)
                HStack(alignment: .top, spacing: 12) {
                    field(L("Provider", lang: lang)) { providerMenu }
                    field(L("API key", lang: lang)) {
                        SecureField(isSet ? L("New API key (empty: keep it)", lang: lang) : L("Paste your key", lang: lang), text: $form.key)
                            .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(Brand.ink)
                            .padding(.horizontal, 12).frame(height: 40)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Brand.card))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isBad ? Color(ShellPalette.setupBad) : Brand.ink, lineWidth: 1.5))
                    }
                }
                .disabled(keyState == .checking)
                if form.provider.custom {
                    HStack(spacing: 12) {
                        field(L("Base URL (…/v1)", lang: lang)) { TextField("", text: $form.url).textFieldStyle(.roundedBorder) }
                        field(L("Model id", lang: lang)) { TextField("", text: $form.model).textFieldStyle(.roundedBorder) }
                    }
                    .disabled(keyState == .checking)
                }
                status
                Text(L("The key stays only in this Mac's keychain", lang: lang))
                    .font(.system(size: 12)).foregroundStyle(ShellColor.secondary)
            }
            .padding(.leading, 32)
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 18)
        .padding(.top, legendHeight)
        .background { Legend.box(top: legendHeight / 2) }
        .overlay(alignment: .topLeading) {
            Text(L("Which cloud model", lang: lang)).font(.system(size: 16, weight: .bold)).cssLine(16, 1.4).foregroundStyle(Brand.ink)
                .padding(.horizontal, 6)
                .background { GeometryReader { g in Color.clear.preference(key: Legend.Width.self, value: g.size.width) } }
                .padding(.leading, 14)
                .accessibilityAddTraits(.isHeader)
        }
        .overlayPreferenceValue(Legend.Width.self) { w in
            // (the box's top edge broken where the legend sits)
            Legend.edge(gapX: 14, gapWidth: w, top: legendHeight / 2)
        }
    }

    /// The legend's line: a 16 pt bold line, 1.4 apart (its box's top edge runs through its middle).
    private var legendHeight: CGFloat { 22.4 }

    /// The service: a 40 pt field-like menu as wide as its column (a down chevron at its right).
    private var providerMenu: some View {
        Menu {
            ForEach(CloudProvider.all) { p in Button { form.provider = p } label: { Text(verbatim: p.title) } }
        } label: {
            HStack {
                Text(verbatim: form.provider.title).font(.system(size: 14)).foregroundStyle(Brand.ink)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.ink).accessibilityHidden(true)
            }
            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ShellColor.buttonLine))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
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

    /// The key's line (FirstRun.KeyState): a dot and its words (P1Setup: works in green, doesn't in orange, both
    /// bold; the rest in the list's text).
    private var status: some View {
        let body = Color(ShellPalette.setupBody)
        let (dot, text, tone, strong): (Color, String, Color, Bool) = switch keyState {
        case .empty: (Brand.mist, L("It will be tried once; you go on when it works", lang: lang), body, false)
        case .set(let l): (ShellColor.ok, L("Set · ends in %@", l, lang: lang), body, false)
        case .checking: (Brand.dot, L("Trying this key…", lang: lang), body, false)
        case .ok(let m): (ShellColor.ok, L("Works · reached %@", m, lang: lang), Color(ShellPalette.setupOK), true)
        case .bad(let why): (Color(ShellPalette.setupBad), L("This key doesn't work: %@", why, lang: lang), ShellColor.orangeText, true)
        case .unreadable: (Color(ShellPalette.setupBad), L("The keys in the keychain can't be read", lang: lang), ShellColor.orangeText, true)
        }
        return HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(text).font(.system(size: 12, weight: strong ? .semibold : .regular)).foregroundStyle(tone)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The fieldset's box (P1Setup 「用哪个云端模型」): its card from the legend's middle down, and its edge with a gap
/// where the legend is.
enum Legend {
    struct Width: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
    static func box(top: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 16).fill(Brand.card).padding(.top, top)
    }
    static func edge(gapX: CGFloat, gapWidth: CGFloat, top: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 16).strokeBorder(Brand.line)
            .padding(.top, top)
            .mask {
                Canvas { c, size in
                    c.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Brand.ink))
                    c.blendMode = .clear
                    c.fill(Path(CGRect(x: gapX, y: 0, width: gapWidth, height: top * 2)), with: .color(Brand.ink))
                }
            }
            .allowsHitTesting(false)
    }
}

/// The privacy cards' line icons (P1Setup, 22 × 16, drawn in its units): a cloud, a laptop.
struct SetupIcon: Shape {
    enum Kind { case cloud, laptop }
    let kind: Kind
    func path(in r: CGRect) -> Path {
        var p = Path()
        switch kind {
        case .cloud:
            // M6 14.5h11 a4 4 … 17.6 6.55 A5.5 5.5 … 7 5.2 4.7 4.7 … 6 14.5z
            p.move(to: CGPoint(x: 6, y: 14.5))
            p.addLine(to: CGPoint(x: 17, y: 14.5))
            p.addArc(center: CGPoint(x: 17.3, y: 10.53), radius: 4, startAngle: .degrees(94.3), endAngle: .degrees(-85.7), clockwise: true)
            p.addArc(center: CGPoint(x: 12.14, y: 7.16), radius: 5.5, startAngle: .degrees(-6.4), endAngle: .degrees(-159.1), clockwise: true)
            p.addArc(center: CGPoint(x: 6.97, y: 9.9), radius: 4.7, startAngle: .degrees(-89.6), endAngle: .degrees(-258.1), clockwise: true)
            p.closeSubpath()
        case .laptop:
            p.addRect(CGRect(x: 4, y: 2, width: 14, height: 9))
            p.move(to: CGPoint(x: 1.5, y: 14)); p.addLine(to: CGPoint(x: 20.5, y: 14))
        }
        return p.applying(CGAffineTransform(translationX: r.minX, y: r.minY).scaledBy(x: r.width / 22, y: r.height / 16))
    }
}

extension View {
    /// Lines `height` × `size` apart, as the board's CSS line-height sets them: the font's own line made up to it,
    /// between the lines and half above and below.
    func cssLine(_ size: CGFloat, _ height: CGFloat) -> some View {
        let f = NSFont.systemFont(ofSize: size)
        let extra = max(0, size * height - (f.ascender - f.descender + f.leading))
        return lineSpacing(extra).padding(.vertical, extra / 2)
    }
}

/// The first run's main button (P1Setup 「继续」): an ink capsule, 44 high, 26 either side of its 15 pt semibold words.
struct SetupMainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Brand.paper)
            .padding(.horizontal, 26).frame(height: 44)
            .background(Capsule().fill(Brand.ink))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
            .pointerStyle(.link)
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
