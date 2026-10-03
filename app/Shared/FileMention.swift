// The files an instruction names ("records.txt", "报销单.xlsx"): with none attached, the home screen says so before the
// run starts. Foundation only, so the unit tests (tests/DecisionTests.swift) run it. The same rule as hands'
// cli.named_files, which refuses such a run up front when none of the files is open either.
//
// A D4 take on 10-01 started with the folder left unattached: TextEdit came up with its Open panel and the run was
// stopped as stuck a minute later, with nothing that said why.

import Foundation

enum FileMention {
    /// Not files: web addresses and app bundles ("example.com", "TextEdit.app").
    static let notFiles: Set<String> = ["app", "com", "org", "net", "io", "cn", "www", "html", "htm"]
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![\w./@-])([\w\x{4e00}-\x{9fff}][\w\x{4e00}-\x{9fff}.\-]*\.[A-Za-z][A-Za-z0-9]{0,4})(?![\w/@-])"#)

    /// The files `goal` names, in order, without repeats.
    static func named(in goal: String) -> [String] {
        let ns = goal as NSString
        var out: [String] = []
        for m in pattern.matches(in: goal, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            guard let ext = name.split(separator: ".").last.map({ $0.lowercased() }), !notFiles.contains(ext),
                  !name.hasPrefix(".") else { continue }
            if !out.contains(name) { out.append(name) }
        }
        return out
    }
}
