import SwiftUI
import Charts
import Store

struct TrendsView: View {
    @EnvironmentObject var env: AppEnvironment
    @State private var tagCounts: [TagMonthCount] = []
    @State private var scorePoints: [ScorePoint] = []
    @State private var roundFilter: RoundType?

    var body: some View {
        Group {
            if tagCounts.isEmpty && scorePoints.isEmpty {
                ContentUnavailableView(
                    "Nothing to trend yet",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text(roundFilter == nil
                                      ? "Trends build up once a few interviews have been debriefed."
                                      : "No debriefed interviews of this round type yet."))
            } else {
                charts
            }
        }
        .onAppear(perform: reload)
        .onChange(of: roundFilter) { _, _ in reload() }
        // The filter is a view-wide control, not a chart's own axis, so it belongs in the
        // window toolbar rather than floating above the first GroupBox.
        .toolbar {
            ToolbarItem {
                Picker("Round type", selection: $roundFilter) {
                    Text("All rounds").tag(RoundType?.none)
                    ForEach(env.prompts.availableRoundTypes(), id: \.self) {
                        Text($0.displayName).tag(RoundType?.some($0))
                    }
                }
                .frame(minWidth: 160)
                .help("Score dimensions differ per round type, so trends are only comparable within one")
            }
        }
    }

    private var charts: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
                        // (date + series) identity instead of touching Store's public type.
                        Chart(identifiableScorePoints) { p in
                            LineMark(x: .value("Date", p.date),
                                     y: .value("Score", p.score),
                                     series: .value("Dimension", p.series))
                            .foregroundStyle(by: .value("Dimension", p.series))
                            PointMark(x: .value("Date", p.date), y: .value("Score", p.score))
                                .foregroundStyle(by: .value("Dimension", p.series))
                        }
                        // Scores are a 1–5 forced choice; a 0 is not a bad score, it is not
                        // a score. Anchoring the axis at 0 spent a fifth of the plot on a
                        // value that can never appear and flattened the range that can.
                        .chartYScale(domain: 1...5)
                        .frame(height: 240)
                    }
                }
            }
            .padding()
        }
    }

    /// Split by round type only in the unfiltered view. `technical_depth` and
    /// `quantified_impact` are declared by two overlays with different definitions, so
    /// across all rounds one line labelled `technical_depth` silently averages two different
    /// questions. Within a single round type there is nothing to disambiguate, and the
    /// suffix would just be noise on every legend entry.
    private var identifiableScorePoints: [IdentifiableScorePoint] {
        let splitByRound = roundFilter == nil
        return scorePoints.map { IdentifiableScorePoint(point: $0, splitByRound: splitByRound) }
    }

    private func reload() {
        tagCounts = (try? env.db.tagFrequencyByMonth()) ?? []
        scorePoints = (try? env.db.scoresByDate(roundType: roundFilter)) ?? []
    }
}

/// Local wrapper giving `ScorePoint` a chart-safe composite identity
/// (date + series) without changing Store's public `ScorePoint` shape.
private struct IdentifiableScorePoint: Identifiable {
    let point: ScorePoint
    let series: String

    init(point: ScorePoint, splitByRound: Bool) {
        self.point = point
        self.series = splitByRound
            ? "\(point.dimension) (\(point.roundType.displayName))"
            : point.dimension
    }

    var id: String { "\(point.date.timeIntervalSince1970)|\(series)" }
    var date: Date { point.date }
    var score: Int { point.score }
}
