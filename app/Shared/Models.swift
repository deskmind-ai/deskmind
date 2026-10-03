// Where the local models live, and how the app knows they are complete: the planner's two (DeskMind Brain, needed
// before anything runs) and the vision model (DeskMind Eyes, optional: only apps with no accessibility tree need it,
// so it is downloaded when a task first asks for it, never with the Brain).
//
// A model is a directory (MLX weights + tokenizer + deskmind.json, which records the prompt format and must never be
// dropped). The release set is described by a manifest -- every file with its URL, size and SHA-256 -- and is
// installed under Application Support/DeskMind/models/<role>. During development `models.local.json` in the same
// folder may point each role at an existing directory instead ({"fast": "/path", "strong": "/path", "eyes": "/path"},
// "eyes" optional).

import CryptoKit
import Foundation

enum ModelRole: String, CaseIterable, Codable {
    case fast, strong, eyes

    /// The planner's models: what "the local model is ready" means. Eyes is not among them -- a user who only works
    /// with Finder and TextEdit never needs it, and must not wait for 3.3 GB they will not use.
    static let brain: [ModelRole] = [.fast, .strong]
}

struct ModelManifest: Codable {
    /// `mirror`: the same bytes from a second host (ModelScope), for where huggingface.co is slow or unreachable.
    struct File: Codable { let path: String; let url: String; var mirror: String? = nil; let size: Int64; let sha256: String }
    struct Model: Codable { let role: ModelRole; let name: String; let files: [File] }
    let name: String
    let version: String
    let models: [Model]
    /// The routing threshold this pair was gated at (RoutingThreshold); absent: the server's default.
    var threshold: Double? = nil

    var totalBytes: Int64 { models.flatMap(\.files).reduce(0) { $0 + $1.size } }
    func only(_ roles: [ModelRole]) -> [Model] { models.filter { roles.contains($0.role) } }
    func bytes(_ roles: [ModelRole]) -> Int64 { only(roles).flatMap(\.files).reduce(0) { $0 + $1.size } }
}

enum DeskMindModels {
    static var root: URL { DeskMindIPC.supportDir.appendingPathComponent("models", isDirectory: true) }
    static var localOverride: URL { DeskMindIPC.supportDir.appendingPathComponent("models.local.json") }

    static func dir(_ role: ModelRole) -> URL { root.appendingPathComponent(role.rawValue, isDirectory: true) }

    /// The bundled manifest of the release models (Contents/Resources/models.json of either app).
    static func manifest() -> ModelManifest? {
        guard let url = Bundle.main.url(forResource: "models", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ModelManifest.self, from: data)
    }

    /// The paths models.local.json points at, if there is one.
    private static func overrides() -> [String: String]? {
        guard let data = try? Data(contentsOf: localOverride) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    /// Whether every file of `roles` is installed and verified.
    static func installed(_ roles: [ModelRole]) -> Bool {
        guard let m = manifest() else { return false }
        let models = m.only(roles)
        guard Set(models.map(\.role)) == Set(roles) else { return false }
        for model in models {
            for f in model.files {
                let p = dir(model.role).appendingPathComponent(f.path)
                let size = (try? FileManager.default.attributesOfItem(atPath: p.path)[.size] as? Int64) ?? -1
                if size != f.size { return false }
                // Same size is not enough across releases (see ModelDownloader): the verified hash must match too.
                let marker = p.appendingPathExtension("verified")
                if (try? String(contentsOf: marker, encoding: .utf8)) != f.sha256 { return false }
            }
        }
        return true
    }

    /// The Brain's directories to serve, if both are in place: the development override first, then the installed set.
    static func readyDirs() -> [ModelRole: URL]? {
        if let map = overrides() {
            var out: [ModelRole: URL] = [:]
            for role in ModelRole.brain {
                guard let p = map[role.rawValue], FileManager.default.fileExists(atPath: p) else { return nil }
                out[role] = URL(fileURLWithPath: p)
            }
            return out
        }
        guard installed(ModelRole.brain) else { return nil }
        return Dictionary(uniqueKeysWithValues: ModelRole.brain.map { ($0, dir($0)) })
    }

    /// The routing threshold to serve the Brain with: the override's, the fast model's own, the manifest's, or the
    /// default (RoutingThreshold).
    static func routingThreshold() -> Double {
        let config = readyDirs()?[.fast].flatMap { try? Data(contentsOf: $0.appendingPathComponent("deskmind.json")) }
        return RoutingThreshold.pick(override: overrides()?["threshold"], model: config.flatMap(RoutingThreshold.fromModelConfig),
                                     manifest: manifest()?.threshold)
    }

    /// The vision model's directory, if it is in place (the override's "eyes", else the installed copy).
    static func eyesDir() -> URL? {
        if let p = overrides()?["eyes"], FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        return installed([.eyes]) ? dir(.eyes) : nil
    }

    /// SHA-256 of a file, streamed (model shards are gigabytes).
    static func sha256(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
