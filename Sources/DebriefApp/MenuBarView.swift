import SwiftUI
import Store

struct MenuBarView: View {
    @EnvironmentObject var env: AppEnvironment

    /// Ceiling on the scrolling part of the popover. Two recovery prompts plus a handful of
    /// finalize jobs already exceed a short display's usable height, and everything below
    /// this frame — including Quit — used to be pushed off-screen with no way to reach it.
    private static let maxScrollHeight: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Recording state and finalize jobs are stacked, not switched between: starting
            // the next interview while the last one is still being debriefed is the whole
            // point. Both are unbounded (n recovery prompts, n jobs, multi-line failures),
            // so they are the part that scrolls.
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Above the recording/idle branch, not inside `idleSection`: the exclusive
                    // resource is a session directory, so recovering an orphaned one *while*
                    // another interview records is deliberately legal (RecoveryTests pins it,
                    // and the checklist asks the tester to do it). Rendered only while idle,
                    // every recovery prompt vanished the moment recording started — the audio
                    // was still there, but the only UI that offers it was not.
                    if !env.recoverableSessions.isEmpty {
                        ForEach(env.recoverableSessions, id: \.self) { dir in
                            RecoveryPrompt(dir: dir)
                        }
                        Divider()
                    }
                    // Detection state and both meters, in EVERY phase. They used to be
                    // split across the two branches below — "Call detected" idle-only,
                    // the meters recording-only — which meant the popover could answer
                    // "is Debrief hearing anything?" in neither state you actually ask it
                    // in: before a call, and while one is being detected.
                    signalSection
                    if case .recording = env.coordinator.recordingPhase {
                        recordingSection()
                    } else {
                        idleSection
                    }
                    if !env.coordinator.finalizeJobs.isEmpty {
                        Divider()
                        FinalizeJobsSection()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.maxScrollHeight)
            // Outside the ScrollView on purpose: these two must stay reachable no matter how
            // much state is above them.
            Divider()
            Button("Open Debrief") { AppDelegate.focusMainWindow() }
            // Routed through applicationShouldTerminate (see AppDelegate), which is what
            // asks before abandoning an unfinished debrief.
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 280)
        // One task owns the meters for exactly as long as the popover is on screen: it
        // re-arms them each tick and releases the devices when SwiftUI cancels it, which
        // ties the mic and the system tap to "something is visibly showing them" rather
        // than to `onDisappear` firing on a MenuBarExtra window.
        //
        // Deliberately a loop rather than `.task(id: recordingPhase)`. An id change cancels
        // the old task and starts the new one without ordering them, so the outgoing task's
        // release could land after the incoming one's start and leave the meters dead with
        // the devices shut — the bug this loop exists to fix, reintroduced by its own fix.
        .task {
            while !Task.isCancelled {
                // Idempotent, and a no-op while a recording owns the devices. Re-calling it
                // is what brings the meters back after a recording is stopped from inside
                // this same popover: `startRecording` released the monitor, and nothing else
                // would ever hand it back while the popover stayed open.
                await env.coordinator.startMonitoring()
                // A tap delivers nothing while the output device is idle, so the "Them" bar
                // would otherwise latch at its last reading when the far side stops talking
                // and go on claiming audio that isn't playing.
                env.coordinator.expireStaleMonitorLevels()
                // ponytail: a 1s poll, not a subscription. The coordinator would have to
                // know a popover exists to push this; if a second surface ever wants live
                // meters, give the coordinator a subscriber count instead.
                try? await Task.sleep(for: .seconds(1))
            }
            await env.coordinator.stopMonitoring()
        }
        // Deliberately does NOT arm AppDelegate.openMainWindow: MenuBarLabel is the only
        // registrar (see the comment on the property). This view's copy was captured from a
        // scene that can be torn down, and it overwrote a closure that is good for the life
        // of the process.
    }

    /// "Is Debrief hearing anything?" — the one question the popover exists to answer, and
    /// the one failure mode the app cannot detect on your behalf: capture that runs, writes
    /// correctly-sized files, and records silence. Shown in every phase, driven by the live
    /// session while recording and by `RecordingCoordinator.startMonitoring` while idle.
    @ViewBuilder
    private var signalSection: some View {
        if case .recording(let started) = env.coordinator.recordingPhase {
            Label("Recording \(started, style: .timer)", systemImage: "record.circle.fill")
                .foregroundStyle(.red)
        } else if env.callDetected {
            Label("Call detected", systemImage: "phone.fill").foregroundStyle(.orange)
        } else {
            // Stated rather than left blank. An absent line is ambiguous between "no call"
            // and "detection is broken", and detection running is itself the thing worth
            // confirming before you rely on it to catch the next call.
            Label("No call detected", systemImage: "phone.down")
                .foregroundStyle(.secondary).font(.caption)
        }
        LevelRow(label: "You", level: env.coordinator.micLevel)
        LevelRow(label: "Them", level: env.coordinator.systemLevel)
        // Named per stream by the coordinator, and only once a start has actually been
        // attempted — so a dead "Them" beside a working "You" says which half is broken,
        // and nothing flashes during the moment before the streams open.
        if let failure = env.coordinator.monitorFailure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow).font(.caption).lineLimit(3)
        }
    }

    @ViewBuilder
    private var idleSection: some View {
        if case .failed(let message) = env.coordinator.recordingPhase {
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).font(.caption).lineLimit(4)
        }
        Button {
            Task { await env.startRecording() }
        } label: {
            Label(env.callDetected ? "Record this call" : "Start recording",
                  systemImage: "record.circle")
        }
        // The popover's primary action while idle. "Plan a call…" stays secondary — one
        // prominent button per surface, or none of them reads as the answer.
        .buttonStyle(.borderedProminent)
        // The sheet itself is presented by MainWindow: a MenuBarExtra window can't present
        // one, so this sets the draft and brings up the window that can.
        Button {
            env.planningCall = PlannedCallDraft()
            AppDelegate.focusMainWindow()
        } label: {
            Label("Plan a call…", systemImage: "calendar.badge.plus")
        }
        if !env.plannedCalls.isEmpty {
            Text("\(env.plannedCalls.count) planned call\(env.plannedCalls.count == 1 ? "" : "s") — pre-fill from the form after you start.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func recordingSection() -> some View {
        if let warning = env.coordinator.streamWarning {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow).font(.caption)
        }
        if let p = env.coordinator.transcribeProgress, p.total > 0 {
            Text("Transcribed \(p.done)/\(p.total) chunks")
                .font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        RecordingControls(axis: .vertical)
    }
}

struct LevelRow: View {
    let label: String
    let level: Float
    var body: some View {
        HStack {
            Text(label).font(.caption).frame(width: 40, alignment: .leading)
            ProgressView(value: min(Double(level) * 4, 1.0))  // RMS is small; scale for visibility
        }
    }
}
