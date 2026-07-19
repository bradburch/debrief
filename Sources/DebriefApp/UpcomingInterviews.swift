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
        decoder.dateDecodingStrategy = .iso8601
        // Decode entry-by-entry: one malformed event on the calendar shouldn't
        // discard every other interview in the file.
        guard let raw = try? decoder.decode([FailableEntry].self, from: data) else {
            logger.error("upcoming.json is not a JSON array — ignoring")
            return []
        }
        // ponytail: a one-hour grace window, so an interview that just started is
        // still offered. Widen it if you routinely record long after the slot.
        let cutoff = now.addingTimeInterval(-3600)
        // A duplicated calendar invite (same event on two calendars, or double-booked)
        // decodes to two byte-identical entries. Dedup here, not in the UI: SwiftUI's
        // `ForEach(id: \.self)` would collide on identical Hashable values and drop or
        // misrender one of the rows.
        var seen = Set<UpcomingInterview>()
        return raw.compactMap(\.value)
            .filter { $0.start >= cutoff }
            .filter { seen.insert($0).inserted }
            .sorted { $0.start < $1.start }
    }

    /// Decodes to nil instead of throwing, so `[FailableEntry]` tolerates bad elements.
    private struct FailableEntry: Decodable {
        let value: UpcomingInterview?
        init(from decoder: Decoder) throws {
            value = try? UpcomingInterview(from: decoder)
        }
    }
}
