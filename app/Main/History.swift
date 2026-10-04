// The user's own instructions: what one run is asked to do (GoalRequest), and the last few runs kept to look back
// on (RunRecord, in Application Support/DeskMind/history.json, on this Mac only).
//
// Ten are kept, as many as the helper keeps run folders (Runner.pruneRuns): a step's screenshot is a path into its
// run folder, so an older record would show steps with no pictures.

import Foundation

/// One instruction, ready to run: the words, the folder if one is attached, and the apps it names.
struct GoalRequest: Identifiable {
    let id = UUID()
    let goal: String
    let folder: String?
    /// The apps the instruction names, in order. Empty only for a folder task, which runs in Finder (see displayApps).
    let apps: [ResolvedApp]
    /// Record this run (the confirmation sheet's "Record this run"; its last setting when the sheet is skipped).
    var record = UserDefaults.standard.bool(forKey: "record.default")

    /// What the confirmation sheet and the run screen show: the named apps, or Finder for a folder task.
    var displayApps: [ResolvedApp] { apps.isEmpty ? [AppScope.finder] : apps }

    /// Whether the vision model may be needed: an app beyond Finder and TextEdit (the helper decides the same way).
    var mayNeedVision: Bool { apps.contains { !["com.apple.finder", "com.apple.TextEdit"].contains($0.bundleID) } }

    /// The helper's "run" request. The apps go by what the instruction calls them; a folder task that names none
    /// sends no list, and hands starts in Finder with its usual file-task apps.
    var body: [String: Any] {
        var b: [String: Any] = ["op": "run", "goal": goal, "foreground_ok": true,
                                "apps": apps.map { ["name": $0.mention, "bundle": $0.bundleID] }]
        if let folder { b["folder"] = folder }
        if record { b["record"] = true }   // the app's own: the helper ignores it
        // The live view (View menu), on unless turned off.
        b["live_view"] = UserDefaults.standard.object(forKey: LiveView.enabledKey) as? Bool ?? true
        return b
    }
}

struct RunRecord: Codable, Identifiable {
    struct App: Codable {
        let mention: String, bundleID: String, path: String, nameEN: String, nameZH: String?
        init(_ a: ResolvedApp) {
            mention = a.mention; bundleID = a.bundleID; path = a.path; nameEN = a.nameEN; nameZH = a.nameZH
        }
        var resolved: ResolvedApp {
            ResolvedApp(mention: mention, bundleID: bundleID, path: path, nameEN: nameEN, nameZH: nameZH)
        }
    }
    struct Step: Codable {
        let n: Int, human: String, app: String, shot: String, describe: String, detail: String, ok: Bool
    }
    let id: UUID
    let date: Date
    let goal: String
    let folder: String?
    let apps: [App]
    /// Finished (the model said it was done), or stopped before that; errored: the run broke (see its summary).
    let finished: Bool
    let errored: Bool
    let summary: String
    let answer: String
    let steps: [Step]
    let created: [String], modified: [String], deleted: [String]
    /// The run's recording, if it was recorded (absent in records written before recording existed).
    var movie: String?
}

@MainActor
final class RunHistory: ObservableObject {
    static let shared = RunHistory()
    static let keep = 10
    @Published private(set) var records: [RunRecord] = []

    private var url: URL { DeskMindIPC.supportDir.appendingPathComponent("history.json") }

    init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        records = (try? Data(contentsOf: url)).flatMap { try? dec.decode([RunRecord].self, from: $0) } ?? []
    }

    func add(_ r: RunRecord) {
        records.insert(r, at: 0)
        if records.count > Self.keep { records.removeLast(records.count - Self.keep) }
        save()
    }

    /// Forget runs. Their recordings stay in Movies › DeskMind: a movie is the user's file once written.
    func remove(_ ids: Set<UUID>) {
        records.removeAll { ids.contains($0.id) }
        save()
    }

    func clear() {
        records = []
        save()
    }

    func setMovie(_ path: String, for id: UUID) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].movie = path
        save()
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: DeskMindIPC.supportDir, withIntermediateDirectories: true)
        if let data = try? enc.encode(records) { try? data.write(to: url, options: .atomic) }
    }
}
