// The right column's 「过程」 tab (M5, plan §11): one task's run as its folder recorded it -- the timeline (each step, its
// result, its picture: ← → pages through them, the replay), the judges' questions (each with 「对 / 不对」 and a note),
// the cost by role, what it changed, and the labels. Drawn from RunDir.Model alone (a cell with no record says
// 「没有记录」) and the labels' file (Annotations: the only thing written, on this Mac). Read only: it sends nothing,
// and opens, pages and labels without bringing anything forward or moving the focus.

import AppKit
import SwiftUI

/// Reads a run's folder and its labels off the main queue, again whenever any of its records grows (RunDir.signature:
/// every file the pane reads, checked each second off the main queue -- #126 Codex review at e419501: an undo's
/// result_response, a judge, a model call never showed).
final class ProcessLoader: ObservableObject {
    @Published private(set) var model: RunDir.Model = .none
    @Published private(set) var labels: [Annotations.Line] = []
    private var asked = 0
    private var timer: Timer?
    private var seen: String?

    /// Read now, then again each time the run's files change, until `stop`.
    func watch(session: String, run: String) {
        stop()
        seen = nil
        let check = { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                let sig = RunDir.signature(session: session, run: run)
                DispatchQueue.main.async {
                    guard let self, sig != self.seen else { return }
                    self.seen = sig
                    self.load(session: session, run: run)
                }
            }
        }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in check() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func load(session: String, run: String) {
        asked += 1
        let ticket = asked
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let m = RunDir.folder(session: session, run: run).map { RunDir.model(RunDir.files(at: $0)) } ?? .none
            let l = Annotations.current(Annotations.lines(run))
            DispatchQueue.main.async {
                guard let self, ticket == self.asked else { return }      // (an older read that came back late)
                if self.model != m { self.model = m }
                if self.labels != l { self.labels = l }
            }
        }
    }
}

/// The step pictures, decoded off the main queue once each and kept (at most `limit`, the oldest asked for first to go).
final class ShotCache: ObservableObject {
    static let limit = 48
    @Published private(set) var images: [String: NSImage] = [:]
    private var order: [String] = [], loading: Set<String> = []

    /// The picture at `url`, if decoded; asked for once, decoded off the main queue.
    func image(_ url: URL) -> NSImage? {
        let k = url.path
        if let i = images[k] { return i }
        guard loading.insert(k).inserted else { return nil }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let img = NSImage(contentsOf: url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(k)
                guard let img else { return }
                self.images[k] = img; self.order.append(k)
                while self.order.count > Self.limit { self.images[self.order.removeFirst()] = nil }
            }
        }
        return nil
    }
}

/// Drawn again only when its own inputs change (`trigger`: the task's steps, end, pictures) -- not on every change of
/// the window's model (#126 review).
struct ProcessPane: View, Equatable {
    let sessionId: String
    let runId: String
    /// Where to show (「明细 ›」: 改动), and its asks: each one scrolls there again.
    var focus: ProcessTabs.Focus? = nil
    var focusAsks = 0
    static func == (a: ProcessPane, b: ProcessPane) -> Bool {
        a.sessionId == b.sessionId && a.runId == b.runId && a.focus == b.focus && a.focusAsks == b.focusAsks
    }
    @StateObject private var loader = ProcessLoader()
    @StateObject private var shots = ShotCache()
    @Environment(\.lang) private var lang
    /// The picture shown large (the step's index), if any.
    @State private var big: Int?
    @State private var openJudges: Set<String> = []
    @State private var notes: [String: String] = [:]


    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(.vertical, 4)
            }
            // (「明细 ›」: to 改动 -- once laid out, and on each new ask)
            .onChange(of: focusAsks, initial: true) { _, _ in if focus == .changes { scroll(proxy) } }
            .onChange(of: loader.model.changes != nil) { _, _ in if focus == .changes { scroll(proxy) } }
        }
        .onAppear { loader.watch(session: sessionId, run: runId) }
        .onDisappear { loader.stop() }
        .sheet(isPresented: Binding(get: { big != nil }, set: { if !$0 { big = nil } })) { ShotViewer(pane: self) }
    }

    @ViewBuilder private var content: some View {
        let m = loader.model
        switch m.state {
        case .none where loader.labels.isEmpty:
            Text(L("No record", lang: lang)).foregroundStyle(ShellColor.secondary)
        case .pruned, .none:
            if m.state == .pruned { Text(L("Run records cleared", lang: lang)).foregroundStyle(ShellColor.secondary) }
            if !loader.labels.isEmpty {
                labelsSection
                section(L("Timeline", lang: lang)) { noRecord }
                section(L("Cost", lang: lang)) { noRecord }
                section(L("Changes", lang: lang)) { noRecord }
            }
        case .running, .ended:
            timeline(m)
            judges(m)
            cost(m)
            changes(m)
            if !loader.labels.isEmpty { labelsSection }
        }
    }

    private var noRecord: some View { Text(L("No record", lang: lang)).font(.system(size: 11)).foregroundStyle(ShellColor.secondary) }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.ink)
            c()
        }
    }

    // MARK: timeline

    private func timeline(_ m: RunDir.Model) -> some View {
        section(L("Timeline", lang: lang)) {
            if m.steps.isEmpty { noRecord }
            ForEach(Array(m.steps.enumerated()), id: \.element.stepId) { i, s in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.planStep.map { L("Plan step %d", $0, lang: lang) } ?? L("No plan step", lang: lang))
                            .font(.system(size: 10)).foregroundStyle(ShellColor.secondary)
                        Text(s.words).font(.system(size: 11)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
                        Text([s.status, s.why].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? L("No record", lang: lang))
                            .font(.system(size: 10)).foregroundStyle(ShellColor.secondary)
                        if m.hasTrace, let a = s.act {
                            if let r = a.epochReason { Text(r).font(.system(size: 10)).foregroundStyle(ShellColor.secondary) }
                            if let c = a.changed { Text(c).font(.system(size: 10, design: .monospaced)).foregroundStyle(ShellColor.secondary).lineLimit(2) }
                        }
                    }
                    Spacer(minLength: 4)
                    if let img = shot(s) {
                        Button { big = i } label: { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 72) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L("Picture of step %d", i + 1, lang: lang))
                    } else {
                        Text(L("No record", lang: lang)).font(.system(size: 9)).foregroundStyle(ShellColor.secondary).frame(width: 72)
                    }
                }
            }
        }
    }

    func shot(_ s: RunDir.Step) -> NSImage? {
        guard let p = s.shot.flatMap(RunDir.contained), let dir = RunDir.folder(session: sessionId, run: runId) else { return nil }
        return shots.image(dir.appendingPathComponent(p))
    }

    /// The step pictures as one strip: the replay.
    struct ShotViewer: View {
        let pane: ProcessPane
        @Environment(\.lang) private var lang
        var body: some View {
            let steps = pane.loader.model.steps
            let i = min(max(pane.big ?? 0, 0), max(steps.count - 1, 0))
            VStack(spacing: 8) {
                if steps.indices.contains(i) {
                    Text(steps[i].words).font(.system(size: 12)).foregroundStyle(Brand.ink)
                    if let img = pane.shot(steps[i]) { Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 720, maxHeight: 520) }
                    else { Text(L("No record", lang: lang)).foregroundStyle(ShellColor.secondary).frame(width: 320, height: 200) }
                }
                HStack {
                    Button(L("Previous", lang: lang)) { pane.big = page(steps, from: i, by: -1) }.keyboardShortcut(.leftArrow, modifiers: [])
                    Button(L("Close", lang: lang)) { pane.big = nil }.keyboardShortcut(.cancelAction)
                    Button(L("Next", lang: lang)) { pane.big = page(steps, from: i, by: 1) }.keyboardShortcut(.rightArrow, modifiers: [])
                }
            }
            .padding(16)
        }
        /// The next step with a picture that way (or where it is).
        private func page(_ steps: [RunDir.Step], from i: Int, by d: Int) -> Int {
            var j = i + d
            while steps.indices.contains(j) { if steps[j].shot != nil { return j }; j += d }
            return i
        }
    }

    // MARK: judges

    private func judges(_ m: RunDir.Model) -> some View {
        section(L("Judges", lang: lang)) {
            if m.judges.isEmpty { noRecord }
            ForEach(m.judges, id: \.judgeId) { j in judgeRow(j) }
        }
    }

    private func judgeRow(_ j: RunDir.Judge) -> some View {
        let label = loader.labels.last { $0.judge_id == j.judgeId }
        let open = openJudges.contains(j.judgeId)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                if open { openJudges.remove(j.judgeId) } else { openJudges.insert(j.judgeId) }
            } label: {
                HStack(spacing: 6) {
                    Text(j.question).font(.system(size: 11, weight: .medium))
                    Text(j.answer ?? L("No record", lang: lang)).font(.system(size: 11))
                    if let by = j.by { Text(by).font(.system(size: 10)).foregroundStyle(ShellColor.secondary) }
                    if let c = j.confidence { Text(String(format: "%.2f", c)).font(.system(size: 10).monospacedDigit()).foregroundStyle(ShellColor.secondary) }
                    if let s = j.shadow { Text(L("Shadow: %@", s.agree.map { $0 ? "=" : "≠" } ?? "?", lang: lang)).font(.system(size: 10)).foregroundStyle(ShellColor.secondary) }
                    if let ms = j.ms { Text(String(format: "%.1f s", Double(ms) / 1000)).font(.system(size: 10).monospacedDigit()).foregroundStyle(ShellColor.secondary) }
                    Spacer()
                    if let l = label { Text(l.label == .right ? L("Right", lang: lang) : L("Wrong", lang: lang)).font(.system(size: 10, weight: .semibold)) }
                }
                .foregroundStyle(Brand.ink)
            }
            .buttonStyle(.plain)
            if open {
                Text(j.kind ?? L("No record", lang: lang)).font(.system(size: 10)).foregroundStyle(ShellColor.secondary)
                Text(j.prompt ?? L("No record", lang: lang)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Brand.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let opts = j.options {
                    ForEach(opts, id: \.id) { o in Text("\(o.id): \(o.text)").font(.system(size: 10)).foregroundStyle(ShellColor.secondary) }
                }
                ForEach(Array(j.tiers.enumerated()), id: \.offset) { _, t in
                    Text(t.line)
                        .font(.system(size: 10)).foregroundStyle(ShellColor.secondary)
                }
                HStack {
                    TextField(L("Note", lang: lang), text: Binding(get: { shownNote(j, label) }, set: { notes[j.judgeId] = $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    Button(L("Right", lang: lang)) { mark(j, .right) }
                    Button(L("Wrong", lang: lang)) { mark(j, .wrong) }
                }
            }
        }
    }

    /// A label: one line appended (the question's material copied from what the view shows), read back.
    /// The note the field shows: what was typed, else the label's own (a relabel keeps it: #126 review).
    private func shownNote(_ j: RunDir.Judge, _ label: Annotations.Line?) -> String { notes[j.judgeId] ?? label?.note ?? "" }

    private func mark(_ j: RunDir.Judge, _ label: Annotations.Label) {
        let note = shownNote(j, loader.labels.last { $0.judge_id == j.judgeId }).trimmingCharacters(in: .whitespacesAndNewlines)
        Annotations.add(Annotations.Line(judge_id: j.judgeId, run_id: runId, label: label, note: note.isEmpty ? nil : note,
                                         at: Date().timeIntervalSince1970, sample: Annotations.sample(j)))
        loader.load(session: sessionId, run: runId)
    }

    // MARK: cost

    private func cost(_ m: RunDir.Model) -> some View {
        section(L("Cost", lang: lang)) {
            if m.cost.isEmpty { noRecord }
            ForEach(m.cost, id: \.role) { r in
                HStack(spacing: 8) {
                    Text(r.role).font(.system(size: 11, weight: r.role == "loop" ? .semibold : .regular))
                    Spacer()
                    Text(L("%d calls", r.calls, lang: lang))
                    Text("\(r.tokensIn) / \(r.tokensOut)")
                    Text(String(format: "$%.4f", r.costUSD))
                    Text(String(format: "%.1f s", Double(r.medianMs) / 1000))
                }
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(Brand.ink)
            }
        }
    }

    // MARK: changes

    private func scroll(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.changesAnchor, anchor: .top) } }
    }
    static let changesAnchor = "process/changes"

    /// 改动: the right column's rows, from the run's own record (RightColumn.rows over ChangeInput.of: one function,
    /// one view -- ChangeRowView); then the undo's answer and the trace's own lists.
    private func changes(_ m: RunDir.Model) -> some View {
        section(L("Changes", lang: lang)) {
            if let c = m.changes {
                ForEach(Array(RightColumn.rows(.of(m)).enumerated()), id: \.offset) { _, r in ChangeRowView(row: r) }
                if let u = c.undo {
                    Text(L("Undo: %@", [u.effect, u.undone.map { "\($0)" }, u.total.map { "/\($0)" }].compactMap { $0 }.joined(), lang: lang)).font(.system(size: 10))
                }
                if m.hasTrace {
                    list(L("Files written", lang: lang), c.filesWritten ?? [])
                    list(L("Files not credited", lang: lang), c.notCredited ?? [])
                    list(L("Changed by another program", lang: lang), c.externalChange ?? [])
                    list(L("Windows made", lang: lang), c.windowsCreated ?? [])
                }
            } else { noRecord }
        }
        .id(Self.changesAnchor)
    }

    @ViewBuilder private func list(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(ShellColor.secondary)
            ForEach(items, id: \.self) { Text($0).font(.system(size: 10)).foregroundStyle(Brand.ink).lineLimit(2).truncationMode(.middle) }
        }
    }

    // MARK: labels

    private var labelsSection: some View {
        section(L("Labels", lang: lang)) {
            ForEach(loader.labels, id: \.judge_id) { line in
                let l = Annotations.shown(line)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(l.question).font(.system(size: 11, weight: .medium))
                        Text(l.answer ?? L("No record", lang: lang)).font(.system(size: 11))
                        if let by = l.by { Text(by).font(.system(size: 10)).foregroundStyle(ShellColor.secondary) }
                        Spacer()
                        Text(l.label == .right ? L("Right", lang: lang) : L("Wrong", lang: lang)).font(.system(size: 10, weight: .semibold))
                    }
                    if let n = l.note { Text(n).font(.system(size: 10)).foregroundStyle(Brand.ink) }
                    // (the whole prompt, as kept: the pane scrolls)
                    Text(l.prompt ?? L("Original text not saved", lang: lang)).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(ShellColor.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    ForEach(l.options, id: \.self) { Text($0).font(.system(size: 10)).foregroundStyle(ShellColor.secondary) }
                    ForEach(Array(l.tiers.enumerated()), id: \.offset) { _, t in Text(t).font(.system(size: 10)).foregroundStyle(ShellColor.secondary) }
                    if let sh = l.shadow { Text(L("Shadow: %@", sh, lang: lang)).font(.system(size: 10)).foregroundStyle(ShellColor.secondary) }
                }
                .foregroundStyle(Brand.ink)
            }
            Button(L("Export Labels…", lang: lang)) { export() }
        }
    }

    /// The labels' file, as it is, to where the user chooses.
    private func export() {
        let p = NSSavePanel()
        p.nameFieldStringValue = runId + "-labels.jsonl"
        p.begin { r in
            guard r == .OK, let url = p.url else { return }
            _ = Annotations.export(runId, to: url)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
