import Foundation

public struct TimedText: Equatable, Sendable {
    public var start: TimeInterval
    public var text: String
    public init(start: TimeInterval, text: String) { self.start = start; self.text = text }
}

public enum MergedSpeaker: String, Sendable { case you = "YOU", them = "THEM" }

public struct TranscriptLine: Equatable, Sendable {
    public var speaker: MergedSpeaker
    public var start: TimeInterval
    public var text: String
    public init(speaker: MergedSpeaker, start: TimeInterval, text: String) {
        self.speaker = speaker; self.start = start; self.text = text
    }
}

public enum TranscriptMerger {
    /// Max gap between same-speaker segments that still coalesces into one line.
    static let coalesceGap: TimeInterval = 2.0

    public static func merge(you: [TimedText], them: [TimedText]) -> [TranscriptLine] {
        let tagged: [(MergedSpeaker, TimedText)] =
            (you.map { (MergedSpeaker.you, $0) } + them.map { (MergedSpeaker.them, $0) })
            .filter { !$0.1.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.1.start < $1.1.start }

        var lines: [TranscriptLine] = []
        // Start of the most recently appended segment (not the line's first segment),
        // so gaps are measured between consecutive segments across long same-speaker runs.
        var lastSegmentStart: TimeInterval = 0
        for (speaker, seg) in tagged {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if var last = lines.last, last.speaker == speaker, seg.start - lastSegmentStart <= coalesceGap {
                last.text += " " + text
                lines[lines.count - 1] = last
                lastSegmentStart = seg.start
            } else {
                lines.append(TranscriptLine(speaker: speaker, start: seg.start, text: text))
                lastSegmentStart = seg.start
            }
        }
        return lines
    }
}
