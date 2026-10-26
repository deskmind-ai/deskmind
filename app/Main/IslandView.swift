// The run's status in the notch, on a Mac that has one: a black shape merged with the notch, the "island". Collapsed
// it is the notch with a wing either side -- the status dot and the step on the left, Stop on the right; it drops
// open on hover, while a step waits for the screen, and for a few seconds when the run ends, with the step's line,
// the stage a starting run is in and the buttons. Ended, it keeps ✓ or ! and a word beside the notch, and "Show
// Details" opens the window on the result. On a screen without a notch the capsule under the menu bar stays
// (OverlayView).
//
// And the main window (MainWindow): a run leaves it where the user put it, neither sending it aside nor bringing it
// forward; everything the run shows is here, and "Show Details" or the Dock bring the window forward.

import AppKit
import SwiftUI

struct IslandView: View {
    @ObservedObject var model: OverlayModel
    /// The notch, in this view's own coordinates (points from the top-left of the panel).
    let notch: CGRect
    let onStop: () -> Void
    var onDetails: (UserGesture) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    @State private var hover = false
    /// Opened by a click, for when hover does not reach a panel of an app that is not in front.
    @State private var pinned = false
    @Environment(\.lang) private var lang

    private var open: Bool {
        hover || pinned || model.waiting || model.takenOver || (model.phase == .running && model.asking)
            || (model.phase != .running && model.resultOpen)
    }
    private var collapsedWidth: CGFloat { notch.width + 2 * Island.wing }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                wings.frame(height: notch.height)
                if open { details.transition(.opacity) }
            }
            .frame(width: open ? max(Island.expanded.width, collapsedWidth) : collapsedWidth,
                   height: open ? Island.expanded.height : notch.height, alignment: .top)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: open ? 22 : 12, bottomTrailingRadius: open ? 22 : 12,
                                               style: .continuous).fill(Color(ShellPalette.islandFill)))
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { hover = h } }
            .onTapGesture { withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { pinned.toggle() } }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: open)
        .onChange(of: model.title) { _, _ in pinned = false }   // the panel is kept between runs
        .onChange(of: model.ending) { _, _ in pinned = false }  // a result collapses on its own after a moment
    }

    /// Either side of the notch: the dot and the step, and Stop (or how it ended).
    private var wings: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if let ending = model.ending {
                    Image(systemName: ending == .done ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(ending == .done ? Color(ShellPalette.islandText) : Color(ShellPalette.islandMuted))
                    Text(L(Island.endWord(ending), lang: lang))
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Color(ShellPalette.islandText))
                        .lineLimit(1)
                } else {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                    // Before the first step, the stage and its seconds: a start takes 20-30 s, and "Starting" alone
                    // for all of it read as stuck.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(wingText).font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(ShellPalette.islandText)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
            .frame(width: Island.wing - 12, alignment: .leading).padding(.leading, 12)
            Spacer(minLength: notch.width)
            Group {
                if model.phase == .running {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(ShellPalette.islandText))
                            .frame(width: 20, height: 20).background(Circle().fill(Color(ShellPalette.islandText).opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .help(L("Stop this task (or press ⌘. in the DeskMind window)", lang: lang))
                    .accessibilityLabel(L("Stop", lang: lang))
                } else {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(ShellPalette.islandText))
                            .frame(width: 20, height: 20).background(Circle().fill(Color(ShellPalette.islandText).opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .help(L("Dismiss", lang: lang))
                    .accessibilityLabel(L("Dismiss", lang: lang))
                }
            }
            .frame(width: Island.wing - 12, alignment: .trailing).padding(.trailing, 12)
        }
    }

    private var wingText: String {
        if model.step > 0 { return L("Step %d", model.step, lang: lang) }
        guard let stage = model.stage else { return L("Starting", lang: lang) }
        return stage.wing(seconds: Int(Date().timeIntervalSince(model.stageSince)), lang: lang)
    }

    /// The Island board's dot: orange while it works and when a card needs you, grey while it gets ready, while it waits
    /// for you to stop using the Mac and when it didn't finish, white when done (the palette's own: no yellow, no green).
    private var dotColor: Color {
        switch model.phase {
        case .running: !model.asking && (model.waiting || (model.step == 0 && model.stage != nil)) ? Color(ShellPalette.islandMuted) : Brand.dot
        case .passed: Color(ShellPalette.islandText)
        case .failed: Color(ShellPalette.islandMuted)
        }
    }

    /// Open: the task, what is happening now (or the stage a starting run is in), and the buttons.
    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.title).font(.system(size: 11)).foregroundStyle(Color(ShellPalette.islandText).opacity(0.55)).lineLimit(1)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(currentLine).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Color(ShellPalette.islandText))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if model.phase == .running && (model.waiting || model.takenOver) { shareButtons }
                Spacer()
                if model.phase == .running {
                    // a card waits in the window: the way to it, besides the Dock and the notification
                    if model.asking { pill(L("Open DeskMind", lang: lang), prominent: true, action: Activation.onClick { RunOverlay.shared.openWindow($0) }) }
                    pill(L("Stop", lang: lang), prominent: !model.asking, action: onStop)
                } else {
                    pill(L("Dismiss", lang: lang), action: onDismiss)
                    pill(L("Show Details", lang: lang), prominent: true, action: Activation.onClick(onDetails))
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 12)
    }

    private var currentLine: String {
        if model.phase == .running, let s = ScreenShareButtons.status(model, lang: lang) { return s }
        if model.phase == .running, model.step == 0, let stage = model.stage {
            return stage.line(seconds: Int(Date().timeIntervalSince(model.stageSince)), typical: model.typical, lang: lang)
        }
        return model.line
    }

    /// The same choices as ScreenShareButtons, drawn for the black island.
    @ViewBuilder private var shareButtons: some View {
        if model.takenOver {
            pill(L("I need it back", lang: lang)) { RunOverlay.shared.holdOff() }
        } else if model.holdUntil != nil {
            pill(L("Go ahead now", lang: lang)) { RunOverlay.shared.takeOver(seconds: 300) }
        } else {
            pill(L("I'm using it · 5 min", lang: lang)) { RunOverlay.shared.holdOff() }
            pill(L("Go ahead now", lang: lang)) { RunOverlay.shared.takeOver(seconds: 300) }
        }
    }

    private func pill(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 11).padding(.vertical, 5)
                .foregroundStyle(prominent ? Color(ShellPalette.islandFill) : Color(ShellPalette.islandText))
                .background(Capsule().fill(prominent ? Color(ShellPalette.islandText) : Color(ShellPalette.islandText).opacity(0.16)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// DeskMind's own window. A run never moves it (M1 S0: it was sent aside at Start and after an answer, and brought
/// forward for a question and at the end, taking the user's focus); only the user brings it forward: the island's
/// "Show Details" and "Open DeskMind", the Dock icon, a click on the live card or a notification (those reopen the app).
@MainActor
enum MainWindow {
    /// The app's one document-style window (not a panel: the island, the decision panel), minimised or not.
    static var window: NSWindow? {
        NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain && $0.contentView != nil }
    }

    /// A key was pressed in the last `seconds`, in any app (the HID system's own count; no keys are read).
    static func userTypedRecently(_ seconds: Double = 2) -> Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) < seconds
    }

    /// The window's state for the UI log (UIEvent.Window): in front (the app active, the window key), behind,
    /// minimised, hidden (the app is), or closed (none, or not on screen).
    static func uiState() -> UIEvent.Window {
        guard let w = window else { return .closed }
        if NSApp.isHidden { return .hidden }
        if w.isMiniaturized { return .minimized }
        if !w.isVisible { return .closed }
        return NSApp.isActive && w.isKeyWindow ? .front : .behind
    }

    /// Restored if minimised, in front, as the key window: only for something the user did (the island's buttons, a
    /// reopen). False when there is no window.
    @discardableResult
    static func comeBack(_ gesture: UserGesture) -> Bool {
        guard let w = window else { return false }
        Activation.bringForward(gesture, window: w)
        return true
    }
}

/// The UI log's `activation` (Shared/UIEvents.swift): each time the app becomes active, the funnel's call behind it
/// (Activation.bringForward, with its gesture), or none -- what it was is not guessed (#123 review at 20e66ab: the
/// HID idle counter also counts the events a task posts). The reopens are put down as they come (reopenAsked), and with
/// each activation the type of the event AppKit was handling then (a click on the window, ⌘Tab's key: the user's).
enum ActivationRecorder {
    nonisolated(unsafe) private static var funnel: (by: UIEvent.Activation, at: Double)?
    nonisolated(unsafe) private static var token: NSObjectProtocol?

    /// The event being handled as the app became active, by its type (its window: one of DeskMind's or not).
    static func input(_ e: NSEvent?) -> UIEvent.Input {
        guard let e else { return .none }
        switch e.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return e.window != nil ? .mouseDownInWindow : .mouseDown
        case .keyDown: return .keyDown
        case .appKitDefined: return .appKitDefined
        default: return .other
        }
    }

    static func start() {
        guard token == nil else { return }
        Activation.onBringForward = { source in funnel = (source == .click ? .button : .reopen, Date().timeIntervalSince1970) }
        token = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            UIEvents.record(.activation(by: UIEvents.activation(funnel: funnel, now: Date().timeIntervalSince1970), input: input(NSApp.currentEvent)))
            funnel = nil
        }
    }
}

/// A reopen -- a click on the Dock icon, on the live card or on a notification (they open the app again) -- is the
/// user asking for the window; but hands also gives the front back with `open -b` after a foreground step, which is a
/// reopen too and cannot be told apart. With a window on screen, macOS brings it forward and nothing more is done.
/// With none on screen (minimised): restored -- while a run is running, only when a card waits (hands is blocked on
/// the user then and takes no steps); with none at all, SwiftUI opens one on the same terms.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Quitting mid-recording: the helper is told to stop and finish the movie (it does, on its own, after the app is
    /// gone). Left recording, it refused the next run's recording.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let run = RunRecorder.shared.run else { return }      // (the helper also stops it at the run's end)
            _ = DeskMindIPC.request(["op": "record_stop", "for_run": run], timeout: 1)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            UIEvents.record(.reopenAsked)
            if flag { return true }
            // While a run is running and no card waits, a reopen is most likely hands giving the front back after a
            // foreground step (`open -b ai.deskmind.app`, DeskMind still the active app after ⌘M): restoring the
            // window then would put it over the app being driven, after every step. Nothing is done; the island is
            // the way in. With a card waiting, hands is blocked on the user and takes no steps: it is the user.
            // (handoff §3.1: a session's task running, no card waiting -- Activation.reopenRestores)
            guard Activation.reopenRestores(shellTaskWithoutCard: ShellModel.shared?.taskRunningWithoutCard == true) else { return false }
            if MainWindow.comeBack(Activation.reopen(sender)) { return false }
            return true
        }
    }
}
