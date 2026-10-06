// The order of a run's two feeds (Helper/Runner.swift). A question arrives on hands' stdout the moment it is asked;
// steps come from the trace file, which is polled. hands flushes each step to the trace before it asks, so a question
// passed on only after the trace has been read up to that moment can never be followed by a step taken before it --
// which would close it (a step after a question means it was answered). Foundation only, so tests/DecisionTests.swift
// checks the ordering.

import Foundation

final class QuestionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [[String: Any]] = []
    private let wake = DispatchSemaphore(value: 0)

    /// A question, from the stdout reader: held until the next cycle, which it starts at once.
    func asked(_ q: [String: Any]) {
        lock.lock(); pending.append(q); lock.unlock()
        wake.signal()
    }

    /// One turn of the run's loop: wait up to `timeout` (less when a question comes), read the trace (`poll`), then
    /// pass on the questions that had come before that read. A question that comes during the read waits for the
    /// next turn, when the steps before it have certainly been read.
    func cycle(timeout: Double, poll: () -> Void, pass: ([String: Any]) -> Void) {
        _ = wake.wait(timeout: .now() + timeout)
        lock.lock(); let questions = pending; pending.removeAll(); lock.unlock()
        poll()
        questions.forEach(pass)
    }
}
