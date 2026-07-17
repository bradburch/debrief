import Foundation
import Store

public struct Highlight: Codable, Equatable, Sendable {
    public var t: String
    public var note: String
    public init(t: String, note: String) { self.t = t; self.note = note }
}

public struct CoachingResult: Codable, Equatable, Sendable {
    public var proseDebrief: String
    public var scores: [String: Int]
    public var advancement: Advancement
    public var advancementRationale: String
    public var weaknessTags: [String]
    public var highlights: [Highlight]
    public var actionItems: [String]
    /// What THEM said about the process, next steps, and timeline. Reuses `Highlight`'s
    /// {t, note} shape so the timestamps are click-to-jump like highlights already are.
    /// Empty is the correct and common answer — the topic often never comes up.
    public var processNotes: [Highlight]

    /// Mean of the dimension scores. Kept as a secondary trend signal only — it is NOT the
    /// headline and NOT what `advancement` is derived from. Two reasons it must not be read
    /// as "did I pass": the dimension set now varies by round type, so means are only
    /// comparable within a round type; and LLM judges compress toward the top of a 1-5 scale,
    /// so averaging several already-compressed dimensions compresses further and discriminates
    /// poorly. `advancement` is the signal; this is a trend line.
    public var overallScore: Double {
        guard !scores.isEmpty else { return 0 }
        return Double(scores.values.reduce(0, +)) / Double(scores.count)
    }

    enum CodingKeys: String, CodingKey {
        case proseDebrief = "prose_debrief"
        case scores
        case advancement
        case advancementRationale = "advancement_rationale"
        case weaknessTags = "weakness_tags"
        case highlights
        case actionItems = "action_items"
        case processNotes = "process_notes"
    }

    public init(proseDebrief: String, scores: [String: Int], advancement: Advancement,
                advancementRationale: String, weaknessTags: [String],
                highlights: [Highlight], actionItems: [String], processNotes: [Highlight] = []) {
        self.proseDebrief = proseDebrief; self.scores = scores
        self.advancement = advancement; self.advancementRationale = advancementRationale
        self.weaknessTags = weaknessTags
        self.highlights = highlights; self.actionItems = actionItems
        self.processNotes = processNotes
    }

    /// Rejects scores outside the rubric's 1-5 band.
    ///
    /// Nothing else can: the Messages API refuses `minimum`/`maximum` on integer types, and
    /// the local-LLM path gets no schema at all — so the band lives only in prompt prose,
    /// which a model can ignore. It has: a real debrief in this database scored
    /// {"structure":0,"questions_asked":0,"answer_relevance":0,"conciseness":0} → a 0.0 mean
    /// rendered as a legitimate result. Failing here marks the session retryable instead,
    /// and lets OpenAICompatibleClient's candidate scan skip a bad object and keep looking.
    /// Clamping was the alternative and is worse — it silently invents a score the judge
    /// never gave.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        proseDebrief = try c.decode(String.self, forKey: .proseDebrief)
        scores = try c.decode([String: Int].self, forKey: .scores)
        advancement = try c.decode(Advancement.self, forKey: .advancement)
        advancementRationale = try c.decode(String.self, forKey: .advancementRationale)
        weaknessTags = try c.decode([String].self, forKey: .weaknessTags)
        highlights = try c.decode([Highlight].self, forKey: .highlights)
        actionItems = try c.decode([String].self, forKey: .actionItems)
        processNotes = try c.decodeIfPresent([Highlight].self, forKey: .processNotes) ?? []

        if let bad = scores.first(where: { !(1...5).contains($0.value) }) {
            throw DecodingError.dataCorruptedError(
                forKey: .scores, in: c,
                debugDescription: "score \(bad.key)=\(bad.value) is outside the rubric's 1-5 band")
        }
    }
}
