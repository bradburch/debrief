import SwiftUI
import Store

struct MenuBarView: View {
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    /// Ceiling on the scrolling part of the popover. Two recovery prompts plus a handful of
    /// finalize jobs already exceed a short display's usable height, and everything below
    /// this frame — including Quit — used to be pushed off-screen with no way to reach it.
    private static let maxScrollHeight: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Recording state and finalize jobs are stacked, not switched between: starting
            // the next interview while the last one is still being debriefed is the whole
            // point. Both are unbounded (n recovery prompts, n jobs, multi-line failures),
            // so they are the part that scrolls.
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if case .recording(let started) = env.coordinator.recordingPhase {
                        recordingSection(started: started)
                    } else {
                        idleSection
                    }
                    if !env.coordinator.finalizeJobs.isEmpty {
                        Divider()
                        FinalizeJobsSection()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.maxScrollHeight)
            // Outside the ScrollView on purpose: these two must stay reachable no matter how
            // much state is above them.
            Divider()
            Button("Open Debrief") { AppDelegate.focusMainWindow() }
            // Routed through applicationShouldTerminate (see AppDelegate), which is what
            // asks before abandoning an unfinished debrief.
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 280)
        // The popover is a MenuBarExtra window, not a view in the main window's scene, so it
        // is a valid place to arm the opener for a Dock click that lands before the main
        // window has ever appeared.
        .onAppear { AppDelegate.openMainWindow = { openWindow(id: "main") } }
    }

    @ViewBuilder
    private var idleSection: some View {
        if !env.recoverableSessions.isEmpty {
            ForEach(env.recoverableSessions, id: \.self) { dir in
                RecoveryPrompt(dir: dir)
            }
            Divider()
        }
        if case .failed(let message) = env.coordinator.recordingPhase {
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).font(.caption).lineLimit(4)
        }
        if env.callDetected {
            Label("Call detected", systemImage: "phone.fill").foregroundStyle(.orange)
        }
        Button {
            Task { await env.startRecording() }
        } label: {
            Label(env.callDetected ? "Record this call" : "Start recording",
                  systemImage: "record.circle")
        }
        // The sheet itself is presented by MainWindow: a MenuBarExtra window can't present
        // one, so this sets the draft and brings up the window that can.
        Button {
            env.planningCall = PlannedCallDraft()
            AppDelegate.focusMainWindow()
        } label: {
            Label("Plan a call…", systemImage: "calendar.badge.plus")
        }
        if !env.plannedCalls.isEmpty {
            Text("\(env.plannedCalls.count) planned call\(env.plannedCalls.count == 1 ? "" : "s") — pre-fill from the form after you start.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func recordingSection(started: Date) -> some View {
        Label("Recording \(started, style: .timer)", systemImage: "record.circle.fill")
            .foregroundStyle(.red)
        LevelRow(label: "You", level: env.coordinator.micLevel)
        LevelRow(label: "Them", level: env.coordinator.systemLevel)
        if let warning = env.coordinator.streamWarning {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow).font(.caption)
        }
        if let p = env.coordinator.transcribeProgress, p.total > 0 {
            Text("Transcribed \(p.done)/\(p.total) chunks")
                .font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        RecordingControls(axis: .vertical)
    }
}

struct LevelRow: View {
    let label: String
    let level: Float
    var body: some View {
        HStack {
            Text(label).font(.caption).frame(width: 40, alignment: .leading)
            ProgressView(value: min(Double(level) * 4, 1.0))  // RMS is small; scale for visibility
        }
    }
}
