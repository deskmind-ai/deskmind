// The live view's feed (A4, invariant 6): Shared/LiveFeed.swift's rules as a table, then live.watch itself
// (Helper/LiveWatch.swift) over a socket pair with a fake picture source -- watched → pictures; two watchers → one
// capture; gone and back within the grace → no stop; gone → pictures stop; the task's end → ended, none after; a
// picture taken of a window the run left → dropped; no permission → said, none taken.
import Foundation

enum LiveWatchTests {
    static func check(_ ok: Bool, _ what: String, file: StaticString = #file, line: UInt = #line) {
        DecisionTests.check(ok, "live-watch: " + what, file: file, line: line)
    }

    static func run() {
        DecisionTests.group("live-watch.feed"); feedTests()
        DecisionTests.group("live-watch.op"); opTests()
        DecisionTests.group("live-watch.static"); staticTests()
    }

    static func feedTests() {
        var f = LiveFeed()
        check(!f.captures("r", now: 0), "nobody watches: nothing captured")
        f.watch("r"); f.watch("r")
        check(f.captures("r", now: 0) && f.watchers["r"] == 2, "two watchers (the dock and the float during a flip): captured, once")
        f.unwatch("r", now: 1)
        check(f.captures("r", now: 1), "one left: still captured")
        f.unwatch("r", now: 2)
        check(f.captures("r", now: 2.4) && !f.captures("r", now: 2.5), "the last left: captured through the grace only")
        f.unwatch("r", now: 2); f.watch("r")
        check(f.captures("r", now: 9), "gone and back: captured again (never a negative count)")
        // the window and its epoch
        check(f.state("r", permission: true) == .noPicture, "no window yet: no picture yet")
        check(f.state("r", permission: false) == .noPermission, "no Screen Recording: said, apart from no picture")
        f.acted("r", window: 7)
        check(f.windows["r"]?.id == 7 && f.windows["r"]?.epoch == 1 && f.state("r", permission: true) == .streaming, "a step in window 7: streaming, epoch 1")
        f.acted("r", window: 7)
        check(f.windows["r"]?.epoch == 1, "the same window again: the same epoch")
        f.acted("r", window: 9)
        check(f.windows["r"]?.epoch == 2, "another window: the epoch moves on")
        f.end("r")
        check(!f.captures("r", now: 9) && f.state("r", permission: true) == .ended, "the task ended: nothing captured, ended")
        // the lines, and the cursor
        let line = LiveFeed.frameLine(run: "r", window: 9, epoch: 2, jpeg: Data([1, 2, 3]), width: 4, height: 3)
        check(LiveFeed.read(line) == .frame(run: "r", window: 9, epoch: 2, jpeg: Data([1, 2, 3]), width: 4, height: 3), "a picture's line read back")
        check(LiveFeed.read(LiveFeed.stateLine(run: "r", .noPermission)) == .state(run: "r", .noPermission), "a state's line read back")
        check(LiveFeed.read(["kind": "live.frame", "run_id": "r", "window": 1]) == nil, "a picture with no picture: nothing")
        let pic = CGSize(width: 200, height: 100)
        let cur = LiveFeed.cursor(pictureWindow: 9, stepWindow: 9, rectNorm: [0.5, 0.5, 0.1, 0.2], picture: pic)
        check(cur.map { abs($0.x - 110) < 0.001 && abs($0.y - 60) < 0.001 } == true, "the cursor at the target's middle: \(String(describing: cur))")
        check(LiveFeed.cursor(pictureWindow: 7, stepWindow: 9, rectNorm: [0.5, 0.5, 0.1, 0.2], picture: pic) == nil, "a step in another window: no cursor on this picture")
        check(LiveFeed.cursor(pictureWindow: 9, stepWindow: 9, rectNorm: [1.5, 0, 0.1, 0.1], picture: pic) == nil, "outside the window: none")
        check(LiveFeed.windowNumber("window:com.apple.TextEdit#812") == 812 && LiveFeed.windowNumber("file:/x") == nil, "a step's window number")
    }

    final class FakeSource: LiveFrameSource {
        private let lock = NSLock()
        private var _count = 0, _permission = true, _delay: Double = 0
        private var _onCapture: (() -> Void)?
        var delay: Double { get { lock.lock(); defer { lock.unlock() }; return _delay } set { lock.lock(); _delay = newValue; lock.unlock() } }
        var onCapture: (() -> Void)? { get { lock.lock(); defer { lock.unlock() }; return _onCapture } set { lock.lock(); _onCapture = newValue; lock.unlock() } }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        var permission: Bool { get { lock.lock(); defer { lock.unlock() }; return _permission } set { lock.lock(); _permission = newValue; lock.unlock() } }
        func capture(window: Int) -> (jpeg: Data, width: Int, height: Int)? {
            lock.lock(); _count += 1; lock.unlock()
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            onCapture?()
            return (Data([0xFF, 0xD8, UInt8(window & 0xFF)]), 8, 6)
        }
    }

    /// One watch over a socket pair: the helper's end served on its own thread; ours read line by line.
    final class Watch {
        let ours: Int32
        private var buf = Data()
        init(run: String) {
            var fds: [Int32] = [0, 0]
            _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
            ours = fds[1]
            let theirs = fds[0]
            Thread.detachNewThread { _ = LiveWatch.serve(["op": LiveWatch.op, "run_id": run], fd: theirs); Darwin.close(theirs) }
        }
        /// The lines that came within `seconds`.
        func lines(within seconds: Double) -> [[String: Any]] {
            var out: [[String: Any]] = []
            let until = Date().addingTimeInterval(seconds)
            var tmp = [UInt8](repeating: 0, count: 65536)
            while Date() < until {
                var p = pollfd(fd: ours, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 20) > 0 else { continue }
                let n = read(ours, &tmp, tmp.count)
                if n <= 0 { break }
                buf.append(contentsOf: tmp[0..<n])
                while let nl = buf.firstIndex(of: 0x0A) {
                    if let o = (try? JSONSerialization.jsonObject(with: buf[buf.startIndex..<nl])) as? [String: Any] { out.append(o) }
                    buf.removeSubrange(buf.startIndex...nl)
                }
            }
            return out
        }
        func close() { Darwin.close(ours) }
    }

    static func frames(_ ls: [[String: Any]]) -> [LiveFeed.Line] { ls.compactMap(LiveFeed.read).filter { if case .frame = $0 { return true }; return false } }
    static func states(_ ls: [[String: Any]]) -> [LiveFeed.State] { ls.compactMap(LiveFeed.read).compactMap { if case .state(_, let s) = $0 { return s }; return nil } }

    static func opTests() {
        let fake = FakeSource()
        LiveWatch.source = fake
        LiveWatch.reset()
        // watched, no window yet: told so, nothing taken
        let a = Watch(run: "run_a")
        var got = a.lines(within: 0.4)
        check(states(got).first == .noPicture && frames(got).isEmpty && fake.count == 0, "no window yet: no picture yet, nothing taken: \(states(got))")
        // a step in a window: pictures, of it
        LiveWatch.note(run: "run_a", ["event": "step", "object": "window:com.apple.TextEdit#812"])
        got = a.lines(within: 0.8)
        let fs = frames(got)
        check(fs.count >= 2, "a step in a window: pictures, about 5 a second: \(fs.count)")
        if case .frame(_, let w, let e, _, _, _)? = fs.first { check(w == 812 && e == 1, "of window 812, epoch 1") }
        // a second watcher (the float, while the dock still watches): one capture, both get it
        let b = Watch(run: "run_a")
        let c0 = fake.count
        let (ga, gb) = (a.lines(within: 0.6), b.lines(within: 0.01))
        let taken = fake.count - c0
        check(taken <= 5, "two watchers: one capture a picture, not two: \(taken) in 0.6 s")
        check(frames(ga).count >= 1 && (frames(gb).count >= 1 || frames(b.lines(within: 0.4)).count >= 1), "both get the pictures")
        // one leaves, comes back within the grace: never stopped
        b.close()
        let b2 = Watch(run: "run_a")
        Thread.sleep(forTimeInterval: 0.3)
        check(LiveWatch.snapshot.captures("run_a", now: Date().timeIntervalSince1970), "gone and back within the grace: still captured")
        // all gone: pictures stop after the grace
        a.close(); b2.close()
        Thread.sleep(forTimeInterval: LiveFeed.grace + 0.4)
        let c1 = fake.count
        Thread.sleep(forTimeInterval: 0.5)
        check(fake.count == c1, "nobody watches past the grace: no picture taken (\(fake.count - c1))")
        // the task's end: ended, no picture after
        let d = Watch(run: "run_a")
        _ = d.lines(within: 0.4)
        LiveWatch.note(run: "run_a", ["event": "task_done"])
        got = d.lines(within: 0.3)
        let c2 = fake.count
        let after = d.lines(within: 0.5)
        check(states(got).contains(.ended) && frames(after).isEmpty && fake.count <= c2 + 1, "the task ended: said, and no picture after it")
        d.close()
        // a picture of a window the run has left: dropped
        LiveWatch.reset()
        LiveWatch.note(run: "run_b", ["event": "step", "object": "window:x#5"])
        fake.delay = 0.15
        fake.onCapture = { LiveWatch.note(run: "run_b", ["event": "step", "object": "window:x#6"]) }
        let e = Watch(run: "run_b")
        got = e.lines(within: 0.8)
        fake.onCapture = nil; fake.delay = 0
        let windows = frames(got).compactMap { (l: LiveFeed.Line) -> Int? in if case .frame(_, let w, _, _, _, _) = l { return w }; return nil }
        check(!windows.contains(5), "a picture taken of window 5 while the run moved to 6: dropped: \(windows)")
        e.close()
        // no Screen Recording: said, nothing taken
        LiveWatch.reset()
        fake.permission = false
        LiveWatch.note(run: "run_c", ["event": "step", "object": "window:x#3"])
        let c3 = fake.count
        let g = Watch(run: "run_c")
        got = g.lines(within: 0.5)
        check(states(got).first == .noPermission && frames(got).isEmpty && fake.count == c3, "no permission: said (not 'no picture yet'), nothing taken")
        g.close()
        fake.permission = true
        Thread.sleep(forTimeInterval: LiveFeed.grace + 0.3)
        LiveWatch.source = nil
        LiveWatch.reset()
    }

    /// Never on disk: the feed's files write no file and log no picture.
    static func staticTests() {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for f in ["Helper/LiveWatch.swift", "Helper/LiveCapture.swift", "Shared/LiveFeed.swift"] {
            let code = ((try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) ?? "")
                .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            let writes = ["write(to:", "createFile", "FileHandle", "fopen", "NSLog", "print(", "UIEvents.record", "CGImageDestinationCreateWithURL", "FileManager"]
            check(!code.isEmpty && writes.allSatisfy { !code.contains($0) }, "\(f): no file, log or UI log line of a picture: \(writes.filter { code.contains($0) })")
        }
    }
}
