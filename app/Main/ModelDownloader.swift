// Downloads the release models listed in models.json into Application Support/DeskMind/models/<role>.
//
// One downloader per group of roles: the Brain's two (fast, strong) on the home screen's "Local model" row, and the
// vision model (eyes) on its own, only when the user asks for it -- from its row or the confirmation sheet of a task
// that may need it. Each has its own progress; resume data is kept per URL, so the two never mix.
//
// One file at a time, with progress; an interrupted file resumes from where it stopped; every file is checked
// against its SHA-256 before it is moved into place, and a file already in place with the right size and a
// verified marker is skipped. The main app does this (it needs no permission for it); the helper only serves.
// The model repos are public: no token is read or sent.

import Foundation

@MainActor
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    enum Phase: Equatable { case idle, downloading, verifying, paused, done, failed(String) }

    @Published var phase: Phase = .idle
    @Published var bytesDone: Int64 = 0
    @Published var bytesTotal: Int64 = 0
    @Published var currentFile = ""
    /// Bytes per second over the last few seconds, and the time left at that rate.
    @Published var speed: Double = 0
    var eta: TimeInterval? { speed > 1 ? Double(bytesTotal - bytesDone) / speed : nil }
    private var samples: [(t: Date, bytes: Int64)] = []
    private var currentTask: URLSessionDownloadTask?

    private var queue: [(role: ModelRole, file: ModelManifest.File)] = []
    private var finishedBytes: Int64 = 0
    private var session: URLSession!
    private var resumeData: [String: Data] = [:]
    var onDone: (() -> Void)?
    /// The roles this downloader fetches.
    let roles: [ModelRole]

    init(roles: [ModelRole] = ModelRole.brain) {
        self.roles = roles
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 6 * 3600
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
    }

    nonisolated private static func marker(_ dest: URL) -> URL { dest.appendingPathExtension("verified") }

    /// Resume data kept on disk, so a download survives quitting the app, not just a dropped connection.
    private static var resumeDir: URL { DeskMindModels.root.appendingPathComponent(".resume", isDirectory: true) }
    private static func resumeFile(_ url: String) -> URL {
        resumeDir.appendingPathComponent(String(url.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16))
    }
    private func saveResume(_ data: Data, for url: String) {
        try? FileManager.default.createDirectory(at: Self.resumeDir, withIntermediateDirectories: true)
        try? data.write(to: Self.resumeFile(url))
    }
    private func takeResume(for url: String) -> Data? {
        let f = Self.resumeFile(url)
        defer { try? FileManager.default.removeItem(at: f) }
        return try? Data(contentsOf: f)
    }

    /// "Re-download": re-check every installed file against its SHA-256 and fetch only the ones that fail.
    func repair() {
        guard let m = DeskMindModels.manifest() else { return }
        phase = .verifying; currentFile = L("downloaded files", lang: ResolvedLang.current)
        let roles = roles
        Task.detached {
            for model in m.only(roles) {
                for f in model.files {
                    let dest = DeskMindModels.dir(model.role).appendingPathComponent(f.path)
                    if DeskMindModels.sha256(of: dest) != f.sha256 {
                        try? FileManager.default.removeItem(at: dest)
                        try? FileManager.default.removeItem(at: Self.marker(dest))
                    }
                }
            }
            await MainActor.run { self.phase = .idle; self.start() }
        }
    }

    /// Pause: stop the transfer and keep what arrived, on disk.
    func pause() {
        guard phase == .downloading, let task = currentTask, let f = current?.file else { return }
        let url = DownloadSource.url(primary: f.url, mirror: f.mirror, usingMirror: usingMirror)
        task.cancel { data in
            Task { @MainActor in
                if let data { self.saveResume(data, for: url) }
                self.phase = .paused; self.speed = 0
            }
        }
    }

    /// On quit, keep the partial file of the one in flight (best effort, a moment to finish).
    func stashForQuit() {
        guard phase == .downloading, let task = currentTask, let f = current?.file else { return }
        let url = DownloadSource.url(primary: f.url, mirror: f.mirror, usingMirror: usingMirror)
        let sem = DispatchSemaphore(value: 0)
        task.cancel { data in
            if let data {
                try? FileManager.default.createDirectory(at: Self.resumeDir, withIntermediateDirectories: true)
                try? data.write(to: Self.resumeFile(url))
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)
    }

    func start() {
        guard phase != .downloading && phase != .verifying, let m = DeskMindModels.manifest(), !m.only(roles).isEmpty else {
            if DeskMindModels.manifest()?.only(roles).isEmpty ?? true { phase = .failed(L("No model list to download", lang: ResolvedLang.current)) }
            return
        }
        bytesTotal = m.bytes(roles)
        finishedBytes = 0
        queue = []
        for model in m.only(roles) {
            for f in model.files {
                let dest = DeskMindModels.dir(model.role).appendingPathComponent(f.path)
                let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? -1
                // The marker holds the SHA-256 it verified: a new release can change a file without changing its
                // size (deskmind.json's prompt_format 2 → 3), and that file must be fetched again.
                let verified = (try? String(contentsOf: Self.marker(dest), encoding: .utf8)) == f.sha256
                if size == f.size && verified {
                    finishedBytes += f.size   // already downloaded and verified
                } else {
                    queue.append((model.role, f))
                }
            }
        }
        bytesDone = finishedBytes
        // Enough room for what is left, the verification copy and a margin: a model half-written into a full
        // disk fails late and leaves the Mac with no space at all.
        let left = queue.reduce(Int64(0)) { $0 + $1.file.size }
        try? FileManager.default.createDirectory(at: DeskMindModels.root, withIntermediateDirectories: true)
        if let free = try? DeskMindModels.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < left + 2_000_000_000 {
            phase = .failed(L("Not enough disk space: %.1f GB needed, only %.1f GB free",
                              Double(left + 2_000_000_000) / 1e9, Double(free) / 1e9, lang: ResolvedLang.current))
            return
        }
        samples = []; speed = 0
        phase = .downloading
        next()
    }

    private var current: (role: ModelRole, file: ModelManifest.File)?
    /// Downloading from the mirror (DownloadSource): set once Hugging Face failed or stalled, and kept across launches.
    private var usingMirror: Bool {
        get { UserDefaults.standard.bool(forKey: "models.mirror") }
        set { UserDefaults.standard.set(newValue, forKey: "models.mirror") }
    }
    private var currentBytes: Int64 = 0
    private var stallCheck: Timer?

    /// The current file again, from its mirror. False when there is no mirror to go to (or it is in use already).
    private func switchToMirror() -> Bool {
        guard let item = current, DownloadSource.shouldSwitch(hasMirror: item.file.mirror != nil, usingMirror: usingMirror) else { return false }
        usingMirror = true
        queue.insert(item, at: 0)
        phase = .downloading
        next()
        return true
    }

    private func next() {
        guard !queue.isEmpty else {
            current = nil; phase = .done; onDone?(); return
        }
        let item = queue.removeFirst()
        current = item
        currentFile = "\(item.role.rawValue)/\(item.file.path)"
        let task: URLSessionDownloadTask
        let url = DownloadSource.url(primary: item.file.url, mirror: item.file.mirror, usingMirror: usingMirror)
        if let data = resumeData.removeValue(forKey: url) ?? takeResume(for: url) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: URLRequest(url: URL(string: url)!))
        }
        currentTask = task
        currentBytes = 0
        samples = []   // a finished file jumps bytesDone; never let that count as speed
        task.resume()
        // A connection to Hugging Face that trickles never fails: give it DownloadSource.window, then the mirror.
        stallCheck?.invalidate()
        if !usingMirror, item.file.mirror != nil {
            let started = Date()
            stallCheck = Timer.scheduledTimer(withTimeInterval: DownloadSource.window, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.currentTask === task, self.phase == .downloading,
                          DownloadSource.stalled(elapsed: Date().timeIntervalSince(started), bytes: self.currentBytes,
                                                 fileSize: item.file.size) else { return }
                    self.currentTask = nil
                    task.cancel()
                    _ = self.switchToMirror()
                }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        MainActor.assumeIsolated {
            guard self.currentTask === downloadTask else { return }
            self.currentBytes = totalBytesWritten
            self.bytesDone = self.finishedBytes + totalBytesWritten
            let now = Date()
            self.samples.append((now, self.bytesDone))
            self.samples.removeAll { now.timeIntervalSince($0.t) > 5 }
            if let first = self.samples.first, now.timeIntervalSince(first.t) > 0.5 {
                self.speed = Double(self.bytesDone - first.bytes) / now.timeIntervalSince(first.t)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // The temporary file is gone when this returns: move it somewhere of ours first, verify afterwards.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: staged)
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        MainActor.assumeIsolated {
            guard self.currentTask === downloadTask else { try? FileManager.default.removeItem(at: staged); return }
            self.stallCheck?.invalidate()
            self.finish(staged: staged, status: status)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }   // paused or quitting: handled there
        let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        MainActor.assumeIsolated {
            guard self.currentTask === task else { return }
            if let data, let f = self.current?.file {
                let url = DownloadSource.url(primary: f.url, mirror: f.mirror, usingMirror: self.usingMirror)
                self.resumeData[url] = data; self.saveResume(data, for: url)
            }
            self.speed = 0
            if self.switchToMirror() { return }
            self.phase = .failed(L("Download interrupted: %@ (click again to pick up where it stopped)",
                                   error.localizedDescription, lang: ResolvedLang.current))
        }
    }

    private func finish(staged: URL, status: Int) {
        guard let item = current else { return }
        // 206 is how a resumed download ends (the server sent the rest of the file); both are complete. The
        // SHA-256 check below is what decides whether the file is right.
        guard status == 200 || status == 206 else {
            try? FileManager.default.removeItem(at: staged)
            if switchToMirror() { return }
            let lang = ResolvedLang.current
            phase = .failed(status == 401 || status == 403
                            ? L("The download server refused the request (HTTP %d). Try again later.", status, lang: lang)
                            : L("Download failed (HTTP %d): %@", status, item.file.path, lang: lang))
            return
        }
        phase = .verifying
        let dest = DeskMindModels.dir(item.role).appendingPathComponent(item.file.path)
        Task.detached {
            let sha = DeskMindModels.sha256(of: staged)
            await MainActor.run {
                guard sha == item.file.sha256 else {
                    try? FileManager.default.removeItem(at: staged)
                    if self.switchToMirror() { return }
                    self.phase = .failed(L("Checksum mismatch: %@ (deleted, please retry)", item.file.path,
                                           lang: ResolvedLang.current))
                    return
                }
                let fm = FileManager.default
                try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: dest)
                do { try fm.moveItem(at: staged, to: dest) } catch {
                    self.phase = .failed(L("Couldn't write %@: %@", dest.path, error.localizedDescription,
                                           lang: ResolvedLang.current)); return
                }
                fm.createFile(atPath: Self.marker(dest).path, contents: Data(item.file.sha256.utf8))
                self.finishedBytes += item.file.size
                self.bytesDone = self.finishedBytes
                self.phase = .downloading
                self.next()
            }
        }
    }
}
