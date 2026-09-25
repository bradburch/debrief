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
            // Gated on `scorePoints` alone. Gating on `tagCounts` too made this unreachable
            // on any real database: `tagFrequencyByMonth` is global and unfiltered, so it is
            // non-empty as soon as one debrief anywhere has a tag — and it would also have
            // let the round-filter copy below promise a filter-awareness the tag chart does
            // not have.
            if scorePoints.isEmpty {
                ContentUnavailableView(
                    "No Scored Debriefs Yet",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text(roundFilter == nil
                                      ? "Scores appear here once an interview has been debriefed."
                                      : "No scored debriefs for this round type."))
            } else {
                charts
            }
        }
        .onAppear(perform: reload)
        .onChange(of: roundFilter) { _, _ in reload() }
        // The filter is a view-wide control, not a chart's own axis, so it belongs in the
        // window toolbar rather than floating above the first chart card.
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
            VStack(alignment: .leading, spacing: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    SectionHeader(title: "Score dimensions over time") {
                        Text(roundFilter?.displayName ?? "All rounds")
                    }
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
                                     series: .value("Dimension", p.dimension))
                            .foregroundStyle(by: .value("Dimension", p.dimension))
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            PointMark(x: .value("Date", p.date), y: .value("Score", p.score))
                                .foregroundStyle(by: .value("Dimension", p.dimension))
                                .symbolSize(24)
                        }
                        // Scores are a 1–5 forced choice; a 0 is not a bad score, it is not
                        // a score. Anchoring the axis at 0 spent a fifth of the plot on a
                        // value that can never appear and flattened the range that can.
                        //
                        // This domain CLIPS rather than rejects: a point outside 1...5 just
                        // vanishes from the plot. That is tolerable only because the scores
                        // are validated on the way in — `decodeCoaching` enforces the range
                        // — so an out-of-range point means a decode bug, not a display one.
                        .chartYScale(domain: 1...5)
                        .chartYAxis { Self.subduedYAxis(values: .stride(by: 1)) }
                        .chartXAxis { Self.subduedXAxis }
                        .chartLegend(position: .bottom, alignment: .leading, spacing: Spacing.m)
                        .frame(height: 260)
                        // Not a per-round split. Keying the series by dimension+round made
                        // this chart honest and unreadable at the same time: every base
                        // dimension multiplies by the number of round types, which on a real
                        // database was 48 lines and a rainbow legend. The ambiguity is worth
                        // one sentence, not forty-eight series.
                        //
                        // Derived from the data on screen, never a hardcoded pair of names:
                        // the rubric is markdown a user can edit, so which dimensions overlap
                        // is a property of *their* prompts folder. The old fixed sentence
                        // named two dimensions a custom round type may not even declare, and
                        // stayed on screen when nothing overlapped at all.
                        let mixed = Self.dimensionsSharedAcrossRounds(
                            in: scorePoints.map { ($0.dimension, $0.roundType) })
                        if roundFilter == nil, !mixed.isEmpty {
                            InlineMessage(text: "\(mixed.map { "`\($0)`" }.joined(separator: ", ")) "
                                 + "\(mixed.count == 1 ? "is scored by" : "are each scored by") "
                                 + "more than one round type, with different definitions, so "
                                 + "\(mixed.count == 1 ? "that line mixes" : "those lines mix") them. "
                                 + "Filter to a round type to compare like with like.")
                        }
                    }
                }
                .card()

                VStack(alignment: .leading, spacing: Spacing.m) {
                    SectionHeader(title: "Focus areas per month") {
                        // The tag chart is global — it does not follow the round filter.
                        Text("All rounds")
                    }
                    if tagCounts.isEmpty {
                        Text("No tagged feedback yet.").foregroundStyle(.secondary).padding()
                    } else {
                        Chart(tagCounts) { item in
                            BarMark(x: .value("Month", item.month),
                                    y: .value("Count", item.count),
                                    width: .ratio(0.6))
                            .foregroundStyle(by: .value("Tag", dimensionDisplayName(item.tag)))
                            .cornerRadius(2)
                        }
                        .chartYAxis { Self.subduedYAxis(values: .automatic(desiredCount: 4)) }
                        .chartXAxis {
                            AxisMarks { _ in
                                AxisValueLabel().foregroundStyle(.secondary)
                            }
                        }
                        .chartLegend(position: .bottom, alignment: .leading, spacing: Spacing.m)
                        .frame(height: 240)
                    }
                }
                .card()
            }
            .padding(Spacing.xl)
        }
    }

    /// Hairline gridlines and secondary labels: the data carries the colour, not the frame.
    private static func subduedYAxis(values: AxisMarkValues) -> some AxisContent {
        AxisMarks(position: .leading, values: values) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                .foregroundStyle(.quaternary)
            AxisValueLabel().foregroundStyle(.secondary)
        }
    }

    private static var subduedXAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
            AxisTick(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.quaternary)
            AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(.secondary)
        }
    }

    private var identifiableScorePoints: [IdentifiableScorePoint] {
        scorePoints.map(IdentifiableScorePoint.init)
    }

    /// Dimension keys that appear under more than one round type in `points` — the lines on
    /// the unfiltered chart that mix two rubrics' definitions of the same word.
    ///
    /// Static and internal so it can be tested without driving SwiftUI: the sentence it feeds
    /// is a factual claim about the user's data, and the version that hardcoded two names was
    /// wrong for anyone whose prompts folder differs from the shipped one. It takes the two
    /// fields it uses rather than `[ScorePoint]` because that type's memberwise init is
    /// internal to Store — widening a public API to build fixtures is the wrong trade.
    static func dimensionsSharedAcrossRounds(
        in points: [(dimension: String, roundType: RoundType)]) -> [String] {
        var rounds: [String: Set<RoundType>] = [:]
        for p in points { rounds[p.dimension, default: []].insert(p.roundType) }
        return rounds.filter { $0.value.count > 1 }.keys.sorted()
    }

    private func reload() {
        tagCounts = (try? env.db.tagFrequencyByMonth()) ?? []
        scorePoints = (try? env.db.scoresByDate(roundType: roundFilter)) ?? []
    }
}

/// Local wrapper giving `ScorePoint` a chart-safe composite identity without changing
/// Store's public `ScorePoint` shape.
///
/// The id carries the round type but the *series* deliberately does not: two round types
/// scoring the same dimension on the same day are two points, not one, yet they belong on
/// one line (see the note under the chart). Still imperfect — two sessions of the same round
/// type on the same day collide and one point is dropped — but that predates this wrapper
/// and needs a real session id from `scoresByDate` to fix properly.
private struct IdentifiableScorePoint: Identifiable {
    let point: ScorePoint
    var id: String { "\(point.date.timeIntervalSince1970)|\(point.dimension)|\(point.roundType.rawValue)" }
    var date: Date { point.date }
    var dimension: String { point.dimension }
    var score: Int { point.score }
}
