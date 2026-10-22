// The machine lock: one computer task at a time on this Mac, whoever starts it -- this helper (op run on the harness,
// `hands do`, the answer to a finished run's result card, 「清除全部」) or a chat session (the harness, whose
// src/session/computer.ts is the same protocol in TypeScript). The protocol and the file format are the harness's
// docs/protocol.md 「电脑锁」; SessionWire.Holder / SessionWire.held are its pure parts.
//
// - `sessions/computer.guard`: an exclusive flock on it around every read-modify-write of the lock (the harness takes
//   the same flock with O_EXLOCK): a check and the write it decides are one step, across processes.
// - `sessions/computer.lock`: the holder, replaced whole. The holder is the executor's process group (the executor
//   is started as its leader: Foundation's Process gives a child a group of its own) and is held while any process of
//   the group lives, whoever started it -- a helper killed outright, or an executor that exited leaving a child, still
//   holds the Mac.
// - acting until task_done; lingering from then on (written before task_done is passed on). A new task: acting →
//   busy; lingering → that group is ended (its undo expires) and the lock is the new task's; it will not end →
//   refused (previous_run_alive). An undo only for its own lingering run, acting again until its result_response.

import Foundation

enum ComputerLock {
    static var sessions: URL { SessionHost.setup.dir.appendingPathComponent("sessions") }
    static var file: URL { sessions.appendingPathComponent("computer.lock") }
    static var guardFile: URL { sessions.appendingPathComponent("computer.guard") }

    /// `f` with the guard's flock held; `otherwise` when the guard cannot be opened (nothing decided unguarded).
    static func guarded<T>(otherwise: T, _ f: () -> T) -> T {
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(guardFile.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            NSLog("DeskMind Hands: computer lock: cannot open its guard (\(String(cString: strerror(errno))))")
            return otherwise
        }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
        return f()
    }

    /// How long an orphaned acting holder keeps the Mac before the next task ends it (as long as a stop is waited for).
    static let orphanSeconds: Double = 12

    // MARK: the system

    static func alive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

    /// A process's start time, seconds since 1970; nil when it is gone or a zombie.
    static func startOf(_ pid: Int32) -> Int? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != SZOMB else { return nil }
        return Int(info.pbi_start_tvsec)
    }

    /// Some process of group `pgid` lives (a zombie acts no more).
    static func groupAlive(_ pgid: Int32) -> Bool {
        guard pgid > 1 else { return false }
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), nil, 0)
        guard bytes > 0 else { return false }
        var buf = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 32)
        let got = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return got > 0 && buf.prefix(Int(got) / MemoryLayout<pid_t>.size).contains { $0 > 0 && startOf($0) != nil }
    }

    static func read() -> SessionWire.Holder? {
        SessionWire.Holder.parse(try? String(contentsOf: file, encoding: .utf8), alive: alive)
    }

    static func held(_ h: SessionWire.Holder) -> Bool {
        SessionWire.held(h, groupAlive: groupAlive, alive: alive, startOf: startOf)
    }

    @discardableResult
    private static func write(_ h: SessionWire.Holder) -> Bool {
        let tmp = "\(file.path).\(getpid()).\(UUID().uuidString.lowercased().prefix(8))"
        guard FileManager.default.createFile(atPath: tmp, contents: h.json, attributes: [.posixPermissions: 0o600]) else {
            NSLog("DeskMind Hands: computer lock: cannot write \(tmp)"); return false
        }
        if rename(tmp, file.path) != 0 { unlink(tmp); return false }
        return true
    }

    /// End a lingering holder's tree: SIGTERM to its group, then SIGKILL. True once it is gone.
    static func endTree(_ h: SessionWire.Holder, term: Double = 1.5, kill wait: Double = 1,
                        signal: (Int32, Int32) -> Int32 = { Darwin.kill($0, $1) }) -> Bool {
        guard h.pgid > 1 else { return !held(h) }
        func gone(within s: Double) -> Bool {
            let until = Date().addingTimeInterval(s)
            while held(h) { if Date() >= until { return false }; Thread.sleep(forTimeInterval: 0.02) }
            return true
        }
        _ = signal(-h.pgid, SIGTERM)
        if gone(within: term) { return true }
        _ = signal(-h.pgid, SIGKILL)
        return gone(within: wait)
    }

    // MARK: the protocol

    /// `failed`: the lock could not be kept (its guard, or its file, could not be written): nothing runs.
    enum Acquired { case ok(SessionWire.Holder?), busy(SessionWire.Holder), alive(SessionWire.Holder), failed(String) }

    /// Inside the guard: may a new task take the Mac? nil: yes (nothing holds it, or what held it was ended); else the
    /// refusal. A holder acting → busy (an orphaned one -- owner and leader gone, a process of its group up -- is
    /// marked and ended `orphanSeconds` later); lingering → its tree ended (its undo expires), or `alive`.
    private static func admit(term: Double, kill: Double, now: Double?, signal: (Int32, Int32) -> Int32) -> Acquired? {
        guard var h = read(), held(h) else { return nil }
        if h.acting {
            guard h.pgid > 0, !alive(h.owner), startOf(h.pid) == nil else { return .busy(h) }
            let t = now ?? Date().timeIntervalSince1970
            guard let since = h.orphanSince else { h.orphanSince = t; write(h); return .busy(h) }
            if t - since < orphanSeconds { return .busy(h) }
            NSLog("DeskMind Hands: run \(h.runID)'s owner and leader are gone, its group still up: ending it")
        } else {
            NSLog("DeskMind Hands: a new task on this Mac: ending the lingering run \(h.runID) (its undo expires)")
        }
        return endTree(h, term: term, kill: kill, signal: signal) ? nil : .alive(h)
    }

    /// Name the group `pid` in the lock (generation `gen`); a write that fails ends that group (it must not act
    /// unrecorded: `hands do` has its task in its arguments).
    private static func record(_ runID: String, by: String, pid: pid_t, gen: Int, signal: (Int32, Int32) -> Int32) -> Acquired {
        let h = SessionWire.Holder(state: "acting", pgid: pid, pid: pid, start: startOf(pid) ?? 0, runID: runID, sessionID: "",
                                   by: by, owner: getpid(), t: Date().timeIntervalSince1970, gen: gen)
        guard write(h) else { _ = signal(-pid, SIGKILL); return .failed("the machine lock could not be written") }
        return .ok(h)
    }

    /// Take the Mac for a new task, in one guarded step (admit), then `spawn` starts the executor (nil: it could not
    /// start, nothing is written) and the lock names its group, acting, generation 1. The executor is sent its task only
    /// after this returns.
    static func acquire(runID: String, by: String, term: Double = 1.5, kill: Double = 1, now: Double? = nil,
                        signal: (Int32, Int32) -> Int32 = { Darwin.kill($0, $1) }, spawn: () -> pid_t?) -> Acquired {
        guarded(otherwise: .failed("the machine lock's guard cannot be opened")) {
            if let refused = admit(term: term, kill: kill, now: now, signal: signal) { return refused }
            guard let pid = spawn() else { return .ok(nil) }
            return record(runID, by: by, pid: pid, gen: 1, signal: signal)
        }
    }

    /// Take the Mac before anything of the task touches the desktop (a run that must open its apps' windows before its
    /// process starts): the same step as acquire, but the lock names this helper itself (pgid 0: held while the
    /// helper lives), acting. Then `commit` starts the process, or `cancel` lets the Mac go.
    static func reserve(runID: String, by: String, term: Double = 1.5, kill: Double = 1, now: Double? = nil,
                        signal: (Int32, Int32) -> Int32 = { Darwin.kill($0, $1) }) -> Acquired {
        guarded(otherwise: .failed("the machine lock's guard cannot be opened")) {
            if let refused = admit(term: term, kill: kill, now: now, signal: signal) { return refused }
            let h = SessionWire.Holder(state: "acting", pgid: 0, pid: 0, start: 0, runID: runID, sessionID: "", by: by,
                                       owner: getpid(), t: Date().timeIntervalSince1970, gen: 1)
            return write(h) ? .ok(h) : .failed("the machine lock could not be written")
        }
    }

    /// The reserved Mac to the task's process: only while the lock is still exactly that reservation (`r`), then
    /// `spawn` starts it and the lock names its group (the next generation). nil from `spawn`: the reservation is let go.
    static func commit(_ r: SessionWire.Holder, signal: (Int32, Int32) -> Int32 = { Darwin.kill($0, $1) },
                       spawn: () -> pid_t?) -> Acquired {
        guarded(otherwise: .failed("the machine lock's guard cannot be opened")) {
            guard read() == r else { return .failed("the machine lock's reservation was lost") }
            guard let pid = spawn() else { unlink(file.path); return .ok(nil) }
            return record(r.runID, by: r.by, pid: pid, gen: r.gen + 1, signal: signal)
        }
    }

    /// A reservation not used (refused, stopped before its launch): the Mac let go, if the lock is still exactly it.
    static func cancel(_ r: SessionWire.Holder) {
        guarded(otherwise: ()) { if read() == r { unlink(file.path) } }
    }

    /// Compare-and-set: the lock goes from exactly `from` (its run, group, state and generation, as its writer last
    /// saw it) to `state`, the next generation. nil when the lock is no longer `from` (an undo, a new task, an end
    /// came between): nothing is written over what it is now.
    private static func transition(_ from: SessionWire.Holder, to state: String) -> SessionWire.Holder? {
        guarded(otherwise: nil) {
            guard var h = read(), h.runID == from.runID, h.pgid == from.pgid, h.state == from.state, h.gen == from.gen else { return nil }
            h.state = state; h.gen += 1; h.t = Date().timeIntervalSince1970
            return write(h) ? h : nil
        }
    }

    /// Its task_done (or an undo's result_response): it acts no more; its result card may be answered, and a new task
    /// may end it. Only from the acting holder `from` it last wrote.
    @discardableResult
    static func linger(_ from: SessionWire.Holder) -> SessionWire.Holder? {
        from.acting ? transition(from, to: "lingering") : nil
    }

    /// `ok`: the lock, acting again for the undo. `failed`: the lock could not be read or written.
    enum Undo { case ok(SessionWire.Holder), busy, expired, failed }

    /// An answer to a finished run's result card: only while the lock is still exactly its lingering holder `from`;
    /// it acts again (the next generation). `expired`: another task started since (or its tree is gone); `busy`: the
    /// lock changed under it otherwise (an answer of it is being carried out).
    static func undo(_ from: SessionWire.Holder) -> Undo {
        guarded(otherwise: .failed) {
            guard var h = mine(read(), from.runID, from.pgid), held(h) else { return .expired }
            guard !h.acting, h.gen == from.gen else { return .busy }
            h.state = "acting"; h.gen += 1; h.t = Date().timeIntervalSince1970
            return write(h) ? .ok(h) : .failed
        }
    }

    private static func mine(_ h: SessionWire.Holder?, _ runID: String, _ pgid: Int32) -> SessionWire.Holder? {
        guard let h, h.runID == runID, h.pgid == pgid else { return nil }
        return h
    }

    /// Its executor has exited: the lock goes if it still names that run and its group is gone (a child still up keeps
    /// it, in the state it had).
    static func free(runID: String, pgid: Int32) {
        guarded(otherwise: ()) {
            if mine(read(), runID, pgid) != nil, !groupAlive(pgid) { unlink(file.path) }
        }
    }

    /// 「清除全部」: this helper's own last run lets go of its files -- a lingering one is ended. False while one of
    /// this helper's acts, or when it will not end.
    static func endOwnLingering() -> Bool {
        guarded(otherwise: false) {
            guard let h = read(), h.by == "helper" || h.by == "hands", held(h) else { return true }
            return !h.acting && endTree(h)
        }
    }

    /// Some task acts on this Mac now (any path): the helper does not restart under it.
    static var acting: Bool {
        guard let h = read() else { return false }
        return h.acting && held(h)
    }

    /// The machine is held by a task that acts, or by a run whose leftovers would not end (an op run is refused).
    static let busy: [String: Any] = ["event": "error", "code": "computer_busy", "error": "another task is using this Mac"]

    /// Its executor (harness) has exited: if the lock still says it acts (no task_done; or it died during an undo), what
    /// is left of its group is given `grace` s to end by itself, then ended -- it must not hold the Mac for good. A
    /// lingering leftover needs nothing: the next task ends it.
    static func reapLeftovers(runID: String, pgid: Int32, grace: Double = 12) {
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            let left: SessionWire.Holder? = guarded(otherwise: nil) {
                guard let h = mine(read(), runID, pgid), h.acting, held(h) else { return nil }
                return h
            }
            guard let h = left else { return }
            NSLog("DeskMind Hands: run \(runID): its executor exited \(Int(grace)) s ago and processes of its group are still up; ending them")
            _ = endTree(h, term: 2, kill: 2)
            free(runID: runID, pgid: pgid)
        }
    }
}
