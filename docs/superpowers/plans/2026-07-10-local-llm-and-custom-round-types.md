# Local LLM Support & Custom Round Types Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users run debrief coaching against any OpenAI-compatible LLM (Ollama, LM Studio, DeepSeek cloud) and add custom interview round types by dropping `.md` files in the prompts folder.

**Architecture:** A second `CoachingLLM` implementation (`OpenAICompatibleClient`) with schema-in-prompt + tolerant JSON extraction instead of structured outputs. `RoundType` changes from a 4-case enum to a string-backed struct so the prompts directory becomes the source of truth for round types, discovered via `PromptStore.availableRoundTypes()`.

**Tech Stack:** Swift 5.10 SPM package, XCTest, GRDB (unchanged), URLSession + MockURLProtocol for HTTP tests.

**Spec:** `docs/superpowers/specs/2026-07-10-local-llm-and-custom-round-types-design.md`

## Global Constraints

- Branch: create `feat/local-llm-custom-rounds` off `feat/session-mgmt-model-selection` (NOT `main` — this feature extends the Settings model picker which only exists on that branch).
- DB compatibility: `RoundType` must keep encoding as a bare string (e.g. `"behavioral"`), never `{"rawValue": "behavioral"}` — existing rows depend on it.
- No new package dependencies.
- Run tests with: `swift test 2>&1 | tail -20` (full suite; CoreML/WhisperKit warnings are noise).
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- UserDefaults keys: `coachingProvider` (`"anthropic"` | `"openai_compat"`), `openAICompatBaseURL`, `openAICompatModel`. Keychain key for the compat API key: `"openai-compat-api-key"`.

---

### Task 0: Branch

- [ ] **Step 1: Create the feature branch**

```bash
cd /Users/bradburch/dev/debrief
git checkout feat/session-mgmt-model-selection
git checkout -b feat/local-llm-custom-rounds
```

---

### Task 1: RoundType becomes a string-backed struct

**Files:**
- Modify: `Sources/Store/Records.swift:6-20` (replace the enum)
- Modify: `Sources/Store/Queries.swift:155,176` (init is no longer failable)
- Test: `Tests/StoreTests/RoundTypeTests.swift` (new file)

**Interfaces:**
- Produces: `RoundType(rawValue: String)` non-failable init; `RoundType.builtins: [RoundType]` (ordered `[.recruiterScreen, .behavioral, .technical, .systemDesign]`); `displayName: String` derived from rawValue for all values. Static constants `.recruiterScreen/.behavioral/.technical/.systemDesign` keep their exact current rawValues.
- Consumes: nothing.

- [ ] **Step 1: Write the failing test**

Create `Tests/StoreTests/RoundTypeTests.swift`:

```swift
import XCTest
@testable import Store

final class RoundTypeTests: XCTestCase {
    func testDisplayNameDerivedFromRawValue() {
        XCTAssertEqual(RoundType.recruiterScreen.displayName, "Recruiter Screen")
        XCTAssertEqual(RoundType.behavioral.displayName, "Behavioral")
        XCTAssertEqual(RoundType.systemDesign.displayName, "System Design")
        XCTAssertEqual(RoundType(rawValue: "take_home_review").displayName, "Take Home Review")
    }

    /// Existing DB rows store the bare raw string; the struct must encode identically
    /// to the old enum or every stored session breaks.
    func testEncodesAsBareString() throws {
        let data = try JSONEncoder().encode([RoundType.behavioral])
        XCTAssertEqual(String(data: data, encoding: .utf8), "[\"behavioral\"]")
        let decoded = try JSONDecoder().decode([RoundType].self, from: Data("[\"pair_programming\"]".utf8))
        XCTAssertEqual(decoded, [RoundType(rawValue: "pair_programming")])
    }

    func testBuiltinsOrder() {
        XCTAssertEqual(RoundType.builtins,
                       [.recruiterScreen, .behavioral, .technical, .systemDesign])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RoundTypeTests 2>&1 | tail -5`
Expected: compile error — `RoundType` has no member `builtins`, and `RoundType(rawValue:)` returns an optional (it's still an enum).

- [ ] **Step 3: Replace the enum in `Sources/Store/Records.swift`**

Replace lines 6-20 (the whole `RoundType` enum) with:

```swift
/// String-backed (not an enum) so users can add round types by dropping a
/// prompt overlay file — see PromptStore.availableRoundTypes().
public struct RoundType: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let recruiterScreen = RoundType(rawValue: "recruiter_screen")
    public static let behavioral = RoundType(rawValue: "behavioral")
    public static let technical = RoundType(rawValue: "technical")
    public static let systemDesign = RoundType(rawValue: "system_design")
    public static let builtins: [RoundType] = [.recruiterScreen, .behavioral, .technical, .systemDesign]

    /// "take_home_review" → "Take Home Review". Matches the old hardcoded
    /// names for all four builtins, so no special-casing.
    public var displayName: String {
        rawValue.split(separator: "_").map(\.capitalized).joined(separator: " ")
    }

    // Explicit single-value coding: memberwise synthesis would encode
    // {"rawValue": "..."} and corrupt DB round-trips.
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
```

- [ ] **Step 4: Fix the two now-non-optional inits in `Sources/Store/Queries.swift`**

Line 155, inside `scoresByDate` — replace:

```swift
guard let rt = RoundType(rawValue: row["roundType"]) else { continue }
```

with:

```swift
let rt = RoundType(rawValue: row["roundType"])
```

Line 176, inside `pipeline()` — replace:

```swift
let sessions = rows.compactMap { row -> SessionSummary? in
    guard let rt = RoundType(rawValue: row["roundType"]) else { return nil }
    return SessionSummary(id: row["id"], roundType: rt, date: row["date"], overallScore: row["overallScore"])
}
```

with:

```swift
let sessions = rows.map { row in
    SessionSummary(id: row["id"], roundType: RoundType(rawValue: row["roundType"]),
                   date: row["date"], overallScore: row["overallScore"])
}
```

- [ ] **Step 5: Build and run the full suite (not just the new tests — UI code uses `RoundType.allCases`, which no longer exists; fix any compile fallout is Task 3's job, so ONLY run Store + CoachingEngine tests here)**

Run: `swift test --filter StoreTests 2>&1 | tail -5` and `swift test --filter CoachingEngineTests 2>&1 | tail -5`

Expected: StoreTests PASS. If `DebriefApp` target breaks the build for test targets, note it and proceed to Task 3 before committing (SPM builds all targets; if so, do Task 3's mechanical picker fixes in this same commit).

- [ ] **Step 6: Commit** (fold Task 3's picker changes in here if the build required them)

```bash
git add Sources/Store/Records.swift Sources/Store/Queries.swift Tests/StoreTests/RoundTypeTests.swift
git commit -m "RoundType: enum → string-backed struct

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: PromptStore — round-type discovery and missing-overlay fallback

**Files:**
- Modify: `Sources/CoachingEngine/PromptStore.swift`
- Test: `Tests/CoachingEngineTests/PromptStoreTests.swift`

**Interfaces:**
- Consumes: `RoundType(rawValue:)`, `RoundType.builtins` from Task 1.
- Produces: `PromptStore.availableRoundTypes() -> [RoundType]` — every `*.md` in the directory except `base.md`; builtins first (in `RoundType.builtins` order), customs after, alphabetical by rawValue. `assembleSystemPrompt` no longer throws when the overlay file is missing (falls back to base-only).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/CoachingEngineTests/PromptStoreTests.swift`:

```swift
func testAvailableRoundTypesDiscoversFilesBuiltinsFirst() throws {
    try store.ensureDefaults()
    try "custom".write(to: dir.appendingPathComponent("take_home_review.md"), atomically: true, encoding: .utf8)
    try "custom".write(to: dir.appendingPathComponent("bar_raiser.md"), atomically: true, encoding: .utf8)
    try "not a prompt".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    XCTAssertEqual(store.availableRoundTypes(), [
        .recruiterScreen, .behavioral, .technical, .systemDesign,       // builtins, fixed order
        RoundType(rawValue: "bar_raiser"), RoundType(rawValue: "take_home_review"),  // customs, alphabetical
    ])  // base.md excluded, non-.md files excluded
}

func testAvailableRoundTypesEmptyDirectory() {
    XCTAssertEqual(store.availableRoundTypes(), [])
}

func testAssembleFallsBackToBaseWhenOverlayMissing() throws {
    try store.ensureDefaults()
    let prompt = try store.assembleSystemPrompt(
        roundType: RoundType(rawValue: "deleted_custom_type"), historyTags: [])
    XCTAssertTrue(prompt.contains("weakness_tags"))          // base rubric present
    XCTAssertTrue(prompt.contains("No prior session history"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PromptStoreTests 2>&1 | tail -5`
Expected: compile error — no member `availableRoundTypes` (and the fallback test would throw `CocoaError.fileReadNoSuchFile`).

- [ ] **Step 3: Implement in `Sources/CoachingEngine/PromptStore.swift`**

Add this method to `PromptStore`:

```swift
/// Every overlay file in the prompts directory is a selectable round type.
/// Builtins first (stable order), then custom files alphabetically.
public func availableRoundTypes() -> [RoundType] {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    let types = files.filter { $0.pathExtension == "md" }
        .map { RoundType(rawValue: $0.deletingPathExtension().lastPathComponent) }
        .filter { $0.rawValue != "base" }
    let customs = types.filter { !RoundType.builtins.contains($0) }.sorted { $0.rawValue < $1.rawValue }
    return RoundType.builtins.filter(types.contains) + customs
}
```

In `assembleSystemPrompt`, replace:

```swift
let overlay = try String(contentsOf: directory.appendingPathComponent("\(roundType.rawValue).md"), encoding: .utf8)
```

with:

```swift
// Missing overlay (user deleted a custom type's file) must not fail the
// debrief — coach from the base rubric alone.
let overlay = (try? String(contentsOf: directory.appendingPathComponent("\(roundType.rawValue).md"),
                           encoding: .utf8)) ?? ""
```

and replace `var sections = [base, overlay, history]` with:

```swift
var sections = overlay.isEmpty ? [base, history] : [base, overlay, history]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PromptStoreTests 2>&1 | tail -5`
Expected: PASS (all, including the pre-existing tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CoachingEngine/PromptStore.swift Tests/CoachingEngineTests/PromptStoreTests.swift
git commit -m "PromptStore: discover round types from prompt files, base-only fallback

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: UI pickers use the dynamic round-type list

**Files:**
- Modify: `Sources/DebriefApp/MenuBarView.swift:46`
- Modify: `Sources/DebriefApp/MainWindow.swift:90` (inside `RecordingBar`)
- Modify: `Sources/DebriefApp/RecoveryPrompt.swift:29`
- Modify: `Sources/DebriefApp/TrendsView.swift:16`

**Interfaces:**
- Consumes: `env.prompts.availableRoundTypes()` from Task 2 (all four views already have `@EnvironmentObject var env: AppEnvironment`, and `AppEnvironment.prompts` is already public within the module).
- Produces: nothing new.

*(If Task 1's build already forced these edits, this task is just verification + the TrendsView optional variant.)*

- [ ] **Step 1: Replace `RoundType.allCases` at each site**

In `MenuBarView.swift`, `MainWindow.swift` (RecordingBar), and `RecoveryPrompt.swift`, the picker line:

```swift
ForEach(RoundType.allCases, id: \.self) { Text($0.displayName).tag($0) }
```

becomes:

```swift
ForEach(env.prompts.availableRoundTypes(), id: \.self) { Text($0.displayName).tag($0) }
```

In `TrendsView.swift` (optional-tagged filter):

```swift
ForEach(RoundType.allCases, id: \.self) { Text($0.displayName).tag(RoundType?.some($0)) }
```

becomes:

```swift
ForEach(env.prompts.availableRoundTypes(), id: \.self) { Text($0.displayName).tag(RoundType?.some($0)) }
```

- [ ] **Step 2: Build everything and run the full suite**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: build succeeds (no remaining `allCases` references — verify with `grep -rn "RoundType.allCases" Sources/`), tests PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/DebriefApp
git commit -m "Round-type pickers list prompt-folder types, not a hardcoded enum

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: OpenAICompatibleClient

**Files:**
- Create: `Sources/CoachingEngine/OpenAICompatibleClient.swift`
- Test: `Tests/CoachingEngineTests/OpenAICompatibleClientTests.swift`

**Interfaces:**
- Consumes: `CoachingLLM` protocol, `ClaudeError`, `CoachingResult` (all existing). Reuses `MockURLProtocol` + `URLRequest.bodyData()` from `Tests/CoachingEngineTests/ClaudeClientTests.swift` (internal to the test target — no changes needed).
- Produces: `OpenAICompatibleClient(baseURL: URL, model: String, apiKey: String = "", session: URLSession = .shared)` conforming to `CoachingLLM`; `static func extractJSON(from: String) -> Data?` (internal, for tests).

- [ ] **Step 1: Write the failing tests**

Create `Tests/CoachingEngineTests/OpenAICompatibleClientTests.swift`:

```swift
import XCTest
@testable import CoachingEngine

final class OpenAICompatibleClientTests: XCTestCase {
    func makeClient(apiKey: String = "") -> OpenAICompatibleClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return OpenAICompatibleClient(baseURL: URL(string: "http://localhost:11434/v1")!,
                                      model: "deepseek-r1:14b", apiKey: apiKey,
                                      session: URLSession(configuration: config))
    }

    static let goodJSON = """
    {"prose_debrief":"Solid.","scores":{"answer_relevance":4,"structure":3,"conciseness":3,"questions_asked":2},
     "weakness_tags":[],"highlights":[{"t":"00:05:10","note":"good {question}"}],"action_items":["Prep"]}
    """

    func envelope(content: String) -> Data {
        try! JSONSerialization.data(withJSONObject:
            ["choices": [["message": ["role": "assistant", "content": content]]]])
    }

    func testRequestShapeAndPlainJSONResponse() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))  // no key → no header
            let body = try! JSONSerialization.jsonObject(with: request.bodyData()) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "deepseek-r1:14b")
            let messages = body["messages"] as! [[String: String]]
            XCTAssertEqual(messages[0]["role"], "system")
            XCTAssertTrue(messages[0]["content"]!.contains("ONLY a single JSON object"))  // format appendix
            XCTAssertTrue(messages[0]["content"]!.hasPrefix("coach"))  // original prompt first
            XCTAssertEqual(messages[1], ["role": "user", "content": "transcript"])
            return (200, self.envelope(content: Self.goodJSON))
        }
        let result = try await makeClient().generateCoaching(systemPrompt: "coach", userMessage: "transcript")
        XCTAssertEqual(result.proseDebrief, "Solid.")
        XCTAssertEqual(result.scores["answer_relevance"], 4)
    }

    func testBearerHeaderWhenKeyProvided() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-local")
            return (200, self.envelope(content: Self.goodJSON))
        }
        _ = try await makeClient(apiKey: "sk-local").generateCoaching(systemPrompt: "s", userMessage: "u")
    }

    func testParsesThinkBlocksAndFences() async throws {
        let wrapped = "<think>hmm {not: json}</think>\nHere you go:\n```json\n\(Self.goodJSON)\n```"
        MockURLProtocol.handler = { _ in (200, self.envelope(content: wrapped)) }
        let result = try await makeClient().generateCoaching(systemPrompt: "s", userMessage: "u")
        XCTAssertEqual(result.highlights.first?.note, "good {question}")  // braces inside strings survive
    }

    func testGarbageContentThrowsEmptyResponse() async {
        MockURLProtocol.handler = { _ in (200, self.envelope(content: "I cannot produce JSON, sorry.")) }
        do {
            _ = try await makeClient().generateCoaching(systemPrompt: "s", userMessage: "u")
            XCTFail("expected throw")
        } catch let e as ClaudeError { XCTAssertEqual(e, .emptyResponse) } catch { XCTFail("\(error)") }
    }

    func testHTTPErrorThrows() async {
        MockURLProtocol.handler = { _ in (500, Data("model not found".utf8)) }
        do {
            _ = try await makeClient().generateCoaching(systemPrompt: "s", userMessage: "u")
            XCTFail("expected throw")
        } catch let e as ClaudeError { XCTAssertEqual(e, .httpStatus(500, body: "model not found")) }
        catch { XCTFail("\(error)") }
    }

    func testExtractJSONEdgeCases() {
        // Unclosed think tag: give up on stripping, still find JSON after it? No —
        // the block swallows the rest; document that nil is acceptable there.
        XCTAssertNil(OpenAICompatibleClient.extractJSON(from: "no braces here"))
        XCTAssertNil(OpenAICompatibleClient.extractJSON(from: "{\"unterminated\": "))
        let s = String(data: OpenAICompatibleClient.extractJSON(from: "prefix {\"a\": \"b}\"} suffix")!,
                       encoding: .utf8)
        XCTAssertEqual(s, "{\"a\": \"b}\"}")
        let esc = String(data: OpenAICompatibleClient.extractJSON(from: #"{"a": "quote \" brace }"}"#)!,
                         encoding: .utf8)
        XCTAssertEqual(esc, #"{"a": "quote \" brace }"}"#)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter OpenAICompatibleClientTests 2>&1 | tail -5`
Expected: compile error — `OpenAICompatibleClient` does not exist.

- [ ] **Step 3: Implement `Sources/CoachingEngine/OpenAICompatibleClient.swift`**

```swift
import Foundation

/// Coaching via any OpenAI-compatible /chat/completions server: Ollama,
/// LM Studio, llama.cpp, or remote providers like DeepSeek cloud.
///
/// These servers disagree on response_format support (json_schema vs
/// json_object vs 400), so instead of structured outputs we ask for JSON in
/// the prompt and parse tolerantly — see extractJSON.
public struct OpenAICompatibleClient: CoachingLLM {
    let baseURL: URL
    let model: String
    let apiKey: String
    let session: URLSession

    public init(baseURL: URL, model: String, apiKey: String = "", session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    static let formatAppendix = """
    ## Output format (mandatory)

    Respond with ONLY a single JSON object — no markdown fences, no commentary, \
    no text before or after it. The object must have exactly these fields:

    {
      "prose_debrief": "string — the 300-600 word markdown debrief",
      "scores": {"answer_relevance": 1-5, "structure": 1-5, "conciseness": 1-5, "questions_asked": 1-5},
      "weakness_tags": ["string — only tags from the allowed vocabulary above"],
      "highlights": [{"t": "HH:MM:SS", "note": "string"}],
      "action_items": ["string"]
    }

    All five top-level fields are required. Scores are integers.
    """

    public func generateCoaching(systemPrompt: String, userMessage: String) async throws -> CoachingResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600  // local inference on a long transcript is slow
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt + "\n\n" + Self.formatAppendix],
                ["role": "user", "content": userMessage],
            ],
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        guard http.statusCode == 200 else {
            throw ClaudeError.httpStatus(http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        struct Envelope: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let content = envelope.choices.first?.message.content,
              let payload = Self.extractJSON(from: content) else {
            throw ClaudeError.emptyResponse
        }
        return try JSONDecoder().decode(CoachingResult.self, from: payload)
    }

    /// Local models wrap JSON in <think> blocks, fences, or prose. Strip think
    /// blocks (they may contain braces), then return the first balanced
    /// top-level JSON object, tracking strings/escapes so braces inside string
    /// values don't fool the depth counter. Fences need no handling: the scan
    /// starts at the first "{".
    static func extractJSON(from text: String) -> Data? {
        var s = text
        while let open = s.range(of: "<think>"),
              let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
            s.removeSubrange(open.lowerBound..<close.upperBound)
        }
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if escaped { escaped = false }
            else if inString && c == "\\" { escaped = true }
            else if c == "\"" { inString.toggle() }
            else if !inString && c == "{" { depth += 1 }
            else if !inString && c == "}" {
                depth -= 1
                if depth == 0 { return String(s[start...i]).data(using: .utf8) }
            }
            i = s.index(after: i)
        }
        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter OpenAICompatibleClientTests 2>&1 | tail -5`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CoachingEngine/OpenAICompatibleClient.swift Tests/CoachingEngineTests/OpenAICompatibleClientTests.swift
git commit -m "OpenAI-compatible coaching client for local/remote LLMs

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Provider selection — Settings UI + AppEnvironment wiring

**Files:**
- Modify: `Sources/DebriefApp/AppEnvironment.swift` (`resolveModel`/`rebuildCoaching`/`live`)
- Modify: `Sources/DebriefApp/SettingsView.swift`
- Test: `Tests/DebriefAppTests/AppEnvironmentTests.swift` (add one test)

**Interfaces:**
- Consumes: `OpenAICompatibleClient` (Task 4), existing `AnthropicClient`, `KeychainStore`.
- Produces: `AppEnvironment.resolveLLM() -> CoachingLLM` (static). UserDefaults keys per Global Constraints.

- [ ] **Step 1: Write the failing test**

Add to `Tests/DebriefAppTests/AppEnvironmentTests.swift` (match the file's existing style when you open it):

```swift
func testResolveLLMDispatchesOnProvider() {
    let d = UserDefaults.standard
    defer {
        d.removeObject(forKey: "coachingProvider")
        d.removeObject(forKey: "openAICompatBaseURL")
        d.removeObject(forKey: "openAICompatModel")
    }
    d.set("openai_compat", forKey: "coachingProvider")
    d.set("http://localhost:1234/v1", forKey: "openAICompatBaseURL")
    d.set("qwen2.5:14b", forKey: "openAICompatModel")
    XCTAssertTrue(AppEnvironment.resolveLLM() is OpenAICompatibleClient)

    d.set("anthropic", forKey: "coachingProvider")
    XCTAssertTrue(AppEnvironment.resolveLLM() is AnthropicClient)

    d.removeObject(forKey: "coachingProvider")  // default: anthropic
    XCTAssertTrue(AppEnvironment.resolveLLM() is AnthropicClient)
}
```

Also add `import CoachingEngine` to that test file if not present.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppEnvironmentTests 2>&1 | tail -5`
Expected: compile error — no member `resolveLLM`.

- [ ] **Step 3: Implement `resolveLLM` in `AppEnvironment.swift`**

Add below `resolveModel()`:

```swift
static func resolveLLM() -> CoachingLLM {
    let d = UserDefaults.standard
    guard d.string(forKey: "coachingProvider") == "openai_compat" else {
        return AnthropicClient(apiKey: resolveAPIKey(), model: resolveModel())
    }
    let base = d.string(forKey: "openAICompatBaseURL") ?? ""
    let url = URL(string: base.isEmpty ? "http://localhost:11434/v1" : base)
        ?? URL(string: "http://localhost:11434/v1")!
    return OpenAICompatibleClient(baseURL: url,
                                  model: d.string(forKey: "openAICompatModel") ?? "",
                                  apiKey: KeychainStore.read(key: "openai-compat-api-key") ?? "")
}
```

In `rebuildCoaching()` replace `llm: AnthropicClient(apiKey: Self.resolveAPIKey(), model: Self.resolveModel())` with `llm: Self.resolveLLM()`.

In `live()` replace `llm: AnthropicClient(apiKey: apiKey, model: resolveModel())` with `llm: resolveLLM()` (the local `apiKey` variable becomes unused — delete it).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AppEnvironmentTests 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Settings UI**

In `SettingsView.swift`:

Add state (near the existing `@AppStorage` lines):

```swift
@AppStorage("coachingProvider") private var provider = "anthropic"
@AppStorage("openAICompatBaseURL") private var compatBaseURL = "http://localhost:11434/v1"
@AppStorage("openAICompatModel") private var compatModel = ""
@State private var compatKey = KeychainStore.read(key: "openai-compat-api-key") ?? ""
```

Rename the `Section("Claude API")` to `Section("Coaching model")` and restructure:

```swift
Section("Coaching model") {
    Picker("Provider", selection: $provider) {
        Text("Claude API (recommended)").tag("anthropic")
        Text("Local / OpenAI-compatible").tag("openai_compat")
    }
    .onChange(of: provider) { env.rebuildCoaching() }

    if provider == "anthropic" {
        // ... the entire existing Claude block moves here unchanged:
        // warning labels, SecureField, Save button, model Picker + caption
    } else {
        TextField("Base URL", text: $compatBaseURL, prompt: Text("http://localhost:11434/v1"))
            .onChange(of: compatBaseURL) { env.rebuildCoaching() }
        TextField("Model", text: $compatModel, prompt: Text("e.g. deepseek-r1:14b"))
            .onChange(of: compatModel) { env.rebuildCoaching() }
        SecureField("API key (optional, for remote providers)", text: $compatKey)
        Button("Save key") {
            do {
                if compatKey.isEmpty {
                    try KeychainStore.delete(key: "openai-compat-api-key")
                } else {
                    try KeychainStore.save(key: "openai-compat-api-key", value: compatKey)
                }
                env.rebuildCoaching()
                saved = true; saveError = nil
            } catch {
                saveError = "Could not save key: \(error.localizedDescription)"; saved = false
            }
        }
        if saved { Text("Saved ✓").foregroundStyle(.green) }
        if let saveError { Text(saveError).foregroundStyle(.red) }
        Text("Works with Ollama, LM Studio, or any /v1/chat/completions server. See docs/local-llm.md for setup. Local models give weaker coaching than Claude.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
```

Keep the existing `apiKey`/`saved`/`saveError` state and Claude-side controls exactly as they are — only their nesting changes.

- [ ] **Step 6: Build, run full suite, and eyeball the UI**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: build + all tests PASS.

Manual check (optional but recommended): `./scripts/make-app.sh && open Debrief.app`, open Settings, flip the provider picker both ways, confirm fields render.

- [ ] **Step 7: Commit**

```bash
git add Sources/DebriefApp/AppEnvironment.swift Sources/DebriefApp/SettingsView.swift Tests/DebriefAppTests/AppEnvironmentTests.swift
git commit -m "Settings: choose Claude API or a local/OpenAI-compatible provider

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Tutorial (docs/local-llm.md) + README/checklist pointers

**Files:**
- Create: `docs/local-llm.md`
- Modify: `README.md` (Requirements section: note the API key is only needed for the Claude provider, link the tutorial)
- Modify: `docs/manual-test-checklist.md` (add local-provider and custom-round-type checks)

**Interfaces:** none — prose.

- [ ] **Step 1: Write `docs/local-llm.md`** with exactly these sections (exact commands included; flesh out prose around them):

````markdown
# Running Debrief with a local LLM

Debrief's coaching step normally calls the Claude API. If you'd rather keep
everything on your machine (or use another provider), point Debrief at any
OpenAI-compatible server. This guide uses Ollama; LM Studio and remote
providers are covered at the end.

## Honest expectations

Local models produce noticeably weaker coaching than Claude: shallower
feedback, occasional invented quotes, and (rarely) malformed output. When
output can't be parsed the session shows **failed** — use "Retry pending
debriefs" in Settings or the retry button in the sessions list. A 14B-class
model is the practical floor for useful feedback.

## 1. Install Ollama and pull a model

```sh
brew install ollama
ollama serve   # leave running (or: brew services start ollama)
```

Pick by RAM (unified memory):
| Mac RAM | Model | Pull command |
|---|---|---|
| 16 GB | `qwen2.5:14b` | `ollama pull qwen2.5:14b` |
| 32 GB | `deepseek-r1:32b` or `qwen2.5:32b` | `ollama pull deepseek-r1:32b` |
| 64 GB+ | `llama3.3:70b` | `ollama pull llama3.3:70b` |

Instruction-tuned models that follow JSON format requests work best.

## 2. Raise the context window (IMPORTANT)

Ollama defaults to a small context window (4k tokens for many models) and
**silently truncates** anything longer. A 45-minute interview transcript plus
the coaching rubric is far bigger than that — with the default you'd get a
debrief of the first few minutes only, with no error.

```sh
OLLAMA_CONTEXT_LENGTH=32768 ollama serve
```

(Or set it in the Ollama app's settings, or bake `PARAMETER num_ctx 32768`
into a Modelfile.) Rule of thumb: 1 hour of interview ≈ 12-16k tokens; 32k
covers any realistic session. To confirm truncation isn't happening, run
`ollama ps` during a debrief and check the context size it reports.

## 3. Point Debrief at it

Settings → Coaching model → Provider: **Local / OpenAI-compatible**
- Base URL: `http://localhost:11434/v1`
- Model: the tag you pulled, e.g. `qwen2.5:14b`
- API key: leave empty for Ollama

The next debrief (or a retry of a failed one) uses the local model.

## Variants

**LM Studio:** load a model, enable the local server (default
`http://localhost:1234/v1`), use the model name shown in the server tab.
Set the context length in the model load settings — same truncation warning
applies.

**Remote OpenAI-compatible providers (e.g. DeepSeek cloud):** Base URL
`https://api.deepseek.com/v1`, model `deepseek-chat`, and paste the
provider's API key into the API key field. Note: your transcript leaves your
machine, same as with Claude.

## Troubleshooting

- **Session failed immediately** — is the server running? `curl http://localhost:11434/v1/models` should return JSON.
- **Failed after several minutes** — the model likely produced unparseable output; retry, or switch to a larger/instruction-tuned model.
- **Debrief only covers the start of the interview** — context window too small; see step 2.
- **HTTP 404** — Base URL must include `/v1`.
````

- [ ] **Step 2: README + checklist edits**

README `Requirements` bullet — change:

```markdown
- A Claude API key (for the coaching step; transcription is free and local)
```

to:

```markdown
- A Claude API key for the coaching step (transcription is free and local) —
  or run coaching fully offline against a local model; see [docs/local-llm.md](docs/local-llm.md)
```

`docs/manual-test-checklist.md` — append:

```markdown
- [ ] Settings → provider "Local / OpenAI-compatible" + running Ollama: debrief completes; stop Ollama: session marks failed, retry works after restart
- [ ] Drop `take_home_review.md` into the prompts folder: "Take Home Review" appears in the round picker; delete the file: existing sessions of that type still debrief (base rubric only)
```

- [ ] **Step 3: Commit**

```bash
git add docs/local-llm.md README.md docs/manual-test-checklist.md
git commit -m "Tutorial: run Debrief coaching against a local LLM

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Subagent prompt review

**Files:**
- Possibly modify: `Sources/CoachingEngine/DefaultPrompts.swift`, `Sources/CoachingEngine/OpenAICompatibleClient.swift` (formatAppendix), `docs/local-llm.md`

- [ ] **Step 1: Dispatch a review subagent** (Sonnet-class model — judgment work, doesn't need the top tier). Prompt it with the full text of `DefaultPrompts.swift` and `formatAppendix`, asking it to adversarially review for:
  - contradictions between base rubric, overlays, and the JSON appendix (e.g. "markdown allowed" in prose_debrief vs "no markdown fences" in the appendix — is that confusable?)
  - instructions a 14B local model will likely fail to follow (nested structure, negations, vocabulary lookups across sections)
  - ambiguity in the weakness-tag vocabulary rules when overlays add tags
  - whether the appendix schema exactly matches `AnthropicClient.outputSchema` fields and `CoachingResult` CodingKeys

- [ ] **Step 2: Verify each finding yourself before applying** (read the actual code/prompt — subagent findings can be plausible-but-wrong). Apply only confirmed fixes.

- [ ] **Step 3: Run full suite, commit if anything changed**

```bash
swift test 2>&1 | tail -5
git add -A && git commit -m "Prompt fixes from adversarial review

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: Final verification

- [ ] **Step 1: Full suite + build**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: all PASS.

- [ ] **Step 2: Grep for leftovers**

```bash
grep -rn "RoundType.allCases" Sources/ Tests/   # expect: no matches
grep -rn "displayName" Sources/Store/Records.swift  # expect: the derived implementation
```

- [ ] **Step 3: End-to-end smoke (if Ollama available locally)**

`./scripts/make-app.sh && open Debrief.app` — flip provider to local, drop a `pair_programming.md` overlay into the prompts folder (copy `behavioral.md`), confirm it appears in the menu-bar round picker.

- [ ] **Step 4: Present integration options** (finishing-a-development-branch skill): merge to the parent branch vs PR.
