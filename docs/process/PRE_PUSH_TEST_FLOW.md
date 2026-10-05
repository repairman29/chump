# Pre-push / cargo-test-with-rerun flow (RESILIENT-224 slice, RESILIENT-918)

Snapshot of the current test-execution path a push goes through, and where
the known repo-path false-red tests live. Read this before touching either
`scripts/git-hooks/pre-push` or `scripts/ci/cargo-test-with-rerun.sh` — the
two systems are related but distinct (local gate vs. CI flake-absorber) and
easy to conflate.

## 1. Source files

| File | Role |
|---|---|
| `scripts/git-hooks/pre-push` | The local git pre-push hook. Guard 0b (~line 670) runs the full test suite before a push is allowed to leave the machine. |
| `scripts/ci/cargo-test-with-rerun.sh` | INFRA-764 wrapper. Runs a given test command once; if it fails and every failing test name is listed in `docs/process/KNOWN_FLAKES.yaml`, reruns once and treats a green rerun as pass. Used both in CI (`.github/workflows/ci.yml`) and by some local test scripts (`scripts/ci/test-status-flip-proof-of-merge.sh`, `scripts/setup/test-runner-lane-broad-canary.sh`). |
| `docs/process/KNOWN_FLAKES.yaml` | Catalog of known-flaky test names consulted by the rerun wrapper. Each entry requires a `tracking_gap:`. |
| `crates/chump-git-hooks/src/bin/chump-pre-push.rs` | INFRA-1997 Rust shim for the pre-push hook, opt-in via `CHUMP_PREPUSH_RUST=1`; not yet the default path. |
| `.github/workflows/ci.yml` (~line 1700-1710) | CI invokes `cargo-test-with-rerun.sh` wrapping both a full `cargo test --workspace` job and a sharded `cargo nextest run --workspace --partition count:N/4` job. |

## 2. Current test execution mechanism: cargo test vs nextest

- **Local pre-push (Guard 0b)** prefers `cargo-nextest` when present on
  `PATH`: `cargo nextest run --bin chump --tests --no-fail-fast`. If
  `cargo-nextest` is not installed, it falls back to
  `cargo test --bin chump --tests --no-fail-fast --quiet` with a loud WARN
  (CREDIBLE-278, `scripts/git-hooks/pre-push:747-756`).
- **CI** runs both: a `cargo test --workspace` job AND a sharded
  `cargo nextest run --workspace --partition count:${shard}/4` job
  (`.github/workflows/ci.yml:1707,1709`), each wrapped in
  `cargo-test-with-rerun.sh`.
- **Why nextest matters (CREDIBLE-175/CREDIBLE-278, PR #3597, commit
  `8845c97`):** `cargo test` runs all tests threaded in one process, so
  tests that read/write process-global env vars (`CHUMP_REPO`,
  `CHUMP_AMBIENT_LOG`, `SESSION_ID`, etc.) race each other and can false-red
  locally on a tree that CI proves green. `cargo nextest` gives every test
  its own process, matching what CI actually gates on. This is why the
  pre-push hook fails LOUD (not silently) when `cargo-nextest` is absent —
  see the WARN block at `scripts/git-hooks/pre-push:752-754`.
- The rerun wrapper's failure-line parser (`cargo-test-with-rerun.sh:115-157`)
  has to understand three distinct output shapes because of this: verbose
  `cargo test` FAILED lines, the `cargo test` quiet-mode `failures:` summary
  block, and ANSI-colored `nextest` `FAIL [time] (N/M) <bin> <path>` lines
  (RESILIENT-306).

## 3. Repo-path tests with known false-reds

These are catalogued in `docs/process/KNOWN_FLAKES.yaml`, all rooted in
env-var/process-global contention under threaded `cargo test` execution:

| Test | Reason |
|---|---|
| `doctor::tests::repo_env_missing_is_warn_not_fail` | Removes `CHUMP_REPO`/`CHUMP_HOME` then asserts `check_repo_env` returns Warn; parallel tests can set those vars in between (tracking: INFRA-977). |
| `diff_review_tool::tests::diff_review_empty_diff_returns_message` | Depends on `git diff` output in the test worktree; parallel tests mutate git state. |
| `repo_path::tests::repo_profiles_list_parses_git_root` | Reads `CHUMP_REPO` env var which parallel tests may mutate between set and read (tracking: INFRA-1008). |
| `repo_path::tests::set_working_repo_from_profile_roundtrip` | Mutates and reads back profile state; collides with parallel `repo_path` tests under `cargo test --tests`. |
| `adversary::e2e_rule_to_ambient::*` (3 tests) | Env-var contention on `CHUMP_AMBIENT_LOG`/`SESSION_ID`; module-local lock doesn't serialize against other modules' tests. |
| `proof_of_merge_tests::credible218_merge_older_than_200_commits_is_proven` | GHA-hosted-runner-only flake; residual git-fixture nondeterminism. |
| `health::tests::infra646_waste_events_counted` | Intermittent panic under parallel test load; env/ambient contention suspected. |

Since PR #3597 (CREDIBLE-175/CREDIBLE-278), the pre-push hook's default path
runs `cargo-nextest` (process-isolated), which structurally avoids the
`repo_path::*` class of false-reds above — they only reproduce under
threaded `cargo test`, i.e. when `cargo-nextest` is missing from `PATH` and
the WARN fallback fires, or in CI's separate `cargo test --workspace` job.
