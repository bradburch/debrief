import XCTest
@testable import Store

/// Pipeline drill-in, company suggestions, and the "Unknown" placeholder exclusion.
final class CompanyQueriesTests: XCTestCase {
    var db: AppDatabase!

    override func setUpWithError() throws { db = try AppDatabase.inMemory() }

    @discardableResult
    private func session(_ co: Company, _ round: RoundType = .behavioral, day: Double,
                         duration: Int = 60) throws -> Int64 {
        try db.insertSession(.init(id: nil, companyId: co.id!, roundType: round,
                                   date: Date(timeIntervalSince1970: 1_750_000_000 + day * 86_400),
                                   durationSeconds: duration, contextNotes: "",
                                   coachingStatus: .pending)).id!
    }

    func testPipelineExcludesPlaceholderCompanyAndCountsItsSessions() throws {
        let acme = try db.fetchOrCreateCompany(named: "Acme")
        let unknown = try db.fetchOrCreateCompany(named: Company.placeholderName)
        try session(acme, day: 0)
        try session(unknown, day: 1)
        try session(unknown, day: 2)

        XCTAssertEqual(try db.pipeline().map(\.company.name), ["Acme"])
        XCTAssertEqual(try db.unassignedSessionCount(), 2)
        // Sessions still lists them — Pipeline's exclusion must not leak into the list.
        XCTAssertEqual(try db.allSessionSummaries().count, 3)
    }

    func testRenameCompanyFixesCaseForEverySessionAndKeepsStatus() throws {
        let acme = try db.fetchOrCreateCompany(named: "acme")
        try session(acme, day: 0)
        try session(acme, day: 1)
        try db.updateCompanyStatus(id: acme.id!, status: .offer)
        let fixed = try db.renameCompany(id: acme.id!, to: "Acme")
        XCTAssertEqual(fixed.status, .offer)
        let pipes = try db.pipeline()
        XCTAssertEqual(pipes.map(\.company.name), ["Acme"], "one pipeline, not a case-split pair")
        XCTAssertEqual(pipes.first?.sessions.count, 2)
    }

    func testPlaceholderMatchIsCaseInsensitive() throws {
        let lower = try db.fetchOrCreateCompany(named: "unknown")
        try session(lower, day: 0)
        XCTAssertEqual(try db.pipeline().count, 0)
        XCTAssertEqual(try db.unassignedSessionCount(), 1)
    }

    func testUnassignedCountIsZeroWithoutPlaceholder() throws {
        try session(try db.fetchOrCreateCompany(named: "Acme"), day: 0)
        XCTAssertEqual(try db.unassignedSessionCount(), 0)
    }

    func testIsPlaceholder() {
        XCTAssertTrue(Company(name: "Unknown").isPlaceholder)
        XCTAssertTrue(Company(name: "  ").isPlaceholder)
        XCTAssertFalse(Company(name: "Acme").isPlaceholder)
    }

    func testCompanySuggestionsOrderActiveThenRecentAndSkipPlaceholderAndEmptyCompanies() throws {
        let old = try db.fetchOrCreateCompany(named: "Beta")
        let recent = try db.fetchOrCreateCompany(named: "Gamma")
        let dead = try db.fetchOrCreateCompany(named: "Aardvark")
        let offer = try db.fetchOrCreateCompany(named: "Delta")
        let unknown = try db.fetchOrCreateCompany(named: Company.placeholderName)
        _ = try db.fetchOrCreateCompany(named: "NoSessions")
        try session(old, day: 1)
        try session(recent, day: 2)
        try session(dead, day: 9)
        try session(offer, day: 5)
        try session(unknown, day: 10)
        try db.updateCompanyStatus(id: dead.id!, status: .dead)
        try db.updateCompanyStatus(id: offer.id!, status: .offer)

        XCTAssertEqual(try db.companySuggestions(), ["Gamma", "Beta", "Delta", "Aardvark"])
    }

    func testCompanyOverviewGathersRoundsTagsAndActionItems() throws {
        let acme = try db.fetchOrCreateCompany(named: "Acme")
        let other = try db.fetchOrCreateCompany(named: "Other")
        let first = try session(acme, .recruiterScreen, day: 0, duration: 1800)
        let second = try session(acme, .technical, day: 3, duration: 3600)
        let elsewhere = try session(other, day: 1)
        try db.saveFeedback(.init(id: nil, sessionId: first, proseDebrief: "", scoresJSON: "{}",
                                  highlightsJSON: "[]", actionItemsJSON: #"["Quantify impact"]"#,
                                  overallScore: 3, advancement: "lean_yes"),
                            tags: ["rambling_intro", "no_quantified_impact"])
        try db.saveFeedback(.init(id: nil, sessionId: second, proseDebrief: "", scoresJSON: "{}",
                                  highlightsJSON: "[]", actionItemsJSON: "[]", overallScore: 4,
                                  processNotesJSON: #"[{"t":"00:01:00","note":"onsite next"}]"#),
                            tags: ["rambling_intro"])
        try db.saveFeedback(.init(id: nil, sessionId: elsewhere, proseDebrief: "", scoresJSON: "{}",
                                  highlightsJSON: "[]", actionItemsJSON: #"["Not Acme"]"#,
                                  overallScore: 2), tags: ["rambling_intro"])

        let o = try XCTUnwrap(db.companyOverview(id: acme.id!))
        XCTAssertEqual(o.company.name, "Acme")
        XCTAssertEqual(o.sessions.map(\.id), [first, second], "chronological, this company only")
        XCTAssertEqual(o.sessions.map(\.durationSeconds), [1800, 3600])
        XCTAssertEqual(o.sessions.map(\.coachingStatus), [.complete, .complete])
        XCTAssertEqual(o.sessions.first?.advancement, .leanYes)
        XCTAssertEqual(o.weaknessTags.map(\.tag), ["rambling_intro", "no_quantified_impact"])
        XCTAssertEqual(o.weaknessTags.first?.count, 2, "another company's tag must not count")
        XCTAssertEqual(o.actionItemsJSON.map(\.json), [#"["Quantify impact"]"#], "\"[]\" dropped")
        XCTAssertEqual(o.processNotesJSON.count, 1)
        XCTAssertNil(try db.companyOverview(id: 9_999))
    }
}
