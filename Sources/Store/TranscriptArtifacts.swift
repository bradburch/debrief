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
    // Complete markers only. A dangling opener is deliberately NOT matched to end-of-string:
    // "so I said [ and then left" would lose real speech. Truncated openers are handled by
    // `isSpeechless` below, which drops the segment only when nothing real remains.
    private static let markers = try! NSRegularExpression(pattern: #"\[[^\]]*\]|\([^\)]*\)"#)
    // A chunk boundary can cut a marker, leaving a trailing opener with nothing after it.
    private static let danglingOpener = try! NSRegularExpression(pattern: #"[\[\(]\s*$"#)

    // The marker words themselves, needed because a chunk boundary can eat the OPENING
    // bracket ("silence ] Okay.") or Whisper drops the brackets entirely ("Silence.") —
    // both observed in real recordings, and neither is reachable by the bracket rules above.
    private static let markerWord = "silence|pause|blank[ _]?audio|noise|inaudible|indistinct|music|no speech(?: detected)?|no audio"

    // "silence ]" — a closer whose opener was lost. Anchored on the marker word so an
    // ordinary "]" in speech can't take the text before it with it.
    private static let danglingCloser = try! NSRegularExpression(
        pattern: #"\b(?:\#(markerWord))\b\s*[\]\)]"#, options: [.caseInsensitive])

    // A marker word standing alone as a whole sentence: "Silence." / "Yeah. Silence."
    // Requires terminal punctuation or end-of-string after the word — WITHOUT that, this
    // would gut real speech like "Music is my hobby" or "there was a pause".
    private static let bareMarkerSentence = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[.!?])\s*)\b(?:\#(markerWord))\b\s*(?:[.!?]|$)"#,
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
