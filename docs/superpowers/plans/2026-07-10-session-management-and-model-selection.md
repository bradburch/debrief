# Session management, model selection & UX polish — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user delete sessions (multi-select + bulk), choose the Claude model that generates debriefs, and hit fewer UX rough edges (empty state, filter, in-window recording status, clearer states).

**Architecture:** Small, additive changes. The Store layer needs nothing — `deleteSession(id:)` exists and cascades (already tested). The coaching model becomes a parameter on `AnthropicClient`, sourced from one `UserDefaults` value and surfaced only in Settings. The rest is SwiftUI edits in three view files.

**Tech Stack:** Swift 5.10, SwiftUI (macOS 14), GRDB, XCTest. Native macOS 14 APIs (`ContentUnavailableView`, `List(selection: Set)`, `.confirmationDialog`).

## Global Constraints

- **Platform:** macOS 14+. Native macOS-14 APIs are allowed and preferred.
- **Build toolchain:** every `swift` command runs under full Xcode. Prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (or `sudo xcode-select -s` once). Referred to below as `$SWIFT` = `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift`.
- **Model ids (verbatim):** Opus 4.8 = `claude-opus-4-8` · Sonnet 5 = `claude-sonnet-5` · Haiku 4.5 = `claude-haiku-4-5-20251001`. Default = `claude-opus-4-8`.
- **UserDefaults key (verbatim):** `coachingModel`.
- **No new dependencies.**
- **onChange form:** use the zero-argument closure form `.onChange(of: x) { ... }` to match existing code (`SessionsView.swift`).
- SwiftUI views are not unit-tested in this project; their tasks build + verify against `docs/manual-test-checklist.md`. Only the client (Task 1) is TDD.

## File map

- `Sources/CoachingEngine/ClaudeClient.swift` — add `model` param (Task 1)
- `Tests/CoachingEngineTests/ClaudeClientTests.swift` — model-override test (Task 1)
- `Sources/DebriefApp/AppEnvironment.swift` — `resolveModel()`, pass model (Task 2)
- `Sources/DebriefApp/SettingsView.swift` — model `Picker` (Task 2)
- `Sources/DebriefApp/SessionsView.swift` — multi-select + delete (Task 3); empty state, filter, failed hint, rename affordance (Task 4)
- `Sources/DebriefApp/MainWindow.swift` — recording status bar (Task 5)

**Recommended subagent model per task:** Task 1 → Sonnet · Task 2 → Sonnet · Task 3 → Sonnet · Task 4 → Sonnet · Task 5 → Opus (most UI logic + coordinator flow).

---

## Task 1: `model` parameter on `AnthropicClient`

**Files:**
- Modify: `Sources/CoachingEngine/ClaudeClient.swift:14-72`
- Test: `Tests/CoachingEngineTests/ClaudeClientTests.swift`

**Interfaces:**
- Produces: `AnthropicClient.init(apiKey: String, model: String = "claude-opus-4-8", session: URLSession = .shared)`. The default keeps every existing caller and the existing `testParsesStructuredResponse` (which asserts `body["model"] == "claude-opus-4-8"`) passing unchanged.

- [ ] **Step 1: Write the failing test**

Add to `Tests/CoachingEngineTests/ClaudeClientTests.swift`, inside `final class ClaudeClientTests`:

```swift
    func testRequestBodyUsesConfiguredModel() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = AnthropicClient(apiKey: "test-key", model: "claude-sonnet-5",
                                     session: URLSession(configuration: config))
        MockURLProtocol.handler = { request in
            let body = try! JSONSerialization.jsonObject(with: request.bodyData()) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "claude-sonnet-5")
            return (200, self.envelope(text: Self.goodPayload))
        }
        _ = try await client.generateCoaching(systemPrompt: "s", userMessage: "u")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$SWIFT test --filter ClaudeClientTests/testRequestBodyUsesConfiguredModel`
Expected: FAIL — compile error, `AnthropicClient` has no `model:` parameter.

- [ ] **Step 3: Write minimal implementation**

In `Sources/CoachingEngine/ClaudeClient.swift`, add a stored property and init parameter, and use it in the body.

Replace the stored props + init (lines 15-21):

```swift
    let apiKey: String
    let model: String
    let session: URLSession

    public init(apiKey: String, model: String = "claude-opus-4-8", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }
```

Replace the hardcoded model line in the `body` dictionary (currently `"model": "claude-opus-4-8",`, line 65):

```swift
            "model": model,
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `$SWIFT test --filter ClaudeClientTests`
Expected: PASS — both the new `testRequestBodyUsesConfiguredModel` and the existing `testParsesStructuredResponse` (default still `claude-opus-4-8`).

- [ ] **Step 5: Commit**

```bash
git add Sources/CoachingEngine/ClaudeClient.swift Tests/CoachingEngineTests/ClaudeClientTests.swift
git commit -m "Add configurable model to AnthropicClient"
```

---

## Task 2: Model selection wiring + Settings picker

**Files:**
- Modify: `Sources/DebriefApp/AppEnvironment.swift:51-59` and `:61-80`
- Modify: `Sources/DebriefApp/SettingsView.swift:16-47`

**Interfaces:**
- Consumes: `AnthropicClient.init(apiKey:model:session:)` from Task 1.
- Produces: `AppEnvironment.resolveModel() -> String` (static). `AppEnvironment.rebuildCoaching()` and `.live()` build the client with `model: resolveModel()`.

- [ ] **Step 1: Add `resolveModel()` and use it in both client builds**

In `Sources/DebriefApp/AppEnvironment.swift`, add a static helper next to `resolveAPIKey` (after line 54):

```swift
    static func resolveModel() -> String {
        UserDefaults.standard.string(forKey: "coachingModel") ?? "claude-opus-4-8"
    }
```

In `rebuildCoaching()` (line 57), pass the model:

```swift
        coaching = CoachingService(db: db, prompts: prompts,
                                   llm: AnthropicClient(apiKey: Self.resolveAPIKey(), model: Self.resolveModel()))
```

In `live()` (line 68), pass the model:

```swift
            let coaching = CoachingService(db: db, prompts: prompts,
                                           llm: AnthropicClient(apiKey: apiKey, model: resolveModel()))
```

- [ ] **Step 2: Add the model picker to Settings**

In `Sources/DebriefApp/SettingsView.swift`, add an `@AppStorage` property below the existing `@AppStorage` (after line 9):

```swift
    @AppStorage("coachingModel") private var model = "claude-opus-4-8"

    private let modelOptions: [(label: String, id: String)] = [
        ("Opus 4.8 — best quality (default)", "claude-opus-4-8"),
        ("Sonnet 5 — balanced", "claude-sonnet-5"),
        ("Haiku 4.5 — fastest, cheapest", "claude-haiku-4-5-20251001"),
    ]
```

Inside the `Section("Claude API")` block, after the API-key `HStack` closes (after line 46, before the Section's closing brace), add:

```swift
                Picker("Model", selection: $model) {
                    ForEach(modelOptions, id: \.id) { Text($0.label).tag($0.id) }
                }
                .onChange(of: model) { env.rebuildCoaching() }
                Text("Which Claude model generates debriefs. Applies to the next (re)generate.")
                    .font(.caption).foregroundStyle(.secondary)
```

- [ ] **Step 3: Build**

Run: `$SWIFT build`
Expected: builds with no errors.

- [ ] **Step 4: Manual verify**

Launch (`./scripts/make-app.sh && open Debrief.app`), open Settings → Claude API. Confirm the Model picker shows three options, defaults to Opus, and persists across relaunch. (Full generation verification happens in the manual checklist.)

- [ ] **Step 5: Commit**

```bash
git add Sources/DebriefApp/AppEnvironment.swift Sources/DebriefApp/SettingsView.swift
git commit -m "Select coaching model in Settings"
```

---

## Task 3: Sessions list — multi-select + bulk delete

**Files:**
- Modify: `Sources/DebriefApp/SessionsView.swift:5-53`

**Interfaces:**
- Consumes: `AppDatabase.deleteSession(id: Int64) throws` (existing), `env.db.allSessionSummaries()` (existing).
- Produces: `SessionsView` selection is `@State private var selection: Set<Int64>`. Detail pane renders only when `selection.count == 1`.

- [ ] **Step 1: Convert selection to a Set and add delete state**

In `Sources/DebriefApp/SessionsView.swift`, replace the `selectedId` state (line 8) with:

```swift
    @State private var selection: Set<Int64> = []
    @State private var confirmingDelete = false
```

- [ ] **Step 2: Bind the List to the Set, add per-row context menu, and route the detail/placeholder off the selection count**

Replace the `List(selection:)` … through the `else { Text("Select a session") … }` block (lines 12-37) with:

```swift
            List(selection: $selection) {
                ForEach(rows, id: \.session.id) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(row.companyName).bold()
                            Spacer()
                            if let score = row.overallScore {
                                Text(String(format: "%.1f", score)).monospacedDigit()
                                    .foregroundStyle(Color.forScore(score))
                            } else {
                                statusBadge(row.session.coachingStatus)
                            }
                        }
                        Text("\(row.session.roundType.displayName) · \(row.session.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(row.session.id!)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            // If the right-clicked row isn't in the current multi-selection,
                            // act on just that row (standard Finder behavior).
                            if !selection.contains(row.session.id!) { selection = [row.session.id!] }
                            confirmingDelete = true
                        }
                    }
                }
            }
            .frame(minWidth: 260, maxWidth: 340)
            .onDeleteCommand { if !selection.isEmpty { confirmingDelete = true } }
            .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive, action: deleteSelected)
                Button("Cancel", role: .cancel) {}
            }

            if selection.count == 1, let id = selection.first {
                SessionDetailView(sessionId: id, onRenamed: reload).id(id)
            } else {
                Text(selection.isEmpty ? "Select a session" : "\(selection.count) sessions selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
```

- [ ] **Step 3: Add the delete title + delete action**

After `reload()` (line 43), add:

```swift
    private var deleteTitle: String {
        selection.count == 1 ? "Delete this session? This can’t be undone."
                             : "Delete \(selection.count) sessions? This can’t be undone."
    }

    private func deleteSelected() {
        for id in selection { try? env.db.deleteSession(id: id) }
        selection = []
        reload()
    }
```

- [ ] **Step 4: Build**

Run: `$SWIFT build`
Expected: builds with no errors.

- [ ] **Step 5: Manual verify**

Launch the app, open Sessions. Confirm: cmd/shift-click selects multiple rows; the detail pane shows for a single selection and a "N sessions selected" placeholder otherwise; right-click → Delete and the ⌫ key both raise a confirmation whose text matches the count; confirming removes the rows and clears the selection; Cancel leaves them.

- [ ] **Step 6: Commit**

```bash
git add Sources/DebriefApp/SessionsView.swift
git commit -m "Multi-select and bulk-delete sessions"
```

---

## Task 4: Sessions list — empty state, filter, failed hint, rename affordance

**Files:**
- Modify: `Sources/DebriefApp/SessionsView.swift`

**Interfaces:**
- Consumes: the `selection`/`rows` state from Task 3.
- Produces: `filterText` state and a `filteredRows` computed list; `ForEach` iterates `filteredRows`.

- [ ] **Step 1: Add filter state and a computed filtered list**

In `SessionsView`, add below the `confirmingDelete` state:

```swift
    @State private var filterText = ""

    private var filteredRows: [(session: InterviewSession, companyName: String, overallScore: Double?)] {
        let q = filterText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return rows }
        return rows.filter { $0.companyName.localizedCaseInsensitiveContains(q) }
    }
```

- [ ] **Step 2: Show an empty state, add the filter field, iterate `filteredRows`**

Wrap the left column so an empty store shows guidance and otherwise a filter field sits above the list. Replace the opening of the `List` column — i.e. change `ForEach(rows, …)` to `ForEach(filteredRows, …)` — and wrap the `List(...)`…`.confirmationDialog(...)` in a `VStack` with a filter field and empty-state branch. The left-column content becomes:

```swift
            VStack(spacing: 0) {
                if rows.isEmpty {
                    ContentUnavailableView(
                        "No sessions yet",
                        systemImage: "waveform",
                        description: Text("Click Record in the menu bar when a call starts."))
                } else {
                    TextField("Filter by company", text: $filterText)
                        .textFieldStyle(.roundedBorder)
                        .padding(8)
                    List(selection: $selection) {
                        ForEach(filteredRows, id: \.session.id) { row in
                            // ... row body unchanged from Task 3 (VStack + .tag + .contextMenu) ...
                        }
                    }
                    .onDeleteCommand { if !selection.isEmpty { confirmingDelete = true } }
                    .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
                        Button("Delete", role: .destructive, action: deleteSelected)
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
            .frame(minWidth: 260, maxWidth: 340)
```

> Note for implementer: keep the exact row `VStack`/`.tag`/`.contextMenu` body produced in Task 3; only the surrounding container, the `ForEach` source (`filteredRows`), and the `.frame` placement change here. The `.frame(minWidth:maxWidth:)` moves from the `List` to the wrapping `VStack`.

- [ ] **Step 3: Add the failed-session hint and a bordered rename field in `SessionDetailView`**

In `SessionDetailView.debriefPane(_:)`, change the title `TextField` style from `.plain` to `.roundedBorder` (line ~124):

```swift
                    TextField("Title", text: $companyName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRename(d) }
```

Then, inside the `GroupBox("Grading criteria for this interview")`'s inner `VStack`, immediately above the `HStack` that holds the hint text + regenerate `Button` (line ~142), add the failed hint:

```swift
                        if d.session.coachingStatus == .failed && d.feedback == nil {
                            Label("Last debrief failed — press Generate to retry.", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
```

- [ ] **Step 4: Build**

Run: `$SWIFT build`
Expected: builds with no errors.

- [ ] **Step 5: Manual verify**

With zero sessions, confirm the "No sessions yet" `ContentUnavailableView` shows. With sessions, confirm: the filter field narrows the list by company name (case-insensitive) and clearing it restores all rows; the detail title field reads as an editable bordered field and still renames on submit/close; a session whose `coachingStatus` is `failed` shows the orange retry hint above the Generate button.

- [ ] **Step 6: Commit**

```bash
git add Sources/DebriefApp/SessionsView.swift
git commit -m "Sessions UX: empty state, filter, failed hint, rename affordance"
```

---

## Task 5: Main window recording status bar

**Files:**
- Modify: `Sources/DebriefApp/MainWindow.swift`

**Interfaces:**
- Consumes: `env.coordinator.phase` (`RecordingPhase`), `env.coordinator.micLevel`/`systemLevel`/`streamWarning`, `env.callDetected`, `env.coordinator.startRecording()`, `env.coordinator.stopAndFinalize(metadata: SessionMetadata)`, `SessionMetadata(company:roundType:notes:)`, `RoundType.allCases`/`.displayName`, and the existing `LevelRow` view (defined in `MenuBarView.swift`, same module — reuse it, do not redefine).
- Produces: a `RecordingBar` view rendered above the tab content in `MainWindow`.

- [ ] **Step 1: Add the `RecordingBar` view**

Append to `Sources/DebriefApp/MainWindow.swift` (new view in the same file; imports `SwiftUI`, `Store`):

```swift
struct RecordingBar: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var company = ""
    @State private var roundType: RoundType = .behavioral
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch env.coordinator.phase {
            case .idle:
                HStack {
                    if env.callDetected {
                        Label("Call detected", systemImage: "phone.fill").foregroundStyle(.orange)
                    } else {
                        Text("No recording in progress").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await env.coordinator.startRecording() }
                    } label: {
                        Label(env.callDetected ? "Record this call" : "Start recording", systemImage: "record.circle")
                    }
                }
            case .recording(let started):
                HStack {
                    Label("Recording \(started, style: .timer)", systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                    Spacer()
                }
                LevelRow(label: "You", level: env.coordinator.micLevel)
                LevelRow(label: "Them", level: env.coordinator.systemLevel)
                if let warning = env.coordinator.streamWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow).font(.caption)
                }
                // ponytail: the Company/Round/Notes stop-form is reproduced from MenuBarView
                // rather than shared via a @Binding-plumbed subview — ~12 lines read clearer
                // than the abstraction. Upgrade path: extract a RecordingControls view if a
                // third caller appears.
                HStack {
                    TextField("Company", text: $company).frame(maxWidth: 200)
                    Picker("Round", selection: $roundType) {
                        ForEach(RoundType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.frame(maxWidth: 220)
                    TextField("Notes (optional)", text: $notes)
                    Button("Stop & Debrief") {
                        Task {
                            let name = company.isEmpty ? "Unknown" : company
                            _ = await env.coordinator.stopAndFinalize(
                                metadata: .init(company: name, roundType: roundType, notes: notes))
                            company = ""; notes = ""
                        }
                    }
                }
            case .finalizing(let status):
                HStack { ProgressView().controlSize(.small); Text(status) }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.caption).lineLimit(3)
            }
        }
        .padding(10)
        .background(.bar)
    }
}
```

- [ ] **Step 2: Render `RecordingBar` above the tab content**

In `MainWindow.body`, wrap the `detail:` switch so the bar sits on top. Replace the `detail: { switch … }` closure (lines 31-38) with:

```swift
        } detail: {
            VStack(spacing: 0) {
                RecordingBar()
                Divider()
                switch tab ?? .sessions {
                case .sessions: SessionsView()
                case .pipeline: PipelineView()
                case .trends: TrendsView()
                case .settings: SettingsView()
                }
            }
        }
```

- [ ] **Step 3: Build**

Run: `$SWIFT build`
Expected: builds with no errors.

- [ ] **Step 4: Manual verify (against `docs/manual-test-checklist.md`)**

Launch the app. Idle: the bar shows "No recording in progress" (or "Call detected" when a meeting app + mic are active) and a Start button. Start from the bar → it switches to the red timer + You/Them level bars + the Company/Round/Notes fields. Fill them, Stop & Debrief → the bar shows finalizing status, then returns to idle and the new session appears in the list. Confirm the menu-bar popover still works independently (starting/stopping from either surface drives the same coordinator).

- [ ] **Step 5: Commit**

```bash
git add Sources/DebriefApp/MainWindow.swift
git commit -m "Show recording status and controls in the main window"
```

---

## Final verification

- [ ] Run the full unit suite: `$SWIFT test --skip IntegrationTests`
Expected: all pass (existing suite + the new `testRequestBodyUsesConfiguredModel`).
- [ ] Walk the live-recording items of `docs/manual-test-checklist.md` once, exercising both the menu-bar popover and the new in-window recording bar.

## Self-review notes (coverage against spec)

- Delete (multi-select + bulk) → Task 3. Store layer + cascade test already exist (`StoreTests.swift:83`), so no Store task.
- Model selection (client param, Settings-only picker, wiring) → Tasks 1–2.
- Empty state, failed hint, filter, rename affordance → Task 4.
- Recording visibility → Task 5.
- Non-goals (per-session model, on-disk cleanup, shared recording subview) → not implemented, by design.
