# Debrief

<img src="assets/logo.png" width="128" alt="Debrief logo — two waveforms, amber (them) and blue (you)">

A macOS menu-bar app that records your job-interview calls locally, transcribes
them on-device, and generates candidate-focused coaching feedback — so you walk
into the next round knowing exactly what to fix.

Debrief **never joins the call as a bot.** It captures audio directly from your
Mac — your microphone plus the system audio playing the other participants — so
nothing appears in the meeting's participant list, and works with Zoom, Google
Meet, Teams, or anything else that plays through your speakers.

## How it works

The core trick is **dual-stream capture**. Your mic and the system-audio output
are recorded as two separate streams:

- Everything on the **mic** stream is **you**.
- Everything on the **system-audio** stream is **them** (the interviewer).

That gives perfect two-party speaker attribution with no ML diarization — which
matters, because coaching your answers requires knowing exactly which words are
yours. It's also why capturing at the machine beats a meeting bot: a bot gets one
mixed track and has to guess who's speaking, and its presence is visible to the
interviewer.

```
call detected ──▶ record (mic + system audio, 16 kHz WAV chunks to disk)
                     │
                     ▼
              live transcription (WhisperKit, on-device)
                     │
              stop ──▶ merge streams by timestamp ──▶ [00:03:12] THEM: …
                                                       [00:03:18] YOU:  …
                     │
                     ▼
              coaching debrief (Claude API) ──▶ scores · weakness tags ·
                                                highlights · action items
```

Audio chunks are flushed to disk **during** capture, so a crash mid-interview
loses nothing — the transcript and debrief are always re-derivable from the
chunks on disk, and Debrief offers to recover an interrupted session on the next
launch.

## Requirements

- macOS 14 or later (Apple Silicon recommended — transcription uses CoreML/Metal)
- Full Xcode installed (the build needs XCTest, which the Command Line Tools alone don't ship)
- A Claude API key (for the coaching step; transcription is free and local)

## Build & run

```sh
git clone https://github.com/bradburch/debrief.git && cd debrief
./scripts/make-app.sh      # release build → Debrief.app
open Debrief.app
```

`make-app.sh` produces a proper `.app` bundle (rather than a bare `swift run`
binary) so macOS attaches the microphone and screen-recording permission prompts
to *Debrief* instead of your terminal.

> **Signing (do this once, before your first build):** create a self-signed
> **Code Signing** certificate named `Debrief Local Signing` — Keychain Access →
> *Certificate Assistant → Create a Certificate…* → Identity Type **Self Signed
> Root**, Certificate Type **Code Signing**. `make-app.sh` signs the bundle with
> it, giving Debrief a code identity that's stable across rebuilds. Without it the
> script falls back to an **ad-hoc** signature whose identity changes every build,
> so macOS keeps re-prompting for your Keychain password and drops the
> Microphone/Screen-Recording grants on each rebuild. No trust step or admin
> password is needed; override the name with `DEBRIEF_SIGN_IDENTITY` if you like.

> **Toolchain note:** every `swift` command must run under the full Xcode
> toolchain, because the Command Line Tools instance has no XCTest. Either run
> `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` once, or
> prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## First-run setup

1. **Grant permissions.** On first launch macOS asks for **Microphone**; the
   first time you record it asks for **Screen Recording** (that's how the
   other side's audio is captured). Grant both, then relaunch if prompted.
2. **Add your Claude API key.** Open the main window → **Settings**, paste a key
   starting with `sk-ant-` (stored in the macOS Keychain). Alternatively, export
   `ANTHROPIC_API_KEY` before launching. Without a key, recordings and
   transcripts still work — debriefs stay pending until a key is set, then
   **Settings → Retry pending debriefs** catches them up.

## Using it

- **Record.** When Debrief notices a call starting (a meeting app running and the
  mic in use), the menu-bar icon pulses. Click **Record** — it never
  auto-records. While recording, the popover shows a live level bar for each
  stream; if one stops moving (e.g. AirPods routed system audio somewhere else),
  you'll get a warning mid-call instead of discovering a dead track afterward.
- **Stop & debrief.** Tag the session with the company and round type
  (recruiter screen / behavioral / technical / system design), hit **Stop &
  Debrief**, and within a minute or two you get scored feedback with clickable
  transcript highlights and concrete action items.
- **Track progress.** The **Pipeline** view groups sessions by company and round;
  the **Trends** view charts your recurring weakness tags and score dimensions
  over time, so "am I actually improving?" is answerable, not a vibe.

The coaching prompts are plain markdown in
`~/Library/Application Support/Debrief/prompts/` — edit `base.md` or any
round-type overlay to retune the feedback without rebuilding.

## Privacy

- **Audio never leaves your machine.** Transcription is fully on-device; raw
  audio is deleted after a successful transcript by default (toggle in Settings).
- **Only transcript text** is sent to the Claude API, and only for the coaching
  step.
- Recording is always an explicit click, never automatic.
- You are responsible for complying with recording-consent laws in your
  jurisdiction — some places require all parties to consent.

## Development

Swift Package, no `.xcodeproj`. Five targets:

| Target          | Responsibility                                        |
| --------------- | ----------------------------------------------------- |
| `CaptureKit`    | Call detection, mic + system-audio recorders, WAV chunking |
| `Transcriber`   | WhisperKit wrapper and two-stream transcript merge    |
| `CoachingEngine`| Prompt assembly, Claude API client, coaching service  |
| `Store`         | GRDB/SQLite schema, records, and trend/pipeline queries |
| `DebriefApp`    | SwiftUI menu-bar app wiring it all together           |

```sh
# Unit tests (fast; skips the model-download integration test)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --skip IntegrationTests

# Real end-to-end WhisperKit test (downloads a model on first run)
DEBRIEF_RUN_INTEGRATION=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter WhisperIntegrationTests
```

Hardware capture paths (mic/screen) can't be unit-tested meaningfully; they're
verified against the checklist in [`docs/manual-test-checklist.md`](docs/manual-test-checklist.md).

The design spec and implementation plan live in [`docs/superpowers/`](docs/superpowers/).

## Status

v1 is feature-complete with a green test suite. The live-call paths
(items 2–8 of the manual checklist) still need a human on a real interview to
sign off — everything up to and including a real on-device transcription of
synthesized speech is automated and passing.
