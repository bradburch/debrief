import SwiftUI

/// The list of finalize jobs — queued, running, and failed-but-not-dismissed. Rendered
/// *alongside* whatever the recording state is, in both the menu-bar popover and the main
/// window's bar, because the two are now independent: a session can be transcribing while
/// the next one records. Shared by both surfaces so they cannot drift, the same reason
/// `RecordingControls` is shared.
struct FinalizeJobsSection: View {
    @EnvironmentObject var env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(env.coordinator.visibleFinalizeJobs) { job in
                HStack(alignment: .top, spacing: Spacing.s) {
                    icon(for: job)
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(verbatim: name(for: job))
                            .font(.callout.weight(.medium)).lineLimit(1)
                        if let failure = job.failure {
                            Text(failure).font(.caption).foregroundStyle(.red).lineLimit(3)
                        } else {
                            Text(job.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if let p = job.progress, p.total > 0, !job.isFinished {
                            HStack(spacing: Spacing.s) {
                                ProgressView(value: Double(p.done), total: Double(p.total))
                                    .progressViewStyle(.linear).controlSize(.small)
                                Text("\(p.done)/\(p.total)")
                                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    // Only failures reach here finished (successes are filtered out): a
                    // debrief that failed at 2am is the one thing worth not clearing itself.
                    if job.isFinished {
                        Button { env.coordinator.dismissJob(job.id) } label: {
                            Label("Dismiss", systemImage: "xmark.circle.fill")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Dismiss")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func icon(for job: FinalizeJob) -> some View {
        if !job.isFinished {
            ProgressView().controlSize(.mini)
        } else if job.failure != nil {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private func name(for job: FinalizeJob) -> String {
        job.company.isEmpty ? "Recording" : job.company
    }
}
