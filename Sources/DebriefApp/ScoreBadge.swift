import SwiftUI
import Store

/// The verdict-and-mean pair, defined once.
///
/// Sessions rows, the debrief header and Pipeline cells all show the same two facts, and
/// each had hand-rolled its own version — which is how they drifted: three different fonts,
/// only two of them monospaced-digit, and only Pipeline explaining the pre-verdict debriefs
/// that carry a mean and no verdict. One component, three densities.
///
/// The hierarchy is fixed here rather than per call site because it is a product decision,
/// not a layout one: the verdict is the headline and the mean rides along as a trend signal
/// (see the `Advancement` doc comment). That is also why `Color.forScore` tints the mean
/// only when there is no verdict — with one, a second colour scale competes with the
/// headline; without one, the mean is the only signal there is.
struct ScoreBadge: View {
    /// nil for a debrief written before the verdict existed, or one not yet coached.
    let advancement: Advancement?
    /// nil for a session with no debrief at all.
    let overallScore: Double?
    var style: Style = .inline
    /// Pipeline draws one cell per round and needs them the same shape, so a missing verdict
    /// renders an em dash there instead of collapsing the cell. Elsewhere it renders nothing
    /// — a Sessions row already says "no debrief" with its status badge.
    var showsPlaceholder = false

    enum Style {
        /// A list row: everything on one line, subordinate to the row's title.
        case inline
        /// A Pipeline cell: verdict over mean, in a fixed-width tile.
        case stacked
        /// The debrief header: the verdict at full size, mean pushed to the trailing edge.
        case prominent
    }

    var body: some View {
        switch style {
        case .inline:
            HStack(spacing: 6) { verdict; score }
        case .stacked:
            VStack(spacing: 2) { verdict; score }
        case .prominent:
            HStack(alignment: .firstTextBaseline) { verdict; Spacer(); score }
        }
    }

    @ViewBuilder
    private var verdict: some View {
        if let advancement {
            Text(advancement.displayName)
                .font(verdictFont).bold()
                .foregroundStyle(Color.forAdvancement(advancement))
        } else if showsPlaceholder {
            Text("—")
                .font(verdictFont)
                .foregroundStyle(.secondary)
                // Two different absences, and telling them apart is the difference between
                // "re-run this in Settings" and "this was never debriefed".
                .help(overallScore == nil
                      ? "Not debriefed yet."
                      : "Debriefed before verdicts existed — re-run in Settings.")
        }
    }

    @ViewBuilder
    private var score: some View {
        if let overallScore {
            Text(style == .prominent
                 ? String(format: "%.1f avg", overallScore)
                 : String(format: "%.1f", overallScore))
                .font(scoreFont).monospacedDigit()
                .foregroundStyle(advancement == nil ? Color.forScore(overallScore) : .secondary)
        }
    }

    private var verdictFont: Font {
        switch style {
        case .inline: return .caption
        case .stacked: return .body
        case .prominent: return .title2
        }
    }

    private var scoreFont: Font {
        switch style {
        case .inline, .prominent: return .caption
        case .stacked: return .caption2
        }
    }
}
