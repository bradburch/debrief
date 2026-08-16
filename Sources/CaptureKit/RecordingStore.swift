import Foundation

public struct RecordingManifest: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var finalized: Bool
    /// Stamped as soon as the session row lands, before the finalize that inserted it has
    /// finished. It closes the duplicate-session window: a crash between the insert and
    /// `finalized: true` leaves a dir that still looks recoverable, and recovering it would
    /// transcribe and insert the same interview a second time. Nil for a dir written before
    /// this field existed, and for one whose row was never inserted.
    public var sessionId: Int64?
    public init(startedAt: Date, finalized: Bool, sessionId: Int64? = nil) {
        self.startedAt = startedAt; self.finalized = finalized; self.sessionId = sessionId
    }
}

public enum RecordingStore {
    public static func appSupportRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Debrief")
    }

    public static func recordingsRoot() -> URL {
        appSupportRoot().appendingPathComponent("recordings")
    }

    public static func createSessionDirectory(root: URL = recordingsRoot()) throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func writeManifest(_ m: RecordingManifest, in dir: URL) throws {
        let data = try JSONEncoder().encode(m)
        try data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
    }

    public static func readManifest(in dir: URL) -> RecordingManifest? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONDecoder().decode(RecordingManifest.self, from: data)
    }

    public static func chunkURLs(in dir: URL, prefix: String) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("\(prefix)-") && $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func unfinalizedSessions(root: URL = recordingsRoot()) -> [URL] {
        // Build child URLs by appending names to the caller-supplied `root` rather than
        // using the resolved URLs from contentsOfDirectory(at:), which canonicalizes
        // symlinked paths (e.g. /var -> /private/var on macOS) and would no longer be
        // `==` to a session URL the caller derived from the same `root`.
        // isDirectory: false pins the hint explicitly so this matches the URL shape
        // createSessionDirectory produces (no trailing slash), instead of letting
        // appendingPathComponent auto-detect the (already-existing) directory and
        // append one, which would break `==` comparisons against session URLs
        // callers already hold.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name -> URL? in
            let dir = root.appendingPathComponent(name, isDirectory: false)
            guard let m = readManifest(in: dir) else { return nil }
            return m.finalized ? nil : dir
        }
    }

    public static func deleteSession(at dir: URL) throws {
        try FileManager.default.removeItem(at: dir)
    }
}
