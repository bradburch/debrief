import Foundation
import GRDB

public enum CompanyStatus: String, Codable, CaseIterable, Sendable { case active, dead, offer }

/// String-backed (not an enum) so users can add round types by dropping a
/// prompt overlay file — see PromptStore.availableRoundTypes().
public struct RoundType: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let recruiterScreen = RoundType(rawValue: "recruiter_screen")
    public static let behavioral = RoundType(rawValue: "behavioral")
    public static let technical = RoundType(rawValue: "technical")
    public static let systemDesign = RoundType(rawValue: "system_design")
    public static let productSense = RoundType(rawValue: "product_sense")
    public static let techDeepDive = RoundType(rawValue: "tech_deep_dive")
    public static let builtins: [RoundType] = [.recruiterScreen, .behavioral, .technical, .systemDesign, .productSense, .techDeepDive]

    /// "take_home_review" → "Take Home Review". Matches the old hardcoded
    /// names for all four builtins, so no special-casing.
    public var displayName: String {
        rawValue.split(separator: "_").map(\.capitalized).joined(separator: " ")
    }

    // Explicit single-value coding: memberwise synthesis would encode
    // {"rawValue": "..."} and corrupt DB round-trips.
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public enum Speaker: String, Codable, Sendable { case you = "YOU", them = "THEM" }

public enum CoachingStatus: String, Codable, Sendable { case pending, complete, failed }

public struct Company: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "company"
    public var id: Int64?
    public var name: String
    public var status: CompanyStatus
    public init(id: Int64? = nil, name: String, status: CompanyStatus = .active) {
        self.id = id; self.name = name; self.status = status
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct InterviewSession: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "session"
    public var id: Int64?
    public var companyId: Int64
    public var roundType: RoundType
    public var date: Date
    public var durationSeconds: Int
    public var contextNotes: String
    public var coachingStatus: CoachingStatus
    public var customInstructions: String
    public init(id: Int64?, companyId: Int64, roundType: RoundType, date: Date,
                durationSeconds: Int, contextNotes: String, coachingStatus: CoachingStatus,
                customInstructions: String = "") {
        self.id = id; self.companyId = companyId; self.roundType = roundType; self.date = date
        self.durationSeconds = durationSeconds; self.contextNotes = contextNotes; self.coachingStatus = coachingStatus
        self.customInstructions = customInstructions
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct TranscriptSegmentRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "transcriptSegment"
    public var id: Int64?
    public var sessionId: Int64
    public var speaker: Speaker
    public var tStart: Double
    public var text: String
    public init(id: Int64?, sessionId: Int64, speaker: Speaker, tStart: Double, text: String) {
        self.id = id; self.sessionId = sessionId; self.speaker = speaker; self.tStart = tStart; self.text = text
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct FeedbackRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "feedback"
    public var id: Int64?
    public var sessionId: Int64
    public var proseDebrief: String
    public var scoresJSON: String
    public var highlightsJSON: String
    public var actionItemsJSON: String
    public var overallScore: Double
    public init(id: Int64?, sessionId: Int64, proseDebrief: String, scoresJSON: String,
                highlightsJSON: String, actionItemsJSON: String, overallScore: Double) {
        self.id = id; self.sessionId = sessionId; self.proseDebrief = proseDebrief
        self.scoresJSON = scoresJSON; self.highlightsJSON = highlightsJSON
        self.actionItemsJSON = actionItemsJSON; self.overallScore = overallScore
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct WeaknessTagRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "weaknessTag"
    public var id: Int64?
    public var sessionId: Int64
    public var tag: String
    public init(id: Int64? = nil, sessionId: Int64, tag: String) {
        self.id = id; self.sessionId = sessionId; self.tag = tag
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
