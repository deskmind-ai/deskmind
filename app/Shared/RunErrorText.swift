// A failed run in one sentence the user can act on (Main/RunView.swift); the raw text stays under "Details".
// Foundation only, so tests/DecisionTests.swift checks each kind of failure against real messages.

import Foundation

enum RunErrorText {
    static func friendly(_ raw: String, lang: ResolvedLang) -> String {
        let r = raw.lowercased()
        // The apps file (~/.config/deskmind/apps.yaml, written by hand) is wrong: hands refuses it at start, so every
        // run fails the same way until it is fixed. What is wrong comes after the file's path.
        if let line = raw.components(separatedBy: "\n").first(where: {
            $0.hasPrefix("ValueError: ") && ($0.contains("apps.yaml") || $0.contains("the apps file"))
        }) {
            let msg = line.dropFirst("ValueError: ".count)
            let what = msg.range(of: ": ").map { String(msg[$0.upperBound...]) } ?? String(msg)
            return L("Your apps file (~/.config/deskmind/apps.yaml) has a problem: %@. Fix it or move it away, then run it again.",
                     what, lang: lang)
        }
        if r.contains("screen recording") || r.contains("tcc") || r.contains("accessibility") && r.contains("not") {
            return L("The helper seems to have lost its permissions. Check “Accessibility” and “Screen Recording” on the home screen, then run it again.",
                     lang: lang)
        }
        if r.contains("quarantined") || r.contains("capture failed") || r.contains("see failed") {
            return L("Couldn't see the window this time (it happens when the Mac is busy). Wait a moment and run it again.",
                     lang: lang)
        }
        // The local model answered, about options it was not offered (hands acts only on offered ones, hands#14): not a
        // timeout, and nothing was done. What was wrong comes after "asked: ".
        if r.contains("answered outside what it was asked") {
            return L("The local model's answer wasn't one of the options it was given, so nothing was done. Please report it on GitHub so it can be fixed.",
                     lang: lang)
        }
        // The local model answered, and refused the step (HTTP 4xx): not a timeout, and running it again will not help.
        // What it said comes after " -- " (hands keeps the server's message).
        if r.contains("provider_unavailable"), r.range(of: #"http error 4\d\d"#, options: .regularExpression) != nil {
            let said = raw.components(separatedBy: " -- ").dropFirst().joined(separator: " -- ")
                .components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
            return said.isEmpty
                ? L("The local model couldn't handle this step. Please report it on GitHub so it can be fixed.", lang: lang)
                : L("The local model couldn't handle this step (%@). Please report it on GitHub so it can be fixed.", said, lang: lang)
        }
        if r.contains("provider_unavailable") || r.contains("timed out") || r.contains("connection refused")
            || r.contains("18850") {
            return L("The local model didn't answer in time. Check that “Local model” is ready on the home screen, then run it again.",
                     lang: lang)
        }
        if r.contains("no folder is attached") {
            return L("The instruction names files, but no folder is attached and none of them is open. Attach the folder they're in, or open them, then run it again.",
                     lang: lang)
        }
        if r.contains("a run is already in progress") {
            return L("The last task is still running. Wait for it to finish, or click “Stop” first.", lang: lang)
        }
        return L("This run hit an error. Run it again; if it keeps happening, report it on GitHub.", lang: lang)
    }
}
