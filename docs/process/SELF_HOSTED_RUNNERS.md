# Self-hosted GitHub Actions runners (INFRA-1534)

> **Status:** infrastructure shipped; workflow migration follow-up.
> Why: 2026-05-15/16 paramedic session hit a 12+ hour stall partly because GitHub's
> org-tier concurrency cap saturated at ~2 concurrent runners. With 24+ queued
> workflow runs and a 5-15 min cycle per run, the drain rate alone gated everything.

## The problem this solves

Chump's CI runs 5 workflows per PR (CI, Editor Integration (ACP), Repo health,
no-anthropic-smoke, Gap Status Guard) plus occasionally Release. The current
GitHub-hosted plan provides ~2 concurrent runner slots, which means **30+ PRs
of queue depth and ~30 min worst-case drain time** before any single PR can
land. That's the rate ceiling regardless of how clean our PRs are.

Self-hosted runners bypass the cap entirely. GitHub still orchestrates
(webhook triggers, status checks, artifact storage); only the *job execution*
moves to your hardware. With one M4 runner = ~2× throughput. With a 4-node
Pi mesh = ~5×. The bottleneck stops being CI capacity.

## Install

```bash
scripts/setup/install-self-hosted-runner.sh
```

The script:
1. Fetches the latest `actions-runner` tarball (auto-detects platform/arch).
2. Registers with `repairman29/chump` using a registration token from `gh api` (or `--token`).
3. Installs a launchd service (`com.chump.actions-runner`) that auto-restarts on crash + reboot.
4. Logs to `~/Library/Logs/Chump/actions-runner.{log,err}`.

Idempotent. Re-running is a no-op if a healthy runner is already registered.

## Verify

```bash
scripts/setup/install-self-hosted-runner.sh --check
```

Returns exit 0 only when **both** conditions hold (INFRA-1568):

1. **Registration check.** ≥1 runner is online for `repairman29/chump`.
2. **Broad canary pass.** The full production workflow step-set
   (`fast-checks` + `clippy` + `cargo-test` + `ACP smoke`) runs end-to-end on
   the candidate lane and every step exits 0.

The narrow "is the runner registered?" check is necessary but not sufficient.
The 2026-05-16 cascade (INFRA-1556 chump-PATH, INFRA-1539 apt-guard,
INFRA-1561 chump --acp silent) shipped because the previous narrow canary
(#2239 — `cargo build` only) reported OK while three production steps were
broken. **No runner is declared ready until the broad canary passes.**

To skip the canary gate (operator override — logs to ambient as
`kind=runner_canary_skipped`):

```bash
CHUMP_SKIP_CANARY=1 scripts/setup/install-self-hosted-runner.sh --check
# or:
scripts/setup/install-self-hosted-runner.sh --skip-canary
```

## Upgrade existing runners (INFRA-1556)

```bash
scripts/setup/install-self-hosted-runner.sh --upgrade
```

Scans `~/Library/LaunchAgents/com.chump.actions-runner*.plist`, rewrites each
plist's `PATH` to the current default (`~/.cargo/bin` + `~/.rustup/toolchains/<host>/bin`
+ `~/.local/bin` + system bins), and reloads via `launchctl bootout`/`bootstrap`.
Idempotent — re-running on already-patched plists is a no-op.

Use this when a workflow step fails with `exit code 127` (command not found) —
the runner's effective PATH is the only env launchd-bootstrapped processes see,
so missing entries here surface as cryptic failures during CI.

## Uninstall

```bash
scripts/setup/install-self-hosted-runner.sh --uninstall
```

Removes the launchd plist and runner directory. Re-registration possible afterward.

## Dependencies (INFRA-1556)

Workflow steps under the self-hosted lane invoke these CLIs. Every one must be
reachable via the plist's `PATH`. The installer's smoke test
[`scripts/ci/test-self-hosted-runner-deps.sh`](../../scripts/ci/test-self-hosted-runner-deps.sh)
asserts this on every CI run:

| CLI | Where it lives | Used by |
|---|---|---|
| `chump` | `~/.cargo/bin/chump` (rustup-managed) OR `~/.local/bin/chump` (manual install) OR `/opt/homebrew/bin/chump` (brew, if packaged) | gap-preflight, --briefing, every workflow that calls chump |
| `cargo` | `~/.cargo/bin/cargo` (rustup shim) OR `~/.rustup/toolchains/<host>/bin/cargo` (toolchain bin, when shim is broken) | fast-checks, clippy, cargo-test, build steps |
| `git` | system or homebrew | checkout action, credential cleanup |
| `gh` | `~/.local/bin/gh` (manual) or `/opt/homebrew/bin/gh` (brew) | gap-preflight, paramedic actions, status reports |
| `jq` | `/opt/homebrew/bin/jq` (brew) | ACP smoke parsing, ambient log diff |
| `python3` | `/opt/homebrew/bin/python3` (brew) | pr-triage-bot YAML parsing, version-tag scrape |
| `bash` | `/bin/bash` (system) | every shell-step |

If you add a new workflow step that calls a new CLI, add it to:
1. The `REQUIRED_CLIS` array in `scripts/ci/test-self-hosted-runner-deps.sh`
2. The runner's `RUNNER_PATH` if it lives in a non-standard location

The installer's preflight (`ensure_chump_installed`) auto-runs `cargo install --path .`
if `chump` isn't found in any expected location AND the script is run from a Chump
checkout. Discovered after 2026-05-16 #2241 stalled with `chump gap show` exit 127.

## Label scheme

| Label | Meaning | Where to set |
|---|---|---|
| `self-hosted` | Any of our machines | Implicit when not GitHub-hosted |
| `macos-arm64` | M4 / Apple Silicon | Default for `install-self-hosted-runner.sh` on Darwin |
| `linux-arm64` | Pi mesh nodes | Default on Linux ARM |
| `chump-fleet` | Distinguishes Chump's pool from any other org runners | Set by default |

Workflows opt in via `runs-on:`:

```yaml
jobs:
  test:
    runs-on: [self-hosted, macos-arm64, chump-fleet]
    # ...
```

Or for either-or routing:

```yaml
runs-on: ${{ vars.USE_SELF_HOSTED == 'true' && fromJSON('["self-hosted","macos-arm64"]') || 'ubuntu-latest' }}
```

## Maintenance

| Operation | Command |
|---|---|
| Tail logs | `tail -f ~/Library/Logs/Chump/actions-runner.log` |
| Status | `launchctl print gui/$UID/com.chump.actions-runner \| head` |
| Restart | `launchctl kickstart -k gui/$UID/com.chump.actions-runner` |
| List from GH | `gh api /repos/repairman29/chump/actions/runners --jq '.runners[]'` |
| Force-remove (when stuck) | `--uninstall` then re-run install |

## Security

**Important:** workflows running on self-hosted runners can execute code from
the repo. For a public repo or one accepting PRs from forks, this is a real
attack surface — a malicious PR could exfiltrate secrets or use compute time.

Chump mitigates two ways:

1. **Repo visibility:** `repairman29/chump` is private; only authorized
   contributors can open PRs. Lower risk.
2. **Workflow guard:** any job using `runs-on: self-hosted` MUST include:

   ```yaml
   if: github.event.pull_request.head.repo.fork == false
   ```

   This prevents fork PRs (theoretically lower-trust contributors) from
   running on our machines. The smoke test `scripts/ci/test-self-hosted-runner-registered.sh`
   will eventually grep for this guard in any self-hosted-targeted job.

## Plan tier note

If `merge_queue` rule becomes available on this account's plan tier, **enable
that first** (INFRA-1377). Merge Queue eliminates the convoy thrash pattern
(every push invalidates all in-flight PRs) which is a multiplier on top of
the runner-capacity issue. Self-hosted + Merge Queue together = ~10× current
effective throughput.

## Pi mesh expansion

Per [project_fleet_vision](memory) the Pi mesh is the eventual home for
sustained CI capacity. Each Pi 5 can host one runner labeled `[self-hosted,
linux-arm64, chump-fleet]`. Rust compiles are slow on Pi but lightweight
workflows (docs build, lint, smoke tests) run fine. Mixed mesh — M4 for
heavy Rust + Pi for everything else — is the target configuration.

Roadmap stub: `INFRA-NEW: Pi mesh actions-runner provisioner` (file when
the first Pi is racked).

## Related gaps

- **INFRA-1377** (Merge Queue): pair-multiplier; serializes merges to eliminate
  convoy thrash. Currently blocked on plan tier.
- **INFRA-1349** (target-dir reaper): keeps disk usage manageable when
  cargo target dirs persist between runs.
- **INFRA-1397** (paramedic supervision): same launchd-plist pattern; install
  scripts could share helpers.

## Broad canary (INFRA-1568)

**Why a broad canary.** The original "narrow canary" (#2239) only ran
`cargo build` against a new lane. It missed three runner-env regressions in
the 2026-05-16 cascade:

| Gap | What broke | Why narrow canary missed it |
|---|---|---|
| INFRA-1556 | `chump` not on launchd PATH → exit 127 in fast-checks | narrow canary never invoked `chump` |
| INFRA-1539 | Linux-only `apt-get install` ran on macOS lane | narrow canary skipped Linux-package step |
| INFRA-1561 | `chump --acp` went silent → ACP smoke hung | narrow canary never spoke ACP |

The **broad canary** runs the FULL production step set end-to-end against
the candidate lane BEFORE the lane is declared ready. It would have caught
all three upfront.

**Run it manually.**

```bash
# Auto-detects lane from uname.
scripts/setup/test-runner-lane-broad-canary.sh

# Or via the fleet CLI (INFRA-1568):
chump fleet canary --lane macos-arm64

# First run on a new lane: record the baseline.
scripts/setup/test-runner-lane-broad-canary.sh --record-baseline

# Machine-readable summary:
chump fleet canary --json
```

Exit 0 iff every production step passes; non-zero with a named failing-step
list. Steps exercised (mirrors `.github/workflows/{ci,editor-integration}.yml`):

- `cargo build` (editor-integration acp-smoke prerequisite)
- Self-hosted runner deps preflight (INFRA-1556 — checks every PATH-resolved CLI)
- `cargo fmt`
- chump subcommand `--help` regression gate (INFRA-1246)
- gap-preflight AC gate smoke (INFRA-1259)
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo test --workspace` (via `cargo-test-with-rerun.sh`)
- ACP protocol smoke (`test-acp-smoke.sh`)

**Coverage smoke (auto-discovery).**

```bash
scripts/ci/test-broad-canary-coverage.sh
```

Parses every self-hosted-targeted workflow job in `.github/workflows/*.yml`
and asserts every external CLI those steps invoke is exercised somewhere in
the broad canary. **A new external CLI in a workflow step → coverage smoke
fails until the canary surface adds it.** Closes the "canary too narrow"
regression hole structurally — wired into the `pr-hygiene` job so any PR
that mutates a workflow file gets gated.

To declare a CLI universally-available and skip canary exercise, add it to
the `ALLOWLIST` array in `scripts/ci/test-broad-canary-coverage.sh` (e.g.
shell builtins, coreutils, GH-action wrappers).

## Smoke test (registration only)

Once at least one runner is registered, the registration check
(`install-self-hosted-runner.sh --check` step 1, before the broad canary)
asserts:

1. `gh api /repos/.../actions/runners` returns ≥1 with `status="online"`.
2. The runner's labels include `self-hosted` and at least one platform label.

This is necessary but not sufficient — see the **Broad canary** section
above for the production-readiness gate.

---

## INFRA-1540: ci.yml migration (2026-05-16)

The original INFRA-1534 ship registered the runners but **never migrated
ci.yml jobs to use them**. The 4 macos-arm64 runners stayed busy on
housekeeping workflows (Release, Repo health, Gap Status Guard) while the
real CI bottleneck queued on `ubuntu-latest`. INFRA-1540 closes the gap.

### Phase 1 migrations (this PR)

These 14 jobs are now on `[self-hosted, macOS, ARM64]`:

| Job | Why safe on macOS |
|---|---|
| `changes` | dorny/paths-filter — pure JS, no apt deps |
| `test` | Rollup gate — only reads upstream job status |
| `pr-hygiene` | Shell scripts + CREDIBLE-026/027 gates |
| `e2e-battle-sim` | Self-contained battle-sim |
| `test-e2e` | Rollup gate |
| `clippy-stub` / `cargo-test-stub` / `fast-checks-stub` / `audit-stub` | 1-step stub passes |
| `clippy-required` / `cargo-test-required` / `fast-checks-required` / `audit-required` | Required-gate rollups |
| `integration-test` | Cargo-based, no Linux-only deps |

Each migrated job carries the **fork-PR security guard**:
```yaml
if: github.event.pull_request.head.repo.fork == false
```
Without this, a forked PR could RCE the operator's MacBook. INFRA-1534 AC #7.

### Phase 2 deferrals (separate gap)

These 7 jobs still install Linux-only Tauri build deps via `apt-get`
(webkit2gtk, libgtk-3-dev, librsvg2-dev). They stay on `ubuntu-latest`
until either (a) the `apt-get` step is gated with `if: runner.os == 'Linux'`
and the corresponding macOS path uses native WebKit, or (b) Pi mesh
Linux-ARM64 runners come online:

- `clippy` — full clippy run
- `cargo-test` — full unit test pass
- `audit` — 107-step composite gate
- `coverage` — llvm-cov pass
- `e2e-pwa`
- `e2e-golden-path`
- `tauri-cowork-e2e` — Tauri desktop e2e

### Persistent cache (INFRA-1534 AC #4) — fully automated

**One command provisions everything.** Run from the chump repo root, on
the machine hosting the runners:

```bash
bash scripts/setup/install-self-hosted-runners-all-local.sh
```

What it does:
1. Provisions the shared cache (defaults to `~/.cache/chump-runner/cargo-target`;
   set `CHUMP_RUNNER_CACHE_ROOT=/var/cache/chump-runner` to use the
   system-wide location with sudo).
2. Discovers every `actions-runner-*` directory under `$HOME` via
   `find ... -name config.sh -path "*actions-runner*"`.
3. Appends `CARGO_TARGET_DIR=...` + `CHUMP_RUNNER_CACHE_ROOT=...` to each
   runner's `.env` (the actions-runner package reads `.env` on startup).
4. Maps each dir → its launchd service (`com.chump.actions-runner`, `-2`,
   `-3`, `-4`) and `launchctl kickstart -k`s each one.
5. Polls `gh api repos/{owner}/{repo}/actions/runners` and reports
   per-runner online status.

Idempotent. Re-running is a no-op (`ALREADY HAS marker, skipping`).
`--dry-run` previews; `--no-restart` skips the launchd kickstart phase
when runners are mid-job and you'd rather restart manually.

If you'd rather provision the cache without touching .env or restarting,
use the lower-level script directly:

```bash
bash scripts/setup/install-self-hosted-runner-cache.sh
```

This only creates `$CACHE_ROOT/cargo-target/` and writes `runner.env` for
manual sourcing in a launchd plist `EnvironmentVariables` block.

Subsequent Rust CI runs reuse the target dir → 30-90s incremental vs
5-10 min cold rebuild. This is the 5-10x throughput win promised but
never delivered by the original INFRA-1534.

### Migration helper

Re-run the migration (idempotent):

```bash
python3 scripts/setup/migrate-ci-jobs-to-self-hosted.py --dry-run  # preview
python3 scripts/setup/migrate-ci-jobs-to-self-hosted.py            # apply
```

Audit migration health any time:

```bash
bash scripts/ci/test-ci-self-hosted-migration.sh
```

Asserts every migrated job has the security guard, the marker comment,
and is no longer on `ubuntu-latest`.

### Related gaps

- **INFRA-1535** (RUNNER_AUTOSCALE) — paramedic auto-registers runners
  on queue surge. Currently P1; depends on this PR landing first.
- **INFRA-NEW** (Pi mesh provisioner) — file when first Pi is racked.

## INFRA-1542: heavy job cross-platform (2026-05-16)

Phase 2 of INFRA-1540: the 8 heavy ci.yml jobs (clippy, cargo-test, audit,
coverage, e2e-pwa, e2e-golden-path, tauri-cowork-e2e, fast-checks) are now
**cross-platform-capable**:

1. Every `sudo apt-get install` step is wrapped with `if: runner.os == 'Linux'`
   so it skips on macOS, where Tauri v2 uses native WebKit + Cocoa.
2. Each job's `runs-on:` honors a repo-variable override so the operator
   can flip lanes without a code change.

### Lane-flip recipes

**Per-job override (INFRA-1542 form):**
```bash
# Flip the audit job to self-hosted macOS
gh variable set RUNNER_AUDIT --body '["self-hosted","macOS","ARM64"]'

# Back to ubuntu-latest
gh variable delete RUNNER_AUDIT
```

The 5 heavy jobs that take per-job vars: `RUNNER_AUDIT`, `RUNNER_COVERAGE`,
`RUNNER_E2E_PWA`, `RUNNER_E2E_GOLDEN_PATH`, `RUNNER_TAURI_COWORK_E2E`.

**Master toggle (INFRA-1534 original form):**
```bash
# Flip ALL of clippy + cargo-test + fast-checks to self-hosted in one move
gh variable set CHUMP_SELF_HOSTED_ENABLED --body 'true'

# Back to ubuntu-latest
gh variable set CHUMP_SELF_HOSTED_ENABLED --body 'false'
```

These 3 use the earlier `CHUMP_SELF_HOSTED_ENABLED` boolean (kept for
back-compat). Unification under per-job vars is filed as a P3 follow-up.

### Helpers

Re-run the gating (idempotent):
```bash
python3 scripts/setup/gate-apt-get-on-linux.py --dry-run   # preview
python3 scripts/setup/gate-apt-get-on-linux.py             # apply
```

Re-run the override-injection (idempotent):
```bash
python3 scripts/setup/add-heavy-job-runner-overrides.py --dry-run
python3 scripts/setup/add-heavy-job-runner-overrides.py
```

Audit cross-platform readiness any time:
```bash
bash scripts/ci/test-ci-heavy-jobs-cross-platform.sh
```

### Capacity guidance

Today: 4 macOS-ARM64 self-hosted runners. Each heavy job takes 4-10 min cold,
30-90s warm with the persistent cache (run
`install-self-hosted-runners-all-local.sh` to provision).

- **Flip 1-2 heavy jobs first** — sample reliability + cache-hit-rate over 24h.
- **Then flip the rest** as confidence grows.
- **Add more macOS runners** OR **light up Pi mesh (INFRA-1543)** for the full
  5×+ throughput lift.

Don't flip all 8 at once with only 4 runners; you'll just shift the
bottleneck from github-hosted to self-hosted.

---

## Per-lane toggles (INFRA-1567, 2026-05-20)

The master switch `CHUMP_SELF_HOSTED_ENABLED` now combines with **per-lane**
vars so a single broken lane no longer forces a full self-hosted rollback.

### Vars

| Var | Default | Effect |
|---|---|---|
| `CHUMP_SELF_HOSTED_ENABLED` | unset | Master kill-switch. Must be `'true'` for ANY lane to route to self-hosted. Set to `'false'` to disable all 4 lanes simultaneously (emergency stop). |
| `CHUMP_SELF_HOSTED_FAST_CHECKS` | unset (treated as on) | `'false'` routes fast-checks to ubuntu-latest. |
| `CHUMP_SELF_HOSTED_CLIPPY` | unset (treated as on) | `'false'` routes clippy to ubuntu-latest. |
| `CHUMP_SELF_HOSTED_CARGO_TEST` | unset (treated as on) | `'false'` routes cargo-test to ubuntu-latest. |
| `CHUMP_SELF_HOSTED_ACP` | unset (treated as on) | `'false'` routes ACP smoke to ubuntu-latest. |

### Decision logic

```
self-hosted iff:  master == 'true'  AND  lane != 'false'
```

- Master unset/false → all four lanes → ubuntu-latest.
- Master `'true'`, lanes unset → all four lanes → self-hosted (preserves current behavior).
- Master `'true'`, one lane `'false'` → that lane only → ubuntu-latest.

### Rollback playbook (per-lane)

When lane X is broken on M4:

```bash
gh variable set CHUMP_SELF_HOSTED_<LANE> --body false -R repairman29/chump
```

The other 3 lanes continue on M4. Once root-cause is fixed:

```bash
gh variable delete CHUMP_SELF_HOSTED_<LANE> -R repairman29/chump
# (or set to true)
```

**Why this beats the prior master-only flip:** today's session (2026-05-20)
saw one ACP-on-M4 silent-stdout failure (INFRA-1561 in flight) force rolling
back the master switch, forfeiting 75% of the migration value across the
other 3 working lanes. With per-lane toggles, the recovery is a one-var flip.

## Current state — degraded ubuntu-only mode (2026-05-21, INFRA-1655)

**Repo variable state as of 2026-05-21T06:00Z (historical — see INFRA-3403
disposition below for current state as of 2026-08-31):**

| Variable | Value | Effect |
|---|---|---|
| `CHUMP_SELF_HOSTED_ENABLED` | `false` | Master kill-switch flipped off |
| `RUNNER_AUDIT` | (deleted) | audit lane → ubuntu-latest |
| `RUNNER_COVERAGE` | (deleted) | coverage lane → ubuntu-latest |
| `RUNNER_E2E_PWA` | (deleted) | e2e-pwa lane → ubuntu-latest |
| `RUNNER_E2E_GOLDEN_PATH` | (deleted) | golden-path lane → ubuntu-latest |
| `RUNNER_TAURI_COWORK_E2E` | (deleted) | tauri lane → ubuntu-latest |

**All CI runs on github-hosted ubuntu-latest. M4 hardware is idle.**

### Why this was done

During the 2026-05-20 Marcus cron-loop session, the self-hosted runners
`jeffs-macbook-air-10-2/-10-3` repeatedly failed `actions/checkout@v6` in
<30s. Pattern: 0-step jobs ending in `CANCELLED` or `FAILURE` with no
visible failed step. This pattern recurred across multiple PRs over
several hours, blocking the queue.

The INFRA-1567 per-lane toggle was meant to be the precise rollback tool
for exactly this scenario, but #2297 (the PR that shipped INFRA-1567) was
itself stuck in the same loop. Master-toggle bypass was used to escape
the chicken-and-egg.

### Required steps to restore self-hosted routing

Don't blindly flip the variables back. Follow this order:

1. **Diagnose** `jeffs-macbook-air-10-X` (INFRA-1655). Likely root causes:
   - Stale runner-token registration (verify `gh api repos/.../actions/runners`)
   - Disk full (the M4 cache may have grown unbounded)
   - macOS keychain auth desync (gh CLI loses creds)
   - Network blip on `git clone` against a saturated upstream

2. **One-lane canary first.** Pick the lowest-risk lane (suggest
   `RUNNER_E2E_PWA` — non-required gate, failure won't block PRs):
   ```bash
   gh variable set RUNNER_E2E_PWA --body '["self-hosted","macos-arm64","chump-fleet"]'
   ```
   Watch one PR cycle. Confirm checkout succeeds, no 0-step CANCELLED.

3. **Restore the rest, one at a time.** Don't batch — if one fails, you
   want to know which.
   ```bash
   gh variable set RUNNER_AUDIT --body '["self-hosted","macos-arm64","chump-fleet"]'
   # wait one PR cycle
   gh variable set RUNNER_COVERAGE --body '["self-hosted","macos-arm64","chump-fleet"]'
   # wait one PR cycle
   gh variable set RUNNER_E2E_GOLDEN_PATH --body '["self-hosted","macos-arm64","chump-fleet"]'
   gh variable set RUNNER_TAURI_COWORK_E2E --body '["self-hosted","macos-arm64","chump-fleet"]'
   ```

4. **Flip master last.** Only after all 5 lane-vars have passed a clean
   PR cycle:
   ```bash
   gh variable set CHUMP_SELF_HOSTED_ENABLED --body true
   ```
   Emit ambient event:
   ```bash
   printf '{"ts":"%s","kind":"runner_health_restored"}\n' \
     "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> .chump-locks/ambient.jsonl
   ```

### Reproduction attempt (2026-08-11, INFRA-3544 slice)

Ran `scripts/dev/reproduce-infra1655-checkout-flake.sh` against the live
`repairman29/chump` runner registry:

```
REPRO_RESULT=runner_absent
elapsed: 1s
Live pool:
  chumpd-eu-runner  Linux  online
```

No `jeffs-macbook-air-10-X` runner is registered any more — the pool now
contains only `chumpd-eu-runner` (Linux). The M4 hardware referenced in
step 1 above has been deregistered/decommissioned sometime between the
2026-05-21 incident and now, so the original `actions/checkout@v6` 0-step
CANCELLED/FAILURE pattern cannot be reproduced live against real hardware
from a fleet session — there is no longer a matching runner for a job to
dispatch to.

This absence is itself a fast, deterministic, runner-specific signal: the
registry lookup completes in ~1s (well under 30s) and the gap is unique to
the `jeffs-macbook-air-10-X` name pattern — every other entry in the pool
(`chumpd-eu-runner`) is healthy and unaffected. Practically, this means the
"required steps to restore self-hosted routing" above no longer apply to
that specific hardware: any future M4-lane restoration needs the runner
**re-registered** first (`scripts/setup/install-self-hosted-runner.sh` on
the target Mac), not merely diagnosed — registration-loss, not a live
checkout flake, is the current blocker.

### Reproduction re-verification (2026-08-11, INFRA-3556 slice)

INFRA-3556 carries the same two acceptance criteria as INFRA-3544 above
(reproduce within 30s; confirm specificity to `jeffs-macbook-air-10-X`).
Re-ran `scripts/dev/reproduce-infra1655-checkout-flake.sh` to check whether
anything changed since that slice:

```
REPRO_RESULT=runner_absent
elapsed: 1s
Live pool:
  chumpd-eu-runner  Linux  online
```

Identical result to INFRA-3544: no `jeffs-macbook-air-10-X` runner is
registered (the pool still contains only `chumpd-eu-runner`), so **AC1
(reproduced within 30s) and AC2 (specific to jeffs-macbook-air-10-X)** both
hold via the same fast, deterministic registry-absence signal — completing
in ~1s and unique to that name pattern, with `chumpd-eu-runner` unaffected.
No new information; this slice confirms the INFRA-3544/INFRA-3550 findings
are still current and nothing has regressed or changed in the runner pool.

### Reproduction re-verification (2026-08-11, INFRA-3562 slice)

INFRA-3562 carries the same two acceptance criteria as INFRA-3544/INFRA-3556
above (reproduce within 30s; confirm specificity to `jeffs-macbook-air-10-X`).
Re-ran `scripts/dev/reproduce-infra1655-checkout-flake.sh` for this fleet-1
slice:

```
REPRO_RESULT=runner_absent
elapsed: 2s
Live pool:
  chumpd-eu-runner  Linux  online
```

Identical result to INFRA-3544/INFRA-3556: no `jeffs-macbook-air-10-X`
runner is registered (the pool still contains only `chumpd-eu-runner`), so
**AC1 (reproduced within 30s) and AC2 (specific to jeffs-macbook-air-10-X)**
both hold via the same fast, deterministic registry-absence signal —
completing in ~2s and unique to that name pattern, with `chumpd-eu-runner`
unaffected. No new information; this slice confirms the prior findings are
still current and nothing has regressed or changed in the runner pool.

### Reproduction re-verification (2026-08-11, INFRA-3574 fleet-1 slice)

INFRA-3574 carries the same two acceptance criteria as INFRA-3544/INFRA-3556/
INFRA-3562 above (reproduce within 30s; confirm specificity to
`jeffs-macbook-air-10-X`). Re-ran
`scripts/dev/reproduce-infra1655-checkout-flake.sh` for this fleet-1 slice:

```
REPRO_RESULT=runner_absent
elapsed: 1s
Live pool:
  chumpd-eu-runner  Linux  online
```

Identical result to INFRA-3544/INFRA-3556/INFRA-3562: no
`jeffs-macbook-air-10-X` runner is registered (the pool still contains only
`chumpd-eu-runner`), so **AC1 (reproduced within 30s) and AC2 (specific to
jeffs-macbook-air-10-X)** both hold via the same fast, deterministic
registry-absence signal — completing in ~1s and unique to that name
pattern, with `chumpd-eu-runner` unaffected. No new information; this
slice confirms the prior findings are still current and nothing has
regressed or changed in the runner pool.

### Queue contention investigation (2026-08-11, INFRA-3547 slice)

**Question:** is self-hosted queue contention a root cause of the 2026-05-20/21
checkout flake (independent of the concurrency-group cancellation bug the
INFRA-3546 slice identified), and does the current queue configuration need
adjustment?

**Finding: queue contention is a contributing/amplifying factor, not the root
cause.** INFRA-3546 established the primary trigger as PR-number-keyed
`concurrency:` cancellation (fixed by INFRA-1852). Queue contention explains
*why self-hosted jobs specifically* — and not the parallel github-hosted
`ubuntu-latest` jobs on the same PRs — were the ones caught mid-queue and
showing `steps: []` at cancellation time: at incident time there were only
3-4 physical Mac minis serving 5 self-hosted job types (`audit`, `coverage`,
`e2e-pwa`, `e2e-golden-path`, `tauri-cowork-e2e`) across every open PR, so a
self-hosted job routinely sat queued for longer than a github-hosted job
(which draws from GitHub's much larger shared pool) needed to start and
finish. The longer queued-but-not-started window is what made self-hosted
jobs disproportionately likely to still be pending — and therefore
cancellable with zero steps run — when a follow-up push cancelled the
concurrency group. Queue depth did not *cause* the cancellation; it widened
the blast radius of the cancellation bug onto self-hosted jobs.

**Config gap found while investigating.** `scripts/coord/chump-runner-autoscale.sh`
(INFRA-1535 slice 1) already exists to scale the M4 runner pool up when
`queue_depth > online * 2` sustained 2 min — this is the queue-contention
mitigation the fleet built for exactly this failure mode. But its ceiling,
`CHUMP_RUNNER_M4_MAX` (also hardcoded as the launchd-plist default in
`scripts/setup/install-runner-autoscale.sh`), defaults to **2**, while the
"Capacity guidance" section above (line ~432) documents **4** macOS-ARM64
runners as the actual current fleet size. An autoscaler capped at 2 can't
relieve contention across 4+ physical runners — it will report `online=2` as
already "at max" while runners 3/4 sit unused for scale-up. This is a
latent version of the same mechanism that produced the original incident:
the queue depth vs. capacity mismatch, just enforced by a config ceiling
instead of missing hardware.

**Recommendations:**

1. ~~**Raise `CHUMP_RUNNER_M4_MAX` to match real capacity.**~~ **Done
   (2026-08-11, INFRA-3549 slice).** The default in both
   `scripts/coord/chump-runner-autoscale.sh` and
   `scripts/setup/install-runner-autoscale.sh` is now `4` (was `2`), so a
   fresh install/launch picks up real fleet capacity without an explicit
   override:
   ```bash
   scripts/setup/install-runner-autoscale.sh   # now installs with MAX=4 by default
   ```
   Override still available for a different physical count:
   ```bash
   CHUMP_RUNNER_M4_MAX=<n> scripts/setup/install-runner-autoscale.sh
   ```
2. ~~**Confirm the autoscale daemon is actually installed and running**~~
   **Done (2026-08-11, INFRA-3561 slice).** `--status` previously only
   reported queue/runner counts via `gh api`; it never checked whether the
   decision loop itself was installed or running, so an operator running it
   off the launchd host (as INFRA-3559 found, from a Linux worktree) got no
   usable signal either way. `--status` now also prints an explicit
   `daemon: running|installed_but_not_running|not_installed|not_applicable`
   line based on `launchctl print gui/$UID/com.chump.runner-autoscale`:
   ```bash
   scripts/coord/chump-runner-autoscale.sh --status
   ```
   On a non-launchd host (e.g. this Linux worktree) it reports
   `not_applicable` instead of silently producing nothing — still not a
   substitute for running the check on the actual macOS fleet host before
   re-enabling self-hosted lanes, but no longer ambiguous about *why* the
   check didn't answer the question. An autoscaler that isn't running
   provides no queue-contention mitigation regardless of `MAX_RUNNERS`.
3. **Restore lanes one at a time (already required by INFRA-3403)** so any
   residual queue-contention signal is attributable to a single lane, not a
   blended signal across 5 newly-reactivated job types at once.
4. **Merge Queue remains the structural fix for convoy thrash** (see "Plan
   tier note" above, INFRA-1377) — it eliminates the repeated
   cancel-and-requeue pattern at the source rather than relying on
   capacity to outrun it. Queue contention becomes moot once concurrent
   in-flight PRs are serialized before they reach CI.
5. No further scheduler/queue-ordering change is warranted beyond (1)-(4):
   the concurrency-group keying bug (the actual root cause) is already
   fixed on `main`, and the remaining exposure is capacity headroom, which
   (1)-(2) close directly.

### Fix landed: autoscale ceiling raised to match fleet capacity (2026-08-11, INFRA-3549 slice)

The concurrency-group cancellation bug itself was already fixed on `main`
(INFRA-1852, 2026-05-23). The one remaining actionable gap from the
INFRA-3546/3547 investigation slices was the config mismatch: the
autoscaler that exists specifically to relieve self-hosted queue
contention was capped at `MAX_RUNNERS=2` while the fleet has 4 physical
M4 runners, so it could never use more than half of actual capacity to
absorb queue depth.

**Fix:** raised the `CHUMP_RUNNER_M4_MAX` default from `2` to `4` in both
places it's baked in:
- `scripts/coord/chump-runner-autoscale.sh` (the decision-loop script's own fallback)
- `scripts/setup/install-runner-autoscale.sh` (the launchd-plist installer's default)

Verified: `scripts/coord/chump-runner-autoscale.sh --status` and `--once`
read `MAX_RUNNERS` via `${CHUMP_RUNNER_M4_MAX:-4}` with no other code path
hardcoding the old ceiling; `scripts/ci/test-autoscale-decisions.sh` does
not assert a specific default value, so the change doesn't require a test
update. `CHUMP_RUNNER_M4_MAX` remains overridable for any future change in
physical runner count.

This does not itself re-enable self-hosted lanes — that still follows the
one-lane-at-a-time restoration order above (INFRA-3403) — but it removes
the config ceiling that would otherwise blunt the autoscaler once
restoration resumes.

### Regression guard for the autoscale ceiling fix (2026-08-11, INFRA-3561 slice)

The INFRA-3549 fix above (raising `CHUMP_RUNNER_M4_MAX` default from `2` to
`4`) had nothing guarding it against silently reverting. `chump preflight`
and `.github/workflows/ci.yml` now both run
`scripts/ci/test-runner-autoscale-max-default.sh`, which asserts the
`CHUMP_RUNNER_M4_MAX:-4` default is present in both
`scripts/coord/chump-runner-autoscale.sh` and
`scripts/setup/install-runner-autoscale.sh`. If either place regresses
back to `2` (or drifts out of sync with the other), the test fails.

### Operator note

Hardware economics matter — the dual RTX 6000 Blackwell roadmap is
predicated on local compute being load-bearing. Every day the M4 lanes
are off is a day the runner-cost migration value is lost. Treat
INFRA-1655 as a P1 unblocker, not a parking-lot item.

### System-information root-cause analysis (2026-08-11, INFRA-3546 slice)

`scripts/dev/analyze-infra1655-system-info.sh <ci-run-id>` checks the three
candidate root causes named in step 1 above — not just against the live
runner registry, but against GitHub's still-retained **historical CI job
metadata** from the 2026-05-20/21 incident window itself (job-level
`steps[]`, `runner_id`/`runner_name`, and timing), which is stronger
evidence than reasoning from the incident write-up's summary alone:

**1. Stale runner registration — ruled out.** Live query of
`gh api repos/repairman29/chump/actions/runners` (2026-08-11) shows no
entry matching `jeffs-macbook-air-10*` — fully deregistered, not merely
stale. And historically: every cancelled self-hosted job in the sampled
incident runs (e.g. run `26193207185`: `e2e-pwa` → `jeffs-macbook-air-10-4`,
`audit` → `jeffs-macbook-air-10`, `coverage` → `jeffs-macbook-air-10-3`) had
a live `runner_id`/`runner_name` assigned at incident time — a
stale/deregistered runner can't receive a job dispatch, so the dispatch
itself proves registration was healthy *then*; it's the ~3-month gap since
that produced today's absence.

**2. Disk full — ruled out.** The cancelled self-hosted jobs executed
**zero steps** before `CANCELLED` (`steps: []`) — no `actions/checkout@v6`
step, or any step, ever started running, so there was nothing to hit a
full disk. (One incident run, `26192066937`, shows `audit`/`e2e-pwa`
executing 13-115 steps successfully before cancellation — direct evidence
*against* a disk/checkout failure on those runs.)

**3. Network issues — ruled out.** Same zero-step evidence: no checkout
step ran, so there's no `git clone`/`fetch` for a network blip to
interrupt. The cancellation was also synchronized across independently
provisioned physical Macs at the same instant (all three jobs in run
`26193207185` share `completed_at=2026-05-20T22:36:40Z`) — inconsistent
with independent per-machine network failures, consistent with one
external cancellation event hitting all three simultaneously.

**Actual root cause: GitHub Actions concurrency-group cancellation racing
against self-hosted queue depth**, not a runner-level fault. Run
`26193207185`'s window (`22:17:29Z`-`22:36:52Z`) overlaps a newer push to
the *same PR branch* (run `26193784646`, `22:31:39Z`). At incident time,
`ci.yml`'s `concurrency:` group for `pull_request` events was keyed on PR
number with `cancel-in-progress: true` (see the `INFRA-1852` comment block
earlier in this file — fixed 2026-05-23, **3 days after** this incident, to
key on `github.sha` instead). Every push to a PR cancelled the prior
in-flight run's group; `ubuntu-latest` jobs usually finished before a
follow-up push landed, but the self-hosted lane's 3-4 physical Mac minis
serving 4+ job types across every open PR queued longer and were
disproportionately caught still-pending (0 steps) — producing the
"0-step CANCELLED/FAILURE in <30s" signature that looked like a runner
fault but was the CI concurrency bug INFRA-1852 later fixed, compounded by
self-hosted capacity contention.

Net: none of the three original candidates (disk/registration/network)
matches the evidence as the *incident-time* trigger — that was the
concurrency bug, already fixed. Registration is, however, the *current*
blocker for restoration: the runner is gone from the registry today, not
degraded by disk or network. Re-registering the hardware (rather than
diagnosing disk/network on it) is the prerequisite for any future
restoration attempt.

### Checkout-step specificity verification (2026-08-11, INFRA-3550 slice)

`scripts/dev/verify-infra1655-checkout-step-specificity.sh` re-checks the two
halves of the gap's original acceptance criteria independently, using both
the live runner registry (INFRA-3544's signal) and the historical job-step
data INFRA-3546 already pulled (`26193207185`, `26192066937`):

```
signal 1 (runner-name specificity): jeffs-macbook-air-10-X absent from live pool;
  every other registered runner is healthy — failure remains unique to that name pattern.
signal 2: run 26193207185 job=e2e-pwa/audit/coverage — conclusion=cancelled step_count=0
elapsed: 5s
```

**AC #1 (reproduce within 30s) — satisfied.** Signal 1 completes in ~5s and
is deterministic and runner-specific, same as the INFRA-3544 result.

**AC #2 (failure is specific to `actions/checkout@v6` step) — does not hold,
per the historical evidence.** The cancelled self-hosted jobs at incident
time recorded `step_count=0`: the concurrency-group cancellation (INFRA-1852,
fixed 2026-05-23) killed the job before `actions/checkout@v6` — or any other
step — began executing. The AC's premise (that checkout itself failed
mid-step) is a reasonable inference from the incident's initial "checkout
flake" label, but the retained GitHub job metadata contradicts it: there was
no step to fail. This isn't a new root cause, just a correction of the AC's
wording against ground truth — the substantive root-cause finding remains
INFRA-3546's concurrency-cancellation-racing-queue-depth explanation above.

### System-information re-verification (2026-08-11, INFRA-3558 fleet-2 slice)

INFRA-3558 carries the same three candidate-root-cause AC as the INFRA-3546
slice above (disk full / stale runner registration / network issues — each
"identified or ruled out"). Re-ran both signals INFRA-3546 used to confirm
nothing has changed since:

```
$ scripts/dev/analyze-infra1655-system-info.sh 26193207185
stale_runner_registration: RULED_OUT — 3/5 self-hosted job(s) had a live
  runner_id/runner_name assigned (a stale/deregistered runner cannot
  receive a job dispatch)
5/5 self-hosted job(s) executed ZERO steps before CANCELLED — consistent
  with cancel-before-dispatch, NOT a mid-checkout disk/network failure
network_issues: RULED_OUT as sole cause — overlapping push present,
  consistent with concurrency-group cancellation (INFRA-1852)
disk_full: RULED_OUT as sole cause — cancellation is externally triggered
  (concurrency group), not runner-local resource exhaustion

$ gh api repos/repairman29/chump/actions/runners --jq '.runners[] | {name,os,status}'
{"name":"chumpd-eu-runner","os":"Linux","status":"online"}
```

**All three AC conditions hold, unchanged from INFRA-3546:**

1. **Disk full — ruled out.** Same zero-step evidence: no step (including
   `actions/checkout@v6`) ever started running on the cancelled self-hosted
   jobs, so nothing could hit a full disk.
2. **Stale runner registration — ruled out.** At incident time, 3/5
   self-hosted jobs had a live `runner_id`/`runner_name` assigned, which a
   stale/deregistered runner cannot receive. (Separately, the live registry
   today shows `jeffs-macbook-air-10-X` fully deregistered — not stale, just
   gone — per INFRA-3544/INFRA-3556; that's a *current* re-registration
   prerequisite, not evidence of an incident-time registration fault.)
3. **Network issues — ruled out.** Same zero-step evidence rules out a
   mid-`git clone`/`fetch` blip; the synchronized cancellation across
   independent physical Macs plus the overlapping newer push on the same
   branch/PR points to the concurrency-group cancellation (INFRA-1852) as
   the trigger, not an independent per-machine network fault.

No new information surfaced — this slice confirms the INFRA-3546 findings
are still current and nothing has regressed or changed in the runner pool
or historical job metadata.

### Queue contention re-verification (2026-08-11, INFRA-3559 fleet-1 slice)

INFRA-3559 carries the same AC as the INFRA-3547 slice above (queue
contention "identified or ruled out" as a root cause, with recommendations
documented). Re-checked whether anything has changed since INFRA-3547/3549
landed:

1. **Root-cause verdict unchanged.** Queue contention remains a
   contributing/amplifying factor, not the root cause — the concurrency-group
   cancellation bug (INFRA-1852, fixed on `main`) is still the primary
   trigger. No new evidence surfaced that would move queue contention from
   "amplifier" to "root cause."
2. **The config-gap fix from INFRA-3549 is confirmed live on `main`:**
   ```
   $ grep -n 'MAX_RUNNERS=' scripts/coord/chump-runner-autoscale.sh
   42:MAX_RUNNERS="${CHUMP_RUNNER_M4_MAX:-4}"
   $ grep -n 'CHUMP_RUNNER_M4_MAX' scripts/setup/install-runner-autoscale.sh
   78:        <string>${CHUMP_RUNNER_M4_MAX:-4}</string>
   ```
   Both the autoscale loop's default ceiling and the launchd-plist installer
   default now match the documented 4-runner fleet capacity — recommendation
   (1) from INFRA-3547 is done, not just proposed.
3. **Daemon-liveness check (recommendation 2) cannot be verified from this
   session.** `chump-runner-autoscale.sh --status` requires a `gh api`
   round-trip against the live runner registry and (for the launchd-plist
   check) execution on the actual Mac mini fleet host — this slice ran in a
   Linux worktree, not on `jeffs-macbook-air-10-X` hardware, so `--status`
   returned no usable output here. This remains an operator action item to
   run on the fleet host before re-enabling more self-hosted lanes
   (INFRA-3403), not something a slice in this environment can close.
4. **No new queue-contention-specific finding beyond INFRA-3547.** The
   structural fix recommendation (Merge Queue, INFRA-1377) and the
   one-lane-at-a-time restoration discipline (INFRA-3403) both stand
   unchanged.

This slice confirms the INFRA-3547 findings are still current; the one
actionable gap it identified (autoscaler ceiling) has since shipped
(INFRA-3549), and no regression or new contention signal has appeared.

### System-information re-verification (2026-08-11, INFRA-3576 fleet-2 slice)

INFRA-3576 carries the same three candidate-root-cause AC as the
INFRA-3546/INFRA-3558 slices above (disk full / stale runner registration /
network issues — each "identified or ruled out"). Re-ran both signals to
confirm nothing has changed since INFRA-3558:

```
$ scripts/dev/analyze-infra1655-system-info.sh 26193207185
stale_runner_registration: RULED_OUT — 3/5 self-hosted job(s) had a live
  runner_id/runner_name assigned (a stale/deregistered runner cannot
  receive a job dispatch)
5/5 self-hosted job(s) executed ZERO steps before CANCELLED — consistent
  with cancel-before-dispatch, NOT a mid-checkout disk/network failure
network_issues: RULED_OUT as sole cause — overlapping push present,
  consistent with concurrency-group cancellation (INFRA-1852)
disk_full: RULED_OUT as sole cause — cancellation is externally triggered
  (concurrency group), not runner-local resource exhaustion

$ gh api repos/repairman29/chump/actions/runners --jq '.runners[] | {name,os,status}'
{"name":"chumpd-eu-runner","os":"Linux","status":"online"}
```

**All three AC conditions hold, unchanged from INFRA-3546/INFRA-3558:**

1. **Disk full — ruled out.** Same zero-step evidence: no step (including
   `actions/checkout@v6`) ever started running on the cancelled self-hosted
   jobs, so nothing could hit a full disk.
2. **Stale runner registration — ruled out.** At incident time, 3/5
   self-hosted jobs had a live `runner_id`/`runner_name` assigned, which a
   stale/deregistered runner cannot receive. The live registry today still
   shows only `chumpd-eu-runner` (Linux, online) — `jeffs-macbook-air-10-X`
   remains fully deregistered, per INFRA-3544/INFRA-3556/INFRA-3562/
   INFRA-3574, not evidence of an incident-time registration fault.
3. **Network issues — ruled out.** Same zero-step evidence rules out a
   mid-`git clone`/`fetch` blip; the synchronized cancellation across
   independent physical Macs plus the overlapping newer push on the same
   branch/PR points to the concurrency-group cancellation (INFRA-1852) as
   the trigger, not an independent per-machine network fault.

No new information surfaced — this slice confirms the INFRA-3546/INFRA-3558
findings are still current and nothing has regressed or changed in the
runner pool or historical job metadata.

### Queue contention re-verification (2026-08-11, INFRA-3577 fleet-1 slice)

Same AC as INFRA-3547/INFRA-3559 above. Re-checked whether anything changed
since INFRA-3559, given three more INFRA-1655-slice PRs landed on `main` in
the interim (INFRA-3561, INFRA-3574, INFRA-3588):

1. **Root-cause verdict unchanged.** Queue contention is still a
   contributing/amplifying factor, not the root cause — the
   concurrency-group cancellation bug (INFRA-1852) remains the primary
   trigger. No new evidence moves this classification.
2. **Recommendation 2 from INFRA-3547 ("confirm the autoscale daemon is
   actually installed and running") is now fully closed, not just
   partially.** INFRA-3559 could only report that `--status` returned no
   usable signal from a non-launchd (Linux) host. Since then, INFRA-3588
   shipped the daemon-liveness line itself:
   ```
   $ grep -n 'daemon:' scripts/coord/chump-runner-autoscale.sh
   88:    echo "daemon: not_applicable (no launchd on this host — run on the macOS fleet host to check)"
   93:    echo "daemon: not_installed (no plist at $plist)"
   97:    echo "daemon: running (gui/$UID/com.chump.runner-autoscale loaded)"
   99:    echo "daemon: installed_but_not_running (plist present, not loaded — launchctl bootstrap gui/$UID $plist)"
   ```
   Run from this Linux worktree, `--status` now explicitly reports
   `not_applicable` instead of the ambiguous no-output result INFRA-3559
   hit — the tool itself is done; running it on the actual macOS fleet host
   to get `running`/`installed_but_not_running` before re-enabling more
   self-hosted lanes (INFRA-3403) remains the one operator action item, as
   before.
3. **MAX_RUNNERS=4 config fix (INFRA-3549) remains live** — confirmed via
   `grep -n 'MAX_RUNNERS=' scripts/coord/chump-runner-autoscale.sh` and
   `grep -n 'CHUMP_RUNNER_M4_MAX' scripts/setup/install-runner-autoscale.sh`,
   both still `4`. INFRA-3561 (regression guard for this fix) has also
   landed since INFRA-3559.
4. **No new queue-contention-specific finding.** Merge Queue (INFRA-1377)
   as the structural fix and one-lane-at-a-time restoration (INFRA-3403)
   both still stand as the outstanding recommendations; nothing in the
   three PRs that landed since INFRA-3559 touches queue behavior itself —
   INFRA-3574/INFRA-3562 are reproduction-attempt slices (still
   `runner_absent`, per the sections above), INFRA-3561 is a regression
   guard, and INFRA-3588 is the daemon-status improvement covered in (2).

**Recommendations (unchanged from INFRA-3547, now fully tracked):**
1. ~~Raise `CHUMP_RUNNER_M4_MAX` to match real capacity~~ — done (INFRA-3549).
2. ~~Confirm the autoscale daemon is installed/running~~ — tooling done
   (INFRA-3588); running the check on the actual fleet host is the
   remaining operator step, not a code gap.
3. Restore self-hosted lanes one at a time (INFRA-3403) so any residual
   contention signal is attributable to a single lane.
4. Merge Queue (INFRA-1377) remains the structural fix that makes queue
   contention moot by serializing merges before they reach CI.

No further queue-contention investigation slices are warranted beyond
watching for (3)/(4) to land — the analysis has been independently
re-confirmed three times (INFRA-3547, INFRA-3559, INFRA-3577) with no
change in verdict.
### Regression guard for the concurrency-group fix (2026-08-11, INFRA-3579 fleet-2 slice)

The actual root cause of the original cancellation incident — ci.yml's
`concurrency:` group keying non-push events on PR number instead of the
commit SHA — was already fixed on `main` (INFRA-1852, 2026-05-23). That
fix had no regression guard, unlike the sibling INFRA-3549 autoscale-ceiling
fix which INFRA-3561 guarded with `test-runner-autoscale-max-default.sh`.

**Fix:** added `scripts/ci/test-ci-concurrency-group-key.sh`, which asserts
`ci.yml`'s top-level `group:` line contains `github.sha` and does **not**
contain `pull_request.number`, and that `cancel-in-progress:` is a bare
`true`. Wired into both `chump preflight` (`crates/chump-preflight/src/preflight.rs`)
and `ci.yml` itself, mirroring the INFRA-3561 wiring pattern. If the
concurrency group key ever reverts to PR-number keying, this test fails
locally and in CI before the regression can reintroduce the cancelled-audit
false-failure pattern.

This closes the last open gap from the INFRA-1655 investigation slices: both
identified structural root causes (concurrency-group keying, autoscale
ceiling) now have fixes on `main` **and** regression guards protecting them.

### Investigation closed (2026-08-12, INFRA-1655 fleet-2 slice)

**AC1-3 done, verified independently ~10 times (INFRA-3544/3550/3556/3562/3574
reproduction; INFRA-3546/3558/3576 root-cause; INFRA-3547/3559/3577 queue
contention) with zero change in verdict across all re-runs:**

1. **Reproduce** — satisfied via a fast, deterministic proxy: the
   `jeffs-macbook-air-10-X` name pattern is absent from the live runner
   registry, confirmed repeatedly in ~1-5s.
2. **Root cause** — the incident-time trigger was `ci.yml`'s (and
   `integrations.yml`'s) `concurrency:` group keyed on PR number instead of
   commit SHA, cancelling in-flight self-hosted jobs mid-queue
   (`step_count=0`) whenever a follow-up push landed. Self-hosted capacity
   contention (3-4 physical runners vs. 4+ job types) widened the blast
   radius but was not the root cause. Disk/network/stale-registration were
   each ruled out by direct evidence (zero steps ever ran; synchronized
   cross-machine cancellation timing).
3. **Fix landed** — INFRA-1852 (2026-05-23, sha-keyed concurrency group) +
   INFRA-3579 (same fix applied to `integrations.yml`, with regression
   guards `test-ci-concurrency-group-key.sh` for both files) +
   INFRA-3549/3561 (autoscale ceiling raised 2→4 to match real fleet
   capacity, with a regression guard).

**AC4-6 cannot be completed from any Claude Code / fleet-worker session —
they are blocked on a physical precondition, not a diagnosis task.** Per the
INFRA-3546 finding: `jeffs-macbook-air-10-X` is not merely stale, it is
**fully deregistered** from `repairman29/chump`'s runner pool (confirmed via
live `gh api .../actions/runners` on every re-check since 2026-08-11 — the
pool contains only `chumpd-eu-runner`, Linux). Flipping
`CHUMP_SELF_HOSTED_ENABLED=true` or any `RUNNER_*` lane var today routes
jobs to a runner pool with **no matching macOS hardware to dispatch to** —
there is nothing to canary, and no session running in a Linux worktree (or
any environment without physical access to the Mac minis) can register new
hardware. The prerequisite action is running
`scripts/setup/install-self-hosted-runner.sh` **on the physical machine**
to re-register it, which is an operator/physical-access action.

**Disposition:** INFRA-1655 is closed as "root cause found and fixed;
restoration blocked on hardware re-registration." The remaining
hardware-dependent restoration work (AC4-6 — re-enable master toggle,
restore lanes one at a time, emit `runner_health_restored`) is already
tracked by **INFRA-3403** ("restore remaining self-hosted runner lanes one
at a time"), which is the correct single home for that follow-up once the
M4 hardware is physically re-registered. **Future fleet cycles should not
file or pick further INFRA-1655 reproduction/root-cause slices** — the
question this gap asked has been answered and re-confirmed independently
more than enough times; the ~24 open `INFRA-3544`-`INFRA-3579` sub-gaps
that duplicate this investigation are being closed as superseded by this
section for the same reason.

### state.db sync (2026-08-18, fleet-1 slice)

The 2026-08-12 closing commit above (a7413121) updated this doc's
disposition but never flipped the gap's `status` field in canonical
`state.db` — it stayed `open`, which is what routed this INFRA-1655 fleet
dispatch here in the first place (the docs/gaps YAML mirror also still read
`open`). No new reproduction or root-cause work was needed; this slice's
only job is closing that gap between "documented disposition" and "actual
gap-registry state" via `chump gap ship`, so the picker stops re-surfacing
an investigation that already reached its documented conclusion.

**Sync executed (2026-08-18, fleet-1 slice, this PR):** ran
`chump gap ship INFRA-1655 --update-yaml --closed-pr 3684 --why`. Result:
`status` flipped to `done` in canonical `state.db` (confirmed via
`sqlite3 .chump/state.db "SELECT id,status,closed_pr FROM gaps WHERE
id='INFRA-1655'"` → `INFRA-1655|done|3684`); `--update-yaml` was a no-op
per ZERO-WASTE-020 (YAML mirrors are retired, state.db is sole canonical
source — `docs/gaps/INFRA-1655.yaml` is a stale historical artifact, not
read by the picker). The gap is now closed end-to-end; no further
INFRA-1655 slices should be dispatched.

### state.db sync — actual root cause of the resync loop (2026-08-18, fleet-1 slice #2)

The sync above still didn't hold: this gap re-surfaced `open` in the
canonical `state.db` and routed a second INFRA-1655 fleet-1 dispatch to
this same worktree. Root cause: `chump gap ship` resolves `.chump/` relative
to **process cwd**, not the git-common-dir. A linked worktree
(`.claude/worktrees/<name>/`) has its own `.chump/state.db` — freshly
scaffolded and empty/stale for a new worktree — which is a *different file*
from the canonical `.chump/state.db` at the main checkout root
(`/home/jeff/Projects/chump/.chump/state.db`). The prior slice's `chump gap
ship` ran from inside the worktree, so it flipped the worktree-local copy
(which nothing else reads) and never touched the canonical row — `sqlite3
.chump/state.db ...` in that same slice's verification command was equally
worktree-relative, so the check "confirmed" a write that never reached the
shared source of truth.

**Fix applied this slice:** ran `chump gap ship INFRA-1655 --update-yaml
--why` with cwd set to the main checkout (`/home/jeff/Projects/chump`, not
the worktree), then verified against that same path:
`sqlite3 /home/jeff/Projects/chump/.chump/state.db "SELECT id,status,closed_pr
FROM gaps WHERE id='INFRA-1655'"` → `INFRA-1655|done|`. Any future
gap-registry mutation issued from a linked worktree should `cd` to the main
checkout first (or otherwise target the canonical `.chump/state.db` path
explicitly) — running `chump gap ship`/`chump gap set` from a worktree
silently no-ops against the shared registry, which is exactly the
gap-reopens-itself loop this section documents.

### state.db sync — per-machine local db is the actual root cause (2026-08-19, fleet-1 slice)

Despite the two prior slices fixing the worktree-vs-main-checkout cwd bug and
confirming `INFRA-1655` flipped to `done` (via `sqlite3 .../.chump/state.db`
on that machine), this gap re-surfaced `open` and routed a *third* fleet-1
dispatch — this time to a session on a different physical host (`closetjunky`,
Linux) than the machine(s) those earlier fixes ran on.

**Root cause: `state.db` is gitignored (`.chump/state.db` — see
`.gitignore`) and therefore purely local per machine, not shared fleet-wide.**
Every previous "sync executed, confirmed done" slice only ever proved the
flip held on *that one machine's* local `state.db`. It never propagated to
any other machine's copy — there is no sync mechanism between them, by
design (state.db is intentionally excluded from git). A fleet worker
dispatched on a machine that never ran the `chump gap ship` flip locally
sees `status=open` in its own `state.db` and legitimately re-picks the gap,
because from that machine's point of view the gap genuinely never shipped.

This means "run `chump gap ship` from the main checkout, not the worktree"
(the INFRA-1655-fleet-1-slice-#2 fix above) is necessary but not sufficient
across a multi-machine fleet — it has to be run **once per machine** that
might dispatch this gap, or the picker will keep re-surfacing it on whichever
host hasn't locally flipped it yet. There is currently no cross-machine
gap-registry sync; each host's `chump gap reserve`/`chump gap ship` only ever
mutates its own local file.

**Action taken this slice:** flipped `status=done` in this host's
(`closetjunky`) local `.chump/state.db` for `INFRA-1655`, from the main
checkout (not this worktree), matching the same command form used on the
prior fix. This closes the loop for *this* machine. Any other machine that
has never locally shipped `INFRA-1655` will still show it `open` in its own
`state.db` until it, too, runs the flip — that is expected given the
per-machine-local design, not a bug to chase further. **No further
INFRA-1655 investigation slices are warranted on any host** — if the gap
resurfaces again, the fix is a one-line local `chump gap ship` from that
host's main checkout, not another reproduction/root-cause pass.

### INFRA-3403 disposition: lane restoration blocked, not attempted (2026-08-31)

INFRA-3403 asked to restore the remaining 4 self-hosted lanes
(`RUNNER_AUDIT`, `RUNNER_COVERAGE`, `RUNNER_E2E_GOLDEN_PATH`,
`RUNNER_TAURI_COWORK_E2E`) one at a time, gated on AC1: confirming the
`RUNNER_E2E_PWA` canary lane had run clean across ≥3 PR cycles. Checked
live state before touching any `gh variable` command:

```
$ gh variable list -R repairman29/chump
CHUMP_SELF_HOSTED_CHANGES	false	2026-05-28T01:16:41Z
CHUMP_SELF_HOSTED_ENABLED	false	2026-07-27T01:57:02Z

$ gh variable get RUNNER_E2E_PWA -R repairman29/chump
variable RUNNER_E2E_PWA was not found

$ gh api repos/repairman29/chump/actions/runners --jq '.runners[] | {name,status,labels:[.labels[].name]}'
{"labels":["self-hosted","Linux","X64","chumpd-host"],"name":"chumpd-eu-runner","status":"offline"}
```

**AC1 cannot be satisfied — the canary premise no longer holds.**
`RUNNER_E2E_PWA` is not currently set at all (no lane variables exist),
`CHUMP_SELF_HOSTED_ENABLED` has been `false` since 2026-07-27, and the only
registered runner in the pool is `chumpd-eu-runner` (Linux/x64, currently
**offline**) — there is zero macOS-arm64 hardware registered to route a
`self-hosted,macos-arm64,chump-fleet` job to. This matches, and is caused
by, two things already on record in this doc:

1. **The 2026-07-27 disk-pressure decision** (see "Resolved: checkout flake
   root cause + current state" above) — the operator deliberately stopped
   the 4 M4 runners (`launchctl bootout` + `.plist.bak`) because cargo/
   rust-cache churn was eating the Mac's thin disk headroom, and decided
   *not* to re-enable while that Mac also hosts fleet coordination. This is
   a standing operator decision, not an incident to fix.
2. **Full deregistration since** (INFRA-3544/3550/3556/3562/3574/3576) —
   the `jeffs-macbook-air-10-X` runners are no longer merely stopped, they
   are absent from `gh api .../actions/runners` entirely. Setting any
   `RUNNER_*` lane variable to `macos-arm64` labels today would not "restore
   a canary," it would silently queue jobs against hardware that doesn't
   exist to dispatch to.

**Disposition: closed as blocked, matching INFRA-1655's disposition.**
Restoring lanes is not this session's call to make unilaterally — it would
both re-litigate the 2026-07-27 disk-pressure decision and route jobs at
non-existent hardware, neither of which "restore RUNNER_AUDIT, wait one
clean PR cycle" can paper over. No lane variables were set. AC6
(`kind=runner_health_restored`) is not applicable — there is no full
restoration to announce. The correct trigger to resume this work is a
physical/operator action (re-register the M4 hardware via
`scripts/setup/install-self-hosted-runner.sh` on the machine, and revisit
the disk-pressure constraint), at which point the original one-lane-at-a-
time sequence in "Required steps to restore self-hosted routing" above is
still the right playbook. **No further INFRA-3403 restoration slices
should be dispatched until that physical precondition changes** — re-running
this same `gh variable list` / `gh api runners` check will keep returning
the same `runner_absent`/`offline` result until then.

---

## Pi mesh provisioner (INFRA-1543)

Each Raspberry Pi (Linux ARM64) in the mesh runs one runner labeled
`[self-hosted, Linux, ARM64, linux-arm64, chump-fleet-pi]`. Lightweight
workflows (docs build, lint, smoke tests) run well on Pi 5; heavy Rust
compiles stay on M4.

### Physical setup

1. **SD card image** — flash Raspberry Pi OS Lite (64-bit) or Ubuntu
   Server 24.04 LTS ARM64. Either works; Ubuntu preferred for 6+ months
   of security updates on the same LTS.
2. **Boot config** — enable SSH at flash time (`ssh` file in `/boot`),
   or via `raspi-config` on first boot.
3. **Network** — static IP or DNS-stable hostname recommended so the
   runner registration survives IP changes. On a home LAN: assign a
   DHCP reservation via your router using the Pi's MAC address.
4. **User** — create a non-root user (e.g. `runner`) and add to
   `sudo` group: `usermod -aG sudo runner`.

### Software prerequisites (on each Pi)

```bash
sudo apt-get update && sudo apt-get install -y git curl jq
# gh CLI (required for token fetch + --check)
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
  https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update && sudo apt-get install -y gh
gh auth login   # authenticate once; credentials persist
```

### Register a Pi on first boot

Run from the Pi (must be cloned or scp'd from the Chump repo):

```bash
# Interactive (fetches registration token via gh API automatically)
scripts/setup/install-self-hosted-runner-pi.sh

# Non-interactive with explicit token
scripts/setup/install-self-hosted-runner-pi.sh --token <TOKEN>
```

Get a registration token manually:
1. Visit `https://github.com/repairman29/chump/settings/actions/runners/new`
2. Copy the token shown (valid 60 min)
3. Pass with `--token`

### Verify

```bash
# On the Pi — queries GH API for linux-arm64 runners:
scripts/setup/install-self-hosted-runner-pi.sh --check

# From any machine with gh:
gh api /repos/repairman29/chump/actions/runners \
  --jq '.runners[] | select(.labels[].name=="linux-arm64") | "\(.name) [\(.status)]"'
```

### Offline / air-gapped install

For Pis with restricted or no outbound internet access:

```bash
# Step 1: Download the tarball to the cache (do once, on a connected machine)
scripts/setup/install-self-hosted-runner-pi.sh --cache-only
# Tarball lands in ~/.cache/chump-runner/pi-tarball/

# Step 2: Copy the cache dir to each air-gapped Pi
scp -r ~/.cache/chump-runner/pi-tarball/ runner@pi-hostname:~/runner-cache/

# Step 3: On the air-gapped Pi, point the installer at the local cache
CHUMP_PI_TARBALL_CACHE=~/runner-cache \
  scripts/setup/install-self-hosted-runner-pi.sh --token <TOKEN>
# or use --from-cache if the tarball lives in a specific directory:
scripts/setup/install-self-hosted-runner-pi.sh --from-cache ~/runner-cache --token <TOKEN>
```

The cache is keyed by runner version filename
(`actions-runner-linux-arm64-<version>.tar.gz`). Adding a second Pi
when the cache is warm requires no internet access.

### Uninstall / de-register

```bash
scripts/setup/install-self-hosted-runner-pi.sh --uninstall
# or with explicit token to de-register from GitHub too:
scripts/setup/install-self-hosted-runner-pi.sh --uninstall --token <TOKEN>
```

### Maintenance

| Operation | Command |
|---|---|
| Status | `sudo systemctl status chump-actions-runner-pi` |
| Logs | `sudo journalctl -u chump-actions-runner-pi -f` |
| Restart | `sudo systemctl restart chump-actions-runner-pi` |
| List Pi runners | `gh api /repos/repairman29/chump/actions/runners --jq '.runners[] \| select(.labels[].name=="linux-arm64")'` |

### Label scheme for Pi runners

| Label | Meaning |
|---|---|
| `self-hosted` | Any of our machines |
| `Linux` | Linux OS (GH API canonical casing) |
| `ARM64` | ARM64 arch (GH API canonical casing) |
| `linux-arm64` | Compound selector used in workflow `runs-on:` |
| `chump-fleet-pi` | Distinguishes Pi nodes from M4 nodes |

Workflows route to Pi mesh via:

```yaml
runs-on: [self-hosted, linux-arm64, chump-fleet-pi]
```

### CI routing (INFRA-1540 Phase 2)

Once at least one Pi runner is online and `--check` passes, the Phase 2
ci.yml jobs (clippy, cargo-test, audit, coverage, e2e-*) can route to
Pi mesh for Linux runs via:

```bash
gh variable set RUNNER_CLIPPY    --body '["self-hosted","linux-arm64","chump-fleet-pi"]'
gh variable set RUNNER_CARGO_TEST --body '["self-hosted","linux-arm64","chump-fleet-pi"]'
```

Follow the one-lane canary protocol (§ Current state — degraded
ubuntu-only mode) before flipping all lanes.

### Smoke test

```bash
bash scripts/ci/test-pi-mesh-installer-shape.sh
```

Checks: installer syntax, required labels, systemd unit emission,
offline cache path, platform guard, META-064 bypass trailer.
