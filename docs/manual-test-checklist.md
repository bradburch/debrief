# Debrief manual verification checklist

Run after any change to CaptureKit or the coordinator. Build: `./scripts/make-app.sh && open Debrief.app`.

1. **Permissions**: first launch prompts for Microphone and Notifications; starting a
   recording prompts for Screen Recording (grant in System Settings, relaunch).
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
