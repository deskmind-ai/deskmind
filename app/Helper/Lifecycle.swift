// How the helper ends on SIGTERM (launchd stopping it, a replaced helper). Not in a signal handler: one runs on
// whatever the thread was doing, and a SIGTERM that came while AppKit was quitting (inside the Objective-C runtime's
// lock) made the handler's first message send abort the helper (os_unfair_lock_recursive_abort under BrainServer.stop,
// 10-04). A dispatch source runs it later, on a queue of its own, and exit runs the atexit hooks that stop the model
// servers. tests/e2e/helper.sh quits an app while sending it SIGTERM, again and again, through this code.

import Foundation

enum Lifecycle {
    /// Kept for the life of the process: a dispatch source that is released stops delivering.
    nonisolated(unsafe) private static var sigterm: DispatchSourceSignal?

    static func exitOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        term.setEventHandler { exit(0) }
        term.resume()
        sigterm = term
    }
}
