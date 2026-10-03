// Which host a model download uses: Hugging Face first, the mirror (ModelScope) once Hugging Face has failed or
// stalled -- and from then on for the files after it too, since a network that cannot reach one file cannot reach the
// next. Foundation only, so the unit tests (tests/DecisionTests.swift) run it; ModelDownloader acts on it.
//
// The mirror serves the same bytes: the manifest's SHA-256 checks a file whichever host it came from.

import Foundation

enum DownloadSource {
    /// Seconds a file is given on Hugging Face, and the bytes it must have brought by then, before it is fetched from
    /// the mirror instead: a connection that trickles never errors, and 5 GB at 50 KB/s is more than a day.
    static let window: TimeInterval = 30
    static let minimumBytes: Int64 = 6_000_000

    static func url(primary: String, mirror: String?, usingMirror: Bool) -> String {
        usingMirror ? (mirror ?? primary) : primary
    }

    /// After a failure (an error, an HTTP status, a checksum): whether to fetch the same file again from its mirror.
    static func shouldSwitch(hasMirror: Bool, usingMirror: Bool) -> Bool { hasMirror && !usingMirror }

    /// Whether a download from Hugging Face is too slow to keep: `elapsed` seconds in, `bytes` received.
    static func stalled(elapsed: TimeInterval, bytes: Int64, fileSize: Int64) -> Bool {
        elapsed >= window && bytes < min(minimumBytes, fileSize)
    }
}
