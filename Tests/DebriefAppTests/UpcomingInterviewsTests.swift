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

    func testDropsStaleEntriesAndSortsByStart() throws {
        let url = try tempFile("""
        [{"company":"Later","start":"2025-06-15T20:00:00Z"},
         {"company":"LongPast","start":"2025-06-01T09:00:00Z"},
         {"company":"Sooner","start":"2025-06-15T18:00:00Z"}]
        """)
        let items = UpcomingInterviews.load(from: url, now: now)
        XCTAssertEqual(items.map(\.company), ["Sooner", "Later"])
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
    func testApplyIgnoresUnknownRoundType() throws {
        let env = try makeTestEnv()
        env.recordRoundType = .behavioral
        env.apply(UpcomingInterview(company: "Figma", roundType: "vibes_check",
                                    start: Date(), notes: nil))
        XCTAssertEqual(env.recordCompany, "Figma")
        XCTAssertEqual(env.recordRoundType, .behavioral)
        XCTAssertEqual(env.recordNotes, "")
    }

    private func makeTestEnv() throws -> AppEnvironment {
        let db = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prompts = PromptStore(directory: promptDir)
        try prompts.ensureDefaults()
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
