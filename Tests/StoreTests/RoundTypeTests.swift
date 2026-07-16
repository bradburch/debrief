import XCTest
@testable import Store

final class RoundTypeTests: XCTestCase {
    func testDisplayNameDerivedFromRawValue() {
        XCTAssertEqual(RoundType.recruiterScreen.displayName, "Recruiter Screen")
        XCTAssertEqual(RoundType.behavioral.displayName, "Behavioral")
        XCTAssertEqual(RoundType.systemDesign.displayName, "System Design")
        XCTAssertEqual(RoundType(rawValue: "take_home_review").displayName, "Take Home Review")
    }

    /// Existing DB rows store the bare raw string; the struct must encode identically
    /// to the old enum or every stored session breaks.
    func testEncodesAsBareString() throws {
        let data = try JSONEncoder().encode([RoundType.behavioral])
        XCTAssertEqual(String(data: data, encoding: .utf8), "[\"behavioral\"]")
        let decoded = try JSONDecoder().decode([RoundType].self, from: Data("[\"pair_programming\"]".utf8))
        XCTAssertEqual(decoded, [RoundType(rawValue: "pair_programming")])
    }

    func testBuiltinsOrder() {
        XCTAssertEqual(RoundType.builtins,
                       [.recruiterScreen, .behavioral, .technical, .systemDesign, .productSense, .techDeepDive])
    }
}
