// Whether a name in an instruction names an app to operate, and where: the part of AppScope that needs no list of
// installed apps, so the unit tests (tests/DecisionTests.swift) run it without a Mac's app folders.

import Foundation

enum AppMention {
    /// Words before a name that make it an app to operate, not a word in a file task ("把照片放进…" is about files,
    /// "在照片里…" is the app). Not "search", "play" or "send": what follows them is what is searched for, played or
    /// sent ("搜索新加坡的天气" is about the weather, not the Weather app).
    static let verbs = launchVerbs + ["在", "用", "通过", "登录", "切到", "切换到",
                                      "in ", "using", "into ", "log in to", "log into"]
    /// The verbs that name an app on their own ("open music"): a Latin name typed in lowercase is an app only after
    /// one of these ("put it in notes" is about a file called notes).
    static let launchVerbs = ["打开", "启动", "运行", "open", "launch", "start", "go to", "switch to"]
    /// Words right after a name that say the same: "网易云里", "Safari app", and the app's state: "Safari 打开着一张
    /// 表" (the D1 goal named Safari only so, and the run could not see the table), "TextEdit 窗口", and in English
    /// "TextEdit has records.txt open", "Safari shows …", "Preview is open …" -- an English goal that named its app
    /// only so was run in Finder (09-30).
    /// Not "上" or "中": "把照片上传…", "照片中的人" are about files.
    static let markers = ["里", "app", "应用", "搜", "播放", "打开着", "开着", "窗口", "window"]
    /// The English ones only after a name typed with its capital, as an app is: "the file notes has 3 lines" is about
    /// a file.
    static let stateMarkers = ["has ", "shows ", "is open", "is showing"]

    static func isCJK(_ s: String) -> Bool { s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }

    /// Where `name` (lowercased) is named as an app in `g` (the goal, lowercased), if it is. `original` is the goal
    /// as typed, consulted for case; `isAlias` for an everyday name a bundle does not carry ("网易云").
    static func range(of name: String, isAlias: Bool, in g: String, original: String?) -> Range<String.Index>? {
        var from = g.startIndex
        while let r = g.range(of: name, range: from..<g.endIndex) {
            from = r.upperBound
            if !isCJK(name) {
                // A whole word, not part of one: "notes" in "notes.txt" is a file. A full stop that ends the
                // sentence is not an extension: "…open them in TextEdit." names the app (09-30: it did not, and the
                // run started in Finder).
                let before = r.lowerBound == g.startIndex ? " " : g[g.index(before: r.lowerBound)]
                let after = r.upperBound == g.endIndex ? " " : g[r.upperBound]
                let afterDot = after == "." && g.index(after: r.upperBound) < g.endIndex
                    ? g[g.index(after: r.upperBound)] : " "
                if before.isLetter || after.isLetter || (after == "." && (afterDot.isLetter || afterDot.isNumber)) {
                    continue
                }
            }
            let head = g[g.startIndex..<r.lowerBound].suffix(8)
            let tail = String(g[r.upperBound...].prefix(12)).trimmingCharacters(in: .whitespaces)
            // As typed: "Music" is the app, "music" in "search music on QQ Music" is what is searched for.
            let lowercaseLatin = !isCJK(name) && original.map { o in
                let typed = o[o.index(o.startIndex, offsetBy: g.distance(from: g.startIndex, to: r.lowerBound))...]
                return typed.first?.isLowercase == true
            } == true
            // A long CJK name ("网易云音乐") or an everyday alias is an app wherever it stands; a short or ordinary one
            // ("照片", "Notes") only next to a verb or an app marker.
            let asApp = isAlias || (isCJK(name) && name.count >= 4)
                || (lowercaseLatin ? launchVerbs : verbs).contains(where: { head.contains($0) })
                || markers.contains(where: { tail.hasPrefix($0) })
                || (!lowercaseLatin && !isCJK(name) && stateMarkers.contains(where: { tail.hasPrefix($0) }))
            if asApp { return r }
        }
        return nil
    }
}
