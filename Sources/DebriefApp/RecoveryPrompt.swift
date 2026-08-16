import SwiftUI
import Store
import CaptureKit

/// Shown in the menu-bar popover when a previous launch left orphaned recording
/// directories on disk (e.g. the app was `kill -9`'d mid-call). Offers to
/// re-transcribe the salvaged chunks into a session, or discard them.
struct RecoveryPrompt: View {
    @EnvironmentObject var env: AppEnvironment
    let dir: URL

    @State private var company = ""
    @State private var roundType: RoundType = .behavioral
    @State private var notes = ""
    /// Carried, not edited: a crashed call's plan still holds the grading criteria it was
    /// scheduled with, and a recovered session is inserted exactly once — criteria that
    /// don't come along here reach the debrief only on a re-coach.
    @State private var criteria = ""
    @State private var plannedCallId: Int64?
    @State private var isRecovering = false

    private var manifestDate: Date? { RecordingStore.readManifest(in: dir)?.startedAt }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let date = manifestDate {
                Label("Unsaved recording from \(date, style: .relative) ago", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow).font(.caption)
            } else {
                Label("Unsaved recording found", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow).font(.caption)
            }
            // The same menu the stop-form offers. Without it, a crash costs the planned
            // call's round type, notes and grading criteria — the annotations are only
            // recoverable by retyping them.
            PrefillMenu(onPlanned: applyPlan, onCalendar: applyCalendar)
            TextField("Company", text: $company)
            Picker("Round", selection: $roundType) {
                ForEach(env.prompts.availableRoundTypes(), id: \.self) { Text($0.displayName).tag($0) }
            }
            // The same latch as the stop-form, and the same undo: here criteria and the plan
            // claim are set at apply and otherwise released only by recovering or discarding.
            if !criteria.isEmpty {
                HStack(spacing: 2) {
                    Label("Grading criteria applied", systemImage: "text.badge.checkmark")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        criteria = ""
                        plannedCallId = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Don't apply these criteria, and keep the planned call")
                }
                .help(criteria)
            }
            HStack {
                // Discarding throws away audio that cannot be re-recorded — say so with the
                // role. Recover stays an ordinary button: the popover may stack several of
                // these above a prominent "Start recording", and a column of blue buttons
                // makes none of them read as the primary action.
                Button("Discard", role: .destructive) { env.discard(dir) }
                Spacer()
                Button("Recover") {
                    isRecovering = true
                    Task {
                        let name = company.isEmpty ? "Unknown" : company
                        await env.recover(dir,
                                          metadata: .init(company: name, roundType: roundType,
                                                          notes: notes, customInstructions: criteria),
                                          plannedCallId: plannedCallId)
                        isRecovering = false
                    }
                }
                .disabled(isRecovering)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.1)))
        // This surface never runs startRecording's refresh, and it is the one that shows up
        // after a crash — when the plan for the crashed call is exactly what's needed.
        .onAppear { env.refreshPlannedCalls() }
    }

    private func applyPlan(_ plan: PlannedCall) {
        company = plan.companyName
        roundType = plan.roundType
        notes = AppEnvironment.contextNotes(role: plan.role, notes: plan.notes)
        criteria = plan.customInstructions
        plannedCallId = plan.id
    }

    private func applyCalendar(_ item: UpcomingInterview) {
        company = item.company
        notes = item.notes ?? ""
        criteria = ""
        plannedCallId = nil
        if let raw = item.roundType {
            let candidate = RoundType(rawValue: raw)
            // Gated for the same reason as AppEnvironment.apply: the Picker binds by tag.
            if env.prompts.availableRoundTypes().contains(candidate) { roundType = candidate }
        }
    }
}
