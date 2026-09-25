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
/// (see the `Advancement` doc comment).
///
/// The mean is always `.secondary`. An earlier draft tinted it with `Color.forScore` when no
/// verdict was present, on the theory that it was then the only signal — but that is a
/// *change* dressed as a refactor: it repainted every pre-verdict debrief in the Sessions
/// list red or green, which is a louder claim than those rows ever made, and it made the
/// same number mean different things in different rows. Consolidating three copies should
/// change where the code lives, not what any of them said. (`Color.forScore` consequently
/// has no caller; it is left in place as the shared definition of the scale, next to
/// `forAdvancement`, for whatever surface next needs to colour a score deliberately.)
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
            HStack(spacing: Spacing.s) { score; verdict }
        case .stacked:
            VStack(alignment: .leading, spacing: Spacing.xxs) { verdict; score }
        case .prominent:
            HStack(alignment: .firstTextBaseline) { verdict; Spacer(); score }
        }
    }

    @ViewBuilder
    private var verdict: some View {
        if let advancement {
            // A tinted capsule in lists and tiles; at the debrief's head, the verdict is set
            // as a headline instead — a pill that size reads as a button.
            if style == .prominent {
                Label {
                    Text(advancement.displayName)
                } icon: {
                    Image(systemName: advancement.advances ? "arrow.up.right.circle.fill"
                                                           : "arrow.down.right.circle.fill")
                }
                .font(verdictFont.weight(.semibold))
                .foregroundStyle(Color.forAdvancement(advancement))
            } else {
                StatusCapsule(text: advancement.displayName,
                              color: Color.forAdvancement(advancement))
            }
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
                .foregroundStyle(.secondary)
        }
    }

    private var verdictFont: Font {
        switch style {
        case .inline: return .caption
        case .stacked: return .callout
        case .prominent: return .title2
        }
    }

    /// nil means "inherit", which is what the Sessions row did before this component existed
    /// — its mean sat at body size beside a `.caption` verdict. Pinning it to `.caption`
    /// here shrank a number on a screen nobody asked to have changed.
    private var scoreFont: Font? {
        switch style {
        case .inline: return nil
        case .prominent: return .callout
        case .stacked: return .caption
        }
    }
}
