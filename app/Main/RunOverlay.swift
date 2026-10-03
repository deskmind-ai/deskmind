// While a real task runs, the agent works in other apps' windows in the background, and the user may be looking at
// something else entirely. The status at the top of the screen says what is happening -- which app, which step, in
// words -- and has a Stop button; it stays out of the way (never takes focus, ignores Spaces). On a Mac with a notch it
// is the island around the notch (IslandView); elsewhere a small floating capsule under the menu bar (OverlayView).
// When the run ends the result is in it too -- open a few seconds, then collapsed to ✓ or ! beside the notch, with
// "Show Details" for the window (which no longer comes back by itself) -- and if DeskMind is not in front a
// notification says it as well.

import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class OverlayModel: ObservableObject {
    enum Phase { case running, passed, failed }
    @Published var phase: Phase = .running
    @Published var app = ""
    @Published var step = 0
    @Published var line = ""   // set by show()
    @Published var title = ""
    /// A step needs the front and the user is using the Mac: the task waits for them (see HANDS_WAIT).
    @Published var waiting = false
    /// The user has handed the screen over for a while: the task does not wait (see Runner.takeOver).
    @Published var takenOver = false
    /// Seconds before the screen is handed over on its own, while a step waits and the user has not said no.
    @Published var countdown: Int? = nil
    /// The user said they are using the Mac: the task waits for them until then.
    @Published var holdUntil: Date? = nil
    /// What the waiting step will do.
    @Published var what = ""
    /// Before the first step: what the run is doing, since when, and how long that took last time (see RunStage).
    @Published var stage: RunStage?
    @Published var stageSince = Date()
    @Published var typical: Int?
    /// How the run ended, once it has (see finish()).
    @Published var ending: Island.Ending?
    /// The result is shown open (for a few seconds after the end); then it collapses to the notch.
    @Published var resultOpen = false
    /// Stop was pressed: the run's end is "stopped", not a failure.
    var stoppedByUser = false
}

@MainActor
final class RunOverlay {
    static let shared = RunOverlay()
    let model = OverlayModel()
    private var panel: NSPanel?
    /// The notch the panel was laid out around, or nil for the capsule: a run on another screen lays it out again.
    private var laidOutFor: CGRect??
    var onStop: (() -> Void)?
    /// Which run the panel shows: the timers of one run's result leave the next run alone.
    private var generation = 0

    func setStage(_ s: RunStage?, since: Date, typical: Int?) {
        model.stage = s; model.stageSince = since; model.typical = typical
    }

    /// Hand the mouse and the front to the running task for `seconds` (0 gives them back).
    func takeOver(seconds: Double) {
        _ = DeskMindIPC.request(["op": "takeover", "seconds": seconds])
        withAnimation(.easeOut(duration: 0.2)) { model.takenOver = seconds > 0; if seconds > 0 { model.waiting = false } }
        if seconds > 0 { stopCountdown(); model.holdUntil = nil }
    }

    /// A step needs the screen and the user is using it. By default DeskMind takes it after a short countdown
    /// (the user asked for the task, and a run that waited silently read as frozen); "I'm using it" holds it off
    /// for 5 minutes, after which the countdown starts again if the step is still waiting.
    static let countdownSeconds = 10
    private var ticker: Timer?

    func setWaiting(_ on: Bool, what: String = "") {
        withAnimation(.easeOut(duration: 0.2)) {
            model.waiting = on && !model.takenOver
            if on && !what.isEmpty { model.what = what; model.line = L("Next: %@", what, lang: ResolvedLang.current) }
        }
        if on && !model.takenOver { startCountdownUnlessHeld() } else { stopCountdown() }
    }

    private func startCountdownUnlessHeld() {
        if let hold = model.holdUntil, hold > Date() { return }
        model.holdUntil = nil
        model.countdown = Self.countdownSeconds
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        if let hold = model.holdUntil {
            // Held by the user: when the time is up and the step still waits, count down again.
            if hold <= Date() { model.holdUntil = nil; if model.waiting { model.countdown = Self.countdownSeconds } }
            return
        }
        guard let c = model.countdown else { ticker?.invalidate(); ticker = nil; return }
        if c <= 1 { model.countdown = nil; ticker?.invalidate(); ticker = nil; takeOver(seconds: 300) }
        else { model.countdown = c - 1 }
    }

    private func stopCountdown() {
        ticker?.invalidate(); ticker = nil; model.countdown = nil
    }

    /// "I'm using it": the task waits for the user for 5 minutes (and gives the screen back if it had it).
    func holdOff(minutes: Double = 5) {
        if model.takenOver { takeOver(seconds: 0) }
        model.countdown = nil
        model.holdUntil = Date().addingTimeInterval(minutes * 60)
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func show(title: String, line: String? = nil) {
        model.phase = .running; model.app = ""; model.step = 0; model.waiting = false; model.takenOver = false
        model.ending = nil; model.resultOpen = false; model.stoppedByUser = false
        generation += 1
        model.holdUntil = nil; stopCountdown()
        model.line = line ?? L("Preparing the sandbox…", lang: ResolvedLang.current); model.title = title
        let screen = NSScreen.main ?? NSScreen.screens.first
        let notch = screen.flatMap { sc in
            Island.notch(screen: sc.frame, safeTop: sc.safeAreaInsets.top, left: sc.auxiliaryTopLeftArea,
                         right: sc.auxiliaryTopRightArea)
        }
        if panel == nil || laidOutFor != .some(notch) {
            panel?.orderOut(nil)
            panel = makePanel(notch: notch)
            laidOutFor = .some(notch)
        }
        if let p = panel, let screen {
            let f = notch.map { Island.expandedFrame(notch: $0, screen: screen.frame) }
                ?? Island.pillFrame(visible: screen.visibleFrame, size: CGSize(width: 560, height: 64))
            p.setFrame(f, display: true)
            p.orderFrontRegardless()
        }
    }

    /// Its own panel, outside the window: LocalizedRoot gives it the language setting (and any switch). The island
    /// sits over the menu bar, in a panel the size of its open state; what is transparent lets clicks through.
    private func makePanel(notch: CGRect?) -> NSPanel {
        let stop: () -> Void = { [weak self] in self?.onStop?() }
        let host: NSView
        if let notch {
            host = NSHostingView(rootView: LocalizedRoot {
                IslandView(model: model, notch: CGRect(origin: .zero, size: notch.size), onStop: stop,
                           onDetails: { [weak self] in self?.showDetails() }, onDismiss: { [weak self] in self?.dismiss() })
            })
        } else {
            host = NSHostingView(rootView: LocalizedRoot {
                OverlayView(model: model, onStop: stop, onTakeOver: { [weak self] secs in self?.takeOver(seconds: secs) },
                            onDetails: { [weak self] in self?.showDetails() }, onDismiss: { [weak self] in self?.dismiss() })
            })
        }
        let size = notch == nil ? NSSize(width: 560, height: 64) : NSSize(width: Island.expanded.width, height: Island.expanded.height)
        host.frame = NSRect(origin: .zero, size: size)
        let p = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false; p.backgroundColor = .clear
        // Above the menu bar for the island (it is part of it); the capsule floats like before and can be moved.
        p.level = notch == nil ? .statusBar : NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.hasShadow = notch == nil
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isMovableByWindowBackground = notch == nil
        p.hidesOnDeactivate = false
        return p
    }

    func update(app: String, step: Int, line: String) {
        if !app.isEmpty { model.app = app }
        model.step = step
        withAnimation(.easeOut(duration: 0.2)) { model.line = line }
    }

    /// A line with no step: waiting for the user's answer, carrying on after it.
    func say(_ line: String) {
        withAnimation(.easeOut(duration: 0.2)) { model.line = line }
    }

    func finish(passed: Bool, summary: String) {
        if model.takenOver { takeOver(seconds: 0) }   // the screen is the user's again when the task ends
        model.waiting = false; model.holdUntil = nil; stopCountdown()
        model.phase = passed ? .passed : .failed
        model.ending = model.stoppedByUser ? .stopped : (passed ? .done : .failed)
        model.line = summary
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { model.resultOpen = true }
        if !NSApp.isActive {
            let lang = ResolvedLang.current
            Self.notify(title: passed ? L("DeskMind finished the task", lang: lang) : L("DeskMind couldn't finish the task", lang: lang),
                        body: L("%@: %@", model.title, summary, lang: lang))
        }
        // Open for a moment, then only ✓ or ! beside the notch; gone after a while if nobody looks.
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Island.resultOpenSeconds) { [weak self] in
            guard let self, self.generation == g else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { self.model.resultOpen = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Island.resultLingerSeconds) { [weak self] in
            guard let self, self.generation == g, self.model.phase != .running else { return }
            self.panel?.orderOut(nil)
        }
    }

    func hide() { panel?.orderOut(nil) }

    /// The finished run's result, put away (×).
    func dismiss() {
        guard model.phase != .running else { return }
        generation += 1
        panel?.orderOut(nil)
    }

    /// "Show Details": the window, on this run's result, in front; the result leaves the notch.
    func showDetails() {
        dismiss()
        MainWindow.comeBack(activate: true)
    }

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c,
                                                                     trigger: nil))
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    let onStop: () -> Void
    let onTakeOver: (Double) -> Void
    var onDetails: () -> Void = {}
    var onDismiss: () -> Void = {}
    @Environment(\.lang) private var lang

    var body: some View {
        HStack(spacing: 12) {
            XiaoFang(mood: model.phase == .running ? .idle : (model.phase == .passed ? .done : .notice), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if model.phase == .running {
                        Circle().fill(Brand.dot).frame(width: 7, height: 7)
                        Text(model.waiting ? L("DeskMind needs the screen for a moment", lang: lang)
                             : (model.app.isEmpty ? L("DeskMind is getting ready", lang: lang)
                                                  : L("DeskMind is working in %@", model.app, lang: lang)))
                    } else {
                        Text(L(Island.endWord(model.ending ?? (model.phase == .passed ? .done : .failed)), lang: lang))
                    }
                    if model.step > 0 { Text(L("· Step %d", model.step, lang: lang)).foregroundStyle(Brand.sage) }
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Brand.ink)
                Text(ScreenShareButtons.status(model, lang: lang) ?? model.line)
                    .font(.system(size: 12)).foregroundStyle(model.waiting || model.takenOver ? Brand.dot : Brand.sage)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.phase == .running && (model.waiting || model.takenOver) {
                ScreenShareButtons(model: model, compact: true)
            }
            if model.phase == .running {
                Button(action: onStop) {
                    Text(L("Stop", lang: lang)).font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .foregroundStyle(Brand.paper).background(Capsule().fill(Brand.ink))
                }
                .buttonStyle(.plain)
                .help(L("Stop this task (or press ⌘. in the DeskMind window)", lang: lang))
            } else {
                Button(action: onDetails) {
                    Text(L("Show Details", lang: lang)).font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .foregroundStyle(Brand.paper).background(Capsule().fill(Brand.ink))
                }
                .buttonStyle(.plain)
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Brand.sage)
                }
                .buttonStyle(.plain)
                .help(L("Dismiss", lang: lang))
                .accessibilityLabel(L("Dismiss", lang: lang))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(width: 560, height: 64)
        .background(Capsule(style: .continuous).fill(Brand.paper))
        .overlay(Capsule(style: .continuous).strokeBorder(Brand.line, lineWidth: 1))
    }
}

/// The choice while a step needs the screen: let it go ahead now, or keep the Mac for 5 minutes; and, while it has
/// the screen, take it back. Shared by the floating capsule and the run window.
struct ScreenShareButtons: View {
    @ObservedObject var model: OverlayModel
    var compact = false
    @Environment(\.lang) private var lang

    /// One line saying where things stand, or nil when nothing is being negotiated.
    static func status(_ m: OverlayModel, lang: ResolvedLang) -> String? {
        if m.takenOver { return L("Using your mouse and screen for now", lang: lang) }
        guard m.waiting else { return nil }
        if let hold = m.holdUntil, hold > Date() {
            return L("Waiting until you're done (until %@)", hold.formatted(date: .omitted, time: .shortened), lang: lang)
        }
        if let c = m.countdown { return L("Taking the screen in %d s", c, lang: lang) }
        return L("Waiting for a still mouse", lang: lang)
    }

    var body: some View {
        HStack(spacing: 6) {
            if model.takenOver {
                pill(L("I need it back", lang: lang)) { RunOverlay.shared.holdOff() }
            } else if model.holdUntil != nil {
                pill(L("Go ahead now", lang: lang)) { RunOverlay.shared.takeOver(seconds: 300) }
            } else {
                pill(L("I'm using it · 5 min", lang: lang)) { RunOverlay.shared.holdOff() }
                if !compact { pill(L("Go ahead now", lang: lang), prominent: true) { RunOverlay.shared.takeOver(seconds: 300) } }
            }
        }
    }

    private func pill(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: compact ? 11 : 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, compact ? 9 : 12).padding(.vertical, 5)
                .foregroundStyle(prominent ? Brand.paper : Brand.ink)
                .background(Capsule().fill(prominent ? Brand.ink : Color.clear))
                .overlay(Capsule().strokeBorder(Brand.ink, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }
}
