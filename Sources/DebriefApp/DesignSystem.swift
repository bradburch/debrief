import SwiftUI
import Store

// Debrief's visual vocabulary, in one place so every surface draws from the same scale.
//
// The rules the views follow:
// - Spacing comes from `Spacing`, never a bare number, so gaps line up across panes.
// - Type is semantic (.title2 / .headline / .subheadline / .callout / .caption) — no point sizes.
// - The accent colour marks what's interactive or "yours" (the You side of a transcript,
//   timestamps you can jump to). Red is reserved for recording and errors; the verdict scale
//   is the only colour *judgement* on screen.
// - Status is a `StatusCapsule`: a tinted pill, never a raw picker or a coloured sentence.

enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

enum Radius {
    static let small: CGFloat = 6
    static let card: CGFloat = 10
}

extension Color {
    /// Debrief's score-quality scale, shared by the Sessions list and Pipeline cells.
    static func forScore(_ score: Double) -> Color {
        score >= 3.5 ? .green : score >= 2.5 ? .orange : .red
    }

    /// The verdict's scale. Distinct from forScore because this is an ordinal call, not a
    /// threshold on a number — the two leans are deliberately different shades so a
    /// borderline result never reads as a clean pass or a clean reject.
    static func forAdvancement(_ a: Advancement) -> Color {
        switch a {
        case .strongYes: return .green
        case .leanYes: return .mint
        case .leanNo: return .orange
        case .strongNo: return .red
        }
    }

    /// Card fill: the control background reads as a raised sheet on the window background in
    /// light mode and as an inset panel in dark mode, which is how AppKit's own grouped
    /// surfaces behave.
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let cardBorder = Color(nsColor: .separatorColor)
}

// MARK: - Status capsule

/// A small tinted pill for a status or verdict. Tint at low opacity behind text in the full
/// colour keeps it legible in both appearances without shouting.
struct StatusCapsule: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

extension CoachingStatus {
    /// A capsule for every state except complete, which needs no badge — the verdict is its
    /// badge. Product copy, not the raw case name.
    var capsule: StatusCapsule? {
        switch self {
        case .pending: return StatusCapsule(text: "Queued")
        case .running: return StatusCapsule(text: "Writing…", color: .accentColor)
        case .failed: return StatusCapsule(text: "Failed", color: .red)
        // Not a shortfall: a transcript-only round is finished when it's transcribed.
        case .skipped: return StatusCapsule(text: "Transcript only")
        case .complete: return nil
        }
    }
}

extension CompanyStatus {
    var displayName: String {
        switch self {
        case .active: return "Active"
        case .dead: return "Closed"
        case .offer: return "Offer"
        }
    }

    var color: Color {
        switch self {
        case .active: return .accentColor
        case .dead: return .secondary
        case .offer: return .green
        }
    }
}

// MARK: - Cards and section headers

private struct CardModifier: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardBackground,
                        in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Color.cardBorder.opacity(0.6), lineWidth: 0.5))
    }
}

extension View {
    /// A rounded, subtly bordered panel — Debrief's one container shape.
    func card(padding: CGFloat = Spacing.l) -> some View {
        modifier(CardModifier(padding: padding))
    }
}

/// A section title with an optional trailing accessory (a count, a button).
struct SectionHeader<Accessory: View>: View {
    let title: String
    var systemImage: String? = nil
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
            Spacer(minLength: Spacing.s)
            accessory()
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .font(.headline)
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(_ title: String, systemImage: String? = nil) {
        self.init(title: title, systemImage: systemImage) { EmptyView() }
    }
}

// MARK: - Inline messages

/// A one-line (or few-line) status message: a warning, an error, or a neutral note. One
/// shape for every "something to know" line so they don't each pick their own colour.
struct InlineMessage: View {
    enum Kind { case info, warning, error }
    let text: String
    var kind: Kind = .info
    var lineLimit: Int? = nil

    var body: some View {
        Label {
            Text(text).lineLimit(lineLimit).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.caption)
        .foregroundStyle(kind == .info ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
    }

    private var symbol: String {
        switch kind {
        case .info: return "info.circle"
        // Orange, not yellow: yellow text is unreadable on a light background.
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - Level meter

/// A slim input-level bar. RMS is small, so it's scaled ×4 for visibility — the same scaling
/// the meters have always used, in one place now.
struct LevelMeter: View {
    let level: Float
    var width: CGFloat? = nil

    private var fraction: Double { min(Double(level) * 4, 1.0) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(fraction > 0.85 ? Color.orange : Color.green)
                    .frame(width: max(geo.size.width * fraction, fraction > 0 ? 3 : 0))
            }
        }
        .frame(width: width, height: 5)
        .animation(.easeOut(duration: 0.15), value: fraction)
        .accessibilityElement()
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

// MARK: - Flow layout

/// Wraps its children onto as many lines as they need — tag rows that would otherwise run
/// off the edge of a narrow pane.
struct FlowLayout: Layout {
    var spacing: CGFloat = Spacing.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(proposal.width ?? width, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

// MARK: - Formatting

/// "00:12:34" → "12:34" when the call is under an hour. Display only — the stored and parsed
/// form stays hh:mm:ss.
func compactTimestamp(_ t: String) -> String {
    t.hasPrefix("00:") && t.count == 8 ? String(t.dropFirst(3)) : t
}

/// "technical_depth" → "Technical depth", for dimension keys parsed out of the rubric markdown.
func dimensionDisplayName(_ key: String) -> String {
    let spaced = key.replacingOccurrences(of: "_", with: " ")
    return spaced.prefix(1).uppercased() + spaced.dropFirst()
}
