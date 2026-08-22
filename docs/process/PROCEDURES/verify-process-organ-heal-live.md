# Verify process-organ-heal LIVE tier on closetjunky — Operator Procedure

**Filed under:** `docs/process/PROCEDURES/` — INFRA-3650 (PEER-HEAL-03, MISSION-010)
**Source scripts:** `scripts/ops/process-organ-heal.sh`, `scripts/ops/check-process-organ-heal-live.sh`, `scripts/setup/chump-node-install.sh`

---

## Status: LIVE ✓ confirmed on closetjunky (2026-08-22)

INFRA-3650 shipped the process-organ heal loop (revives unsupervised bash
procs like `almanac-vision-keeper.sh` that aren't wrapped as systemd units)
across three PRs (#4115, #4116, and this session's finalization). The
**WIRING tier** — the code, the registry, the install-time hook in
`chump-node-install.sh`, the reaper-heartbeat-watchdog.sh TARGETS entry, and
CI coverage (`scripts/ci/test-process-organ-heal.sh`) — was shipped first and
was already green.

The **LIVE tier** (AC1/AC4: proving the loop is actually running on
`closetjunky` itself, not just merged) turned out to be verifiable in this
session, once it became clear the session's worktree host **is**
closetjunky (`hostname` → `closetjunky`) — the earlier remote-access attempts
below were all trying to SSH into itself with the wrong keys, not a real
external-access problem:

```
$ scripts/ops/check-process-organ-heal-live.sh
=== check-process-organ-heal-live (INFRA-3650, AC4) ===
  ✓ process-organ-heal: systemd timer chump-process-organ-heal.timer active (oneshot+timer shape)
  ✓ organ_watchdog_tick fresh (3s ago, threshold 600s): 2026-08-22T09:55:22Z
  ✓ almanac-vision-keeper: running (pgrep)

 LIVE ✓  process-organ-heal + almanac-vision-keeper confirmed on this node
```

That first run required a manual `CHUMP_AMBIENT_LOG` override, which
surfaced a real bug: the script's hardcoded default
(`$HOME/.chumpnode/repo/.chump-locks/ambient.jsonl`) does not match how
`chump-process-organ-heal.service` actually deploys on CJ — its systemd
drop-in sets `CHUMP_REPO_ROOT=/home/jeff/Projects/chump`, not
`$HOME/.chumpnode/repo`. The script was silently reporting a false NOT-LIVE
verdict even though the loop was genuinely live. Fixed in this same PR: the
script now discovers its own checkout's `.chump-locks/ambient.jsonl` by
walking up from its own script path (same trick `process-organ-heal.sh`
already used), with `CHUMP_AMBIENT_LOG` still available as an explicit
override. Regression-guarded by
`scripts/ci/test-process-organ-heal.sh` step 7.

### Why earlier sessions believed this was blocked

Before this session confirmed the host, remote-access attempts from a
regular (non-CJ) Claude Code worktree all failed, which is still true for
*other* fleet sessions that are not physically running on CJ:

- `ssh closetjunky` / `ssh 100.90.52.126` → `Permission denied (publickey)` (no key for this box in a non-CJ worktree)
- `tailscale ssh closetjunky` → fails at host-key verification (CJ's sshd isn't Tailscale-SSH-enabled)
- `ssh -o ProxyCommand="tailscale nc %h %p" closetjunky` (routes over the tailnet, bypassing the tailscale-ssh wrapper) → still `Permission denied (publickey)` — confirms it's a real auth gap for remote sessions, not a routing issue
- No GitHub Actions self-hosted runner is registered on CJ (`gh api repos/repairman29/chump/actions/runners` shows only `chumpd-eu-runner`, a different host, and it's offline) — so there's no CI-driven remote path either

**Lesson for future sessions:** check `hostname` before concluding a target
node is unreachable — a fleet worker dispatched with a node-scoped worktree
may already *be* the target node.

## Steps (run ON closetjunky, or via SSH from a session that has the key)

**1. Confirm the organ is installed (idempotent — safe to re-run):**
```bash
bash scripts/setup/chump-node-install.sh
```
This installs the `process-organ-heal` wrapper under `common_organs()` (see
`scripts/setup/chump-node-install.sh:401-430`) if it isn't already present.

**2. Run the live-tier check:**
```bash
scripts/ops/check-process-organ-heal-live.sh
```
Exit 0 + `LIVE ✓` means:
- the heal loop's systemd unit/timer or wrapper process is active (pgrep or systemctl)
- a fresh `kind=organ_watchdog_tick` (source=process-organ-heal) appeared in `ambient.jsonl` within the last 2 cycle-intervals
- `almanac-vision-keeper.sh` is running

**3. If it fails**, the script's own `no "..."` output names which of the
three checks is red — re-run step 1, then check
`.chump-locks/process-organ-logs/process-organ-heal.log` (relative to the
checkout root) for spawn errors.
