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
        // Fix 2: the matched round-type mention (and its separator) is stripped from
        // company — see testMapStripsMatchedRoundTypeAndSeparatorFromCompany below for
        // the dedicated coverage of that behavior.
        let item = CalendarEvents.map(title: "Stripe — System Design", notes: nil,
                                      start: now, knownRoundTypes: knownRoundTypes, now: now)
        XCTAssertEqual(item?.company, "Stripe")
        XCTAssertEqual(item?.roundType, "system_design")
    }

    /// Fix 1(a): notes are invite-body prose, not a label — a round type named only in
    /// the notes must NOT pre-fill. This replaces a prior test that asserted the opposite
    /// (matching notes) — that was the bug this fix corrects.
    func testMapIgnoresRoundTypeMentionedOnlyInNotes() {
        let item = CalendarEvents.map(title: "Figma interview", notes: "Round: Technical",
                                      start: now, knownRoundTypes: knownRoundTypes, now: now)
        XCTAssertEqual(item?.company, "Figma interview")
        XCTAssertNil(item?.roundType)
    }

    /// The real-world failure scenario this fix targets: Zoom/Meet/Teams invite
    /// boilerplate in the notes body must not mis-fire a round-type match, silently
    /// grading a recruiter screen against the technical rubric.
    func testMapIgnoresBoilerplateTechnicalDifficultiesInNotes() {
        let item = CalendarEvents.map(
            title: "Recruiter screen",
            notes: "Zoom Meeting\nIf you have technical difficulties, call the front desk.",
            start: now, knownRoundTypes: knownRoundTypes, now: now)
        XCTAssertEqual(item?.company, "Recruiter screen")
        XCTAssertNil(item?.roundType)
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

    /// Fix 1(b): a needle must match a whole word, not any substring — "technicalities"
    /// contains "technical" as characters but is not the word "technical".
    func testMatchRoundTypeRejectsSubstringInsideLongerWord() {
        XCTAssertNil(CalendarEvents.matchRoundType(in: "Let's discuss the technicalities of the offer",
                                                    known: knownRoundTypes))
    }

    /// Same failure mode as above, exercised through the title (where matching now
    /// happens) rather than calling `matchRoundType` directly.
    func testMapRejectsSubstringInsideLongerWordInTitle() {
        let item = CalendarEvents.map(title: "Technicalities of the offer", notes: nil,
                                      start: now, knownRoundTypes: knownRoundTypes, now: now)
        XCTAssertNil(item?.roundType)
    }

    // MARK: - strippedCompany (Fix 2)

    func testMapStripsMatchedRoundTypeAndSeparatorFromCompany() {
        let item = CalendarEvents.map(title: "Stripe — System Design", notes: nil,
                                      start: now, knownRoundTypes: knownRoundTypes, now: now)
        XCTAssertEqual(item?.company, "Stripe")
        XCTAssertEqual(item?.roundType, "system_design")
    }

    func testMapLeavesTitleUntouchedWhenNoRoundTypeMatches() {
        let item = CalendarEvents.map(title: "Stripe / Brad — Onsite 2", notes: nil,
                                      start: now, knownRoundTypes: knownRoundTypes, now: now)
        XCTAssertEqual(item?.company, "Stripe / Brad — Onsite 2")
        XCTAssertNil(item?.roundType)
    }

    func testMapNeverStripsCompanyToEmpty() {
        // The whole title IS the round-type mention — stripping it would leave "".
        let item = CalendarEvents.map(title: "Technical", notes: nil,
                                      start: now, knownRoundTypes: knownRoundTypes, now: now)
        XCTAssertEqual(item?.company, "Technical")
        XCTAssertEqual(item?.roundType, "technical")
    }

    // MARK: - deterministic tie-break (Fix 3)

    func testMatchRoundTypeTieBreaksDeterministicallyRegardlessOfKnownOrder() {
        // "system_design"/"System Design" and "product_sense"/"Product Sense" are all
        // 13 characters — a genuine length tie. The result must not depend on the
        // (unspecified) order `sorted` puts equal-length elements in.
        let tied = ["system_design", "product_sense"]
        let forward = CalendarEvents.matchRoundType(in: "System Design / Product Sense round",
                                                     known: tied)
        let reversed = CalendarEvents.matchRoundType(in: "System Design / Product Sense round",
                                                      known: tied.reversed())
        XCTAssertEqual(forward, reversed)
        // Pin the actual tie-break rule (higher raw value wins) so a regression that
        // changes the winner, not just the determinism, is caught too.
        XCTAssertEqual(forward, "system_design")
    }
}
