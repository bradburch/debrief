# Debrief — Interview Note Taker & Coach

**Date:** 2026-07-02
**Status:** Approved design

## Summary

Debrief is a macOS menu-bar app that records interview calls (Zoom, Google Meet, Teams, etc.) directly from the user's machine — never joining the call as a bot — transcribes them locally, and generates post-call coaching feedback focused on improving the user's performance **as a candidate**. Feedback is structured and tagged so weaknesses can be tracked across interviews and companies over time.

## Goals

- Capture both sides of an interview call with zero visible presence in the meeting.
- Produce an accurate speaker-attributed transcript within minutes of call end, entirely locally.
- Generate coaching debriefs tailored to the interview round type (recruiter screen, behavioral, technical/coding, system design).
- Track recurring weaknesses and score trends across sessions, and organize sessions by company pipeline.

## Non-goals (v1)

- Calendar integration (no OAuth, no pre-labeled meetings).
- Interviewer/recruiter mode (coaching the person asking the questions).
- Windows/Linux support.
- Real-time in-call coaching or live notes blending.
- Long-term retention of raw audio.

## Core design decision: dual-stream capture

The mic (the user's voice) and system audio (other participants, played through the user's output device) are captured as **two separate streams**. Everything on the mic stream is YOU; everything on the system stream is THEM. This gives perfect two-party speaker attribution with no ML diarization, which is essential because coaching requires knowing exactly which words are the user's. It is also why the no-bot approach beats bots here: a bot receives one mixed track and must guess speakers, and its presence is visible to the interviewer.

## Architecture

SwiftUI menu-bar app (`LSUIElement`; no Dock icon by default) with an on-demand main window. Four Swift package targets:

```
DebriefApp (menu bar + windows)
├── CaptureKit      — audio in: call detection, recording, stream management
├── Transcriber     — WhisperKit wrapper: audio chunks → timestamped text
├── CoachingEngine  — transcript → Claude API → structured feedback
└── Store           — GRDB/SQLite: sessions, transcripts, feedback, companies
```

### Call detection

A poller (~5s while idle) checks two signals:

1. **Mic-in-use** — CoreAudio reports another process holding the microphone. This is the robust, platform-agnostic signal (catches Meet in a browser tab).
2. **Meeting app present** — NSWorkspace process check (Zoom, Teams, etc.) for added confidence and labeling.

When a call is detected, the menu-bar icon pulses and a notification offers one-click **Record**. The app **never auto-records** — an explicit click is always required.

### Capture

- **Mic (YOU):** AVAudioEngine input tap, 16 kHz mono (Whisper's native format).
- **System audio (THEM):** ScreenCaptureKit audio-only capture; requires one-time Screen Recording permission.

Both streams are flushed to disk as `.wav` chunks **during** capture so a crash loses nothing. **Invariant: audio chunks land on disk first; everything downstream (transcription, coaching) is re-derivable from them.** Raw audio is deleted after successful transcription (default; configurable).

Permissions required: Microphone, Screen Recording, and Notifications (for the call-detected Record pop-up; the app works without it). The OS prompts for each on first use; Settings has deep-links to the Microphone and Screen Recording panes.

## Transcription

- WhisperKit (CoreML/Metal-accelerated Whisper), running **during** the call on ~30-second windows per stream, so the transcript is nearly complete at hang-up.
- Live pass uses a small model (`base.en`); a post-call re-pass with a larger model produces the final transcript (`small.en` in v1 — `medium` is a possible later upgrade once its latency is measured). Raw audio is deleted only after the re-pass completes. Models download on first run.
- The two streams' timestamped segments merge chronologically into one transcript:

```
[00:03:12] THEM: Tell me about a time you disagreed with a teammate.
[00:03:18] YOU:  Yeah, so, um — at my last role we were migrating...
```

- If live transcription can't keep up on a given machine, fall back to transcribe-after-call.

## Session metadata

At stop (or any time before), the user tags the session: **company**, **round type** (recruiter screen / behavioral / technical / system design), and free-form context notes. Round type selects the coaching prompt overlay.

## Coaching engine

On session end, the merged transcript is sent to the Claude API with a prompt assembled from three layers, all stored as **plain markdown files** in `~/Library/Application Support/Debrief/prompts/` so they can be edited without rebuilding the app:

1. **Base coach prompt** — shared rubric: did the user answer the question actually asked; talk-time ratio; filler-word density; rambling detection; questions the user asked the interviewer.
2. **Round-type overlay:**
   - *Behavioral:* STAR structure per story, story strength, quantified impact.
   - *Technical/coding:* think-aloud narration quality, clarifying questions, hint handling, recovery from being stuck.
   - *Recruiter screen:* self-pitch quality, plus extraction of logistics (comp discussed, process, timeline, next steps).
   - *System design:* requirements-gathering coverage, trade-off articulation, conversation driving.
3. **History context** — recurring weakness tags from the last 10 sessions (constant in the prompt file, so it's tunable), enabling longitudinal feedback ("third interview in a row where the 'tell me about yourself' answer ran long") without resending past transcripts.

The response is requested as structured output: a prose debrief plus a JSON block:

```json
{
  "scores": {"answer_relevance": 4, "structure": 2, "conciseness": 3, "questions_asked": 4},
  "weakness_tags": ["rambling_intro", "no_quantified_impact"],
  "highlights": [{"t": "00:14:22", "note": "Strong recovery after the hint — reference this pattern"}],
  "action_items": ["Send thank-you note mentioning the migration discussion", "Prep a 90-second version of the disagreement story"]
}
```

The weakness-tag vocabulary is defined in the prompt files (user-evolvable). Tags are the mechanism that turns prose feedback into queryable progress data.

The Claude API key is stored in the macOS Keychain, entered once in settings.

## Data model (SQLite via GRDB)

- `companies` — name, status (active / dead / offer)
- `sessions` — company_id, round_type, date, duration, context_notes
- `transcript_segments` — session_id, speaker (YOU/THEM), t_start, text
- `feedback` — session_id, prose_debrief, scores (JSON), action_items
- `weakness_tags` — session_id, tag (own table so trend queries are a simple GROUP BY)

## UI

**Menu bar:**
- Idle: quiet icon. Call detected: pulsing icon + notification with Record button.
- Recording: red dot + elapsed time. Popover shows Stop, session tagging fields, and **live audio-level indicators for both streams** — the user can see mid-call that both sides are being captured. This is the primary defense against the most common local-capture failure (audio routed where ScreenCaptureKit can't see it, e.g., certain AirPods configurations).

**Main window** (sidebar with three views):
1. **Sessions** — chronological list; detail view shows the debrief beside the scrollable transcript; highlight timestamps click-to-jump.
2. **Pipeline** — companies as rows, rounds as horizontal progression, each cell a session with its overall score; per-company status.
3. **Trends** — weakness-tag frequency over time, score dimensions across sessions, filterable by round type.

## Error handling

| Failure | Behavior |
|---|---|
| Crash mid-recording | Chunks already on disk; on relaunch, offer recovery + transcription of the partial session |
| One stream silent (device routing) | Live level indicators + a "no audio on X stream" warning notification after 60s of silence during a call |
| Claude API down / offline post-call | Transcript saved regardless; coaching queued with retry; "Regenerate debrief" always available |
| Whisper can't keep up live | Fall back to transcribe-after-call; disk chunks are source of truth |
| macOS permission revoked | Capture-start failure surfaces immediately in the menu bar; Settings deep-links to System Settings |
| Claude response missing/invalid JSON block | Keep the prose debrief, mark structured data absent, offer regenerate |

## Testing

- **Transcriber & merge:** unit tests with fixture WAVs; golden-file tests for the two-stream chronological merge.
- **CoachingEngine:** prompt-assembly unit tests (correct overlay per round type, history tags included); Claude client behind a protocol with mocks; JSON schema validation with graceful fallback.
- **Store:** GRDB in-memory tests, especially trends aggregations.
- **CaptureKit:** kept as thin as possible over Apple frameworks; verified via a manual checklist with real Zoom and Meet test calls (mocking ScreenCaptureKit mostly tests the mocks).

## Platform floor

Minimum macOS 14 (required by WhisperKit; ScreenCaptureKit audio capture needs macOS 13+ anyway).

## Key technology choices

| Concern | Choice | Rationale |
|---|---|---|
| Platform | macOS native, Swift/SwiftUI | Cleanest system-audio capture; user is on a Mac |
| Transcription | WhisperKit (CoreML/Metal), local | Free, private (audio never leaves the machine), near-real-time on Apple Silicon. Chosen over whisper.cpp because whisper.cpp dropped SPM support; WhisperKit is Swift-native, handles model downloads, and runs the same Whisper models |
| Coaching LLM | Claude API | Best coaching quality; pennies per interview; only transcript text leaves the machine |
| Storage | SQLite via GRDB | Simple, queryable for trends/pipeline views |
| Prompts | Markdown files on disk | Tune coaching without rebuilding — prompt iteration is where the product gets good |

## Privacy posture

- Raw audio: never leaves the machine; deleted after transcription by default.
- Transcript text: sent to the Claude API only, for coaching.
- Consent: recording only ever starts from an explicit user click. (User is responsible for complying with applicable recording-consent laws in their jurisdiction.)
