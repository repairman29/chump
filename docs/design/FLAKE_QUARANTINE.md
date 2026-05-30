# Flake Quarantine Mechanism

> META-140 (META-131 slice e). Designs the auto-skip-after-N-consecutive-fails
> path that keeps a single flaky test from wedging the queue. Pairs with
> META-134 (CI verified aggregator) — the aggregator treats a `QUARANTINE`
> verdict as a pass *only when* a backing follow-up gap exists, so the
> mechanism cannot silently hide regressions.

## Why a quarantine layer

Today a single flake — e.g. INFRA-1585 `pwa-onboarding.spec.ts:opens-the-onboarding-modal`
fails 40 % of runs from container DNS races — wedges every PR that touches
**any** part of the workspace. The cost compounds: every wedged PR burns
~15 min round-trip, the rebase-and-retry loop pushes other PRs behind main,
and the operator is forced to either (a) merge with `--no-verify` (and
silently ship the next regression on top of the flake) or (b) babysit
re-runs until the dice land. Both options are bad.

A quarantine layer breaks the loop by detecting **intermittent** failures
with a stable error fingerprint, auto-tagging the offending test as
`flake-quarantined`, and skipping it in subsequent runs. The same event
files a `RESILIENT P1` follow-up gap so the underlying bug stays visible
in the queue rather than melting into background noise.

## Definition of "flake"

A flake is a test that fails **intermittently** with the **same error
fingerprint** across PRs that **do not touch the test's code path**.

The three clauses each carry weight:

| Clause | Why it matters |
|---|---|
| **Intermittently** | A consistently-failing test is a regression, not a flake. Quarantining it would mask a real bug. The detector requires both passes and failures in the recent window. |
| **Same error fingerprint** | If a test fails for ten different reasons, the failures are unrelated and need individual triage. Fingerprint matching ensures the quarantine claim is "this *specific* failure mode is non-deterministic". |
| **PRs that do not touch the code path** | If the test fails on PRs that mutate its source/imports, the failure is almost certainly the PR's fault. Excluding those runs from the flake-rate calculation prevents author-induced failures from getting a flake free-pass. |

Identifiers are stable strings of the form `<crate>::<test_path>` for Rust
(e.g. `chump_gap::gap_store::tests::reserve_picks_next_id`) and
`<spec_file>:<test_name>` for Playwright/JS (e.g.
`tests/pwa-onboarding.spec.ts:opens the onboarding modal`).

## Detection algorithm

Per test identifier, the detector maintains a sliding window of the most
recent **N = 10** runs (across all PRs, all branches) in
`.chump/flake_tracker.db`. After each CI job completes, the detector
ingests the test result XML and:

1. Computes `error_fingerprint = sha256(first 200 chars of stderr/stack)[:16]`
   for each failure. The 200-char window is chosen empirically: it captures
   the panic message + first 2-3 stack frames without absorbing volatile
   line numbers from deeper frames.
2. Counts failures in the window where `error_fingerprint` matches the
   most-common fingerprint for that test.
3. If **3 or more** of the last 10 runs match the same fingerprint **AND**
   at least 1 run in the window succeeded → tag the test as
   `flake-quarantined`.
4. Records the quarantine timestamp, the offending fingerprint, and a
   reference to the auto-filed follow-up gap.

The quarantine tag **persists for 14 days** OR until the tracked test
**passes 5 consecutive times** (whichever comes first). Both expiry
conditions emit `kind=flake_unquarantined` and reopen the underlying
follow-up gap so the operator sees the test back on the floor.

### Why 3-of-10 with a passing-run requirement

| Threshold | Behavior | Rejected because |
|---|---|---|
| 1 failure | Quarantine on first hiccup | Author-induced first-run failures (compile error, bad test data) would self-quarantine on PR open. |
| 2-of-10 | Quarantine on second occurrence | Two failures within 10 runs can easily be "I broke main twice in a row" rather than a flake. False-quarantine rate spikes. |
| **3-of-10 with ≥ 1 pass** | Quarantine after sustained intermittency | Three failures inside ten runs *with* at least one pass mixed in is the canonical flake signature. Pure regression would never produce a pass in the same window. |
| 5+ in 10 | Quarantine only on chronic flakes | The fix window for chronic flakes (the operator manually skips for hours) is exactly what this mechanism is supposed to *eliminate*. Waiting that long defeats the purpose. |

## CI integration

A new script `scripts/ci/flake-detector.sh` runs as the final step of each
`cargo-test`, `cargo-nextest`, and `e2e-pwa` job in `.github/workflows/ci.yml`.
It ingests the test result artifact (junit-xml or nextest-json), updates
`.chump/flake_tracker.db`, and emits ambient events for any quarantine
transitions.

Test runners filter on the quarantine tag:

```bash
# cargo-nextest path
cargo nextest run --filter 'not test(=flake-quarantined)'

# Playwright path — quarantine list applied via grep-invert before exec
QUARANTINED=$(sqlite3 .chump/flake_tracker.db \
  "SELECT test_path FROM flake_quarantine WHERE datetime('now') < expires_at")
npx playwright test --grep-invert "$QUARANTINED"
```

When at least one test was skipped, the job verdict is
**`SUCCESS-WITH-QUARANTINE`** rather than plain `SUCCESS`. The CI verified
aggregator (META-134) handles the verdict as follows:

| Verdict | Aggregator treatment |
|---|---|
| `SUCCESS` | Pass. |
| `SUCCESS-WITH-QUARANTINE` + backing follow-up gap exists | Pass. Logged in verdict bundle for transparency. |
| `SUCCESS-WITH-QUARANTINE` + no backing follow-up gap | **Fail.** Emit `kind=quarantine_unbacked` and block the PR. |
| `FAILURE` | Fail (regardless of quarantine state). |

The "must have a backing gap" rule is the safety valve: it makes it
**impossible** to silently quarantine a test without leaving an audit
trail in the gap registry.

## Follow-up gap auto-file

On a new quarantine event, `flake-detector.sh` files a gap via the
existing `chump gap reserve` path:

```bash
chump gap reserve \
  --domain INFRA \
  --priority P1 \
  --effort s \
  --title "RESILIENT P1: ${TEST_PATH} flake-quarantined ${FAIL_COUNT}/${WINDOW_SIZE} runs failed (error: ${FINGERPRINT})" \
  --notes "auto-filed by flake-detector.sh; quarantine expires ${EXPIRES_AT}"
```

The gap body is templated with:

- The test identifier
- The error fingerprint and a representative stack trace from the most
  recent failure
- Links to the last 3 failing CI runs
- Acceptance criteria (auto-populated):
  1. Reproduce the failure locally (script provided in body)
  2. Identify root cause (race, ordering, external dep, etc.)
  3. Fix or rewrite the test
  4. Remove the quarantine tag via `chump fleet flakes unquarantine <test>`
  5. Test passes 5 consecutive times in CI

The filed gap ID is written back to `flake_quarantine.follow_up_gap` so
the aggregator can verify the backing gap on every run.

## Operator surface

```
chump fleet flakes                       # list currently quarantined tests
chump fleet flakes show <test>           # show fingerprint, runs, follow-up
chump fleet flakes unquarantine <test>   # manually remove (emits ambient)
chump fleet flakes quarantine <test>     # manually add (rare; pre-empts repeat)
```

`chump fleet flakes` (no arg) output:

```
TEST                                                    QUARANTINED    EXPIRES    FOLLOW-UP
tests/pwa-onboarding.spec.ts:opens onboarding modal     3h ago         13d 21h    INFRA-flake-014
chump_worker::tests::picks_oldest_first                 2d 6h ago      11d 18h    INFRA-flake-012
```

Ambient event kinds (registered in `docs/observability/EVENT_REGISTRY.yaml`):

- `flake_quarantined` — fields: `test_path`, `fingerprint`, `fail_count`, `window_size`, `follow_up_gap`, `expires_at`
- `flake_unquarantined` — fields: `test_path`, `reason` (`expiry` | `passed_5x` | `manual`), `quarantine_duration_s`
- `quarantine_unbacked` — fields: `test_path`, `pr_number` (aggregator fail signal)

Each emit site carries an adjacent `# scanner-anchor: "kind":"<x>"` comment
per the register-without-emit discipline (CLAUDE.md hard rule).

## Schema — `.chump/flake_tracker.db`

```sql
CREATE TABLE IF NOT EXISTS flake_run (
  test_path         TEXT NOT NULL,
  run_id            TEXT NOT NULL,         -- CI run id, unique per attempt
  pr_num            INTEGER,               -- nullable for main-branch runs
  conclusion        TEXT NOT NULL,         -- 'pass' | 'fail' | 'skip'
  error_fingerprint TEXT,                  -- nullable when conclusion='pass'
  ts                TEXT NOT NULL,         -- ISO-8601 UTC
  PRIMARY KEY (test_path, run_id)
);
CREATE INDEX IF NOT EXISTS idx_flake_run_path_ts ON flake_run(test_path, ts DESC);

CREATE TABLE IF NOT EXISTS flake_quarantine (
  test_path         TEXT PRIMARY KEY,
  quarantined_at    TEXT NOT NULL,         -- ISO-8601 UTC
  fingerprint       TEXT NOT NULL,         -- offending fingerprint
  follow_up_gap     TEXT NOT NULL,         -- e.g. 'INFRA-flake-014'
  expires_at        TEXT NOT NULL,         -- quarantined_at + 14d
  consecutive_passes INTEGER NOT NULL DEFAULT 0  -- resets to 0 on fail
);
```

Window queries are bounded by the `idx_flake_run_path_ts` index — the
detector's hot path is "give me the last 10 rows for `<test_path>`" which
is O(log n) on the index plus 10 row reads. At a fleet rate of ~200 test
results/hour, the table grows ~5 MB/month; an idempotent monthly prune
keeps only the last 90 days per test.

## Trade-offs

| Risk | Mitigation |
|---|---|
| **False quarantine** — a real regression looks like a flake because a partially-broken codebase happens to pass intermittently | (a) Backing follow-up gap is **mandatory** — operator can always see what's hidden. (b) 14-day hard expiry caps the blast radius. (c) `quarantine_unbacked` is a CI failure, not a warning. |
| **Quarantine creep** — operator gets used to seeing `SUCCESS-WITH-QUARANTINE` and stops checking the follow-up queue | `chump fleet flakes` in the SLO dashboard; weekly digest counts quarantined tests; aggregate count > 10 emits `kind=quarantine_creep` and pages the operator. |
| **Author games the system** — a contributor learns to push 3 failing runs in a row to auto-skip a test they don't want to fix | Detector excludes runs from PRs that *touch the test's source path* from the flake-rate calculation. A contributor cannot quarantine the test they just modified. |
| **Fingerprint collision** — two genuinely different failure modes hash to the same prefix | sha256 over 200 chars makes collision astronomically unlikely. If it ever fires, the quarantine still rests on intermittency + backing-gap requirements, so the worst case is one extra entry in the follow-up queue. |
| **Detector itself flakes** — if `flake-detector.sh` crashes, the whole CI job fails | Detector runs as a `continue-on-error: true` step. Failure is logged as `kind=flake_detector_error` ambient but does not block the PR. |

## Open questions (not in scope for this design)

1. **Cross-OS fingerprinting** — should Linux and macOS runs share a
   fingerprint, or is OS-specific quarantine sufficient? Initial design
   assumes shared; revisit if cross-OS false quarantines surface.
2. **Test-path renames** — if a test is renamed, the quarantine entry is
   orphaned. A future hook in `flake-detector.sh` could grep for git
   renames at quarantine-load time; punted for v1.
3. **Sub-test granularity** — Rust `proptest` cases and Playwright
   `test.each` rows generate per-iteration identifiers. v1 quarantines at
   the parent-test level; per-iteration quarantine is a future tune knob.

## References

- META-131 — parent gap, "(e) flake quarantine" slice
- META-134 — CI verified aggregator (consumer of `SUCCESS-WITH-QUARANTINE`)
- INFRA-1585 — the canonical PWA onboarding flake that motivated this design
- `docs/observability/EVENT_REGISTRY.yaml` — event-kind registration target
- `scripts/ci/flake-detector.sh` — the executable surface (to be implemented)
