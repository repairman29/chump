# Wedge Class Catalog

> **What this is**: enumeration of every fleet-wedge class we've experienced, with
> detection signatures, time-to-recovery targets, and the recovery playbook.
>
> **Why it exists**: Operator paramedic-time is the #1 cost. This catalog reduces
> "diagnose a new wedge from scratch" to "look up the signature, run the playbook."
>
> **How to use**: When `chump fleet wedge-watch` fires, find the matching signature
> here. Run the recovery section. If no signature matches, you found a new class —
> add it after recovery.

---

## Class definitions

A **wedge class** is a fleet-wide condition where:
- ≥3 PRs are simultaneously stuck (BLOCKED/DIRTY/FAILURE) for >30 min
- All share at least one common failure signature (same test, same error, same job)
- Standard auto-rescue (auto-rebase, retrigger, label nudge) does not clear it

A class is **not** the same as a single PR failure. Single PR failures resolve via
shepherd-curator rescue or auto-retrigger. A wedge is the *aggregate*.

---

## Class W-001 — gh API false-positive merge conflicts

**Signature**:
- `gh pr update-branch <N>` returns "Cannot update PR branch due to conflicts"
- `git fetch origin <branch> && git rebase origin/main` in a fresh worktree: SUCCEEDS with zero conflicts
- pr_auto_rebase_failed ambient events cluster on ≥3 PRs in <10 min

**Time-to-recovery target**: <2 min (fully automated)

**Detection**: `tail .chump-locks/ambient.jsonl | grep pr_auto_rebase_failed | wc -l` ≥ 3 in last 10 min

**Recovery playbook** (now automatic via INFRA-1958):
1. `pr-auto-rebase.sh` detects gh API failure
2. Falls back to local rebase in `/tmp/wt-<pr>`
3. If local rebase succeeds: `git push origin HEAD:<branch> --force-with-lease`
4. Emits `pr_auto_rebase_fallback` event
5. Only escalates to `pr_auto_rebase_failed` if local also fails

**Hardening shipped**: INFRA-1958 (`#2553`)

---

## Class W-002 — Runner-side binary cache lag

**Signature**:
- Tests grep `chump <subcommand>` output for new-feature keywords; grep fails
- `chump --version` on runner shows build SHA older than `origin/main` HEAD
- Affects `test-fleet-spec.sh`, `test-fleet-fanout.sh`, `test-rollup-semantic.sh`,
  `test-inspect-resume-scrap.sh`, similar binary-greping tests

**Time-to-recovery target**: <30 min (next cron tick)

**Detection**: `(/opt/homebrew/bin/chump --version | grep -oE '\([a-f0-9]+ built')` vs
`(git rev-parse --short=12 origin/main)` — diff means stale

**Recovery playbook** (now automatic via CREDIBLE-076):
1. `com.chump.refresh-runner-binary` launchd cron fires every 30 min
2. `scripts/setup/refresh-runner-binary.sh` rebuilds chump from origin/main
3. Hardcopies (not symlinks) to `/opt/homebrew/bin/chump` so cargo cleanups don't break runners
4. Idempotent — SKIPs if installed binary SHA matches main HEAD

**Manual override**:
```bash
cargo install --path /Users/jeffadkins/Projects/Chump --bin chump --force
cp ~/.cargo/bin/chump /opt/homebrew/bin/chump
chmod +x /opt/homebrew/bin/chump
```

**Hardening shipped**: CREDIBLE-076 (`#2559`)

---

## Class W-003 — Config-warning stdout pollution

**Signature**:
- Test captures `chump <cmd> 2>&1` and greps for expected output
- Output starts with `chump config warning: DISCORD_TOKEN not set or empty`
- Subsequent grep for actual output fails because warning ate the match

**Time-to-recovery target**: 0 (capability guard fires SKIP before grep)

**Detection**: Test failure log contains `chump config warning:` AND `expected.*got`

**Recovery playbook** (now structural via CREDIBLE-076):
- Every binary-touching test must have a capability guard (see
  `docs/process/CI_REQUIRED_CHECKS_DESIGN.md` § The capability-guard pattern)
- Guard either (a) checks subcommand presence and SKIPs if absent, or (b) strips
  `chump config (warning|info|debug):` lines before greping
- `scripts/ci/test-required-checks-self-audit.sh --strict` enforces

**Hardening shipped**: CREDIBLE-076/077/078 (`#2559/#2560/#2562`)

---

## Class W-004 — sqlite r2d2 lock contention under parallel CI

**Signature**:
- Test output contains `ERROR r2d2: database is locked`
- Multiple self-hosted CI runs are concurrent (≥2 on the same machine)
- Failures appear in tests that invoke chump commands hitting `state.db`

**Time-to-recovery target**: 0 (structurally eliminated)

**Detection**: grep CI logs for `r2d2.*database is locked`

**Recovery playbook** (now structural via INFRA-1959):
- ci.yml fast-checks/cargo-test/audit jobs set:
  ```yaml
  env:
    CHUMP_REPO: ${{ github.workspace }}
    CHUMP_LOCK_DIR: ${{ github.workspace }}/.chump-locks
  ```
- Forces per-checkout state.db (each CI run has its own `_work/<repo>/<repo>/.chump/state.db`)
- No cross-run contention possible

**Hardening shipped**: INFRA-1959 (`#2563`)

---

## Class W-005 — GIT_DIR env-leak from Actions runner-listener

**Signature**:
- `scripts/ci/test-pre-push-force-lease-guard.sh` fails: "hook allowed the stale-fetch force-push"
- Local repro of same test PASSES
- Only fails when run under self-hosted GitHub Actions runner

**Time-to-recovery target**: 0 (fixed at hook layer)

**Detection**: test-pre-push-force-lease-guard.sh in CI fail-log

**Recovery playbook** (now fixed via INFRA-1950):
- Pre-push hook explicitly uses `git -C "$REPO_ROOT"` for Guard 3's `merge-base`
  and `ls-remote` calls
- Ignores ambient GIT_DIR leaked by the runner-listener parent process

**Hardening shipped**: INFRA-1950 (now on main as of `9141e7f35`)

---

## Class W-006 — Branch force-push stomp (operator-induced)

**Signature**:
- Batch-rebase script force-pushes wrong content (often the prior PR's merge commit) over a
  branch
- `gh pr list` shows the PR auto-closed (orphan-PR-closer detects ahead=0 vs main)
- The original feature commit is orphaned in the reflog (still reachable but not referenced)

**Time-to-recovery target**: <15 min

**Detection**: `gh pr list --state closed --search "closed:>=<window>"` and check
mergedAt=null; verify branch HEAD vs expected commit message

**Recovery playbook**:
1. `git log --all --diff-filter=A --oneline -1 -- <known-file-added-by-PR>` finds orphan SHA
2. Cherry-pick onto fresh main:
   ```bash
   git worktree add /tmp/recover-<pr> origin/main
   cd /tmp/recover-<pr>
   git cherry-pick -X theirs <orphan-sha>
   ```
3. Resolve any `event-registry-reserved.txt` conflicts with take-both
   (sed strip `<<<<<<<|=======|>>>>>>>` markers, sort, dedupe)
4. `git push origin HEAD:<branch> --force-with-lease`
5. `gh pr create` if old PR is closed

**No structural fix yet** — this is operator-induced. The pattern is real though: any
batch-rebase script SHOULD verify each push doesn't reduce ahead count below the
expected delta.

**Follow-up**: file WEDGE-006-followup — pr-auto-rebase --safety-net flag that checks
"if push would result in ahead=0 vs main, abort"

---

## Class W-007 — Required-status-check absent from CI workflow

**Signature**:
- Branch protection requires status check named X
- PR's CI run never produces a status named X (no matching job exists)
- PR sits BLOCKED indefinitely; auto-merge can't fire

**Time-to-recovery target**: <5 min (operator action)

**Detection**:
```bash
gh api repos/repairman29/Chump/branches/main/protection/required_status_checks --jq .contexts
# vs
gh pr checks <PR> --json name | jq -r '.[].name'
# anything required not present = wedge candidate
```

**Recovery playbook**:
1. Either add the job to ci.yml, OR remove from required_status_checks
2. INFRA-1522 (open P0) will automate this: `chump fleet doctor` refuses `up` when
   required-check ↔ workflow-job mapping drifts

**Hardening**: INFRA-1522 (open, P0)

---

## Class W-008 — Auto-merge wedged on CLEAN state

**Signature**:
- PR shows mergeStateStatus=CLEAN, all required checks SUCCESS, autoMergeRequest=true
- Hours pass with no merge
- Often after a long-running CI completes during a quiet period

**Time-to-recovery target**: <5 min (single API toggle)

**Detection**: PR age > 1h + mergeStateStatus=CLEAN + autoMergeRequest set

**Recovery playbook**:
1. `gh pr merge <N> --auto --squash` (re-arm) — usually wakes it up
2. If still stuck: `gh pr merge <N> --squash --admin` (admin override)

**Hardening**: INFRA-1528 (open, P0) — auto-merge-armer that watches for this pattern
and re-fires automatically

---

## Class W-009 — Cascade: keystone PR blocks N children

**Signature**:
- One PR fixes a trunk-RED issue (test broken on main)
- N other PRs all fail the same test, all waiting for keystone to land
- Keystone itself has the fix in its test edit but its own CI still fails for unrelated reasons
- Removing keystone from queue (by closing or merging) cascades all N children

**Time-to-recovery target**: keystone's recovery time

**Detection**:
```bash
# all open PRs failing on the same line, plus one PR whose diff is exactly the test fix
gh pr list --state open --json number,statusCheckRollup | \
  jq '...' # group failed PRs by failure line; find the cohort
```

**Recovery playbook**:
1. Identify keystone (the PR whose diff contains the fix for the common failure line)
2. Drive keystone to merge first (with whatever combination of guards, retriggers,
   amendments, or admin override needed)
3. Other PRs cascade once main is green

---

## Class W-010 — Multi-layer protection (legacy + ruleset)

**Signature**:
- Operator updates branch-protection-main via REST API
- Subsequent admin-merge fails with `Repository rule violations found`
- Cause: GitHub Rulesets (newer feature) layer requires checks separately from legacy
  branch protection

**Time-to-recovery target**: <5 min

**Detection**: `Repository rule violations` error during gh pr merge --admin

**Recovery playbook**:
1. Check ruleset state: `gh api repos/<org>/<repo>/rulesets/<id>`
2. Patch ruleset rules array via PUT (PATCH 404s; PUT requires full body)
3. Re-attempt merge

**Already documented** in CREDIBLE-076 § Re-arming.

---

## Class W-011 — Installer-manifest drift

**Signature**:
- `pr-hygiene` job fails on every PR with `FAIL [unmapped] install-<name>.sh`
- `scripts/ci/test-install-script-manifest.sh` exits 1
- One or more `scripts/setup/install-*.sh` files have no entry in any of:
  REQUIRED_DAEMONS in `scripts/setup/chump-fleet-bootstrap.sh`,
  `scripts/setup/optional-installers-allowlist.txt`,
  `scripts/setup/deprecated-installers-allowlist.txt`

**Time-to-recovery target**: <5 min

**Detection**: `bash scripts/ci/test-install-script-manifest.sh 2>&1 | grep -c "FAIL \[unmapped\]"` > 0

**Recovery playbook**:
1. Identify unmapped installer(s) from the FAIL output
2. Decide bucket: required (load-bearing daemon) / optional (situational) / deprecated
3. Append filename to the appropriate manifest
4. Local verify: `bash scripts/ci/test-install-script-manifest.sh` exits 0
5. Tiny PR + admin-merge

**Hardening shipped**: none yet. Long-term: `chump fleet bootstrap --check` gate
emits `installer_manifest_drift` ambient event when a new installer lands without
a manifest entry (open follow-up).

**First seen**: 2026-05-25 wedge recovery — 5 installers landed across
CREDIBLE-076/META-088/INFRA-1898/INFRA-1924/META-098 without manifest updates,
blocking every PR's pr-hygiene gate. Fixed in RESILIENT-019 (`#2567`).

---

## Class W-012 — Workflow-env-overhead cascade

**Signature**:
- A test creates its OWN `$TMP/repo` fixture and invokes the `chump` binary
- The CI workflow sets `CHUMP_REPO: ${{ github.workspace }}` (INFRA-1959 et al)
- chump binary uses the workflow CHUMP_REPO override instead of the test's `cd $REPO`
- Test fails because the workflow's state.db lacks the test's seeded fixtures

**Time-to-recovery target**: <5 min per test

**Detection**: `test-*.sh` failing with gap-not-found or empty-database messages
when run under CI but PASSING locally; symptoms emerge AFTER any PR that adds
workflow-level CHUMP_REPO env to a job.

**Recovery playbook**:
1. Identify the failing test from the CI log
2. Add `unset CHUMP_REPO CHUMP_LOCK_DIR` directly after `mktemp -d` setup
3. Local verify: `bash scripts/ci/<test>.sh` PASSES from a clean env
4. Tiny PR + admin-merge

**Hardening shipped**: RESILIENT-020 patches `test-gap-preflight-ac-gate.sh`. Pattern is:
any test using `mktemp -d` + chump binary should `unset CHUMP_REPO CHUMP_LOCK_DIR` to
ignore workflow-level injection. About 10 such tests in tree as of 2026-05-25 — patched
lazily as they surface.

**Lesson**: workflow-level env vars can silently hijack per-test fixtures. Future broad
env additions to ci.yml should grep `scripts/ci/test-*.sh` for naive `mktemp -d`-and-
invoke patterns first.

**First seen**: 2026-05-25 — cascade from INFRA-1959 (own fix) into
`test-gap-preflight-ac-gate.sh`. Blocked CREDIBLE-076 § Re-arming canary #2564.
Fixed in RESILIENT-020.

---

## Recovery time SLOs

| Class | Target | Current |
|---|---|---|
| W-001 | <2 min | ✅ automated |
| W-002 | <30 min | ✅ automated (cron) |
| W-003 | 0 | ✅ structural |
| W-004 | 0 | ✅ structural |
| W-005 | 0 | ✅ shipped |
| W-006 | <15 min | 🟡 manual reflog recovery |
| W-007 | <5 min | 🟡 INFRA-1522 pending |
| W-008 | <5 min | 🟡 INFRA-1528 pending |
| W-009 | keystone-bound | 🟡 always |
| W-010 | <5 min | ✅ documented |
| W-011 | <5 min | 🟡 manual (long-term: chump fleet bootstrap --check) |
| W-012 | <5 min per test | 🟡 patch tests lazily as they surface |

## When you find a new class

Add a section here with:
1. Signature (3+ specific symptoms)
2. Time-to-recovery target
3. Detection (one-liner that surfaces it)
4. Recovery playbook (numbered steps)
5. Hardening shipped (or "TBD: file WEDGE-NNN")

Add the detection one-liner to `scripts/coord/wedge-watch.sh` so it auto-pages next time.
