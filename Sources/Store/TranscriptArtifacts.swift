import Foundation

/// Strips Whisper's non-speech markers out of transcript text.
///
/// WhisperKit narrates what it hears in brackets or parens when it isn't speech —
/// `[BLANK_AUDIO]`, `[ Silence ]`, `[ Pause ]`, `[inaudible]`, `[NOISE]`, `(indistinct)`,
/// even `(scissors snipping)` — and emits a bare `[` when a ~30s chunk boundary cuts a
/// marker in half. None of it is anything the candidate said. Left in, it pads the
/// transcript the LLM reads, and shows up as junk lines in the transcript pane.
///
/// Applied at the single write boundary (`insertSegments`) rather than in TranscriptMerger,
/// so no path into the DB — live stop or crash recovery — can persist a marker, and the
/// v5 migration can reuse the exact same rules on rows written before this existed.
public enum TranscriptArtifacts {
    // The marker words themselves. Used to ANCHOR the looser rules below — a rule that fires
    // on any bracket/paren span is the dangerous kind, because deleting real speech is far
    // worse than leaving a marker in.
    private static let markerWord = "silence|pause|blank[ _]?audio|noise|inaudible|indistinct|music|no speech(?: detected)?|no audio"

    // Bracketed AND parenthesized spans, both broad. Whisper learned its conventions from
    // subtitles, where (parens) and [brackets] both mean "not speech" — it renders spoken
    // asides with commas, not parens. Checked against every parenthesized span in a real
    // 11-interview database: (Laughter) (indistinct) (laughing) (inaudible) (sniffing)
    // (scissors snipping) (door opens) (eerie music) (clicking) (upbeat music) — 10 of 10
    // non-speech, 0 spoken asides. Anchoring this on marker words instead would leak most of
    // them. ponytail: if a spoken aside in parens ever shows up, narrow to a word-count or
    // digit heuristic then — not before, on speculation.
    private static let markers = try! NSRegularExpression(pattern: #"\[[^\]]*\]|\([^\)]*\)"#)
    // A chunk boundary can cut a marker, leaving a trailing opener with nothing after it.
    private static let danglingOpener = try! NSRegularExpression(pattern: #"[\[\(]\s*$"#)

    // "silence ]" — a closer whose opener was eaten by a chunk boundary. Anchored on the
    // marker word so an ordinary "]" in speech can't take the text before it with it.
    private static let danglingCloser = try! NSRegularExpression(
        pattern: #"\b(?:\#(markerWord))\b\s*[\]\)]"#, options: [.caseInsensitive])

    // Whisper sometimes drops the brackets entirely ("Silence.", "Yeah. Silence."), which no
    // bracket rule can reach. Restricted to the two markers ACTUALLY observed bare in real
    // recordings — the full markerWord list here deleted genuine speech: "No audio." (an
    // interviewer flagging a mic problem) and "Pause. Let me think about that." both vanished.
    // Short standalone utterances are exactly what Whisper emits as their own segment, so a
    // false positive here costs a whole line of the transcript.
    private static let bareMarkerWord = "silence|blank[ _]?audio"
    private static let bareMarkerSentence = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[.!?])\s*)\b(?:\#(bareMarkerWord))\b\s*(?:[.!?]|$)"#,
        options: [.caseInsensitive])

    // Whisper's speaker-change marker. Debrief attributes speakers from the dual-stream split
    // (mic = YOU, system audio = THEM), so ">>" carries no information here — it is noise that
    // survives into the prompt and the transcript pane. Never appears in real speech.
    private static let speakerChange = try! NSRegularExpression(pattern: #">>+"#)
    private static let repeatedSpace = try! NSRegularExpression(pattern: #"\s{2,}"#)
    // " ." / " ," left behind once a mid-sentence marker is removed.
    private static let spaceBeforePunctuation = try! NSRegularExpression(pattern: #"\s+([.,!?;:])"#)

    /// The text with markers removed, or "" if nothing but markers was there.
    public static func clean(_ text: String) -> String {
        var s = text
        // Order matters: complete markers first, so "[silence]" is gone before the bare-word
        // rules ever see it and the word rules only face genuinely broken fragments.
        for regex in [markers, danglingCloser, bareMarkerSentence, danglingOpener, speakerChange] {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                               withTemplate: " ")
        }
        s = spaceBeforePunctuation.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        s = repeatedSpace.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return isSpeechless(s) ? "" : s
    }

    /// True when nothing alphanumeric survives — a bare "[", "(", or stray punctuation left
    /// by a truncated marker. Keeps `clean` from emitting lines that are pure punctuation.
    private static func isSpeechless(_ s: String) -> Bool {
        !s.contains { $0.isLetter || $0.isNumber }
    }
}
