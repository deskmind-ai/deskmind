// The task's bar at the notch (the Island board), on a Mac that has one: a black strip merged with the notch, as tall
// as it, 380 wide (460 while it needs you); on a screen without a notch the same bar as a capsule under the menu bar.
// Left, a dot -- or 小方 looking up, while a card waits -- and what is going on; right, the step and its time, what it
// waits for, or how it ended (IslandFeed.frame: the words are the feed's, this only draws them). The whole bar is one
// click: the user's way to the task (RunOverlay.tapped). Hovered while the task runs, its right side gives way to Stop.
//
// And the main window (MainWindow): a run leaves it where the user put it, neither sending it aside nor bringing it
// forward; a click on the bar, a notification or the Dock bring the window forward.

import AppKit
import SwiftUI

struct IslandView: View {
    @ObservedObject var model: OverlayModel
    /// The bar's height: the notch's (or the capsule's, with none).
    let height: CGFloat
    let notched: Bool
    let onStop: () -> Void
    let onTap: (UserGesture) -> Void
    /// The clock the step's time is counted on (the offscreen render gives its own).
    var now: () -> Double = { Date().timeIntervalSince1970 }
    @State private var hover = false
    @State private var breathe = false
    @Environment(\.lang) private var lang
    @Environment(\.accessibilityReduceMotion) private var reduce

    private var kind: IslandFrame.Kind { model.frame?.kind ?? .preparing }
    private var running: Bool { model.phase == .running }

    var body: some View {
        let wide = kind == .needsYou
        Button(action: Activation.onClick { g in onTap(g) }) {
            HStack(spacing: 8) {
                lead
                Text(model.frame?.left ?? "").font(.system(size: 13, weight: kind == .needsYou || !running ? .semibold : .regular))
                    .foregroundStyle(kind == .needsYou ? Color(ShellPalette.onInkOrange) : Color(ShellPalette.islandText)).lineLimit(1)
                Spacer(minLength: 84)
                ZStack(alignment: .trailing) {
                    right.opacity(hover && running ? 0 : 1)
                    if running {
                        Button(action: onStop) {
                            Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(ShellPalette.islandText))
                                .frame(width: 20, height: 20).background(Circle().fill(Color(ShellPalette.islandText).opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                        .opacity(hover ? 1 : 0)
                        .help(L("Stop this task (or press ⌘. in the DeskMind window)", lang: lang))
                        .accessibilityLabel(L("Stop", lang: lang))     // (in the tree whether shown or not)
                    }
                }
                .animation(reduce ? nil : .easeOut(duration: 0.15), value: hover)
            }
            .padding(.horizontal, 16)
            .frame(width: wide ? Island.barWideWidth : Island.barWidth, height: height)
            .background(shape.fill(Color(ShellPalette.islandFill)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(reduce ? nil : .easeOut(duration: 0.35), value: wide)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("%@ · %@", model.frame?.left ?? "", rightText, lang: lang))
        .onAppear { breathe = true }
    }

    private var shape: AnyShape {
        notched ? AnyShape(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18, style: .continuous))
                : AnyShape(Capsule())
    }

    /// The dot (orange, breathing, while it works; grey preparing, paused, didn't finish or stopped; the text's colour
    /// when done) -- or, while it needs you, 小方 looking up in its place.
    @ViewBuilder private var lead: some View {
        let color: Color = switch kind {
        case .working, .needsYou: Brand.dot
        case .done: Color(ShellPalette.islandText)
        case .preparing, .paused, .failed, .stopped: Color(ShellPalette.islandGrey)
        }
        let period: Double? = kind == .working ? 1.6 : kind == .needsYou ? 0.8 : nil
        if kind == .needsYou {
            XiaoFace(eyes: .up, size: 20, onInk: true)
        } else {
        Circle().fill(color).frame(width: 8, height: 8)
            .overlay(Circle().stroke(Brand.dot.opacity(kind == .needsYou ? 0.35 : 0), lineWidth: 4))
            .scaleEffect(period != nil && breathe && !reduce ? 1.25 : 1)
            .opacity(period != nil && breathe && !reduce ? 0.7 : 1)
            .animation(period.map { reduce ? nil : .easeInOut(duration: $0 / 2).repeatForever(autoreverses: true) } ?? nil, value: breathe)
            .accessibilityHidden(true)
        }
    }

    /// The right side: the feed's words, or -- working, preparing -- the time, counted here each second.
    private var right: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(rightText).font(.system(size: 13).monospacedDigit()).foregroundStyle(Color(ShellPalette.islandMuted)).lineLimit(1)
        }
    }

    private var rightText: String {
        guard let f = model.frame else { return "" }
        let secs = f.startedAt.map { max(0, Int(now() - $0)) }
        switch f.kind {
        case .working: return L("Step %d · %@", f.step, String(format: "%d:%02d", (secs ?? 0) / 60, (secs ?? 0) % 60), lang: lang)
        case .preparing: return secs.map { L("%d s", $0, lang: lang) } ?? ""
        default: return f.right
        }
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
