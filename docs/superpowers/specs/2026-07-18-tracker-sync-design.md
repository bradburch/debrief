# Job-search tracker sync

Connect Debrief to the job search's external source of truth: pull upcoming
interviews in from a dedicated Google Calendar, push finished debriefs out to a
Google Sheet (+ transcript in Drive) and a Notion page.

## Decision: MCP first, minimal app code

Almost all of this needs **no Swift**. Debrief already writes one self-contained
Markdown file per session (`SessionMarkdown.render`, called from
`RecordingCoordinator` on every finalize when `exportDirectory` is set). Claude
Code has Google Calendar, Google Drive, and Notion MCP servers connected. So the
sync runs in Claude's process against files on disk, not in the app.

This keeps Debrief's privacy model intact: **the app never talks to Google or
Notion.** No OAuth, no token storage, no HTTP client beyond the two existing LLM
backends. Only the pull side needs app code, and only to *read a local file*.

Rejected: building Sheets/Drive/Notion clients into the app. It buys automatic
background sync at the cost of the first credentialed network integration in a
local-only app. Revisit only if the MCP flow proves too manual in practice.

## Push (no app code)

Trigger: on request, or on a `/loop`. Source: the configured `exportDirectory`.

For each Markdown file not yet synced:

1. **Drive** — upload the file as-is.
2. **Sheet** — append a row: date, company, round type, advancement verdict,
   overall score, weakness tags, Drive link.
3. **Notion** — create one page per interview: debrief prose, scores, action
   items, process notes; transcript inside a collapsed toggle.

Sheet and Notion both receive the data by design — the Sheet is the at-a-glance
pipeline view, Notion is the readable record.

**The target schema is read every run, not stored.** Before writing, the sync
reads the Sheet's header row and the Notion database's property list (names and
types), then maps Debrief's fields onto whatever is actually there by normalized
name against a synonym list. There is no stored mapping to drift out of date, and
adding a column on the tracker side needs no change here — it simply starts
getting filled.

The rules that keep this from corrupting a hand-maintained tracker are the
negative ones:

- **Never create, rename, delete, or reorder a column or property.**
- **Never write to a column that wasn't matched.** A Debrief field with no home is
  skipped and reported, not improvised into a new column.
- **Respect the declared type.** A Notion `select` is written only if the value is
  already among its options; otherwise the field is reported and skipped.
- **Ambiguity is reported, never guessed.** If two columns both plausibly match one
  field, write neither and say so.

A missing target column is therefore a report, not an error, and never a silent
overwrite of the wrong column.

**Sync state:** none stored. `SessionMarkdown.filename(for:)` is deterministic
(`yyyy-MM-dd-{company-slug}-{roundtype}-{id}.md`), so an existing Drive file or
Sheet row with that session id means it is already synced. Re-running is
idempotent: overwrite the Drive file, update the matching row in place.

## Pull (small app change)

1. Claude reads the **dedicated interview calendar** — every event on it is an
   interview, so no title parsing and no guest heuristics. The calendar name
   lives in the sync prompt, not in app Settings; the app never reads a
   calendar.
2. Claude writes `upcoming.json` into Debrief's data directory:
   `[{ company, roundType, start, notes }]`.
3. The app reads it and offers those entries when starting a recording: picking
   "Stripe — System Design, 2pm" fills company, round type, and notes.

App-side scope: read and decode one JSON file, and turn `MenuBarView`'s Company
`TextField` into a combo box backed by it. Free-form typing must keep working
exactly as it does today — the file is a convenience, never a requirement.
A missing, stale, or malformed `upcoming.json` degrades to today's behavior
silently; it is a cache, not state.

Round type comes from the event only if it matches a known `RoundType`;
otherwise the picker keeps its current default and the user selects.

## Explicitly out of scope

- **Conflict resolution.** Push writes, pull reads, and they never touch the
  same field. Renaming a company in Notion has no effect on Debrief.
- **Matching a recording back to the calendar event it came from.** The pull
  side pre-fills text; it does not create a link that the push side must honor.
- Deleting or archiving rows/pages when a session is deleted in Debrief.

## Testing

- `upcoming.json` decoding: valid file, absent file, malformed file, unknown
  round type. Absent and malformed must both yield an empty list, not a throw.
- Push has no app code and therefore no unit tests; verify by running it once
  against a scratch Sheet, Drive folder, and Notion database.
- Recording flow with the combo box is a hardware path — add it to
  `docs/manual-test-checklist.md` rather than testing it in the suite.
