// While a chat task runs, the agent works in other apps' windows in the background, and the user may be looking at
// something else entirely. The bar at the top of the screen (the Island board) says what is happening -- the app and
// the step, that it needs you, that it waits for you to stop using the Mac -- in one strip at the notch (a capsule
// under the menu bar on a screen without one). It never takes focus and ignores Spaces; a click on it is the user's
// way to the task (IslandView). When the task ends the bar says how; a done task's bar goes after a few seconds, one
// that didn't finish or was stopped stays until clicked (its why is to be read) -- and if DeskMind is not in front a
// notification says it as well.

import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class OverlayModel: ObservableObject {
    enum Phase { case running, passed, failed }
    @Published var phase: Phase = .running
    @Published var step = 0
    @Published var line = ""   // set by show()
    @Published var title = ""
    /// The bar as the task's state has it now (IslandFeed.frame): its kind and words.
    @Published var frame: IslandFrame?
    /// How the run ended, once it has (see finish()).
    @Published var ending: Island.Ending?
    /// Stop was pressed: the run's end is "stopped", not a failure.
    var stoppedByUser = false
    /// A card waits for the user in DeskMind's window.
    @Published var asking = false
}

@MainActor
final class RunOverlay {
    static let shared = RunOverlay()
    let model = OverlayModel()
    private var panel: NSPanel?
    /// The notch the panel was laid out around, or nil for the capsule: a run on another screen lays it out again.
    private var laidOutFor: CGRect??
    var onStop: (() -> Void)?
    /// A click on the bar while the task runs (the float, or the window on the task: ChatIslandSurface).
    var onTap: ((UserGesture) -> Void)?
    /// Which run the panel shows: the timers of one run's result leave the next run alone.
    private var generation = 0

    func show(title: String, line: String? = nil) {
        onDetails = nil
        model.phase = .running; model.step = 0; model.frame = nil
        model.ending = nil; model.stoppedByUser = false
        generation += 1
        model.line = line ?? ""; model.title = title
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
            // (the panel as wide as the bar gets -- needing you -- and the bar centred in it: what is clear lets
            // clicks through, so the width changes without moving the panel)
            p.setFrame(Island.barFrame(notch: notch, screen: screen.frame, visible: screen.visibleFrame, needsYou: true), display: true)
            Activation.showPanel(p)
        }
    }

    /// Its own panel, outside the window: LocalizedRoot gives it the language setting (and any switch).
    private func makePanel(notch: CGRect?) -> NSPanel {
        let host = NSHostingView(rootView: LocalizedRoot {
            IslandView(model: model, height: notch?.height ?? Island.barHeight, notched: notch != nil,
                       onStop: { [weak self] in self?.onStop?() }, onTap: { [weak self] g in self?.tapped(g) })
        })
        host.frame = NSRect(x: 0, y: 0, width: Island.barWideWidth, height: notch?.height ?? Island.barHeight)
        let p = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false; p.backgroundColor = .clear
        // Above the menu bar at the notch (it is part of it); under it, with the status bar's windows, elsewhere.
        p.level = notch == nil ? .statusBar : NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        return p
    }

    /// The task's state now, as the bar draws it.
    func apply(_ f: IslandFrame) {
        withAnimation(.easeOut(duration: 0.35)) { model.frame = f }
        model.step = f.step
        model.line = f.line
    }

    /// `notify`: post the result's notification when DeskMind is not active (a chat task's is CardNotices', by id).
    func finish(passed: Bool, summary: String, notify: Bool = true) {
        model.phase = passed ? .passed : .failed
        model.ending = model.stoppedByUser ? .stopped : (passed ? .done : .failed)
        model.line = summary
        // DeskMind is not the active app (the task worked in others): the notification is the result's way in then.
        if notify && !NSApp.isActive {
            let lang = ResolvedLang.current
            Self.notify(title: passed ? L("DeskMind finished the task", lang: lang) : L("DeskMind couldn't finish the task", lang: lang),
                        body: L("%@: %@", model.title, summary, lang: lang))
        }
        // done: a few seconds; didn't finish or stopped: until clicked, or a while
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + (passed ? Island.resultOpenSeconds : Island.resultLingerSeconds)) { [weak self] in
            guard let self, self.generation == g, self.model.phase != .running else { return }
            self.panel?.orderOut(nil)
        }
    }

    func hide() { panel?.orderOut(nil) }

    /// A finished run's bar, put away.
    func dismiss() {
        guard model.phase != .running else { return }
        generation += 1
        panel?.orderOut(nil)
    }

    /// A click on the bar: while the task runs, the way to it (onTap); ended, the window on its result, and the bar
    /// goes.
    func tapped(_ g: UserGesture) {
        if model.phase == .running, let onTap { onTap(g); return }
        dismiss()
        MainWindow.comeBack(g)
        onDetails?()
    }

    /// What a click on an ended task's bar does past bringing the window back: the task's conversation selected.
    var onDetails: (() -> Void)?

    /// A card waits in the window (or not any more).
    func setAsking(_ on: Bool) {
        guard model.asking != on else { return }
        model.asking = on
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
