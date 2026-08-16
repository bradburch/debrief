import XCTest
@testable import DebriefApp
import Store

/// The footnote under the unfiltered score chart makes a factual claim about the reader's own
/// data ("these lines mix two round types"). It used to name two dimensions from the shipped
/// rubric — but the rubric is markdown the user edits, so on any other prompts folder the
/// sentence named dimensions that didn't overlap, or stayed on screen when nothing did.
final class TrendsViewTests: XCTestCase {
    func testOnlyDimensionsScoredByMoreThanOneRoundTypeAreNamed() {
        let points: [(dimension: String, roundType: RoundType)] = [
            ("structure", .behavioral),
            ("structure", .technical),        // shared → named
            ("technical_depth", .technical),  // one round only → not named
            ("questions_asked", .behavioral),
        ]
        XCTAssertEqual(TrendsView.dimensionsSharedAcrossRounds(in: points), ["structure"])
    }

    func testNoOverlapNamesNothingSoTheFootnoteCanBeHidden() {
        let points: [(dimension: String, roundType: RoundType)] = [
            ("technical_depth", .technical), ("structure", .technical),
        ]
        XCTAssertTrue(TrendsView.dimensionsSharedAcrossRounds(in: points).isEmpty,
                      "a footnote would claim an ambiguity that isn't in the data")
        XCTAssertTrue(TrendsView.dimensionsSharedAcrossRounds(in: []).isEmpty)
    }

    /// Sorted, so the sentence doesn't reshuffle itself between reloads of the same data —
    /// Dictionary iteration order is not stable across runs.
    func testNamesComeBackSorted() {
        let points: [(dimension: String, roundType: RoundType)] = [
            ("quantified_impact", .behavioral), ("quantified_impact", .technical),
            ("conciseness", .behavioral), ("conciseness", .systemDesign),
        ]
        XCTAssertEqual(TrendsView.dimensionsSharedAcrossRounds(in: points),
                       ["conciseness", "quantified_impact"])
    }
}
