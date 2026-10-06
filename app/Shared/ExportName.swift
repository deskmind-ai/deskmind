// Where an export goes (Main/ReplayGIF.swift): "<date time> <task>.<ext>", and never over a file already there.

import Foundation

enum ExportName {
    /// The task's name as a file name: no "/" or ":", single spaces, 40 characters at most.
    static func title(_ s: String) -> String {
        let words = s.replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: ":", with: " ")
            .split(whereSeparator: \.isWhitespace)
        return String(words.joined(separator: " ").prefix(40))
    }

    /// The first free name in `dir`: "<stamp> <title>.<ext>", else "<stamp> <title> 2.<ext>", " 3"... The stamp is
    /// usually to the minute, so two exports within a minute, or two runs of the same task, would otherwise collide.
    static func unique(dir: URL, stamp: String, title: String, ext: String,
                       exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let t = Self.title(title)
        let base = t.isEmpty ? stamp : "\(stamp) \(t)"
        var url = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while exists(url) { url = dir.appendingPathComponent("\(base) \(n).\(ext)"); n += 1 }
        return url
    }
}
