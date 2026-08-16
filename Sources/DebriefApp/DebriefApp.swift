import SwiftUI
import AppKit

@main
struct DebriefApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var env = AppEnvironment.live()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environmentObject(env)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Window("Debrief", id: "main") {
            MainWindow().environmentObject(env)
        }
        // Only a default: WindowFrameAutosave hands the NSWindow to AppKit's frame
        // autosave, so after the first launch the user's own size and position win.
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
    /// outside one. Whichever view is alive registers the action here. `MainWindow` does it
    /// on appear, so it is armed from launch: with no `LSUIElement` the Window scene opens
    /// at launch rather than starting the app at zero windows.
    @MainActor static var openMainWindow: (() -> Void)?

    /// Bring the main window up and focused, creating it if the user closed it.
    ///
    /// The `async` hop is load-bearing: `openWindow` creates the NSWindow asynchronously, so
    /// activating in the same turn races it and can leave a brand-new window unfocused.
    @MainActor
    static func focusMainWindow() {
        openMainWindow?()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil)
        }
    }

    /// A Dock click. `hasVisibleWindows` is false in the case that matters — the user closed
    /// the window and came back to the Dock icon — and AppKit's default handling has nothing
    /// to reopen, since the window belongs to a SwiftUI scene. Returning false says "handled".
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Self.focusMainWindow()
        return false
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
