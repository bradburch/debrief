# Per-interview Grading Criteria Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user paste free-form grading criteria onto a single recording; the coaching model then grades against them, weighting them above the general rubric on conflict while still applying the base dimensions and output format.

**Architecture:** One new `session.customInstructions` column (migration `v2`), threaded from the DB through `CoachingService` into the *system* prompt as a trailing precedence-marked section. A criteria `TextEditor` + "Regenerate" button in the session detail view persists the text and re-runs coaching.

**Tech Stack:** Swift, SwiftUI, GRDB, XCTest. macOS app built with `swift build` / tested with `swift test`.

## Global Constraints

- Empty/whitespace-only criteria must reproduce today's behavior exactly: no prompt change, byte-identical assembled system prompt.
- New `InterviewSession.customInstructions` parameter is added **last** in the memberwise initializer with a default of `""`, so existing call sites and tests compile unchanged.
- Follow existing store patterns: raw-SQL writers via `dbWriter.write`, GRDB Codable records.
- Run the relevant `swift test` filter after each task; commit only when its tests pass.

---

### Task 1: Data model — `customInstructions` column, field, and writer

**Files:**
- Modify: `Sources/Store/Records.swift:37-52` (`InterviewSession`)
- Modify: `Sources/Store/AppDatabase.swift:22-63` (migrator — add `v2`)
- Modify: `Sources/Store/Queries.swift:56-60` (add writer after `updateCompanyName`)
- Test: `Tests/StoreTests/StoreTests.swift`

**Interfaces:**
- Produces: `InterviewSession.customInstructions: String` (memberwise init param, defaulted `""`, added last); `AppDatabase.updateSessionCriteria(id: Int64, _ text: String) throws`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/StoreTests/StoreTests.swift`:

```swift
func testCustomInstructionsDefaultsEmptyAndRoundTrips() throws {
    let co = try db.fetchOrCreateCompany(named: "Acme")
    let s = try db.insertSession(.init(id: nil, companyId: co.id!, roundType: .behavioral,
                                       date: Date(), durationSeconds: 60, contextNotes: "",
                                       coachingStatus: .pending))
    XCTAssertEqual(try db.sessionDetail(id: s.id!)?.session.customInstructions, "")
    try db.updateSessionCriteria(id: s.id!, "Grade harshly on system-design depth.")
    XCTAssertEqual(try db.sessionDetail(id: s.id!)?.session.customInstructions,
                   "Grade harshly on system-design depth.")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StoreTests.testCustomInstructionsDefaultsEmptyAndRoundTrips`
Expected: FAIL to compile — `customInstructions` and `updateSessionCriteria` don't exist.

- [ ] **Step 3: Add the stored property (Records.swift)**

In `InterviewSession`, add the property after `coachingStatus`:

```swift
    public var coachingStatus: CoachingStatus
    public var customInstructions: String
    public init(id: Int64?, companyId: Int64, roundType: RoundType, date: Date,
                durationSeconds: Int, contextNotes: String, coachingStatus: CoachingStatus,
                customInstructions: String = "") {
        self.id = id; self.companyId = companyId; self.roundType = roundType; self.date = date
        self.durationSeconds = durationSeconds; self.contextNotes = contextNotes; self.coachingStatus = coachingStatus
        self.customInstructions = customInstructions
    }
```

- [ ] **Step 4: Add migration `v2` (AppDatabase.swift)**

Immediately before `return m` in the `migrator` computed property:

```swift
        m.registerMigration("v2") { db in
            try db.alter(table: "session") { t in
                t.add(column: "customInstructions", .text).notNull().defaults(to: "")
            }
        }
```

- [ ] **Step 5: Add the writer (Queries.swift)**

After `updateCompanyName(id:name:)`:

```swift
    public func updateSessionCriteria(id: Int64, _ text: String) throws {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE session SET customInstructions = ? WHERE id = ?", arguments: [text, id])
        }
    }
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter StoreTests.testCustomInstructionsDefaultsEmptyAndRoundTrips`
Expected: PASS

- [ ] **Step 7: Run the full Store suite (guards migration + `s.*` decode)**

Run: `swift test --filter StoreTests`
Expected: PASS — all existing tests still green (they construct `InterviewSession` without the new arg, relying on its default).

- [ ] **Step 8: Commit**

```bash
git add Sources/Store/Records.swift Sources/Store/AppDatabase.swift Sources/Store/Queries.swift Tests/StoreTests/StoreTests.swift
git commit -m "feat: add session.customInstructions column, field, and writer"
```

---

### Task 2: Prompt assembly — append criteria section and forward it through coaching

**Files:**
- Modify: `Sources/CoachingEngine/PromptStore.swift:32-44` (`assembleSystemPrompt`)
- Modify: `Sources/CoachingEngine/CoachingService.swift:20-21` (pass the field)
- Test: `Tests/CoachingEngineTests/PromptStoreTests.swift`, `Tests/CoachingEngineTests/CoachingServiceTests.swift`

**Interfaces:**
- Consumes: `InterviewSession.customInstructions`, `AppDatabase.updateSessionCriteria` (Task 1).
- Produces: `assembleSystemPrompt(roundType:historyTags:customInstructions:)` with `customInstructions: String = ""` defaulted last; when non-empty (trimmed) the prompt ends with a `## Criteria for THIS interview` section.

- [ ] **Step 1: Write the failing tests (PromptStoreTests.swift)**

```swift
func testAssembleAppendsCustomInstructionsWithPrecedence() throws {
    try store.ensureDefaults()
    let prompt = try store.assembleSystemPrompt(
        roundType: .behavioral, historyTags: [],
        customInstructions: "Focus on staff-level scope.")
    XCTAssertTrue(prompt.contains("Focus on staff-level scope."))
    XCTAssertTrue(prompt.contains("Criteria for THIS interview"))
    XCTAssertTrue(prompt.contains("Where they conflict"))
    XCTAssertLessThan(prompt.range(of: "weakness_tags")!.lowerBound,
                      prompt.range(of: "Criteria for THIS interview")!.lowerBound,
                      "criteria section comes after the base rubric")
}

func testAssembleOmitsCriteriaSectionWhenEmptyOrWhitespace() throws {
    try store.ensureDefaults()
    let prompt = try store.assembleSystemPrompt(
        roundType: .behavioral, historyTags: [], customInstructions: "   \n  ")
    XCTAssertFalse(prompt.contains("Criteria for THIS interview"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PromptStoreTests`
Expected: FAIL to compile — `assembleSystemPrompt` has no `customInstructions` parameter.

- [ ] **Step 3: Implement the section (PromptStore.swift)**

Replace the signature and `return` of `assembleSystemPrompt`:

```swift
    public func assembleSystemPrompt(roundType: RoundType,
                                     historyTags: [(tag: String, count: Int)],
                                     customInstructions: String = "") throws -> String {
        let base = try String(contentsOf: directory.appendingPathComponent("base.md"), encoding: .utf8)
        let overlay = try String(contentsOf: directory.appendingPathComponent("\(roundType.rawValue).md"), encoding: .utf8)
        let history: String
        if historyTags.isEmpty {
            history = "## Prior session history\n\nNo prior session history."
        } else {
            let lines = historyTags.map { "- \($0.tag) (x\($0.count))" }.joined(separator: "\n")
            history = "## Prior session history\n\nRecurring weakness tags from this candidate's recent interviews:\n\(lines)"
        }
        var sections = [base, overlay, history]
        let trimmed = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            sections.append("""
            ## Criteria for THIS interview

            These instructions were provided specifically for this interview. Where they conflict \
            with the general rubric above, follow these. Otherwise the base dimensions, weakness-tag \
            vocabulary, and output format above still fully apply.

            \(trimmed)
            """)
        }
        return sections.joined(separator: "\n\n")
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PromptStoreTests`
Expected: PASS — including the two pre-existing tests (they omit `customInstructions`, so the default `""` keeps their prompts unchanged).

- [ ] **Step 5: Write the failing wiring test (CoachingServiceTests.swift)**

Add a stub near the top-level `StubLLM` (file scope), then the test inside `CoachingServiceTests`:

```swift
struct RequireMarkerLLM: CoachingLLM {
    let marker: String
    func generateCoaching(systemPrompt: String, userMessage: String) async throws -> CoachingResult {
        guard systemPrompt.contains(marker) else { throw ClaudeError.emptyResponse }
        return CoachingResult(proseDebrief: "ok",
                              scores: ["answer_relevance": 3, "structure": 3, "conciseness": 3, "questions_asked": 3],
                              weaknessTags: [], highlights: [], actionItems: [])
    }
}
```

```swift
func testCoachForwardsCustomInstructionsIntoSystemPrompt() async throws {
    let id = try seedSession()
    try db.updateSessionCriteria(id: id, "GRADE_MARKER_XYZ")
    let service = CoachingService(db: db, prompts: prompts, llm: RequireMarkerLLM(marker: "GRADE_MARKER_XYZ"))
    try await service.coach(sessionId: id)  // throws emptyResponse if the marker never reached the system prompt
    XCTAssertEqual(try db.sessionDetail(id: id)?.session.coachingStatus, .complete)
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `swift test --filter CoachingServiceTests.testCoachForwardsCustomInstructionsIntoSystemPrompt`
Expected: FAIL — `coach` still calls `assembleSystemPrompt` without `customInstructions`, so the marker is absent and `RequireMarkerLLM` throws.

- [ ] **Step 7: Forward the field (CoachingService.swift)**

Replace the `assembleSystemPrompt` call in `coach`:

```swift
            let system = try prompts.assembleSystemPrompt(roundType: detail.session.roundType,
                                                          historyTags: history,
                                                          customInstructions: detail.session.customInstructions)
```

- [ ] **Step 8: Run the full coaching suite**

Run: `swift test --filter CoachingEngineTests`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add Sources/CoachingEngine/PromptStore.swift Sources/CoachingEngine/CoachingService.swift Tests/CoachingEngineTests/PromptStoreTests.swift Tests/CoachingEngineTests/CoachingServiceTests.swift
git commit -m "feat: append per-interview criteria to system prompt and forward through coaching"
```

---

### Task 3: UI — criteria editor and regenerate action in the session detail

**Files:**
- Modify: `Sources/DebriefApp/SessionsView.swift:55-167` (`SessionDetailView`)
- Modify: `docs/manual-test-checklist.md` (add one verification line)

**Interfaces:**
- Consumes: `InterviewSession.customInstructions`, `AppDatabase.updateSessionCriteria` (Task 1); `CoachingService.coach` (existing).
- Produces: no new public API — a `@State` criteria editor, persisted on disappear and immediately before regenerate.

Note: `RecordingCoordinator.insertSession(...)` needs **no** change — it omits `customInstructions`, which defaults to `""` (Task 1).

- [ ] **Step 1: Add criteria state and seed it on appear**

In `SessionDetailView`, add alongside the other `@State`:

```swift
    @State private var criteria = ""
```

In the `.onAppear` closure, after `companyName = detail?.company.name ?? ""`:

```swift
            criteria = detail?.session.customInstructions ?? ""
```

- [ ] **Step 2: Persist criteria on disappear**

Add a `commitCriteria` helper next to `commitRename`:

```swift
    private func commitCriteria() {
        try? env.db.updateSessionCriteria(id: sessionId, criteria)
    }
```

Change `.onDisappear` so it saves both (only when the detail loaded):

```swift
        .onDisappear { if let detail { commitRename(detail); commitCriteria() } }
```

- [ ] **Step 3: Add the criteria GroupBox + regenerate action, always visible**

In `debriefPane`, insert this block right after the title/`renameError` HStack and **before** `if let f = d.feedback {`:

```swift
                GroupBox("Grading criteria for this interview") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextEditor(text: $criteria)
                            .frame(minHeight: 60, maxHeight: 140)
                            .font(.callout)
                        HStack {
                            Text("Paste a rubric or focus for this interview. Applied when you (re)generate the debrief.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(regenerating ? "Regenerating…" : (d.feedback == nil ? "Generate debrief" : "Regenerate")) {
                                regenerating = true
                                Task {
                                    try? env.db.updateSessionCriteria(id: sessionId, criteria)
                                    try? await env.coaching.coach(sessionId: sessionId)
                                    detail = try? env.db.sessionDetail(id: sessionId)
                                    regenerating = false
                                }
                            }.disabled(regenerating)
                        }
                    }
                }
```

- [ ] **Step 4: Remove the now-duplicate regenerate button from the no-feedback branch**

In the `else` branch of `if let f = d.feedback`, delete the `Button(regenerating ? …)` (the new GroupBox button covers this case). Keep the status line:

```swift
                } else {
                    Text("No debrief yet (\(d.session.coachingStatus.rawValue)).")
                }
```

- [ ] **Step 5: Build and confirm it compiles**

Run: `swift build`
Expected: Build succeeds with no errors.

- [ ] **Step 6: Run the whole test suite (nothing regressed)**

Run: `swift test`
Expected: PASS

- [ ] **Step 7: Add a manual-test line**

Append to `docs/manual-test-checklist.md`:

```markdown
- [ ] Open a session, paste text into "Grading criteria for this interview", click Regenerate; the new debrief reflects the criteria. Reopen the session — the criteria text is still there.
```

- [ ] **Step 8: Commit**

```bash
git add Sources/DebriefApp/SessionsView.swift docs/manual-test-checklist.md
git commit -m "feat: paste-in grading criteria with regenerate in session detail"
```

---

## Self-Review

**Spec coverage:**
- Data model column + field + default `""` → Task 1. ✅
- `updateSessionCriteria` writer → Task 1. ✅
- `assembleSystemPrompt` new param + precedence section + empty-omit → Task 2 (steps 1–4). ✅
- `CoachingService.coach` threads the field → Task 2 (steps 5–7). ✅
- Detail-view editor, seed on appear, persist on disappear + before regenerate → Task 3. ✅
- Regenerate reachable after a debrief already exists (the app's main path, since auto-debrief runs before criteria) → Task 3 step 3 (button shown regardless of `feedback`). ✅
- Test coverage for present/absent criteria → Task 2 steps 1, 5. ✅
- `RecordingCoordinator` call site → handled by the defaulted init param (Task 1); Task 3 notes it needs no edit. ✅

**Placeholder scan:** none — every code step shows the exact code.

**Type consistency:** `customInstructions: String` and `updateSessionCriteria(id:_:)` are used identically in Tasks 1, 2, 3. `assembleSystemPrompt(roundType:historyTags:customInstructions:)` matches its call in `CoachingService`. `criteria` is the single `@State` name throughout Task 3.
