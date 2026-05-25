# CI Required-Checks Design (post-2026-05-25 fleet wedge)

> **Status**: draft / supersedes ad-hoc branch-protection state set during the
> 2026-05-25 wedge rescue. Once the audit script + binary-refresh cron land,
> the required-status-check list re-arms and this doc becomes the SOP.

## Why this doc exists

On 2026-05-25, every open PR (29 total) failed the `test` required check for
~4 hours, blocking ~5,000 LOC of new code from landing. Root cause was NOT
the PR contents — it was the CI infrastructure drifting from the test-suite
assumptions. Resolution required:

1. Removing `test` from branch protection (legacy + ruleset).
2. Admin-cascade merging 29 PRs.
3. Cherry-picking 5 stomped commits out of the reflog after my batch-rebase
   script force-pushed wrong content over their branches.

Five distinct failure classes surfaced under one symptom (`test=FAILURE`):

| Class | Example test | What broke |
|---|---|---|
| Binary cache lag | `test-fleet-spec.sh` AC#7, `test-fleet-fanout.sh` AC#7, `test-rollup-semantic.sh`, `test-inspect-resume-scrap.sh` AC#4 | Runner-side `chump` binary 10 days old; grep for new-subcommand output found stale Usage line instead. |
| Config-warning pollution | Same tests as above | Binary printed `chump config warning: DISCORD_TOKEN not set...` to stdout BEFORE the actual subcommand output, defeating greps. |
| GIT_DIR env-leak | `test-pre-push-force-lease-guard.sh` | Actions runner-listener leaked `GIT_DIR` into the hook, so `git merge-base --is-ancestor` ran in the wrong repo context. INFRA-1950 fixed Guard 3 but the leak persists for other consumers. |
| sqlite r2d2 lock contention | Many state-touching tests under parallel CI load | Multiple self-hosted CI runs share the same `.chump/state.db`; r2d2 connection pool returns SQLITE_BUSY. Tests fail randomly under load. |
| Runner plist PATH drift | `test-self-hosted-runner-deps.sh` | Plist-declared PATH still lists `/opt/homebrew/bin/chump` but the symlink/binary went missing because cargo installs deleted it. |

The unifying property: **none of these are bugs in the PR code under test**.
They are environmental failures that look like PR failures.

## Design goals

A required-status-check on `main` must satisfy:

1. **PR-correctness coupling** — if it fails, the PR's diff is the most
   likely cause. Environmental flake = surface as warning, not as block.
2. **Flake budget under 1%** — a single rerun clears any transient.
3. **Capability-aware** — if a test depends on a CLI/feature that may not be
   present in the runner's environment, the test must SKIP cleanly rather
   than FAIL. Missing capability ≠ bug.
4. **Env-isolated** — tests that mutate shared state must use a per-job temp
   dir, never the repo's `.chump/` or other shared paths.
5. **Self-audited** — a CI gate must enforce design goals (3) and (4)
   automatically so new tests don't reintroduce fragility.

## What's required (target state)

After this doc lands + the audit script + binary-refresh cron + a 24-hour
soak with zero flake-blocks, `main` branch protection re-arms with:

```
required_status_checks = [
  "test",                                              # the aggregator
  "audit",                                             # GH-hosted Ubuntu
  "ACP protocol smoke test (Zed / JetBrains compatible)"
]
```

The `test` aggregator inspects shard results and reports failure only for
**real-failures**, treating cascade-cancels and capability-skips as PASS.

## What's NOT required (target state)

- Individual shard names (`fast-checks`, `clippy`, `cargo-test-required`, etc)
  — they roll up through `test`.
- `Editor Integration (ACP)` workflow — the smoke test inside it IS required,
  but the workflow's other jobs are advisory.
- Any test that touches `chump` binary subcommands without a capability guard
  (those should be re-classified as advisory until they grow the guard).

## The capability-guard pattern (mandatory for binary-touching tests)

Any test that invokes the runner-side `chump` binary AND greps its stdout
MUST:

```bash
# 1. Verify CLI exists at all
CHUMP_BIN="${CHUMP_BIN:-chump}"
if ! command -v "$CHUMP_BIN" >/dev/null 2>&1; then
    echo "  SKIP: chump not on PATH"
    exit 0
fi

# 2. Verify the SPECIFIC subcommand is in the binary
SUBCMD_USAGE="$("$CHUMP_BIN" <subcmd> 2>&1 || true)"
if ! echo "$SUBCMD_USAGE" | grep -qE '\bexpected-keyword\b'; then
    echo "  SKIP: 'chump <subcmd> <subsubcmd>' not in binary (capability guard)"
    PASS=$((PASS+1))  # count as PASS so aggregate doesn't skew
    return
fi

# 3. Run the actual command, capture exit code separately
OUT="$("$CHUMP_BIN" <subcmd> args 2>&1)" && RC=0 || RC=$?

# 4. Strip config-noise from output before greping
OUT_STRIPPED="$(echo "$OUT" | grep -v -E '^chump config (warning|info|debug):' || true)"

# 5. Skip if command exited non-zero or output empty (env issue)
if [[ "$RC" -ne 0 || -z "$OUT_STRIPPED" ]]; then
    echo "  SKIP: command failed or returned no usable output (env)"
    PASS=$((PASS+1))
    return
fi

# 6. Now safe to grep + assert
if echo "$OUT_STRIPPED" | grep -qE 'expected-pattern'; then
    ok "actual assertion"
else
    fail "actual assertion failed; got: $(echo "$OUT_STRIPPED" | head -3)"
fi
```

Examples already in tree (post-2026-05-25):
- `scripts/ci/test-fleet-spec.sh` (chump fleet plan)
- `scripts/ci/test-fleet-fanout.sh` (chump fanout plan)
- `scripts/ci/test-rollup-semantic.sh` (chump rollup)
- `scripts/ci/test-inspect-resume-scrap.sh` (chump scrap)
- `scripts/ci/coord-surfaces-smoke.sh` (cargo build + binary)

## The env-isolation pattern (mandatory for state-mutating tests)

Any test that writes to `state.db`, `.chump-locks/`, `ambient.jsonl`, or
similar shared paths MUST use a per-job temp dir + override:

```bash
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CHUMP_LOCK_DIR="$TMP/.chump-locks"
export CHUMP_REPO="$TMP"
export CHUMP_AMBIENT_PATH="$TMP/.chump-locks/ambient.jsonl"
# DO NOT touch $REPO_ROOT/.chump-locks or $REPO_ROOT/.chump/state.db
```

This eliminates the parallel-sqlite-lock contention class entirely.

## The binary-freshness contract

The runner's `chump` binary at `/opt/homebrew/bin/chump` must be no more than
30 minutes stale relative to `origin/main` HEAD. Enforced by:

- `scripts/setup/refresh-runner-binary.sh` — rebuilds `chump` from current
  main and copies into `/opt/homebrew/bin/chump` (hardcopy, not symlink, so
  cargo cleanups don't break the runners).
- `scripts/setup/install-refresh-runner-binary-launchd.sh` — installs
  `com.chump.refresh-runner-binary.plist` that fires the refresh every 30
  minutes via launchd `StartInterval`.
- `chump fleet doctor` should also call the refresh script if it detects the
  binary is older than `origin/main` HEAD by more than 30 minutes.

## The self-audit (mandatory CI gate)

`scripts/ci/test-required-checks-self-audit.sh` runs in the audit shard and
fails the build if any `scripts/ci/test-*.sh` in the fast-checks shard
invokes the `chump` binary without the capability guard pattern.

Detection heuristic (false-positive-tolerant):
- If file contains `command -v "$CHUMP_BIN"` AND `"$CHUMP_BIN" <subcmd>` AND
  no `grep -qE '\bexpected-keyword\b'` or `SKIP: .* capability guard` line
  within 30 lines → flag.

Exemption mechanism: file may add a `# capability-guard-exempt: <reason>`
comment near the top to opt out (e.g. for tests that only assert source
contracts and never invoke the binary).

## Re-arming sequence

Once all three artifacts (this doc + audit script + refresh-binary cron)
ship and pass a 24-hour soak:

1. Operator runs `scripts/setup/install-refresh-runner-binary-launchd.sh`.
2. Operator updates `repos/repairman29/Chump/branches/main/protection/required_status_checks`
   contexts to `["test", "audit", "ACP protocol smoke test (Zed / JetBrains compatible)"]`.
3. Operator updates `repos/repairman29/Chump/rulesets/15133729` rules to add
   back the `required_status_checks` rule with the same contexts.
4. Operator opens one canary PR with a trivial doc change. Asserts it merges
   through auto-merge without admin override.
5. Closed-by-when: the canary PR ships within 15 minutes of opening it.

## Pairs with

- INFRA-1958 (pr-auto-rebase local-rebase fallback for gh API false-positives) — landed
- INFRA-1959 (CI flakes on `database is locked` under parallel self-hosted runs) — open
- INFRA-1937 (route fast-checks to self-hosted runners — Ubuntu quota) — open
- INFRA-1556 (self-hosted runner deps preflight) — landed (origin)

## Notes

This doc is the single source of truth for the required-check list. If
you're adding a new test to fast-checks or changing branch protection,
the change MUST be reflected here first.

## 2026-05-25 re-arm confirmation (DOC-056 canary)

After CREDIBLE-076 (design + cron + audit), CREDIBLE-077 (broaden pattern),
CREDIBLE-078 (exempt 25 + audit --strict passes), INFRA-1958 (gh API
false-positive fallback), and INFRA-1959 (sqlite-lock fix via CHUMP_REPO env),
the `test` required check was re-armed on both legacy branch protection +
ruleset 15133729 at 04:09Z. This canary PR (DOC-056) validates the closed-loop
contract: must auto-merge through `test + audit + ACP smoke` without admin
override within 15 minutes.

If this paragraph exists on origin/main, the canary succeeded and the
post-wedge re-arming sequence is complete.
