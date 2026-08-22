# Verify process-organ-heal LIVE tier on closetjunky — Operator Procedure

**Filed under:** `docs/process/PROCEDURES/` — INFRA-3650 (PEER-HEAL-03, MISSION-010)
**Source scripts:** `scripts/ops/process-organ-heal.sh`, `scripts/ops/check-process-organ-heal-live.sh`, `scripts/setup/chump-node-install.sh`

---

## Why this procedure exists

INFRA-3650 shipped the process-organ heal loop (revives unsupervised bash
procs like `almanac-vision-keeper.sh` that aren't wrapped as systemd units)
across three PRs (#4115, #4116, and this session's finalization). The
**WIRING tier** — the code, the registry, the install-time hook in
`chump-node-install.sh`, the reaper-heartbeat-watchdog.sh TARGETS entry, and
CI coverage (`scripts/ci/test-process-organ-heal.sh`) — is fully shipped and
green.

The **LIVE tier** — actually confirming the loop is running on
`closetjunky` (CJ) itself — cannot be done from a Claude Code session. Every
authoring session so far (2026-08-22, this session included) has confirmed
there is **no credential path** from the fleet's sandboxed sessions to CJ:

- `ssh closetjunky` / `ssh 100.90.52.126` → `Permission denied (publickey)` (no key for this box in any worktree)
- `tailscale ssh closetjunky` → fails at host-key verification (CJ's sshd isn't Tailscale-SSH-enabled)
- `ssh -o ProxyCommand="tailscale nc %h %p" closetjunky` (routes over the tailnet, bypassing the tailscale-ssh wrapper) → still `Permission denied (publickey)` — confirms this is a real auth gap, not a routing issue
- No GitHub Actions self-hosted runner is registered on CJ (`gh api repos/repairman29/chump/actions/runners` shows only `chumpd-eu-runner`, a different host, and it's offline) — so there's no CI-driven path either

This is expected and correct per this gap's AC4 ("verified by systemctl/pgrep
on the TARGET node, never merged=running") — a green PR proves the code is
correct, not that any specific machine is running it. **Only a human with an
authorized SSH key for CJ (currently: the operator, from `jeffs-macbook-air`)
can close this loop.**

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
`~/.chumpnode/repo/.chump-locks/process-organ-logs/process-organ-heal.log`
for spawn errors.

## Closing the loop

Once `check-process-organ-heal-live.sh` reports `LIVE ✓` on CJ, this gap's
AC1 and AC4 are satisfied end-to-end. No code change is required to close
this — it's a pure verification step.
