import SwiftUI
import Store
import CoachingEngine

struct SessionsView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var rows: [(session: InterviewSession, companyName: String, overallScore: Double?)] = []
    @State private var selection: Set<Int64> = []
    @State private var confirmingDelete = false

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(rows, id: \.session.id) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(row.companyName).bold()
                            Spacer()
                            if let score = row.overallScore {
                                Text(String(format: "%.1f", score)).monospacedDigit()
                                    .foregroundStyle(Color.forScore(score))
                            } else {
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
            .frame(minWidth: 260, maxWidth: 340)
            .onDeleteCommand { if !selection.isEmpty { confirmingDelete = true } }
            .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive, action: deleteSelected)
                Button("Cancel", role: .cancel) {}
            }

            if selection.count == 1, let id = selection.first {
                SessionDetailView(sessionId: id, onRenamed: reload).id(id)
            } else {
                Text(selection.isEmpty ? "Select a session" : "\(selection.count) sessions selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: reload)
        .onReceive(env.coordinator.$phase) { if case .idle = $0 { reload() } }
    }

    private func reload() { rows = (try? env.db.allSessionSummaries()) ?? [] }

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
                        .textFieldStyle(.plain)
                        .onSubmit { commitRename(d) }
                    Text("— \(d.session.roundType.displayName)").foregroundStyle(.secondary)
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
                        HStack {
                            Text("Paste a rubric or focus for this interview. Applied when you (re)generate the debrief.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(regenerateButtonTitle(hasFeedback: d.feedback != nil)) {
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
                            }.disabled(regenerating)
                        }
                    }
                }
                if let f = d.feedback {
                    if !d.tags.isEmpty {
                        HStack {
                            ForEach(d.tags, id: \.self) { tag in
                                Text(tag).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.red.opacity(0.15), in: Capsule())
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
