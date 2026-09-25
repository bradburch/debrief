import SwiftUI
import Store
import CoachingEngine  // Highlight — process notes are stored as its {t,note} JSON

/// A company in Pipeline's navigation stack.
struct CompanyRoute: Hashable {
    let id: Int64
}

/// Pipeline tab: the company list, drilling into one company's overview. A NavigationStack
/// inside the split view's detail column, so the overview gets the standard back button.
struct PipelineView: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        NavigationStack(path: $env.pipelinePath) {
            PipelineList()
                .navigationDestination(for: CompanyRoute.self) { CompanyOverviewView(companyId: $0.id) }
        }
    }
}

private struct PipelineList: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var pipelines: [CompanyPipeline] = []
    /// Sessions filed under the "Unknown" placeholder, which is not a pipeline.
    @State private var unassigned = 0

    var body: some View {
        Group {
            if pipelines.isEmpty {
                ContentUnavailableView {
                    Label("No Pipeline Yet", systemImage: "building.2")
                } description: {
                    Text("Record an interview and its company appears here, round by round.")
                } actions: {
                    unassignedNote
                }
            } else {
                pipelineList
            }
        }
        .navigationTitle("Pipeline")
        .onAppear(perform: reload)
        .onReceive(env.coordinator.$finalizeCompletions) { _ in reload() }
    }

    /// Unobtrusive pointer to interviews Pipeline leaves out, rather than a fake "Unknown"
    /// company. Absent when there are none.
    @ViewBuilder private var unassignedNote: some View {
        if unassigned > 0 {
            Button {
                env.selectedTab = .sessions
            } label: {
                Label(unassigned == 1
                      ? "1 interview has no company — assign one in Sessions"
                      : "\(unassigned) interviews have no company — assign one in Sessions",
                      systemImage: "questionmark.folder")
                    .font(.caption)
            }
            .buttonStyle(.link)
            .help("Open Sessions; set the company in the session's title field")
        }
    }

    private var pipelineList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.m) {
                ForEach(pipelines) { pipe in
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        HStack(alignment: .center, spacing: Spacing.s) {
                            NavigationLink(value: CompanyRoute(id: pipe.id)) {
                                Text(verbatim: pipe.company.name).font(.title3.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .help("Open the \(pipe.company.name) overview")
                            CompanyStatusPicker(company: pipe.company, onChange: reload)
                            Spacer()
                            Text("\(pipe.sessions.count) round\(pipe.sessions.count == 1 ? "" : "s")")
                                .font(.callout).foregroundStyle(.secondary)
                            // The chat moved into the overview; this is the way there.
                            NavigationLink(value: CompanyRoute(id: pipe.id)) {
                                Label("Overview", systemImage: "chevron.right")
                                    .labelStyle(.titleAndIcon)
                            }
                            .controlSize(.small)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Spacing.xs) {
                                ForEach(pipe.sessions) { s in
                                    roundTile(s)
                                    if s.id != pipe.sessions.last?.id {
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        ProcessNotes(entries: pipe.processNotesJSON)
                    }
                    .card()
                }
                unassignedNote
            }
            .padding(Spacing.xl)
        }
    }

    /// One round: a Button rather than .onTapGesture, which keeps keyboard focus, VoiceOver,
    /// and the pointer cursor for free.
    private func roundTile(_ s: SessionSummary) -> some View {
        Button { env.revealSession(s.id) } label: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(s.roundType.displayName)
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .lineLimit(1)
                // This view IS the advancement story, so the verdict leads and the mean is
                // a subscript — and every cell keeps its shape when either is missing.
                ScoreBadge(advancement: s.advancement,
                           overallScore: s.overallScore,
                           style: .stacked, showsPlaceholder: true)
                Text(s.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(width: 118, alignment: .leading)
            .padding(Spacing.s)
            .background(.quaternary.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Open this session")
        .accessibilityLabel("\(s.roundType.displayName), \(s.date.formatted(date: .abbreviated, time: .omitted))")
    }

    private func reload() {
        // A company whose sessions were all renamed away is not a pipeline.
        pipelines = ((try? env.db.pipeline()) ?? []).filter { !$0.sessions.isEmpty }
        unassigned = (try? env.db.unassignedSessionCount()) ?? 0
    }
}

/// The active/dead/offer pop-up, shared by the Pipeline card and the company overview.
private struct CompanyStatusPicker: View {
    @EnvironmentObject var env: AppEnvironment
    let company: Company
    let onChange: () -> Void

    var body: some View {
        // Native pop-up: a custom capsule label inside a Menu gets flattened by AppKit
        // (it rendered as a 7×4pt stub in the live app), and a stock control reads as native.
        Picker("Status", selection: Binding(
            get: { company.status },
            set: { newStatus in
                if let id = company.id { try? env.db.updateCompanyStatus(id: id, status: newStatus) }
                env.refreshCompanies()   // suggestions rank active companies first
                onChange()
            })) {
            ForEach(CompanyStatus.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("Status for \(company.name)")
        .help("Change status")
    }
}

/// One company at a glance: every round in order, where it stands, what to work on, what's
/// planned next, and the Q&A chat over its sessions.
private struct CompanyOverviewView: View {
    @EnvironmentObject var env: AppEnvironment
    let companyId: Int64
    @State private var overview: CompanyOverview?
    @State private var loaded = false

    var body: some View {
        Group {
            if let overview {
                HSplitView {
                    ScrollView {
                        content(overview)
                            .padding(Spacing.xl)
                            .frame(maxWidth: 820, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minWidth: 400)
                    CompanyChatPanel(companyName: overview.company.name,
                                     sessionIds: overview.sessions.map(\.id))
                        .id(companyId)   // a different company starts a fresh conversation
                        .frame(minWidth: 300, idealWidth: 360)
                }
            } else if loaded {
                ContentUnavailableView("Company not found", systemImage: "building.2",
                                       description: Text("It may have been renamed or removed."))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(overview?.company.name ?? "Company")
        .onAppear(perform: reload)
        .onReceive(env.coordinator.$finalizeCompletions) { _ in reload() }
    }

    private func reload() {
        overview = try? env.db.companyOverview(id: companyId)
        loaded = true
    }

    /// Plans are matched by name (a plan is not linked to a company row until it is
    /// recorded), case-insensitively for the same reason completion normalizes case.
    private func plans(for name: String) -> [PlannedCall] {
        env.plannedCalls.filter { $0.companyName.caseInsensitiveCompare(name) == .orderedSame }
    }

    @ViewBuilder
    private func content(_ o: CompanyOverview) -> some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            header(o)
            upcoming(o)
            rounds(o)
            if !o.processNotesJSON.isEmpty {
                ProcessNotes(entries: o.processNotesJSON, showsDivider: false).card()
            }
            weaknesses(o)
            actionItems(o)
        }
    }

    @ViewBuilder
    private func header(_ o: CompanyOverview) -> some View {
        let latestVerdict = o.sessions.last { $0.advancement != nil }
        let advancing = o.sessions.filter { $0.advancement?.advances == true }.count
        let notAdvancing = o.sessions.filter { $0.advancement?.advances == false }.count
        let totalSeconds = o.sessions.map(\.durationSeconds).reduce(0, +)
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .center, spacing: Spacing.m) {
                Text(verbatim: o.company.name).font(.title.weight(.semibold))
                CompanyStatusPicker(company: o.company, onChange: reload)
                Spacer()
            }
            HStack(spacing: Spacing.s) {
                Text("Latest verdict").foregroundStyle(.secondary)
                if let latestVerdict {
                    ScoreBadge(advancement: latestVerdict.advancement, overallScore: nil)
                    Text(latestVerdict.roundType.displayName).foregroundStyle(.secondary)
                } else {
                    Text("None yet").foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            // No mean score here: overallScore is only comparable within one round type,
            // and a company's rounds are mostly different types. The verdict tally is the
            // number that does add up.
            Text(statsLine(o, advancing: advancing, notAdvancing: notAdvancing, totalSeconds: totalSeconds))
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func statsLine(_ o: CompanyOverview, advancing: Int, notAdvancing: Int, totalSeconds: Int) -> String {
        var parts = ["\(o.sessions.count) round\(o.sessions.count == 1 ? "" : "s")"]
        if let first = o.sessions.first?.date, let last = o.sessions.last?.date {
            let f = first.formatted(date: .abbreviated, time: .omitted)
            let l = last.formatted(date: .abbreviated, time: .omitted)
            parts.append(f == l ? f : "\(f) – \(l)")
        }
        if totalSeconds > 0 { parts.append("\(Self.duration(totalSeconds)) total") }
        if advancing + notAdvancing > 0 { parts.append("\(advancing) advancing, \(notAdvancing) not") }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    @ViewBuilder
    private func upcoming(_ o: CompanyOverview) -> some View {
        let plans = plans(for: o.company.name)
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader(title: "Upcoming", systemImage: "calendar") {
                Button("Plan a call", systemImage: "calendar.badge.plus") {
                    var draft = PlannedCallDraft()
                    draft.companyName = o.company.name
                    env.planningCall = draft
                }
                .labelStyle(.titleAndIcon)
                .controlSize(.small)
            }
            if plans.isEmpty {
                Text("Nothing planned.").font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(plans) { plan in
                Button { env.planningCall = PlannedCallDraft(plan) } label: {
                    HStack {
                        Text(plan.roundType.displayName)
                        Spacer()
                        Text(plan.scheduledDate.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Edit this planned call")
            }
        }
        .card()
    }

    @ViewBuilder
    private func rounds(_ o: CompanyOverview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Interviews", systemImage: "list.bullet").padding(.bottom, Spacing.s)
            if o.sessions.isEmpty {
                Text("No recorded rounds.").font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(o.sessions) { s in
                Button { env.revealSession(s.id) } label: {
                    HStack(spacing: Spacing.m) {
                        Text(s.date.formatted(date: .abbreviated, time: .omitted))
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .leading)
                        Text(s.roundType.displayName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if s.coachingStatus == .complete || s.advancement != nil {
                            ScoreBadge(advancement: s.advancement, overallScore: s.overallScore)
                        } else if let capsule = s.coachingStatus.capsule {
                            capsule.help(s.coachingStatus.debriefPlaceholder)
                        }
                        Text(Self.duration(s.durationSeconds))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .font(.callout)
                    .padding(.vertical, Spacing.s)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open this session")
                .accessibilityLabel("\(s.roundType.displayName), \(s.date.formatted(date: .abbreviated, time: .omitted))")
                if s.id != o.sessions.last?.id { Divider() }
            }
        }
        .card()
    }

    @ViewBuilder
    private func weaknesses(_ o: CompanyOverview) -> some View {
        if !o.weaknessTags.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                SectionHeader("Focus areas", systemImage: "scope")
                // Most frequent first; a count only where it recurred, since a single
                // round is the common case and "×1" on every tag is noise.
                FlowLayout(spacing: Spacing.xs) {
                    ForEach(o.weaknessTags, id: \.tag) { t in
                        HStack(spacing: Spacing.xs) {
                            Text(verbatim: dimensionDisplayName(t.tag))
                            if t.count > 1 {
                                Text("\(t.count)").monospacedDigit().foregroundStyle(.tertiary)
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, Spacing.s).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    }
                }
            }
            .card()
        }
    }

    @ViewBuilder
    private func actionItems(_ o: CompanyOverview) -> some View {
        let groups = o.actionItemsJSON.compactMap { entry -> (RoundType, Date, [String])? in
            let items = (try? JSONDecoder().decode([String].self, from: Data(entry.json.utf8))) ?? []
            return items.isEmpty ? nil : (entry.roundType, entry.date, items)
        }
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.m) {
                SectionHeader(title: "Action items", systemImage: "checklist") {
                    Text("Latest round first").font(.caption)
                }
                ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("\(g.0.displayName) · \(g.1.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        ForEach(Array(g.2.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                                Image(systemName: "circle").font(.caption2).foregroundStyle(.tint)
                                Text(item).font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .card()
        }
    }
}

/// What each interviewer said about this company's process, gathered across its rounds —
/// the answer to "what happens next with these people?", which is otherwise scattered across
/// several debriefs. Absent entirely when nobody mentioned the process.
private struct ProcessNotes: View {
    /// `CompanyPipeline.processNotesJSON` / `CompanyOverview.processNotesJSON`.
    let entries: [(roundType: RoundType, date: Date, json: String)]
    /// The Pipeline card separates this from its round cells; the overview's card doesn't need it.
    var showsDivider = true
    @State private var expanded = false

    /// Newest round first (the query orders it), flattened to (round, date, note).
    private var notes: [(round: RoundType, date: Date, note: Highlight)] {
        entries.flatMap { entry -> [(RoundType, Date, Highlight)] in
            let decoded = (try? JSONDecoder().decode([Highlight].self,
                                                     from: Data(entry.json.utf8))) ?? []
            // LLMs occasionally emit a literal "placeholder" note when there was nothing to
            // record (seen in real debriefs); it is noise, not a next step.
            return decoded.filter { $0.note.caseInsensitiveCompare("placeholder") != .orderedSame }
                .map { (entry.roundType, entry.date, $0) }
        }
    }

    var body: some View {
        if !notes.isEmpty {
            if showsDivider { Divider() }
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Label("Process & next steps", systemImage: "signpost.right")
                        .font(showsDivider ? .subheadline.weight(.semibold) : .headline)
                    Text("Latest first").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if notes.count > 3 {
                        Button(expanded ? "Show less" : "Show all \(notes.count)") { expanded.toggle() }
                            .font(.caption).buttonStyle(.link)
                    }
                }
                // Collapsed by default so a chatty company can't push the whole pipeline
                // off-screen; the newest 3 are the ones that still apply.
                ForEach(Array((expanded ? notes : Array(notes.prefix(3))).enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(item.note.note).font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Text(([item.round.displayName, item.date.formatted(date: .abbreviated, time: .omitted)]
                              + (item.note.t.contains(":") ? [compactTimestamp(item.note.t)] : []))
                                .joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.leading, Spacing.s)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.quaternary).frame(width: 2)
                    }
                }
            }
        }
    }
}

/// Free-form Q&A over one company's sessions, using whatever LLM Settings configured. Lives
/// in the company overview's right-hand pane (it was a sheet off the Pipeline card).
/// ponytail: history lives in this view's @State only — leaving the overview forgets the
/// chat. Persist to the DB if people start wanting to come back to a conversation.
private struct CompanyChatPanel: View {
    let companyName: String
    let sessionIds: [Int64]
    @EnvironmentObject var env: AppEnvironment
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var waiting = false
    @State private var error: String?
    @State private var request: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Label("Ask about \(companyName)", systemImage: "bubble.left.and.text.bubble.right")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        if messages.isEmpty {
                            VStack(spacing: Spacing.s) {
                                Image(systemName: "bubble.left.and.text.bubble.right")
                                    .font(.title).foregroundStyle(.tertiary)
                                Text("Ask about \(sessionIds.count == 1 ? "this round" : "these \(sessionIds.count) rounds")")
                                    .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                                Text("“What did they say about next steps?”")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.top, Spacing.xl)
                        }
                        ForEach(messages) { m in
                            // AttributedString, not LocalizedStringKey: a key treats "%" in a reply as a format specifier.
                            Text((try? AttributedString(markdown: m.content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(m.content))
                                .textSelection(.enabled)
                                .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s)
                                .background(m.role == .user ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.6)),
                                            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                                .frame(maxWidth: .infinity, alignment: m.role == .user ? .trailing : .leading)
                                .padding(m.role == .user ? .leading : .trailing, Spacing.xl)
                        }
                        if waiting { ProgressView().controlSize(.small) }
                        if let error {
                            InlineMessage(text: error, kind: .error)
                                .textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(Spacing.l)
                }
                .onChange(of: messages.count) { proxy.scrollTo("bottom") }
            }
            Divider()
            HStack(alignment: .bottom, spacing: Spacing.s) {
                TextField("Ask a question", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .onSubmit(send)
                    .padding(.horizontal, Spacing.m).padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(Color.cardBorder, lineWidth: 0.5))
                Button(action: send) {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.defaultAction)
                .disabled(waiting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send")
            }
            .padding(Spacing.m)
        }
        // Leaving mid-question stops the call rather than letting it bill in the background.
        .onDisappear { request?.cancel() }
    }

    private func send() {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !waiting else { return }
        draft = ""; error = nil; waiting = true
        messages.append(ChatMessage(role: .user, content: q))
        let history = messages, ids = sessionIds
        let coaching = env.coaching  // read at send time: picks up a key changed in Settings
        request = Task {
            do {
                let reply = try await coaching.askAboutCompany(sessionIds: ids, messages: history)
                messages.append(ChatMessage(role: .assistant, content: reply))
            } catch {
                // Drop the unanswered question so the history stays user/assistant alternating.
                messages.removeLast()
                draft = q
                self.error = String(describing: error)
            }
            waiting = false
        }
    }
}
