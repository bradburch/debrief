import XCTest
@testable import Store

final class StoreTests: XCTestCase {
    var db: AppDatabase!

    override func setUpWithError() throws { db = try AppDatabase.inMemory() }

    func testFetchOrCreateCompanyIsIdempotent() throws {
        let a = try db.fetchOrCreateCompany(named: "Acme")
        let b = try db.fetchOrCreateCompany(named: "Acme")
        XCTAssertEqual(a.id, b.id)
    }

    func testRenameSessionDoesNotAffectSiblingsSharingCompany() throws {
        let unknown = try db.fetchOrCreateCompany(named: "Unknown")
        func makeSession() throws -> Int64 {
            try db.insertSession(InterviewSession(
                id: nil, companyId: unknown.id!, roundType: .behavioral,
                date: Date(timeIntervalSince1970: 1_750_000_000),
                durationSeconds: 60, contextNotes: "", coachingStatus: .pending)).id!
        }
        let a = try makeSession()
        let b = try makeSession()

        let renamed = try db.renameSession(id: a, companyNamed: "Acme")
        XCTAssertNotEqual(renamed.id, unknown.id)                         // peeled off to its own company
        XCTAssertEqual(try db.sessionDetail(id: a)?.company.name, "Acme")
        XCTAssertEqual(try db.sessionDetail(id: b)?.company.name, "Unknown")  // sibling untouched
    }

    func testRenameSessionReusesExistingCompany() throws {
        let acme = try db.fetchOrCreateCompany(named: "Acme")
        let unknown = try db.fetchOrCreateCompany(named: "Unknown")
        let s = try db.insertSession(InterviewSession(
            id: nil, companyId: unknown.id!, roundType: .behavioral,
            date: Date(timeIntervalSince1970: 1_750_000_000),
            durationSeconds: 60, contextNotes: "", coachingStatus: .pending)).id!
        let renamed = try db.renameSession(id: s, companyNamed: "Acme")
        XCTAssertEqual(renamed.id, acme.id)  // attaches to existing company, no duplicate
    }

    func testSessionRoundTripAndDetail() throws {
        let co = try db.fetchOrCreateCompany(named: "Acme")
        let s = try db.insertSession(InterviewSession(
            id: nil, companyId: co.id!, roundType: .behavioral,
            date: Date(timeIntervalSince1970: 1_750_000_000),
            durationSeconds: 3600, contextNotes: "final round", coachingStatus: .pending))
        XCTAssertNotNil(s.id)
        try db.insertSegments([
            .init(id: nil, sessionId: s.id!, speaker: .them, tStart: 192, text: "Tell me about a conflict."),
            .init(id: nil, sessionId: s.id!, speaker: .you, tStart: 198, text: "At my last role..."),
        ])
        let detail = try XCTUnwrap(db.sessionDetail(id: s.id!))
        XCTAssertEqual(detail.segments.count, 2)
        XCTAssertEqual(detail.segments[0].speaker, .them)
        XCTAssertEqual(detail.company.name, "Acme")
        let text = try db.transcriptText(sessionId: s.id!)
        XCTAssertTrue(text.contains("[00:03:12] THEM: Tell me about a conflict."))
        XCTAssertTrue(text.contains("[00:03:18] YOU: At my last role..."))
    }

    func testAllSessionSummariesJoinsCompanyAndOptionalScore() throws {
        let co = try db.fetchOrCreateCompany(named: "Acme")
        let scored = try db.insertSession(InterviewSession(
            id: nil, companyId: co.id!, roundType: .technical,
            date: Date(timeIntervalSince1970: 1_750_000_000),
            durationSeconds: 1800, contextNotes: "", coachingStatus: .pending))
        let unscored = try db.insertSession(InterviewSession(
            id: nil, companyId: co.id!, roundType: .behavioral,
            date: Date(timeIntervalSince1970: 1_750_100_000),
            durationSeconds: 1800, contextNotes: "", coachingStatus: .pending))
        try db.saveFeedback(FeedbackRecord(
            id: nil, sessionId: scored.id!, proseDebrief: "d", scoresJSON: "{}",
            highlightsJSON: "[]", actionItemsJSON: "[]", overallScore: 3.5), tags: [])

        let rows = try db.allSessionSummaries()
        XCTAssertEqual(rows.map(\.session.id), [unscored.id, scored.id])  // date desc
        XCTAssertEqual(rows.map(\.companyName), ["Acme", "Acme"])
        XCTAssertEqual(rows.map(\.overallScore), [nil, 3.5])
    }

    func testDeleteSessionCascadesSegmentsFeedbackAndTags() throws {
        let co = try db.fetchOrCreateCompany(named: "Acme")
        let s = try db.insertSession(InterviewSession(
            id: nil, companyId: co.id!, roundType: .behavioral,
            date: Date(timeIntervalSince1970: 1_750_000_000),
            durationSeconds: 3600, contextNotes: "final round", coachingStatus: .pending))
        try db.insertSegments([
            .init(id: nil, sessionId: s.id!, speaker: .them, tStart: 192, text: "Tell me about a conflict."),
            .init(id: nil, sessionId: s.id!, speaker: .you, tStart: 198, text: "At my last role..."),
        ])
        try db.saveFeedback(
            .init(id: nil, sessionId: s.id!, proseDebrief: "Solid.", scoresJSON: "{}",
                  highlightsJSON: "[]", actionItemsJSON: "[]", overallScore: 3.5),
            tags: ["rambling_intro", "no_quantified_impact"])
        XCTAssertNotNil(try db.sessionDetail(id: s.id!))

        try db.deleteSession(id: s.id!)

        XCTAssertNil(try db.sessionDetail(id: s.id!))
        // FK cascade removed the dependent rows too, not just the session itself.
        // recentWeaknessTags(...) is vacuous here since its subquery joins on session
        // existence, so assert the cascade directly against the weaknessTag table.
        let recent = try db.recentWeaknessTags(limitSessions: 10)
        XCTAssertTrue(recent.isEmpty)
        let tagCount = try db.dbWriter.read { rawDb in
            try Int.fetchOne(rawDb, sql: "SELECT COUNT(*) FROM weaknessTag WHERE sessionId = ?", arguments: [s.id!])
        }
        XCTAssertEqual(tagCount, 0)
        let segmentCount = try db.dbWriter.read { rawDb in
            try Int.fetchOne(rawDb, sql: "SELECT COUNT(*) FROM transcriptSegment WHERE sessionId = ?", arguments: [s.id!])
        }
        XCTAssertEqual(segmentCount, 0)
        let feedbackCount = try db.dbWriter.read { rawDb in
            try Int.fetchOne(rawDb, sql: "SELECT COUNT(*) FROM feedback WHERE sessionId = ?", arguments: [s.id!])
        }
        XCTAssertEqual(feedbackCount, 0)
    }

    func testSaveFeedbackStoresTagsAndCompletesSession() throws {
        let co = try db.fetchOrCreateCompany(named: "Acme")
        let s = try db.insertSession(.init(id: nil, companyId: co.id!, roundType: .technical,
                                           date: Date(), durationSeconds: 60, contextNotes: "", coachingStatus: .pending))
        try db.saveFeedback(
            .init(id: nil, sessionId: s.id!, proseDebrief: "Solid.", scoresJSON: "{}",
                  highlightsJSON: "[]", actionItemsJSON: "[]", overallScore: 3.5),
            tags: ["rambling_intro", "no_quantified_impact"])
        let detail = try XCTUnwrap(db.sessionDetail(id: s.id!))
        XCTAssertEqual(detail.session.coachingStatus, .complete)
        XCTAssertEqual(Set(detail.tags), ["rambling_intro", "no_quantified_impact"])
    }

    func testSaveFeedbackReplacesExistingFeedbackAndTags() throws {
        let co = try db.fetchOrCreateCompany(named: "Acme")
        let s = try db.insertSession(.init(id: nil, companyId: co.id!, roundType: .technical,
                                           date: Date(), durationSeconds: 60, contextNotes: "", coachingStatus: .pending))
        try db.saveFeedback(
            .init(id: nil, sessionId: s.id!, proseDebrief: "v1", scoresJSON: "{}",
                  highlightsJSON: "[]", actionItemsJSON: "[]", overallScore: 2.0),
            tags: ["a", "b"])
        try db.saveFeedback(
            .init(id: nil, sessionId: s.id!, proseDebrief: "v2", scoresJSON: "{}",
                  highlightsJSON: "[]", actionItemsJSON: "[]", overallScore: 4.0),
            tags: ["b", "c"])
        let detail = try XCTUnwrap(db.sessionDetail(id: s.id!))
        XCTAssertEqual(detail.feedback?.proseDebrief, "v2")
        XCTAssertEqual(detail.feedback?.overallScore, 4.0)
        XCTAssertEqual(Set(detail.tags), ["b", "c"])
        XCTAssertEqual(detail.session.coachingStatus, .complete)
        let recent = try db.recentWeaknessTags(limitSessions: 10)
        XCTAssertEqual(recent.first { $0.tag == "b" }?.count, 1)
    }

    func testRecentWeaknessTagsWindowsToLastNSessions() throws {
        let co = try db.fetchOrCreateCompany(named: "Acme")
        for i in 0..<3 {
            let s = try db.insertSession(.init(id: nil, companyId: co.id!, roundType: .behavioral,
                                               date: Date(timeIntervalSince1970: Double(i) * 86_400),
                                               durationSeconds: 60, contextNotes: "", coachingStatus: .pending))
            let tags = i == 0 ? ["old_only_tag"] : ["rambling_intro"]
            try db.saveFeedback(.init(id: nil, sessionId: s.id!, proseDebrief: "", scoresJSON: "{}",
                                      highlightsJSON: "[]", actionItemsJSON: "[]", overallScore: 3), tags: tags)
        }
        let recent = try db.recentWeaknessTags(limitSessions: 2)
        XCTAssertEqual(recent.first?.tag, "rambling_intro")
        XCTAssertEqual(recent.first?.count, 2)
        XCTAssertFalse(recent.contains { $0.tag == "old_only_tag" })
    }

    func testPipelineGroupsByCompany() throws {
        let a = try db.fetchOrCreateCompany(named: "Acme")
        let b = try db.fetchOrCreateCompany(named: "Beta")
        _ = try db.insertSession(.init(id: nil, companyId: a.id!, roundType: .recruiterScreen,
                                       date: Date(), durationSeconds: 60, contextNotes: "", coachingStatus: .pending))
        _ = try db.insertSession(.init(id: nil, companyId: b.id!, roundType: .technical,
                                       date: Date(), durationSeconds: 60, contextNotes: "", coachingStatus: .pending))
        let pipe = try db.pipeline()
        XCTAssertEqual(pipe.count, 2)
        XCTAssertEqual(pipe.flatMap(\.sessions).count, 2)
    }

    func testTagFrequencyByMonthGroupsByMonth() throws {
        let co = try db.fetchOrCreateCompany(named: "Acme")
        // 1_750_000_000 = 2025-06-15 UTC; 1_753_000_000 = 2025-07-20 UTC.
        let june = try db.insertSession(.init(id: nil, companyId: co.id!, roundType: .behavioral,
                                              date: Date(timeIntervalSince1970: 1_750_000_000),
                                              durationSeconds: 60, contextNotes: "", coachingStatus: .pending))
        let july = try db.insertSession(.init(id: nil, companyId: co.id!, roundType: .behavioral,
                                              date: Date(timeIntervalSince1970: 1_753_000_000),
                                              durationSeconds: 60, contextNotes: "", coachingStatus: .pending))
        try db.saveFeedback(.init(id: nil, sessionId: june.id!, proseDebrief: "", scoresJSON: "{}",
                                  highlightsJSON: "[]", actionItemsJSON: "[]", overallScore: 3),
                            tags: ["rambling_intro", "no_quantified_impact"])
        try db.saveFeedback(.init(id: nil, sessionId: july.id!, proseDebrief: "", scoresJSON: "{}",
                                  highlightsJSON: "[]", actionItemsJSON: "[]", overallScore: 3),
                            tags: ["rambling_intro"])
        let rows = try db.tagFrequencyByMonth()
        XCTAssertEqual(rows.count, 3)
        // Verifies GRDB's stored Date format is compatible with strftime('%Y-%m', ...).
        XCTAssertEqual(Set(rows.map(\.month)), ["2025-06", "2025-07"])
        XCTAssertTrue(rows.contains(TagMonthCount(month: "2025-06", tag: "rambling_intro", count: 1)))
        XCTAssertTrue(rows.contains(TagMonthCount(month: "2025-06", tag: "no_quantified_impact", count: 1)))
        XCTAssertTrue(rows.contains(TagMonthCount(month: "2025-07", tag: "rambling_intro", count: 1)))
        // Rows are ordered by month ascending.
        XCTAssertEqual(rows.map(\.month), rows.map(\.month).sorted())
    }

    func testPipelineCarriesOverallScoreWhenFeedbackExists() throws {
        let co = try db.fetchOrCreateCompany(named: "Acme")
        let scored = try db.insertSession(.init(id: nil, companyId: co.id!, roundType: .behavioral,
                                                date: Date(timeIntervalSince1970: 1_750_000_000),
                                                durationSeconds: 60, contextNotes: "", coachingStatus: .pending))
        let unscored = try db.insertSession(.init(id: nil, companyId: co.id!, roundType: .technical,
                                                  date: Date(timeIntervalSince1970: 1_750_100_000),
                                                  durationSeconds: 60, contextNotes: "", coachingStatus: .pending))
        try db.saveFeedback(.init(id: nil, sessionId: scored.id!, proseDebrief: "", scoresJSON: "{}",
                                  highlightsJSON: "[]", actionItemsJSON: "[]", overallScore: 3.5),
                            tags: [])
        let pipe = try db.pipeline()
        XCTAssertEqual(pipe.count, 1)
        let summaries = try XCTUnwrap(pipe.first?.sessions)
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.first { $0.id == scored.id! }?.overallScore, 3.5)
        XCTAssertNil(summaries.first { $0.id == unscored.id! }?.overallScore ?? nil)
    }

    func testScoresByDateDecodesDimensionsAndFiltersByRoundType() throws {
        let co = try db.fetchOrCreateCompany(named: "Acme")
        let s = try db.insertSession(.init(id: nil, companyId: co.id!, roundType: .technical,
                                           date: Date(timeIntervalSince1970: 1_750_000_000),
                                           durationSeconds: 60, contextNotes: "", coachingStatus: .pending))
        try db.saveFeedback(.init(id: nil, sessionId: s.id!, proseDebrief: "",
                                  scoresJSON: #"{"structure": 2, "conciseness": 4}"#,
                                  highlightsJSON: "[]", actionItemsJSON: "[]", overallScore: 3.0),
                            tags: [])
        let all = try db.scoresByDate(roundType: nil)
        XCTAssertEqual(all.count, 2)
        let byDim = Dictionary(uniqueKeysWithValues: all.map { ($0.dimension, $0) })
        XCTAssertEqual(byDim["structure"]?.score, 2)
        XCTAssertEqual(byDim["conciseness"]?.score, 4)
        XCTAssertTrue(all.allSatisfy { $0.roundType == .technical })
        XCTAssertTrue(all.allSatisfy { abs($0.date.timeIntervalSince1970 - 1_750_000_000) < 1 })

        XCTAssertEqual(try db.scoresByDate(roundType: .technical).count, 2)
        XCTAssertTrue(try db.scoresByDate(roundType: .behavioral).isEmpty)
    }

    func testCustomInstructionsDefaultsEmptyAndRoundTrips() throws {
        let co = try db.fetchOrCreateCompany(named: "Acme")
        let s = try db.insertSession(.init(id: nil, companyId: co.id!, roundType: .behavioral,
                                           date: Date(), durationSeconds: 60, contextNotes: "",
                                           coachingStatus: .pending))
        XCTAssertEqual(try db.sessionDetail(id: s.id!)?.session.customInstructions, "")
        try db.updateSessionCriteria(id: s.id!, "Grade harshly on system-design depth.")
        XCTAssertEqual(try db.sessionDetail(id: s.id!)?.session.customInstructions,
                       "Grade harshly on system-design depth.")
    }
}
