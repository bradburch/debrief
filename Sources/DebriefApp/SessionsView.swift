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
                        "No Sessions Yet",
                        systemImage: "waveform",
                        description: Text("Start a recording from the toolbar or the menu bar when a call begins."))
                } else {
                    if filteredRows.isEmpty {
                        ContentUnavailableView.search(text: filterText)
                    } else {
                        ScrollViewReader { proxy in
                        List(selection: $selection) {
                            ForEach(filteredRows, id: \.session.id) { row in
                                VStack(alignment: .leading, spacing: Spacing.xs) {
                                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                                        Text(verbatim: row.companyName)
                                            .font(.headline).lineLimit(1)
                                        Spacer(minLength: Spacing.xs)
                                        Text(row.session.date.formatted(date: .abbreviated, time: .omitted))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    HStack(spacing: Spacing.s) {
                                        Text(row.session.roundType.displayName)
                                            .font(.subheadline).foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Spacer(minLength: Spacing.xs)
                                        ScoreBadge(advancement: row.advancement,
                                                   overallScore: row.overallScore)
                                            .font(.subheadline)
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
                                }
                                .padding(.vertical, Spacing.xs)
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
                        .listStyle(.inset)
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
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
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
                Group {
                    if selection.isEmpty {
                        ContentUnavailableView("No Session Selected", systemImage: "doc.text.magnifyingglass",
                                               description: Text("Choose an interview to read its debrief and transcript."))
                    } else {
                        ContentUnavailableView("\(selection.count) Sessions Selected",
                                               systemImage: "square.stack",
                                               description: Text("Press Delete to remove them."))
                    }
                }
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
        env.refreshCompanies()
    }

    /// The shared `CoachingStatus.capsule` (DesignSystem.swift) — Queued / Writing… / Failed /
    /// Transcript only. Nothing for complete; the verdict is that row's badge.
    @ViewBuilder
    private func statusBadge(_ status: CoachingStatus) -> some View {
        if let capsule = status.capsule { capsule }
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
    /// Open on appear when the session already has criteria, so they're never hidden state.
    @State private var criteriaExpanded = false
    /// The rubric's dimension order for this session's round type, read once per load rather
    /// than per render (it parses the prompts folder).
    @State private var dimensionOrder: [String] = []

    var body: some View {
        Group {
            if let detail {
                HSplitView {
                    debriefPane(detail).frame(minWidth: 340, idealWidth: 520)
                    transcriptPane(detail).frame(minWidth: 300, idealWidth: 400)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            detail = try? env.db.sessionDetail(id: sessionId)
            companyName = detail.map { Self.editableName($0.company) } ?? ""
            criteria = detail?.session.customInstructions ?? ""
            criteriaExpanded = !criteria.isEmpty
            roundTypes = env.prompts.availableRoundTypes()
            loadDimensionOrder()
        }
        .onDisappear { if let detail { commitRename(detail) } }  // criteria persists live via .onChange
    }

    private func loadDimensionOrder() {
        guard let type = detail?.session.roundType else { return }
        dimensionOrder = (try? env.prompts.dimensions(for: type)) ?? []
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
            loadDimensionOrder()
            regenerate()      // re-coach on the new rubric
        } catch {
            regenerateError = "Couldn’t change interview type: \(error.localizedDescription)"
        }
    }

    /// The no-company placeholder shows as an empty field, so its prompt reads "Company" and
    /// the suggestions offer real companies to assign — instead of "Unknown" as if it were one.
    private static func editableName(_ c: Company) -> String { c.isPlaceholder ? "" : c.name }

    private func commitRename(_ d: SessionDetail) {
        // Re-spelled as an existing company when only the case differs, so a rename can't
        // split one company's pipeline in two.
        let trimmed = env.canonicalCompany(companyName, current: d.company.name)
        guard !trimmed.isEmpty, trimmed != d.company.name else {
            companyName = Self.editableName(d.company)
            return
        }
        do {
            // A case-only change is a correction to the company's spelling, not a move —
            // unless that spelling already exists as its own company, then it's a move into it.
            let company = trimmed.caseInsensitiveCompare(d.company.name) == .orderedSame && !d.company.isPlaceholder
                && !env.companySuggestions.contains(trimmed)
                ? try env.db.renameCompany(id: d.company.id!, to: trimmed)
                : try env.db.renameSession(id: sessionId, companyNamed: trimmed)
            detail = SessionDetail(session: d.session, company: company,
                                    segments: d.segments, feedback: d.feedback, tags: d.tags)
            companyName = Self.editableName(company)
            renameError = nil
            env.refreshCompanies()
            onRenamed?()
        } catch {
            companyName = Self.editableName(d.company)
            renameError = "Couldn’t rename: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func debriefPane(_ d: SessionDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header(d)
                if let renameError {
                    InlineMessage(text: renameError, kind: .error)
                }
                if let regenerateError {
                    InlineMessage(text: regenerateError, kind: .error)
                }
                if let regenerateNote {
                    InlineMessage(text: regenerateNote)
                }
                if d.session.coachingStatus == .failed {
                    // Shown even when stale feedback is still present: after a failed
                    // re-coach (e.g. following a round-type change) that feedback was
                    // scored on a different rubric and must not read as current.
                    InlineMessage(text: "The last debrief failed — use \(regenerateButtonTitle(hasFeedback: d.feedback != nil)) to retry.",
                                  kind: .warning)
                }
                if let f = d.feedback {
                    feedbackSections(f, tags: d.tags)
                } else if d.session.coachingStatus == .skipped {
                    // Deliberate, not missing — say so, or it reads as a failure.
                    placeholder("\(d.session.roundType.displayName) is transcript-only, so there's no debrief. "
                                + "The transcript is on the right.",
                                systemImage: "text.alignleft")
                } else {
                    placeholder(d.session.coachingStatus.debriefPlaceholder,
                                systemImage: d.session.coachingStatus == .failed
                                    ? "exclamationmark.triangle" : "hourglass")
                }
                // Last, not first: the verdict is the headline. The criteria are an input to
                // the header's (Re)generate button, and open on appear whenever they're set.
                criteriaSection(d)
            }
            .padding(Spacing.xl)
            // The one long-form read in the app. A capped measure for the same reason any
            // prose gets one: at full pane width on a wide display the eye loses the line.
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Company as the title, then round · date · duration, then the pane's one action.
    @ViewBuilder
    private func header(_ d: SessionDetail) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .center, spacing: Spacing.m) {
                CompanyField(title: "Company", text: $companyName) { commitRename(d) }
                    .textFieldStyle(.plain)
                    .font(.title.weight(.semibold))
                Button(regenerateButtonTitle(hasFeedback: d.feedback != nil)) {
                    regenerate()
                }
                // Also disabled while someone else's debrief holds the claim:
                // `coach()` would bail and the click would do nothing at all.
                .disabled(regenerating || d.session.coachingStatus == .running)
                .help("Re-run the debrief on the current rubric and grading criteria")
            }
            HStack(spacing: Spacing.s) {
                Picker("Interview type", selection: Binding(
                    get: { d.session.roundType },
                    set: { commitRoundType(d, $0) })) {
                    ForEach(roundTypeOptions(including: d.session.roundType), id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .labelsHidden()
                .fixedSize()
                // Don't switch rubric mid-coach — whether this pane started the coach
                // (`regenerating`) or a finalize job / Re-run sweep did (`running`): the
                // auto re-coach a type change fires would bail on the other call's claim.
                .disabled(regenerating || d.session.coachingStatus == .running)
                Text("·").foregroundStyle(.tertiary)
                Text(d.session.date.formatted(date: .long, time: .shortened))
                if d.session.durationSeconds > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text(Duration.seconds(d.session.durationSeconds)
                        .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                        .monospacedDigit()
                }
                if regenerating {
                    ProgressView().controlSize(.small).padding(.leading, Spacing.xs)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func criteriaSection(_ d: SessionDetail) -> some View {
        DisclosureGroup(isExpanded: $criteriaExpanded) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                TextEditor(text: $criteria)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.xs)
                    .frame(minHeight: 70, maxHeight: 160)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: Radius.small))
                    .overlay(RoundedRectangle(cornerRadius: Radius.small)
                        .strokeBorder(Color.cardBorder, lineWidth: 0.5))
                    .disabled(regenerating)  // don't let the text drift from what's being graded
                    .onChange(of: criteria) { commitCriteria() }  // durable: survives quit without a click
                Text("A rubric or focus for this interview, applied when the debrief is (re)generated.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, Spacing.s)
        } label: {
            HStack(spacing: Spacing.s) {
                Text("Grading criteria").font(.headline)
                if !criteria.isEmpty && !criteriaExpanded {
                    StatusCapsule(text: "Custom", color: .accentColor)
                }
            }
        }
        .card(padding: Spacing.m)
    }

    @ViewBuilder
    private func feedbackSections(_ f: FeedbackRecord, tags: [String]) -> some View {
        if let advancement = f.advancementValue {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Verdict").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .textCase(.uppercase)
                ScoreBadge(advancement: advancement,
                           overallScore: f.overallScore, style: .prominent)
                if !f.advancementRationale.isEmpty {
                    Text(f.advancementRationale)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .card()
        }
        let scores = orderedScores(f)
        if !scores.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.m) {
                SectionHeader(title: "Scores") {
                    // No verdict: the mean is all there is to headline, so it rides here.
                    if f.advancementValue == nil {
                        Text(String(format: "%.1f avg", f.overallScore)).monospacedDigit()
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.s) {
                    ForEach(scores, id: \.key) { item in
                        GridRow {
                            Text(dimensionDisplayName(item.key))
                                .font(.callout)
                                .lineLimit(2)
                            ScoreBar(score: item.value)
                            Text("\(item.value)")
                                .font(.callout.weight(.medium)).monospacedDigit()
                                .gridColumnAlignment(.trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .card()
        }
        if !tags.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                SectionHeader("Focus areas")
                // Informational tags, not errors: these name what to work on next, and a
                // red capsule per tag read as a row of alarms even on a Strong Yes. The
                // verdict above is the only thing on this pane that gets to carry a colour
                // judgement.
                FlowLayout(spacing: Spacing.xs) {
                    ForEach(tags, id: \.self) { tag in
                        Text(verbatim: dimensionDisplayName(tag)).font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, Spacing.s).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        // Above Highlights and the prose: what happens next is the most actionable thing
        // in a debrief, and it's what you come back for.
        if let notes = try? JSONDecoder().decode([Highlight].self,
                                                 from: f.processNotesJSON.data(using: .utf8)!),
           !notes.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                SectionHeader("Process & next steps", systemImage: "signpost.right")
                // Index, not `t`: two notes can legitimately share a timestamp (the model
                // quotes one moment twice), and a duplicate ForEach id drops rows and
                // scrambles them.
                ForEach(Array(notes.enumerated()), id: \.offset) { _, n in
                    timestampedRow(n)
                }
            }
            .card()
        }
        if let highlights = try? JSONDecoder().decode([Highlight].self,
                                                      from: f.highlightsJSON.data(using: .utf8)!),
           !highlights.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                SectionHeader("Highlights", systemImage: "star")
                ForEach(highlights, id: \.t) { h in
                    timestampedRow(h)
                }
            }
            .card()
        }
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader("Debrief")
            // Looser leading than body default: this is the one long-form read in the app.
            Text(LocalizedStringKey(f.proseDebrief))  // renders markdown
                .textSelection(.enabled)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card()
        if let items = try? JSONDecoder().decode([String].self,
                                                 from: f.actionItemsJSON.data(using: .utf8)!),
           !items.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                SectionHeader("Action items", systemImage: "checklist")
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                        Image(systemName: "circle")
                            .font(.caption2).foregroundStyle(.tint)
                        Text(item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .card()
        }
    }

    /// A highlight or process note: the timestamp jumps the transcript to that moment.
    private func timestampedRow(_ h: Highlight) -> some View {
        Button {
            scrollTarget = parseTimestamp(h.t)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                Text(compactTimestamp(h.t))
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.tint)
                    .frame(minWidth: 44, alignment: .leading)
                Text(h.note)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show this moment in the transcript")
    }

    private func placeholder(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
    }

    /// Scores in the rubric's own order (base dimensions, then the round's), falling back to
    /// alphabetical for any key the current prompts no longer declare.
    private func orderedScores(_ f: FeedbackRecord) -> [(key: String, value: Int)] {
        guard let scores = try? JSONDecoder().decode([String: Int].self, from: Data(f.scoresJSON.utf8))
        else { return [] }
        let order = dimensionOrder
        return scores.map { (key: $0.key, value: $0.value) }.sorted { a, b in
            let ia = order.firstIndex(of: a.key) ?? Int.max
            let ib = order.firstIndex(of: b.key) ?? Int.max
            return ia != ib ? ia < ib : a.key < b.key
        }
    }

    @ViewBuilder
    private func transcriptPane(_ d: SessionDetail) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transcript").font(.headline)
                Spacer()
                HStack(spacing: Spacing.m) {
                    speakerKey("You", color: .accentColor)
                    speakerKey("Them", color: .secondary)
                }
                .font(.caption)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.s) {  // eager: scrollTo on unrendered lazy rows lands off-target
                        ForEach(Array(d.segments.enumerated()), id: \.element.id) { index, seg in
                            // The speaker is named only where it changes, so a run of one
                            // person's segments reads as one turn.
                            let isNewTurn = index == 0 || d.segments[index - 1].speaker != seg.speaker
                            transcriptRow(seg, showsSpeaker: isNewTurn)
                                .padding(.top, isNewTurn && index > 0 ? Spacing.s : 0)
                                .id(seg.tStart)
                        }
                    }
                    .padding(Spacing.l)
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
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func speakerKey(_ name: String, color: Color) -> some View {
        HStack(spacing: Spacing.xs) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).foregroundStyle(.secondary)
        }
    }

    private func transcriptRow(_ seg: TranscriptSegmentRecord, showsSpeaker: Bool) -> some View {
        let isYou = seg.speaker == .you
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Text(compactTimestamp(formatTimestamp(seg.tStart)))
                .font(.caption).monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                if showsSpeaker {
                    Text(seg.speaker.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isYou ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                Text(seg.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, Spacing.s)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isYou ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 2)
            }
        }
    }

    private func parseTimestamp(_ t: String) -> Double {
        let parts = t.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }
}

/// One dimension's 1–5 score as five segments in the accent colour. Deliberately not the
/// verdict's red-to-green scale: the verdict is the only colour judgement on the pane.
private struct ScoreBar: View {
    let score: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(i <= score ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 22, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}
