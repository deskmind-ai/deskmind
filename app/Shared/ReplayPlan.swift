// Which steps a replay and its GIF show (Main/Replay.swift, Main/ReplayGIF.swift): what needs no screen, so
// tests/DecisionTests.swift checks it.

import Foundation

/// A step as replayed: its screenshot and what it did, in words.
struct ReplayFrame: Identifiable, Sendable {
    let id = UUID()
    let n: Int
    let image: String
    let words: String
}

enum ReplayPlan {
    /// A GIF shows at most this many steps: the last ones.
    static let gifSteps = 16

    /// The steps that kept a screenshot still on disk ("Clear all" deletes them), in order. None: no Replay, no GIF.
    static func frames(_ steps: [(n: Int, shot: String, words: String)],
                       exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [ReplayFrame] {
        steps.filter { !$0.shot.isEmpty && exists($0.shot) }.map { ReplayFrame(n: $0.n, image: $0.shot, words: $0.words) }
    }

    static func gifFrames(_ all: [ReplayFrame]) -> [ReplayFrame] { Array(all.suffix(gifSteps)) }
}
