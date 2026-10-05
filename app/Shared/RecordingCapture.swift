// How a run is recorded (Helper/ScreenRecorder.swift), as far as it needs no screen: which capture at what rate, when
// the next picture is due, and whether a picture is written. Foundation only, so tests/DecisionTests.swift checks it.

import Foundation

enum RecordingCapture {
    struct Mode: Equatable {
        let fps: Double
        /// A capture stream (ScreenCaptureKit writes the movie), or one-shot screenshots written by the recorder.
        let stream: Bool
        var name: String { stream ? "stream" : "one-shot screenshots" }
    }

    /// One-shot screenshots ten a second: a running stream slows the models down (about 10% a decision, against about
    /// 3%). "Smooth Recordings": the stream at 30 a second, for footage where motion matters. A full-resolution
    /// one-shot takes about 80 ms, so more than about 12 a second is out of its reach.
    static func mode(smooth: Bool) -> Mode {
        smooth ? Mode(fps: 30, stream: true) : Mode(fps: 10, stream: false)
    }

    /// When the picture after one due at `due` is due, the clock reading `now`: one interval on, or now if the loop
    /// has fallen behind -- a slow picture is not made up for with a burst.
    static func nextDue(after due: Double, now: Double, fps: Double) -> Double {
        max(due + 1 / fps, now)
    }

    /// Whether a picture taken `at` seconds into the movie is written: only after the last one written, while the
    /// movie still takes pictures (cleared before it is finished) and the writer is ready for more.
    static func shouldAppend(at: Double, last: Double, accepting: Bool, ready: Bool) -> Bool {
        accepting && ready && at > last
    }
}
