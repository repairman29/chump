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

Returns exit 0 with the runner list if ≥1 runner is online, exit 1 otherwise.

## Uninstall

```bash
scripts/setup/install-self-hosted-runner.sh --uninstall
```

Removes the launchd plist and runner directory. Re-registration possible afterward.

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

## Smoke test

Once at least one runner is registered, the upcoming `scripts/ci/test-self-hosted-runner-registered.sh` asserts:

1. `gh api /repos/.../actions/runners` returns ≥1 with `status="online"`.
2. The runner's labels include `self-hosted` and at least one platform label.
3. A trivial canary workflow runs to completion on the self-hosted lane.

This becomes part of `chump fleet doctor --check` so a missing/wedged runner
surfaces as a fleet-level health alarm.

---

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
