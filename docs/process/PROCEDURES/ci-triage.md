# CI Failure Triage (CREDIBLE-013)

When `cargo test` fails on a PR, the triage layer (`scripts/ci/triage-cargo-test-failure.sh`) automatically classifies the failures and posts a verdict to the GitHub job summary — the first thing a PR author sees when the build goes red. This eliminates manual log-reading for the most common failure classes.

## Verdict classes and example output

**`flake`** — all failures are registered in `docs/process/KNOWN_FLAKES.yaml`; the auto-rerun harness may have already recovered:
```
TRIAGE: flake — all 2 failed test(s) are registered flakes: known_flake_module::tests::test_env_race another_flake::tests::timing_sensitive
```

**`real`** — one or more failures are not in the flake catalog; a genuine regression needs a fix before merge:
```
TRIAGE: real — 1 test(s) not in flake catalog (need fix): real_bug_module::tests::broken_calculation
```

**`known-bug`** — a failed test name matches the title of an open gap; the failure is tracked and expected:
```
TRIAGE: known-bug — some_module::tests::slow_path matches open gap INFRA-1234; 0 flake / 1 real of 1 total
```

**`unknown`** — cargo output was empty or contained no parseable `FAILED` lines; investigate manually:
```
TRIAGE: unknown — cargo output present but no FAILED test names parsed
```

## Tuning the flake registry

Add an entry to `docs/process/KNOWN_FLAKES.yaml` under `flakes:` when you observe a test that fails intermittently due to a known race or environment issue. Every entry **must** include an open `tracking_gap:` pointing at the root-cause fix — the catalog is a stop-gap, not a parking lot.

```yaml
flakes:
  - test: module::tests::env_dependent_test
    reason: "mutates a shared env var; collides under parallel test execution"
    tracking_gap: INFRA-XXXX
    added: "2026-06-04"
    last_observed: "2026-06-04"
    max_reruns: 1
```

Remove the entry after 10 consecutive green CI runs once the tracking gap is resolved.

## Extending known-bug detection

The triage script searches open gaps for titles containing the failed test name fragment. It queries `.chump/state.db` directly via `sqlite3` (fastest), or falls back to `chump gap list --status open --json` if the DB is unavailable. To suppress gap lookup (e.g. in offline environments), set `CHUMP_TRIAGE_OFFLINE=1`.

The ambient event `kind=ci_triage_verdict` is emitted on every triage run and appears in `.chump-locks/ambient.jsonl` with fields: `verdict`, `failed_test_count`, `flake_test_count`, `real_test_count`, `commit`, `job`, `pr_number`.

## Bypasses

The triage step is `continue-on-error: true` — it is informational and never itself fails the build. The cargo-test step's own exit code is what gates merges.

Offline / no-DB environments: set `CHUMP_TRIAGE_OFFLINE=1` to skip the gap search.
