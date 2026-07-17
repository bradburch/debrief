# Configurable data locations + Cowork export

**Date:** 2026-07-17
**Status:** Approved design, ready for implementation plan

## Problem

Two related asks:

1. **"Have a setting to select where to save transcripts, etc."** Today every persisted
   artifact lives under a hardcoded `~/Library/Application Support/Debrief/` root, with no way
   to relocate it.
2. **"Ensure this works with Claude Cowork."** [Claude Cowork](https://www.anthropic.com/product/claude-cowork)
   is a working-session mode where Claude reads/edits/creates files in folders you point it at.
   It works with **files**. Debrief stores transcripts and coaching feedback as **rows in a
   SQLite database**, so pointing Cowork at Debrief's data folder yields only an opaque
   `.sqlite` blob plus WAV chunks — nothing Cowork can turn into a doc or analysis.

The two asks are **independent** and split cleanly:

- **Part A** relocates Debrief's own storage directories (for the user's storage layout).
- **Part B** exports each session as a readable markdown file (this is what actually makes
  Cowork useful).

Either part can ship alone. Part A does *not* serve Cowork; Part B does.

## Current state (from codebase exploration)

There is **no single data root** — two independent computations of the "Debrief" base dir:

- **Audio + DB root:** `RecordingStore.appSupportRoot()`
  (`Sources/CaptureKit/RecordingStore.swift:10-13`) →
  `~/Library/Application Support/Debrief`. `recordingsRoot()` appends `recordings`.
- **Prompts root:** `PromptStore.defaultDirectory()`
  (`Sources/CoachingEngine/PromptStore.swift:15-18`) →
  `~/Library/Application Support/Debrief/prompts` (computed independently).

Three path chokepoints, **all called only from `AppEnvironment.live()`**
(`Sources/DebriefApp/AppEnvironment.swift`):

- Audio: `RecordingCoordinator`'s `recordingsRoot` param (default
  `RecordingStore.recordingsRoot()`), threaded from `live()`.
- DB: `root.appendingPathComponent("db/debrief.sqlite")` → `AppDatabase.onDisk(at:)`
  (`AppEnvironment.swift:199-200`, `Sources/Store/AppDatabase.swift:16-20`).
- Prompts: `PromptStore(directory: PromptStore.defaultDirectory())` (`AppEnvironment.swift:201`).

Downstream constructors already accept an injected directory (`WavChunkWriter(directory:)`,
`PromptStore(directory:)`, `RecordingCoordinator(recordingsRoot:)`), so the only hardcoded
decisions are the three above.

**Crash recovery** (`RecordingStore.unfinalizedSessions()`) reads a hardcoded
`recordingsRoot()` — it MUST read the configured audio dir or recovery silently misses sessions.

**Settings:** `Sources/DebriefApp/SettingsView.swift` — a SwiftUI `Form`, one tab in the main
window (`MainTab.settings`), not a native `Settings {}` scene. Non-secret prefs use
`@AppStorage` (UserDefaults) declared in the view and re-read directly via `UserDefaults.standard`
in `AppEnvironment`. Secrets use `KeychainStore`. Runtime-effective changes (e.g. LLM) are applied
imperatively via `env.rebuildCoaching()`. There is no central Settings struct — keyed reads on
both sides. **The app is not sandboxed** (self-signed, full-path file access; no
`NSOpenPanel`/security-scoped-bookmark code exists), so a plain folder path in UserDefaults works —
no bookmark machinery needed.

Transcripts/feedback are DB rows (`Sources/Store/Records.swift`), same SQLite file as everything
else. Backfill patterns already exist: `recoachAll()`, `retryAllPending()`.

## Part A — Configurable data locations

### What's configurable

Three **independent** pickers, each relocating a whole **directory** (moving the directory, not
individual files, is what keeps SQLite's `-wal`/`-shm` sidecars intact):

- **Audio** → the `recordings/` dir.
- **Database** → the `db/` dir (`debrief.sqlite` + sidecars).
- **Prompts** → the `prompts/` dir.

### Move-at-launch (the safety-critical mechanism)

The DB is held open by a live `DatabaseQueue` for the whole run; moving an open SQLite file
corrupts recent writes. So **no move ever happens while the app is running.** Flow:

1. User picks a new folder (`NSOpenPanel`, directories only). We record intent (`from → to`),
   touch nothing.
2. Alert: "Debrief needs to relaunch to move your data." → **Relaunch Now** / **Later**.
3. On next launch, **before `AppEnvironment.live()` opens the DB or builds any store**, a single
   reconcile step executes pending moves, then computes effective paths.

This is the "declared vs. reconciled state" pattern: UserDefaults declares the *desired* location;
one startup reconcile makes the filesystem match. Exactly one place mutates files, and it runs
when nothing holds the data open. Uniform across all three types (audio/prompts aren't locked, but
one code path is simpler than special-casing the DB).

### Storage & reconcile

Per type, track **desired** (user-set via picker, or the historical default when unset) and where
data **currently lives**. At launch: if desired ≠ current and the current location exists →
`FileManager.moveItem(current → desired)`, then adopt desired as current. Then compute effective
paths and thread them into the three chokepoints in `AppEnvironment.live()`, **including the
crash-recovery scan** (`unfinalizedSessions` must use the effective audio dir).

Implementation may use a desired/actual key pair per type, or a single reconcile "pending moves"
record — either is acceptable; the contract is: files move exactly once, at launch, before any
store opens.

### Error handling (data-safety — not lazy here)

- **Move fails** (unwritable target, disk full): abort *that type's* migration, keep data at the
  old location, use the old location this session, surface an error on next open. Never adopt an
  empty new location and orphan the data.
- **Target already contains Debrief data:** refuse with an error rather than overwrite/merge.
- **Same-folder / no-op pick:** ignored.

### UI

New **"Data Locations"** section in `SettingsView`: three rows, each showing the current path + a
**Change…** button. Confirm → relaunch alert. Relaunch offered via the standard macOS
relaunch (`open` the bundle, then `NSApp.terminate`); "Later" just defers to the next manual launch.

## Part B — Cowork export

### Formatter

`SessionMarkdown.render(session, feedback, transcript) -> String` — a **pure** function in
`Store` (next to the records it reads). One markdown file per session, containing exactly what the
DB already holds:

- Header: company · round type · date (+ custom instructions if any)
- **Advancement verdict** (the headline — elicited directly, never derived from scores)
- Overall score + per-dimension scores
- Highlights, action items, process notes, weakness tags
- Full merged (you/them) transcript

**No audio** — Cowork does text work; WAV is useless to it.

### Write behavior

- **Deterministic filename:** e.g. `2026-07-17-Acme-Product-Sense-<shortid>.md`, so re-exports
  overwrite in place (idempotent) — never pile up duplicates.
- **Write site:** at the end of `RecordingCoordinator.runFinalize`, **after** the debrief is
  stored, wrapped in `try?` — exactly like the coaching call. **An export failure must never block
  or fail finalization** (same non-fatal contract as the LLM call). The DB stays the source of
  truth; the export is a re-derivable projection.
- **Enable:** setting the export folder enables it; no separate toggle.

### Settings

New **"Cowork Export"** section: an **Export folder** picker (no relaunch — write-only output,
nothing to move) + an **"Export all sessions now"** button that iterates completed sessions and
writes their markdown, mirroring the existing `recoachAll()` / `retryAllPending()` backfill
pattern. Re-coached sessions re-export over their deterministic filename.

### Remote Cowork

Desktop Cowork reads local folders directly. For **remote** Cowork (Anthropic's isolated env), the
user points the export folder at a cloud-synced location (iCloud Drive, Dropbox) — a user choice,
no code implication.

## Testing

- **Part A:** reconcile function — temp-dir test: seed files, reconcile, assert they moved; assert
  a simulated move failure leaves the source intact.
- **Part B:** `SessionMarkdown.render` on a fixture record — assert the verdict, a score, and a
  transcript line all appear. Pure function, trivial to check.

Hardware capture paths remain covered by `docs/manual-test-checklist.md`, not unit tests.

## Explicitly out of scope

- Export formats other than markdown (JSON, CSV).
- Per-field export toggles / templating.
- Auto-copying WAV audio into the export folder.
- Security-scoped bookmarks (app is not sandboxed).
- A "reset to default location" button (user can pick the default folder manually).
- Merging into a target that already holds Debrief data (refused, not merged).
- Headless/env-var configuration of locations (GUI picker only for now).
