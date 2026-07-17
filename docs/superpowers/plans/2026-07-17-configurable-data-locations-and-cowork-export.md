# Configurable Data Locations + Cowork Export — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users relocate Debrief's audio/database/prompts directories, and export each session as a readable markdown file so Claude Cowork can work with transcripts and debriefs.

**Architecture:** Two independent parts. **Part B (Tasks 1–4)** adds a pure `SessionMarkdown` renderer in `CoachingEngine`, export methods on `CoachingService`, an auto-export hook in `runFinalize`, and an Export-folder setting. **Part A (Tasks 5–7)** adds `DataLocations` in `DebriefApp` that reconciles desired-vs-actual directories at launch (moving data before any store opens), threads the effective paths through `AppEnvironment.live()`, and adds three pickers + relaunch to Settings. Build Part B first — it's what serves Cowork and has no dependency on Part A.

**Tech Stack:** Swift Package (no xcodeproj), SwiftUI + AppKit (`NSOpenPanel`, `NSWorkspace`), GRDB/SQLite, XCTest. macOS 14+.

## Global Constraints

- **Toolchain:** every `swift` command MUST run under Xcode's toolchain: prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the Command Line Tools instance has no XCTest).
- **Run tests** with `--skip IntegrationTests` unless a task says otherwise.
- **The app is not sandboxed** — plain folder paths in `UserDefaults` work; do NOT add security-scoped bookmarks.
- **Determinism in library code:** `Date.now`/`Math.random` are fine in the app but forbidden in test assertions on filenames — use `DateFormatter` with `Locale(identifier: "en_US_POSIX")` and an explicit `dateFormat`.
- **UserDefaults keys (verbatim):**
  - Export: `"exportDirectory"` (String path; `""`/absent = export disabled)
  - Audio: `"audioDirDesired"`, `"audioDirActual"`, `"audioDirError"`
  - Database: `"dbDirDesired"`, `"dbDirActual"`, `"dbDirError"`
  - Prompts: `"promptsDirDesired"`, `"promptsDirActual"`, `"promptsDirError"`
- **Canonical subdir names** appended to a user-picked parent folder: audio → `recordings`, db → `db`, prompts → `prompts`. A stored desired/actual value is always the *full* effective directory (parent + canonical name).
- **Non-fatal contract:** export must never block or fail finalization — wrap the auto-export call in `try?`, exactly like the existing `try? await coaching.coach(...)`.
- **Commit** after each task's tests pass.

---

### Task 1: `SessionMarkdown` renderer (pure)

**Files:**
- Create: `Sources/CoachingEngine/SessionMarkdown.swift`
- Test: `Tests/CoachingEngineTests/SessionMarkdownTests.swift`

**Interfaces:**
- Consumes: `Store.SessionDetail` (`session`, `company`, `segments`, `feedback: FeedbackRecord?`, `tags: [String]`), `Store.formatTimestamp(_:)`, `Store.Advancement`, `CoachingEngine.Highlight`.
- Produces:
  - `SessionMarkdown.render(_ detail: SessionDetail) -> String`
  - `SessionMarkdown.filename(for detail: SessionDetail) -> String`
  - `SessionMarkdown.slug(_ s: String) -> String` (internal)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import Store
@testable import CoachingEngine

final class SessionMarkdownTests: XCTestCase {
    private func fixture() -> SessionDetail {
        let session = InterviewSession(
            id: 42, companyId: 1, roundType: .productSense,
            date: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 1800,
            contextNotes: "senior PM loop", coachingStatus: .complete, customInstructions: "")
        let company = Company(id: 1, name: "Acme Corp!", status: .active)
        let segments = [
            TranscriptSegmentRecord(id: 1, sessionId: 42, speaker: .them, tStart: 0, text: "Tell me about a product you shipped."),
            TranscriptSegmentRecord(id: 2, sessionId: 42, speaker: .you, tStart: 4, text: "I led the checkout redesign."),
        ]
        let feedback = FeedbackRecord(
            id: 1, sessionId: 42,
            proseDebrief: "Strong structure, thin on metrics.",
            scoresJSON: #"{"structure":4,"metrics":2}"#,
            highlightsJSON: #"[{"t":"00:00:04","note":"Clear ownership framing"}]"#,
            actionItemsJSON: #"["Quantify impact with a metric"]"#,
            overallScore: 3.0,
            advancement: "lean_yes", advancementRationale: "Advances on communication.",
            processNotesJSON: #"[{"t":"00:10:00","note":"Next round in a week"}]"#)
        return SessionDetail(session: session, company: company, segments: segments, feedback: feedback, tags: ["weak_metrics"])
    }

    func testRenderContainsHeadlineSections() {
        let md = SessionMarkdown.render(fixture())
        XCTAssertTrue(md.contains("# Acme Corp! — Product Sense"))
        XCTAssertTrue(md.contains("## Verdict: Lean Yes"))
        XCTAssertTrue(md.contains("Advances on communication."))
        XCTAssertTrue(md.contains("- structure: 4"))
        XCTAssertTrue(md.contains("Quantify impact with a metric"))
        XCTAssertTrue(md.contains("Next round in a week"))
        XCTAssertTrue(md.contains("`weak_metrics`"))
        XCTAssertTrue(md.contains("[00:00:04] YOU: I led the checkout redesign."))
    }

    func testFilenameIsDeterministicAndSlugged() {
        XCTAssertEqual(SessionMarkdown.filename(for: fixture()), "2023-11-14-acme-corp-product_sense-42.md")
    }

    func testRenderWithoutFeedbackStillHasTranscript() {
        let base = fixture()
        let noFeedback = SessionDetail(session: base.session, company: base.company,
                                       segments: base.segments, feedback: nil, tags: [])
        let md = SessionMarkdown.render(noFeedback)
        XCTAssertFalse(md.contains("## Verdict"))
        XCTAssertTrue(md.contains("## Transcript"))
        XCTAssertTrue(md.contains("[00:00:00] THEM: Tell me about a product you shipped."))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SessionMarkdownTests`
Expected: FAIL — `SessionMarkdown` is undefined / no such module member.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import Store

/// Renders a session (transcript + debrief) as a standalone markdown document, and derives
/// a deterministic filename for it. A pure projection of the DB — no IO — so it is trivially
/// testable and re-exportable. Lives in CoachingEngine because it decodes the feedback JSON
/// columns using Highlight, which Store cannot import.
public enum SessionMarkdown {
    public static func render(_ detail: SessionDetail) -> String {
        let s = detail.session
        var out = "# \(detail.company.name) — \(s.roundType.displayName)\n\n"

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        out += "- Date: \(stamp.string(from: s.date))\n"
        out += "- Duration: \(s.durationSeconds / 60) min\n"
        if !s.contextNotes.isEmpty { out += "- Notes: \(s.contextNotes)\n" }
        if !s.customInstructions.isEmpty { out += "- Custom criteria: \(s.customInstructions)\n" }
        out += "\n"

        if let f = detail.feedback {
            if let adv = f.advancementValue {
                out += "## Verdict: \(adv.displayName)\n\n"
                if !f.advancementRationale.isEmpty { out += "\(f.advancementRationale)\n\n" }
            }
            if !f.proseDebrief.isEmpty { out += "## Debrief\n\n\(f.proseDebrief)\n\n" }

            let dec = JSONDecoder()
            if let scores = try? dec.decode([String: Int].self, from: Data(f.scoresJSON.utf8)), !scores.isEmpty {
                out += "## Scores (1–5)\n\n- Overall: \(String(format: "%.1f", f.overallScore))\n"
                for key in scores.keys.sorted() { out += "- \(key): \(scores[key]!)\n" }
                out += "\n"
            }
            if let highs = try? dec.decode([Highlight].self, from: Data(f.highlightsJSON.utf8)), !highs.isEmpty {
                out += "## Highlights\n\n"
                for h in highs { out += "- [\(h.t)] \(h.note)\n" }
                out += "\n"
            }
            if let items = try? dec.decode([String].self, from: Data(f.actionItemsJSON.utf8)), !items.isEmpty {
                out += "## Action items\n\n"
                for i in items { out += "- \(i)\n" }
                out += "\n"
            }
            if let notes = try? dec.decode([Highlight].self, from: Data(f.processNotesJSON.utf8)), !notes.isEmpty {
                out += "## Process notes\n\n"
                for n in notes { out += "- [\(n.t)] \(n.note)\n" }
                out += "\n"
            }
            if !detail.tags.isEmpty {
                out += "## Weakness tags\n\n" + detail.tags.map { "`\($0)`" }.joined(separator: " ") + "\n\n"
            }
        }

        out += "## Transcript\n\n"
        for seg in detail.segments {
            out += "[\(formatTimestamp(seg.tStart))] \(seg.speaker.rawValue): \(seg.text)\n"
        }
        return out
    }

    public static func filename(for detail: SessionDetail) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let date = day.string(from: detail.session.date)
        let company = slug(detail.company.name)
        let round = detail.session.roundType.rawValue
        let id = detail.session.id ?? 0
        return "\(date)-\(company)-\(round)-\(id).md"
    }

    /// "Acme Corp!" -> "acme-corp". Lowercase, non-alphanumerics collapse to single hyphens.
    static func slug(_ s: String) -> String {
        let mapped = s.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "session" : collapsed
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SessionMarkdownTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CoachingEngine/SessionMarkdown.swift Tests/CoachingEngineTests/SessionMarkdownTests.swift
git commit -m "Add SessionMarkdown renderer for session export"
```

---

### Task 2: Export methods on `CoachingService`

**Files:**
- Modify: `Sources/CoachingEngine/CoachingService.swift` (add two methods; end of the struct, before the closing brace ~line 115)
- Test: `Tests/CoachingEngineTests/CoachingExportTests.swift`

**Interfaces:**
- Consumes: `SessionMarkdown.render`, `SessionMarkdown.filename`, `AppDatabase.sessionDetail(id:)`, `AppDatabase.sessionsWithTranscript() -> [InterviewSession]`.
- Produces:
  - `CoachingService.exportSession(id: Int64, to directory: URL) throws`
  - `CoachingService.exportAll(to directory: URL) -> [Int64: Error]`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import Store
@testable import CoachingEngine

final class CoachingExportTests: XCTestCase {
    private func makeService(_ db: AppDatabase) -> CoachingService {
        // llm is unused by export; any client is fine.
        CoachingService(db: db, prompts: PromptStore(directory: URL(fileURLWithPath: "/tmp/none")),
                        llm: AnthropicClient(apiKey: "", model: "x"))
    }

    private func seedSession(_ db: AppDatabase, company: String) throws -> Int64 {
        let c = try db.fetchOrCreateCompany(named: company)
        let s = try db.insertSession(InterviewSession(
            id: nil, companyId: c.id!, roundType: .behavioral, date: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, contextNotes: "", coachingStatus: .complete))
        _ = try db.insertSegments([
            TranscriptSegmentRecord(id: nil, sessionId: s.id!, speaker: .you, tStart: 0, text: "Hello there.")
        ])
        return s.id!
    }

    func testExportSessionWritesFile() throws {
        let db = try AppDatabase.inMemory()
        let id = try seedSession(db, company: "Acme")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try makeService(db).exportSession(id: id, to: dir)

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 1)
        let contents = try String(contentsOf: dir.appendingPathComponent(files[0]), encoding: .utf8)
        XCTAssertTrue(contents.contains("# Acme — Behavioral"))
        XCTAssertTrue(contents.contains("Hello there."))
    }

    func testExportAllWritesOnePerSession() throws {
        let db = try AppDatabase.inMemory()
        _ = try seedSession(db, company: "Acme")
        _ = try seedSession(db, company: "Globex")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let errors = makeService(db).exportAll(to: dir)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CoachingExportTests`
Expected: FAIL — `exportSession`/`exportAll` undefined. (If `db.insertSession`/`insertSegments`/`sessionsWithTranscript` signatures differ, check `Sources/Store/Queries.swift` and adjust the fixture — do not change production signatures.)

- [ ] **Step 3: Write the implementation** — add to `CoachingService` (inside the struct):

```swift
    /// Writes one session's markdown to `directory` (created if needed), overwriting the
    /// deterministic per-session filename so re-exports don't pile up. No-op if the session
    /// or its detail is missing.
    public func exportSession(id: Int64, to directory: URL) throws {
        guard let detail = try db.sessionDetail(id: id) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(SessionMarkdown.filename(for: detail))
        try SessionMarkdown.render(detail).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Exports every session that has a transcript. Returns per-session errors; keeps going
    /// past a failure so one unwritable file can't abort the batch.
    public func exportAll(to directory: URL) -> [Int64: Error] {
        var errors: [Int64: Error] = [:]
        for session in (try? db.sessionsWithTranscript()) ?? [] {
            guard let id = session.id else { continue }
            do { try exportSession(id: id, to: directory) } catch { errors[id] = error }
        }
        return errors
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter CoachingExportTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CoachingEngine/CoachingService.swift Tests/CoachingEngineTests/CoachingExportTests.swift
git commit -m "Add exportSession/exportAll to CoachingService"
```

---

### Task 3: Auto-export on finalize (coordinator wiring)

**Files:**
- Modify: `Sources/DebriefApp/RecordingCoordinator.swift` (add stored `exportDirectory` closure + init param; call it in `runFinalize`)
- Test: `Tests/DebriefAppTests/RecordingCoordinatorTests.swift` (extend using its existing fakes)

**Interfaces:**
- Consumes: `CoachingService.exportSession(id:to:)`.
- Produces: `RecordingCoordinator.init(..., exportDirectory: @escaping @Sendable () -> URL?)` — a new trailing parameter with a UserDefaults-reading default, so a folder chosen in Settings applies to the next finalize without relaunch.

- [ ] **Step 1: Add the stored property + init parameter**

In `RecordingCoordinator`, add a stored property near `deleteAudioOnSuccess` (line ~62):

```swift
    private let exportDirectory: @Sendable () -> URL?
```

Add this parameter to `init` (after `deleteAudioOnSuccess: Bool = true`, before the closing `)` at line ~81) and assign it:

```swift
                exportDirectory: @escaping @Sendable () -> URL? = {
                    guard let p = UserDefaults.standard.string(forKey: "exportDirectory"), !p.isEmpty else { return nil }
                    return URL(fileURLWithPath: p)
                }) {
```

…and in the body: `self.exportDirectory = exportDirectory`.

- [ ] **Step 2: Call export in `runFinalize`**

In `runFinalize`, immediately after the coaching line:

```swift
            phase = .finalizing(status: "Coaching…")
            try? await coaching.coach(sessionId: session.id!)  // failure leaves session retryable
```

add:

```swift
            // Export a Cowork-readable markdown copy if an export folder is configured.
            // Non-fatal, same contract as coaching above: a failed export never fails finalize.
            if let exportDir = exportDirectory() {
                try? coaching.exportSession(id: session.id!, to: exportDir)
            }
```

- [ ] **Step 3: Write the failing test** — extend `RecordingCoordinatorTests` reusing its existing fake recorders/transcriber (same file). Model it on an existing finalize test that produces speech; pass `exportDirectory: { tempDir }` to the coordinator and assert a file lands. Skeleton:

```swift
    func testFinalizeExportsMarkdownWhenDirectoryConfigured() async throws {
        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Build the coordinator the same way the existing finalize tests do, but add:
        //   exportDirectory: { exportDir }
        // Drive a recording that transcribes to at least one real speech segment, then stop.
        // (Reuse this file's existing fake transcriber that returns non-empty TimedText.)
        // ... existing arrange/act from the nearest finalize test ...
        let files = (try? FileManager.default.contentsOfDirectory(atPath: exportDir.path)) ?? []
        XCTAssertEqual(files.count, 1, "finalize should write exactly one markdown export")
    }
```

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RecordingCoordinatorTests`
Expected: the new test FAILS before Steps 1–2 are applied (no file written), PASSES after.

- [ ] **Step 4: Run the whole coordinator suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RecordingCoordinatorTests`
Expected: PASS, including pre-existing tests (default `exportDirectory` returns nil under a clean `UserDefaults`, so they don't write files).

- [ ] **Step 5: Commit**

```bash
git add Sources/DebriefApp/RecordingCoordinator.swift Tests/DebriefAppTests/RecordingCoordinatorTests.swift
git commit -m "Auto-export session markdown on finalize when export folder set"
```

---

### Task 4: Export-folder setting (Settings UI)

**Files:**
- Modify: `Sources/DebriefApp/SettingsView.swift` (add a "Cowork export" section)
- Modify: `Sources/DebriefApp/AppEnvironment.swift` (add an `exportAll` trigger method)

**Interfaces:**
- Consumes: `CoachingService.exportAll(to:)`, `@AppStorage("exportDirectory")`.
- Produces: `AppEnvironment.exportAllSessions(to: URL)` (fire-and-forget, off-main).

- [ ] **Step 1: Add the off-main trigger to `AppEnvironment`**

Add near `startRecoach()`:

```swift
    /// Exports every session with a transcript to `dir`, off the main thread (many small
    /// file writes). Fire-and-forget: the folder picker is the user-facing confirmation.
    func exportAllSessions(to dir: URL) {
        let coaching = self.coaching
        Task.detached { _ = coaching.exportAll(to: dir) }
    }
```

- [ ] **Step 2: Add the Settings section**

Add `@AppStorage("exportDirectory") private var exportDir = ""` to the property block (~line 16), then add this `Section` after the "Coaching" section (~line 137):

```swift
            Section("Cowork export") {
                Text(exportDir.isEmpty
                     ? "Off — choose a folder to write each debrief as a markdown file Claude Cowork can read."
                     : "Exporting to: \(exportDir)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Choose export folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            exportDir = url.path
                            env.exportAllSessions(to: url)  // backfill existing sessions immediately
                        }
                    }
                    if !exportDir.isEmpty {
                        Button("Turn off") { exportDir = "" }
                        Button("Export all now") {
                            env.exportAllSessions(to: URL(fileURLWithPath: exportDir))
                        }
                    }
                }
            }
```

- [ ] **Step 3: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: builds clean.

- [ ] **Step 4: Manual verification (real app — UI isn't unit-tested here)**

```bash
./scripts/make-app.sh && open Debrief.app
```
Open the main window (Window ▸ Debrief), go to Settings ▸ Cowork export, choose a temp folder, confirm existing sessions produce `.md` files in it, then run a short recording and confirm a new `.md` appears on finalize. Note the result in your task report.

- [ ] **Step 5: Commit**

```bash
git add Sources/DebriefApp/SettingsView.swift Sources/DebriefApp/AppEnvironment.swift
git commit -m "Add Cowork export folder setting"
```

---

### Task 5: `DataLocations` reconcile core

**Files:**
- Create: `Sources/DebriefApp/DataLocations.swift`
- Test: `Tests/DebriefAppTests/DataLocationsTests.swift`

**Interfaces:**
- Consumes: `RecordingStore.appSupportRoot()`, `RecordingStore.recordingsRoot()`, `PromptStore.defaultDirectory()`.
- Produces:
  - `DataLocations.Resolved` (`audio: URL`, `db: URL`, `prompts: URL`)
  - `DataLocations.resolveAndReconcile(defaults:fm:) -> Resolved`
  - `DataLocations.migrateDirectory(from:to:fm:) throws` (the safety-critical move; tested directly)
  - `DataLocations.MigrationError` (`.targetNotEmpty`)

- [ ] **Step 1: Write the failing test** (targets the pure move logic — the part that can lose data):

```swift
import XCTest
@testable import DebriefApp

final class DataLocationsTests: XCTestCase {
    private let fm = FileManager.default
    private func tmp() -> URL { fm.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testMovesPopulatedDirectory() throws {
        let from = tmp(), to = tmp()
        try write("data", to: from.appendingPathComponent("file.txt"))
        try DataLocations.migrateDirectory(from: from, to: to, fm: fm)
        XCTAssertFalse(fm.fileExists(atPath: from.path))
        XCTAssertEqual(try String(contentsOf: to.appendingPathComponent("file.txt"), encoding: .utf8), "data")
    }

    func testRefusesNonEmptyTargetAndLeavesSourceIntact() throws {
        let from = tmp(), to = tmp()
        try write("src", to: from.appendingPathComponent("file.txt"))
        try write("existing", to: to.appendingPathComponent("other.txt"))
        XCTAssertThrowsError(try DataLocations.migrateDirectory(from: from, to: to, fm: fm))
        XCTAssertEqual(try String(contentsOf: from.appendingPathComponent("file.txt"), encoding: .utf8), "src")
    }

    func testNoopWhenSourceMissing() throws {
        let from = tmp(), to = tmp()
        try DataLocations.migrateDirectory(from: from, to: to, fm: fm) // must not throw
        XCTAssertFalse(fm.fileExists(atPath: to.path))
    }

    func testNoopWhenEqual() throws {
        let dir = tmp()
        try write("x", to: dir.appendingPathComponent("file.txt"))
        try DataLocations.migrateDirectory(from: dir, to: dir, fm: fm)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("file.txt"), encoding: .utf8), "x")
    }

    func testMovesIntoEmptyExistingTarget() throws {
        let from = tmp(), to = tmp()
        try write("src", to: from.appendingPathComponent("file.txt"))
        try fm.createDirectory(at: to, withIntermediateDirectories: true) // empty dir the user pre-made
        try DataLocations.migrateDirectory(from: from, to: to, fm: fm)
        XCTAssertEqual(try String(contentsOf: to.appendingPathComponent("file.txt"), encoding: .utf8), "src")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DataLocationsTests`
Expected: FAIL — `DataLocations` undefined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import CaptureKit
import CoachingEngine
import os

private let logger = Logger(subsystem: "com.debrief.app", category: "datalocations")

/// Resolves where Debrief keeps its audio, database, and prompts — honoring user-chosen
/// folders from Settings — and moves any existing data to match, ONCE, at launch, before any
/// store opens. "Declared vs. reconciled state": Settings declares a desired directory; this
/// is the single place that mutates the filesystem to match it, and it runs while nothing
/// holds the DB open (which is why moving the DB here is safe and moving it live is not).
enum DataLocations {
    enum MigrationError: Error { case targetNotEmpty(URL) }

    struct Resolved { let audio: URL; let db: URL; let prompts: URL }

    /// (desiredKey, actualKey, errorKey, canonical subdir name, default full dir)
    private struct Kind {
        let desiredKey: String, actualKey: String, errorKey: String, defaultDir: URL
    }

    private static func kinds() -> (audio: Kind, db: Kind, prompts: Kind) {
        (audio: Kind(desiredKey: "audioDirDesired", actualKey: "audioDirActual",
                     errorKey: "audioDirError", defaultDir: RecordingStore.recordingsRoot()),
         db: Kind(desiredKey: "dbDirDesired", actualKey: "dbDirActual",
                  errorKey: "dbDirError", defaultDir: RecordingStore.appSupportRoot().appendingPathComponent("db")),
         prompts: Kind(desiredKey: "promptsDirDesired", actualKey: "promptsDirActual",
                       errorKey: "promptsDirError", defaultDir: PromptStore.defaultDirectory()))
    }

    static func resolveAndReconcile(defaults: UserDefaults = .standard, fm: FileManager = .default) -> Resolved {
        let k = kinds()
        return Resolved(audio: reconcile(k.audio, defaults: defaults, fm: fm),
                        db: reconcile(k.db, defaults: defaults, fm: fm),
                        prompts: reconcile(k.prompts, defaults: defaults, fm: fm))
    }

    /// Returns the directory to actually use this launch. On a successful move, adopts `desired`
    /// and records it as `actual`; on failure, keeps `actual`, records an error for Settings to
    /// show, and leaves `desired` set so the move is retried next launch.
    private static func reconcile(_ kind: Kind, defaults: UserDefaults, fm: FileManager) -> URL {
        let desired = defaults.string(forKey: kind.desiredKey).map(URL.init(fileURLWithPath:)) ?? kind.defaultDir
        let actual = defaults.string(forKey: kind.actualKey).map(URL.init(fileURLWithPath:)) ?? kind.defaultDir
        guard desired != actual else { defaults.removeObject(forKey: kind.errorKey); return actual }
        do {
            try migrateDirectory(from: actual, to: desired, fm: fm)
            defaults.set(desired.path, forKey: kind.actualKey)
            defaults.removeObject(forKey: kind.errorKey)
            return desired
        } catch {
            logger.error("data-location move failed \(actual.path, privacy: .public) -> \(desired.path, privacy: .public): \(error, privacy: .public)")
            defaults.set("Couldn’t move to \(desired.path): \(error.localizedDescription). Still using \(actual.path).",
                         forKey: kind.errorKey)
            return actual
        }
    }

    /// Moves directory `from` to `to`. No-op if equal or if the source doesn't exist (no data
    /// yet). Moves into an empty pre-existing target; refuses a non-empty one rather than
    /// overwrite. This is the only place that can lose data, so it is deliberately conservative.
    static func migrateDirectory(from: URL, to: URL, fm: FileManager) throws {
        if from == to { return }
        guard fm.fileExists(atPath: from.path) else { return }
        if fm.fileExists(atPath: to.path) {
            let contents = (try? fm.contentsOfDirectory(atPath: to.path)) ?? []
            if !contents.isEmpty { throw MigrationError.targetNotEmpty(to) }
            try fm.removeItem(at: to) // empty dir — clear it so moveItem can create it fresh
        }
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: from, to: to)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DataLocationsTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/DebriefApp/DataLocations.swift Tests/DebriefAppTests/DataLocationsTests.swift
git commit -m "Add DataLocations launch-time directory reconcile"
```

---

### Task 6: Thread effective paths through `AppEnvironment`

**Files:**
- Modify: `Sources/DebriefApp/AppEnvironment.swift` (`live()` + `init` + the three `unfinalizedSessions()` call sites)

**Interfaces:**
- Consumes: `DataLocations.resolveAndReconcile()`, `RecordingStore.unfinalizedSessions(root:)`.
- Produces: `AppEnvironment.init(..., recordingsRoot: URL = RecordingStore.recordingsRoot())` — new trailing param so recovery scans the configured audio dir.

- [ ] **Step 1: Add `recordingsRoot` to `AppEnvironment`**

Add a stored property: `private let recordingsRoot: URL` (near `alerts`). Add `recordingsRoot: URL = RecordingStore.recordingsRoot()` as the last `init` parameter and assign `self.recordingsRoot = recordingsRoot`. Replace the three crash-recovery scans:
- line ~141 `recoverableSessions = RecordingStore.unfinalizedSessions()` → `RecordingStore.unfinalizedSessions(root: recordingsRoot)`
- line ~150 (in `recover`) same replacement
- line ~155 (in `discard`) same replacement

- [ ] **Step 2: Reconcile + use effective dirs in `live()`**

Replace the top of `live()`’s `do` block:

```swift
            let root = RecordingStore.appSupportRoot()
            let db = try AppDatabase.onDisk(at: root.appendingPathComponent("db/debrief.sqlite"))
            let prompts = PromptStore(directory: PromptStore.defaultDirectory())
```

with:

```swift
            // MUST run before any store opens — it may move the DB directory.
            let loc = DataLocations.resolveAndReconcile()
            let db = try AppDatabase.onDisk(at: loc.db.appendingPathComponent("debrief.sqlite"))
            let prompts = PromptStore(directory: loc.prompts)
```

Pass the audio dir to the coordinator — add `recordingsRoot: loc.audio,` to the `RecordingCoordinator(...)` call (alongside the existing args, before `deleteAudioOnSuccess:`), and pass it to the environment: change the `AppEnvironment(...)` call to include `recordingsRoot: loc.audio`.

- [ ] **Step 3: Build + run existing tests**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --skip IntegrationTests
```
Expected: builds clean; the full suite passes (nothing changed for the default-path case — `resolveAndReconcile` with clean defaults returns the historical dirs).

- [ ] **Step 4: Manual verification (real move + relaunch)**

```bash
./scripts/make-app.sh && open Debrief.app
```
This task has no Settings UI yet (Task 7), so verify the effective-path plumbing by temporarily setting a desired key via `defaults`, then launching:
```bash
defaults write com.debrief.app dbDirDesired "$HOME/DebriefTest/db"
```
Launch, confirm the DB moved to `~/DebriefTest/db/debrief.sqlite` and the app opens with prior sessions intact, then reset:
```bash
defaults delete com.debrief.app dbDirDesired; defaults delete com.debrief.app dbDirActual
```
(Move the DB back or relaunch to reconcile.) Report the result.

- [ ] **Step 5: Commit**

```bash
git add Sources/DebriefApp/AppEnvironment.swift
git commit -m "Use reconciled data locations in composition root"
```

---

### Task 7: Data-locations pickers + relaunch (Settings UI)

**Files:**
- Modify: `Sources/DebriefApp/SettingsView.swift` (add a "Data locations" section + a relaunch helper)

**Interfaces:**
- Consumes: the desired/actual/error UserDefaults keys (Global Constraints), `DataLocations` canonical subdir names.

- [ ] **Step 1: Add a relaunch helper + a row builder**

Add to `SettingsView` (private methods):

```swift
    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// One relocatable directory. `subdir` is the canonical name appended to the picked parent.
    private func locationRow(_ title: String, desiredKey: String, actualKey: String,
                             errorKey: String, subdir: String, defaultPath: String) -> some View {
        let d = UserDefaults.standard
        let current = d.string(forKey: actualKey) ?? d.string(forKey: desiredKey) ?? defaultPath
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).bold()
                Spacer()
                Button("Change…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.message = "Choose a parent folder — Debrief will keep a “\(subdir)” folder inside it."
                    guard panel.runModal() == .OK, let parent = panel.url else { return }
                    let desired = parent.appendingPathComponent(subdir).path
                    guard desired != current else { return }
                    d.set(desired, forKey: desiredKey)
                    relaunchPrompt = RelaunchPrompt(dir: title)
                }
            }
            Text(current).font(.caption).foregroundStyle(.secondary)
            if let err = d.string(forKey: errorKey) {
                Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
    }
```

Add state near the other `@State`s:

```swift
    @State private var relaunchPrompt: RelaunchPrompt?
    private struct RelaunchPrompt: Identifiable { let id = UUID(); let dir: String }
```

- [ ] **Step 2: Add the section + relaunch alert**

Add this `Section` after the "Cowork export" section:

```swift
            Section("Data locations") {
                Text("Where Debrief stores its files. Changing a location moves the existing data and relaunches Debrief.")
                    .font(.caption).foregroundStyle(.secondary)
                locationRow("Recordings", desiredKey: "audioDirDesired", actualKey: "audioDirActual",
                            errorKey: "audioDirError", subdir: "recordings",
                            defaultPath: RecordingStore.recordingsRoot().path)
                locationRow("Database", desiredKey: "dbDirDesired", actualKey: "dbDirActual",
                            errorKey: "dbDirError", subdir: "db",
                            defaultPath: RecordingStore.appSupportRoot().appendingPathComponent("db").path)
                locationRow("Prompts", desiredKey: "promptsDirDesired", actualKey: "promptsDirActual",
                            errorKey: "promptsDirError", subdir: "prompts",
                            defaultPath: PromptStore.defaultDirectory().path)
            }
```

Add the alert modifier after the existing `.confirmationDialog(...)` on the `Form`:

```swift
        .alert("Relaunch to move your data?", isPresented: Binding(
            get: { relaunchPrompt != nil }, set: { if !$0 { relaunchPrompt = nil } })) {
            Button("Relaunch now") { relaunch() }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Debrief will move your \(relaunchPrompt?.dir.lowercased() ?? "data") to the new folder on the next launch.")
        }
```

Add `import CaptureKit` at the top of `SettingsView.swift` (for `RecordingStore`) if not present.

- [ ] **Step 3: Build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: builds clean.

- [ ] **Step 4: Manual verification (full flow)**

```bash
./scripts/make-app.sh && open Debrief.app
```
Settings ▸ Data locations ▸ Database ▸ Change… → pick a folder → "Relaunch now". After relaunch, confirm: the DB lives at `<picked>/db/debrief.sqlite`, prior sessions are intact, and the row shows the new path. Repeat for Recordings. Test the refuse path: pick a folder that already contains a non-empty `db` folder and confirm the error label appears and data stayed put. Report results against `docs/manual-test-checklist.md`.

- [ ] **Step 5: Commit**

```bash
git add Sources/DebriefApp/SettingsView.swift
git commit -m "Add data-locations pickers with move-and-relaunch"
```

---

## Self-review notes

- **Spec coverage:** Part A pickers → Tasks 5–7; move-at-launch + relaunch → Tasks 5/6/7; crash-recovery uses effective audio dir → Task 6 Step 1; error handling (refuse non-empty target, keep source) → Task 5; Part B renderer → Task 1; write site in `runFinalize` non-fatal → Task 3; Export folder + "export all" backfill → Task 4; "no audio in export", markdown-only, deterministic filename → Tasks 1–2. Out-of-scope items (JSON/CSV, templating, bookmarks, reset button, env-var config) are not implemented, per spec.
- **Type consistency:** `exportSession(id:to:)`/`exportAll(to:)`, `SessionMarkdown.render(_:)`/`filename(for:)`, `DataLocations.resolveAndReconcile`/`migrateDirectory(from:to:fm:)`/`Resolved(audio:db:prompts:)`, and the UserDefaults key strings are used identically across tasks.
- **Known soft spot:** Task 3's coordinator test reuses fakes from the existing `RecordingCoordinatorTests` (not reproduced here); if that file's fake transcriber doesn't emit speech, model the new test on whichever existing test drives a successful finalize.
