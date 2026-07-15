import XCTest
@testable import CaptureKit

final class CallDetectorTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testMicAloneNeedsConfirmationWindow() {
        var d = CallDetector(confirmation: 10)
        XCTAssertNil(d.ingest(.init(micInUse: true, meetingAppRunning: false), at: t0))
        XCTAssertNil(d.ingest(.init(micInUse: true, meetingAppRunning: false), at: t0.addingTimeInterval(5)))
        XCTAssertEqual(d.ingest(.init(micInUse: true, meetingAppRunning: false), at: t0.addingTimeInterval(11)),
                       .callLikelyStarted)
        // No duplicate event while call continues.
        XCTAssertNil(d.ingest(.init(micInUse: true, meetingAppRunning: false), at: t0.addingTimeInterval(20)))
        XCTAssertTrue(d.inCall)
    }

    func testMeetingAppPlusMicStartsImmediately() {
        var d = CallDetector(confirmation: 10)
        XCTAssertEqual(d.ingest(.init(micInUse: true, meetingAppRunning: true), at: t0), .callLikelyStarted)
    }

    func testMicBlipDoesNotTrigger() {
        var d = CallDetector(confirmation: 10)
        XCTAssertNil(d.ingest(.init(micInUse: true, meetingAppRunning: false), at: t0))
        XCTAssertNil(d.ingest(.init(micInUse: false, meetingAppRunning: false), at: t0.addingTimeInterval(3)))
        // Mic returns; the confirmation clock restarts.
        XCTAssertNil(d.ingest(.init(micInUse: true, meetingAppRunning: false), at: t0.addingTimeInterval(5)))
        XCTAssertNil(d.ingest(.init(micInUse: true, meetingAppRunning: false), at: t0.addingTimeInterval(14)))
        XCTAssertEqual(d.ingest(.init(micInUse: true, meetingAppRunning: false), at: t0.addingTimeInterval(16)),
                       .callLikelyStarted)
    }

    func testCallEndsAfterMicFreeConfirmation() {
        var d = CallDetector(confirmation: 10)
        _ = d.ingest(.init(micInUse: true, meetingAppRunning: true), at: t0)
        XCTAssertNil(d.ingest(.init(micInUse: false, meetingAppRunning: true), at: t0.addingTimeInterval(60)))
        XCTAssertEqual(d.ingest(.init(micInUse: false, meetingAppRunning: true), at: t0.addingTimeInterval(71)),
                       .callLikelyEnded)
        XCTAssertFalse(d.inCall)
    }

    // Start uses the short window; end uses the (longer) endConfirmation independently, so a
    // transient mic-free blip shorter than endConfirmation must NOT end an active call.
    func testStartAndEndUseSeparateConfirmationWindows() {
        var d = CallDetector(confirmation: 5, endConfirmation: 10)
        // Browser-only start: fires at 5s (short window), not 10s.
        XCTAssertNil(d.ingest(.init(micInUse: true, meetingAppRunning: false), at: t0))
        XCTAssertEqual(d.ingest(.init(micInUse: true, meetingAppRunning: false), at: t0.addingTimeInterval(5)),
                       .callLikelyStarted)
        // A 7s mic-free blip (> start window, < end window) must not end the call.
        XCTAssertNil(d.ingest(.init(micInUse: false, meetingAppRunning: false), at: t0.addingTimeInterval(10)))
        XCTAssertNil(d.ingest(.init(micInUse: false, meetingAppRunning: false), at: t0.addingTimeInterval(17)))
        XCTAssertTrue(d.inCall, "a blip shorter than endConfirmation should not truncate the call")
        // Mic comes back — still in call, window resets.
        XCTAssertNil(d.ingest(.init(micInUse: true, meetingAppRunning: false), at: t0.addingTimeInterval(18)))
        XCTAssertTrue(d.inCall)
    }
}
