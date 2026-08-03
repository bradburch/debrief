# Debrief manual verification checklist

Run after any change to CaptureKit or the coordinator. Build: `./scripts/make-app.sh && open Debrief.app`.

1. **Permissions**: first launch prompts for Microphone and Notifications; starting a
   recording may prompt to record system audio — System Settings lists this under
   Privacy & Security > Screen & System Audio Recording (grant, relaunch).
2. **Detection**: start a test meeting (meet.google.com in a browser, mic on). Within ~15s
   the menu-bar icon becomes a phone, the popover shows "Call detected", and a
   notification pops up (first run: grant the notification permission prompt). Clicking
   the notification's **Record** button starts recording; clicking the notification body
   does NOT. Leaving the meeting without recording clears the notification.
3. **Recording**: click Record. Speak; confirm the "You" level bar moves. Have the other
   side speak (or play audio); confirm the "Them" bar moves. Both bars moving = both
   streams healthy.
4. **Silent stream warning**: mute system audio for 60s+ while recording; a yellow warning
   appears in the popover.
5. **Auto-stop on call end**: while recording a detected call, leave the meeting (close the
   tab / hang up) without touching Debrief. Within ~15s the recording stops and finalizes
   on its own. Conversely, staying in the call must NOT auto-stop (the per-process mic
   probe must not count Debrief's own capture). Metadata typed into the stop form after
   hanging up may be cut short by auto-stop (~10-15s window); sessions can be renamed
   afterwards.
6. **Stop & Debrief**: fill Company/Round, click Stop & Debrief. Phase shows Transcribing →
   Saving → Coaching, then idle. Session appears in the main window with a transcript where
   your words are YOU and theirs are THEM, with sane timestamps.
7. **Debrief**: with a valid API key in Settings, the debrief appears with scores, tags,
   highlights (click one — transcript scrolls), and action items.
8. **No key**: remove the API key; record a short session; it stays "coaching…/failed" and
   Settings → Retry pending debriefs completes it after re-adding the key.
9. **Crash recovery**: start a recording, `kill -9` the Debrief process mid-call, relaunch.
   The popover offers recovery; recovering produces a session from the partial audio.
10. **Audio deletion**: with "Keep raw audio" off, confirm the recordings folder (default
    `~/Library/Application Support/Debrief/recordings/`, or wherever Settings → Data
    locations points it) is empty after a successful debrief.
11. **Regenerate with criteria**: open a session, paste text into "Grading criteria for
    this interview", click Regenerate; the new debrief reflects the criteria. Reopen the
    session — the criteria text is still there.
12. **Local LLM provider**: Settings → provider "Local / OpenAI-compatible" + running
    Ollama: debrief completes; stop Ollama: session marks failed, retry works after restart.
13. **Custom round type**: drop `take_home_review.md` into the prompts folder: "Take Home
    Review" appears in the round picker; delete the file: existing sessions of that type
    still debrief (base rubric only).
14. **Calendar pre-fill**: Settings → Calendar pre-fill: with no calendar selected
    (or access not yet granted), Debrief falls back to `upcoming.json` — with an
    `upcoming.json` in Application Support, start a recording: "From calendar" lists
    the entries, and choosing one fills company, round type, and notes. With both the
    file absent and no calendar selected, the menu is hidden and typing a company by
    hand works as before.
15. **Calendar grant + picker**: Settings → Calendar pre-fill, click "Grant calendar
    access": macOS shows its own permission dialog listing every calendar on the Mac
    (including a Google account added in System Settings, if any). After allowing,
    the section switches to a calendar Picker and a status line ("Granted"); pick a
    calendar with an upcoming interview on it and the status line reports how many
    are visible. Start a recording: "From calendar" now lists entries sourced from
    the chosen calendar (title, notes, and any recognizable round type), with no
    network activity involved — this is a local read of macOS Calendar. Denying the
    prompt (or Privacy & Security > Calendars later) leaves the section showing
    "Denied" and Debrief keeps using `upcoming.json`.
16. **Continuity/cellular calls** — *root cause found and fixed 2026-07-29; this item is
    now a regression test.* History: during a Continuity cellular call (an iPhone call
    answered on the Mac) the "Them" bar never moved and the caller was absent from the
    transcript, while Zoom/Meet/browser calls captured fine. Diagnosis from a live call:
    ScreenCaptureKit delivered `sys-*.wav` chunks at full rate and correct length, every
    sample bit-exact zero. The control was free — of 26 recordings on disk, 20+ had
    healthy `sys` RMS (0.03–0.09) and only the Continuity ones were silent, so capture
    was not broken generally.

    The cause was structural, not a bug: `SCContentFilter(display:excludingWindows:)`
    scopes capture to audio from *windows on that display*, and a Continuity call is
    voiced by a windowless system daemon. It was never in the mix SCK was faithfully
    delivering. No `SCStreamConfiguration` change reaches it. `SystemAudioRecorder` now
    uses a **CoreAudio process tap** instead, which scopes by what reaches the output
    device; against the same live call it tracked speech at -15 dB and gaps at -80 dB
    while SCK wrote zeros.

    To regression-test, record a Continuity cellular call and confirm the "Them" bar
    moves and the caller appears in the transcript. If it looks silent again, the
    fastest triage is the chunks themselves rather than the UI — a full-length `sys`
    chunk of pure zeros means the tap is delivering but empty, a missing or short chunk
    means it isn't delivering at all:

    ```sh
    python3 - <<'EOF'
    import array, glob, math, os, wave
    d = max(glob.glob(os.path.expanduser(
        "~/Library/Application Support/Debrief/recordings/*")), key=os.path.getmtime)
    for f in sorted(glob.glob(os.path.join(d, "*.wav"))):
        w = wave.open(f, "rb"); n, sw = w.getnframes(), w.getsampwidth()
        a = array.array({2: "h", 4: "f"}[sw]); a.frombytes(w.readframes(n))
        rms = math.sqrt(sum((v / (32768.0 if sw == 2 else 1.0)) ** 2 for v in a) / len(a)) if len(a) else 0
        print(f"{os.path.basename(f):14s} {n/w.getframerate():5.1f}s "
              f"{'SILENT' if rms == 0 else f'rms={rms:.5f}'}")
    EOF
    ```

    Also worth checking here, since the tap replaced SCK: **auto-stop still works.** The
    old SCK path ran through `com.apple.replayd`, which held mic input for the whole
    recording and had to be denylisted in `DetectionProbes` or `callLikelyEnded` never
    fired. The tap runs in-process, so `getpid()` self-exclusion covers it — confirm a
    call still auto-stops after it ends rather than recording indefinitely.
17. **Interview types (Settings)**: the pane lists every round type, with "Transcript only"
    under `Mock Interview`. Check each path the unit tests can't reach:
    - **New type…** → name it "Take Home Review", confirm the caption reads "Saved as
      take_home_review.md", save, and confirm it appears in the picker when tagging a
      recording. Re-open **New type…** and type the same name: Save must stay disabled
      (collision), as it must for a name with no usable characters ("!!!").
    - **Duplicate** a scored type, save, and confirm the copy is independently editable.
    - **Delete** an unused type: confirms, then disappears. Delete one that a recording
      uses: blocked with a count, and the type survives. Deleting is only ever a prompt
      file — recordings already tagged with it keep their tag.
    - **Transcript only** checkbox: tick it on a scored type, save, reopen — the marker
      persists and is not duplicated in the prompt text. Untick it and the body survives.
    - Record a short session tagged `Mock Interview`: it transcribes, the session shows
      "transcript only" instead of a debrief, and **no API call is made** (watch the
      Pipeline tab, and confirm Settings > "Retry pending debriefs" reports "All caught
      up" rather than queueing it). "Re-run debriefs on current rubric" must skip it too.
18. **Claude subscription provider**: Settings > Coaching model > "Claude subscription
    (Claude Code CLI)". The pane should confirm the resolved binary path in green; if it
    shows the orange not-found warning, set the path explicitly. Then record a short
    session and confirm a debrief appears with scores on the round's real dimensions.
    Specific things to check, because the CLI path has no JSON schema behind it:
    - **Scores use the round type's dimensions**, not invented keys. Wrong keys mean the
      prose contract failed and the session should have been left `failed`, not stored.
    - **Launch the app from Finder, not a terminal**, at least once. A Finder-launched app
      inherits a minimal PATH, so a CLI found via a shell may be invisible to the bundle —
      that is exactly the failure `ClaudeCodeCLIClient.defaultSearchPaths()` guards.
    - **"Re-run debriefs on current rubric" across several sessions** — subscription rate
      limits are session-windowed, so watch for throttling that the metered API wouldn't hit.
      Failures here should leave sessions retryable, never block finalize.
    - Sign out of the CLI (`claude` logout) and confirm a debrief fails cleanly and stays
      retryable rather than hanging.
