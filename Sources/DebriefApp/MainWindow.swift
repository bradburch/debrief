import SwiftUI
import Store

extension Color {
    /// Debrief's score-quality scale, shared by the Sessions list and Pipeline cells.
    static func forScore(_ score: Double) -> Color {
        score >= 3.5 ? .green : score >= 2.5 ? .orange : .red
    }

    /// The verdict's scale. Distinct from forScore because this is an ordinal call, not a
    /// threshold on a number — the two leans are deliberately different shades so a
    /// borderline result never reads as a clean pass or a clean reject.
    static func forAdvancement(_ a: Advancement) -> Color {
        switch a {
        case .strongYes: return .green
        case .leanYes: return .mint
        case .leanNo: return .orange
        case .strongNo: return .red
        }
    }
}

enum MainTab: String, CaseIterable {
    case sessions = "Sessions", pipeline = "Pipeline", trends = "Trends", settings = "Settings"
    var symbol: String {
        switch self {
        case .sessions: return "list.bullet.rectangle"
        case .pipeline: return "building.2"
        case .trends: return "chart.line.uptrend.xyaxis"
        case .settings: return "gearshape"
        }
    }
}

struct MainWindow: View {
    // Tab selection lives on AppEnvironment so other views can navigate here (Pipeline →
    // a session). Was @State; nothing else could reach it.
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        NavigationSplitView {
            List(MainTab.allCases, id: \.self, selection: $env.selectedTab) { t in
                Label(t.rawValue, systemImage: t.symbol).tag(t)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            VStack(spacing: 0) {
                RecordingBar()
                RecoachBar()
                switch env.selectedTab ?? .sessions {
                case .sessions: SessionsView()
                case .pipeline: PipelineView()
                case .trends: TrendsView()
                case .settings: SettingsView()
                }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .toolbar { RecordingToolbarItems(env: env) }
        // Presented here, not in the views that open it: the menu-bar popover is a
        // MenuBarExtra window and can't reliably present a sheet of its own, so its
        // "Plan a call" opens this window and sets the same draft.
        .sheet(item: $env.planningCall) { draft in
            PlannedCallEditor(draft: draft)
        }
    }
}


/// A re-run takes ~30s per session and outlives the Settings tab, so its progress is shown
/// app-wide rather than only where it was started. Absent unless a run is in flight.
struct RecoachBar: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        if let progress = env.recoachProgress {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress.total == 0
                     ? "Re-coaching debriefs…"
                     : "Re-coaching debrief \(min(progress.done + 1, progress.total)) of \(progress.total)…")
                    .font(.caption)
                if progress.total > 0 {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                        .progressViewStyle(.linear).frame(maxWidth: 160)
                }
                Spacer()
                Button("Stop") { env.cancelRecoach() }.controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
        }
    }
}

/// Recording status in the window toolbar, where it stays visible whichever tab is open:
/// the idle primary action, or the live timer and both meters. The stop-form needs more room
/// than a toolbar has, so it stays in `RecordingBar` below.
struct RecordingToolbarItems: ToolbarContent {
    @ObservedObject var env: AppEnvironment

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if case .recording(let started) = env.coordinator.recordingPhase {
                Label {
                    Text(started, style: .timer).monospacedDigit()
                } icon: {
                    Image(systemName: "record.circle.fill")
                }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.red)
                .help("Recording — stop it from the bar below")
                ToolbarMeter(label: "You", level: env.coordinator.micLevel)
                ToolbarMeter(label: "Them", level: env.coordinator.systemLevel)
            } else {
                if env.callDetected {
                    Label("Call detected", systemImage: "phone.fill")
                        .labelStyle(.titleAndIcon).foregroundStyle(.orange)
                }
                Button {
                    Task { await env.startRecording() }
                } label: {
                    Label(env.callDetected ? "Record this call" : "Start recording",
                          systemImage: "record.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)   // the one thing to do while idle
                .tint(.red)
            }
        }
    }
}

private struct ToolbarMeter: View {
    let label: String
    let level: Float
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption)
            ProgressView(value: min(Double(level) * 4, 1.0))  // same scaling as LevelRow
                .frame(width: 60)
        }
        .help("\(label) input level")
    }
}

/// What doesn't fit in the toolbar: the stop-form and stream warning while recording, a
/// failed start, and finalize jobs. Renders nothing when none of those apply.
struct RecordingBar: View {
    @EnvironmentObject var env: AppEnvironment

    private var isRecording: Bool {
        if case .recording = env.coordinator.recordingPhase { return true }
        return false
    }
    private var failure: String? {
        if case .failed(let message) = env.coordinator.recordingPhase { return message }
        return nil
    }

    var body: some View {
        if isRecording || failure != nil || !env.coordinator.finalizeJobs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if isRecording {
                    if let warning = env.coordinator.streamWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow).font(.caption)
                    }
                    // Shared with MenuBarView's popover form (RecordingControls.swift) so the
                    // two surfaces can't drift.
                    RecordingControls(axis: .horizontal)
                } else if let failure {
                    Label(failure, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red).font(.caption).lineLimit(3)
                }
                if !env.coordinator.finalizeJobs.isEmpty {
                    if isRecording || failure != nil { Divider() }
                    FinalizeJobsSection()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}
