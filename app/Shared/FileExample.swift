// The home screen's file example ("Make a folder called Receipts and move … into it", Main/HomeView.swift): the file
// it names is always one the folder really holds. First run, 10-05: the example named expenses.csv, the folder did
// not have it, and the run made the folder and then failed. Foundation only, so tests/DecisionTests.swift checks it.

import Foundation

enum FileExample {
    /// The expenses file the helper seeds in the sample folder, in either language.
    static let sampleNames = ["报销单.csv", "expenses.csv"]
    /// Document kinds, most example-like first: what a person would file away.
    static let documentKinds = ["csv", "xlsx", "pdf", "docx", "txt", "md", "numbers", "pages", "key", "pptx"]

    /// The file the example moves, given the names of the files (not folders) in the folder: the sample expenses
    /// file when it is there, else a document, else any visible file with an extension; nil when there is none -- then
    /// the example is not offered.
    static func file(in names: [String]) -> String? {
        if let s = names.first(where: { sampleNames.contains($0) }) { return s }
        let visible = names.filter { !$0.hasPrefix(".") && !$0.hasPrefix("~$") && ($0 as NSString).pathExtension != "" }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for kind in documentKinds {
            if let f = visible.first(where: { ($0 as NSString).pathExtension.lowercased() == kind }) { return f }
        }
        return visible.first
    }

    /// The names of the files directly in a folder (no folders, nothing hidden).
    static func files(at path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                   options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            .map(\.lastPathComponent)
    }
}
