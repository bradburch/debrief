# Local LLM Support & Custom Interview Types — Design

**Date:** 2026-07-10
**Status:** Approved

## Goal

Two user-facing features plus one process step:

1. Run debrief coaching against a local LLM (Ollama, LM Studio, llama.cpp) or any
   OpenAI-compatible remote provider (e.g. DeepSeek cloud), selectable in Settings,
   with a setup tutorial.
2. Let users add new interview round types by dropping a `.md` overlay file into the
   existing prompts folder — no app UI needed.
3. During implementation, a subagent reviews the coaching prompts (existing defaults
   plus the new JSON-format appendix) and verified findings are folded in.

## Part 1: Local LLM support

### New client

`Sources/CoachingEngine/OpenAICompatibleClient.swift` — a second implementation of
the existing `CoachingLLM` protocol:

```swift
public struct OpenAICompatibleClient: CoachingLLM {
    let baseURL: URL        // e.g. http://localhost:11434/v1
    let model: String       // e.g. deepseek-r1:14b
    let apiKey: String      // optional; sent as Bearer token when non-empty
    let session: URLSession
}
```

`generateCoaching` POSTs `{baseURL}/chat/completions` with the system prompt and
user message. Timeout 600 s (local inference is slow).

### Structured output strategy

OpenAI-compatible servers disagree on `response_format` support (LM Studio: full
`json_schema`; Ollama compat endpoint: `json_object` only; DeepSeek cloud: errors on
`json_schema`). The client therefore does NOT send `response_format` and instead:

- Appends a format appendix to the system prompt: "Respond with ONLY a JSON object
  matching this schema", followed by the schema (same shape as
  `AnthropicClient.outputSchema`).
- Parses tolerantly, in order:
  1. Strip `<think>…</think>` blocks (DeepSeek-R1 and other reasoning models emit
     these).
  2. Strip markdown code fences.
  3. Extract the first balanced `{…}` JSON object from the remaining text.
  4. Decode as `CoachingResult` (same decoder path as the Anthropic client).

Errors surface through the existing error handling (`markCoachingFailed` +
session-list retry), same as Anthropic failures.

### Settings & wiring

- Provider picker in Settings: **Claude API** (default; today's UI unchanged) /
  **Local / OpenAI-compatible**.
- When local is selected: base URL text field (default `http://localhost:11434/v1`),
  free-text model name field, optional API key field (stored in Keychain under a
  separate key, `openai-compat-api-key`).
- Persisted in UserDefaults: `coachingProvider` (`anthropic` | `openai_compat`),
  `openAICompatBaseURL`, `openAICompatModel`.
- `AppEnvironment.rebuildCoaching()` / `live()` construct whichever client the
  provider setting names.

### Tutorial

`docs/local-llm.md`: install Ollama, pull a recommended model, point Debrief at it.
Must cover:

- **Context length** — Ollama's default context window silently truncates long
  inputs, and interview transcripts are long. Show how to raise it
  (`OLLAMA_CONTEXT_LENGTH` env var or a Modelfile with `num_ctx`), and how to spot
  truncation.
- Model recommendations by RAM tier, favoring instruction-following models capable
  of JSON output.
- LM Studio and remote OpenAI-compatible providers (DeepSeek cloud) as variants.
- Honest quality note: local models produce weaker coaching than Claude; the
  schema-in-prompt approach can occasionally fail to parse (session shows failed,
  retry from the sessions list).

## Part 2: Custom interview types

### RoundType becomes string-backed

`RoundType` in `Sources/Store/Records.swift` changes from a 4-case enum to:

```swift
public struct RoundType: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public static let recruiterScreen = RoundType(rawValue: "recruiter_screen")
    public static let behavioral      = RoundType(rawValue: "behavioral")
    public static let technical      = RoundType(rawValue: "technical")
    public static let systemDesign    = RoundType(rawValue: "system_design")
}
```

- DB storage is unchanged: it already persists the raw string, and
  `RawRepresentable` + `Codable` keeps the same encoded form.
- `displayName`: built-ins keep their current names; anything else is derived from
  the raw value (`take_home_review` → "Take Home Review").
- `RoundType(rawValue:)` never fails now, which removes the silent row-skipping in
  `Queries.swift` for unknown types.

### Discovery

`PromptStore.availableRoundTypes() -> [RoundType]` — every `*.md` file in the
prompts directory except `base.md`, built-ins first in their current order, custom
types alphabetical after. Replaces `RoundType.allCases` at all four picker sites
(MenuBarView, MainWindow, RecoveryPrompt, TrendsView filter).

### Fallback

`assembleSystemPrompt` currently throws if the overlay file is missing (e.g. user
deleted a custom type's file after recording sessions with it). Change: missing
overlay → assemble from `base.md` alone, don't fail the debrief.

## Part 3: Prompt review subagent

During implementation, dispatch a Sonnet subagent to adversarially review the
default prompts and the new JSON-format appendix for contradictions, ambiguity, and
local-model failure modes. Verified findings are folded into `DefaultPrompts.swift`
/ the appendix before merge. Process step, not a feature.

## Testing

- `OpenAICompatibleClient` JSON extraction: plain JSON, fenced JSON, `<think>`
  preamble, JSON with surrounding prose, unparseable garbage (throws).
- `PromptStore.availableRoundTypes()`: discovery, built-in-first ordering,
  `base.md` exclusion.
- Missing-overlay fallback in `assembleSystemPrompt`.
- `RoundType` display-name derivation for custom raw values.

## Out of scope

- In-app prompt/round-type editor UI.
- In-app "review my prompt" feature.
- Anthropic-protocol proxying, streaming, per-provider structured-output modes.
