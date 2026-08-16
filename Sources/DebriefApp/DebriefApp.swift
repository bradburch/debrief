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
    }

    /// Recording and finalizing are concurrent states now, so one symbol has to stand for
    /// both. Recording wins — it is the state where doing the wrong thing loses audio — and
    /// running jobs surface as the hourglass whenever nothing is being recorded. The popover
    /// lists the jobs themselves either way.
    private var menuBarSymbol: String {
        if case .recording = env.coordinator.recordingPhase { return "record.circle.fill" }
        if env.coordinator.hasActiveJobs { return "hourglass.circle" }
        if case .failed = env.coordinator.recordingPhase { return "exclamationmark.circle" }
        if env.coordinator.finalizeJobs.contains(where: { $0.failure != nil }) { return "exclamationmark.circle" }
        return env.callDetected ? "phone.circle.fill" : "waveform.circle"
    }
}

/// Exists for one reason: a finalize now outlives the recording it came from, so quitting
/// mid-job silently discards a transcribed-but-unsaved interview. Every quit path (the
/// popover's button, ⌘Q from the main window, the Dock) funnels through
/// `applicationShouldTerminate`, which is why this is a delegate rather than a check on the
/// button.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI builds the delegate before `AppEnvironment.live()` runs, so the environment
    /// registers itself here instead of being injected. Weak: the delegate must not keep the
    /// app graph alive.
    @MainActor static weak var environment: AppEnvironment?

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
