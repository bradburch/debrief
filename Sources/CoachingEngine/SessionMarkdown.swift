import Foundation
import Store

/// Renders a session (transcript + debrief) as a standalone markdown document, and derives
/// a deterministic filename for it. A pure projection of the DB — no IO — so it is trivially
/// testable and re-exportable. Lives in CoachingEngine because it decodes the feedback JSON
/// columns using Highlight, which Store cannot import.
public enum SessionMarkdown {
    public static func render(_ detail: SessionDetail) -> String {
        let s = detail.session
        var out = "# \(detail.company.name) — \(s.roundType.displayName)\n\n"

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        out += "- Date: \(stamp.string(from: s.date))\n"
        out += "- Duration: \(s.durationSeconds / 60) min\n"
        if !s.contextNotes.isEmpty { out += "- Notes: \(s.contextNotes)\n" }
        if !s.customInstructions.isEmpty { out += "- Custom criteria: \(s.customInstructions)\n" }
        out += "\n"

        if let f = detail.feedback {
            if let adv = f.advancementValue {
                out += "## Verdict: \(adv.displayName)\n\n"
                if !f.advancementRationale.isEmpty { out += "\(f.advancementRationale)\n\n" }
            }
            if !f.proseDebrief.isEmpty { out += "## Debrief\n\n\(f.proseDebrief)\n\n" }

            let dec = JSONDecoder()
            if let scores = try? dec.decode([String: Int].self, from: Data(f.scoresJSON.utf8)), !scores.isEmpty {
                out += "## Scores (1–5)\n\n- Overall: \(String(format: "%.1f", f.overallScore))\n"
                for key in scores.keys.sorted() { out += "- \(key): \(scores[key]!)\n" }
                out += "\n"
            }
            if let highs = try? dec.decode([Highlight].self, from: Data(f.highlightsJSON.utf8)), !highs.isEmpty {
                out += "## Highlights\n\n"
                for h in highs { out += "- [\(h.t)] \(h.note)\n" }
                out += "\n"
            }
            if let items = try? dec.decode([String].self, from: Data(f.actionItemsJSON.utf8)), !items.isEmpty {
                out += "## Action items\n\n"
                for i in items { out += "- \(i)\n" }
                out += "\n"
            }
            if let notes = try? dec.decode([Highlight].self, from: Data(f.processNotesJSON.utf8)), !notes.isEmpty {
                out += "## Process notes\n\n"
                for n in notes { out += "- [\(n.t)] \(n.note)\n" }
                out += "\n"
            }
            if !detail.tags.isEmpty {
                out += "## Weakness tags\n\n" + detail.tags.map { "`\($0)`" }.joined(separator: " ") + "\n\n"
            }
        }

        out += "## Transcript\n\n"
        for seg in detail.segments {
            out += "[\(formatTimestamp(seg.tStart))] \(seg.speaker.rawValue): \(seg.text)\n"
        }
        return out
    }

    public static func filename(for detail: SessionDetail) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let date = day.string(from: detail.session.date)
        let company = slug(detail.company.name)
        let round = detail.session.roundType.rawValue
        let id = detail.session.id ?? 0
        return "\(date)-\(company)-\(round)-\(id).md"
    }

    /// "Acme Corp!" -> "acme-corp". Lowercase, non-alphanumerics collapse to single hyphens.
    static func slug(_ s: String) -> String {
        let mapped = s.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "session" : collapsed
    }
}
