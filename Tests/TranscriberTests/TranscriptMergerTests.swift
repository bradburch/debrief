import XCTest
@testable import Transcriber

final class TranscriptMergerTests: XCTestCase {
    func testMergeInterleavesChronologically() {
        let you = [TimedText(start: 198, text: "At my last role..."),
                   TimedText(start: 260, text: "So the outcome was...")]
        let them = [TimedText(start: 192, text: "Tell me about a conflict."),
                    TimedText(start: 255, text: "And then?")]
        let lines = TranscriptMerger.merge(you: you, them: them)
        XCTAssertEqual(lines.map(\.start), [192, 198, 255, 260])
        XCTAssertEqual(lines.map(\.speaker), [.them, .you, .them, .you])
    }

    func testMergeCoalescesConsecutiveSameSpeakerLines() {
        // Two adjacent chunks from the same stream within 2s are one utterance.
        let you = [TimedText(start: 10.0, text: "I started by"),
                   TimedText(start: 11.5, text: "profiling the query.")]
        let lines = TranscriptMerger.merge(you: you, them: [])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "I started by profiling the query.")
    }

    func testCoalescingAnchorAdvancesAcrossLongRuns() {
        // Three segments, each 1.5s apart: all one utterance even though
        // the third starts 3.0s after the first.
        let you = [TimedText(start: 0.0, text: "I started by"),
                   TimedText(start: 1.5, text: "profiling the query"),
                   TimedText(start: 3.0, text: "and found the missing index.")]
        let lines = TranscriptMerger.merge(you: you, them: [])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "I started by profiling the query and found the missing index.")
        XCTAssertEqual(lines[0].start, 0.0)
    }

    func testMergeSkipsEmptyAndWhitespaceText() {
        let them = [TimedText(start: 5, text: "  "), TimedText(start: 6, text: "Hello.")]
        let lines = TranscriptMerger.merge(you: [], them: them)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Hello.")
    }
}
