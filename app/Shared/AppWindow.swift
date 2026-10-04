// Whether an app a run is about to work in needs its window brought back first. A running app with no window (its
// last window closed, the app left running, as music players are) gave hands nothing to look at: the observation
// read "(no window open)", and the planner ended the run as done after one step, having done nothing. A reopen
// (`open -g -b`, which does not bring the app forward) makes such an app show its main window again.
//
// Not for document-based apps -- those whose Info.plist names an NSDocumentClass for a document type (TextEdit,
// Preview, Pages, Numbers, Keynote; Safari too): a reopen with nothing open puts up their Open panel or template
// chooser, and hands opens their documents itself. Nor for Finder, which hands opens a folder in. The named ones are
// listed as well, in case an app's declaration is not where it is looked for. Foundation only, so
// tests/DecisionTests.swift checks it.

import Foundation

enum AppWindow {
    /// Apps not to reopen whatever their Info.plist says.
    static let opensItsOwn: Set<String> = ["com.apple.finder", "com.apple.textedit", "com.apple.preview",
                                           "com.apple.iwork.pages", "com.apple.iwork.numbers", "com.apple.iwork.keynote"]

    /// `running`: the app is running. `ordinaryWindows`: how many normal (layer 0) windows of it are on screen.
    /// `documentBased`: its Info.plist declares a document type with an NSDocumentClass (see documentBased(info:)).
    static func shouldReopen(bundle: String, running: Bool, ordinaryWindows: Int, documentBased: Bool) -> Bool {
        running && ordinaryWindows == 0 && !documentBased && !opensItsOwn.contains(bundle.lowercased())
    }

    /// Whether an app's Info.plist declares a document type handled by an NSDocument subclass.
    static func documentBased(info: [String: Any]?) -> Bool {
        (info?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []).contains { $0["NSDocumentClass"] != nil }
    }
}
