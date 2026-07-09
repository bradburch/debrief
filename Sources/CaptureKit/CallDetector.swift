import Foundation

public struct DetectionSnapshot: Sendable {
    public var micInUse: Bool
    public var meetingAppRunning: Bool
    public init(micInUse: Bool, meetingAppRunning: Bool) {
        self.micInUse = micInUse; self.meetingAppRunning = meetingAppRunning
    }
}

public enum CallDetectorEvent: Equatable, Sendable { case callLikelyStarted, callLikelyEnded }

/// Pure state machine: feed it snapshots, it emits at most one event per transition.
/// Mic-in-use is the load-bearing signal (works for browser-tab Meet calls);
/// a running meeting app upgrades confidence and skips the confirmation window.
public struct CallDetector: Sendable {
    private let confirmation: TimeInterval
    public private(set) var inCall = false
    private var micActiveSince: Date?
    private var micFreeSince: Date?

    public init(confirmation: TimeInterval = 10) { self.confirmation = confirmation }

    public mutating func ingest(_ snapshot: DetectionSnapshot, at now: Date) -> CallDetectorEvent? {
        if !inCall {
            guard snapshot.micInUse else { micActiveSince = nil; return nil }
            if snapshot.meetingAppRunning {
                inCall = true; micFreeSince = nil
                return .callLikelyStarted
            }
            if let since = micActiveSince {
                if now.timeIntervalSince(since) >= confirmation {
                    inCall = true; micFreeSince = nil
                    return .callLikelyStarted
                }
            } else {
                micActiveSince = now
            }
            return nil
        } else {
            if snapshot.micInUse { micFreeSince = nil; return nil }
            if let since = micFreeSince {
                if now.timeIntervalSince(since) >= confirmation {
                    inCall = false; micActiveSince = nil; micFreeSince = nil
                    return .callLikelyEnded
                }
            } else {
                micFreeSince = now
            }
            return nil
        }
    }
}
