import Foundation

public struct Highlight: Codable, Equatable, Sendable {
    public var t: String
    public var note: String
    public init(t: String, note: String) { self.t = t; self.note = note }
}

public struct CoachingResult: Codable, Equatable, Sendable {
    public var proseDebrief: String
    public var scores: [String: Int]
    public var weaknessTags: [String]
    public var highlights: [Highlight]
    public var actionItems: [String]

    public var overallScore: Double {
        guard !scores.isEmpty else { return 0 }
        return Double(scores.values.reduce(0, +)) / Double(scores.count)
    }

    enum CodingKeys: String, CodingKey {
        case proseDebrief = "prose_debrief"
        case scores
        case weaknessTags = "weakness_tags"
        case highlights
        case actionItems = "action_items"
    }

    public init(proseDebrief: String, scores: [String: Int], weaknessTags: [String],
                highlights: [Highlight], actionItems: [String]) {
        self.proseDebrief = proseDebrief; self.scores = scores; self.weaknessTags = weaknessTags
        self.highlights = highlights; self.actionItems = actionItems
    }
}
