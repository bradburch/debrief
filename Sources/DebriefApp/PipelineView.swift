import SwiftUI
import Store

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
                                VStack(spacing: 4) {
                                    Text(s.roundType.displayName).font(.caption)
                                    if let score = s.overallScore {
                                        Text(String(format: "%.1f", score)).bold().monospacedDigit()
                                            .foregroundStyle(Color.forScore(score))
                                    } else {
                                        Text("—").foregroundStyle(.secondary)
                                    }
                                    Text(s.date.formatted(date: .numeric, time: .omitted))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(8)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                if s.id != pipe.sessions.last?.id {
                                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
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
