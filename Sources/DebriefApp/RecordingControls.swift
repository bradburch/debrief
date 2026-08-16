import SwiftUI
import Store

/// The stop-form: optional "Pre-fill" menu (planned calls + calendar), Company/Round/Notes fields, and
/// the Stop & Debrief button. Shared by MenuBarView's narrow popover (stacked vertically)
/// and MainWindow's wide `RecordingBar` (laid out as a single row), so the two surfaces
/// cannot drift out of sync with each other — see AppEnvironment.upcoming/apply for why a
/// single array feeds both.
struct RecordingControls: View {
    @EnvironmentObject var env: AppEnvironment

    /// `.vertical` for the narrow menu-bar popover; `.horizontal` for the wide main window.
    let axis: Axis

    var body: some View {
        if axis == .vertical {
            VStack(alignment: .leading, spacing: 10) {
                prefillMenu
                TextField("Company", text: $env.recordCompany)
                roundPicker
                TextField("Notes (optional)", text: $env.recordNotes)
                criteriaNote
                stopButton
            }
        } else {
            HStack {
                prefillMenu
                TextField("Company", text: $env.recordCompany).frame(maxWidth: 200)
                roundPicker.frame(maxWidth: 220)
                TextField("Notes (optional)", text: $env.recordNotes)
                criteriaNote
                stopButton
            }
        }
    }

    /// Planned calls and calendar entries in one menu — `PrefillMenu` renders nothing when
    /// both are empty, which is the normal case.
    private var prefillMenu: some View {
        PrefillMenu(onPlanned: { env.apply($0) }, onCalendar: { env.apply($0) })
    }

    /// The criteria are not editable here (there is no room in either surface, and they were
    /// written when the call was planned), but they must be visible: they change how this
    /// interview is graded, and silently carried state is how a wrong rubric goes unnoticed.
    /// Editable per session in the debrief pane afterwards, as before.
    @ViewBuilder private var criteriaNote: some View {
        if !env.recordCriteria.isEmpty {
            Label("Grading criteria applied", systemImage: "text.badge.checkmark")
                .font(.caption).foregroundStyle(.secondary)
                .help(env.recordCriteria)
        }
    }

    private var roundPicker: some View {
        Picker("Round", selection: $env.recordRoundType) {
            ForEach(env.prompts.availableRoundTypes(), id: \.self) { Text($0.displayName).tag($0) }
        }
    }

    private var stopButton: some View {
        Button("Stop & Debrief") {
            Task { await env.stopAndDebrief() }
        }
    }
}
