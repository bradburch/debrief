import SwiftUI
import Store
import CaptureKit

/// Shown in the menu-bar popover when a previous launch left orphaned recording
/// directories on disk (e.g. the app was `kill -9`'d mid-call). Offers to
/// re-transcribe the salvaged chunks into a session, or discard them.
struct RecoveryPrompt: View {
    @EnvironmentObject var env: AppEnvironment
    let dir: URL

    @State private var company = ""
    @State private var roundType: RoundType = .behavioral
    @State private var isRecovering = false

    private var manifestDate: Date? { RecordingStore.readManifest(in: dir)?.startedAt }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let date = manifestDate {
                Label("Unsaved recording from \(date, style: .relative) ago", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow).font(.caption)
            } else {
                Label("Unsaved recording found", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow).font(.caption)
            }
            TextField("Company", text: $company)
            Picker("Round", selection: $roundType) {
                ForEach(RoundType.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            HStack {
                Button("Discard") { env.discard(dir) }
                Spacer()
                Button("Recover") {
                    isRecovering = true
                    Task {
                        let name = company.isEmpty ? "Unknown" : company
                        await env.recover(dir, metadata: .init(company: name, roundType: roundType, notes: ""))
                        isRecovering = false
                    }
                }
                .disabled(isRecovering)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.1)))
    }
}
