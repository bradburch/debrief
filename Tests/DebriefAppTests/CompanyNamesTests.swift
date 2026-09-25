import XCTest
import Store
@testable import DebriefApp

final class CompanyNamesTests: XCTestCase {
    let names = ["Carvana", "Acme", "Globex", "Initech"]

    func testPrefixMatchesLeadThenContainsInRankedOrder() {
        XCTAssertEqual(CompanyNames.matches(for: "ca", in: ["Vacasa", "Carvana", "Acme"]),
                       ["Carvana", "Vacasa"])
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(CompanyNames.matches(for: "GLO", in: names), ["Globex"])
    }

    func testEmptyQueryOffersTopOfListAndExactMatchIsHidden() {
        XCTAssertEqual(CompanyNames.matches(for: "", in: names, limit: 2), ["Carvana", "Acme"])
        XCTAssertEqual(CompanyNames.matches(for: "Acme", in: names), [],
                       "once the field holds a company exactly, nothing is left to suggest")
        XCTAssertEqual(CompanyNames.matches(for: "acme", in: names), ["Acme"],
                       "a different casing is still offered, so picking it fixes the case")
    }

    func testCanonicalAdoptsExistingSpelling() {
        XCTAssertEqual(CompanyNames.canonical("  carvana ", in: names), "Carvana")
        XCTAssertEqual(CompanyNames.canonical("Caravana", in: names), "Caravana",
                       "a different name is not re-spelled — only case is normalized")
        XCTAssertEqual(CompanyNames.canonical("   ", in: names), "")
        XCTAssertEqual(CompanyNames.canonical("unknown", in: names), Company.placeholderName)
        // Re-casing the company being edited is a correction, not a typo to snap back.
        XCTAssertEqual(CompanyNames.canonical("CARVANA", in: names, current: "Carvana"), "CARVANA")
    }

    func testMergeRanksRecordedFirstAndDropsDuplicatesAndPlaceholder() {
        XCTAssertEqual(CompanyNames.merge(recorded: ["Acme", "Globex"],
                                          planned: ["acme", "Hooli", " ", "Unknown", "Hooli"]),
                       ["Acme", "Globex", "Hooli"])
    }
}
