# Coaching eval

Compares models (or prompts) on the real coaching call: each case goes through the app's own
`CoachingService.coach()` → `AnthropicClient`, then the grader reads back what landed in the
database.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift run DebriefEval --dry-run                 # plan + cost estimate, no API calls
swift run DebriefEval --approve-harness         # first run only: you approve the harness sha
swift run DebriefEval                           # sonnet-5-5 vs haiku-5-5, 5 reps, opus judge on rep 0
```

Results land in `.claude/hillclimb/coaching/`: `baseline/` is the first `--models` entry and
`v1/` the second. Each holds `results.jsonl`, `errors.jsonl` and `traces/`, with a
`summary.md` plus `report.html` at the top. A re-run resumes, skipping every (case, rep) it
already scored. Errors are always re-run.

## Flags

| flag | default | |
|---|---|---|
| `--models a,b` | `claude-sonnet-5-5,claude-haiku-5-5` | first → `baseline/`, then `v1/`, `v2/`… |
| `--reps N` | 5 | reps per (case, model) |
| `--cases x,y*` | all | ids or globs |
| `--judge-model ID` / `none` | `claude-opus-5-5` | |
| `--judge-reps N` | 1 | judge reps 0..N-1 only |
| `--concurrency N` | 4 | calls in flight |
| `--timeout-s N` | 300 | hard wall-clock ceiling per call, retries included |
| `--prompts-dir DIR` | `~/Library/Application Support/Debrief/prompts` | read-only |
| `--out DIR` | `.claude/hillclimb/coaching` | |
| `--report-builder PATH` | the claude-api skill's `build-report-lite.mjs` | skipped if it or `node` is missing |
| `--summary` | | rebuild `summary.md` and the report from what's on disk |

The cases are `fixtures/synthetic/*.json` (committed) plus `fixtures/local/*.json`, which hold
real transcripts and are gitignored. Round types marked transcript-only are skipped.

## Metrics

- **verdict_match** (headline): the stored `advancement` agrees with the real outcome
  (`expected.advances`). Only scored when the outcome is known. A missing verdict counts as a
  miss. The summary also reports precision, recall and specificity for "advances".
- **contract**: the status is `complete`, a feedback row exists, the score keys equal
  `dimensions(for:)`, every score is 1–5, the verdict is valid, there are 3–5 highlights, and
  every highlight or process-note timestamp is within ±5s of a real segment. The sub-checks
  `keys_ok`, `ts_grounded` (a fraction) and `n_highlights` are reported separately.
- **refused**: `stop_reason == refusal`. This is graded, not treated as an error.
- **chk_\***: assertions on the synthetic fixtures (verdict is no-advance, correctness below
  conciseness, process-note mentions, prompt-injection resisted, max mean score).
- **Judge** (`grounded`, `actionable`, `rationale_consistent`, `calibrated`, `judge_mean`):
  each criterion is a 0/1 from Opus. The judge never sees which model wrote the debrief. The
  rubric is in `Sources/DebriefEval/JudgeRubric.swift`.

The summary shows each metric's mean with a 95% CI, pass@k and pass^k per case for
`contract` and `verdict_match` (and flags any case where a rep broke the contract), tokens,
$ cost (failed calls included), p50/p95 latency, errors by class, and the prompt, schema and
harness hashes.

Rows with `status: truncated` are counted but kept out of the means, so compare the truncated
counts between models too. A failed attempt goes to `errors.jsonl` with a class (`http_4xx`,
`http_5xx`, `timeout`, `transport`, `decode`, `model_mismatch`, `harness`) and never to
`results.jsonl`. When only the judge fails, the scored row is kept without judge metrics, and
the judge error is logged with `stage: judge`.

## Cost

`--dry-run` prints an estimate: 10k in / 5k out tokens per coaching call and 12k / 1.5k per
judge call, at sonnet-5-5 $2/$10, haiku-5-5 $0.10/$0.50 and opus-5-5 $4/$20 per MTok. Long
real transcripts run well above 10k input tokens, so check a pilot's `usage` before trusting
the estimate.

## Safety

- Every (case, model, rep) gets a fresh `AppDatabase.inMemory()`. The app's database is never
  opened, and nothing is written outside `--out` and `eval/labels/`.
- The prompts directory is only read; `ensureDefaults()` is never called on it.
- The API key comes from `ANTHROPIC_API_KEY`, or else from Debrief's `secrets.json`. It is
  never printed.
- **Harness gate.** The runner hashes `Sources/DebriefEval/*.swift` together with
  `_state.json.harness_paths`, which covers the client, the service and the store. If the
  hash doesn't match the one you approved, it exits 2 until you re-run with
  `--approve-harness`. The gate detects changes; it is not a security boundary.
- `results.jsonl` stores each prompt in full, so for `fixtures/local` cases it contains real
  transcripts. Don't commit it.

## Judge calibration

```sh
swift run DebriefEval --judge-selftest     # paid, 4 Opus calls: a known-good debrief must pass every criterion; empty, "I don't know", and wrong-interview debriefs must fail every one
swift run DebriefEval --export-labels 30   # writes eval/labels/label.md + labels.json + _key.json (gitignored)
# label blind: items are item-NN in hashed order; don't open _key.json until you're done
swift run DebriefEval --agreement          # per-criterion agreement % and Cohen's kappa
```

Any criterion below 90% agreement gets flagged. Don't let that criterion drive a decision
until the rubric has been revised and re-checked.
