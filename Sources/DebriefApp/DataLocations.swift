import Foundation
import CaptureKit
import CoachingEngine
import os

private let logger = Logger(subsystem: "com.debrief.app", category: "datalocations")

/// Resolves where Debrief keeps its audio, database, and prompts — honoring user-chosen
/// folders from Settings — and moves any existing data to match, ONCE, at launch, before any
/// store opens. "Declared vs. reconciled state": Settings declares a desired directory; this
/// is the single place that mutates the filesystem to match it, and it runs while nothing
/// holds the DB open (which is why moving the DB here is safe and moving it live is not).
/// That "nothing holds the DB open" assumption is enforced across the relaunch handoff by the
/// Settings gate (`SettingsView.canRelocate`): a relocation can only be *initiated* when the
/// old instance is idle (not recording/finalizing) and not re-coaching, so no writer is left
/// racing this move when the new instance reconciles at launch.
enum DataLocations {
    enum MigrationError: Error, LocalizedError {
        case targetNotEmpty(URL)

        var errorDescription: String? {
            switch self {
            case .targetNotEmpty(let url):
                return "The folder “\(url.path)” already contains files. Choose an empty folder or a new location."
            }
        }
    }

    struct Resolved { let audio: URL; let db: URL; let prompts: URL }

    /// One relocatable data kind: the UserDefaults keys that declare its desired/actual
    /// location and hold the last move error, plus the default full directory used when no
    /// desired/actual is stored. (`internal`, not `private`, so tests can drive `reconcile`.)
    struct Kind {
        let desiredKey: String, actualKey: String, errorKey: String, defaultDir: URL
    }

    private static func kinds() -> (audio: Kind, db: Kind, prompts: Kind) {
        (audio: Kind(desiredKey: "audioDirDesired", actualKey: "audioDirActual",
                     errorKey: "audioDirError", defaultDir: RecordingStore.recordingsRoot()),
         db: Kind(desiredKey: "dbDirDesired", actualKey: "dbDirActual",
                  errorKey: "dbDirError", defaultDir: RecordingStore.appSupportRoot().appendingPathComponent("db")),
         prompts: Kind(desiredKey: "promptsDirDesired", actualKey: "promptsDirActual",
                       errorKey: "promptsDirError", defaultDir: PromptStore.defaultDirectory()))
    }

    static func resolveAndReconcile(defaults: UserDefaults = .standard, fm: FileManager = .default) -> Resolved {
        let k = kinds()
        return Resolved(audio: reconcile(k.audio, defaults: defaults, fm: fm),
                        db: reconcile(k.db, defaults: defaults, fm: fm),
                        prompts: reconcile(k.prompts, defaults: defaults, fm: fm))
    }

    /// Returns the directory to actually use this launch. On a successful move, adopts `desired`
    /// and records it as `actual`; on failure, keeps `actual`, records an error for Settings to
    /// show, and leaves `desired` set so the move is retried next launch.
    static func reconcile(_ kind: Kind, defaults: UserDefaults, fm: FileManager) -> URL {
        let desired = defaults.string(forKey: kind.desiredKey).map(URL.init(fileURLWithPath:)) ?? kind.defaultDir
        let actual = defaults.string(forKey: kind.actualKey).map(URL.init(fileURLWithPath:)) ?? kind.defaultDir
        guard desired != actual else { defaults.removeObject(forKey: kind.errorKey); return actual }
        do {
            try migrateDirectory(from: actual, to: desired, fm: fm)
            defaults.set(desired.path, forKey: kind.actualKey)
            defaults.removeObject(forKey: kind.errorKey)
            return desired
        } catch {
            logger.error("data-location move failed \(actual.path, privacy: .public) -> \(desired.path, privacy: .public): \(error, privacy: .public)")
            defaults.set("Couldn’t move to \(desired.path): \(error.localizedDescription). Still using \(actual.path).",
                         forKey: kind.errorKey)
            return actual
        }
    }

    /// Moves directory `from` to `to`. No-op if equal or if the source doesn't exist (no data
    /// yet). Moves into an empty pre-existing target; refuses a non-empty one rather than
    /// overwrite. This is the only place that can lose data, so it is deliberately conservative.
    static func migrateDirectory(from: URL, to: URL, fm: FileManager) throws {
        if from == to { return }
        guard fm.fileExists(atPath: from.path) else { return }
        if fm.fileExists(atPath: to.path) {
            // Propagate a listing failure rather than swallowing it: an undeterminable target
            // must be REFUSED (throw), never assumed empty and removed. `try?` here would let a
            // target we can't inspect fall through to `removeItem` and be deleted.
            let contents = try fm.contentsOfDirectory(atPath: to.path)
            if !contents.isEmpty { throw MigrationError.targetNotEmpty(to) }
            try fm.removeItem(at: to) // empty dir — clear it so moveItem can create it fresh
        }
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: from, to: to)
    }
}
