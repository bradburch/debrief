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
                if rows.isEmpty {
                    ContentUnavailableView(
                        "No sessions yet",
                        systemImage: "waveform",
                        description: Text("Click Record in the menu bar when a call starts."))
                } else {
                    TextField("Filter by company", text: $filterText)
                        .textFieldStyle(.roundedBorder)
                        .padding(8)
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
                                        // Verdict is the headline; the mean rides alongside as a
                                        // trend signal. Pre-v3 debriefs have no verdict and show
                                        // the score alone until re-coached.
                                        if let advancement = row.advancement {
                                            Text(advancement.displayName)
                                                .font(.caption).bold()
                                                .foregroundStyle(Color.forAdvancement(advancement))
                                        }
                                        if let score = row.overallScore {
                                            Text(String(format: "%.1f", score)).monospacedDigit()
                                                .foregroundStyle(.secondary)
                                        }
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
                                    Button("Delete", role: .destructive) {
                                        // If the right-clicked row isn't in the current multi-selection,
                                        // act on just that row (standard Finder behavior).
                                        if !selection.contains(row.session.id!) { selection = [row.session.id!] }
                                        confirmingDelete = true
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
        }
        .onReceive(env.coordinator.$phase) { if case .idle = $0 { reload() } }
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
        case .pending: Text("coaching…").font(.caption2).foregroundStyle(.secondary)
        case .failed: Text("failed").font(.caption2).foregroundStyle(.red)
        case .complete: EmptyView()
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
        Task {
            do {
                try await env.coaching.coach(sessionId: sessionId)
            } catch {
                regenerateError = "Couldn’t generate debrief: \(error.localizedDescription)"
            }
            // Guard the reload: a failed read must not blank out the pane.
            if let fresh = try? env.db.sessionDetail(id: sessionId) { detail = fresh }
            regenerating = false
        }
    }

    /// The round types offerable for `current`, always including `current` itself so a
    /// session recorded under a custom type whose overlay was later deleted still shows.
    private func roundTypeOptions(including current: RoundType) -> [RoundType] {
        let opts = env.prompts.availableRoundTypes()
        return opts.contains(current) ? opts : [current] + opts
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
                    .disabled(regenerating)   // don't switch rubric mid-coach
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
                        if d.session.coachingStatus == .failed && d.feedback == nil {
                            Label("Last debrief failed — press Generate to retry.", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            Text("Paste a rubric or focus for this interview. Applied when you (re)generate the debrief.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(regenerateButtonTitle(hasFeedback: d.feedback != nil)) {
                                regenerate()
                            }.disabled(regenerating)
                        }
                    }
                }
                if let f = d.feedback {
                    if let advancement = f.advancementValue {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(advancement.displayName).font(.title2).bold()
                                        .foregroundStyle(Color.forAdvancement(advancement))
                                    Spacer()
                                    Text(String(format: "%.1f avg", f.overallScore))
                                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
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
                            ForEach(d.tags, id: \.self) { tag in
                                Text(tag).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.red.opacity(0.15), in: Capsule())
                            }
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
                    Text(LocalizedStringKey(f.proseDebrief))  // renders markdown
                        .textSelection(.enabled)
                    if let items = try? JSONDecoder().decode([String].self,
                                                             from: f.actionItemsJSON.data(using: .utf8)!),
                       !items.isEmpty {
                        GroupBox("Action items") {
                            ForEach(items, id: \.self) { Text("• \($0)").frame(maxWidth: .infinity, alignment: .leading) }
                        }
                    }
                } else {
                    Text("No debrief yet (\(d.session.coachingStatus.rawValue)).")
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
