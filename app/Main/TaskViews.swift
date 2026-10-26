// A computer task in the chat (M2 A3): what was asked and who started it, where it is (preparing, step n of m, paused
// while you use the Mac, checking the result, stopping), its cards that are no longer pinned, and how it ended in plain
// words (done, done but not confirmed, didn't finish, cancelled, stopped — the screen locked, the helper quit, the last
// step unknown — interrupted); then its result card with undo.
//
// The result card's state is the session's (TaskState.resultCardState, Shared/ResultCard.swift): its buttons take a
// click exactly while it is open (undo: while the harness offers it), its line says what came of the undo from the
// harness's record, and the countdown to `undo_until` is for display only.
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
    /// then a line -- the orange dot while it runs, where it is and its current step -- with 「过程」, 「已录制」 and Stop;
    /// its cards; how it ended and its result card.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if labelled { SpeakerLabel() }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if task.running {
                    Circle().fill(Brand.dot).frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Brand.dot.opacity(0.2), lineWidth: 4))
                        .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "macwindow").font(.system(size: 12)).foregroundStyle(ShellColor.secondary).accessibilityHidden(true)
                }
                Text(line).font(.system(size: 13)).foregroundStyle(task.running ? Brand.ink : ShellColor.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                // the task's 「过程」 in the right column (M5): for a task that ended (the running one's is the column's
                // own tab; the board's running line is the status alone)
                if stop == nil && !task.running {
                    Button(L("Process", lang: lang)) { shell.showProcess(task.runId) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(ShellColor.orangeText)
                        .accessibilityHint(L("Shows this task's process in the right column", lang: lang))
                }
                // 「已录制」: the task's movie (Movies › DeskMind), when one was made
                if task.ended, let path = shell.movies[task.runId] {
                    Button(L("Recorded", lang: lang)) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(ShellColor.orangeText)
                        .accessibilityHint(L("Opens the task's recording", lang: lang))
                }
                // (Stop: the header's in the chat; a row given its own Stop shows it)
                if task.running, let stop {
                    Button(L("Stop", lang: lang)) { stop() }
                        .buttonStyle(InkButtonStyle(prominent: false, small: true))
                        .disabled(task.stopping)
                        .accessibilityLabel(L("Stop", lang: lang))
                        .accessibilityHint(L("Stops the computer task", lang: lang))
                }
            }
            // (the pinned card is above the composer -- or here, whole, when it is too tall to pin: A2; the rest are a line
            // each, in their phase)
            if let p = shell.pinned(session), p.runId == task.runId {
                let m = CardModel(card: p.card.card, runId: p.runId, askId: p.card.askId)
                if !shell.cardPinnedWhole(m) {
                    CardView(shell: shell, card: m, phase: p.phase, askedAt: p.card.askedAt, session: session).id(Self.cardAnchor(m))
                }
            }
            ForEach(task.cards.filter { $0.askId != shell.pinned(session)?.card.askId }, id: \.askId) { c in
                AnsweredRow(card: c, runId: task.runId, phase: shell.phase(task.runId, c, in: session))
            }
            if !task.running {
                let summary = ShellText.summary(task, lang: lang)
                if !summary.isEmpty { Text(summary).font(.system(size: 15)).foregroundStyle(Brand.ink).textSelection(.enabled) }
                if ShellText.fullyUndone(task) == nil, let a = task.answer, !a.isEmpty, a != summary { Text(a).font(.system(size: 15)).foregroundStyle(Brand.ink).textSelection(.enabled) }
                ResultSection(shell: shell, task: task, session: session)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Computer task: %@", task.raw, lang: lang))
    }

    /// 「执行中 · 第 2 步，共 4 步：写入回复」: where it is, and while it runs its current step in words.
    private var line: String {
        let state = ShellText.task(task, lang: lang)
        guard task.running, let step = task.steps.last, shell.pinned(session)?.runId != task.runId else { return state }
        return L("%@: %@", state, step.displayText, lang: lang)
    }

    /// Where 「跳到卡片」 scrolls to: a card drawn in place in the chat.
    static func cardAnchor(_ card: CardModel) -> String { "card/" + ShellModel.cardKey(card) }
}

/// The result card (its text says what was done, and why it can't be undone when it can't), its buttons — enabled
/// only while its state is open (ShellModel.answerable: TaskState.resultCardState), undo only while offered — and its
/// line: the minutes left (display only), 「撤回中」, what the undo came to, or why it expired.
struct ResultSection: View {
    @ObservedObject var shell: ShellModel
    let task: TaskState
    let session: SessionState
    @Environment(\.lang) private var lang

    var body: some View {
        if let rc = task.resultCard, !rc.options.isEmpty {
            let m = CardModel(resultCard: rc, runId: task.runId)
            VStack(alignment: .leading, spacing: 6) {
                CardView(shell: shell, card: m, phase: .open, askedAt: nil, session: session)
                    .id(ShellModel.cardKey(m))
                // (the countdown refreshes each 30 s; whether undo can be clicked never reads the clock)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    if let line = ShellText.resultLine(task, hint: shell.cards.hint(task.runId), now: shell.now(), lang: lang) {
                        Text(line).font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(line)
                    }
                }
            }
        }
    }
}
