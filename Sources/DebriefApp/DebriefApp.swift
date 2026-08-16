import SwiftUI
import AppKit
import OSLog

@main
struct DebriefApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var env = AppEnvironment.live()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environmentObject(env)
        } label: {
            MenuBarLabel(symbol: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Window("Debrief", id: "main") {
            MainWindow().environmentObject(env)
        }
        // First launch only. A `Window` scene already persists its own frame (measured:
        // under the `NSWindow Frame main` default, restored without any help), so this is
        // the size a fresh install opens at and nothing more — the user's own size wins
        // from then on. An AppKit frame-autosave shim here is not just redundant, it
        // writes a second, competing record.
        .defaultSize(width: 1100, height: 700)
    }

    /// Recording and finalizing are concurrent states now, so one symbol has to stand for
    /// both. Recording wins — it is the state where doing the wrong thing loses audio — and
    /// running jobs surface as the hourglass whenever nothing is being recorded. The popover
    /// lists the jobs themselves either way.
    /// Order is deliberate: a failed *start* outranks a running job, because it means nothing
    /// is being captured right now and the user has to act. Hiding it behind an hourglass
    /// reads as "busy, all fine".
    private var menuBarSymbol: String {
        if case .recording = env.coordinator.recordingPhase { return "record.circle.fill" }
        if case .failed = env.coordinator.recordingPhase { return "exclamationmark.circle" }
        if env.coordinator.hasActiveJobs { return "hourglass.circle" }
        if env.coordinator.finalizeJobs.contains(where: { $0.failure != nil }) { return "exclamationmark.circle" }
        return env.callDetected ? "phone.circle.fill" : "waveform.circle"
    }
}

/// The menu-bar icon, and the one place `AppDelegate.openMainWindow` can be armed early
/// enough to be useful.
///
/// It exists as a named view rather than a bare `Image` for exactly that: the label is the
/// only part of the app's UI that is rendered from launch, whether or not the user has
/// opened the popover or the window, so its `onAppear` is the earliest hook that has
/// `openWindow` in scope.
private struct MenuBarLabel: View {
    let symbol: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .onAppear { AppDelegate.openMainWindow = { openWindow(id: "main") } }
    }
}

/// Two jobs, both of which have to happen outside SwiftUI:
///
/// 1. A finalize outlives the recording it came from, so quitting mid-job silently discards a
///    transcribed-but-unsaved interview. Every quit path (the popover's button, ⌘Q from the
///    main window, the Dock) funnels through `applicationShouldTerminate`, which is why this
///    is a delegate rather than a check on the button.
/// 2. Debrief has a Dock icon, and a Dock click on an app showing no windows arrives as
///    `applicationShouldHandleReopen` — again outside any view.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI builds the delegate before `AppEnvironment.live()` runs, so the environment
    /// registers itself here instead of being injected. Weak: the delegate must not keep the
    /// app graph alive.
    @MainActor static weak var environment: AppEnvironment?

    /// Opening a `Window(id:)` scene needs SwiftUI's `openWindow` action, which only exists
    /// inside a view — and both callers below (a Dock click, the popover's button) run
    /// outside one. `MenuBarLabel` registers it, and is deliberately the *only* registrar:
    /// it is the one view guaranteed to have appeared, because dropping `LSUIElement` does
    /// NOT make the `Window` scene open at launch (measured — the app still starts at zero
    /// windows) and the popover's content is built lazily on first click.
    ///
    /// `MainWindow` used to re-register on appear. That was strictly worse than nothing: it
    /// replaced a closure good for the life of the process with one captured from a scene
    /// that can be torn down, for no gain, since the label's copy is always valid.
    @MainActor static var openMainWindow: (() -> Void)?

    /// Bring the main window up and focused, creating it if the user closed it.
    ///
    /// The `async` hop is load-bearing: `openWindow` creates the NSWindow asynchronously, so
    /// activating in the same turn races it and can leave a brand-new window unfocused.
    @MainActor
    static func focusMainWindow() {
        if openMainWindow == nil {
            // Should be impossible — MenuBarLabel arms this at launch — but a silent no-op
            // here is exactly the bug that shipped in the first draft, so leave a trace
            // rather than a dead click.
            Logger(subsystem: "com.debrief.app", category: "app")
                .error("focusMainWindow with no opener registered — the main window cannot be created")
        }
        openMainWindow?()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
        }
    }

    /// A Dock click. `hasVisibleWindows` is false in the two cases that matter — the window
    /// was closed, or it is minimised — and our own handling only covers the first.
    ///
    /// So this returns **true**, not false: "handled" would suppress AppKit's default
    /// reopen, and that default is what deminiaturises a minimised window. Returning true
    /// keeps it, and `focusMainWindow` supplements it for the closed-window case, where
    /// AppKit has nothing to restore because the window belongs to a SwiftUI scene.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Self.focusMainWindow()
        return true
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator = Self.environment?.coordinator else { return .terminateNow }
        let pending = coordinator.finalizeJobs.filter { !$0.isFinished }
        guard !pending.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = pending.count == 1
            ? "Still finishing one debrief"
            : "Still finishing \(pending.count) debriefs"
        alert.informativeText = "Quitting now stops the transcript and debrief part-way. "
            + "The audio is kept, and Debrief offers to recover it on the next launch."
        alert.addButton(withTitle: "Wait")
        alert.addButton(withTitle: "Quit anyway")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
}
