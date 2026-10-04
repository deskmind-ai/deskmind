// Whether an app a run is about to work in needs its window brought back first. A running app with no window (its
// last window closed, the app left running, as music players are) gave hands nothing to look at: the observation
// read "(no window open)", and the planner ended the run as done after one step, having done nothing. A reopen
// (`open -g -b`, which does not bring the app forward) makes such an app show its main window again.
//
// Not for Finder and TextEdit: hands opens their windows itself (a folder, a document), and a reopen with nothing
// open puts up TextEdit's Open panel. Foundation only, so tests/DecisionTests.swift checks it.

import Foundation

enum AppWindow {
    /// Apps whose windows hands opens itself.
    static let opensItsOwn: Set<String> = ["com.apple.finder", "com.apple.textedit"]

    /// `running`: the app is running. `ordinaryWindows`: how many normal (layer 0) windows of it are on screen.
    static func shouldReopen(bundle: String, running: Bool, ordinaryWindows: Int) -> Bool {
        running && ordinaryWindows == 0 && !opensItsOwn.contains(bundle.lowercased())
    }
}
