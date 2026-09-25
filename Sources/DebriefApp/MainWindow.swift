import SwiftUI
import Store

// `Color.forScore` / `forAdvancement` live in DesignSystem.swift with the rest of the palette.

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
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
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
            VStack(spacing: 0) {
                HStack(spacing: Spacing.m) {
                    ProgressView().controlSize(.small)
                    Text(progress.total == 0
                         ? "Re-coaching debriefs…"
                         : "Re-coaching debrief \(min(progress.done + 1, progress.total)) of \(progress.total)…")
                        .font(.callout)
                    if progress.total > 0 {
                        ProgressView(value: Double(progress.done), total: Double(progress.total))
                            .progressViewStyle(.linear).controlSize(.small).frame(maxWidth: 180)
                    }
                    Spacer()
                    Button("Stop") { env.cancelRecoach() }.controlSize(.small)
                }
                .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
                Divider()
            }
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
                HStack(spacing: Spacing.m) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "record.circle.fill").symbolEffect(.pulse)
                        Text(started, style: .timer).monospacedDigit()
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                    .help("Recording — stop it from the bar below")
                    ToolbarMeter(label: "You", level: env.coordinator.micLevel)
                    ToolbarMeter(label: "Them", level: env.coordinator.systemLevel)
                }
                .padding(.horizontal, Spacing.s)
            } else {
                if env.callDetected {
                    StatusCapsule(text: "Call detected", color: .orange, systemImage: "phone.fill")
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
        HStack(spacing: Spacing.xs) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            LevelMeter(level: level, width: 56)  // same scaling as LevelRow — both use LevelMeter
                .accessibilityLabel("\(label) level")
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
        if isRecording || failure != nil || !env.coordinator.visibleFinalizeJobs.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if isRecording {
                    if let warning = env.coordinator.streamWarning {
                        InlineMessage(text: warning, kind: .warning)
                    }
                    // Shared with MenuBarView's popover form (RecordingControls.swift) so the
                    // two surfaces can't drift.
                    RecordingControls(axis: .horizontal)
                } else if let failure {
                    InlineMessage(text: failure, kind: .error, lineLimit: 3)
                }
                if !env.coordinator.visibleFinalizeJobs.isEmpty {
                    if isRecording || failure != nil { Divider() }
                    FinalizeJobsSection()
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
