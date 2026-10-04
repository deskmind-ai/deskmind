// What a GitHub report carries besides the user's own words (Shared/IssueReport.swift): enough to tell what went
// wrong -- the error as the run reported it, how long each decision took, the shape of the request that failed, the
// versions and the Mac -- and nothing of what was on the screen or in the folder. Paths, the user's name and quoted
// names are taken out of the error; the folder is counted, not listed; the failed request is its questions' kinds
// and sizes. Foundation only, so tests/DecisionTests.swift checks it.

import Foundation

struct Diagnostics {
    /// The run's error, as hands reported it (its last lines); sanitized when shown.
    var error = ""
    /// Each decision's time, in seconds.
    var stepSeconds: [Double] = []
    /// The request that failed: question → (kind, options) (hands' "request_failed").
    var failedRequest: [String: (type: String, options: Int)] = [:]
    /// The attached folder: how many files and folders directly in it.
    var folder: (files: Int, folders: Int)?
    /// App, runtime, models, macOS, Mac, chip, memory.
    var system: [(String, String)] = []

    /// The error's useful lines, with paths, the user's name and quoted names taken out.
    static func sanitize(_ raw: String, user: String = NSUserName()) -> String {
        let keep = raw.split(separator: "\n").map(String.init).filter { line in
            let l = line.lowercased()
            return l.contains("error") || l.contains("failed") || l.contains("unavailable") || l.contains("errored")
                || l.contains("exception") || l.contains("timed out") || l.hasPrefix("metal") || l.contains("malloc")
        }
        var s = keep.suffix(4).joined(separator: "\n")
        // Absolute paths: /Users/…, /private/…, /var/…, /Volumes/…, ~/…
        s = s.replacingOccurrences(of: #"(~|/(Users|private|var|Volumes|tmp|Applications|Library))(/[^\s'"\)\],]*)?"#,
                                   with: "<path>", options: .regularExpression)
        if user.count >= 2 { s = s.replacingOccurrences(of: user, with: "<user>") }
        // A quoted name that looks like a file, a person or screen text: anything with a dot, a slash, a space or
        // non-ASCII in it. Short identifiers ('window_id') stay: they say where the error is.
        s = s.replacingOccurrences(of: #"'[^'\n]*([./ ]|[^\x00-\x7F])[^'\n]*'"#, with: "'…'", options: .regularExpression)
        s = s.replacingOccurrences(of: #""[^"\n]*([./ ]|[^\x00-\x7F])[^"\n]*""#, with: "\"…\"", options: .regularExpression)
        return String(s.prefix(800))
    }

    /// The section a report carries, folded: a few lines of numbers and kinds.
    func markdown() -> String {
        var lines: [String] = []
        let e = Self.sanitize(error)
        if !e.isEmpty { lines.append("Error:\n```\n\(e)\n```") }
        if !stepSeconds.isEmpty {
            let shown = stepSeconds.prefix(40).map { String(format: "%.1f", $0) }.joined(separator: ", ")
            lines.append("Decision time per step (s): \(shown)\(stepSeconds.count > 40 ? ", …" : "")")
        }
        if !failedRequest.isEmpty {
            let qs = failedRequest.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value.type), \($0.value.options))" }
            lines.append("Failed request: \(qs.joined(separator: ", "))")
        }
        if let folder { lines.append("Attached folder: \(folder.files) files, \(folder.folders) folders") }
        if !system.isEmpty { lines.append(system.map { "\($0.0): \($0.1)" }.joined(separator: " · ")) }
        guard !lines.isEmpty else { return "" }
        return "<details><summary>Diagnostics (no screen content, file names or paths)</summary>\n\n"
            + lines.joined(separator: "\n\n") + "\n\n</details>\n"
    }

    /// The files and folders directly in a folder, counted.
    static func count(folder path: String) -> (files: Int, folders: Int)? {
        guard let items = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path),
                                                                         includingPropertiesForKeys: [.isDirectoryKey],
                                                                         options: [.skipsHiddenFiles]) else { return nil }
        let dirs = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.count
        return (items.count - dirs, dirs)
    }

    /// This Mac: its model identifier, chip and memory.
    static func mac() -> [(String, String)] {
        func sysctl(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buf = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
            return String(cString: buf)
        }
        var out: [(String, String)] = []
        if let m = sysctl("hw.model") { out.append(("Mac", m)) }
        if let c = sysctl("machdep.cpu.brand_string") { out.append(("chip", c)) }
        out.append(("memory", "\(ProcessInfo.processInfo.physicalMemory >> 30) GB"))
        return out
    }
}
