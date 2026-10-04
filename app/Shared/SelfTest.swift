// The Self-test screen's tasks in the app's language (Main/RunView.swift). Their titles in hands' task files are in
// Chinese, and showed so in an English app (first run, 10-05). Also what the Start button says. Foundation only, so
// tests/DecisionTests.swift checks it.

import Foundation

enum SelfTest {
    /// English titles (L() keys) of the sandbox tasks the screen runs: the mock desktop's six and the four real ones.
    static let titles: [String: String] = [
        "S01-rename": "Rename a file and keep its contents",
        "S02-edit-save": "Open a document, add a line and save",
        "S03-zh-text": "Type Chinese text exactly",
        "S04-clipboard-protect": "Finish without wiping the clipboard",
        "S05-cancel": "Start no new write after a cancel",
        "S06-stale-binding": "Find the window again after it moves",
        "G07-finder-newfolder": "Make a new folder",
        "G08-finder-move-one": "Move a file into a folder",
        "G01-finder-sort": "Sort files by type",
        "G04-chinese-exact": "Type exact Chinese text and save",
    ]

    /// A task's title for the screen: ours, in the app's language, else the task file's.
    static func title(id: String, fallback: String, lang: ResolvedLang) -> String {
        titles[id].map { L($0, lang: lang) } ?? fallback
    }

    /// "Start" for a task not run yet on this screen, "Run again" for the one that just ran -- picking another task
    /// after a run showed "Run again", which read as running the last one again.
    static func startLabel(selected: String, lastRun: String?) -> String {
        selected == lastRun ? "Run again" : "Start"
    }
}
