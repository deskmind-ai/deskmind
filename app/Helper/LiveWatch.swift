// live.watch {run_id} (A4): the pictures of the window a run acts in, to the main app, only while it watches
// (Shared/LiveFeed.swift has the rules and the table). Its own connection, as sessions.watch: the helper writes
// live.state and live.frame lines until the app closes it. The pictures are taken by `source` (Helper/LiveCapture.swift,
// ScreenCaptureKit; a test's own), kept in memory only, and sent as they are: nothing here writes a file or logs a
// picture (ShellTests checks it).
//
// Who acts where: the runs' own events, as SessionHost hands them to the live card (`note`): a step in a window moves
// the run's target there; the task's end ends it.

import Foundation

/// What takes a run's pictures.
protocol LiveFrameSource: AnyObject {
    /// Screen Recording is granted (no picture can be taken without it).
    var permission: Bool { get }
    /// One picture of the window `window` (a CGWindow number) as JPEG, and the part of the window it shows ([x, y, w, h]
    /// of it, 0–1), or nil (gone, hidden, not capturable).
    func capture(window: Int) -> (jpeg: Data, width: Int, height: Int, visible: [Double])?
}

enum LiveWatch {
    static let op = LiveFeed.op

    private static let lock = NSLock()
    nonisolated(unsafe) private static var feed = LiveFeed()
    nonisolated(unsafe) private static var conns: [String: [Conn]] = [:]
    nonisolated(unsafe) private static var loops: Set<String> = []
    nonisolated(unsafe) private static var told: [String: LiveFeed.State] = [:]
    /// Set at the helper's start (ScreenLiveSource); a test sets its own. None: nothing is captured. (Under `lock`:
    /// a capture thread reads it while it may be set.)
    nonisolated(unsafe) private static var _source: LiveFrameSource?
    static var source: LiveFrameSource? {
        get { lock.lock(); defer { lock.unlock() }; return _source }
        set { lock.lock(); _source = newValue; lock.unlock() }
    }
    nonisolated(unsafe) static var now: () -> Double = { Date().timeIntervalSince1970 }

    /// One watching connection: its lines in order, off the caller's thread; one that does not take a line within the
    /// socket's send timeout is dropped (its read side shut, so its own thread ends the watch).
    final class Conn {
        let fd: Int32
        private let queue = DispatchQueue(label: "ai.deskmind.hands.live.watch")
        private var closed = false   // on `queue`
        init(fd: Int32) { self.fd = fd }
        func send(_ o: [String: Any], now: Bool = false) {
            guard var d = try? JSONSerialization.data(withJSONObject: o) else { return }
            d.append(0x0A)
            let write = { [self] in
                guard !closed else { return }
                let ok = d.withUnsafeBytes { buf -> Bool in
                    var off = 0
                    while off < buf.count {
                        let n = Darwin.write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
                        if n < 0 && errno == EINTR { continue }
                        if n <= 0 { return false }
                        off += n
                    }
                    return true
                }
                if !ok { closed = true; Darwin.shutdown(fd, SHUT_RDWR) }
            }
            if now { write() } else { queue.async(execute: write) }
        }
        /// A picture: only the newest waits (#125 review) -- a newer one replaces one not sent yet, so a slow watcher never
        /// builds a queue of old pictures.
        private let frameLock = NSLock()
        private var waiting: [String: Any]?
        func sendFrame(_ o: [String: Any]) {
            frameLock.lock()
            let scheduled = waiting != nil
            waiting = o
            frameLock.unlock()
            guard !scheduled else { return }
            queue.async { [self] in
                frameLock.lock(); let o = waiting; waiting = nil; frameLock.unlock()
                if let o { send(o, now: true) }
            }
        }
        /// No line is written after this returns.
        func finish() { queue.sync { closed = true } }
    }

    // MARK: the runs' events

    /// An event of a running task (SessionHost's UI hooks, every live task's): a step in a window, the task's end.
    static func note(run: String, _ ev: [String: Any]) {
        switch ev["event"] as? String ?? ev["kind"] as? String {
        case "step":
            guard let w = LiveFeed.windowNumber(ev["object"] as? String) else { return }
            lock.lock(); feed.acted(run, window: w); lock.unlock()
        case "task_done", "done":
            ended(run)
        default: break
        }
    }

    /// The run's task ended (or the helper goes): its watchers are told, nothing more is captured.
    static func ended(_ run: String) {
        lock.lock()
        feed.end(run)
        let cs = conns[run] ?? []
        told[run] = .ended
        lock.unlock()
        for c in cs { c.send(LiveFeed.stateLine(run: run, .ended)) }
    }

    // MARK: the op

    /// live.watch: true when it was this op (it returns when the app closed the connection).
    static func serve(_ req: [String: Any], fd: Int32) -> Bool {
        guard req["op"] as? String == op else { return false }
        guard let run = req["run_id"] as? String, !run.isEmpty else {
            let c = Conn(fd: fd); c.send(["ok": false, "error": "live.watch needs run_id"]); c.finish(); return true
        }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let c = Conn(fd: fd)
        // registered first: the capture loop finds it watched before it looks
        lock.lock()
        feed.watch(run)
        conns[run, default: []].append(c)
        let src = _source
        lock.unlock()
        let permission = src?.permission ?? false
        lock.lock()
        let st = feed.state(run, permission: permission)
        let start = !loops.contains(run) && st != .ended
        if start { loops.insert(run) }
        lock.unlock()
        c.send(LiveFeed.stateLine(run: run, st))
        if start { Thread.detachNewThread { capture(run) } }
        // until the app closes it (or a write to it failed and shut it)
        var buf = [UInt8](repeating: 0, count: 256)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
        }
        lock.lock()
        conns[run]?.removeAll { $0 === c }
        if conns[run]?.isEmpty == true { conns[run] = nil }
        feed.unwatch(run, now: now())
        lock.unlock()
        c.finish()
        return true
    }

    /// The run's pictures, while the feed says it is captured (its own thread; one per run).
    private static func capture(_ run: String) {
        while true {
            lock.lock()
            let src = _source
            lock.unlock()
            let permission = src?.permission ?? false
            lock.lock()
            guard feed.captures(run, now: now()) else { loops.remove(run); lock.unlock(); return }
            let st = feed.state(run, permission: permission)
            let target = feed.windows[run]
            let cs = conns[run] ?? []
            let say = told[run] != st && st != .streaming
            if say { told[run] = st }
            lock.unlock()
            if say { for c in cs { c.send(LiveFeed.stateLine(run: run, st)) } }
            let taken = st == .streaming ? target.flatMap { t in src?.capture(window: t.id).map { (t, $0) } } : nil
            if st == .streaming, taken == nil {
                // (#125 Codex: the window cannot be taken -- gone, hidden, not capturable: watchers are told, once, so an
                // older picture is never shown as live)
                lock.lock()
                let say = told[run] != .noPicture && feed.captures(run, now: now())
                if say { told[run] = .noPicture }
                let cs2 = conns[run] ?? []
                lock.unlock()
                if say { for c in cs2 { c.send(LiveFeed.stateLine(run: run, .noPicture)) } }
            } else if let (t, pic) = taken {
                // still wanted, and still of that window (the run may have moved on, or ended, meanwhile)?
                lock.lock()
                let keep = feed.captures(run, now: now()) && feed.windows[run]?.epoch == t.epoch
                let now = conns[run] ?? []
                if keep { told[run] = .streaming }
                lock.unlock()
                if keep {
                    let line = LiveFeed.frameLine(run: run, window: t.id, epoch: t.epoch, jpeg: pic.jpeg, width: pic.width, height: pic.height, visible: pic.visible)
                    for c in now { c.sendFrame(line) }
                }
            }
            Thread.sleep(forTimeInterval: 1 / LiveFeed.fps)
        }
    }

    /// Tests: the feed as it is now.
    static var snapshot: LiveFeed { lock.lock(); defer { lock.unlock() }; return feed }
    /// Tests: start afresh.
    static func reset() { lock.lock(); feed = LiveFeed(); conns = [:]; told = [:]; lock.unlock() }
}
