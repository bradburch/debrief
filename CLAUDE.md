# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Debrief is a macOS menu-bar app that records interview calls locally, transcribes them on-device (WhisperKit), and generates coaching feedback via an LLM. `README.md` covers the product, privacy model, and first-run setup — read it for the "why." This file covers building and the non-obvious architecture.

## Always delegate to subagents, at the right model strength

**Dispatch work to subagents by default — every action, not just big ones.** Do it inline only when delegating genuinely costs more than it saves (a one-line edit to a file already open, answering from what's already on screen). When in doubt, delegate.

**Always set the strength explicitly.** Pass `model` and `effort` on every `Agent`/`Workflow` call rather than letting them inherit by accident — an unset tier is a silent default, not a decision. Getting it wrong is expensive both ways: a weak agent on a judgment call ships a confident wrong answer, and a strong agent on a mechanical sweep burns tokens for nothing.

**Send independent tasks in one message** so they run concurrently, and prefer `pipeline()` over barriers in workflows.

| Work | Agent | Model / effort |
|---|---|---|
| Locating code, tracing callers, "where is X used" | `Explore` | haiku–sonnet, **low** |
| Mechanical sweeps: renames, call-site updates, fixture extraction | `general-purpose` | sonnet, **low–medium** |
| Reading a subsystem to answer a design question | `general-purpose` | sonnet–opus, **medium** |
| Prompt/rubric wording, schema + migration design, `RecordingCoordinator` concurrency | `general-purpose` | opus, **high–xhigh** |
| Adversarial checks: "is this claim supported?", reviewing a risky diff | an agent **other than the author** | opus, **high** |
| Cited, fact-checked research | `deep-research` skill | verify/synthesis **high**; search/fetch **medium** |

Calibration notes specific to this repo:
- **Verification is not mechanical.** Judging *what would falsify this* deserves high effort — see "Verify against reality" below. A passing mocked test means very little here.
- **Prompt and rubric changes are the highest-judgment work in the codebase** and the least checkable by tests. Never delegate them cheaply; the failure mode is fluent, plausible, and wrong.
- **Never let the author verify their own work.** Spawn a separate agent to check a rubric change or a risky diff. Both real bugs this rubric work shipped (an API-rejected schema, a stored all-zero debrief) were invisible to the code that produced them.
- **Don't split what shares a contract.** The scored dimensions live in `DefaultPrompts` + `PromptStore.dimensions(for:)` + all three LLM clients + the DB schema. Parallel agents each editing one end produce a diff that compiles and doesn't work — give one agent the whole contract.
- **And don't overload what already serves two masters.** The converse bug, shipped twice: `sessionsWithTranscript()` feeds both the re-coach sweep and `exportAll`, so narrowing it for one silently broke the other. Before adding a filter to a shared query — or a second reader to a file descriptor — grep its callers and ask whether they want the same thing.

## Toolchain gotcha (read first)

Every `swift` command **must** run under the full Xcode toolchain — the Command Line Tools instance has no XCTest and the build fails without it. Either run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` once, or prefix every command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

The deployment floor is **macOS 14.2** (`Package.swift` and the bundle's `LSMinimumSystemVersion`, which must stay in sync) — CoreAudio process taps need it. SourceKit in the editor may still report "compiling for macOS 14.0" against a stale index; trust `swift build`.

## Commands

```sh
# Build + bundle into Debrief.app (do this to run — see "Why .app" below)
./scripts/make-app.sh && open Debrief.app

# Unit tests (fast; skips the WhisperKit model-download integration test)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --skip IntegrationTests

# One target's tests
… swift test --filter CoachingEngineTests

# One test case
… swift test --filter TranscriptMergerTests

# Real end-to-end WhisperKit test (downloads a CoreML model on first run)
DEBRIEF_RUN_INTEGRATION=1 … swift test --filter WhisperIntegrationTests

# Real Anthropic call — the ONLY check that the built JSON schema is one the API accepts
ANTHROPIC_API_KEY=… DEBRIEF_RUN_INTEGRATION=1 … swift test --filter CoachingIntegrationTests

# Real system-audio capture (needs an output device + audible volume; plays audio via `say`)
DEBRIEF_RUN_INTEGRATION=1 … swift test --filter SystemAudioIntegrationTests

# Real `claude -p` call — spends Claude subscription quota
DEBRIEF_RUN_INTEGRATION=1 … swift test --filter ClaudeCodeCLIIntegrationTests
```

**Never run `make-app.sh` while a recording is in progress** — it overwrites the running
executable. Check for a live session first (`manifest.json` with `"finalized":false`, or a
`sys-*.wav` written seconds ago) and stop it before rebuilding.

**Why `make-app.sh` instead of `swift run`:** macOS attaches Microphone/system-audio TCC prompts to the *bundle*, and `CallAlerts` touches `UNUserNotificationCenter`, which traps in an unbundled binary. Always run the app via the `.app`. The script signs with a stable self-signed identity (`Debrief Local Signing`) so TCC grants survive rebuilds — the header comment in the script explains why ad-hoc signing loses grants every build.

Hardware capture paths can't be fully unit-tested; verify them against `docs/manual-test-checklist.md`.

**A Finder-launched `.app` inherits a minimal PATH** (`/usr/bin:/bin:/usr/sbin:/sbin`). Anything that spawns a helper binary must search absolute paths — `/usr/bin/env <tool>` resolves in your shell and fails in the bundle. See `ClaudeCodeCLIClient.defaultSearchPaths()`.

## Verify against reality — green tests prove less here than usual

Three whole classes of bug in this app are invisible to `swift test`, and all three have shipped:

1. **The API rejects a schema the mocks accept.** `outputSchema(dimensions:)` is hand-built JSON; every unit test mocks `URLSession`, so a schema the Messages API 400s on passes the suite cleanly and fails every real debrief. Run `CoachingIntegrationTests` after touching the schema, the clients, or the scored dimensions.
2. **A prompt change that "reads better" and scores worse.** Nothing in the suite can tell you a rubric got *dumber*. Run a real transcript through it and compare against the old prompts before believing a rubric improvement.
3. **Capture that runs, writes correctly-sized files, and records silence.** Every mocked recorder test passed while ScreenCaptureKit wrote full-rate zeros for an entire call. Nothing short of measuring real audio catches it.

**The fastest capture diagnostic is the chunks already on disk.** Compare mic vs sys RMS across `~/Library/Application Support/Debrief/recordings/*` — the pattern instantly separates "capture is broken" (every session silent) from "this call type is excluded" (one session silent, twenty fine), and a full-length chunk of pure zeros is a different bug from a missing or short chunk. Item 16 of the checklist has a ready-to-paste script. Note `audioop` was **removed in Python 3.13**, so compute RMS with `array` + `math`, not the obvious one-liner.

The UI is drivable — don't stop at "it builds." `Debrief` is a `MenuBarExtra` plus `Window(id: "main")`, so it launches with **zero windows**; open the main window with:

```applescript
tell application "Debrief" to activate
delay 1
tell application "System Events" to tell process "Debrief" to click menu item "Debrief" of menu 1 of menu bar item "Window" of menu bar 1
```

**The `activate` is load-bearing.** Without it the click reports success and the window
count stays 0 — a silent no-op, not an error.

Then drive it via System Events accessibility. Useful paths (macOS 15, verified):
- sidebar tabs: `outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1` → `select row N` (1=Sessions, 2=Pipeline, 3=Trends, 4=Settings)
- detail pane: `group 2 of splitter group 1 of group 1 of window 1`

AppleScript gotchas that cost real time: `right`, `st`, and other reserved words silently break scripts with confusing syntax errors; `entire contents` is flaky on large trees and returns empty rather than erroring — prefer explicit paths and `count of (groups of x)` style probes; compare a known-good state against the state under test rather than trusting one absolute reading.

On the Settings pane specifically, `entire contents` **errors outright** (`-1700`, "can't make into type specifier"). What works is counting the Form's sections — `count of UI elements of scroll area 1 of group 2 of splitter group 1 of group 1 of window 1` returns one `group` per `Section`, so an added section is visible as the count changing. `screencapture` is not a fallback: the shell lacks Screen Recording, so it fails with "could not create image from display".

## Architecture

Swift Package, no `.xcodeproj`. Four library targets + one executable; the executable is the only place they're wired together:

```
DebriefApp (SwiftUI menu-bar app, composition root)
  ├─ CaptureKit     call detection, mic + system-audio recorders, WAV chunking
  ├─ Transcriber    WhisperKit wrapper + two-stream transcript merge
  ├─ CoachingEngine prompt assembly, LLM clients, coaching service
  └─ Store          GRDB/SQLite schema, records, trend/pipeline queries
```

Library targets depend only on `Store` (or nothing) and take injected protocols — no hardware or LLM concretions. `DebriefApp.AppEnvironment.live()` is the **composition root**: the single place concrete `WhisperTranscriber`, `MicRecorder`/`SystemAudioRecorder`, and the resolved `CoachingLLM` get injected. To test a unit without hardware, inject a fake at that boundary (see `RecordingCoordinatorTests`).

### Dual-stream capture (the core idea)

Mic stream = **you**, system-audio stream = **them**. Two separate WAV streams give perfect two-party attribution with no ML diarization. `TranscriptMerger.merge(you:them:)` interleaves them by timestamp. Everything downstream assumes this mapping.

System audio comes from a **CoreAudio process tap**, not ScreenCaptureKit. SCK scopes capture to audio from *windows on a display*, so a Continuity/cellular call — voiced by a windowless daemon — delivered full-rate digital silence for the whole call. A tap scopes by what reaches the output device instead. Two invariants follow, both easy to undo by accident:
- **The aggregate device has no output sub-device, only the tap.** Binding it to a device UID would go stale when the output switches mid-call.
- **A tap delivers *nothing* while the output is idle** — zero callbacks until audio plays. `SystemAudioRecorder.padSilenceToNow` reconstructs the missing wall-clock time as silence. Remove it and the mic track (which always streams) keeps real time while the system track compresses, so every "them" segment after a gap lands early in the merge. Adding an output sub-device does **not** fix the idling; it was measured.

### Crash-safety: chunks on disk are the source of truth

Audio is flushed to disk in ~30s WAV chunks *during* capture (`WavChunkWriter`). The transcript and debrief are always re-derivable from those chunks, so a mid-interview crash loses nothing and Debrief offers recovery on next launch (`RecordingStore.unfinalizedSessions()`).

`RecordingCoordinator.runFinalize` is the **single convergence point** for both paths:
- `stopAndFinalize` (normal stop) and `finalizeFromDisk` (crash recovery) both funnel into it once chunks are on disk — identical code, so recovery and live stop produce the same result.
- **Concurrency contract:** the coordinator is `@MainActor`, and finalizers claim `phase = .finalizing` *before any `await`* (atomic on the main actor). That's the lock preventing two finalizers racing — see the long comment on `finalizeFromDisk`. Don't insert an `await` between a phase guard and its claim.
- The live transcription loop caches per-chunk results; `runFinalize` reuses the cache and only transcribes chunks not yet done (the final partial chunk, or — on recovery — all of them, since a fresh process has an empty cache).

Phase state machine: `.idle → .recording → .finalizing(status:) → .idle` (or `.failed`). `runFinalize` always lands in a terminal state.

### LLM abstraction

`CoachingLLM` protocol has three implementations: `AnthropicClient` (Claude API), `OpenAICompatibleClient` (Ollama / LM Studio / any OpenAI-compatible server — see `docs/local-llm.md`), and `ClaudeCodeCLIClient` (shells out to `claude -p`, billing a Claude subscription instead of an API key). `AppEnvironment.resolveLLM()` picks based on `UserDefaults`, falling back to `AnthropicClient` when the CLI isn't found. Only the Anthropic path can enforce a JSON schema; the other two share one prose contract — `OpenAICompatibleClient.formatAppendix` states the rules and `decodeCoaching(from:dimensions:)` enforces them, so a change to either half needs the other. The API key lives in a 0600 `secrets.json` under Application Support (`SecretStore`), falling back to `ANTHROPIC_API_KEY`. It is deliberately *not* the Keychain: the self-signed, no-Team-ID signing pins each keychain item to the app's cdhash, which changes every rebuild and re-prompts for the keychain password on every launch/save — the header comment in `SecretStore` records the full dead-end (data-protection keychain and null-ACL both ruled out). Sign with a Team ID cert if you want keychain-grade at-rest encryption back. `coordinator.coaching` is reassignable so a key/model changed in Settings applies to the next debrief without relaunch (`rebuildCoaching()`).

Coaching runs with `try?` inside `runFinalize` — a failed debrief leaves the session **retryable** (status `pending`/`failed`), never blocks finalization. Settings → "Retry pending debriefs" calls `retryAllPending()`; Settings → "Re-run debriefs on current rubric" calls `recoachAll()`, which re-coaches **already-complete** sessions too (the only way a prompt change reaches existing debriefs).

The response contract is **per-round, not constant** — `generateCoaching(systemPrompt:userMessage:dimensions:)` takes the round's scored keys. The two clients enforce that same contract by *different mechanisms*, so a change to one needs the other:
- `AnthropicClient.outputSchema(dimensions:)` — a real JSON schema (`additionalProperties: false` + exhaustive `required`).
- `OpenAICompatibleClient.formatAppendix(dimensions:)` — **prose**, because these servers disagree on `response_format`. Since `scores` is `[String: Int]`, a local model returning the wrong keys still *decodes*; an explicit key-set check rejects it.

Schema gotcha: the Messages API **rejects `minimum`/`maximum` on integer types** with a 400. Score ranges live in the prompt text, not the schema. Only `CoachingIntegrationTests` catches this class of bug — mocked tests pass against a schema the API refuses.

### Prompts: the rubric is data, not code

- **Global** prompts are plain markdown in `~/Library/Application Support/Debrief/prompts/` (`PromptStore`, seeded from `DefaultPrompts`): `base.md` + per-round-type overlays. Editing them retunes every debrief without rebuilding. **`ensureDefaults()` only writes a file that doesn't exist** — editing `DefaultPrompts` alone will NOT update an existing install.
- **Scored dimensions are parsed out of the markdown.** Each file's `## Scored dimensions` section (`- key: description`) becomes the JSON-schema keys via `PromptStore.dimensions(for:)` = base's shared delivery dimensions + the overlay's round-specific ones. A new round type is a new `.md` file — no Swift change. Settings → **Interview types** is a convenience over that folder (create/duplicate/edit/delete), never a second source of truth; editing the files by hand still works.
- **A round type can opt out of scoring** with `transcript-only: true` in its overlay's leading metadata block (only that block is scanned, so rubric prose discussing it can't switch scoring off). `mock_interview` ships this way. The guard lives in `CoachingService.coach()` — all three paths (finalize, `retryAllPending`, `recoachAll`) funnel through there, so one check keeps a practice round from ever billing a call.
- **The verdict is the headline, and it is not an average.** `advancement` (`Advancement`, a 4-point forced choice) is elicited from the model *directly* and must never be derived from `scores` — real scorecards co-record the verdict and the ratings. `overallScore` is a secondary trend line only; it is comparable *within* a round type, not across (dimension sets differ), and LLM judges compress toward the top of a 1–5 scale, so a flat mean discriminates poorly. See the provenance comment atop `DefaultPrompts` for what the rubric design is and isn't evidence-backed by.
- **Per-interview** grading criteria (`session.customInstructions`, added in migration v2) override the global prompt for one session only.

### Store

GRDB with a `DatabaseMigrator` (`AppDatabase.migrator`) — **schema changes go in a new `registerMigration` block, never by editing an existing one.** (`coachingStatus` is a plain TEXT column with no CHECK constraint, so adding a `CoachingStatus` case needs no migration — `skipped` was added that way. It is terminal, unlike `failed`: both coaching sweeps exclude it, or a transcript-only session would be offered for retry forever.) In-memory DB for tests (`AppDatabase.inMemory()`), on-disk for the app. LLM feedback (scores, highlights, action items, process notes) is stored as JSON strings in columns; weakness tags are a separate indexed table for trend queries.

`insertSegments` runs `TranscriptArtifacts.clean` on every write, so the transcript table holds
speech and nothing else. WhisperKit narrates non-speech as `[BLANK_AUDIO]`, `[ Silence ]`,
`(indistinct)`, and emits `>>` speaker-change markers and half-cut brackets at chunk
boundaries — 11% of segments in a real database. It lives at the Store boundary, not in
`TranscriptMerger`, because both the live-stop and crash-recovery paths funnel through it and
because migration v5 reuses the identical rules to clean pre-existing rows. If you extend it,
keep the false-positive tests: the bare-word rules must never eat real speech ("Music is my
hobby", "we sat in silence"), and an unclosed `[` must never consume the rest of a line.
