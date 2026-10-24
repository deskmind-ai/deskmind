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
    @Environment(\.lang) private var lang

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "macwindow").foregroundStyle(Brand.ink).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.raw.isEmpty ? L("Computer task", lang: lang) : task.raw)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.ink).lineLimit(3)
                    if let o = ShellText.origin(task, lang: lang) {
                        Text(o).font(.system(size: 11)).foregroundStyle(ShellColor.secondary)
                    }
                    Text(ShellText.task(task, lang: lang)).font(.system(size: 12)).foregroundStyle(task.running ? ShellColor.orangeText : ShellColor.secondary)
                }
                Spacer()
                if task.running {
                    Button(L("Stop", lang: lang)) { shell.stop() }
                        .buttonStyle(InkButtonStyle(prominent: false))
                        .disabled(task.stopping)
                        .accessibilityLabel(L("Stop", lang: lang))
                        .accessibilityHint(L("Stops the computer task", lang: lang))
                }
            }
            if task.running, let step = task.steps.last {
                Text(step.displayText).font(.system(size: 12)).foregroundStyle(ShellColor.secondary).lineLimit(2)
                    .accessibilityLabel(L("Current step: %@", step.displayText, lang: lang))
            }
            // (the pinned card is above the composer; the rest are a line each, in their phase)
            ForEach(task.cards.filter { $0.askId != shell.pinned(session)?.card.askId }, id: \.askId) { c in
                Text(ShellText.cardLine(shell.phase(task.runId, c, in: session), kind: c.card.kind, lang: lang))
                    .font(.system(size: 11)).foregroundStyle(ShellColor.secondary).lineLimit(2)
            }
            if !task.running {
                let summary = task.done?.summary ?? task.end?.summary ?? ""
                if !summary.isEmpty { Text(summary).font(.system(size: 13)).foregroundStyle(Brand.ink).textSelection(.enabled) }
                if let a = task.answer, !a.isEmpty, a != summary { Text(a).font(.system(size: 13)).foregroundStyle(Brand.ink).textSelection(.enabled) }
                ResultSection(shell: shell, task: task, session: session)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(task.running ? Brand.dot.opacity(0.6) : Brand.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Computer task: %@", task.raw, lang: lang))
    }
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
                CardView(shell: shell, card: m, phase: .open, askedAt: nil, session: session, bodyCap: CardBody.maxHeight)
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
