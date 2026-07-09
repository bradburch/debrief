import SwiftUI

@main
struct DebriefApp: App {
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

    private var menuBarSymbol: String {
        switch env.coordinator.phase {
        case .recording: return "record.circle.fill"
        case .finalizing: return "hourglass.circle"
        case .failed: return "exclamationmark.circle"
        case .idle: return env.callDetected ? "phone.circle.fill" : "waveform.circle"
        }
    }
}
