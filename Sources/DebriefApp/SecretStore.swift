import Foundation
import CaptureKit

/// API keys for a local, single-user dev app. Stored as a 0600 JSON file in
/// Application Support instead of the macOS Keychain.
///
/// Why not the Keychain: the app is signed with a self-signed cert that has no
/// Team ID, so the login keychain pins each item's partition to the app's
/// cdhash — which changes every rebuild. Every rebuild then re-prompts for the
/// keychain password (the data-protection keychain isn't reachable without a
/// provisioning-profile entitlement, and a null-application ACL is still gated
/// by the cdhash partition). A 0600 file is prompt-free forever, and its
/// security is on par here: readable only by processes running as you (already
/// true for the ANTHROPIC_API_KEY env fallback).
///
/// Tradeoff vs the Keychain: the key is plaintext at rest, so unlike a Keychain
/// item it rides along in cleartext in unencrypted Time Machine backups unless
/// the whole disk/backup is encrypted (FileVault). Give the app a Team ID cert
/// if you want keychain-grade at-rest encryption back.
enum SecretStore {
    private static var file: URL {
        RecordingStore.appSupportRoot().appendingPathComponent("secrets.json")
    }

    static func read(key: String) -> String? { load()[key] }

    static func save(key: String, value: String) throws {
        var all = load()
        all[key] = value
        try write(all)
    }

    static func delete(key: String) throws {
        var all = load()
        guard all.removeValue(forKey: key) != nil else { return }
        try write(all)
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    private static func write(_ all: [String: String]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // umask 0o077 so the atomic write's temp file is born 0600 — a post-write
        // chmod leaves a 0644 window, and if it throws the file stays 0644 forever.
        // ponytail: umask is process-global; safe here because secrets are only ever
        // written from the Settings UI on the main actor (no concurrent file creation).
        let previous = umask(0o077)
        defer { umask(previous) }
        try JSONEncoder().encode(all).write(to: file, options: .atomic)
    }
}
