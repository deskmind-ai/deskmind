// Installing and starting DeskMind Hands: the one routine the app's launch, the nested copy's hand-over, the Restart
// button and the restart for a Screen Recording grant all use (decisions in Shared/HelperLocation.swift).
//
// The copy that runs is the installed one in Application Support. It is made from the copy shipped inside
// DeskMind.app whenever they differ -- version, build, the runtime's stamp or the executable itself, older or newer
// -- by copying to a temporary name and swapping it in. The copy keeps its signature, and TCC follows the designated
// requirement (bundle id and Team ID), so a replaced copy keeps the permissions already granted.
//
// It is started by /usr/bin/open in a detached shell, as a new instance: that outlives the process that asks (a
// helper restarting itself, the nested copy handing over), and it does not mistake the asking process -- same bundle
// id -- for the app to open. NSWorkspace did both, and started nothing right after a fresh copy (rc.2 e2e).

import CryptoKit
import Foundation

enum HelperInstaller {
    static func stamp(of bundle: String) -> HelperLocation.Stamp? {
        let fm = FileManager.default
        guard let info = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist"),
              let exe = fm.contents(atPath: bundle + "/Contents/MacOS/DeskMindHands") else { return nil }
        let runtime = (try? String(contentsOfFile: bundle + "/Contents/Resources/runtime/hands/.version", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return HelperLocation.Stamp(version: info["CFBundleShortVersionString"] as? String ?? "",
                                    build: info["CFBundleVersion"] as? String ?? "", runtime: runtime,
                                    executable: SHA256.hash(data: exe).map { String(format: "%02x", $0) }.joined())
    }

    /// Make the installed copy the shipped one. Returns whether it changed.
    @discardableResult
    static func ensureInstalled(shipped: String, installed: String) throws -> Bool {
        guard HelperLocation.needsInstall(shipped: stamp(of: shipped), installed: stamp(of: installed)) else { return false }
        let fm = FileManager.default
        try fm.createDirectory(atPath: (installed as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let staging = installed + ".new"
        try? fm.removeItem(atPath: staging)
        try fm.copyItem(atPath: shipped, toPath: staging)
        if fm.fileExists(atPath: installed) {
            _ = try fm.replaceItemAt(URL(fileURLWithPath: installed), withItemAt: URL(fileURLWithPath: staging))
        } else {
            try fm.moveItem(atPath: staging, toPath: installed)
        }
        return true
    }

    /// Start the installed copy as a new instance after `delay` seconds, from a detached shell that outlives the caller.
    static func launch(_ installed: String, after delay: Double = 0) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep \(delay); exec /usr/bin/open -n -g \"$0\"", installed]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
