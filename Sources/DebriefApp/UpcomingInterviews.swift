import Foundation
import CaptureKit
import os

private let logger = Logger(subsystem: "com.debrief.app", category: "upcoming")

/// One scheduled interview, as written by Claude from the dedicated interview calendar.
/// `roundType` is the raw string; adopting it into the UI is gated by
/// `PromptStore.availableRoundTypes()` (see AppEnvironment.apply) because the Picker
/// binds by tag and an unknown tag blanks the selection.
struct UpcomingInterview: Codable, Hashable, Sendable {
    let company: String
    let roundType: String?
    let start: Date
    let notes: String?
}

/// Reads the calendar hand-off file. This is a *cache*, not state: every failure path
/// returns [] so the recording form falls back to plain typing. Nothing here throws.
enum UpcomingInterviews {
    static func fileURL() -> URL {
        RecordingStore.appSupportRoot().appendingPathComponent("upcoming.json")
    }

    static func load(from url: URL = fileURL(), now: Date = Date()) -> [UpcomingInterview] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { try decodeFlexibleISO8601($0) }
        // Decode entry-by-entry: one malformed event on the calendar shouldn't
        // discard every other interview in the file.
        guard let raw = try? decoder.decode([FailableEntry].self, from: data) else {
            logger.error("upcoming.json is not a JSON array — ignoring")
            return []
        }
        // ponytail: a one-hour grace window, so an interview that just started is
        // still offered. Widen it if you routinely record long after the slot.
        let cutoff = now.addingTimeInterval(-3600)
        // ponytail: a 14-day forward bound, so a mis-dated far-future entry (bad year,
        // stuck recurring event) doesn't linger in the menu forever. A count cap was
        // rejected in review — it would silently hide the soonest entries instead of the
        // stale ones. Widen by changing the `14 *` below.
        let forwardBound = now.addingTimeInterval(14 * 24 * 3600)
        // A duplicated calendar invite (same event on two calendars, or double-booked)
        // decodes to two byte-identical entries. Dedup here, not in the UI: SwiftUI's
        // `ForEach(id: \.self)` would collide on identical Hashable values and drop or
        // misrender one of the rows.
        var seen = Set<UpcomingInterview>()
        return raw.compactMap(\.value)
            .filter { $0.start >= cutoff && $0.start <= forwardBound }
            .filter { seen.insert($0).inserted }
            .sorted { $0.start < $1.start }
    }

    /// `.iso8601` alone rejects fractional-second timestamps (`…18:00:00.000Z`), which
    /// Google Calendar commonly emits — every entry would silently decode to nil and
    /// `load()` would return `[]` with no signal at all. Try fractional seconds first,
    /// then fall back to whole seconds, so both forms parse. Formatters are built inline
    /// (not cached as static state) because `ISO8601DateFormatter` is a mutable class and
    /// this closure must be `Sendable` to satisfy `dateDecodingStrategy`'s signature.
    private static func decodeFlexibleISO8601(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        if let date = ISO8601DateFormatter().date(from: string) { return date }
        throw DecodingError.dataCorruptedError(in: container,
            debugDescription: "Expected an ISO8601 date, got \(string)")
    }

    /// Decodes to nil instead of throwing, so `[FailableEntry]` tolerates bad elements.
    /// Logs at debug (never error/UI) so a malformed entry leaves a diagnostic thread to
    /// pull without alarming anyone — this file degrading silently is by design.
    private struct FailableEntry: Decodable {
        let value: UpcomingInterview?
        init(from decoder: Decoder) throws {
            do {
                value = try UpcomingInterview(from: decoder)
            } catch {
                logger.debug("Dropping malformed upcoming.json entry: \(String(describing: error), privacy: .public)")
                value = nil
            }
        }
    }
}
