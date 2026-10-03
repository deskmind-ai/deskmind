// Which apps an instruction is about. "打开网易云音乐，搜索…并播放" names one; "In Safari, search … and put the answer in
// Notes" names two, in order: the first is where the run starts, and the planner may switch among them (and only
// them -- hands refuses any other). Nothing named and a folder attached: a file task, done in Finder. Nothing named
// and no folder: the user is asked which app to use before anything runs, since the model, offered no app at all,
// can only wander (09-27: offered only Finder for a NetEase instruction, it pressed "go up a folder" five times and
// was stopped as stuck).
//
// Names come from the installed apps themselves -- file name, display name, the bundle's English and Chinese names
// -- not from a hard-coded list, plus a few everyday names a bundle does not carry ("网易云", "NetEase Cloud Music").

import AppKit

struct ResolvedApp: Hashable {
    /// What the instruction calls it ("网易云"): the name hands and the planner see.
    let mention: String
    let bundleID: String
    let path: String
    let nameEN: String
    let nameZH: String?

    func displayName(_ lang: ResolvedLang) -> String { lang == .zhHans ? (nameZH ?? nameEN) : nameEN }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: path) }
}

enum AppScope {
    struct Installed {
        let bundleID: String
        let path: String
        let nameEN: String
        let nameZH: String?
        var names: [String]
    }

    /// Never a target: this app itself.
    static let excluded: Set<String> = ["ai.deskmind.app", "ai.deskmind.hands"]

    /// Everyday names a bundle does not carry, by bundle id; used only when that app is installed.
    static let aliases: [String: [String]] = [
        "com.netease.163music": ["NetEase Cloud Music", "Netease Music", "NetEase Music", "网易云"],
        "com.tencent.QQMusicMac": ["QQ Music", "QQ音乐"],
        "com.tencent.xinWeChat": ["WeChat", "微信"],
        "com.google.Chrome": ["Chrome", "谷歌浏览器"],
        "com.apple.finder": ["Finder", "访达"],
    ]

    /// How to show an app whose bundle only carries a file-like name ("NeteaseMusic"): (English, Chinese).
    static let shownAs: [String: (String, String)] = [
        "com.netease.163music": ("NetEase Cloud Music", "网易云音乐"),
        "com.tencent.QQMusicMac": ("QQ Music", "QQ音乐"),
        "com.tencent.xinWeChat": ("WeChat", "微信"),
    ]

    /// Every installed app with its names.
    static let installed: [Installed] = {
        let fm = FileManager.default
        var dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"]
        dirs += ((try? fm.contentsOfDirectory(atPath: "/Applications")) ?? [])
            .filter { !$0.hasSuffix(".app") }.map { "/Applications/" + $0 }   // folders of apps (e.g. Utilities)
        // Finder lives in CoreServices, where nothing else a user would name does.
        var paths = ["/System/Library/CoreServices/Finder.app"]
        for dir in dirs {
            for entry in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where entry.hasSuffix(".app") {
                paths.append(dir + "/" + entry)
            }
        }
        var out: [Installed] = []
        var seen = Set<String>()
        for path in paths {
            guard let bundle = Bundle(path: path), let id = bundle.bundleIdentifier, !excluded.contains(id),
                  !seen.contains(id) else { continue }
            seen.insert(id)
            let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            var names = [file]
            var en: String? = nil, zh: String? = nil
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let v = bundle.infoDictionary?[key] as? String { names.append(v); en = en ?? v }
            }
            // The Chinese name a user types is often only in the localized InfoPlist.strings.
            for loc in ["zh-Hans", "zh_CN", "zh-CN", "zh_Hans"] {
                if let url = bundle.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil,
                                        localization: loc),
                   let dict = NSDictionary(contentsOf: url) as? [String: Any] {
                    for key in ["CFBundleDisplayName", "CFBundleName"] {
                        if let v = dict[key] as? String { names.append(v); zh = zh ?? v }
                    }
                }
            }
            if let url = bundle.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil,
                                    localization: "en"),
               let dict = NSDictionary(contentsOf: url) as? [String: Any],
               let v = (dict["CFBundleDisplayName"] ?? dict["CFBundleName"]) as? String {
                names.append(v); en = v
            }
            // Apple's own apps keep every language in one compiled table, InfoPlist.loctable ({locale: {key: value}}),
            // not in .lproj folders: without it "备忘录" and "访达" were never found.
            if let url = bundle.url(forResource: "InfoPlist", withExtension: "loctable"),
               let table = NSDictionary(contentsOf: url) as? [String: [String: Any]] {
                for loc in ["zh_CN", "zh-Hans", "zh_Hans"] {
                    if let v = (table[loc]?["CFBundleDisplayName"] ?? table[loc]?["CFBundleName"]) as? String {
                        names.append(v); zh = zh ?? v
                    }
                }
                if let v = (table["en"]?["CFBundleDisplayName"] ?? table["en"]?["CFBundleName"]) as? String {
                    names.append(v); en = v
                }
            }
            names.append(fm.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""))
            names += aliases[id] ?? []
            let usable = Set(names.map { $0.trimmingCharacters(in: .whitespaces) }).filter { n in
                // Two CJK characters or four Latin ones at least: "QQ" aside, shorter names match inside ordinary
                // words.
                isCJK(n) ? n.count >= 2 : n.count >= 4
            }
            guard !usable.isEmpty else { continue }
            let shown = shownAs[id]
            out.append(Installed(bundleID: id, path: path, nameEN: shown?.0 ?? en ?? file,
                                 nameZH: shown?.1 ?? zh.flatMap { isCJK($0) ? $0 : nil },
                                 names: usable.sorted { $0.count > $1.count }))
        }
        return out
    }()

    static func isCJK(_ s: String) -> Bool { AppMention.isCJK(s) }

    /// Where in `goal` (lowercased) the app is named, if it is, as an app (Shared/AppMention.swift, which the unit
    /// tests run).
    private static func mention(of app: Installed, in g: String, original: String?) -> (Range<String.Index>, String)? {
        var best: (Range<String.Index>, String)? = nil
        for name in app.names {
            let isAlias = (aliases[app.bundleID] ?? []).contains(name)
            guard let r = AppMention.range(of: name.lowercased(), isAlias: isAlias, in: g, original: original) else {
                continue
            }
            if best == nil || r.lowerBound < best!.0.lowerBound { best = (r, name) }
        }
        return best
    }

    /// The installed apps `goal` names, in the order it names them.
    static func resolve(_ goal: String) -> [ResolvedApp] {
        let g = goal.lowercased()
        var hits: [(String.Index, Range<String.Index>, ResolvedApp)] = []
        for app in installed {
            // The original is consulted for case only where lowercasing kept every character in place.
            guard let (r, name) = mention(of: app, in: g, original: goal.count == g.count ? goal : nil) else { continue }
            // As the user wrote it, when lowercasing kept every character in place (it does for CJK and Latin).
            var typed = name
            if goal.count == g.count {
                let a = g.distance(from: g.startIndex, to: r.lowerBound), n = g.distance(from: r.lowerBound, to: r.upperBound)
                let start = goal.index(goal.startIndex, offsetBy: a)
                typed = String(goal[start..<goal.index(start, offsetBy: n)])
            }
            hits.append((r.lowerBound, r, ResolvedApp(mention: typed, bundleID: app.bundleID,
                                                      path: app.path, nameEN: app.nameEN, nameZH: app.nameZH)))
        }
        hits.sort { $0.0 < $1.0 }
        // A name inside a longer one already matched ("音乐" inside "网易云音乐") is not a second app.
        var out: [(Range<String.Index>, ResolvedApp)] = []
        for (_, r, app) in hits where !out.contains(where: { $0.0.overlaps(r) || $0.1.bundleID == app.bundleID }) {
            out.append((r, app))
        }
        return out.map(\.1)
    }

    static var finder: ResolvedApp {
        let path = "/System/Library/CoreServices/Finder.app"
        return ResolvedApp(mention: "Finder", bundleID: "com.apple.finder", path: path, nameEN: "Finder", nameZH: "访达")
    }

    static func isInstalled(_ bundleID: String) -> Bool { installed.contains { $0.bundleID == bundleID } }
}
