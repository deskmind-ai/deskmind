// A computer task in the chat (M2 A3): its cards that are no longer pinned, where it is (preparing, step n of m, paused
// while you use the Mac, checking the result, stopping, waiting for you), and how it ended -- the result card: what it
// did, what went out, what was undone, what it couldn't confirm, with undo while the harness offers it.
//
// The result card's state is the session's (TaskState.resultCardState, Shared/ResultCard.swift): its undo takes a click
// exactly while it is open with undo offered, its rows say what came of the undo from the harness's record, and the
// countdown to `undo_until` is for display only.
//
// Focus (handoff §3.1): nothing here activates the app, brings a window forward or moves the keyboard focus
// (ShellTests.focusTests reads the window's view files from build.sh).

import SwiftUI

struct TaskRow: View {
    @ObservedObject var shell: ShellModel
    let task: TaskState
    let session: SessionState
    /// Its Stop: the chat's (the selected session's task) unless given.
    var stop: (() -> Void)? = nil
    @Environment(\.lang) private var lang

    /// The 「● DeskMind」 label above it (the first of DeskMind's turn: ChatColumn.speaks).
    var labelled = false

    /// Not a box (P1Main): what was asked is the user's bubble above, so it is not said again here. DeskMind's label,
    /// its cards no longer pinned -- whole while no card waits (P1Main), a line each while one does (P1Waiting) -- then
    /// where it is, in a line with the orange dot (two while a card waits: the step done, the one that waits); the card
    /// too tall to pin, in place; once it ended, its result card.
    // (in typed pieces: CI's older compiler gives up on long view expressions, rc.21)
    var body: some View {
        let pinned: Pinned? = shell.pinned(session)
        let mine: Pinned? = Self.mine(pinned, runId: task.runId)
        let answered: [CardState] = shown(pinned: pinned?.card.askId)
        let compact: Bool = pinned != nil
        return VStack(alignment: .leading, spacing: 12) {
            if labelled { SpeakerLabel() }
            // (a card voided by the user's change and asked again is the new card's 「已作废」 strip, not a card of its own)
            ForEach(answered, id: \.askId) { c in answeredRow(c, compact: compact) }
            if task.running { statusLines(pinned: mine) }
            // (the pinned card is above the composer -- or here, whole, when it is too tall to pin: A2)
            if let p = mine { tooTall(p) }
            if !task.running { ended }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Computer task: %@", task.raw, lang: lang))
    }

    typealias Pinned = (runId: String, card: CardState, phase: CardPhase)

    static func mine(_ p: Pinned?, runId: String) -> Pinned? {
        guard let p, p.runId == runId else { return nil }
        return p
    }

    private func answeredRow(_ c: CardState, compact: Bool) -> some View {
        let phase: CardPhase = shell.phase(task.runId, c, in: session)
        return AnsweredRow(card: c, runId: task.runId, phase: phase, compact: compact)
    }

    @ViewBuilder private func tooTall(_ p: Pinned) -> some View {
        let m = CardModel(card: p.card.card, runId: p.runId, askId: p.card.askId)
        if !shell.cardPinnedWhole(m) {
            CardView(shell: shell, card: m, phase: p.phase, askedAt: p.card.askedAt, session: session).id(Self.cardAnchor(m))
        }
    }

    /// Once it ended: its answer (when it says more than the summary, and nothing was undone) and its result card.
    @ViewBuilder private var ended: some View {
        if ShellText.fullyUndone(task) == nil, let a = task.answer, !a.isEmpty, a != ShellText.summary(task, lang: lang) {
            Text(a).font(.system(size: 15)).lineSpacing(15 * 0.55 - 3).foregroundStyle(Brand.ink).textSelection(.enabled)
        }
        ResultSection(shell: shell, task: task, session: session)
    }

    /// Its cards as the chat shows them: not the pinned one, and not one voided by a change the next card was asked for.
    private func shown(pinned: String?) -> [CardState] {
        task.cards.enumerated().filter { i, c in
            guard c.askId != pinned else { return false }
            if i + 1 < task.cards.count, case .voided("steer") = shell.phase(task.runId, c, in: session) { return false }
            return true
        }.map(\.1)
    }

    /// Where it is (P1Main): the orange dot with its halo and 「执行中 · 第 2 步，共 4 步：写入回复」; while its card waits
    /// (P1Waiting), the step done with a green check, then 「第 3 步要往外发，先等你确认 · 已置顶在输入框上方」 in orange.
    @ViewBuilder private func statusLines(pinned: (runId: String, card: CardState, phase: CardPhase)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let p = pinned, p.phase == .open {
                if let done = task.steps.last(where: { $0.status == .ok || $0.status == .unverified }) {
                    HStack(spacing: 8) {
                        CheckMark().stroke(ShellColor.ok, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .frame(width: 13, height: 13).accessibilityHidden(true)
                        Text(L("Step %d done: %@", done.planStep ?? done.n, done.displayText, lang: lang))
                            .font(.system(size: 13)).foregroundStyle(ShellColor.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                let m = CardModel(card: p.card.card, runId: p.runId, askId: p.card.askId)
                HStack(spacing: 8) {
                    dot(halo: 0.28)
                    Text(waitLine(m)).font(.system(size: 13, weight: .semibold)).foregroundStyle(ShellColor.orangeText)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    dot(halo: 0.2)
                    Text(line).font(.system(size: 13)).foregroundStyle(CardColor.body)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    // (Stop: the header's in the chat; a row given its own Stop shows it)
                    if let stop {
                        Button(L("Stop", lang: lang)) { stop() }
                            .buttonStyle(InkButtonStyle(prominent: false, small: true))
                            .disabled(task.stopping)
                            .accessibilityLabel(L("Stop", lang: lang))
                            .accessibilityHint(L("Stops the computer task", lang: lang))
                    }
                }
            }
        }
    }

    private func dot(halo: Double) -> some View {
        Circle().fill(Brand.dot).frame(width: 8, height: 8)
            .overlay(Circle().stroke(Brand.dot.opacity(halo), lineWidth: 4))
            .padding(4)
            .accessibilityHidden(true)
    }

    /// 「第 3 步要往外发，先等你确认 · 已置顶在输入框上方」: the step the card waits on (the one after the last with a plan
    /// step), whether it sends (CardModel.sends), and where the card is.
    private func waitLine(_ m: CardModel) -> String {
        // (the step it waits on: the last one while it has no result yet, else the one after it)
        let next: Int? = task.plan.isEmpty ? nil : task.steps.last.flatMap { $0.status == .running ? $0.planStep : $0.planStep.map { $0 + 1 } }
        let what: String
        switch (m.sends, next) {
        case (true, let n?): what = L("Step %d sends something out: waiting for you to confirm", n, lang: lang)
        case (true, nil): what = L("It sends something out: waiting for you to confirm", lang: lang)
        case (false, let n?) where m.kind == .action: what = L("Step %d waits for you to confirm", n, lang: lang)
        default: what = L("Waiting for your answer", lang: lang)
        }
        return shell.cardPinnedWhole(m) ? L("%@ · pinned above the message field", what, lang: lang) : what
    }

    /// 「执行中 · 第 2 步，共 4 步：写入回复」: where it is, and its current step in words.
    private var line: String {
        let state = ShellText.task(task, lang: lang)
        guard let step = task.steps.last, shell.pinned(session)?.runId != task.runId else { return state }
        return L("%@: %@", state, step.displayText, lang: lang)
    }

    /// Where 「跳到卡片」 scrolls to: a card drawn in place in the chat.
    static func cardAnchor(_ card: CardModel) -> String { "card/" + ShellModel.cardKey(card) }
}

/// The result card (P3States 「结果卡」, P1Flow frame 6): 300 wide, its head -- 做完了, 已撤回 · 11:20, 撤回了一部分 (orange),
/// 做了，但没法确认结果, or how it ended -- then a row per thing under its 58 pt label (做了 / 发出去的 / 已撤回 / 没撤回 /
/// 改动 / 没确认), from the harness's own words and the task's record; 「撤回」 only while the harness offers it (a
/// button only when there is something to do -- no 「好的」), and 「复盘 ›」 to the task's process. Under it, the line:
/// the minutes left to undo (display only), 「撤回中」, or why the undo can no longer be done.
struct ResultSection: View {
    @ObservedObject var shell: ShellModel
    let task: TaskState
    let session: SessionState
    @Environment(\.lang) private var lang

    var body: some View {
        // (an end with no result card and nothing to list -- stopped before it did anything: its words in a line, no card)
        if task.resultCard == nil && rows.isEmpty {
            HStack(spacing: 10) {
                Text(head).font(.system(size: 13)).foregroundStyle(ShellColor.secondary)
                Button(L("Review ›", lang: lang)) { shell.showProcess(task.runId) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(ShellColor.orangeText)
                    .accessibilityLabel(L("Review", lang: lang))
                    .accessibilityHint(L("Shows this task's process in the right column", lang: lang))
            }
        } else {
            card
        }
    }

    // (in typed pieces: CI's older compiler gives up on long view expressions, rc.21)
    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 7) {
                headRow
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in rowView(r) }
                Spacer(minLength: 0)
                if let foot { Text(foot).font(.system(size: 11)).foregroundStyle(ShellColor.secondary).fixedSize(horizontal: false, vertical: true) }
                actions
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(width: 300, alignment: .leading)
            .frame(minHeight: 180, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Brand.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.line, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(head)
            // (the countdown refreshes each 30 s; whether undo can be clicked never reads the clock)
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                if let l = resultLine {
                    Text(l).font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(l)
                }
            }
        }
    }

    private var headRow: some View {
        let colour: Color = partlyUndone ? ShellColor.orangeText : Brand.ink
        return HStack(spacing: 6) {
            if headOK {
                CheckMark().stroke(ShellColor.ok, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 13, height: 13).accessibilityHidden(true)
            }
            Text(head).font(.system(size: 15, weight: .bold)).foregroundStyle(colour)
        }
    }

    private func rowView(_ r: Row) -> some View {
        let weight: Font.Weight = r.bad ? .bold : .regular
        let colour: Color = r.bad ? ShellColor.orangeText : ShellColor.secondary
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(r.label).font(.system(size: 12, weight: weight))
                .foregroundStyle(colour).frame(width: 58, alignment: .leading)
            Text(r.value).font(.system(size: 12)).lineSpacing(2).foregroundStyle(CardColor.body)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// Its undo -- the card's own option, open only while the harness offers it -- then 复盘 and 「已录制」.
    private var undoButtons: [(CardModel, CardModel.Button)] {
        guard let r = task.resultCard else { return [] }
        let m = CardModel(resultCard: r, runId: task.runId)
        return m.buttons.filter { $0.role == .undo }.map { (m, $0) }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            // (its undo: the card's own option, through shell.click -- open only while the harness offers it)
            ForEach(undoButtons, id: \.1.index) { m, b in
                if task.resultCardState.undoEnabled {
                    Button(b.text) { _ = shell.click(b) }
                        .buttonStyle(CardButtonStyle(prominent: false, height: 32, radius: 16, size: 12, fill: false))
                        .disabled(!shell.buttonEnabled(b, card: m, in: session))
                        .accessibilityLabel(b.text)
                        .accessibilityHint(L("Undoes what the task changed", lang: lang))
                }
            }
            Spacer(minLength: 0)
            Button(L("Review ›", lang: lang)) { shell.showProcess(task.runId) }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(ShellColor.orangeText)
                .accessibilityLabel(L("Review", lang: lang))
                .accessibilityHint(L("Shows this task's process in the right column", lang: lang))
            // 「已录制」: the task's movie (Movies › DeskMind), when one was made
            if let path = shell.movies[task.runId] {
                Button(L("Recorded", lang: lang)) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(ShellColor.orangeText)
                    .accessibilityLabel(L("Recorded", lang: lang))
                    .accessibilityHint(L("Opens the task's recording", lang: lang))
            }
        }
    }

    /// The line under the card: what ShellText.resultLine says, but not a count the card's rows already give.
    private var resultLine: String? {
        if case .undone = task.resultCardState { return nil }
        return ShellText.resultLine(task, hint: shell.cards.hint(task.runId), now: shell.now(), lang: lang)
    }

    private var undone: (n: Int, m: Int, refused: String?)? {
        if case .undone(let n, let m, let r) = task.resultCardState { return (n, m, r) }
        return nil
    }
    private var partlyUndone: Bool { undone.map { $0.n < $0.m || $0.refused != nil } ?? false }
    private var headOK: Bool { undone == nil && task.status == "succeeded" }

    /// 做完了 / 已撤回 · 11:20 / 撤回了一部分 / 做了，但没法确认结果 / how it ended.
    private var head: String {
        if let u = undone {
            if u.n == u.m && u.refused == nil && u.m > 0 { return task.undoAt.map { L("Undone · %@", ShellText.time($0), lang: lang) } ?? L("Undone", lang: lang) }
            return L("Partly undone", lang: lang)
        }
        switch task.status {
        case "succeeded": return L("It's done", lang: lang)
        case "unconfirmed": return L("Done, but the result can't be confirmed", lang: lang)
        default: return ShellText.task(task, lang: lang)
        }
    }

    struct Row { var label: String; var value: String; var bad = false }

    /// Its rows: the harness's result card, a line each -- 「做了：…」 as 做了 and its words -- else the summary; what went
    /// out; what the undo did; the changes, or that there were none; what could not be confirmed.
    private var rows: [Row] {
        var out: [Row] = []
        let changes = task.done?.changes ?? task.end?.changes
        if let u = undone {
            out.append(Row(label: L("Undone", lang: lang), value: L("%d of %d changes", u.n, u.m, lang: lang)))
            if let r = u.refused { out.append(Row(label: L("Not undone", lang: lang), value: r, bad: true)) }
            else if u.n < u.m { out.append(Row(label: L("Not undone", lang: lang), value: L("%d changes", u.m - u.n, lang: lang), bad: true)) }
            return out
        }
        let text = task.resultCard?.text ?? ""
        for l in text.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !l.isEmpty {
            out.append(Self.row(l))
        }
        if out.isEmpty {
            let s = ShellText.summary(task, lang: lang)
            if !s.isEmpty { out.append(Row(label: L("Did", lang: lang), value: s)) }
        }
        if let ext = changes?.external, !ext.isEmpty {
            out.append(Row(label: L("Went out", lang: lang), value: ext.joined(separator: "、") + " · " + L("Sent (it can't be undone from here)", lang: lang)))
        }
        if let c = changes {
            let n = (c.created.count, c.modified.count, c.deleted.count)
            if n.0 + n.1 + n.2 > 0 && !out.contains(where: { $0.label == L("Changes", lang: lang) }) {
                out.append(Row(label: L("Changes", lang: lang), value: L("Created %d · changed %d · deleted %d", n.0, n.1, n.2, lang: lang)))
            } else if c.isEmpty && task.status == "succeeded" {
                out.append(Row(label: L("Changes", lang: lang), value: L("Nothing of yours changed and nothing was sent out", lang: lang)))
            }
            if !c.unconfirmed.isEmpty { out.append(Row(label: L("Not confirmed", lang: lang), value: c.unconfirmed.joined(separator: "、"), bad: true)) }
        }
        return out
    }

    /// Under it: what went out is handled where it went; undo covers this Mac's changes only.
    private var foot: String? {
        guard undone == nil, let ext = (task.done?.changes ?? task.end?.changes)?.external, !ext.isEmpty else { return nil }
        return L("What was sent out is handled where it went; undo covers only the changes on this Mac", lang: lang)
    }

    /// A line of the harness's result card under its head (CardModel.resultRow).
    static func row(_ line: String) -> Row {
        let r = CardModel.resultRow(line)
        return Row(label: r.label, value: r.value)
    }
}
