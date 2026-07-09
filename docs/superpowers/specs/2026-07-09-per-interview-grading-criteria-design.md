# Per-interview grading criteria — design

## Problem

The coaching model grades every interview against the same rubric (base prompt +
round-type overlay + weakness history). There is no way to give the model
criteria that apply to *one specific* interview — e.g. a job's published rubric,
a leveling guide, or "focus on system-design trade-offs, this is a staff role".

## Goal

Let the user paste free-form grading criteria tied to a single recording. When
present, the model reads and grades against them, treating them as higher
priority than the general rubric on conflict, while the base dimensions,
weakness-tag vocabulary, and output format still fully apply.

## Non-goals

- Entering criteria in the record panel (menu bar) before finalize. First
  auto-debrief runs without criteria; user regenerates to apply them.
- Per-round criteria templates, or criteria reuse/history across interviews.

## Data model

Add one column via a new migration `v2`:

```
session.customInstructions TEXT NOT NULL DEFAULT ''
```

Empty string is the "feature off" state and reproduces today's behavior exactly
(existing rows migrate to `''`).

Add the field to `InterviewSession`:

```swift
public var customInstructions: String
```

Update its initializer and all call sites (notably `RecordingCoordinator`'s
`insertSession`, which passes `customInstructions: ""` — new recordings start
with no criteria).

## Prompt assembly

Criteria is grading instruction, so it rides the **system** channel, not the
transcript/user-message channel.

`PromptStore.assembleSystemPrompt` gains a parameter:

```swift
func assembleSystemPrompt(roundType: RoundType,
                          historyTags: [(tag: String, count: Int)],
                          customInstructions: String) throws -> String
```

When `customInstructions` is non-empty (after trimming), append a final section
after base + overlay + history:

```
## Criteria for THIS interview

These instructions were provided specifically for this interview. Where they
conflict with the general rubric above, follow these. Otherwise the base
dimensions, weakness-tag vocabulary, and output format above still fully apply.

<customInstructions verbatim>
```

When empty, the section is omitted and the assembled prompt is byte-identical to
today's.

`CoachingService.coach` reads `detail.session.customInstructions` and passes it
through. The user message (metadata + transcript) is unchanged.

## UI

In `SessionDetailView`'s debrief pane, above the debrief body:

- A "Grading criteria" `TextEditor` (multi-line, paste-friendly), bound to a
  `@State` string seeded from `detail.session.customInstructions` on appear.
- Persisted on the same triggers as the title edit:
  - on `onDisappear` (alongside the existing rename commit), and
  - immediately before "Regenerate debrief" runs, so regenerate always grades
    against what is currently on screen.

New DB writer:

```swift
func updateSessionCriteria(id: Int64, _ text: String) throws
```

The existing "Regenerate debrief" button is the apply action; no separate
"apply criteria" button.

## Testing

Extend `PromptStoreTests`:

- With non-empty `customInstructions`, the assembled system prompt contains the
  criteria text and the precedence sentence ("Where they conflict ... follow
  these").
- With empty `customInstructions`, the "Criteria for THIS interview" heading is
  absent.

## Files touched

- `Sources/Store/Records.swift` — `InterviewSession.customInstructions`
- `Sources/Store/AppDatabase.swift` — migration `v2`
- `Sources/Store/Queries.swift` — `updateSessionCriteria`
- `Sources/CoachingEngine/PromptStore.swift` — new param + section
- `Sources/CoachingEngine/CoachingService.swift` — thread the field through
- `Sources/DebriefApp/RecordingCoordinator.swift` — `insertSession` call site
- `Sources/DebriefApp/SessionsView.swift` — criteria editor + persistence
- `Tests/CoachingEngineTests/PromptStoreTests.swift` — assertions
