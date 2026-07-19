# Tracker Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pull upcoming interviews from a dedicated Google Calendar into the recording UI, and push finished debriefs to a Google Sheet, Google Drive, and Notion.

**Architecture:** The push side needs no application code — it runs over MCP against the Markdown files `RecordingCoordinator` already exports. The pull side adds one local file: Claude writes `upcoming.json` into Application Support, and the app reads it to pre-fill the recording form. The app never makes a network call to Google or Notion.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest. No new package dependencies.

## Global Constraints

- Every `swift` command MUST be prefixed `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` — the Command Line Tools instance has no XCTest and the build fails without it.
- Run the app via `./scripts/make-app.sh && open Debrief.app`, never `swift run`.
- No new package dependencies.
- The app must not gain any network call to Google or Notion. Both are reached only through Claude's MCP servers.
- Free-form typing in the Company field must keep working exactly as it does today. `upcoming.json` is a convenience cache, never required state.
- A missing, stale, or malformed `upcoming.json` degrades silently to current behavior. Loading it must never throw.
- Work happens on branch `tracker-sync`.

---

### Task 1: `upcoming.json` model and loader

**Files:**
- Create: `Sources/DebriefApp/UpcomingInterviews.swift`
- Test: `Tests/DebriefAppTests/UpcomingInterviewsTests.swift`

**Interfaces:**
- Consumes: `RecordingStore.appSupportRoot()` from `CaptureKit` (already used by `DataLocations.kinds()`).
- Produces:
  - `struct UpcomingInterview: Codable, Hashable, Sendable { let company: String; let roundType: String?; let start: Date; let notes: String? }`
  - `enum UpcomingInterviews { static func fileURL() -> URL; static func load(from url: URL, now: Date) -> [UpcomingInterview] }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/DebriefAppTests/UpcomingInterviewsTests.swift`:

```swift
import XCTest
@testable import DebriefApp

final class UpcomingInterviewsTests: XCTestCase {
    /// Writes `json` to a fresh temp file and returns its URL.
    private func tempFile(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try Data(json.utf8).write(to: url)
        return url
    }

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    func testDecodesValidFile() throws {
        let url = try tempFile("""
        [{"company":"Stripe","roundType":"system_design",
          "start":"2025-06-15T18:00:00Z","notes":"panel of 2"}]
        """)
        let items = UpcomingInterviews.load(from: url, now: now)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].company, "Stripe")
        XCTAssertEqual(items[0].roundType, "system_design")
        XCTAssertEqual(items[0].notes, "panel of 2")
    }

    func testMissingFileYieldsEmptyList() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        XCTAssertEqual(UpcomingInterviews.load(from: url, now: now), [])
    }

    func testMalformedFileYieldsEmptyList() throws {
        let url = try tempFile("{ this is not json")
        XCTAssertEqual(UpcomingInterviews.load(from: url, now: now), [])
    }

    /// A calendar event may have no description and no recognizable round in its title.
    /// The entry must survive with nils, not be dropped.
    func testOptionalFieldsMayBeAbsent() throws {
        let url = try tempFile("""
        [{"company":"Figma","start":"2025-06-15T18:00:00Z"}]
        """)
        let items = UpcomingInterviews.load(from: url, now: now)
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].roundType)
        XCTAssertNil(items[0].notes)
    }

    /// One bad entry must not discard the good ones alongside it.
    func testSkipsUndecodableEntriesButKeepsTheRest() throws {
        let url = try tempFile("""
        [{"company":"Stripe","start":"2025-06-15T18:00:00Z"},
         {"roundType":"behavioral","start":"2025-06-15T19:00:00Z"},
         {"company":"Figma","start":"2025-06-15T20:00:00Z"}]
        """)
        let items = UpcomingInterviews.load(from: url, now: now)
        XCTAssertEqual(items.map(\.company), ["Stripe", "Figma"])
    }

    func testDropsStaleEntriesAndSortsByStart() throws {
        let url = try tempFile("""
        [{"company":"Later","start":"2025-06-15T20:00:00Z"},
         {"company":"LongPast","start":"2025-06-01T09:00:00Z"},
         {"company":"Sooner","start":"2025-06-15T18:00:00Z"}]
        """)
        let items = UpcomingInterviews.load(from: url, now: now)
        XCTAssertEqual(items.map(\.company), ["Sooner", "Later"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter UpcomingInterviewsTests
```
Expected: FAIL — `cannot find 'UpcomingInterviews' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/DebriefApp/UpcomingInterviews.swift`:

```swift
import Foundation
import CaptureKit
import os

private let logger = Logger(subsystem: "com.debrief.app", category: "upcoming")

/// One scheduled interview, as written by Claude from the dedicated interview calendar.
/// `roundType` is the raw string; adopting it into the UI is gated by
/// `PromptStore.availableRoundTypes()` (see AppEnvironment.apply) because the Picker
/// binds by tag and an unknown tag blanks the selection.
struct UpcomingInterview: Codable, Hashable, Sendable {
    let company: String
    let roundType: String?
    let start: Date
    let notes: String?
}

/// Reads the calendar hand-off file. This is a *cache*, not state: every failure path
/// returns [] so the recording form falls back to plain typing. Nothing here throws.
enum UpcomingInterviews {
    static func fileURL() -> URL {
        RecordingStore.appSupportRoot().appendingPathComponent("upcoming.json")
    }

    static func load(from url: URL = fileURL(), now: Date = Date()) -> [UpcomingInterview] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Decode entry-by-entry: one malformed event on the calendar shouldn't
        // discard every other interview in the file.
        guard let raw = try? decoder.decode([FailableEntry].self, from: data) else {
            logger.error("upcoming.json is not a JSON array — ignoring")
            return []
        }
        // ponytail: a one-hour grace window, so an interview that just started is
        // still offered. Widen it if you routinely record long after the slot.
        let cutoff = now.addingTimeInterval(-3600)
        return raw.compactMap(\.value)
            .filter { $0.start >= cutoff }
            .sorted { $0.start < $1.start }
    }

    /// Decodes to nil instead of throwing, so `[FailableEntry]` tolerates bad elements.
    private struct FailableEntry: Decodable {
        let value: UpcomingInterview?
        init(from decoder: Decoder) throws {
            value = try? UpcomingInterview(from: decoder)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter UpcomingInterviewsTests
```
Expected: PASS, 6 tests.

- [ ] **Step 6: Commit**

```sh
git add Sources/DebriefApp/UpcomingInterviews.swift Tests/DebriefAppTests/UpcomingInterviewsTests.swift
git commit -m "Read upcoming interviews from a calendar hand-off file"
```

---

### Task 2: Offer calendar entries in the recording form

**Files:**
- Modify: `Sources/DebriefApp/AppEnvironment.swift:23-25` (add published list + apply method)
- Modify: `Sources/DebriefApp/MenuBarView.swift:41` (add the picker menu above the Company field)
- Modify: `docs/manual-test-checklist.md` (append a verification entry)
- Test: `Tests/DebriefAppTests/UpcomingInterviewsTests.swift` (extend)

**Interfaces:**
- Consumes: `UpcomingInterview`, `UpcomingInterviews.load(from:now:)` from Task 1.
- Produces: `AppEnvironment.upcoming: [UpcomingInterview]`, `AppEnvironment.refreshUpcoming()`, `AppEnvironment.apply(_ item: UpcomingInterview)`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/DebriefAppTests/UpcomingInterviewsTests.swift`, inside a new class at the end of the file:

```swift
@MainActor
final class ApplyUpcomingTests: XCTestCase {
    /// A round type the prompt store knows about is adopted.
    func testApplyAdoptsKnownRoundType() throws {
        let env = try makeTestEnv()
        env.apply(UpcomingInterview(company: "Stripe", roundType: "system_design",
                                    start: Date(), notes: "panel of 2"))
        XCTAssertEqual(env.recordCompany, "Stripe")
        XCTAssertEqual(env.recordRoundType, .systemDesign)
        XCTAssertEqual(env.recordNotes, "panel of 2")
    }

    /// RoundType accepts any string, so an unknown value would decode fine but leave
    /// the Picker with no matching tag. It must be ignored and the default kept.
    func testApplyIgnoresUnknownRoundType() throws {
        let env = try makeTestEnv()
        env.recordRoundType = .behavioral
        env.apply(UpcomingInterview(company: "Figma", roundType: "vibes_check",
                                    start: Date(), notes: nil))
        XCTAssertEqual(env.recordCompany, "Figma")
        XCTAssertEqual(env.recordRoundType, .behavioral)
        XCTAssertEqual(env.recordNotes, "")
    }
}
```

Add this helper to the same new class — it mirrors `AppEnvironmentTests.makeEnv`:

```swift
    private func makeTestEnv() throws -> AppEnvironment {
        let db = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let promptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prompts = PromptStore(directory: promptDir)
        try prompts.ensureDefaults()
        let coaching = CoachingService(db: db, prompts: prompts, llm: OKStubLLM())
        let coordinator = RecordingCoordinator(
            db: db, coaching: coaching,
            transcriber: FakeTranscriber(textForChunk: "final"),
            makeMicRecorder: { FakeRecorder(writer: $0, seconds: 2) },
            makeSystemRecorder: { FakeRecorder(writer: $0, seconds: 2) },
            recordingsRoot: root, chunkDuration: 1.0)
        return AppEnvironment(db: db, prompts: prompts, coaching: coaching,
                              coordinator: coordinator, alerts: nil)
    }
```

Add the imports the helper needs to the top of the file:

```swift
import Store
import CoachingEngine
import CaptureKit
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ApplyUpcomingTests
```
Expected: FAIL — `value of type 'AppEnvironment' has no member 'apply'`.

- [ ] **Step 3: Add the published list and apply method**

In `Sources/DebriefApp/AppEnvironment.swift`, immediately after line 25 (`@Published var recordNotes = ""`), add:

```swift
    /// Interviews read from the calendar hand-off file, offered as pre-fills when
    /// starting a recording. Empty is the normal case, not an error.
    @Published var upcoming: [UpcomingInterview] = []

    func refreshUpcoming() {
        upcoming = UpcomingInterviews.load()
    }

    /// Pre-fills the stop-form fields from a scheduled interview. The round type is
    /// adopted only if the prompt store has an overlay for it — RoundType accepts any
    /// string, but the Picker binds by tag, so an unknown value would blank the control.
    func apply(_ item: UpcomingInterview) {
        recordCompany = item.company
        recordNotes = item.notes ?? ""
        if let raw = item.roundType {
            let candidate = RoundType(rawValue: raw)
            if prompts.availableRoundTypes().contains(candidate) {
                recordRoundType = candidate
            }
        }
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run:
```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ApplyUpcomingTests
```
Expected: PASS, 2 tests.

- [ ] **Step 5: Add the menu to the recording form**

In `Sources/DebriefApp/MenuBarView.swift`, replace line 41:

```swift
                TextField("Company", text: $env.recordCompany)
```

with:

```swift
                if !env.upcoming.isEmpty {
                    Menu("From calendar") {
                        ForEach(env.upcoming, id: \.self) { item in
                            Button("\(item.company) — \(item.start, style: .time)") {
                                env.apply(item)
                            }
                        }
                    }
                }
                TextField("Company", text: $env.recordCompany)
```

The `TextField` is unchanged, so free-form typing keeps working by construction.

- [ ] **Step 6: Refresh the list when a recording starts**

In `Sources/DebriefApp/MenuBarView.swift`, replace the `.idle` case's record button action (line 22):

```swift
                    Task { await env.startRecording() }
```

with:

```swift
                    env.refreshUpcoming()
                    Task { await env.startRecording() }
```

- [ ] **Step 7: Build and verify the app launches**

Run:
```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
./scripts/make-app.sh && open Debrief.app
```
Expected: builds clean; the menu-bar item appears. With no `upcoming.json` present, the recording form looks exactly as it does today (no "From calendar" menu).

- [ ] **Step 8: Verify the pre-fill against a real file**

Write a fixture, then start a recording from the menu bar:

```sh
cat > ~/Library/Application\ Support/Debrief/upcoming.json <<'EOF'
[{"company":"Stripe","roundType":"system_design",
  "start":"2099-01-01T18:00:00Z","notes":"panel of 2"}]
EOF
```

Expected: "From calendar" appears; choosing "Stripe — 6:00 PM" fills Company with `Stripe`, sets Round to `System Design`, and fills Notes with `panel of 2`. Delete the file afterward.

- [ ] **Step 9: Record the manual check**

Append to `docs/manual-test-checklist.md`:

```markdown
- [ ] **Calendar pre-fill.** With an `upcoming.json` in Application Support, start a
      recording: "From calendar" lists the entries, and choosing one fills company,
      round type, and notes. With the file absent, the menu is hidden and typing a
      company by hand works as before.
```

- [ ] **Step 10: Commit**

```sh
git add Sources/DebriefApp/AppEnvironment.swift Sources/DebriefApp/MenuBarView.swift \
        Tests/DebriefAppTests/UpcomingInterviewsTests.swift docs/manual-test-checklist.md
git commit -m "Offer scheduled interviews as recording pre-fills"
```

---

### Task 3: The sync runbook

**Files:**
- Create: `docs/tracker-sync.md`

**Interfaces:**
- Consumes: `UpcomingInterviews.fileURL()` (the path the pull half writes to), and the export directory configured in Settings → Cowork export.
- Produces: nothing consumed by later tasks. This task is documentation plus one live verification.

This task has **no application code and no unit tests**. The sync runs in Claude's process over MCP; its correctness check is running it once against scratch targets and inspecting the result. A mocked test here would assert nothing real.

- [ ] **Step 1: Collect the real targets and read their live schemas**

Before writing anything, get these four values from the user or via MCP — the runbook must name them exactly, not describe them:
- the dedicated interview calendar's name (blocked: the Google Calendar token is expired and needs re-authorization)
- the target Google Sheet (URL + tab) — one exists; the user is supplying it
- the Drive folder for transcripts
- the Notion parent page or database

Then read each target's CURRENT schema and record it in the runbook as an example,
not as a hardcoded contract: the Sheet's header row, and the Notion database's
property names with their types.

- [ ] **Step 2: Write the schema-adaptive mapping rules**

The runbook must re-read the schema on EVERY run rather than storing a mapping.
Document, with the field list on one side and the synonyms accepted on the other:

- Map Debrief's fields (date, company, round type, advancement verdict, overall
  score, weakness tags, transcript link) onto whatever columns/properties exist,
  by normalized name against a synonym list.
- **Never create, rename, delete, or reorder a column or property.**
- **Never write to an unmatched column.** Report skipped fields.
- **Respect declared types** — a Notion `select` value must already be among its
  options, else report and skip.
- **Ambiguity is reported, never guessed** — two plausible matches for one field
  means write neither.

- [ ] **Step 3: Write the runbook**

Create `docs/tracker-sync.md` covering:

**Push.** For each Markdown file in the configured export directory: upload to the named Drive folder; append a row to the named Sheet tab with date, company, round type, advancement verdict, overall score, weakness tags, and the Drive link; create a Notion page under the named parent with the debrief prose, scores, action items, and process notes, with the transcript inside a collapsed toggle.

**Idempotency.** `SessionMarkdown.filename(for:)` is deterministic
(`yyyy-MM-dd-{company-slug}-{roundtype}-{id}.md`), so the session id embedded in the
filename identifies an already-synced session. Re-running overwrites the Drive file and
updates the matching Sheet row in place rather than appending a duplicate. No sync-state
file is kept.

**Pull.** Read events from the named calendar for the next 14 days. Every event on that
calendar is an interview — no title parsing. Map each to
`{company, roundType, start, notes}` and write the array to
`~/Library/Application Support/Debrief/upcoming.json` (that is
`UpcomingInterviews.fileURL()`). Company comes from the event title; `roundType` should
be emitted only when it matches a known round (`recruiter_screen`, `behavioral`,
`technical`, `system_design`, `product_sense`, `tech_deep_dive`), otherwise omitted;
notes from the event description.

**Cadence.** Both halves run on request, or under `/loop`.

- [ ] **Step 4: Dry-run the push against scratch targets**

Create a throwaway Sheet, Drive folder, and Notion page. Run the push for a single
already-exported session. Verify: the Drive file's contents match the local Markdown
byte-for-byte; the Sheet row's verdict and score match the file's `## Verdict` and
`## Scores` sections; the Notion page renders the transcript inside a toggle.

Then run the same push a second time without changing anything. Expected: still one
Drive file, still one Sheet row, still one Notion page — no duplicates.

- [ ] **Step 5: Dry-run the pull**

Run the pull against the real calendar. Verify `upcoming.json` parses, then confirm the
entries appear under "From calendar" when starting a recording.

- [ ] **Step 6: Commit**

```sh
git add docs/tracker-sync.md
git commit -m "Document the tracker sync runbook"
```

---

## Verification

Full suite, before opening a PR:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --skip IntegrationTests
```

No `CoachingIntegrationTests` run is needed: this work does not touch the JSON schema,
the LLM clients, or the scored dimensions.
