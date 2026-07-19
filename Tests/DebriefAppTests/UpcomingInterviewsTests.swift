import XCTest
@testable import DebriefApp

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
