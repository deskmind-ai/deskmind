// The first setup's three steps (Main/HomeView.swift SetupCard) in words: 1 allow, 2 download the local models, 3 try
// your first task. What needs no screen, so tests/DecisionTests.swift checks it.

import Foundation

enum SetupSteps {
    /// Where the model download is: Main/ModelDownloader.swift's phase, without the app's types.
    enum Transfer: Equatable { case idle, downloading(done: Int64, total: Int64), verifying, paused, failed, done }

    /// Step 1's count: the background helper and each required permission.
    static func grants(helperReady: Bool, required: [Bool]) -> (done: Int, total: Int) {
        ((helperReady ? 1 : 0) + required.filter { $0 }.count, 1 + required.count)
    }

    /// Step 2 in a few words, from where the download and the model really are. The download starts only when the
    /// user presses Download, so it is never said to be running when it is not.
    static func download(brain: String, transfer: Transfer, lang: ResolvedLang) -> String {
        if brain == "ready" { return L("Ready", lang: lang) }
        switch transfer {
        case .downloading(let done, let total):
            return String(format: "%.1f / %.1f GB", Double(done) / 1e9, Double(total) / 1e9)
        case .verifying: return L("checking the files", lang: lang)
        case .paused: return L("paused", lang: lang)
        case .failed: return L("didn't finish — try again below", lang: lang)
        case .idle, .done: break
        }
        return switch brain {
        case "missing": L("about 5.3 GB — press Download", lang: lang)
        case "loading": L("loading", lang: lang)
        default: ""
        }
    }

    /// Step 3, beside it and under it: locked until the first two are done, then the examples are the way in.
    static func firstTask(unlocked: Bool, lang: ResolvedLang) -> (progress: String, hint: String) {
        unlocked ? (L("Ready", lang: lang), L("Pick one of the examples above, or type your own.", lang: lang))
                 : (L("unlocks when 1 and 2 are done", lang: lang),
                    L("The examples above start working as soon as the first two steps are done.", lang: lang))
    }
}
