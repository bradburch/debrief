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

    /// Every text field is trimmed on the way to the row. Whitespace-only criteria are the
    /// case that matters: `assembleSystemPrompt` trims them away and appends nothing, so
    /// storing them non-empty would light a "Grading criteria applied" badge over a rubric
    /// the debrief never sees.
    var plannedCall: PlannedCall {
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return PlannedCall(id: planId, companyName: trim(companyName), role: trim(role),
                           roundType: roundType, scheduledDate: scheduledDate,
                           notes: trim(notes), customInstructions: trim(customInstructions))
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
        VStack(spacing: 0) {
            Form {
                Section {
                    CompanyField(text: $draft.companyName)
                    TextField("Role", text: $draft.role, prompt: Text("Optional"))
                    Picker("Round", selection: $draft.roundType) {
                        ForEach(roundTypes, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    DatePicker("Scheduled", selection: $draft.scheduledDate)
                    TextField("Notes", text: $draft.notes, prompt: Text("Optional"))
                } header: {
                    Text(draft.planId == nil ? "Plan a call" : "Edit planned call")
                        .font(.headline)
                }
                Section {
                    TextEditor(text: $draft.customInstructions)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 110)
                        .accessibilityLabel("Grading criteria")
                } header: {
                    Text("Grading criteria")
                } footer: {
                    // Entered before the call, so it reaches the first debrief — not only a re-run.
                    Text("A rubric or focus for this interview. Applied to its first debrief.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)   // Escape dismisses, as a sheet should
                Button("Save") {
                    env.savePlannedCall(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
            }
            .padding(Spacing.l)
        }
        .frame(width: 480)
        .frame(minHeight: 520)
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
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // "Plan a call" used to live here as an icon button. It is a Sessions-level
            // action, so it moved to the window toolbar — leaving this an ordinary list
            // header, which is also what lets SessionsView hide the whole section when
            // there is nothing upcoming.
            Text("Upcoming").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Spacing.xxs)
            ForEach(env.plannedCalls) { plan in
                Button { env.planningCall = PlannedCallDraft(plan) } label: {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: "calendar")
                            .foregroundStyle(.tint)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            // Text(verbatim:) so a company name containing "%" isn't parsed as a
                            // format specifier by LocalizedStringKey.
                            Text(verbatim: plan.companyName).font(.callout.weight(.medium))
                            Text("\(plan.roundType.displayName) · \(plan.scheduledDate.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Spacing.xs)
                    .padding(.horizontal, Spacing.s)
                    .background(Color.cardBackground,
                                in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit this planned call")
                .contextMenu {
                    Button { env.planningCall = PlannedCallDraft(plan) } label: {
                        Label("Edit…", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        if let id = plan.id { env.deletePlannedCall(id: id) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.m)
        // The refresh lives on SessionsView, not here: this section is conditional on the
        // list being non-empty, so an `onAppear` of its own would never run in the one state
        // that needs it.
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

    /// Renders nothing when there is nothing to offer — which is also why it carries no
    /// refresh of its own: an `.onAppear` on a view that resolves to no content is exactly
    /// the case SwiftUI may never invoke, and "no plans loaded yet" is that case. Whoever
    /// shows this menu refreshes first (`startRecording`, `RecoveryPrompt.onAppear`), on top
    /// of the refreshes at launch and after every save or delete.
    var body: some View {
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

    static func label(for plan: PlannedCall) -> Text {
        Text(verbatim: plan.companyName)
            + Text(" — \(plan.roundType.displayName) · ")
            + Text(plan.scheduledDate, style: .date)
    }
}
