import SwiftUI
import Store

/// One planned call being created or edited. `planId` is nil for a new plan; `id` is the
/// sheet's identity, not the row's — `.sheet(item:)` needs a fresh identity each time the
/// sheet is opened, including twice on the same row.
struct PlannedCallDraft: Identifiable, Equatable {
    let id = UUID()
    var planId: Int64?
    var companyName: String = ""
    var role: String = ""
    var roundType: RoundType = .behavioral
    var scheduledDate: Date = Date()
    var notes: String = ""
    var customInstructions: String = ""

    init() {}

    init(_ plan: PlannedCall) {
        planId = plan.id
        companyName = plan.companyName
        role = plan.role
        roundType = plan.roundType
        scheduledDate = plan.scheduledDate
        notes = plan.notes
        customInstructions = plan.customInstructions
    }

    var plannedCall: PlannedCall {
        PlannedCall(id: planId,
                    companyName: companyName.trimmingCharacters(in: .whitespacesAndNewlines),
                    role: role, roundType: roundType, scheduledDate: scheduledDate,
                    notes: notes, customInstructions: customInstructions)
    }

    /// A plan is only useful if it names a company — that's what the pre-fill is for.
    var isValid: Bool { !companyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The "Plan a call" sheet. Presented by MainWindow off `env.planningCall`, so both entry
/// points (the Sessions sidebar and the menu-bar popover) open the same one.
struct PlannedCallEditor: View {
    @EnvironmentObject var env: AppEnvironment
    @State var draft: PlannedCallDraft
    @Environment(\.dismiss) private var dismiss
    @State private var roundTypes: [RoundType] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.planId == nil ? "Plan a call" : "Edit planned call").font(.headline)
            Form {
                TextField("Company", text: $draft.companyName)
                TextField("Role (optional)", text: $draft.role)
                Picker("Round", selection: $draft.roundType) {
                    ForEach(roundTypes, id: \.self) { Text($0.displayName).tag($0) }
                }
                DatePicker("Scheduled", selection: $draft.scheduledDate)
                TextField("Notes (optional)", text: $draft.notes)
            }
            Text("Grading criteria").font(.subheadline)
            TextEditor(text: $draft.customInstructions)
                .font(.callout)
                .frame(minWidth: 420, minHeight: 110)
                .border(.separator)
            Text("Paste a rubric or focus for this interview. Because it's entered before the call, it reaches the first debrief — not only a re-run.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    env.savePlannedCall(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
            }
        }
        .padding()
        .onAppear {
            roundTypes = env.prompts.availableRoundTypes()
            // The Picker binds by tag, so a draft carrying a type whose overlay was deleted
            // would render a blank control — same reason AppEnvironment.apply gates the
            // calendar's round type.
            if !roundTypes.contains(draft.roundType), let first = roundTypes.first {
                draft.roundType = first
            }
        }
    }
}

/// The small upcoming list above the session list: planned calls, soonest first, plus the
/// entry point for making one. Click a row to edit it, right-click to delete.
struct PlannedCallsSection: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Upcoming").font(.caption).bold().foregroundStyle(.secondary)
                Spacer()
                Button { env.planningCall = PlannedCallDraft() } label: {
                    Label("Plan a call", systemImage: "calendar.badge.plus")
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Plan a call")
            }
            ForEach(env.plannedCalls) { plan in
                Button { env.planningCall = PlannedCallDraft(plan) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        // Text(verbatim:) so a company name containing "%" isn't parsed as a
                        // format specifier by LocalizedStringKey.
                        Text(verbatim: plan.companyName)
                        Text("\(plan.roundType.displayName) · \(plan.scheduledDate.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Edit…") { env.planningCall = PlannedCallDraft(plan) }
                    Button("Delete", role: .destructive) {
                        if let id = plan.id { env.deletePlannedCall(id: id) }
                    }
                }
            }
        }
        .padding(8)
        .onAppear { env.refreshPlannedCalls() }
    }
}

/// The pre-fill menu, shared by the stop-form and the crash-recovery prompt. Planned calls
/// come first (they carry grading criteria; calendar entries don't), then calendar events.
///
/// Parameterized by two closures rather than writing to `AppEnvironment` directly: the
/// recovery prompt fills its own local fields, and a crashed planned call losing its
/// annotations is exactly the case this menu exists to cover.
struct PrefillMenu: View {
    @EnvironmentObject var env: AppEnvironment
    let onPlanned: (PlannedCall) -> Void
    let onCalendar: (UpcomingInterview) -> Void

    var body: some View {
        // The refresh hangs off a Group wrapping the `if`, not off the Menu inside it: on the
        // Menu it would never run in the one state that needs it — no plans loaded yet means
        // no Menu, so nothing appears, so nothing refreshes, so no Menu.
        Group {
            if !env.plannedCalls.isEmpty || !env.upcoming.isEmpty {
                Menu("Pre-fill") {
                    ForEach(env.plannedCalls) { plan in
                        Button { onPlanned(plan) } label: { Self.label(for: plan) }
                    }
                    if !env.plannedCalls.isEmpty, !env.upcoming.isEmpty { Divider() }
                    ForEach(env.upcoming, id: \.self) { item in
                        Button { onCalendar(item) } label: {
                            Text(verbatim: item.company) + Text(" — ") + Text(item.start, style: .time)
                        }
                    }
                }
            }
        }
        // Cheap single-table read, and the only thing that keeps the crash-recovery prompt's
        // menu current — that surface never runs startRecording's refresh.
        .onAppear { env.refreshPlannedCalls() }
    }

    static func label(for plan: PlannedCall) -> Text {
        Text(verbatim: plan.companyName)
            + Text(" — \(plan.roundType.displayName) · ")
            + Text(plan.scheduledDate, style: .date)
    }
}
