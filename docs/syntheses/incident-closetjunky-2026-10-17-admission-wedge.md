# Incident: closetjunky admission-ceiling wedge — 2026-10-17 02:10Z

**Incident ID**: RESILIENT-1611 incident class 21 (admission-ceiling wedge)
**Node**: closetjunky (4-core 8GB)
**Start time**: 2026-10-17T02:10Z
**Duration**: ~54 minutes (until manual power cycle at ~02:04Z UTC... actually 03:04Z)
**Status**: RESOLVED (power cycled); root cause fixes shipped in RESILIENT-1611

## Summary

closetjunky became unreachable for command execution while a Sonnet dispatch ran `cargo fix --workspace --all-targets` (62% CPU) beside a second `claude -p` instance. The node entered memory thrash with load 14.1 on 4 cores. SSH authenticated but hung with "Timeout, server 100.90.52.126 not responding"; Tailscale was reachable (ping 12ms) but not SSH-enabled, blocking rescue.

## Timeline

- **02:10Z**: Sonnet dispatch starts workspace-wide cargo fix on closetjunky.
- **02:15Z**: Load observed at 14.1 on 4 cores; MemAvailable very low; ssh authentication succeeds, then times out.
- **02:27Z**: Last successful observation before node became fully unresponsive.
- **02:04Z** → **03:04Z**: Node unable to accept new SSH sessions; Tailscale active but no SSH fallback available.
- **03:04Z+**: Manual power cycle from cabinet (operator requested via jeffos).

## Root Cause

The admission ceiling (INFRA-8219 / RESILIENT-1604) was not yet counting `cargo fix`, `cargo clippy`, or `cargo test` as cargo jobs. The gap description in RESILIENT-1611 states:

> The Sonnet brief for shell-only gaps forbids workspace-wide cargo commands (R6.3 layer-aware dispatch gives shell gaps no cargo at all).

Without this restriction, a Sonnet instance spawned to work on a shell-only gap was able to run `cargo fix --workspace --all-targets` unchecked, exhausting the node's resources. Two concurrent `claude -p` instances + heavy cargo build = load 14 on 4 cores = memory thrash.

Admission ceiling guards against *concurrent* jobs but not against *single jobs with massive scope*. The fix is twofold:
1. **Dispatch routing (R6.3)**: Shell-only gaps are dispatched to Sonnet with a budget that forbids workspace-wide cargo commands.
2. **Node dead-man (RESILIENT-1611 AC#3)**: A watchdog monitors load and memory; when sustained above threshold, it kills the newest `claude -p` and `cargo tree` processes, and triggers a watchdog reboot if sshd becomes unresponsive.

## Lessons Learned

1. **Admission ceilings are necessary but insufficient**: They prevent *concurrent* spawning but don't protect against a single job with unbounded scope (cargo fix --workspace on a 4-core box).

2. **Dispatch routing must enforce model-scoped constraints**: Sonnet for shell-only gaps should never have the budget to run workspace builds. The layer-aware dispatch model (INFRA-8220) assigns opus (3600s) to Rust, sonnet (1800s) to shell/docs; the dispatch brief for sonnet must forbid workspace-wide cargo commands.

3. **SSH is a single point of failure**: When sshd entered memory thrash and became unresponsive, the node went OFFLINE on the tailnet with no fallback. Tailscale SSH (tailscale set --ssh) provides a rescue path on port 3478 that is independent of the system sshd.

4. **Node dead-man is essential for owned iron**: A machine without self-reboot capability after prolonged unresponsiveness requires manual intervention (power cycle from cabinet). Systemd watchdog or kernel softdog + a load/memory killer closes the loop: the node can recover itself.

## Fixes Shipped

### 1. Dispatch brief restriction (R6.3 layer-aware routing)

Shell-only gaps (no `.rs` files) are dispatched to Sonnet with a restriction in the brief:

> **Do not run workspace-wide cargo commands** (`cargo fix --workspace`, `cargo clippy --workspace`, `cargo test --workspace`). These commands require Rust model budget and are forbidden for shell-only gaps per PHASE-R R6 layer-aware dispatch (INFRA-8220).

This is enforced at the dispatch routing layer and documented in the subagent brief.

### 2. Node dead-man watchdog (AC#3)

Installed via `chump-node-install.sh` on every owned node:
- Monitors load1 and MemAvailable every 60 seconds (configurable).
- When load1 > 3 × nproc for 10 minutes (configurable), kills the newest `claude -p` and `cargo tree` processes.
- When MemAvailable < 5% for 10 minutes (configurable), kills the newest `claude -p` and `cargo tree` processes.
- When sshd remains unresponsive for 15 minutes (configurable), triggers a hardware watchdog reboot (systemd watchdog or kernel softdog).
- Emits `kind=deadman_load_action`, `kind=deadman_memory_action`, `kind=deadman_reboot` to ambient.jsonl.

### 3. Tailscale SSH enablement (AC#4)

`chump-node-install.sh` now runs `tailscale set --ssh` on every owned node, enabling the Tailscale SSH listener on port 3478. This provides a rescue path independent of the system sshd.

Verification: `tailscale ssh <node-name>` works even when system sshd is wedged.

## Prevention

To prevent recurrence:

1. **Dispatch briefs for shell-only gaps** must include the forbiddance of workspace-wide cargo commands.
2. **Layer-aware dispatch model (INFRA-8220)** ensures shell gaps get Sonnet (1800s budget), which is insufficient for workspace builds.
3. **Dead-man watchdog** on every node auto-recovers from sustained load/memory pressure.
4. **Tailscale SSH** as a fallback when system sshd is unresponsive.
5. **Admission ceiling** (INFRA-8219) prevents concurrent overload; dead-man prevents single-job unbounded scope.

## Incident Classification

**Class 21**: Admission-ceiling wedge (single large job exceeds node capacity, memory thrash, sshd unresponsive, no fallback rescue path).

## Related Gaps

- RESILIENT-1611: phase-R R6 admission ceiling + node-level dead-man self-reboot
- INFRA-8220: layer-aware dispatch model defaults (Opus/3600 for Rust, Sonnet/1800 for shell+docs)
- INFRA-8219: port node admission ceiling to Rust (chump admit)
- RESILIENT-1604: node-wide admission ceiling for claude -p + cargo/rustc
