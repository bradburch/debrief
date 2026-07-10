# Debrief manual verification checklist

Run after any change to CaptureKit or the coordinator. Build: `./scripts/make-app.sh && open Debrief.app`.

1. **Permissions**: first launch prompts for Microphone; starting a recording prompts for
   Screen Recording (grant in System Settings, relaunch).
2. **Detection**: start a test meeting (meet.google.com in a browser, mic on). Within ~15s
   the menu-bar icon becomes a phone and the popover shows "Call detected".
3. **Recording**: click Record. Speak; confirm the "You" level bar moves. Have the other
   side speak (or play audio); confirm the "Them" bar moves. Both bars moving = both
   streams healthy.
4. **Silent stream warning**: mute system audio for 60s+ while recording; a yellow warning
   appears in the popover.
5. **Stop & Debrief**: fill Company/Round, click Stop & Debrief. Phase shows Transcribing →
   Saving → Coaching, then idle. Session appears in the main window with a transcript where
   your words are YOU and theirs are THEM, with sane timestamps.
6. **Debrief**: with a valid API key in Settings, the debrief appears with scores, tags,
   highlights (click one — transcript scrolls), and action items.
7. **No key**: remove the API key; record a short session; it stays "coaching…/failed" and
   Settings → Retry pending debriefs completes it after re-adding the key.
8. **Crash recovery**: start a recording, `kill -9` the Debrief process mid-call, relaunch.
   The popover offers recovery; recovering produces a session from the partial audio.
9. **Audio deletion**: with "Keep raw audio" off, confirm
   `~/Library/Application Support/Debrief/recordings/` is empty after a successful debrief.
- [ ] Open a session, paste text into "Grading criteria for this interview", click Regenerate; the new debrief reflects the criteria. Reopen the session — the criteria text is still there.
- [ ] Settings → provider "Local / OpenAI-compatible" + running Ollama: debrief completes; stop Ollama: session marks failed, retry works after restart
- [ ] Drop `take_home_review.md` into the prompts folder: "Take Home Review" appears in the round picker; delete the file: existing sessions of that type still debrief (base rubric only)
