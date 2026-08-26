import XCTest
@testable import DebriefApp
import Store
import CoachingEngine
import Transcriber

/// `startTimers` has no other coverage, and its failure mode is silent.
///
/// `Timer(timeInterval:)` — unlike `Timer.scheduledTimer` — returns an **unscheduled** timer,
/// so dropping a `RunLoop.main.add` leaves a timer that is fully constructed, `isValid`, and
/// never fires. For `detectTimer` that is call detection dying with no error, no crash and
/// nothing on screen to notice; for `meterTimer` it is every level meter latching again.
///
/// Asserted with `CFRunLoopContainsTimer` rather than by waiting for fires: the honest
/// wait is one health interval (10s), which would swamp a suite that runs in seven.
@MainActor
final class TimerSchedulingTests: XCTestCase {
    private func timer(_ env: AppEnvironment, _ label: String) throws -> Timer {
        let found = Mirror(reflecting: env).children.first { $0.label == label }?.value
        return try XCTUnwrap(found as? Timer, "\(label) was never assigned")
    }

    func testEveryTimerIsScheduledInCommonModes() throws {
        let db = try AppDatabase.inMemory()
        let env = try AppEnvironmentTests().makeEnv(db: db)

        for label in ["detectTimer", "healthTimer", "meterTimer"] {
            let t = try timer(env, label)
            XCTAssertTrue(t.isValid, "\(label) is invalid")
            // The load-bearing assertion. `isValid` is true for an unscheduled timer too, so
            // it cannot tell a working timer from one that will never fire.
            XCTAssertTrue(
                CFRunLoopContainsTimer(CFRunLoopGetMain(), t, CFRunLoopMode.commonModes),
                "\(label) is not registered in the main run loop's common modes — it will "
                + "never fire, or will stall for the duration of any tracking gesture")
        }
    }
}
