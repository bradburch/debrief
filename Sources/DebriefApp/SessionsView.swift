import SwiftUI
import Store
import CoachingEngine

struct SessionsView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var rows: [(session: InterviewSession, companyName: String, overallScore: Double?, advancement: Advancement?)] = []
    @State private var selection: Set<Int64> = []
    @State private var confirmingDelete = false
    @State private var filterText = ""
    /// Set when arriving from Pipeline; the List scrolls to it and clears it.
    @State private var scrollToSession: Int64?

    private var filteredRows: [(session: InterviewSession, companyName: String, overallScore: Double?, advancement: Advancement?)] {
        let q = filterText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return rows }
        return rows.filter { $0.companyName.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                // Planned calls are not sessions and never appear in the list below — they
                // live in their own table precisely so they can't show up as zero-minute
                // rows here or in Pipeline/Trends.
                if !env.plannedCalls.isEmpty {
                    PlannedCallsSection()
                    Divider()
                }
                if rows.isEmpty {
                    ContentUnavailableView(
                        "No sessions yet",
                        systemImage: "waveform",
                        description: Text("Click Record in the menu bar when a call starts."))
                } else {
                    if filteredRows.isEmpty {
                        ContentUnavailableView.search(text: filterText)
                    } else {
                        ScrollViewReader { proxy in
                        List(selection: $selection) {
                            ForEach(filteredRows, id: \.session.id) { row in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(row.companyName).bold()
                                        Spacer()
                                        ScoreBadge(advancement: row.advancement,
                                                   overallScore: row.overallScore)
                                        // Show the badge whenever coaching isn't complete, not
                                        // just when there's no score: a re-coach that fails on
                                        // an already-complete session leaves the stale feedback
                                        // row behind, so keying on `overallScore == nil` hid
                                        // the failure entirely and showed the old score as if
                                        // it were fresh.
                                        if row.session.coachingStatus != .complete {
                                            statusBadge(row.session.coachingStatus)
                                        }
                                    }
                                    Text("\(row.session.roundType.displayName) · \(row.session.date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .tag(row.session.id!)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        // If the right-clicked row isn't in the current multi-selection,
                                        // act on just that row (standard Finder behavior).
                                        if !selection.contains(row.session.id!) { selection = [row.session.id!] }
                                        confirmingDelete = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .onDeleteCommand { if !selection.isEmpty { confirmingDelete = true } }
                        .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
                            Button("Delete", role: .destructive, action: deleteSelected)
                            Button("Cancel", role: .cancel) {}
                        }
                        // `task(id:)`, not `onChange`: this List only exists once `rows` is
                        // non-empty, so on a Pipeline reveal it is built AFTER
                        // revealPendingSession() already set scrollToSession — an onChange
                        // installed here would never observe a change and never fire.
                        // task(id:) runs on appear too, which is the case that matters.
                        .task(id: scrollToSession) {
                            guard let target = scrollToSession else { return }
                            proxy.scrollTo(target, anchor: .center)
                            scrollToSession = nil
                        }
                        }
                    }
                }
            }
            .frame(minWidth: 260, maxWidth: 340)
            // Drop any selected ids no longer visible, so a hidden-but-selected row can't be
            // bulk-deleted and the detail pane can't dangle. Keyed on the visible id list, so
            // it fires both when the filter changes and when rows change (e.g. a rename →
            // reload that filters a selected row out without touching filterText).
            .onChange(of: filteredRows.map { $0.session.id! }) {
                selection.formIntersection(Set(filteredRows.map { $0.session.id! }))
            }

            if selection.count == 1, let id = selection.first {
                SessionDetailView(sessionId: id, onRenamed: reload).id(id)
            } else {
                Text(selection.isEmpty ? "Select a session" : "\(selection.count) sessions selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            reload()
            revealPendingSession()
            // Owned here, not by PlannedCallsSection: that section renders nothing when the
            // list is empty, and a view that resolves to no content is exactly the one
            // SwiftUI may never call `onAppear` on — so the refresh that would populate it
            // would never run. Same trap `PrefillMenu` documents.
            env.refreshPlannedCalls()
        }
        // A finalize no longer ends by returning the coordinator to .idle — it ends on its
        // own job, and the next recording may already be running. The completion counter is
        // the signal that a session may have appeared (or failed to).
        .onReceive(env.coordinator.$finalizeCompletions) { _ in reload() }
        // Replaces a hand-rolled TextField in the sidebar. Same filter, standard place: the
        // search field belongs in the window's toolbar on macOS, not stacked above the list.
        .searchable(text: $filterText, prompt: "Filter by company")
        .toolbar {
            ToolbarItem {
                Button { env.planningCall = PlannedCallDraft() } label: {
                    Label("Plan a call", systemImage: "calendar.badge.plus")
                }
                .help("Plan an upcoming interview so its criteria reach the first debrief")
            }
        }
    }

    private func reload() { rows = (try? env.db.allSessionSummaries()) ?? [] }

    /// Selects the session Pipeline asked for. MUST run after `reload()`: the
    /// `onChange(of: filteredRows…)` above intersects `selection` with the visible rows, so
    /// selecting against a still-empty `rows` would be wiped the moment they load.
    private func revealPendingSession() {
        guard let id = env.sessionToReveal else { return }
        env.sessionToReveal = nil
        guard rows.contains(where: { $0.session.id == id }) else { return }
        selection = [id]
        scrollToSession = id
    }

    private var deleteTitle: String {
        selection.count == 1 ? "Delete this session? This can’t be undone."
                             : "Delete \(selection.count) sessions? This can’t be undone."
    }

    private func deleteSelected() {
        for id in selection { try? env.db.deleteSession(id: id) }
        selection = []
        reload()
    }

    @ViewBuilder
    private func statusBadge(_ status: CoachingStatus) -> some View {
        switch status {
        case .pending: Text("Queued").font(.caption2).foregroundStyle(.secondary)
        case .running: Text("Writing…").font(.caption2).foregroundStyle(.secondary)
        case .failed: Text("Failed").font(.caption2).foregroundStyle(.red)
        // Not a shortfall: a transcript-only round is finished when it's transcribed.
        case .skipped: Text("Transcript only").font(.caption2).foregroundStyle(.secondary)
        case .complete: EmptyView()
        }
    }
}

extension CoachingStatus {
    /// What to say where a debrief would be. Product copy, not the raw case name: this sits
    /// in the reading pane, and "No debrief yet (pending)." leaks a database value at the
    /// reader without telling them whether to wait, retry, or stop expecting one.
    var debriefPlaceholder: String {
        switch self {
        case .pending: return "Debrief queued…"
        case .running: return "Writing debrief…"
        case .failed: return "Debrief failed — retry from Settings"
        case .skipped: return "Practice round — transcript only"
        // Unreachable while a complete session has its feedback row, which is the point of
        // saying something rather than rendering an empty pane if that ever stops holding.
        case .complete: return "No debrief for this session."
        }
    }
}

struct SessionDetailView: View {
    @EnvironmentObject var env: AppEnvironment
    let sessionId: Int64
    var onRenamed: (() -> Void)? = nil
    @State private var detail: SessionDetail?
    @State private var companyName = ""
    @State private var renameError: String?
    @State private var scrollTarget: Double?
    @State private var regenerating = false
    @State private var criteria = ""
    @State private var regenerateError: String?
    /// Not an error: what to say when `coach()` bailed because another debrief already holds
    /// this session's claim. Separate from `regenerateError` so it doesn't render in red —
    /// nothing went wrong, the work is simply someone else's.
    @State private var regenerateNote: String?
    // Snapshot the selectable round types once per session view. availableRoundTypes() does a
    // directory listing, and debriefPane re-renders on every criteria keystroke — recomputing
    // it per render would list the prompts dir on every keypress.
    @State private var roundTypes: [RoundType] = []

    var body: some View {
        Group {
            if let detail {
                HSplitView {
                    debriefPane(detail).frame(minWidth: 300)
                    transcriptPane(detail).frame(minWidth: 300)
                }
            } else {
                ProgressView()
            }
        }
        .onAppear {
            detail = try? env.db.sessionDetail(id: sessionId)
            companyName = detail?.company.name ?? ""
            criteria = detail?.session.customInstructions ?? ""
            roundTypes = env.prompts.availableRoundTypes()
        }
        .onDisappear { if let detail { commitRename(detail) } }  // criteria persists live via .onChange
    }

    private func commitCriteria() {
        try? env.db.updateSessionCriteria(id: sessionId, criteria)
    }

    private func regenerateButtonTitle(hasFeedback: Bool) -> String {
        switch (regenerating, hasFeedback) {
        case (true, false): return "Generating…"
        case (true, true): return "Regenerating…"
        case (false, false): return "Generate debrief"
        case (false, true): return "Regenerate"
        }
    }

    /// Re-runs coaching for this session on its current rubric, then reloads the pane.
    /// Shared by the Regenerate button and the round-type change (which re-coaches so the
    /// debrief's dimensions match the new round).
    private func regenerate() {
        regenerating = true
        regenerateError = nil
        regenerateNote = nil
        Task {
            do {
                try await env.coaching.coach(sessionId: sessionId)
            } catch {
                regenerateError = "Couldn’t generate debrief: \(error.localizedDescription)"
            }
            // Guard the reload: a failed read must not blank out the pane.
            if let fresh = try? env.db.sessionDetail(id: sessionId) { detail = fresh }
            // `coach()` returns silently when another debrief already holds the session's
            // claim (a finalize job for this very recording, or a Re-run sweep). The button
            // would otherwise flip back to "Regenerate" with the OLD debrief still on screen,
            // reading as "re-ran, nothing changed". The disabled state below hides most of
            // this, but it is computed from a `detail` loaded on appear — a job that starts
            // coaching afterwards is invisible to it, so the honest message still has to exist.
            if regenerateError == nil, detail?.session.coachingStatus == .running {
                regenerateNote = "A debrief for this session is already being written — "
                    + "this pane will show it once that finishes."
            }
            regenerating = false
            onRenamed?()  // refresh the sidebar row's score/advancement/type badge post-coach
        }
    }

    /// The round types offerable for `current`, always including `current` itself so a
    /// session recorded under a custom type whose overlay was later deleted still shows.
    private func roundTypeOptions(including current: RoundType) -> [RoundType] {
        roundTypes.contains(current) ? roundTypes : [current] + roundTypes
    }

    /// Persists a new round type, then auto re-coaches on the new rubric. The type change
    /// stands even if coaching fails — the session is simply retryable via Regenerate.
    private func commitRoundType(_ d: SessionDetail, _ newType: RoundType) {
        guard newType != d.session.roundType else { return }
        do {
            try env.db.updateSessionRoundType(id: sessionId, newType)
            var s = d.session; s.roundType = newType
            detail = SessionDetail(session: s, company: d.company,
                                   segments: d.segments, feedback: d.feedback, tags: d.tags)
            onRenamed?()      // the sidebar row shows the round type too
            regenerate()      // re-coach on the new rubric
        } catch {
            regenerateError = "Couldn’t change interview type: \(error.localizedDescription)"
        }
    }

    private func commitRename(_ d: SessionDetail) {
        let trimmed = companyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != d.company.name else {
            companyName = d.company.name
            return
        }
        do {
            let company = try env.db.renameSession(id: sessionId, companyNamed: trimmed)
            detail = SessionDetail(session: d.session, company: company,
                                    segments: d.segments, feedback: d.feedback, tags: d.tags)
            companyName = company.name
            renameError = nil
            onRenamed?()
        } catch {
            companyName = d.company.name
            renameError = "Couldn’t rename: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func debriefPane(_ d: SessionDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 4) {
                    TextField("Title", text: $companyName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRename(d) }
                    Text("—").foregroundStyle(.secondary)
                    Picker("Interview type", selection: Binding(
                        get: { d.session.roundType },
                        set: { commitRoundType(d, $0) })) {
                        ForEach(roundTypeOptions(including: d.session.roundType), id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .labelsHidden()
                    .font(.body)              // don't inherit the title2/bold below
                    // Don't switch rubric mid-coach — whether this pane started the coach
                    // (`regenerating`) or a finalize job / Re-run sweep did (`running`): the
                    // auto re-coach a type change fires would bail on the other call's claim.
                    .disabled(regenerating || d.session.coachingStatus == .running)
                }
                .font(.title2).bold()
                if let renameError {
                    Text(renameError).font(.caption).foregroundStyle(.red)
                }
                GroupBox("Grading criteria for this interview") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextEditor(text: $criteria)
                            .frame(minHeight: 60, maxHeight: 140)
                            .font(.callout)
                            .disabled(regenerating)  // don't let the text drift from what's being graded
                            .onChange(of: criteria) { commitCriteria() }  // durable: survives quit without a click
                        if let regenerateError {
                            Text(regenerateError).font(.caption).foregroundStyle(.red)
                        }
                        if let regenerateNote {
                            Text(regenerateNote).font(.caption).foregroundStyle(.secondary)
                        }
                        if d.session.coachingStatus == .failed {
                            // Shown even when stale feedback is still present: after a failed
                            // re-coach (e.g. following a round-type change) that feedback was
                            // scored on a different rubric and must not read as current.
                            Label("Last debrief failed — use the button below to retry.", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            Text("Paste a rubric or focus for this interview. Applied when you (re)generate the debrief.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(regenerateButtonTitle(hasFeedback: d.feedback != nil)) {
                                regenerate()
                            }
                            // Also disabled while someone else's debrief holds the claim:
                            // `coach()` would bail and the click would do nothing at all.
                            .disabled(regenerating || d.session.coachingStatus == .running)
                        }
                    }
                }
                if let f = d.feedback {
                    if let advancement = f.advancementValue {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 4) {
                                ScoreBadge(advancement: advancement,
                                           overallScore: f.overallScore, style: .prominent)
                                if !f.advancementRationale.isEmpty {
                                    Text(f.advancementRationale)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if !d.tags.isEmpty {
                        HStack {
                            // Informational tags, not errors: these name what to work on
                            // next, and a red capsule per tag read as a row of alarms even
                            // on a Strong Yes. The verdict above is the only thing on this
                            // pane that gets to carry a colour judgement.
                            ForEach(d.tags, id: \.self) { tag in
                                Text(tag).font(.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(.quaternary, in: Capsule())
                            }
                            Spacer()
                        }
                    }
                    // Above Highlights and the prose: what happens next is the most
                    // actionable thing in a debrief, and it's what you come back for.
                    if let notes = try? JSONDecoder().decode([Highlight].self,
                                                             from: f.processNotesJSON.data(using: .utf8)!),
                       !notes.isEmpty {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Process & next steps", systemImage: "signpost.right.fill")
                                    .font(.headline).foregroundStyle(.blue)
                                // Index, not `t`: two notes can legitimately share a timestamp
                                // (the model quotes one moment twice), and a duplicate ForEach
                                // id drops rows and scrambles them.
                                ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                                    Button {
                                        scrollTarget = parseTimestamp(n.t)
                                    } label: {
                                        HStack(alignment: .top) {
                                            Text(n.t).monospacedDigit().foregroundStyle(.blue)
                                            Text(n.note).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if let highlights = try? JSONDecoder().decode([Highlight].self,
                                                                  from: f.highlightsJSON.data(using: .utf8)!),
                       !highlights.isEmpty {
                        GroupBox("Highlights") {
                            ForEach(highlights, id: \.t) { h in
                                Button {
                                    scrollTarget = parseTimestamp(h.t)
                                } label: {
                                    HStack(alignment: .top) {
                                        Text(h.t).monospacedDigit().foregroundStyle(.blue)
                                        Text(h.note).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    // The one long-form read in the app. Capped measure and looser leading
                    // for the same reason any prose gets them: at full pane width on a wide
                    // display the eye loses the line.
                    Text(LocalizedStringKey(f.proseDebrief))  // renders markdown
                        .textSelection(.enabled)
                        .lineSpacing(4)
                        .frame(maxWidth: 680, alignment: .leading)
                    if let items = try? JSONDecoder().decode([String].self,
                                                             from: f.actionItemsJSON.data(using: .utf8)!),
                       !items.isEmpty {
                        GroupBox("Action items") {
                            ForEach(items, id: \.self) { Text("• \($0)").frame(maxWidth: .infinity, alignment: .leading) }
                        }
                    }
                } else if d.session.coachingStatus == .skipped {
                    // Deliberate, not missing — say so, or it reads as a failure.
                    Text("\(d.session.roundType.displayName) is transcript-only, so there's no debrief. "
                         + "The transcript is on the right.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(d.session.coachingStatus.debriefPlaceholder)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func transcriptPane(_ d: SessionDetail) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(d.segments, id: \.id) { seg in
                        HStack(alignment: .top, spacing: 8) {
                            Text(formatTimestamp(seg.tStart)).monospacedDigit()
                                .font(.caption).foregroundStyle(.secondary)
                            Text(seg.speaker.rawValue).font(.caption).bold()
                                .foregroundStyle(seg.speaker == .you ? .blue : .primary)
                                .frame(width: 44, alignment: .leading)
                            Text(seg.text).textSelection(.enabled)
                        }
                        .id(seg.tStart)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                // Scroll to the nearest segment at/after the highlight timestamp.
                let dest = d.segments.first { $0.tStart >= target - 1 }?.tStart ?? target
                withAnimation { proxy.scrollTo(dest, anchor: .top) }
            }
        }
    }

    private func parseTimestamp(_ t: String) -> Double {
        let parts = t.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}
