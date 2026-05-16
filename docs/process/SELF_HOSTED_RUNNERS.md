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
