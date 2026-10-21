// The helper's chat-session ops (Helper/SessionHost.swift) on a socket of their own, for tests/e2e/session.sh: the
// same SessionHost.serve the helper's socket calls, with `harness.mjs session` processes on the simulated computer
// and a fake model service on localhost (fake_model.py). Nothing on this Mac is driven; nothing touches the real
// Application Support folder.
//
//   SessionE2E serve <socket> <dir> <node> <harness.mjs> <idle seconds>   (LOCAL_URL / LOCAL_API_KEY passed on)
//   SessionE2E lock <dir>                                                  the machine lock: take, busy, stale
//
// `lock` prints PASS or FAIL per check; its exit status is the number of failures.

import AppKit
import Foundation

@main
enum SessionE2E {
    nonisolated(unsafe) static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print("\(ok ? "PASS" : "FAIL") \(what)")
        if !ok { failures += 1 }
    }

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let a = CommandLine.arguments
        if a.count == 3, a[1] == "lock" { lock(dir: a[2]) }
        guard a.count == 7, a[1] == "serve" else {
            print("usage: SessionE2E serve <socket> <dir> <node> <harness.mjs> <idle s> | lock <dir>"); exit(2)
        }
        let dir = URL(fileURLWithPath: a[3])
        let pass = ProcessInfo.processInfo.environment.filter { ["LOCAL_URL", "LOCAL_API_KEY", "TMPDIR"].contains($0.key) }
        SessionHost.setup = .init(node: URL(fileURLWithPath: a[4]), bundle: URL(fileURLWithPath: a[5]), dir: dir, cwd: nil,
                                  logs: dir.appendingPathComponent("logs"),
                                  environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"].merging(pass) { x, _ in x } },
                                  prepare: {}, idleSeconds: Double(a[6]) ?? 300, driver: "sim")
        serve(path: a[2])
    }

    /// The helper's accept loop (HandsHelper.serve), with only the session ops behind it.
    static func serve(path: String) {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
        guard bound, listen(fd, 8) == 0 else { print("cannot listen on \(path)"); exit(1) }
        print("listening"); fflush(stdout)
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { continue }
            DispatchQueue.global().async {
                defer { close(c) }
                var data = Data()
                var buf = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(c, &buf, buf.count)
                    if n <= 0 { break }
                    data.append(buf, count: n)
                    if buf[..<n].contains(0x0A) { break }
                }
                let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                if SessionHost.serve(req, fd: c) { return }
                _ = SessionHost.writeAll(c, Data(#"{"ok":false,"error":"unknown op"}"#.utf8 + [0x0A]))
            }
        }
    }

    /// ComputerLock against a lock file in `dir`: taken when free, busy while a live process holds it (a session, or
    /// only its executor), taken over when its holders are gone, and released only while it is still ours.
    static func lock(dir: String) {
        SessionHost.setup = .init(node: URL(fileURLWithPath: "/"), bundle: URL(fileURLWithPath: "/"), dir: URL(fileURLWithPath: dir), cwd: nil,
                                  logs: URL(fileURLWithPath: dir), environment: { [:] }, prepare: {}, idleSeconds: 300)
        let file = ComputerLock.file.path
        try? FileManager.default.removeItem(atPath: file)
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        func content() -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file)))) as? [String: Any] ?? [:]
        }
        guard case .taken(let release) = ComputerLock.take(runID: "run_t") else { check(false, "a free lock is taken"); exit(1) }
        check(content()["pid"] as? Int == me && content()["run_id"] as? String == "run_t", "it names this process: \(content())")
        check(ComputerLock.holder() != nil, "held")
        if case .busy = ComputerLock.take(runID: "run_2") { check(true, "a second take is busy") } else { check(false, "a second take is busy") }
        release()
        check(!FileManager.default.fileExists(atPath: file), "released")
        // a lock whose holders are gone (a pid that is no process)
        var dead: Int32 = 99_999
        while ComputerLock.alive(dead) { dead -= 1 }
        try? #"{"pid":\#(dead),"session_id":"ses_old","run_id":"run_old"}"#.write(toFile: file, atomically: true, encoding: .utf8)
        check(ComputerLock.holder() == nil, "a dead holder holds nothing")
        if case .taken(let r) = ComputerLock.take(runID: "run_3") {
            check(content()["run_id"] as? String == "run_3", "a stale lock is taken over"); r()
        } else { check(false, "a stale lock is taken over") }
        // a live holder: the session (pid 1 stands for a live process this user cannot signal), or only its executor
        for (text, what) in [(#"{"pid":1,"session_id":"s","run_id":"r"}"#, "a live session"),
                             (#"{"pid":\#(dead),"session_id":"s","run_id":"r","executor_pid":1}"#, "a killed session's executor still stopping")] {
            try? text.write(toFile: file, atomically: true, encoding: .utf8)
            if case .busy = ComputerLock.take(runID: "run_4") { check(true, "busy while \(what) holds it") } else { check(false, "busy while \(what) holds it") }
            check((try? String(contentsOfFile: file, encoding: .utf8)) == text, "\(what): its lock untouched")
        }
        // released only while ours: a lock replaced meanwhile is left alone
        if case .taken(let r) = { try? FileManager.default.removeItem(atPath: file); return ComputerLock.take(runID: "run_5") }() {
            let other = #"{"pid":1,"session_id":"other","run_id":"r"}"#
            try? other.write(toFile: file, atomically: true, encoding: .utf8)
            r()
            check((try? String(contentsOfFile: file, encoding: .utf8)) == other, "a release leaves another's lock")
        } else { check(false, "taken again") }
        try? FileManager.default.removeItem(atPath: file)
        print(failures == 0 ? "lock: all passed" : "lock: \(failures) failed")
        exit(Int32(min(failures, 100)))
    }
}
