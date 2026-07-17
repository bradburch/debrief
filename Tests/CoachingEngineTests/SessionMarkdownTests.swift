import XCTest
import Store
@testable import CoachingEngine

final class SessionMarkdownTests: XCTestCase {
    private func fixture() -> SessionDetail {
        let session = InterviewSession(
            id: 42, companyId: 1, roundType: .productSense,
            date: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 1800,
            contextNotes: "senior PM loop", coachingStatus: .complete, customInstructions: "")
        let company = Company(id: 1, name: "Acme Corp!", status: .active)
        let segments = [
            TranscriptSegmentRecord(id: 1, sessionId: 42, speaker: .them, tStart: 0, text: "Tell me about a product you shipped."),
            TranscriptSegmentRecord(id: 2, sessionId: 42, speaker: .you, tStart: 4, text: "I led the checkout redesign."),
        ]
        let feedback = FeedbackRecord(
            id: 1, sessionId: 42,
            proseDebrief: "Strong structure, thin on metrics.",
            scoresJSON: #"{"structure":4,"metrics":2}"#,
            highlightsJSON: #"[{"t":"00:00:04","note":"Clear ownership framing"}]"#,
            actionItemsJSON: #"["Quantify impact with a metric"]"#,
            overallScore: 3.0,
            advancement: "lean_yes", advancementRationale: "Advances on communication.",
            processNotesJSON: #"[{"t":"00:10:00","note":"Next round in a week"}]"#)
        return SessionDetail(session: session, company: company, segments: segments, feedback: feedback, tags: ["weak_metrics"])
    }

    func testRenderContainsHeadlineSections() {
        let md = SessionMarkdown.render(fixture())
        XCTAssertTrue(md.contains("# Acme Corp! — Product Sense"))
        XCTAssertTrue(md.contains("## Verdict: Lean Yes"))
        XCTAssertTrue(md.contains("Advances on communication."))
        XCTAssertTrue(md.contains("- structure: 4"))
        XCTAssertTrue(md.contains("Quantify impact with a metric"))
        XCTAssertTrue(md.contains("Next round in a week"))
        XCTAssertTrue(md.contains("`weak_metrics`"))
        XCTAssertTrue(md.contains("[00:00:04] YOU: I led the checkout redesign."))
    }

    func testFilenameIsDeterministicAndSlugged() {
        XCTAssertEqual(SessionMarkdown.filename(for: fixture()), "2023-11-14-acme-corp-product_sense-42.md")
    }

    func testRenderWithoutFeedbackStillHasTranscript() {
        let base = fixture()
        let noFeedback = SessionDetail(session: base.session, company: base.company,
                                       segments: base.segments, feedback: nil, tags: [])
        let md = SessionMarkdown.render(noFeedback)
        XCTAssertFalse(md.contains("## Verdict"))
        XCTAssertTrue(md.contains("## Transcript"))
        XCTAssertTrue(md.contains("[00:00:00] THEM: Tell me about a product you shipped."))
    }
}
