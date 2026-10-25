// The one way DeskMind may come to the front (and the one way it opens apps in the background). The rule: no app
// activation, ever, unless the user directly acted on DeskMind — a click on one of its own buttons or its live card,
// the Dock icon, a notification (which reopens the app). It is a type guarantee, not a convention:
//
// - Everything that brings a window or an app forward takes a `UserGesture` (Activation.bringForward, openApp, and
//   so MainWindow.comeBack, RunOverlay.openWindow / showDetails, LiveCard's click). Its initialiser is fileprivate:
//   only this file makes one, through a factory tied to a user-event handler — `onClick` wraps a button's action,
//   `mouseUp` takes the AppKit mouse-up being delivered now, `reopen` is the app delegate's reopen. Code that is not
//   a handler (a card arriving, a status change) has no gesture to pass, so it does not compile.
// - A background launch (`Launch`) builds its own configuration with `activates = false` (or `open -g`); callers
//   pass no configuration.
// - Panels are shown with `showPanel`, which refuses one that could activate.
// ShellTests.activationTests holds the rest: the raw AppKit calls appear only in here, and the factories only in
// handlers.

import AppKit

/// Proof that the user just acted on DeskMind (see the file's header). Made only by Activation's factories.
struct UserGesture {
    enum Source: Equatable { case click, reopen }
    let source: Source
    fileprivate init(_ source: Source) { self.source = source }
}

enum Activation {
    // MARK: the factories (each used only in a user-event handler: ShellTests.activationTests)

    /// A button's (or a tap's) action, given the gesture it is: `Button(action: Activation.onClick { g in … })`.
    static func onClick(_ action: @escaping (UserGesture) -> Void) -> () -> Void { { action(UserGesture(.click)) } }

    /// The AppKit mouse-up being delivered now (the event the application is handling), as a gesture; nil otherwise.
    static func mouseUp(_ event: NSEvent) -> UserGesture? {
        guard event.type == .leftMouseUp, NSApp.currentEvent === event else { return nil }
        return UserGesture(.click)
    }

    /// The app delegate's reopen: the Dock icon, a notification, the live card's open (applicationShouldHandleReopen).
    static func reopen(_ sender: NSApplication) -> UserGesture { UserGesture(.reopen) }

    /// A reopen with no window on screen restores the window — the Dock icon, a notification: the user's — except
    /// while a session's task runs with no card waiting: hands may give the front back there with `open -b`, a
    /// reopen too.
    static func reopenRestores(shellTaskWithoutCard: Bool) -> Bool { !shellTaskWithoutCard }

    // MARK: the funnel

    /// Told of each bringForward before it activates, with what the gesture was (the UI log's `activation`: the main
    /// app's ActivationRecorder). Main thread.
    nonisolated(unsafe) static var onBringForward: ((UserGesture.Source) -> Void)?

    /// DeskMind's window, restored if minimised, in front as the key window.
    static func bringForward(_ gesture: UserGesture, window: NSWindow) {
        onBringForward?(gesture.source)
        NSApp.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Opens (and brings forward) the app at `url`: the live card's click opening DeskMind.
    static func openApp(_ gesture: UserGesture, at url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// A panel on screen without activating anything: only a non-activating one.
    static func showPanel(_ panel: NSPanel) {
        precondition(panel.styleMask.contains(.nonactivatingPanel), "a panel that could activate DeskMind")
        panel.orderFrontRegardless()
    }
}

/// Opening apps in the background: never in front.
enum Launch {
    /// Launches the app at `url` in the background (its configuration is this function's: activates = false).
    static func background(_ url: URL, completion: @escaping (Error?) -> Void) {
        NSWorkspace.shared.openApplication(at: url, configuration: backgroundConfig()) { _, error in completion(error) }
    }

    /// The one configuration a background launch uses, as it is passed (ShellTests checks it): never in front, not in
    /// the recent items, the running instance when there is one.
    static func backgroundConfig() -> NSWorkspace.OpenConfiguration {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        cfg.createsNewApplicationInstance = false
        return cfg
    }

    /// The `open` arguments of a background reopen of `bundle` (bundleInBackground passes them as they are).
    static func bundleArguments(_ bundle: String) -> [String] { ["-g", "-b", bundle] }

    /// `open -g -b <bundle>`, waited for: launches the app, or reopens its windows, without bringing it forward.
    static func bundleInBackground(_ bundle: String) {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = bundleArguments(bundle)
        try? open.run(); open.waitUntilExit()
    }
}
