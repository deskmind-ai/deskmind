// The main window's state as the user sees it, settled (A3, plan §1.4): what CardPlacement.place is given. Observed,
// never acted on -- nothing here moves a window, the focus or the front app (ShellTests checks the window's files) --
// from AppKit's own notifications, and settled by FrontmostDebounce (250 ms: windows change order in steps, and a card
// must not hop between the chat and the float on the way). The float's own visibility is the float's to say (A5).

import AppKit

@MainActor
final class FrontmostMonitor: ObservableObject {
    /// The state that counts now (FrontmostDebounce.stable).
    @Published private(set) var window: MainWindowState
    /// Told of every change seen, before the settle (the float answers to the window's state now: never two places).
    var onRaw: (() -> Void)?
    private var debounce: FrontmostDebounce
    private var observers: [NSObjectProtocol] = []
    private var tick: Timer?

    init() {
        let now = Self.observe()
        window = now
        debounce = FrontmostDebounce(now)
        let c = NotificationCenter.default
        let names: [Notification.Name] = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                                          NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                                          NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                                          NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                                          NSWindow.willCloseNotification, NSWindow.didChangeOcclusionStateNotification]
        for n in names {
            observers.append(c.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saw() }
            })
        }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        tick?.invalidate()
    }

    /// The window as it is now, unsettled.
    static func observe() -> MainWindowState {
        guard let w = MainWindow.window, w.isVisible || w.isMiniaturized else { return .away }
        if NSApp.isHidden || w.isMiniaturized { return .away }
        if NSApp.isActive && w.isKeyWindow { return .front }
        return w.occlusionState.contains(.visible) ? .behindVisible : .away
    }

    private func saw() {
        onRaw?()
        let t = Date().timeIntervalSince1970
        set(debounce.saw(Self.observe(), at: t))
        // a change waits its 250 ms: looked at again then, by the clock alone
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: FrontmostDebounce.settle + 0.01, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.set(self.debounce.saw(Self.observe(), at: Date().timeIntervalSince1970))
            }
        }
    }

    private func set(_ s: MainWindowState) { if window != s { window = s } }
}
