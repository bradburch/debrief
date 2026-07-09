# Incremental Accurate Transcription

**Date:** 2026-07-08
**Status:** Approved, pending implementation

## Problem

Two complaints about the post-call flow:

1. **Slow.** After the user hits stop, transcription takes minutes on a long call.
2. **Opaque.** The UI shows only `"Transcribing…"` — no progress, no sign of liveness.

### Root cause

During a call, the live loop (`RecordingCoordinator.startLiveTranscription`, 5 s poll)
transcribes every closed chunk with `base.en` (fast) into `liveCache`. That result is
**never shown to the user** — it's read only as a per-chunk fallback in
`transcribeStream` (`RecordingCoordinator.swift:266`).

At stop, `runFinalize` throws the live results away and re-runs the *entire* session
through `small.en` (accurate, slower), one chunk at a time, mic stream fully then system
stream fully — all serial. So the post-stop wait is a full accurate re-pass over the
whole call, and nothing reflects its progress.

The redundancy (transcribe fast → discard → transcribe slow) is the seam both goals cut
through.

## Approach

Move the accurate transcription **into the call** so finalize has almost nothing left to
do, and surface chunk progress as a natural byproduct.

### 1. Accurate transcription runs during the call

- The 5 s live loop switches `base.en` → `small.en` and caches the **accurate** per-chunk
  result as each chunk closes.
- `liveCache` (throwaway fallback) becomes `chunkTranscripts` — the authoritative source
  finalize reads from.
- `RecordingCoordinator`'s two transcriber params (`liveTranscriber`, `finalTranscriber`)
  collapse to a single `transcriber`.
- `AppEnvironment` stops constructing the `base.en` model. `WhisperModel.live` is deleted
  if nothing else references it. One model to load/download instead of two.
- `small.en` now loads at call-start (first poll) instead of at finalize — moving the
  model-load stall and any first-run weight download off the moment the user is waiting.

### 2. Finalize becomes reuse + drain

`transcribeStream` inverts priority: **use the cache if present, else transcribe now.**

At stop, the only uncached chunks are the final partial chunk (flushed after the last
poll) and any that closed in the last few seconds — a handful at most. The post-stop
transcription goes from "the whole call" to "≤ a chunk or two." Merge → save → coach
downstream is unchanged.

### 3. Progress reporting

Add one published field on the coordinator: `transcribeProgress: (done: Int, total: Int)?`.

- **During recording:** the live loop sets it — `done` = chunks cached, `total` = chunks
  closed so far. A ticking `"8/9"` is visible proof the pipeline is alive.
- **During finalize:** the drain loop increments it — `"Transcribing 13/14…"`.

`phase` keeps its stage labels (Stopping / Saving / Coaching); `transcribeProgress`
supplies the fraction. Two fields, one job each. `MenuBarView` renders the fraction next
to the spinner in both phases.

## Data flow

```
Recording ── live loop (5 s poll) ── small.en per new closed chunk ── chunkTranscripts[filename]
                                                                    └─ update transcribeProgress
Stop ── cancel loop, flush writers ──▶ finalize:
    for each chunk: chunkTranscripts[filename] ?? transcribe(now)   (drain the few uncached)
                    └─ update transcribeProgress
    ── merge ── save session + segments ── coach
```

## Risks & tradeoffs

- **`small.en` during the call is heavier than `base.en`.** On M-series it stays real-time
  with margin (30 s chunk ≈ 2–6 s, polled every 5 s). If it ever falls behind, the backlog
  drains at finalize — that path is today's behavior, so the worst case is "no better than
  now," never worse. The real cost is **battery/thermal on long calls** (continuous ANE
  inference alongside Zoom + camera). Modest; measure-then-fix (throttle poll or restore
  `base.en` live behind a flag) rather than build a mitigation speculatively.

- **Dropping the `base.en` fallback.** It only helped when `small.en` failed a chunk that
  `base.en` survived. The common failures (model can't load; corrupt/empty audio) hit both
  models identically — correlated. The design also **retries `small.en` at finalize** for
  any chunk that failed live. Residual exposure: a chunk failing `small.en` twice logs +
  yields empty text (vs. rough `base.en` text before). Rare, logged, low-stakes. Marked
  with a `ponytail:` comment at the fallback site.

- **Cache-key mismatch (non-risk, noted for safety).** The cache is keyed by chunk
  filename. If the live loop and finalize ever disagreed on a key, that chunk is a cache
  *miss* → transcribed at finalize. Worst case "slow like today," never wrong output. Safe
  failure direction.

## Testing

One meaningful check in `RecordingCoordinatorTests`, using a spy transcriber that counts
calls per chunk URL:

- Finalize does **not** re-transcribe chunks already cached by the live loop — the core
  speed guarantee.
- `transcribeProgress` reaches `done == total` after finalize.

No new frameworks or fixtures beyond the existing test setup.

## Files touched

- `Sources/DebriefApp/RecordingCoordinator.swift` — live loop model swap, cache semantics,
  finalize reuse/drain, `transcribeProgress` publishing, collapse to one transcriber.
- `Sources/DebriefApp/AppEnvironment.swift` — wiring: single accurate transcriber.
- `Sources/DebriefApp/MenuBarView.swift` — render `transcribeProgress`.
- `Sources/Transcriber/WhisperTranscriber.swift` — delete `WhisperModel.live` if unused.
- `Tests/DebriefAppTests/RecordingCoordinatorTests.swift` — spy-based reuse + progress test.

## Out of scope (YAGNI)

- Event-driven chunk-close notifications (the 5 s poll already discovers new chunks
  promptly).
- Parallelizing the two streams / multiple model pipes (unnecessary once finalize is
  near-empty).
- A runtime model selector / real-time-keeps-up guard (add only if measurement shows
  `small.en` can't keep up).
