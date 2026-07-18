import Foundation

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
/// true for the ANTHROPIC_API_KEY env fallback) and encrypted at rest by
/// FileVault. Give the app a Team ID cert if you want keychain-grade at-rest.
enum SecretStore {
    // Inlined rather than importing CaptureKit for one path — matches PromptStore's convention.
    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Debrief/secrets.json")
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
        try JSONEncoder().encode(all).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
