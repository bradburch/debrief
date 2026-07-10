# Session management, model selection & UX polish — design

## Problem

Three gaps in the current app:

1. **No way to delete a session.** Once recorded, a session is permanent — test
   runs, mis-tagged calls, and abandoned recordings pile up with no removal path.
2. **The coaching model is hardcoded** (`claude-opus-4-8` in `AnthropicClient`).
   Opus is the best but slowest/most expensive; there's no way to trade quality
   for speed/cost.
3. **UX rough edges.** No empty-state guidance, no filter over a growing list,
   and the main window is disconnected from the core Record action (only the
   menu-bar popover shows recording state).

## Goal

Let the user delete sessions (including several at once), choose which Claude
model generates debriefs, and hit fewer friction points in everyday use.

## Non-goals

- Per-session model choice — one global setting satisfies "allow model
  selection". A future session could override it, but not now.
- On-disk audio cleanup on delete — raw audio is already deleted after a
  successful transcript by default, so there is nothing to clean up in the
  common case.
- Extracting a shared recording-controls view between the popover and the
  window — the two forms are reproduced independently (see Recording bar).

---

## 1. Delete sessions (multi-select + bulk)

The Store layer is already complete: `AppDatabase.deleteSession(id:)` exists,
and the `v1` schema declares `transcriptSegment`, `feedback`, and `weaknessTag`
as `belongsTo("session", onDelete: .cascade)`. GRDB enables foreign-key
enforcement by default, so deleting a session row cascades to all its children.
No Store changes are needed.

### UI (`SessionsView`)

- Change the list selection from `selectedId: Int64?` to
  `selection: Set<Int64>`. `List(selection:)` bound to a `Set` gives cmd/shift
  multi-select for free (standard Finder/Mail behavior).
- The detail pane shows only when exactly one row is selected. For 0 selected,
  show "Select a session"; for 2+, show "\(n) sessions selected".
- **Delete** is offered via a row `.contextMenu` and the ⌫ key, both routed to a
  single confirmation.
- A `.confirmationDialog` whose message reflects the count:
  "Delete \(n) session(s)? This can't be undone." On confirm: loop
  `db.deleteSession(id:)` over the selected set, `reload()`, then clear
  `selection`.

`reload()` and the `onReceive(coordinator.$phase)` behavior are unchanged.

---

## 2. Model selection for generation

### Client

`AnthropicClient.init` gains a `model` parameter with a default that preserves
every existing caller and test:

```swift
public init(apiKey: String, model: String = "claude-opus-4-8", session: URLSession = .shared)
```

The request body uses `self.model` instead of the hardcoded literal.

### Persistence

One value: `UserDefaults` key `"coachingModel"`, default `"claude-opus-4-8"`.
Options offered:

| Label       | Model id                    |
| ----------- | --------------------------- |
| Opus 4.8    | `claude-opus-4-8`           |
| Sonnet 5    | `claude-sonnet-5`           |
| Haiku 4.5   | `claude-haiku-4-5-20251001` |

### Wiring

`AppEnvironment` reads the stored model when building the client:

```swift
static func resolveModel() -> String {
    UserDefaults.standard.string(forKey: "coachingModel") ?? "claude-opus-4-8"
}
```

Both `live()` and `rebuildCoaching()` pass
`AnthropicClient(apiKey:, model: Self.resolveModel())`.

### UI (`SettingsView`, Claude API section)

A `Picker` bound to `@AppStorage("coachingModel")`, listing the three models by
label. `onChange` → `env.rebuildCoaching()` so a running app picks the new model
up immediately (same mechanism the API-key Save already uses). Settings is the
only home for this control.

---

## 3. UX polish

### Empty state (`SessionsView`)

When `rows.isEmpty`, replace the empty list with centered guidance:
"No sessions yet — click **Record** in the menu bar when a call starts." The
detail-side placeholder still reads "Select a session" but is unreachable while
the list is empty.

### Failed-session hint (`SessionDetailView`)

When the selected session's `coachingStatus == .failed` and there is no
feedback, show a one-line hint above the existing Generate button:
"Last debrief failed — press Generate to retry." The existing
Generate/Regenerate button is already the retry path; no new action.

### List filter (`SessionsView`)

A plain filter `TextField` pinned above the list, filtering `rows` by company
name (case-insensitive `contains`). ponytail: plain field over `.searchable`
to avoid `NavigationSplitView` toolbar-placement surprises. Empty filter = all
rows. Rows hidden by the filter are simply not rendered; selection of a
now-hidden row is harmless (detail just won't show it).

### Rename affordance (`SessionDetailView`)

The title `TextField` switches from `.plain` to `.roundedBorder` so it reads as
editable rather than static text. Behavior (commit on submit / on disappear) is
unchanged.

### Recording bar (`MainWindow`)

A compact status bar pinned to the top of the main window, driven by
`env.coordinator.phase`, so the window reflects the core action instead of only
the menu-bar popover:

- **idle**: subtle "No recording in progress", or "Call detected" (orange) when
  `env.callDetected`; a **Start recording** button calling
  `coordinator.startRecording()` (needs no metadata).
- **recording**: red record dot + `started`-relative timer, `LevelRow` bars for
  You/Them (reusing the existing `LevelRow` view), any `streamWarning`, and a
  **Stop & Debrief** button. Stopping needs metadata, so the bar reproduces the
  popover's three inline fields (Company / Round `Picker` / Notes) and calls
  `coordinator.stopAndFinalize(metadata:)`.
- **finalizing**: a `ProgressView` + the status string.
- **failed**: the failure message.

ponytail: the stop-form's three fields are reproduced here rather than shared
with `MenuBarView` via a `@Binding`-plumbed subview — ~15 duplicated lines read
more clearly than the abstraction. Upgrade path: extract a `RecordingControls`
view if a third caller ever appears. A `ponytail:` comment marks it in code.

---

## Testing

- **Store**: `deleteSession` cascade is already covered by existing tests; if
  not, add one asserting that after `deleteSession`, the session's segments,
  feedback, and tags are all gone.
- **Client**: `ClaudeClientTests` — assert the request body's `model` field
  reflects the value passed to `init` (default and an override).
- UI wiring (empty state, filter, recording bar, confirmation) is verified
  manually against `docs/manual-test-checklist.md`; SwiftUI views aren't
  unit-tested in this project.

## Files touched

- `Sources/CoachingEngine/ClaudeClient.swift` — `model` param + use it
- `Sources/DebriefApp/AppEnvironment.swift` — `resolveModel`, pass model in
  `live()` + `rebuildCoaching()`
- `Sources/DebriefApp/SettingsView.swift` — model `Picker`
- `Sources/DebriefApp/SessionsView.swift` — multi-select, delete + confirm,
  empty state, filter, failed hint, rename affordance
- `Sources/DebriefApp/MainWindow.swift` — recording status bar
- `Tests/CoachingEngineTests/ClaudeClientTests.swift` — model-in-body assertion
- `Tests/StoreTests/StoreTests.swift` — delete-cascade assertion (if missing)
