// What a run may do unasked in the folder it works in (Helper/Runner.swift). Foundation only, so
// tests/DecisionTests.swift checks it.

import Foundation

enum FolderPolicy {
    /// Whether renames wait for the user's approval (hands' --confirm-renames): in any folder but the sample one, which
    /// is made to be played with and can be reset. A rename has no undo; on a vague goal a planner renamed real
    /// files to "file-8" and "file-3" (10-05).
    static func confirmRenames(folder: String, sample: String) -> Bool {
        let f = URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath().path
        let s = URL(fileURLWithPath: sample).standardizedFileURL.resolvingSymlinksInPath().path
        return !(f == s || f.hasPrefix(s + "/"))
    }
}
