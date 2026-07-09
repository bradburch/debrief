import SwiftUI

extension Color {
    /// Debrief's score-quality scale, shared by the Sessions list and Pipeline cells.
    static func forScore(_ score: Double) -> Color {
        score >= 3.5 ? .green : score >= 2.5 ? .orange : .red
    }
}

enum MainTab: String, CaseIterable {
    case sessions = "Sessions", pipeline = "Pipeline", trends = "Trends", settings = "Settings"
    var symbol: String {
        switch self {
        case .sessions: return "list.bullet.rectangle"
        case .pipeline: return "building.2"
        case .trends: return "chart.line.uptrend.xyaxis"
        case .settings: return "gearshape"
        }
    }
}

struct MainWindow: View {
    @State private var tab: MainTab? = .sessions

    var body: some View {
        NavigationSplitView {
            List(MainTab.allCases, id: \.self, selection: $tab) { t in
                Label(t.rawValue, systemImage: t.symbol).tag(t)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            switch tab ?? .sessions {
            case .sessions: SessionsView()
            case .pipeline: PipelineView()
            case .trends: TrendsView()
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}
