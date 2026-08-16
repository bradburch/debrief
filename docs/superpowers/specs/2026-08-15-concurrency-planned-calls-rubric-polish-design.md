# Design: record-while-finalizing, planned calls, rubric repair, UI polish

Approved 2026-08-15. Four workstreams, four PRs, in this order. PR 1 stacks on the open
docs-refresh PR (#21); PR 3 bases on main; PRs 2 and 4 stack on PR 1.

## 1. Record while another session finalizes

Split `RecordingCoordinator`'s single `phase` into:

- `recordingPhase: RecordingPhase` — `.idle / .recording(started:) / .failed(message:)` (start
  failures only; finalize failures live on the job).
- `finalizeJobs: [FinalizeJob]` — published display state: id, dir, company, status text,
  progress, failure. Drained FIFO by one runner Task. Finalizes run serially with each other
  (they contend on Whisper and the DB anyway) but concurrently with recording.
- `claimedDirs: Set<String>` — private, non-published, keyed by session-directory UUID
  (`lastPathComponent`, never raw URL paths — /var vs /private/var). This is the lock.

Invariant, translated from the old phase lock: **the exclusive resource is a session
directory.** Check-and-claim `claimedDirs` with no `await` between (atomic on @MainActor), in
`stopAndFinalize`, `finalizeFromDisk`, and the runner. Exactly one release site, in a `defer`,
on every exit path including the zero-chunk early return. Never infer a claim from
`finalizeJobs` (display state).

Required companion fixes (not optional):

- All per-session capture state (`sessionDir`, writers, recorders, `liveTask`,
  `chunkTranscripts`, `lastMicAudio/lastSysAudio`, progress) collapses into one
  `LiveSession` struct, `live: LiveSession?`.
- The per-chunk transcript cache is keyed by bare filename and every session has a
  `mic-0000.wav` — pass the cache **by value** into `runFinalize` to kill cross-session
  transcript swaps.
- `WhisperTranscriber` gets an explicit serial gate (task-chaining): the actor is reentrant,
  so without it A's finalize and B's live loop run `pipe.transcribe` concurrently on one
  WhisperKit pipeline — wrong-output failure, not a crash. `loadedPipe()` dedup is already
  correct.
- `transcribeNewChunks`'s per-chunk loop gets a `Task.isCancelled` check;
  `stopAndFinalize` awaits `liveTask` after cancelling.
- `startRecording` claims the phase **before** its first `await` (today two concurrent starts
  both pass the guard).
- Crash recovery: expose `activeDirs` (live dir ∪ claimed dirs); filter it from
  `recoverableSessions`; `finalizeFromDisk` refuses claimed dirs (authority), UI filter is
  belt-and-braces. Rescan recoverables when a job completes.
- Quit safety: confirm on quit while `!finalizeJobs.isEmpty`; stamp the session id into the
  dir manifest when the row inserts so recovery skips dirs whose session already exists
  (closes the duplicate-row window).
- New `CoachingStatus.running` (plain TEXT column, no migration): set before the LLM await,
  excluded from `sessionsNeedingCoaching()`, swept `running → pending` on launch. NOT added to
  `sessionsWithTranscript()` (it serves recoachAll + exportAll — do not narrow it).
- UI: menu bar icon combines recording state + job count; MenuBarView and RecordingBar render
  a persistent jobs section alongside any recording state; `SessionsView`'s
  `.idle`-means-finalize-finished refresh becomes a job-completion observation;
  Settings `canRelocate` and retry sweep gate on `finalizeJobs.isEmpty`.
- `stopAndFinalize` becomes non-blocking; expose `awaitFinalize(_:) async -> Int64?` for the
  ~9 test call sites. Rewrite `testRecoveryRefusedWhileNotIdle` (now allowed by design) and
  `testConcurrentRecoveryRefused` (same-dir refusal + different-dirs-both-complete). New
  tests: B-records-while-A-finalizes with non-crossed transcripts (transcriber fake must echo
  the directory, not just filename), failed finalize of A leaves B recording.
- CLAUDE.md crash-safety/concurrency paragraphs + manual-test-checklist get updated in this PR
  (based on the refreshed docs from #21).

## 2. Pre-created (planned) calls

- Migration v6: `plannedCall(id, companyName TEXT, role TEXT, roundType TEXT,
  scheduledDate DATETIME, notes TEXT, customInstructions TEXT)`. Company as text — finalize
  already resolves via `fetchOrCreateCompany`. NOT sessions in a planned state: they'd show as
  zero-minute rows in Sessions/Pipeline, and `runFinalize`'s orphan-compensation deletes the
  row on a no-speech call.
- `SessionMetadata` gains `customInstructions` (and role folded into it or notes), passed to
  `insertSession` — pre-entered criteria reach the FIRST debrief.
- Planned calls merge into the existing upcoming/pre-fill pipeline (`AppEnvironment.upcoming`,
  `apply(_:)`, the "From calendar" menu); `apply` also stashes criteria in a new
  `recordCriteria`. The planned row is consumed (deleted) only after finalize returns a
  session id. The crash-recovery prompt gets the same pre-fill menu.
- UI: "Plan a call" sheet reachable from the Sessions toolbar and the menu-bar popover idle
  state; a small upcoming list showing planned calls.

## 3. Rubric repair (no new round types)

Finding: the requested Technical-Coding / System-Design / Project-Deep-Dive types already
ship as `technical.md`, `system_design.md`, `tech_deep_dive.md`. Fix in place; no renames
(renames fork Trends history).

Eleven approved wording fixes (exact text in the review, summarized):
infer-and-name target level; two-directional calibration (measured mean 2.19, zero 5s — the
anti-leniency text pushes an already-harsh judge down); `conciseness` rewritten (WhisperKit
deletes um/uh — filler counts are confabulated; judge length via line-start timestamps);
`correctness` rewritten around audible evidence (THEM's reactions), never "judge the CODE";
`highlights` 3-5 with mandatory strengths; `questions_asked` disambiguated from problem-scoping
questions; a general not-observed-scores-3-and-say-so rule; `driving` loses "whiteboard";
`complexity_and_testing` scores narration only; 5-anchors added to the ~20 failure-only
dimensions; base↔overlay precedence rule (overlay wins). Plus an audio-only evidence caveat
section in base.md.

Contract-wide changes (one agent owns all ends): `highlights` gets `minItems: 3` in
`AnthropicClient.outputSchema` — verified against the real API via `CoachingIntegrationTests`
(the API rejects some schema keywords; if 400, drop the keyword, keep prose) — and the same
rule in `OpenAICompatibleClient.formatAppendix` prose.

Deployment: `ensureDefaults()` never updates existing files, so the same fixes are written to
`~/Library/Application Support/Debrief/prompts/*.md` with timestamped `.bak` backups.
`recoachAll()` is NOT run automatically (bills ~30 LLM calls; user's button).

## 4. UI polish + Dock icon

- Dock presence: drop `LSUIElement` (scripts/make-app.sh:31) so the app shows in the Dock as
  well as the menu bar; Dock icon click opens/focuses the main window; revisit the
  MenuBarView focus workaround that assumes LSUIElement.
- Toolbars: `.toolbar` on Sessions (New/Plan a call, filter via `.searchable`), Pipeline,
  Trends.
- Button hierarchy: `.borderedProminent` on primary actions (Record, Stop & Debrief),
  `.destructive` role styling on deletes; icons on Edit/Duplicate/Delete rows.
- One shared `ScoreBadge`/verdict component replacing the three hand-rolled copies
  (SessionsView ×2, PipelineView).
- `ContentUnavailableView` empty states on Pipeline and Trends (match Sessions).
- Product copy for coaching status instead of raw `coachingStatus.rawValue`.
- Menu-bar popover: scrollable, jobs section, no fixed-height overflow.
- Window frame persistence for the main window.
- Weakness-tag chips: neutral/warning tint, not universal alarm red.
- Trends: `.chartYScale` domain matches the 1–5 contract; note `technical_depth` /
  `quantified_impact` are shared across two overlays with different definitions (split series
  by round type or label it).
