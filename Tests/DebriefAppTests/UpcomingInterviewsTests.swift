import XCTest
@testable import DebriefApp
import Store
import CoachingEngine
import CaptureKit

final class UpcomingInterviewsTests: XCTestCase {
    /// Writes `json` to a fresh temp file and returns its URL.
    private func tempFile(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try Data(json.utf8).write(to: url)
        return url
    }

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    func testDecodesValidFile() throws {
        let url = try tempFile("""
        [{"company":"Stripe","roundType":"system_design",
          "start":"2025-06-15T18:00:00Z","notes":"panel of 2"}]
        """)
        let items = UpcomingInterviews.load(from: url, now: now)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].company, "Stripe")
        XCTAssertEqual(items[0].roundType, "system_design")
        XCTAssertEqual(items[0].notes, "panel of 2")
    }

    func testMissingFileYieldsEmptyList() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        XCTAssertEqual(UpcomingInterviews.load(from: url, now: now), [])
    }

    func testMalformedFileYieldsEmptyList() throws {
        let url = try tempFile("{ this is not json")
        XCTAssertEqual(UpcomingInterviews.load(from: url, now: now), [])
    }

    /// A calendar event may have no description and no recognizable round in its title.
    /// The entry must survive with nils, not be dropped.
    func testOptionalFieldsMayBeAbsent() throws {
        let url = try tempFile("""
        [{"company":"Figma","start":"2025-06-15T18:00:00Z"}]
        """)
        let items = UpcomingInterviews.load(from: url, now: now)
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].roundType)
        XCTAssertNil(items[0].notes)
    }

    /// One bad entry must not discard the good ones alongside it.
    func testSkipsUndecodableEntriesButKeepsTheRest() throws {
        let url = try tempFile("""
        [{"company":"Stripe","start":"2025-06-15T18:00:00Z"},
         {"roundType":"behavioral","start":"2025-06-15T19:00:00Z"},
         {"company":"Figma","start":"2025-06-15T20:00:00Z"}]
        """)
        let items = UpcomingInterviews.load(from: url, now: now)
        XCTAssertEqual(items.map(\.company), ["Stripe", "Figma"])
    }

    /// A duplicated calendar invite (same event synced from two calendars, or a
    /// double-booked entry) decodes to two byte-identical entries. Left undeduped, these
    /// produce identical SwiftUI `ForEach(id: \.self)` identities, which SwiftUI drops or
    /// misrenders. The loader must collapse them before the UI ever sees the list.
    func testDedupsDuplicateEntries() throws {
        let url = try tempFile("""
        [{"company":"Stripe","roundType":"system_design",
          "start":"2025-06-15T18:00:00Z","notes":"panel of 2"},
         {"company":"Stripe","roundType":"system_design",
          "start":"2025-06-15T18:00:00Z","notes":"panel of 2"},
         {"company":"Figma","start":"2025-06-15T20:00:00Z"}]
        """)
        let items = UpcomingInterviews.load(from: url, now: now)
        XCTAssertEqual(items.map(\.company), ["Stripe", "Figma"])
    }

    func testDropsStaleEntriesAndSortsByStart() throws {
        let url = try tempFile("""
        [{"company":"Later","start":"2025-06-15T20:00:00Z"},
         {"company":"LongPast","start":"2025-06-01T09:00:00Z"},
         {"company":"Sooner","start":"2025-06-15T18:00:00Z"}]
        """)
        let items = UpcomingInterviews.load(from: url, now: now)
        XCTAssertEqual(items.map(\.company), ["Sooner", "Later"])
    }

    /// Google Calendar commonly emits fractional-second timestamps
    /// (`2026-07-20T18:00:00.000Z`), which plain `.iso8601` cannot parse — every entry
    /// would silently decode to nil and the whole file would yield []. Must decode.
    func testDecodesFractionalSecondTimestamp() throws {
        let url = try tempFile("""
        [{"company":"Stripe","start":"2025-06-15T18:00:00.000Z"}]
        """)
        let items = UpcomingInterviews.load(from: url, now: now)
        XCTAssertEqual(items.map(\.company), ["Stripe"])
    }

    /// Whole-second timestamps (no fractional component) must keep decoding after adding
    /// fractional-second support — the fallback path must still work.
    func testDecodesWholeSecondTimestamp() throws {
        let url = try tempFile("""
        [{"company":"Figma","start":"2025-06-15T18:00:00Z"}]
        """)
        let items = UpcomingInterviews.load(from: url, now: now)
        XCTAssertEqual(items.map(\.company), ["Figma"])
    }

    /// A far-future entry (bad year, stuck recurring event) must not linger in the menu
    /// forever — a symmetric forward bound drops it just like the backward `cutoff` drops
    /// stale entries.
    func testDropsFarFutureEntries() throws {
        let url = try tempFile("""
        [{"company":"Soon","start":"2025-06-16T09:00:00Z"},
         {"company":"WayOut","start":"2099-01-01T09:00:00Z"}]
        """)
        let items = UpcomingInterviews.load(from: url, now: now)
        XCTAssertEqual(items.map(\.company), ["Soon"])
    }
    // MARK: - statusText (Settings "Calendar pre-fill" section)

    func testStatusTextFileAbsent() {
        XCTAssertEqual(UpcomingInterviews.statusText(fileExists: false, entryCount: 0),
                        "No upcoming.json found.")
        // Even a bogus nonzero count must not be trusted when the file itself is absent.
        XCTAssertEqual(UpcomingInterviews.statusText(fileExists: false, entryCount: 3),
                        "No upcoming.json found.")
    }

    func testStatusTextFilePresentButEmpty() {
        XCTAssertEqual(UpcomingInterviews.statusText(fileExists: true, entryCount: 0),
                        "upcoming.json found, but no upcoming interviews in it.")
    }

    func testStatusTextSingularEntry() {
        XCTAssertEqual(UpcomingInterviews.statusText(fileExists: true, entryCount: 1),
                        "1 upcoming interview ready.")
    }

    func testStatusTextPluralEntries() {
        XCTAssertEqual(UpcomingInterviews.statusText(fileExists: true, entryCount: 2),
                        "2 upcoming interviews ready.")
    }
}

@MainActor
final class ApplyUpcomingTests: XCTestCase {
    /// A round type the prompt store knows about is adopted.
    func testApplyAdoptsKnownRoundType() throws {
        let env = try makeTestEnv()
        env.apply(UpcomingInterview(company: "Stripe", roundType: "system_design",
                                    start: Date(), notes: "panel of 2"))
        XCTAssertEqual(env.recordCompany, "Stripe")
        XCTAssertEqual(env.recordRoundType, .systemDesign)
        XCTAssertEqual(env.recordNotes, "panel of 2")
    }

    /// RoundType accepts any string, so an unknown value would decode fine but leave
    /// the Picker with no matching tag. It must be ignored and the default kept.
    /// Seeds `.systemDesign` (not `.behavioral`, the property's own default) so a
    /// passing assertion proves the value was left untouched, not merely that it
    /// still equals whatever `recordRoundType` defaults to.
    func testApplyIgnoresUnknownRoundType() throws {
        let env = try makeTestEnv()
        env.recordRoundType = .systemDesign
        env.apply(UpcomingInterview(company: "Figma", roundType: "vibes_check",
                                    start: Date(), notes: nil))
        XCTAssertEqual(env.recordCompany, "Figma")
        XCTAssertEqual(env.recordRoundType, .systemDesign)
        XCTAssertEqual(env.recordNotes, "")
    }

    /// `apply` gates adoption on `prompts.availableRoundTypes()`, which is DIRECTORY-driven
    /// (see PromptStore.availableRoundTypes), not on `RoundType.builtins`. A user-dropped
    /// overlay file for a custom round type is a valid, selectable round type even though it
    /// isn't one of the shipped builtins. `system_design`/`vibes_check` alone can't prove
    /// this: both are decided identically by `builtins.contains` and by
    /// `availableRoundTypes().contains`, so this test writes a genuinely custom overlay
    /// (`take_home_review.md`) that only the directory-driven guard recognizes.
    ///
    /// Verified this fails against a `RoundType.builtins.contains(candidate)` stub: swapping
    /// the guard in `apply` to that expression left `recordRoundType` at the seeded
    /// `.behavioral` default instead of adopting `take_home_review`, failing the
    /// `XCTAssertEqual(env.recordRoundType, RoundType(rawValue: "take_home_review"))` line
    /// below. Restored the correct `prompts.availableRoundTypes().contains(candidate)` guard
    /// afterward.
    func testApplyAdoptsCustomRoundType() throws {
        let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let env = try makeTestEnv(promptDir: promptDir) { dir in
            try Data("## Scored dimensions\n\n- rigor: how rigorously they walked the take-home\n"
                .utf8).write(to: dir.appendingPathComponent("take_home_review.md"))
        }
        env.recordRoundType = .behavioral
        env.apply(UpcomingInterview(company: "Anduril", roundType: "take_home_review",
                                    start: Date(), notes: nil))
        XCTAssertEqual(env.recordCompany, "Anduril")
        XCTAssertEqual(env.recordRoundType, RoundType(rawValue: "take_home_review"))
    }

    private func makeTestEnv(promptDir: URL = FileManager.default.temporaryDirectory
                                .appendingPathComponent(UUID().uuidString),
                              configurePrompts: (URL) throws -> Void = { _ in }) throws -> AppEnvironment {
        let db = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        addTeardownBlock { try? FileManager.default.removeItem(at: promptDir) }
        let prompts = PromptStore(directory: promptDir)
        try prompts.ensureDefaults()
        try configurePrompts(promptDir)
        let coaching = CoachingService(db: db, prompts: prompts, llm: OKStubLLM())
        let coordinator = RecordingCoordinator(
            db: db, coaching: coaching,
            transcriber: FakeTranscriber(textForChunk: "final"),
            makeMicRecorder: { FakeRecorder(writer: $0, seconds: 2) },
            makeSystemRecorder: { FakeRecorder(writer: $0, seconds: 2) },
            recordingsRoot: root, chunkDuration: 1.0)
        return AppEnvironment(db: db, prompts: prompts, coaching: coaching,
                              coordinator: coordinator, alerts: nil)
    }
}
