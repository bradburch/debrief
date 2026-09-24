import XCTest
import GRDB
@testable import Store

final class StoreTests: XCTestCase {
    var db: AppDatabase!

    override func setUpWithError() throws { db = try AppDatabase.inMemory() }

    func testFetchOrCreateCompanyIsIdempotent() throws {
        let a = try db.fetchOrCreateCompany(named: "Acme")
        let b = try db.fetchOrCreateCompany(named: "Acme")
        XCTAssertEqual(a.id, b.id)
    }

    func testDeleteCompanyIfUnusedKeepsACompanyWithSessionsAndRemovesAnEmptyOne() throws {
        let used = try db.fetchOrCreateCompany(named: "Acme")
        _ = try db.insertSession(InterviewSession(
            id: nil, companyId: used.id!, roundType: .behavioral,
            date: Date(timeIntervalSince1970: 1_750_000_000),
            durationSeconds: 60, contextNotes: "", coachingStatus: .pending))
        let empty = try db.fetchOrCreateCompany(named: "Globex")

        try db.deleteCompanyIfUnused(id: used.id!)
        try db.deleteCompanyIfUnused(id: empty.id!)

        XCTAssertNotNil(try db.findCompany(named: "Acme"))
        XCTAssertNil(try db.findCompany(named: "Globex"))
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

    func testUpdateSessionRoundTypeChangesOnlyThatSession() throws {
        let co = try db.fetchOrCreateCompany(named: "Acme")
        func makeSession() throws -> Int64 {
            try db.insertSession(InterviewSession(
                id: nil, companyId: co.id!, roundType: .behavioral,
                date: Date(timeIntervalSince1970: 1_750_000_000),
                durationSeconds: 60, contextNotes: "", coachingStatus: .pending)).id!
        }
        let a = try makeSession()
        let b = try makeSession()

        try db.updateSessionRoundType(id: a, .systemDesign)
        XCTAssertEqual(try db.sessionDetail(id: a)?.session.roundType, .systemDesign)
        XCTAssertEqual(try db.sessionDetail(id: b)?.session.roundType, .behavioral)  // sibling untouched
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

    func testPipelineRanksActiveFirstAndDeadLast() throws {
        let dead = try db.fetchOrCreateCompany(named: "Aardvark")   // alphabetically first
        let old = try db.fetchOrCreateCompany(named: "Beta")
        let recent = try db.fetchOrCreateCompany(named: "Gamma")
        for (co, t) in [(dead, 3.0), (old, 1.0), (recent, 2.0)] {
            _ = try db.insertSession(.init(id: nil, companyId: co.id!, roundType: .technical,
                                           date: Date(timeIntervalSince1970: 1_750_000_000 + t * 86_400),
                                           durationSeconds: 60, contextNotes: "", coachingStatus: .pending))
        }
        try db.updateCompanyStatus(id: dead.id!, status: .dead)
        XCTAssertEqual(try db.pipeline().map(\.company.name), ["Gamma", "Beta", "Aardvark"])
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

    /// `running` marks an LLM call in flight, so a Retry sweep must leave it alone — and a
    /// launch must hand it back, since only a dead process can leave one behind.
    func testRunningCoachingIsSkippedBySweepsButReclaimedOnLaunch() throws {
        let co = try db.fetchOrCreateCompany(named: "Acme")
        func makeSession(_ status: CoachingStatus) throws -> Int64 {
            let s = try db.insertSession(.init(id: nil, companyId: co.id!, roundType: .behavioral,
                                               date: Date(), durationSeconds: 60, contextNotes: "",
                                               coachingStatus: status))
            try db.insertSegments([.init(id: nil, sessionId: s.id!, speaker: .you, tStart: 0, text: "hello there")])
            return s.id!
        }
        let running = try makeSession(.running)
        let pending = try makeSession(.pending)

        XCTAssertEqual(try db.sessionsNeedingCoaching().map(\.id), [pending])
        // sessionsWithTranscript is deliberately untouched: it also feeds exportAll.
        XCTAssertEqual(try db.sessionsWithTranscript().count, 2)

        XCTAssertEqual(try db.resetRunningCoaching(), 1)
        XCTAssertEqual(try db.sessionDetail(id: running)?.session.coachingStatus, .pending)
        XCTAssertEqual(Set(try db.sessionsNeedingCoaching().map(\.id)), [running, pending])
    }

    /// The claim itself. `coach()` runs off the main actor from three call sites, so "read the
    /// status, then write `running`" is two racing statements — both callers read `pending`,
    /// both bill an LLM call, both write the same feedback row. Read and write live in one
    /// write transaction so the second claim can only ever see the first one's result.
    func testClaimCoachingIsExclusiveAndReportsThePriorStatus() throws {
        let co = try db.fetchOrCreateCompany(named: "Acme")
        let s = try db.insertSession(.init(id: nil, companyId: co.id!, roundType: .behavioral,
                                           date: Date(), durationSeconds: 60, contextNotes: "",
                                           coachingStatus: .pending))
        let id = try XCTUnwrap(s.id)

        XCTAssertEqual(try db.claimCoaching(sessionId: id), .pending,
                       "the first claim must report the status it replaced")
        XCTAssertEqual(try db.sessionDetail(id: id)?.session.coachingStatus, .running)
        XCTAssertNil(try db.claimCoaching(sessionId: id),
                     "a second caller claimed a session already being coached")
        XCTAssertEqual(try db.sessionDetail(id: id)?.session.coachingStatus, .running,
                       "the refused claim still wrote")

        // A re-coach of a finished session claims too, and must report `complete` — that is
        // what a cancelled run puts back, and restoring `pending` there would drag a session
        // holding good feedback into every retry sweep.
        try db.setCoachingStatus(sessionId: id, .complete)
        XCTAssertEqual(try db.claimCoaching(sessionId: id), .complete)

        // A session that isn't there is nothing to claim, not a crash.
        XCTAssertNil(try db.claimCoaching(sessionId: 9_999))
    }

    /// `plannedCalls` filters rather than purges, so a plan you never recorded drops out of
    /// every surface after 24h — including the list its only delete button lives on. The
    /// launch purge is what stops "invisible" from also meaning "permanent".
    func testStalePlannedCallsArePurgedButRecentAndFutureOnesSurvive() throws {
        let now = Date()
        let ancient = try db.insertPlannedCall(.init(companyName: "Ancient", roundType: .behavioral,
                                                     scheduledDate: now.addingTimeInterval(-40 * 86_400)))
        let lastWeek = try db.insertPlannedCall(.init(companyName: "LastWeek", roundType: .behavioral,
                                                      scheduledDate: now.addingTimeInterval(-7 * 86_400)))
        let tomorrow = try db.insertPlannedCall(.init(companyName: "Upcoming", roundType: .behavioral,
                                                      scheduledDate: now.addingTimeInterval(86_400)))

        XCTAssertEqual(try db.purgeStalePlannedCalls(now: now), 1)

        // Read with a window wide enough to include the survivors that `plannedCalls` filters.
        let remaining = try db.plannedCalls(now: now.addingTimeInterval(-40 * 86_400)).map(\.id)
        XCTAssertFalse(remaining.contains(ancient.id), "a 40-day-old plan outlived the purge")
        XCTAssertTrue(remaining.contains(lastWeek.id), "a week-old plan is still worth recovering")
        XCTAssertTrue(remaining.contains(tomorrow.id))
        // Idempotent: a second launch finds nothing left to do.
        XCTAssertEqual(try db.purgeStalePlannedCalls(now: now), 0)
    }

    func testPlannedCallsRoundTripAndComeBackSoonestFirst() throws {
        let later = try db.insertPlannedCall(.init(companyName: "Globex", role: "Staff iOS",
                                                   roundType: .technical,
                                                   scheduledDate: Date(timeIntervalSinceNow: 7_200),
                                                   notes: "panel of two",
                                                   customInstructions: "Grade on API design."))
        let sooner = try db.insertPlannedCall(.init(companyName: "Acme", roundType: .behavioral,
                                                    scheduledDate: Date(timeIntervalSinceNow: 3_600)))

        let all = try db.plannedCalls()
        XCTAssertEqual(all.map(\.id), [sooner.id, later.id], "planned calls must come back soonest first")
        let stored = try XCTUnwrap(all.last)
        XCTAssertEqual(stored.companyName, "Globex")
        XCTAssertEqual(stored.role, "Staff iOS")
        XCTAssertEqual(stored.roundType, .technical)
        // Read the raw column, not just the round-trip: encode and decode are symmetric, so a
        // RoundType stored as {"rawValue":"technical"} would round-trip fine here and then
        // blank every Picker that binds by tag.
        let rawRoundType = try db.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT roundType FROM plannedCall WHERE id = ?",
                                arguments: [stored.id])
        }
        XCTAssertEqual(rawRoundType, "technical")
        XCTAssertEqual(stored.notes, "panel of two")
        XCTAssertEqual(stored.customInstructions, "Grade on API design.")
        // The defaulted columns, which the record's own defaults also cover.
        XCTAssertEqual(all.first?.role, "")
        XCTAssertEqual(all.first?.notes, "")
        XCTAssertEqual(all.first?.customInstructions, "")

        var edited = stored
        edited.companyName = "Globex Inc"
        edited.roundType = .systemDesign
        edited.customInstructions = "Grade on scalability."
        try db.updatePlannedCall(edited)
        let after = try XCTUnwrap(db.plannedCalls().last)
        XCTAssertEqual(after.companyName, "Globex Inc")
        XCTAssertEqual(after.roundType, .systemDesign)
        XCTAssertEqual(after.customInstructions, "Grade on scalability.")

        try db.deletePlannedCall(id: XCTUnwrap(sooner.id))
        XCTAssertEqual(try db.plannedCalls().map(\.id), [later.id])
        // Editing a plan that a finalize already consumed is a no-op, not a throw.
        XCTAssertNoThrow(try db.updatePlannedCall(sooner))
    }

    /// A plan is consumed only by a *successful* finalize, so the ones you never recorded
    /// accumulate — and ascending order parks the oldest of them at the top of the sidebar
    /// list and the pre-fill menu. The window is a filter, not a purge: the 24h grace keeps
    /// an interview that ran late (or whose finalize failed overnight) available the next
    /// morning, which is exactly when the recovery prompt needs it.
    func testPlannedCallsDropStaleEntriesButKeepTheOvernightGrace() throws {
        let now = Date()
        let lastWeek = try db.insertPlannedCall(.init(companyName: "Stale", roundType: .behavioral,
                                                      scheduledDate: now.addingTimeInterval(-7 * 86_400)))
        let anHourAgo = try db.insertPlannedCall(.init(companyName: "RanLate", roundType: .behavioral,
                                                       scheduledDate: now.addingTimeInterval(-3_600)))
        let tomorrow = try db.insertPlannedCall(.init(companyName: "Upcoming", roundType: .behavioral,
                                                      scheduledDate: now.addingTimeInterval(86_400)))

        let offered = try db.plannedCalls(now: now)
        XCTAssertEqual(offered.map(\.id), [anHourAgo.id, tomorrow.id],
                       "a week-old plan is still at the top of every pre-fill menu")
        XCTAssertFalse(offered.contains { $0.id == lastWeek.id })
        // Filtered, not purged — the row is still there to be deleted or re-dated.
        XCTAssertEqual(try db.plannedCalls(now: now.addingTimeInterval(-7 * 86_400)).count, 3)

        // And the list is bounded, so a runaway backlog can't fill the sidebar.
        for i in 0..<25 {
            _ = try db.insertPlannedCall(.init(companyName: "Bulk\(i)", roundType: .behavioral,
                                               scheduledDate: now.addingTimeInterval(Double(i) * 60)))
        }
        XCTAssertEqual(try db.plannedCalls(now: now).count, 20)
    }

    /// The row can vanish under an open editor: the sheet is modal to the window, and the
    /// call it plans can finish (and consume it) at any moment. Silently dropping the typing
    /// is the one outcome that isn't recoverable — a duplicate row is one right-click away.
    func testUpdatingAConsumedPlanReportsTheMissingRowRatherThanFailingQuietly() throws {
        let plan = try db.insertPlannedCall(.init(companyName: "Acme", roundType: .behavioral,
                                                  scheduledDate: Date(timeIntervalSinceNow: 3_600)))
        var edited = plan
        edited.companyName = "Acme Corp"
        XCTAssertTrue(try db.updatePlannedCall(edited), "an existing row must report as updated")

        try db.deletePlannedCall(id: XCTUnwrap(plan.id))
        XCTAssertFalse(try db.updatePlannedCall(edited), "a consumed row must report as missing")
        XCTAssertFalse(try db.updatePlannedCall(.init(companyName: "New", roundType: .behavioral,
                                                      scheduledDate: Date())),
                       "a plan with no id was never in the table")
    }

    /// Planned calls are not sessions, and every session-shaped query has to keep agreeing:
    /// one showing up in Sessions, Pipeline or Trends would be a zero-minute phantom round.
    func testPlannedCallsAreInvisibleToEverySessionQuery() throws {
        _ = try db.insertPlannedCall(.init(companyName: "Acme", roundType: .behavioral,
                                           scheduledDate: Date()))
        XCTAssertTrue(try db.allSessionSummaries().isEmpty)
        XCTAssertTrue(try db.pipeline().isEmpty, "a planned call must not create a company either")
        XCTAssertTrue(try db.scoresByDate(roundType: nil).isEmpty)
        XCTAssertTrue(try db.sessionsNeedingCoaching().isEmpty)
        XCTAssertTrue(try db.sessionsWithTranscript().isEmpty)
        XCTAssertEqual(try db.sessionCount(forRoundType: .behavioral), 0)
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
