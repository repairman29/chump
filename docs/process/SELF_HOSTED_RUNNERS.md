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
