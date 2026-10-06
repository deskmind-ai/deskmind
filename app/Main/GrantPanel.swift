// The drag-to-grant accessory: a small panel that sits under System Settings' window and follows it, holding the
// helper's tile. The helper lives inside DeskMind.app, where neither Spotlight nor the "+" picker finds it, so the
// user drags it into the privacy list.

import AppKit
import SwiftUI

enum Grant: String, CaseIterable, Identifiable {
    case accessibility, screen, automation
    var id: String { rawValue }

    /// Named as System Settings names them.
    func title(_ lang: ResolvedLang) -> String {
        switch self {
        case .accessibility: L("Accessibility", lang: lang)
        case .screen: L("Screen Recording", lang: lang)
        case .automation: L("Automation", lang: lang)
        }
    }

    func subtitle(_ lang: ResolvedLang) -> String {
        switch self {
        case .accessibility: L("Reads the buttons and text in windows, and clicks and types for you", lang: lang)
        case .screen: L("Sees what's on screen, to tell how far a task has got", lang: lang)
        case .automation: L("Lets Finder and TextEdit save and move files in the background", lang: lang)
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: "hand.point.up.left"
        case .screen: "rectangle.dashed.badge.record"
        case .automation: "gearshape.2"
        }
    }

    var required: Bool { self != .automation }
    /// Dragged into a list in System Settings; automation is granted by a system prompt instead.
    var byDrag: Bool { self != .automation }
    var statusKey: String {
        switch self {
        case .accessibility: "accessibility"
        case .screen: "screen_recording_granted"
        case .automation: "automation"
        }
    }

    var settingsURL: URL {
        let anchor = switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screen: "Privacy_ScreenCapture"
        case .automation: "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

/// The helper as shipped, inside this app.
var bundledHelperURL: URL {
    Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/DeskMind Hands.app")
}

/// The helper as installed and run: a copy outside DeskMind.app, in Application Support/DeskMind.
/// Nested inside the main bundle, Screen Recording was judged against DeskMind itself (tccd logged the subject as
/// ai.deskmind.app with DeskMind Hands only as the responsible process), so the switch turned on for DeskMind
/// Hands had no effect.
var helperURL: URL { DeskMindIPC.supportDir.appendingPathComponent("DeskMind Hands.app") }

/// Copy the bundled helper out when it is missing or differs from the shipped one (HelperInstaller). Returns whether it
/// changed.
@discardableResult
func installHelper() throws -> Bool {
    try HelperInstaller.ensureInstalled(shipped: bundledHelperURL.path, installed: helperURL.path)
}

@MainActor
final class GrantPanelController {
    static let shared = GrantPanelController()
    private var panel: NSPanel?
    private var follow: Timer?

    func show(_ grant: Grant, model: HelperModel) {
        close()
        NSWorkspace.shared.open(grant.settingsURL)
        // A panel of its own, outside the window: it reads the language setting itself, and follows a switch too.
        let view = LocalizedRoot {
            GrantAccessory(grant: grant, onClose: { [weak self] in self?.close() }).environmentObject(model)
        }
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 132)
        let panel = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        self.panel = panel
        place()
        panel.orderFrontRegardless()
        // System Settings takes a moment to open and the user may move it: stay docked under its window.
        follow = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            Task { @MainActor in GrantPanelController.shared.place() }
        }
    }

    func close() {
        HelperModel.shared?.watchGrant(nil)
        follow?.invalidate(); follow = nil
        panel?.orderOut(nil); panel = nil
    }

    /// Under System Settings' window, centred; bottom-centre of the main screen when it is not found yet.
    func place() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = panel.frame.size
        var origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 40)
        if let r = settingsWindowFrame() {
            // CGWindow bounds are top-left based; AppKit is bottom-left.
            let top = screen.frame.maxY - r.maxY
            origin = NSPoint(x: r.midX - size.width / 2, y: max(screen.visibleFrame.minY + 8, top - size.height - 10))
        }
        panel.setFrameOrigin(origin)
    }

    private func settingsWindowFrame() -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for w in list {
            // By bundle id: the owner's name is System Settings in whatever language macOS runs in.
            let pid = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
            guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.systempreferences",
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = b["Width"], width > 300 else { continue }
            return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: width, height: b["Height"] ?? 0)
        }
        return nil
    }
}

struct GrantAccessory: View {
    let grant: Grant
    let onClose: () -> Void
    @EnvironmentObject var model: HelperModel
    @State private var nudge = false
    @State private var dropped = false
    @Environment(\.lang) private var lang

    var granted: Bool { model.status[grant.statusKey] as? Bool == true }

    var body: some View {
        HStack(spacing: 16) {
            XiaoFang(mood: granted ? .done : .notice, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                if granted {
                    Text(L("“%@” is allowed", grant.title(lang), lang: lang)).font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(grant == .screen ? L("Restarting the helper to apply it…", lang: lang)
                                          : L("You can go back to DeskMind now.", lang: lang))
                        .font(.system(size: 12)).foregroundStyle(Brand.sage)
                } else if dropped {
                    Text(L("Added. Now turn on the switch next to “DeskMind Hands”", lang: lang))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(L("This confirms itself once the switch is on", lang: lang))
                        .font(.system(size: 12)).foregroundStyle(Brand.sage)
                } else {
                    Text(L("Drag the icon on the right into the “%@” list above", grant.title(lang), lang: lang))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(L("Then turn on the switch next to it", lang: lang))
                        .font(.system(size: 12)).foregroundStyle(Brand.sage)
                }
            }
            .foregroundStyle(Brand.ink)
            Spacer(minLength: 0)
            if !granted && !dropped {
                VStack(spacing: 2) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(Brand.dot)
                        .offset(y: nudge ? -4 : 2)
                        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: nudge)
                    ZStack {
                        VStack(spacing: 3) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: helperURL.path))
                                .resizable().frame(width: 48, height: 48)
                            Text("DeskMind Hands").font(.system(size: 10, weight: .medium)).foregroundStyle(Brand.ink)
                        }
                        .allowsHitTesting(false)
                        // AppKit drag source over the tile: it knows when the drop landed, SwiftUI's onDrag does not.
                        DragSource(url: helperURL) { withAnimation(.easeOut(duration: 0.25)) { dropped = true } }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Brand.card))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Brand.dot, style: StrokeStyle(lineWidth: 1.4, dash: [5, 4])))
                    .help(L("Drag into the list in System Settings", lang: lang))
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(width: 480, height: 132)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Brand.paper))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Brand.line, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Brand.sage)
                    .padding(8)
            }.buttonStyle(.plain)
        }
        .onAppear { nudge = true; model.watchGrant(grant) }
        .onChange(of: granted) { _, now in
            guard now else { return }
            if grant == .screen { model.send(["op": "restart"], label: "restart after screen recording") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { onClose() }
        }
    }
}


/// A drag source that hands System Settings a file URL and reports when the drop was accepted.
struct DragSource: NSViewRepresentable {
    let url: URL
    let onDropped: () -> Void

    func makeNSView(context: Context) -> DragSourceView {
        let v = DragSourceView()
        v.url = url
        v.onDropped = onDropped
        return v
    }

    func updateNSView(_ v: DragSourceView, context: Context) { v.onDropped = onDropped }
}

final class DragSourceView: NSView, NSDraggingSource {
    var url: URL?
    var onDropped: (() -> Void)?

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let url else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let side: CGFloat = 56
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if !operation.isEmpty { onDropped?() }
    }
}
