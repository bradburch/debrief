# Incremental Accurate Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the accurate (`small.en`) transcription during the call so finalize reuses cached per-chunk results instead of re-transcribing the whole session, and surface chunk progress in the menu bar.

**Architecture:** The 5 s live loop already polls for newly-closed chunks. Point it at the accurate model and keep its results as the authoritative cache. Finalize inverts to "use cache, else transcribe," so only the last partial chunk (and any un-polled tail) needs work at stop. A single published `transcribeProgress` field drives the UI in both phases.

**Tech Stack:** Swift, SwiftUI, WhisperKit, XCTest. macOS menu-bar app (SPM package).

## Global Constraints

- `RecordingCoordinator` is `@MainActor`; all its methods and `@Published` mutations run on the main actor.
- `Transcribing.transcribe(wavURL:)` returns `[TimedText]` and may throw. A successful call may return `[]`; a failure throws.
- Chunk cache is keyed by `url.lastPathComponent`.
- Recovery path (`finalizeFromDisk`) runs in a fresh process with an empty cache — finalize must still transcribe every chunk from disk in that case. Do not assume the cache is populated.
- Do not reset `transcribeProgress` in `cleanupState()`; reset it only in `startRecording()`. (Post-finalize the value lingers at `done == total`, which is invisible because the UI only reads it during `.recording`/`.finalizing`, and it lets a test assert completion.)

---

### Task 1: Move accurate transcription into the call; finalize reuses the cache

**Files:**
- Modify: `Sources/DebriefApp/RecordingCoordinator.swift`
- Modify: `Sources/DebriefApp/AppEnvironment.swift:73-79`
- Modify: `Sources/Transcriber/WhisperTranscriber.swift:4-7`
- Modify: `Tests/TranscriberTests/WhisperIntegrationTests.swift:20`
- Test: `Tests/DebriefAppTests/RecordingCoordinatorTests.swift`

**Interfaces:**
- Consumes: `Transcribing.transcribe(wavURL:) async throws -> [TimedText]`; `WavChunkWriter.completedChunks: [URL]`; `RecordingStore.chunkURLs(in:prefix:)`.
- Produces (relied on by Task 2):
  - `struct TranscribeProgress: Equatable, Sendable { let done: Int; let total: Int }`
  - `RecordingCoordinator.transcribeProgress: TranscribeProgress?` (`@Published public private(set)`)
  - `RecordingCoordinator.init(db:coaching:transcriber:makeMicRecorder:makeSystemRecorder:recordingsRoot:chunkDuration:deleteAudioOnSuccess:)` — the two transcriber params are collapsed into one `transcriber: Transcribing`.
  - `RecordingCoordinator.transcribeNewChunks() async` — now `internal` (was `private`), so tests can trigger a live pass deterministically.

---

- [ ] **Step 1: Write the failing test for cache reuse + progress completion**

Add these two helpers and one test to `Tests/DebriefAppTests/RecordingCoordinatorTests.swift`.

Add near `FakeTranscriber` (top of file):

```swift
/// Records how many times each chunk filename is transcribed, to prove the
/// finalize pass reuses live-cached chunks instead of re-transcribing them.
final class CountingTranscriber: Transcribing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var callsByChunk: [String: Int] = [:]
    func transcribe(wavURL: URL) async throws -> [TimedText] {
        lock.lock(); callsByChunk[wavURL.lastPathComponent, default: 0] += 1; lock.unlock()
        return [TimedText(start: 1.0, text: "final \(wavURL.lastPathComponent)")]
    }
}
```

Add this test inside `RecordingCoordinatorTests`:

```swift
func testFinalizeReusesLiveCachedChunksAndCompletesProgress() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let db = try AppDatabase.inMemory()
    let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let prompts = PromptStore(directory: promptDir)
    try prompts.ensureDefaults()
    let spy = CountingTranscriber()
    let coordinator = RecordingCoordinator(
        db: db,
        coaching: CoachingService(db: db, prompts: prompts, llm: OKStubLLM()),
        transcriber: spy,
        makeMicRecorder: { FakeRecorder(writer: $0, seconds: 3) },
        makeSystemRecorder: { FakeRecorder(writer: $0, seconds: 3) },
        recordingsRoot: root,
        chunkDuration: 1.0)

    await coordinator.startRecording()
    // Deterministically run one live pass (the 5s timer won't fire in a unit test).
    await coordinator.transcribeNewChunks()
    let cached = Set(spy.callsByChunk.keys)
    XCTAssertFalse(cached.isEmpty, "live pass should have transcribed at least one closed chunk")

    _ = await coordinator.stopAndFinalize(
        metadata: .init(company: "Acme", roundType: .behavioral, notes: ""))

    // No chunk is transcribed more than once: cached chunks are reused, and only
    // the uncached final-partial chunk gets transcribed at finalize.
    for (chunk, count) in spy.callsByChunk {
        XCTAssertEqual(count, 1, "\(chunk) transcribed \(count)x; cached chunks must not be re-transcribed")
    }
    // Progress reached completion.
    let p = try XCTUnwrap(coordinator.transcribeProgress)
    XCTAssertEqual(p.done, p.total)
    XCTAssertGreaterThan(p.total, 0)
}
```

- [ ] **Step 2: Run the test to verify it fails to compile**

Run: `swift test --filter RecordingCoordinatorTests`
Expected: BUILD FAILURE — `transcriber:` label unknown on `RecordingCoordinator.init` and `transcribeProgress` / `transcribeNewChunks` not accessible. (The existing tests also still use the old two-transcriber init; they will be fixed in Step 6.)

- [ ] **Step 3: Add `TranscribeProgress`, swap the model, collapse to one transcriber, publish progress**

In `Sources/DebriefApp/RecordingCoordinator.swift`:

Add the progress type just below the `RecordingPhase` enum (after line 23):

```swift
public struct TranscribeProgress: Equatable, Sendable {
    public let done: Int
    public let total: Int
    public init(done: Int, total: Int) { self.done = done; self.total = total }
}
```

Add the published field next to the other `@Published` properties (after `streamWarning`, line 32):

```swift
    @Published public private(set) var transcribeProgress: TranscribeProgress?
```

Replace the two transcriber stored properties (lines 36-37):

```swift
    private let transcriber: Transcribing
```

Replace the cache property (line 49):

```swift
    private var chunkTranscripts: [String: [TimedText]] = [:]  // chunk filename -> accurate segments
```

Update the initializer signature and body (lines 54-64). New signature and the assignment line:

```swift
    public init(db: AppDatabase,
                coaching: CoachingService,
                transcriber: Transcribing,
                makeMicRecorder: @escaping (WavChunkWriter) -> StreamRecorder,
                makeSystemRecorder: @escaping (WavChunkWriter) -> StreamRecorder,
                recordingsRoot: URL = RecordingStore.recordingsRoot(),
                chunkDuration: TimeInterval = 30,
                deleteAudioOnSuccess: Bool = true) {
        self.db = db; self.coaching = coaching
        self.transcriber = transcriber
        self.makeMicRecorder = makeMicRecorder; self.makeSystemRecorder = makeSystemRecorder
        self.recordingsRoot = recordingsRoot; self.chunkDuration = chunkDuration
        self.deleteAudioOnSuccess = deleteAudioOnSuccess
    }
```

In `startRecording()`, replace `liveCache = [:]` (line 98) with:

```swift
            chunkTranscripts = [:]
            transcribeProgress = nil
```

Replace `transcribeNewChunks` (lines 116-121) — now `internal`, using the accurate transcriber, caching only on success, and publishing progress:

```swift
    func transcribeNewChunks() async {
        let chunks = (micWriter?.completedChunks ?? []) + (sysWriter?.completedChunks ?? [])
        for url in chunks where chunkTranscripts[url.lastPathComponent] == nil {
            // Cache only on success; a thrown failure stays uncached so it is retried
            // (here on the next poll, and again at finalize). A successful-but-empty
            // result caches as [] and counts as done.
            if let segments = try? await transcriber.transcribe(wavURL: url) {
                chunkTranscripts[url.lastPathComponent] = segments
            }
        }
        let done = chunks.filter { chunkTranscripts[$0.lastPathComponent] != nil }.count
        transcribeProgress = TranscribeProgress(done: done, total: chunks.count)
    }
```

In `runFinalize`, seed the finalize progress total. Replace lines 213-216 with:

```swift
            phase = .finalizing(status: "Transcribing…")
            transcribeProgress = TranscribeProgress(done: 0, total: micChunks.count + sysChunks.count)
            let you = await transcribeStream(chunks: micChunks)
            let them = await transcribeStream(chunks: sysChunks)
            let lines = TranscriptMerger.merge(you: you, them: them)
```

Replace `transcribeStream` (lines 256-271) with the reuse-then-transcribe form:

```swift
    /// Build one stream's transcript, offsetting each chunk's segment times by its
    /// position. Reuses the accurate result the live loop already cached; only
    /// transcribes chunks not yet cached (the final partial chunk, an un-polled tail,
    /// or — on crash recovery — every chunk, since a fresh process has no cache).
    private func transcribeStream(chunks: [URL]) async -> [TimedText] {
        var all: [TimedText] = []
        for (index, url) in chunks.enumerated() {
            let offset = Double(index) * chunkDuration
            let segments: [TimedText]
            if let cached = chunkTranscripts[url.lastPathComponent] {
                segments = cached
            } else if let fresh = try? await transcriber.transcribe(wavURL: url) {
                segments = fresh
            } else {
                // ponytail: base.en fallback removed. A chunk that fails the accurate
                // model both live and here yields empty text; failures are correlated
                // (same audio/lib), so this is rare. Upgrade path: re-add a lighter
                // fallback model only if empties show up in practice.
                segments = []
            }
            all += segments.map { TimedText(start: $0.start + offset, text: $0.text) }
            transcribeProgress = transcribeProgress.map { TranscribeProgress(done: $0.done + 1, total: $0.total) }
        }
        return all
    }
```

In `cleanupState()` (line 276), rename the cache reset. Replace `liveTask = nil; liveCache = [:]` with:

```swift
        liveTask = nil; chunkTranscripts = [:]
```

(Leave `transcribeProgress` untouched here — per Global Constraints it resets only in `startRecording`.)

- [ ] **Step 4: Remove the `base.en` model and update its wiring**

In `Sources/Transcriber/WhisperTranscriber.swift`, replace the enum (lines 4-7) with the single remaining case:

```swift
public enum WhisperModel: String, Sendable {
    case accurate = "small.en" // per-chunk transcription, live during the call and at finalize
}
```

In `Sources/DebriefApp/AppEnvironment.swift`, replace the coordinator construction (lines 73-79) with the single-transcriber form:

```swift
            let coordinator = RecordingCoordinator(
                db: db, coaching: coaching,
                transcriber: WhisperTranscriber(model: .accurate),
                makeMicRecorder: { MicRecorder(writer: $0) },
                makeSystemRecorder: { SystemAudioRecorder(writer: $0) },
                deleteAudioOnSuccess: !keepAudio)
```

In `Tests/TranscriberTests/WhisperIntegrationTests.swift` line 20, change `.live` to `.accurate`:

```swift
        let transcriber = WhisperTranscriber(model: .accurate)
```

- [ ] **Step 5: Verify no stale references remain**

Run: `cd ~/dev/debrief && grep -rn "model: \.live\|liveTranscriber\|finalTranscriber\|liveCache" Sources Tests`
Expected: no matches. (Pattern is `model: .live`, not `.live`, to avoid matching the unrelated `AppEnvironment.live()` factory. If any of the four remain, fix them before continuing.)

- [ ] **Step 6: Update the existing tests to the single-transcriber init**

In `Tests/DebriefAppTests/RecordingCoordinatorTests.swift`, `makeCoordinator` (lines 49-58): replace the two `...Transcriber:` lines with one. The block becomes:

```swift
        return RecordingCoordinator(
            db: db,
            coaching: CoachingService(db: db, prompts: prompts, llm: OKStubLLM()),
            transcriber: FakeTranscriber(textForChunk: "final"),
            makeMicRecorder: { FakeRecorder(writer: $0, seconds: 2) },
            makeSystemRecorder: { FakeRecorder(writer: $0, seconds: 2) },
            recordingsRoot: root,
            chunkDuration: 1.0,
            deleteAudioOnSuccess: deleteAudio)
```

In `testLiveFinalizeUsesExactWallClockDuration` (lines 142-149), make the same substitution:

```swift
        let coordinator = RecordingCoordinator(
            db: db,
            coaching: CoachingService(db: db, prompts: prompts, llm: OKStubLLM()),
            transcriber: FakeTranscriber(textForChunk: "final"),
            makeMicRecorder: { FakeRecorder(writer: $0, seconds: 2) },
            makeSystemRecorder: { FakeRecorder(writer: $0, seconds: 2) },
            recordingsRoot: root)
```

(`testFullLifecyclePersistsSessionAndDeletesAudio` asserts segment text contains `"final"`; the single `FakeTranscriber(textForChunk: "final")` keeps that assertion valid.)

- [ ] **Step 7: Run the full DebriefApp + Transcriber tests to verify green**

Run: `cd ~/dev/debrief && swift test --filter RecordingCoordinatorTests && swift test --filter TranscriptMergerTests`
Expected: PASS — including the new `testFinalizeReusesLiveCachedChunksAndCompletesProgress`, and the unchanged `testFullLifecyclePersistsSessionAndDeletesAudio`, `testChunkOffsetsApplied`, `testLiveFinalizeUsesExactWallClockDuration`, `testStreamHealthWarnsAfterSilence`, plus `RecoveryTests` if included by the filter. If recovery tests exist, run them too: `swift test --filter RecoveryTests`.

- [ ] **Step 8: Commit**

```bash
cd ~/dev/debrief
git add Sources/DebriefApp/RecordingCoordinator.swift Sources/DebriefApp/AppEnvironment.swift Sources/Transcriber/WhisperTranscriber.swift Tests/DebriefAppTests/RecordingCoordinatorTests.swift Tests/TranscriberTests/WhisperIntegrationTests.swift
git commit -m "feat(transcription): run accurate model during call, reuse at finalize

Point the live loop at small.en and keep its per-chunk results as the
authoritative cache; finalize reuses them and only transcribes the
uncached tail (final partial chunk, or every chunk on crash recovery).
Collapse the two transcribers into one, drop the unused base.en model,
and publish transcribeProgress for the UI.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Show chunk progress in the menu bar

**Files:**
- Modify: `Sources/DebriefApp/MenuBarView.swift:30-59`

**Interfaces:**
- Consumes: `RecordingCoordinator.transcribeProgress: TranscribeProgress?` (from Task 1).
- Produces: nothing downstream.

This task is UI-only; SwiftUI views have no unit test here, so verification is a build + a manual look (Step 3).

- [ ] **Step 1: Add the progress line to both phases**

In `Sources/DebriefApp/MenuBarView.swift`, in the `.recording` case, add a caption after the `LevelRow`s / warning block (after line 38, before the `Divider()` on line 39):

```swift
                if let p = env.coordinator.transcribeProgress, p.total > 0 {
                    Text("Transcribed \(p.done)/\(p.total) chunks")
                        .font(.caption).foregroundStyle(.secondary)
                }
```

Replace the `.finalizing` case (lines 53-54) with a version that appends the fraction while transcription is still in flight:

```swift
            case .finalizing(let status):
                HStack { ProgressView().controlSize(.small); Text(status) }
                if let p = env.coordinator.transcribeProgress, p.done < p.total {
                    Text("\(p.done)/\(p.total) chunks")
                        .font(.caption).foregroundStyle(.secondary)
                }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd ~/dev/debrief && swift build`
Expected: Build succeeds.

- [ ] **Step 3: Manual visual check**

Launch the app (or the built `Debrief.app`), start a recording, and confirm the menu bar shows a ticking `Transcribed N/M chunks` during recording and `N/M chunks` under `Transcribing…` at stop. (No automated test — this is a SwiftUI view.)

- [ ] **Step 4: Commit**

```bash
cd ~/dev/debrief
git add Sources/DebriefApp/MenuBarView.swift
git commit -m "feat(ui): show transcription chunk progress in the menu bar

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Notes for the executor

- **`chunkDuration` in unit tests is 1.0s** and `FakeRecorder` synthesizes 1s appends, so a few chunks close per stream. The reuse test uses `seconds: 3` to guarantee at least one closed chunk exists before `transcribeNewChunks()` runs.
- **The 5s live timer never fires in unit tests** (start→stop happens in well under 5s). That is why the reuse test calls `transcribeNewChunks()` directly. Production liveness relies on the timer in `startLiveTranscription()`, which is unchanged.
- **Crash recovery is covered by the "else transcribe" branch**: `finalizeFromDisk` starts with an empty `chunkTranscripts`, so every chunk falls through to a fresh transcription. If `RecoveryTests` exists, it should still pass unchanged.
