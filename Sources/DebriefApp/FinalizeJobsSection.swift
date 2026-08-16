import SwiftUI

/// The list of finalize jobs — queued, running, and finished-but-not-dismissed. Rendered
/// *alongside* whatever the recording state is, in both the menu-bar popover and the main
/// window's bar, because the two are now independent: a session can be transcribing while
/// the next one records. Shared by both surfaces so they cannot drift, the same reason
/// `RecordingControls` is shared.
struct FinalizeJobsSection: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(env.coordinator.finalizeJobs) { job in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    icon(for: job)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label(for: job)).font(.caption).lineLimit(3)
                        if let p = job.progress, p.total > 0 {
                            Text("\(p.done)/\(p.total) chunks")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    // Finished jobs stay until dismissed: a debrief that failed at 2am is
                    // the one thing here worth not clearing itself.
                    if job.isFinished {
                        Button("Dismiss") { env.coordinator.dismissJob(job.id) }
                            .buttonStyle(.borderless).controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func icon(for job: FinalizeJob) -> some View {
        if !job.isFinished {
            ProgressView().controlSize(.small)
        } else if job.failure != nil {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private func label(for job: FinalizeJob) -> String {
        let name = job.company.isEmpty ? "Recording" : job.company
        if let failure = job.failure { return "\(name): \(failure)" }
        return job.isFinished ? job.status : "\(name) — \(job.status)"
    }
}
