import SwiftUI
import Charts
import Store

struct TrendsView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var tagCounts: [TagMonthCount] = []
    @State private var scorePoints: [ScorePoint] = []
    @State private var roundFilter: RoundType?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Round type", selection: $roundFilter) {
                    Text("All rounds").tag(RoundType?.none)
                    ForEach(RoundType.allCases, id: \.self) { Text($0.displayName).tag(RoundType?.some($0)) }
                }
                .frame(width: 260)

                GroupBox("Weakness tags per month") {
                    if tagCounts.isEmpty {
                        Text("No tagged feedback yet.").foregroundStyle(.secondary).padding()
                    } else {
                        Chart(tagCounts) { item in
                            BarMark(x: .value("Month", item.month),
                                    y: .value("Count", item.count))
                            .foregroundStyle(by: .value("Tag", item.tag))
                        }
                        .frame(height: 240)
                    }
                }

                GroupBox("Score dimensions over time") {
                    if scorePoints.isEmpty {
                        Text("No scored sessions yet.").foregroundStyle(.secondary).padding()
                    } else {
                        // ScorePoint has no stable identity of its own, and two dimensions
                        // scored on the same session share the same date — keying the chart
                        // by \.date alone would collide. Wrap locally with a composite
                        // (date + dimension) identity instead of touching Store's public type.
                        Chart(identifiableScorePoints) { p in
                            LineMark(x: .value("Date", p.date),
                                     y: .value("Score", p.score),
                                     series: .value("Dimension", p.dimension))
                            .foregroundStyle(by: .value("Dimension", p.dimension))
                            PointMark(x: .value("Date", p.date), y: .value("Score", p.score))
                                .foregroundStyle(by: .value("Dimension", p.dimension))
                        }
                        .chartYScale(domain: 0...5)
                        .frame(height: 240)
                    }
                }
            }
            .padding()
        }
        .onAppear(perform: reload)
        .onChange(of: roundFilter) { _, _ in reload() }
    }

    private var identifiableScorePoints: [IdentifiableScorePoint] {
        scorePoints.map(IdentifiableScorePoint.init)
    }

    private func reload() {
        tagCounts = (try? env.db.tagFrequencyByMonth()) ?? []
        scorePoints = (try? env.db.scoresByDate(roundType: roundFilter)) ?? []
    }
}

/// Local wrapper giving `ScorePoint` a chart-safe composite identity
/// (date + dimension) without changing Store's public `ScorePoint` shape.
private struct IdentifiableScorePoint: Identifiable {
    let point: ScorePoint
    var id: String { "\(point.date.timeIntervalSince1970)|\(point.dimension)" }
    var date: Date { point.date }
    var dimension: String { point.dimension }
    var score: Int { point.score }
}
