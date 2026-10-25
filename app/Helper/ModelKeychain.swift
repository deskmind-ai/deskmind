// The helper's keychain item for the model settings (A11, Shared/ModelStore.swift): a generic password, this helper's
// own (made by it, so it reads it without asking), holding models.env's text. Only the helper touches it.

import Foundation
import Security

final class ModelKeychain: ModelStore.Keychain {
    static let shared = ModelKeychain()
    static let service = "ai.deskmind.models"
    static let account = "models.env"

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: Self.account]
    }

    func read() -> ModelStore.Read {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        // (a background helper never shows a dialog: an item it may not read without one is "the read failed")
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return .none }
        guard s == errSecSuccess, let d = out as? Data, let text = String(data: d, encoding: .utf8) else { return .failed }
        return .value(text)
    }

    /// The query with no dialog ever: a background helper never prompts (an item it may not touch without one fails).
    private var quiet: [String: Any] {
        var q = base
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return q
    }

    func modified() -> Date? {
        var q = quiet
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let a = out as? [String: Any] else { return nil }
        return a[kSecAttrModificationDate as String] as? Date
    }

    func write(_ text: String) -> Bool {
        let data = Data(text.utf8)
        let s = SecItemUpdate(quiet as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if s == errSecSuccess { return true }
        guard s == errSecItemNotFound else { return false }
        return add(data)
    }

    /// The user's own save over an item this helper cannot read (another build made it, the keychain refuses): it is
    /// deleted and written anew, this helper's.
    func replace(_ text: String) -> Bool {
        let s = SecItemDelete(quiet as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { return false }
        return add(Data(text.utf8))
    }

    private func add(_ data: Data) -> Bool {
        var a = quiet
        a[kSecValueData as String] = data
        a[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(a as CFDictionary, nil) == errSecSuccess
    }

    /// models.env's old place (moved in once, then removed: ModelStore.current).
    static var legacyFile: URL { DeskMindIPC.supportDir.appendingPathComponent("models.env") }

    /// The store in use: the keychain, or -- a test's own support folder (tests/e2e) -- a file in that folder, so a test
    /// never touches the user's keychain (and an unsigned test build is never refused by it).
    static var store: ModelStore.Keychain {
        DeskMindIPC.supportOverride.map { FileKeychain($0.appendingPathComponent("keychain.test")) } ?? shared
    }

    /// The settings now, the move from models.env done on the way (nil: the keychain could not be read, no file).
    static func env() -> [String: String]? {
        ModelStore.current(keychain: store, file: legacyFile).map(ModelStore.parse)
    }
}

/// A test's keychain: one file.
final class FileKeychain: ModelStore.Keychain {
    let url: URL
    init(_ url: URL) { self.url = url }
    func read() -> ModelStore.Read {
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        return (try? String(contentsOf: url, encoding: .utf8)).map { .value($0) } ?? .failed
    }
    func write(_ text: String) -> Bool { (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil }
    func replace(_ text: String) -> Bool { write(text) }
    func modified() -> Date? { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
}
