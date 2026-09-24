import SwiftUI
import Store
import CoachingEngine  // Highlight — process notes are stored as its {t,note} JSON

struct PipelineView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var pipelines: [CompanyPipeline] = []
    @State private var chatPipe: CompanyPipeline?

    var body: some View {
        Group {
            if pipelines.isEmpty {
                ContentUnavailableView(
                    "No pipeline yet",
                    systemImage: "building.2",
                    description: Text("Record an interview and its company appears here, round by round."))
            } else {
                pipelineList
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $chatPipe) { CompanyChatSheet(pipe: $0) }
    }

    private var pipelineList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(pipelines) { pipe in
                    GroupBox {
                        HStack(spacing: 12) {
                            ForEach(pipe.sessions) { s in
                                // A Button rather than .onTapGesture: keeps keyboard focus,
                                // VoiceOver, and the pointer cursor for free.
                                Button { env.revealSession(s.id) } label: {
                                    VStack(spacing: 4) {
                                        Text(s.roundType.displayName).font(.caption)
                                        // This view IS the advancement story, so the verdict
                                        // leads and the mean is a subscript — and every cell
                                        // keeps its shape when either is missing.
                                        ScoreBadge(advancement: s.advancement,
                                                   overallScore: s.overallScore,
                                                   style: .stacked, showsPlaceholder: true)
                                        Text(s.date.formatted(date: .numeric, time: .omitted))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .padding(8)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                    .contentShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                .help("Open this session")
                                if s.id != pipe.sessions.last?.id {
                                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        ProcessNotes(pipe: pipe)
                    } label: {
                        HStack {
                            Text(pipe.company.name).font(.headline)
                            Spacer()
                            Button("Ask about \(pipe.company.name)", systemImage: "bubble.left.and.text.bubble.right") {
                                chatPipe = pipe
                            }
                            .controlSize(.small)
                            // Titled, then hidden: an empty-string label leaves VoiceOver
                            // announcing an unnamed pop-up in a view with one per company.
                            Picker("Status", selection: statusBinding(for: pipe.company)) {
                                ForEach(CompanyStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .accessibilityLabel("Status for \(pipe.company.name)")
                            .frame(width: 110)
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func reload() { pipelines = (try? env.db.pipeline()) ?? [] }

    private func statusBinding(for company: Company) -> Binding<CompanyStatus> {
        Binding(
            get: { company.status },
            set: { newStatus in
                if let id = company.id { try? env.db.updateCompanyStatus(id: id, status: newStatus) }
                reload()
            })
    }
}

/// What each interviewer said about this company's process, gathered across its rounds —
/// the answer to "what happens next with these people?", which is otherwise scattered across
/// several debriefs. Absent entirely when nobody mentioned the process.
private struct ProcessNotes: View {
    let pipe: CompanyPipeline
    @State private var expanded = false

    /// Newest round first (the query orders it), flattened to (round, date, note).
    private var notes: [(round: RoundType, date: Date, note: Highlight)] {
        pipe.processNotesJSON.flatMap { entry -> [(RoundType, Date, Highlight)] in
            let decoded = (try? JSONDecoder().decode([Highlight].self,
                                                     from: Data(entry.json.utf8))) ?? []
            return decoded.map { (entry.roundType, entry.date, $0) }
        }
    }

    var body: some View {
        if !notes.isEmpty {
            Divider().padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Label("Process & next steps", systemImage: "signpost.right.fill")
                        .font(.caption).bold().foregroundStyle(.blue)
                    Text("· latest first").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if notes.count > 3 {
                        Button(expanded ? "Show less" : "Show all \(notes.count)") { expanded.toggle() }
                            .font(.caption).buttonStyle(.link)
                    }
                }
                // Collapsed by default so a chatty company can't push the whole pipeline
                // off-screen; the newest 3 are the ones that still apply.
                ForEach(Array((expanded ? notes : Array(notes.prefix(3))).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.note.note).font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            Text("\(item.round.displayName) · \(item.date.formatted(date: .abbreviated, time: .omitted)) · \(item.note.t)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// Free-form Q&A over one company's sessions, using whatever LLM Settings configured.
/// ponytail: history lives in this sheet's @State only — closing it forgets the chat. Persist
/// to the DB if people start wanting to come back to a conversation.
private struct CompanyChatSheet: View {
    let pipe: CompanyPipeline
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var waiting = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Ask about \(pipe.company.name)").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if messages.isEmpty {
                            Text("Ask anything about your \(pipe.sessions.count) recorded round(s) — e.g. \"What did they say about next steps?\"")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(messages) { m in
                            // AttributedString, not LocalizedStringKey: a key treats "%" in a reply as a format specifier.
                            Text((try? AttributedString(markdown: m.content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(m.content))
                                .textSelection(.enabled)
                                .padding(8)
                                .background(m.role == .user ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .frame(maxWidth: .infinity, alignment: m.role == .user ? .trailing : .leading)
                        }
                        if waiting { ProgressView().controlSize(.small) }
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
                                .textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .onChange(of: messages.count) { proxy.scrollTo("bottom") }
            }
            Divider()
            HStack {
                TextField("Ask a question", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .onSubmit(send)
                Button("Send", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(waiting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    private func send() {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !waiting else { return }
        draft = ""; error = nil; waiting = true
        messages.append(ChatMessage(role: .user, content: q))
        let history = messages, ids = pipe.sessions.map(\.id)
        let coaching = env.coaching  // read at send time: picks up a key changed in Settings
        Task {
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
