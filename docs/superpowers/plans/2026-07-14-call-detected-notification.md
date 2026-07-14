# Call-Detected Notification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When Debrief detects a call starting, pop up a macOS notification with a one-click **Record** action, fulfilling the v1 design line "Call detected: pulsing icon + notification with Record button. The app never auto-records."

**Architecture:** `AppEnvironment.pollDetection` already knows when a call likely starts/ends. We add a tiny `CallAlerting` protocol seam (so tests never touch `UNUserNotificationCenter`, which crashes outside a bundled app), a real `CallAlerts` implementation using `UNUserNotificationCenter`, and a shared `env.startRecording()` wrapper (mirroring the existing `stopAndDebrief()`) so the notification action, menu-bar button, and main-window button share one path that also clears any delivered notification.

**Tech Stack:** Swift 5.10, SwiftUI, UserNotifications framework (native — no new dependencies), XCTest.

## Global Constraints

- Platform: macOS 14+ (`Package.swift` platforms `.macOS(.v14)`).
- **The app never auto-records** (design spec, `docs/superpowers/specs/2026-07-02-interview-note-taker-design.md`): the notification must require an explicit user click to start recording.
- No new SPM dependencies; UserNotifications is a system framework.
- `UNUserNotificationCenter.current()` must never be constructed in `swift test` (it traps without an app bundle). All unit tests go through the `CallAlerting` protocol with a fake.
- Follow existing code style: `ponytail:` comments for deliberate simplifications; tests colocated in `Tests/DebriefAppTests`.
- Existing behavior to preserve: `callDetected` drives the menu-bar icon (`phone.circle.fill`) and the "Call detected" labels; call-end auto-stop (`stopAndDebrief` from `pollDetection`) must keep working.

---

### Task 1: `CallAlerting` seam + posting/clearing from detection

**Files:**
- Create: `Sources/DebriefApp/CallAlerts.swift` (protocol only in this task)
- Modify: `Sources/DebriefApp/AppEnvironment.swift`
- Test: `Tests/DebriefAppTests/AppEnvironmentTests.swift`

**Interfaces:**
- Consumes: `AppEnvironment.pollDetection(_:at:)`, `RecordingPhase`, existing `makeEnv(db:)` test helper in `AppEnvironmentTests`.
- Produces:
  - `protocol CallAlerting: AnyObject { func callDetected(); func clear() }`
  - `AppEnvironment.init(db:prompts:coaching:coordinator:alerts:)` — new trailing parameter `alerts: CallAlerting? = nil`.
  - Behavior: `.callLikelyStarted` while coordinator is `.idle` → `alerts?.callDetected()`; `.callLikelyEnded` → `alerts?.clear()` (always).

- [ ] **Step 1: Write the failing test**

Append to `Tests/DebriefAppTests/AppEnvironmentTests.swift` (inside the class a fake, at file scope is also fine — match the file's existing style of top-level fakes):

```swift
final class FakeAlerts: CallAlerting {
    var detectedCount = 0
    var clearCount = 0
    func callDetected() { detectedCount += 1 }
    func clear() { clearCount += 1 }
}
```

And the test method:

```swift
func testCallStartPostsAlertAndCallEndClearsIt() async throws {
    let db = try AppDatabase.inMemory()
    let alerts = FakeAlerts()
    let env = try makeEnv(db: db, alerts: alerts)
    let t0 = Date()

    // Call starts while idle → alert posted.
    await env.pollDetection(.init(micInUse: true, meetingAppRunning: true), at: t0)
    XCTAssertEqual(alerts.detectedCount, 1)
    XCTAssertEqual(alerts.clearCount, 0)

    // Call ends (mic free past the 10s confirmation) → alert cleared.
    await env.pollDetection(.init(micInUse: false, meetingAppRunning: true), at: t0.addingTimeInterval(60))
    await env.pollDetection(.init(micInUse: false, meetingAppRunning: true), at: t0.addingTimeInterval(71))
    XCTAssertEqual(alerts.clearCount, 1)
}
```

This requires extending the existing helper — change its signature to:

```swift
func makeEnv(db: AppDatabase, alerts: CallAlerting? = nil) throws -> AppEnvironment {
```

and its last line to:

```swift
return AppEnvironment(db: db, prompts: prompts, coaching: coaching, coordinator: coordinator, alerts: alerts)
```

(The two existing tests keep calling `makeEnv(db: db)` unchanged.)

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppEnvironmentTests 2>&1 | tail -20`
Expected: compile FAILURE — `cannot find type 'CallAlerting' in scope` (the protocol doesn't exist yet). A compile failure is this step's "red".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/DebriefApp/CallAlerts.swift`:

```swift
/// Seam over UNUserNotificationCenter so unit tests never construct it
/// (UNUserNotificationCenter.current() traps outside a bundled .app).
public protocol CallAlerting: AnyObject {
    func callDetected()
    func clear()
}
```

In `Sources/DebriefApp/AppEnvironment.swift`:

1. Add a stored property near `private var detector = CallDetector()`:

```swift
private let alerts: CallAlerting?
```

2. Extend `init` (existing parameters unchanged, new one last):

```swift
init(db: AppDatabase, prompts: PromptStore, coaching: CoachingService,
     coordinator: RecordingCoordinator, alerts: CallAlerting? = nil) {
    self.alerts = alerts
    // ...existing body unchanged...
```

3. In `pollDetection(_:at:)`, extend both event branches:

```swift
case .callLikelyStarted:
    callDetected = true
    if case .idle = coordinator.phase { alerts?.callDetected() }
case .callLikelyEnded:
    callDetected = false
    alerts?.clear()
    if case .recording = coordinator.phase { await stopAndDebrief() }
```

(The `.idle` guard keeps a mid-recording "call started" event — possible when the user started recording before joining the call — from popping a useless "Record?" notification.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AppEnvironmentTests 2>&1 | tail -20`
Expected: all AppEnvironmentTests PASS, including `testCallStartPostsAlertAndCallEndClearsIt`.

- [ ] **Step 5: Commit**

```bash
git add Sources/DebriefApp/CallAlerts.swift Sources/DebriefApp/AppEnvironment.swift Tests/DebriefAppTests/AppEnvironmentTests.swift
git commit -m "feat: post/clear call-detected alert from detection events"
```

---

### Task 2: Shared `startRecording()` wrapper that clears the alert

**Files:**
- Modify: `Sources/DebriefApp/AppEnvironment.swift` (next to `stopAndDebrief()`)
- Modify: `Sources/DebriefApp/MenuBarView.swift` (the `Start recording` button)
- Modify: `Sources/DebriefApp/MainWindow.swift` (the `Start recording` button)
- Test: `Tests/DebriefAppTests/AppEnvironmentTests.swift`

**Interfaces:**
- Consumes: `CallAlerting` and the `alerts` property from Task 1; `RecordingCoordinator.startRecording()`.
- Produces: `AppEnvironment.startRecording() async` — the single start path for both buttons and (in Task 3) the notification action.

- [ ] **Step 1: Write the failing test**

Append to `Tests/DebriefAppTests/AppEnvironmentTests.swift`:

```swift
func testStartRecordingClearsDeliveredAlert() async throws {
    let db = try AppDatabase.inMemory()
    let alerts = FakeAlerts()
    let env = try makeEnv(db: db, alerts: alerts)

    await env.pollDetection(.init(micInUse: true, meetingAppRunning: true), at: Date())
    XCTAssertEqual(alerts.detectedCount, 1)

    await env.startRecording()
    XCTAssertEqual(alerts.clearCount, 1, "starting a recording should clear the call-detected notification")
    guard case .recording = env.coordinator.phase else {
        return XCTFail("startRecording() should start the coordinator, got \(env.coordinator.phase)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppEnvironmentTests 2>&1 | tail -20`
Expected: compile FAILURE — `value of type 'AppEnvironment' has no member 'startRecording'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/DebriefApp/AppEnvironment.swift`, next to `stopAndDebrief()`:

```swift
/// Single start path shared by the two Record buttons and the notification's
/// Record action; clears the call-detected notification so it can't be
/// clicked again mid-recording.
func startRecording() async {
    alerts?.clear()
    await coordinator.startRecording()
}
```

In `Sources/DebriefApp/MenuBarView.swift`, change the start button's action:

```swift
Button {
    Task { await env.startRecording() }
} label: {
    Label(env.callDetected ? "Record this call" : "Start recording",
          systemImage: "record.circle")
}
```

In `Sources/DebriefApp/MainWindow.swift`, same change:

```swift
Button {
    Task { await env.startRecording() }
} label: {
    Label(env.callDetected ? "Record this call" : "Start recording", systemImage: "record.circle")
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test 2>&1 | grep -E "Executed.*tests|failed" | tail -5`
Expected: full suite PASS (run the whole suite here — the view files changed).

- [ ] **Step 5: Commit**

```bash
git add Sources/DebriefApp/AppEnvironment.swift Sources/DebriefApp/MenuBarView.swift Sources/DebriefApp/MainWindow.swift Tests/DebriefAppTests/AppEnvironmentTests.swift
git commit -m "feat: route all recording starts through env.startRecording, clearing the alert"
```

---

### Task 3: Real `CallAlerts` on UNUserNotificationCenter + wiring + docs

**Files:**
- Modify: `Sources/DebriefApp/CallAlerts.swift` (add the concrete class)
- Modify: `Sources/DebriefApp/AppEnvironment.swift` (`live()` wiring)
- Modify: `docs/manual-test-checklist.md` (items 1 and 2)
- Modify: `docs/superpowers/specs/2026-07-02-interview-note-taker-design.md` (permissions line)

**Interfaces:**
- Consumes: `CallAlerting` (Task 1), `AppEnvironment.startRecording()` (Task 2).
- Produces: `final class CallAlerts: NSObject, CallAlerting, UNUserNotificationCenterDelegate` with `var onRecord: (@MainActor () -> Void)?`.

No unit test: this class is a thin adapter over `UNUserNotificationCenter`, which cannot run under `swift test` (no bundle). Verification is the manual checklist step added below, plus the full suite staying green.

- [ ] **Step 1: Implement `CallAlerts`**

Append to `Sources/DebriefApp/CallAlerts.swift`:

```swift
import UserNotifications

/// Real notification adapter. Constructed only from AppEnvironment.live()
/// (never in tests — see protocol doc comment).
final class CallAlerts: NSObject, CallAlerting, UNUserNotificationCenterDelegate {
    static let recordActionID = "record"
    static let categoryID = "call-detected"
    static let requestID = "call-detected"

    /// Set by live() to route the notification's Record action into
    /// AppEnvironment.startRecording() on the main actor.
    var onRecord: (@MainActor () -> Void)?

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(identifier: Self.recordActionID, title: "Record",
                                          options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [record],
                                   intentIdentifiers: [], options: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func callDetected() {
        let content = UNMutableNotificationContent()
        content.title = "Call detected"
        content.body = "Record this call with Debrief?"
        content.sound = .default  // authorization/willPresent request sound, but it only plays if set on the content
        content.categoryIdentifier = Self.categoryID
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: Self.requestID, content: content, trigger: nil))
    }

    func clear() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.requestID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestID])
    }

    // Show the banner even though a menu-bar (LSUIElement) app counts as
    // "foreground" — without this the notification is silently swallowed.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        // Explicit Record button only. The default body click just dismisses:
        // "never auto-records" means an ambiguous click must not start capture.
        guard response.actionIdentifier == Self.recordActionID else { return }
        await MainActor.run { self.onRecord?() }
    }
}
```

- [ ] **Step 2: Wire into `AppEnvironment.live()`**

In `Sources/DebriefApp/AppEnvironment.swift`, inside `live()`, replace the return with:

```swift
let alerts = CallAlerts()
let env = AppEnvironment(db: db, prompts: prompts, coaching: coaching,
                         coordinator: coordinator, alerts: alerts)
alerts.onRecord = { [weak env] in
    guard let env else { return }
    Task { await env.startRecording() }
}
return env
```

- [ ] **Step 3: Build and run the full suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | grep -E "Executed.*tests|failed" | tail -5`
Expected: `Build complete!` and full suite PASS (nothing constructs `CallAlerts` under test).

- [ ] **Step 4: Update the docs (checklist + spec permissions line)**

In `docs/superpowers/specs/2026-07-02-interview-note-taker-design.md`, the Capture section says:

```markdown
Permissions required: Microphone, Screen Recording. Nothing else. The OS prompts for each on first use; Settings has deep-links to both System Settings panes.
```

Replace with:

```markdown
Permissions required: Microphone, Screen Recording, and Notifications (for the call-detected Record pop-up; the app works without it). The OS prompts for each on first use; Settings has deep-links to the Microphone and Screen Recording panes.
```

In `docs/manual-test-checklist.md`, item 1 (Permissions) — replace:

```markdown
1. **Permissions**: first launch prompts for Microphone; starting a recording prompts for
   Screen Recording (grant in System Settings, relaunch).
```

with:

```markdown
1. **Permissions**: first launch prompts for Microphone and Notifications; starting a
   recording prompts for Screen Recording (grant in System Settings, relaunch).
```

Then extend item 2 (Detection) — replace:

```markdown
2. **Detection**: start a test meeting (meet.google.com in a browser, mic on). Within ~15s
   the menu-bar icon becomes a phone and the popover shows "Call detected".
```

with:

```markdown
2. **Detection**: start a test meeting (meet.google.com in a browser, mic on). Within ~15s
   the menu-bar icon becomes a phone, the popover shows "Call detected", and a
   notification pops up (first run: grant the notification permission prompt). Clicking
   the notification's **Record** button starts recording; clicking the notification body
   does NOT. Leaving the meeting without recording clears the notification.
```

- [ ] **Step 5: Commit**

```bash
git add Sources/DebriefApp/CallAlerts.swift Sources/DebriefApp/AppEnvironment.swift docs/manual-test-checklist.md
git commit -m "feat: call-detected notification with one-click Record action"
```
