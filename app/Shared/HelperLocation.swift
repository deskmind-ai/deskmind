// Which copy of DeskMind Hands may run, and when it restarts itself. Foundation only, so tests/DecisionTests.swift
// checks it.
//
// The helper runs from its installed copy in Application Support (see helperURL in Main/GrantPanel.swift): nested in
// DeskMind.app, macOS judges its Screen Recording against DeskMind, and the switch turned on for DeskMind Hands has no
// effect. The nested copy still gets started by bundle id -- macOS's own "Quit & Reopen" after Screen Recording is
// turned on did that on a clean Mac (0.4.1-rc.1), and the setup then showed Screen Recording off whatever the user did.

import Foundation

enum HelperLocation {
    static let appName = "DeskMind Hands.app"

    static func installedPath(supportDir: String) -> String {
        (supportDir as NSString).appendingPathComponent(appName)
    }

    /// Whether a helper at `path` runs from inside another app's bundle (DeskMind.app's Contents/Library/LoginItems):
    /// the copy whose permissions count as DeskMind's.
    static func isNested(_ path: String, installedPath: String) -> Bool {
        let p = (path as NSString).standardizingPath
        return p != (installedPath as NSString).standardizingPath && p.contains(".app/Contents/")
    }

    /// The installed copy to hand over to and exit, when this one is nested; nil to keep running. The nested copy
    /// first installs itself there when the installed copy is missing or differs (an update the app has not copied
    /// out yet), so the hand-over always starts the version that shipped with this DeskMind.app.
    static func handOverTarget(bundlePath: String, installedPath: String) -> String? {
        isNested(bundlePath, installedPath: installedPath) ? (installedPath as NSString).standardizingPath : nil
    }

    /// What tells two copies of the helper apart (HelperInstaller.stamp).
    struct Stamp: Equatable {
        let version: String, build: String, runtime: String, executable: String
    }

    /// Whether the installed copy must be (re)made from the shipped one: missing, or different in any way -- an older
    /// copy after an update, or a newer one left by a later DeskMind.app that was replaced by an older one.
    static func needsInstall(shipped: Stamp?, installed: Stamp?) -> Bool {
        guard let shipped else { return false }   // nothing to install from
        return installed != shipped
    }

    /// Whether to restart so a Screen Recording grant takes effect: a new process sees it (the probe) and this one
    /// does not, and no task is running. Once per process. The helper starts its own successor before it exits
    /// (HelperInstaller.launch), so this does not depend on the app being open.
    static func restartForGrant(live: Bool, probe: Bool, taskRunning: Bool, alreadyScheduled: Bool) -> Bool {
        probe && !live && !taskRunning && !alreadyScheduled
    }

    /// The app's side: a connected helper running nested in an app bundle is the wrong one. Only nested: a helper
    /// started from a development build or a test elsewhere is left alone.
    static func isWrongCopy(runningPath: String?, installedPath: String) -> Bool {
        guard let runningPath, !runningPath.isEmpty else { return false }   // an older helper that doesn't say
        return isNested(runningPath, installedPath: installedPath)
    }
}

/// One helper at a time. Several launchers can start one at once -- a helper restarting itself, the app noticing it
/// gone, the nested copy handing over -- and a second helper would take the socket from the first (serve() unlinks
/// it). Each holds an flock on a file next to the socket for as long as it lives (released when it exits, however it
/// exits; not inherited by its children). A starting helper waits for the holder to go -- the successor of a restart
/// or an update -- and gives up after `wait` seconds: another helper is running, so this one is not needed.
enum HelperLock {
    static let fileName = "hands.lock"

    /// The descriptor holding the lock; nil when another process kept it for `wait` seconds; -1 when there is no lock
    /// file to hold (the helper goes on without one rather than not run).
    static func acquire(_ path: String, wait: Double) -> Int32? {
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return -1 }
        let deadline = Date().addingTimeInterval(wait)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
            if Date() >= deadline { close(fd); return nil }
            usleep(100_000)
        }
    }
}
