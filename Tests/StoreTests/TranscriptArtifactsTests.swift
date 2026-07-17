import XCTest
@testable import Store

/// Every fixture here is a verbatim string from the real Debrief database — these are the
/// artifacts WhisperKit actually produced across 11 recorded interviews, not invented ones.
final class TranscriptArtifactsTests: XCTestCase {
    func testDropsPureArtifactSegments() {
        // Whole-segment markers, with the observed casing/spacing variants.
        for junk in ["[BLANK_AUDIO]", "[ Silence ]", "[Silence]", "[silence]", "[ silence ]",
                     "[ Pause ]", "[inaudible]", "[INAUDIBLE]", "[no speech detected]",
                     "[no audio]", "[NOISE]", "(indistinct)", "(scissors snipping)"] {
            XCTAssertEqual(TranscriptArtifacts.clean(junk), "", junk)
        }
    }

    func testDropsTruncatedOpeners() {
        // A ~30s chunk boundary can cut a marker in half, leaving a bare opener as the whole
        // segment — 93 "[" and 16 "(" segments in the real DB.
        XCTAssertEqual(TranscriptArtifacts.clean("["), "")
        XCTAssertEqual(TranscriptArtifacts.clean("("), "")
        XCTAssertEqual(TranscriptArtifacts.clean("  [  "), "")
    }

    func testKeepsSpeechAndStripsAttachedMarker() {
        XCTAssertEqual(TranscriptArtifacts.clean("Yeah. [BLANK_AUDIO]"), "Yeah.")
        XCTAssertEqual(TranscriptArtifacts.clean("[BLANK_AUDIO] Okay."), "Okay.")
        XCTAssertEqual(TranscriptArtifacts.clean("Yeah. [ Pause ]"), "Yeah.")
        XCTAssertEqual(TranscriptArtifacts.clean("if you have any questions for me. [ Silence ]"),
                       "if you have any questions for me.")
        XCTAssertEqual(TranscriptArtifacts.clean("role in your ideal next place? [ Silence ]"),
                       "role in your ideal next place?")
    }

    func testStripsMidSentenceMarkerWithoutLeavingGaps() {
        XCTAssertEqual(TranscriptArtifacts.clean("I owned [inaudible] the billing platform"),
                       "I owned the billing platform")
        // The marker sat right before punctuation — no " ." left behind.
        XCTAssertEqual(TranscriptArtifacts.clean("we shipped it (indistinct) ."), "we shipped it.")
    }

    func testNeverEatsSpeechAfterADanglingOpener() {
        // The regex must not run an unclosed "[" to end-of-string; that would silently delete
        // real speech, which is far worse than leaving one stray bracket.
        XCTAssertEqual(TranscriptArtifacts.clean("so I said [ and then I left"),
                       "so I said [ and then I left")
    }

    func testLeavesCleanSpeechUntouched() {
        let speech = "I led the migration and cut p99 latency from 800ms to 120ms."
        XCTAssertEqual(TranscriptArtifacts.clean(speech), speech)
    }

    func testHandlesMarkersWhoseBracketsWereLost() {
        // Verbatim from the real DB: a chunk boundary ate the opening bracket, or Whisper
        // never emitted brackets at all. The bracket rules cannot see these.
        XCTAssertEqual(TranscriptArtifacts.clean("Silence."), "")
        XCTAssertEqual(TranscriptArtifacts.clean("silence ]"), "")
        XCTAssertEqual(TranscriptArtifacts.clean("silence ] Okay."), "Okay.")
        XCTAssertEqual(TranscriptArtifacts.clean("Yeah. Silence."), "Yeah.")
    }

    func testStripsWhisperSpeakerChangeMarker() {
        // ">>" is Whisper guessing at speaker turns; Debrief already knows the speaker from
        // which stream the audio came in on. Verbatim shapes from the real DB.
        XCTAssertEqual(TranscriptArtifacts.clean(">> Sounds great."), "Sounds great.")
        XCTAssertEqual(TranscriptArtifacts.clean(">>"), "")
        XCTAssertEqual(TranscriptArtifacts.clean("[BLANK_AUDIO] >> It's still startup."),
                       "It's still startup.")
        XCTAssertEqual(TranscriptArtifacts.clean(">> Good morning. How are you?"),
                       "Good morning. How are you?")
    }

    func testMarkerWordsInRealSpeechSurvive() {
        // The bare-word rules are the dangerous ones — they must only fire on a marker word
        // standing alone as a sentence, never on the same word used in conversation.
        for speech in [
            "Music is my hobby, actually.",
            "We sat in silence for a moment and then moved on.",
            "There was a pause while the build ran.",
            "The signal to noise ratio on that team was rough.",
            "I paused the rollout after the first alert.",
            "That silence in the room told me everything.",
        ] {
            XCTAssertEqual(TranscriptArtifacts.clean(speech), speech, "mangled real speech")
        }
    }

    func testInsertSegmentsCleansAndDropsOnWrite() throws {
        let db = try AppDatabase.inMemory()
        let co = try db.fetchOrCreateCompany(named: "Acme")
        let s = try db.insertSession(.init(id: nil, companyId: co.id!, roundType: .behavioral,
                                           date: Date(), durationSeconds: 60, contextNotes: "",
                                           coachingStatus: .pending))
        try db.insertSegments([
            .init(id: nil, sessionId: s.id!, speaker: .them, tStart: 1, text: "Tell me about yourself."),
            .init(id: nil, sessionId: s.id!, speaker: .you, tStart: 2, text: "[BLANK_AUDIO]"),
            .init(id: nil, sessionId: s.id!, speaker: .you, tStart: 3, text: "Sure. [ Silence ]"),
            .init(id: nil, sessionId: s.id!, speaker: .you, tStart: 4, text: "["),
        ])
        let text = try db.transcriptText(sessionId: s.id!)
        XCTAssertFalse(text.contains("BLANK_AUDIO"), text)
        XCTAssertFalse(text.contains("Silence"), text)
        XCTAssertTrue(text.contains("Tell me about yourself."))
        XCTAssertTrue(text.contains("Sure."))
        // The two speechless segments never reached the table.
        let detail = try XCTUnwrap(db.sessionDetail(id: s.id!))
        XCTAssertEqual(detail.segments.count, 2)
    }
}
