import SwiftUI
import Store
import CoachingEngine  // Highlight — process notes are stored as its {t,note} JSON

struct PipelineView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var pipelines: [CompanyPipeline] = []

    var body: some View {
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
                                        // This view IS the advancement story, so the verdict leads
                                        // and the mean is a subscript. A pre-v3 debrief has a score
                                        // but no verdict; an uncoached session has neither.
                                        if let advancement = s.advancement {
                                            Text(advancement.displayName).bold()
                                                .foregroundStyle(Color.forAdvancement(advancement))
                                        } else if s.overallScore != nil {
                                            Text("—").foregroundStyle(.secondary)
                                                .help("Debriefed before verdicts existed — re-run in Settings.")
                                        } else {
                                            Text("—").foregroundStyle(.secondary)
                                        }
                                        if let score = s.overallScore {
                                            Text(String(format: "%.1f", score)).font(.caption2).monospacedDigit()
                                                .foregroundStyle(.secondary)
                                        }
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
                            Picker("", selection: statusBinding(for: pipe.company)) {
                                ForEach(CompanyStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .frame(width: 110)
                        }
                    }
                }
                if pipelines.isEmpty {
                    Text("No sessions yet. Record an interview to start your pipeline.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .onAppear(perform: reload)
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
