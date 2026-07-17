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
    /// names for every builtin, so no special-casing.
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

/// The interviewer's would-I-advance call — the headline signal of a debrief.
///
/// Deliberately has no neutral case: a four-point forced choice, mirroring the discrete
/// ordinal recommendations real scorecards record (interviewing.io's yes/no advance,
/// Amazon's Strongly Inclined → Strongly Not Inclined). The LLM is asked for this
/// directly and told NOT to derive it from the dimension scores — real scorecards
/// co-record the verdict and the ratings rather than computing one from the other.
public enum Advancement: String, Codable, Equatable, Sendable, CaseIterable {
    case strongNo = "strong_no"
    case leanNo = "lean_no"
    case leanYes = "lean_yes"
    case strongYes = "strong_yes"

    public var displayName: String {
        switch self {
        case .strongNo: return "Strong No"
        case .leanNo: return "Lean No"
        case .leanYes: return "Lean Yes"
        case .strongYes: return "Strong Yes"
        }
    }

    public var advances: Bool { self == .leanYes || self == .strongYes }
}

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
    /// Raw rather than `Advancement` so a pre-v3 row's "" round-trips instead of
    /// failing to decode. Read it through `advancementValue`.
    public var advancement: String
    public var advancementRationale: String
    /// [{t,note}] JSON — process/next-steps/timeline the interviewer mentioned. "[]" for
    /// pre-v4 rows and whenever the topic never came up.
    public var processNotesJSON: String

    /// nil for feedback written before the verdict existed (migration v3).
    public var advancementValue: Advancement? { Advancement(rawValue: advancement) }

    public init(id: Int64?, sessionId: Int64, proseDebrief: String, scoresJSON: String,
                highlightsJSON: String, actionItemsJSON: String, overallScore: Double,
                advancement: String = "", advancementRationale: String = "",
                processNotesJSON: String = "[]") {
        self.id = id; self.sessionId = sessionId; self.proseDebrief = proseDebrief
        self.scoresJSON = scoresJSON; self.highlightsJSON = highlightsJSON
        self.actionItemsJSON = actionItemsJSON; self.overallScore = overallScore
        self.advancement = advancement; self.advancementRationale = advancementRationale
        self.processNotesJSON = processNotesJSON
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
