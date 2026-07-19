import SwiftUI
import Store

/// The stop-form: optional "From calendar" pre-fill menu, Company/Round/Notes fields, and
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
                calendarMenu
                TextField("Company", text: $env.recordCompany)
                roundPicker
                TextField("Notes (optional)", text: $env.recordNotes)
                stopButton
            }
        } else {
            HStack {
                calendarMenu
                TextField("Company", text: $env.recordCompany).frame(maxWidth: 200)
                roundPicker.frame(maxWidth: 220)
                TextField("Notes (optional)", text: $env.recordNotes)
                stopButton
            }
        }
    }

    @ViewBuilder private var calendarMenu: some View {
        if !env.upcoming.isEmpty {
            Menu("From calendar") {
                ForEach(env.upcoming, id: \.self) { item in
                    Button {
                        env.apply(item)
                    } label: {
                        // Text(verbatim:) for the company: Button("\(...)") builds a
                        // LocalizedStringKey, so a company name containing "%" would be
                        // parsed as a format specifier. Concatenated Text keeps the
                        // `.time` style on the date portion.
                        Text(verbatim: item.company) + Text(" — ") + Text(item.start, style: .time)
                    }
                }
            }
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
