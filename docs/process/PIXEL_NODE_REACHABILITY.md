# Pixel node reachability — CJ ↔ Pixel (INFRA-3664)

Pixel (`pixel-8-pro`) is the 2nd owned build/shipper node (sovereign horizontal
scale — no cloud). This doc corrects the reachability facts this gap was
originally filed against and documents the wiring path.

## Corrected facts

The gap's own diagnostic (`ssh pixel = DNS fail; 100.90.52.126:22
unreachable; no Host entry`) was testing the **wrong host and the wrong
port**:

| Wrong (as filed)              | Correct                                   |
|--------------------------------|--------------------------------------------|
| `100.90.52.126`                | `100.84.132.93` — `100.90.52.126` is **CJ's own** tailnet IP (`tailscale status`), not Pixel's |
| port `22`                      | port `8022` — Termux's `sshd` runs unprivileged and cannot bind <1024 |
| (no user documented)           | `u0_a314` — Termux's Linux-UID alias, not `pixel`/`termux`/`repairman29` |

`tailscale ping pixel-8-pro` and `nc -zv 100.84.132.93 8022` both succeed —
Pixel was never actually off-network; the recorded IP/port were stale.

## Wiring identity (🤖 scriptable + 🧑 one manual step)

```bash
scripts/setup/wire-pixel-ssh.sh
```

This generates a dedicated `~/.ssh/chump_pixel` keypair, writes a `Host
pixel` block to `~/.ssh/config` (so `ssh pixel` resolves+connects), and
tests connectivity. The **one step it cannot script** (credential action,
never automated per RESILIENT-173 / `ADD_A_FLEET_NODE.md`): pasting the
generated pubkey into `~/.ssh/authorized_keys` **on the phone, in Termux**.
The script prints the exact 3-line command when this step is still pending.

Once authorized, `ssh pixel echo ok` succeeds from CJ (or any box that runs
the wiring script), matching AC1 ("Pixel reachable from CJ").

## Termux Rust toolchain

Tracked separately by `scripts/setup/build-android.sh` (cross-compile from a
Mac) and `chump-node-install.sh` (native on-device install, RESILIENT-318 /
RESILIENT-364 / INFRA-3629) — see `docs/process/COTG_NODE_INSTALL.md`.

## Picker coordination (INFRA-513 race)

`scripts/setup/pixel-worker.sh` previously picked a gap from `chump gap
list --json` and ran `chump --execute-gap` directly against the main
checkout — no atomic claim, so a second worker (CJ, another node) racing on
the same gap in the same window would silently lose (the INFRA-513 failure
mode: `silent_agent` event, one worker's first commit fails). It now:

1. `chump claim "$GAP"` — atomic (single DB transaction; INFRA-513 fix)
2. on claim failure (lost the race, or a gate blocked it): skip, no
   cooldown, re-pick next tick
3. on success: `cd` into the claim's worktree and run `--execute-gap` there

**Stress-test criterion (unchanged from `fleet-scaling-2026-05-06.md`):
zero `silent_agent` events for ≥30 min once the Pixel worker is live and
claiming alongside other workers.**

## Remaining to close AC2

Once the phone-side pubkey step above is done and the worker is started
(`pixel-node-supervisor.sh`), verify:

```bash
# on Pixel or via `ssh pixel`:
tail -f ~/pixel-worker.log     # or wherever supervisor redirects stdout
grep silent_agent .chump-locks/ambient.jsonl | tail   # watch for 30 min
```

and confirm at least one gap ships end-to-end from the Pixel worker (its
`chump claim` + PR shows `WORKER_MACHINE=pixel-8-pro` / `machine:
pixel-8-pro` in the ambient `sub_agent_dispatched`/ship events).
