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

    /// The installed copy to hand over to and exit, when this one runs from inside another app's bundle and the
    /// installed copy is there; nil to keep running (already the installed copy, or nothing to hand over to).
    static func handOverTarget(bundlePath: String, installedPath: String, installedExists: Bool) -> String? {
        let mine = (bundlePath as NSString).standardizingPath, installed = (installedPath as NSString).standardizingPath
        guard mine != installed, mine.contains(".app/Contents/"), installedExists else { return nil }
        return installed
    }

    /// Whether to restart so a Screen Recording grant takes effect: a new process sees it (the probe) and this one
    /// does not, and no task is running. Once per process.
    static func restartForGrant(live: Bool, probe: Bool, taskRunning: Bool, alreadyScheduled: Bool) -> Bool {
        probe && !live && !taskRunning && !alreadyScheduled
    }

    /// The app's side: a connected helper running from anywhere but the installed copy is the wrong one.
    static func isWrongCopy(runningPath: String?, installedPath: String) -> Bool {
        guard let runningPath, !runningPath.isEmpty else { return false }   // an older helper that doesn't say
        return (runningPath as NSString).standardizingPath != (installedPath as NSString).standardizingPath
    }
}
