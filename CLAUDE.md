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
- **Don't split what shares a contract.** The scored dimensions live in `DefaultPrompts` + `PromptStore.dimensions(for:)` + both LLM clients + the DB schema. Parallel agents each editing one end produce a diff that compiles and doesn't work — give one agent the whole contract.

## Toolchain gotcha (read first)

Every `swift` command **must** run under the full Xcode toolchain — the Command Line Tools instance has no XCTest and the build fails without it. Either run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` once, or prefix every command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

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
```

**Why `make-app.sh` instead of `swift run`:** macOS attaches Microphone/Screen-Recording TCC prompts to the *bundle*, and `CallAlerts` touches `UNUserNotificationCenter`, which traps in an unbundled binary. Always run the app via the `.app`. The script signs with a stable self-signed identity (`Debrief Local Signing`) so TCC/Keychain grants survive rebuilds — the header comment in the script explains why ad-hoc signing loses grants every build.

Hardware capture paths (mic/screen) can't be unit-tested; verify them against `docs/manual-test-checklist.md`.

## Verify against reality — green tests prove less here than usual

Two whole classes of bug in this app are invisible to `swift test`, and both have shipped:

1. **The API rejects a schema the mocks accept.** `outputSchema(dimensions:)` is hand-built JSON; every unit test mocks `URLSession`, so a schema the Messages API 400s on passes the suite cleanly and fails every real debrief. Run `CoachingIntegrationTests` after touching the schema, the clients, or the scored dimensions.
2. **A prompt change that "reads better" and scores worse.** Nothing in the suite can tell you a rubric got *dumber*. Run a real transcript through it and compare against the old prompts before believing a rubric improvement.

The UI is drivable — don't stop at "it builds." `Debrief` is a `MenuBarExtra` plus `Window(id: "main")`, so it launches with **zero windows**; open the main window with:

```applescript
tell application "System Events" to tell process "Debrief" to click menu item "Debrief" of menu 1 of menu bar item "Window" of menu bar 1
```

Then drive it via System Events accessibility. Useful paths (macOS 15, verified):
- sidebar tabs: `outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1` → `select row N` (1=Sessions, 2=Pipeline, 3=Trends, 4=Settings)
- detail pane: `group 2 of splitter group 1 of group 1 of window 1`

AppleScript gotchas that cost real time: `right`, `st`, and other reserved words silently break scripts with confusing syntax errors; `entire contents` is flaky on large trees and returns empty rather than erroring — prefer explicit paths and `count of (groups of x)` style probes; compare a known-good state against the state under test rather than trusting one absolute reading.

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

### Crash-safety: chunks on disk are the source of truth

Audio is flushed to disk in ~30s WAV chunks *during* capture (`WavChunkWriter`). The transcript and debrief are always re-derivable from those chunks, so a mid-interview crash loses nothing and Debrief offers recovery on next launch (`RecordingStore.unfinalizedSessions()`).

`RecordingCoordinator.runFinalize` is the **single convergence point** for both paths:
- `stopAndFinalize` (normal stop) and `finalizeFromDisk` (crash recovery) both funnel into it once chunks are on disk — identical code, so recovery and live stop produce the same result.
- **Concurrency contract:** the coordinator is `@MainActor`, and finalizers claim `phase = .finalizing` *before any `await`* (atomic on the main actor). That's the lock preventing two finalizers racing — see the long comment on `finalizeFromDisk`. Don't insert an `await` between a phase guard and its claim.
- The live transcription loop caches per-chunk results; `runFinalize` reuses the cache and only transcribes chunks not yet done (the final partial chunk, or — on recovery — all of them, since a fresh process has an empty cache).

Phase state machine: `.idle → .recording → .finalizing(status:) → .idle` (or `.failed`). `runFinalize` always lands in a terminal state.

### LLM abstraction

`CoachingLLM` protocol has two implementations: `AnthropicClient` (Claude API) and `OpenAICompatibleClient` (Ollama / LM Studio / any OpenAI-compatible server — see `docs/local-llm.md`). `AppEnvironment.resolveLLM()` picks based on `UserDefaults`. The API key lives in the macOS Keychain (`KeychainStore`), falling back to `ANTHROPIC_API_KEY`. `coordinator.coaching` is reassignable so a key/model changed in Settings applies to the next debrief without relaunch (`rebuildCoaching()`).

Coaching runs with `try?` inside `runFinalize` — a failed debrief leaves the session **retryable** (status `pending`/`failed`), never blocks finalization. Settings → "Retry pending debriefs" calls `retryAllPending()`; Settings → "Re-run debriefs on current rubric" calls `recoachAll()`, which re-coaches **already-complete** sessions too (the only way a prompt change reaches existing debriefs).

The response contract is **per-round, not constant** — `generateCoaching(systemPrompt:userMessage:dimensions:)` takes the round's scored keys. The two clients enforce that same contract by *different mechanisms*, so a change to one needs the other:
- `AnthropicClient.outputSchema(dimensions:)` — a real JSON schema (`additionalProperties: false` + exhaustive `required`).
- `OpenAICompatibleClient.formatAppendix(dimensions:)` — **prose**, because these servers disagree on `response_format`. Since `scores` is `[String: Int]`, a local model returning the wrong keys still *decodes*; an explicit key-set check rejects it.

Schema gotcha: the Messages API **rejects `minimum`/`maximum` on integer types** with a 400. Score ranges live in the prompt text, not the schema. Only `CoachingIntegrationTests` catches this class of bug — mocked tests pass against a schema the API refuses.

### Prompts: the rubric is data, not code

- **Global** prompts are plain markdown in `~/Library/Application Support/Debrief/prompts/` (`PromptStore`, seeded from `DefaultPrompts`): `base.md` + per-round-type overlays. Editing them retunes every debrief without rebuilding. **`ensureDefaults()` only writes a file that doesn't exist** — editing `DefaultPrompts` alone will NOT update an existing install.
- **Scored dimensions are parsed out of the markdown.** Each file's `## Scored dimensions` section (`- key: description`) becomes the JSON-schema keys via `PromptStore.dimensions(for:)` = base's shared delivery dimensions + the overlay's round-specific ones. A new round type is a new `.md` file — no Swift change.
- **The verdict is the headline, and it is not an average.** `advancement` (`Advancement`, a 4-point forced choice) is elicited from the model *directly* and must never be derived from `scores` — real scorecards co-record the verdict and the ratings. `overallScore` is a secondary trend line only; it is comparable *within* a round type, not across (dimension sets differ), and LLM judges compress toward the top of a 1–5 scale, so a flat mean discriminates poorly. See the provenance comment atop `DefaultPrompts` for what the rubric design is and isn't evidence-backed by.
- **Per-interview** grading criteria (`session.customInstructions`, added in migration v2) override the global prompt for one session only.

### Store

GRDB with a `DatabaseMigrator` (`AppDatabase.migrator`) — **schema changes go in a new `registerMigration` block, never by editing an existing one.** In-memory DB for tests (`AppDatabase.inMemory()`), on-disk for the app. LLM feedback (scores, highlights, action items, process notes) is stored as JSON strings in columns; weakness tags are a separate indexed table for trend queries.

`insertSegments` runs `TranscriptArtifacts.clean` on every write, so the transcript table holds
speech and nothing else. WhisperKit narrates non-speech as `[BLANK_AUDIO]`, `[ Silence ]`,
`(indistinct)`, and emits `>>` speaker-change markers and half-cut brackets at chunk
boundaries — 11% of segments in a real database. It lives at the Store boundary, not in
`TranscriptMerger`, because both the live-stop and crash-recovery paths funnel through it and
because migration v5 reuses the identical rules to clean pre-existing rows. If you extend it,
keep the false-positive tests: the bare-word rules must never eat real speech ("Music is my
hobby", "we sat in silence"), and an unclosed `[` must never consume the rest of a line.
