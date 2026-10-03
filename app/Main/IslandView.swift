// The run's status in the notch, on a Mac that has one: a black shape merged with the notch, the "island". Collapsed
// it is the notch with a wing either side -- the status dot and the step on the left, Stop on the right; it drops
// open on hover, while a step waits for the screen, and for a few seconds when the run ends, with the step's line,
// the stage a starting run is in and the buttons. Ended, it keeps ✓ or ! and a word beside the notch, and "Show
// Details" opens the window on the result. On a screen without a notch the capsule under the menu bar stays
// (OverlayView).
//
// And the main window stepping aside for the whole run (MainWindow): it covered the very app being driven, and
// everything the run shows is here. It comes back for a question, for "Show Details", or from the Dock.

import AppKit
import SwiftUI

struct IslandView: View {
    @ObservedObject var model: OverlayModel
    /// The notch, in this view's own coordinates (points from the top-left of the panel).
    let notch: CGRect
    let onStop: () -> Void
    var onDetails: () -> Void = {}
    var onDismiss: () -> Void = {}
    @State private var hover = false
    /// Opened by a click, for when hover does not reach a panel of an app that is not in front.
    @State private var pinned = false
    @Environment(\.lang) private var lang

    private var open: Bool {
        hover || pinned || model.waiting || model.takenOver || (model.phase != .running && model.resultOpen)
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
                                               style: .continuous).fill(Color.black))
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
                        .font(.system(size: 12)).foregroundStyle(ending == .done ? Color.green : Brand.dot)
                    Text(L(Island.endWord(ending), lang: lang))
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                        .lineLimit(1)
                } else {
                    Circle().fill(dotColor).frame(width: 7, height: 7)
                    // Before the first step, the stage and its seconds: a start takes 20-30 s, and "Starting" alone
                    // for all of it read as stuck.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(wingText).font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
            .frame(width: Island.wing - 12, alignment: .leading).padding(.leading, 12)
            Spacer(minLength: notch.width)
            Group {
                if model.phase == .running {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 20, height: 20).background(Circle().fill(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .help(L("Stop this task (or press ⌘. in the DeskMind window)", lang: lang))
                    .accessibilityLabel(L("Stop", lang: lang))
                } else {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 20, height: 20).background(Circle().fill(Color.white.opacity(0.18)))
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

    private var dotColor: Color {
        switch model.phase {
        case .running: model.waiting || model.takenOver ? Color.yellow : Brand.dot
        case .passed: Color.green
        case .failed: Brand.dot
        }
    }

    /// Open: the task, what is happening now (or the stage a starting run is in), and the buttons.
    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(currentLine).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if model.phase == .running && (model.waiting || model.takenOver) { shareButtons }
                Spacer()
                if model.phase == .running {
                    pill(L("Stop", lang: lang), prominent: true, action: onStop)
                } else {
                    pill(L("Dismiss", lang: lang), action: onDismiss)
                    pill(L("Show Details", lang: lang), prominent: true, action: onDetails)
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
                .foregroundStyle(prominent ? Color.black : Color.white)
                .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.16)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// DeskMind's own window, out of the way while a run works in other apps' windows, and back when the user asks for
/// it (the island's "Show Details", the Dock icon) or the run needs them (a question). Off with View ▸ "Keep DeskMind
/// Open While a Task Runs".
@MainActor
enum MainWindow {
    static let keepOpenKey = "run.keepWindowOpen"
    private static var aside: [NSWindow] = []

    /// The app's one document-style window (not a panel: the island, the decision panel).
    static var window: NSWindow? {
        NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain && $0.contentView != nil }
    }

    static var isAside: Bool { !aside.isEmpty }

    /// Out of the way now -- and again a moment later: Start is pressed on the confirmation sheet, and the sheet going
    /// away brought the window back in front, so it stayed in the middle of the screen while the run started.
    static func stepAside() {
        guard !UserDefaults.standard.bool(forKey: keepOpenKey) else { return }
        for w in NSApp.windows where !(w is NSPanel) && w.canBecomeMain && w.isVisible && !aside.contains(w) {
            aside.append(w)
        }
        aside.forEach { $0.orderOut(nil) }
        for delay in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                for w in aside where w.isVisible { w.orderOut(nil) }
            }
        }
    }

    /// Back where it was. `activate` when the user has something to do there (a question, the details); otherwise
    /// it is only brought in front, and the app the user is in keeps the keyboard.
    static func comeBack(activate: Bool = false) {
        let windows = aside.isEmpty ? [window].compactMap { $0 } : aside
        aside = []
        if activate { NSApp.activate() }
        for w in windows { if activate { w.makeKeyAndOrderFront(nil) } else { w.orderFrontRegardless() } }
    }
}

/// A click on the Dock icon while the window is aside brings that window back: left to SwiftUI, it opened a second
/// one, a fresh home screen beside the run.
///
/// Not while a run is running: hands gives the front back to the app that had it after every step it takes in
/// another app, with `open -b`, and to a running app that is a reopen -- DeskMind's own, since Start was pressed
/// here. Each step brought the window back over the app being worked in. The island is the way in meanwhile;
/// questions bring the window back themselves.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Quitting mid-recording: the helper is told to stop and finish the movie (it does, on its own, after the app is
    /// gone). Left recording, it refused the next run's recording.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard RunRecorder.shared.isRecording else { return }
            _ = DeskMindIPC.request(["op": "record_stop"], timeout: 1)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if RunModel.shared?.phase == .running && MainWindow.isAside { return false }
            guard MainWindow.isAside else { return true }
            MainWindow.comeBack(activate: true)
            return false
        }
    }
}
