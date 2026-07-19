import XCTest
@testable import DebriefApp

/// Tests only the two pure statics on `CalendarEvents` — neither takes an EventKit type
/// in its signature, so both are testable without a real `EKEventStore` or a TCC grant.
/// EventKit itself cannot be unit-tested; see `docs/manual-test-checklist.md` for the
/// manual grant-flow and calendar-picker checks.
@MainActor
final class CalendarEventsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let knownRoundTypes = ["behavioral", "technical", "system_design", "tech_deep_dive"]

    // MARK: - map

    func testMapFindsRoundTypeInTitle() {
        let item = CalendarEvents.map(title: "Stripe — System Design", notes: nil,
                                      start: now, knownRoundTypes: knownRoundTypes, now: now)
        XCTAssertEqual(item?.company, "Stripe — System Design")
        XCTAssertEqual(item?.roundType, "system_design")
    }

    func testMapFindsRoundTypeInNotes() {
        let item = CalendarEvents.map(title: "Figma interview", notes: "Round: Technical",
                                      start: now, knownRoundTypes: knownRoundTypes, now: now)
        XCTAssertEqual(item?.company, "Figma interview")
        XCTAssertEqual(item?.roundType, "technical")
    }

    func testMapLeavesRoundTypeNilWhenAbsent() {
        let item = CalendarEvents.map(title: "Anduril chat", notes: "bring laptop",
                                      start: now, knownRoundTypes: knownRoundTypes, now: now)
        XCTAssertEqual(item?.company, "Anduril chat")
        XCTAssertNil(item?.roundType)
    }

    func testMapRejectsNilTitle() {
        XCTAssertNil(CalendarEvents.map(title: nil, notes: nil, start: now,
                                        knownRoundTypes: knownRoundTypes, now: now))
    }

    func testMapRejectsEmptyTitle() {
        XCTAssertNil(CalendarEvents.map(title: "   ", notes: nil, start: now,
                                        knownRoundTypes: knownRoundTypes, now: now))
    }

    func testMapRejectsEventOutsideWindow() {
        let farFuture = now.addingTimeInterval(30 * 24 * 3600)
        XCTAssertNil(CalendarEvents.map(title: "Stripe", notes: nil, start: farFuture,
                                        knownRoundTypes: knownRoundTypes, now: now))
        let farPast = now.addingTimeInterval(-2 * 24 * 3600)
        XCTAssertNil(CalendarEvents.map(title: "Stripe", notes: nil, start: farPast,
                                        knownRoundTypes: knownRoundTypes, now: now))
    }

    func testMapAcceptsEventAtWindowBoundaries() {
        let window = UpcomingInterviews.window(now: now)
        XCTAssertNotNil(CalendarEvents.map(title: "Stripe", notes: nil, start: window.lowerBound,
                                           knownRoundTypes: knownRoundTypes, now: now))
        XCTAssertNotNil(CalendarEvents.map(title: "Stripe", notes: nil, start: window.upperBound,
                                           knownRoundTypes: knownRoundTypes, now: now))
    }

    // MARK: - matchRoundType

    /// `tech_deep_dive` must win over `technical` when both appear as substrings —
    /// verifies the longest-candidate-first sort, not just that matching works at all.
    func testMatchRoundTypeLongestMatchWins() {
        let match = CalendarEvents.matchRoundType(in: "Tech Deep Dive — technical round",
                                                   known: knownRoundTypes)
        XCTAssertEqual(match, "tech_deep_dive")
    }

    func testMatchRoundTypeRawKeyForm() {
        let match = CalendarEvents.matchRoundType(in: "interview: system_design",
                                                   known: knownRoundTypes)
        XCTAssertEqual(match, "system_design")
    }

    func testMatchRoundTypeDisplayForm() {
        let match = CalendarEvents.matchRoundType(in: "interview: System Design",
                                                   known: knownRoundTypes)
        XCTAssertEqual(match, "system_design")
    }

    func testMatchRoundTypeReturnsNilWhenNoneMatch() {
        XCTAssertNil(CalendarEvents.matchRoundType(in: "just a chat about the role",
                                                    known: knownRoundTypes))
    }
}
