# Off-laptop substrate — runbook (RESILIENT-176, PREP slice)

> Ground-up step 5 (docs/design/GROUND_UP_2026-07-19.md): run `chumpd`
> (MISSION-051) on an always-on host instead of this MacBook, so lid-close /
> sleep / disk-treadmill stop being fleet-availability problems. Extends the
> INFRA-1543 Pi-mesh direction.
>
> **Status: PREP slice only.** RESILIENT-176 `depends_on: MISSION-051`
> (chumpd binary — open at time of writing, actively being built). This
> document and `scripts/setup/provision-chumpd-host.sh` do the inventory,
> provisioning, and runbook work that doesn't require chumpd to exist yet.
> The actual cutover (AC #1–#4 on RESILIENT-176) is blocked on:
> 1. MISSION-051 merging (chumpd binary + socket API), **and**
> 2. an operator decision on which host candidate below to use.
>
> No remote actions were taken to produce this document. No credentials
> were read, generated, or transmitted.

---

## 1. Today's actual state (verified 2026-07-19, read-only local inventory)

The fleet runs **4 self-hosted GitHub Actions runners**, all registered as
per-user macOS `launchd` LaunchAgents **on this laptop**:

```
$ launchctl list | grep actions-runner
62539  -9  com.chump.actions-runner
62541  -9  com.chump.actions-runner-2
62543  -9  com.chump.actions-runner-3
62544  -9  com.chump.actions-runner-4

$ /usr/libexec/PlistBuddy -c "Print :WorkingDirectory" ~/Library/LaunchAgents/com.chump.actions-runner.plist
/Users/jeffadkins/actions-runner-chump
```

All four `WorkingDirectory` entries resolve to `~/actions-runner-chump*` —
this machine's home directory. **There is no existing always-on host today.**
"Move chumpd off the laptop" is therefore a genuine provisioning decision,
not a config flip.

Laptop specs (for capacity comparison): 24 GB RAM, `/` filesystem 460 GiB
total / ~18 GiB free at time of writing.

---

## 2. Host candidates

| Candidate | Status today | Cost | Capacity vs. requirement | Provisioning readiness |
|---|---|---|---|---|
| **This MacBook** (status quo) | Running 4 GH runners + fleet workers now | $0 marginal | 24 GB RAM, ~18 GiB free disk — meets the ~20 GB floor *today* but competes with dev work, sleeps, and is the exact problem RESILIENT-176 exists to fix | N/A — not a candidate, it's the thing being replaced |
| **Pi-mesh box** (INFRA-1543 direction) | **0 physical Pi's racked.** INFRA-1543 shipped `scripts/setup/install-self-hosted-runner-pi.sh` (systemd, `linux-arm64` labels, offline tarball cache) but its own AC #7 ("rack first Pi, run installer, verify online") is an unchecked operator TODO — no Pi mesh runner has ever registered | Hardware cost only (~$60–150 one-time per Pi 4/5, 8GB); ~$0/mo power | Typical Pi 5 8GB: 8GB RAM (tight — chumpd + 2 Sonnet workers + cargo build headroom is a squeeze), 20-256GB microSD/NVMe depending on config | Installer exists and is tested (`scripts/ci/test-pi-mesh-installer-shape.sh`); needs physical hardware + rack-and-register before it's usable |
| **DigitalOcean droplet** | **Documented + operator-authorized 2026-05-30**, but not confirmed currently running (no local record of an active droplet ID; `gh api .../actions/runners` returned a transient 500 during this inventory, not re-polled per read-only-local scope) | ~$24/mo (`s-4vcpu-8gb`), bumpable to `s-8vcpu-16gb` | 4 vCPU / 8 GB RAM / 160 GB SSD (default size) — comfortably clears the ~20 GB floor and RAM budget | **Most ready candidate.** Full installer already exists: `scripts/setup/install-do-droplet-runner.sh` + `docs/process/SELF_HOSTED_RUNNER_DO.md` (droplet create, Rust toolchain, sccache, runner registration, all scripted). Would need extending (or running alongside) to also provision chumpd once MISSION-051 ships |
| **Mac mini** | Not owned / not referenced anywhere in `docs/`, `SITES.md`, `DOMAINS.md`, or `PROJECT_MATRIX.md` — a hypothetical purchase, not existing infra | ~$599+ one-time (M4 8GB base) + always-on power | 8–24 GB RAM depending on config, generous disk | No installer exists; would reuse the macOS launchd path from `install-self-hosted-runner.sh` + this gap's `provision-chumpd-host.sh`, but needs the physical purchase first |

**Baseline requirement** (chumpd + 2 Sonnet workers, per RESILIENT-176 AC #1
and this gap's inventory): `git`, `gh` (authenticated), `claude` CLI, Rust
`cargo` toolchain, **~20 GB disk** headroom (worktrees + cargo target +
buffer, per `docs/process/DISK_COST_MODEL.yaml`), and outbound network to
`github.com` + `api.anthropic.com`. `scripts/setup/provision-chumpd-host.sh
--check` verifies all of the above on any candidate host without mutating
anything.

**Honest read:** the DigitalOcean droplet is the only candidate with a
tested, already-authorized, already-scripted install path today. The Pi-mesh
direction is the operator's stated long-term preference (INFRA-1543,
`docs/strategy/DISK_AWARE_FLEET_2026-05-29.md`) but requires buying and
racking hardware first. Recommend: pressure-test on the DO droplet path
(cheapest to reverse, fastest to stand up) while Pi hardware acquisition
happens in parallel — **this is an open question for the full RESILIENT-176
gap, not decided by this PREP slice.**

---

## 3. Provisioning — one command

On the chosen host (any of the candidates above once it exists / is
reachable):

```bash
scripts/setup/provision-chumpd-host.sh --check     # readiness report, no mutation, exit 0/1
scripts/setup/provision-chumpd-host.sh --dry-run    # print every action, touch nothing
scripts/setup/provision-chumpd-host.sh              # idempotent full provision
```

What it does, in order:
1. Refuses to run with `$HOME` unset.
2. Checks for `git`, `gh` (+ `gh auth status`), `claude` CLI, `cargo`;
   prints an install hint for anything missing.
3. Checks disk headroom (`>= 20 GB` at `$HOME`) and network reachability to
   `github.com` + `api.anthropic.com`.
4. Checks presence (never value) of `GH_TOKEN`/`GITHUB_TOKEN` and the oauth
   token file (`~/.chump/oauth-token.json` by default) — see the auth
   material checklist below.
5. Clones (or fetches, if already cloned) the repo via HTTPS into
   `$CHUMPD_PROVISION_DIR` (default `~/chump-host`).
6. Builds `chump` (`cargo build --release --bin chump`).
7. Checks whether the checkout has a `chumpd` binary target yet. **Today it
   does not** (MISSION-051 pending) — the script prints a BLOCKED message
   and stops cleanly rather than faking an install. Re-running the script
   after MISSION-051 merges resumes from here.
8. Once `chumpd` exists: installs the service — macOS via
   `scripts/setup/install-chumpd.sh` (not yet written; ships with
   MISSION-051), Linux via the `scripts/setup/chumpd.service` systemd
   user-unit template in this PR (placeholders substituted, installed to
   `~/.config/systemd/user/`).
9. Runs a validation dry-run: `CHUMPD_TAKEOVER=0 chumpd --mode=off
   --dry-run` — proves the supervisor boots and exits clean without taking
   over fleet coordination or touching shared state. (Flag names are
   provisional pending MISSION-051's actual CLI surface.)

Safe to re-run at any point — every step checks current state first.

---

## 4. Auth material checklist

⛔ = operator-only step; this script/runbook never performs it for you.

| Item | Where it lives | How this runbook handles it |
|---|---|---|
| `GH_TOKEN` (GitHub PAT, `repo` scope) | Operator's password manager | ⛔ Operator exports it into an **env file** on the host (e.g. `~/.chump/chumpd.env`, `chmod 600`), never into a command line / argv (RESILIENT-173). `provision-chumpd-host.sh --check` only checks presence in the current shell env, never prints the value. |
| Claude subscription oauth token | `~/.chump/oauth-token.json` on the machine that's currently authenticated | ⛔ Operator copies this file to the new host out-of-band (`scp` between two machines the operator controls, or re-run `claude login` on the new host). The provisioning script only checks the file exists. |
| SSH key for git push (if not using HTTPS+token) | `~/.ssh/` | ⛔ Operator provisions per `CLAUDE.md` → INFRA-AGENT-CREDS "explicit mode" (`SSH_KEY_PATH` env var) or relies on `gh auth login`'s HTTPS credential helper. |
| `EnvironmentFile=` referenced by `chumpd.service` | `~/.chump/chumpd.env`, `0600`, not committed | ⛔ Operator creates this file directly on the host; the systemd template references it via `EnvironmentFile=-...` (leading `-` = optional, service still starts if the file is briefly absent during provisioning). |

Per `CLAUDE.md` → "GitHub credentials for agents (INFRA-AGENT-CREDS)": the
explicit mode (`GH_TOKEN`, `SSH_KEY_PATH`, `GITHUB_TOKEN` env vars) is the
right mode for a fresh host with no keyring — implicit mode (macOS Keychain
/ inherited SSH agent) doesn't transfer to a new machine.

---

## 5. Cutover checklist (once MISSION-051 has shipped AND a host is chosen)

1. `scripts/setup/provision-chumpd-host.sh` on the target host — confirm it
   completes through "service install" (no BLOCKED message).
2. Operator provisions auth material per §4 on the target host.
3. Start chumpd on the target host in **off mode** first (`CHUMPD_TAKEOVER=0`
   equivalent, or whatever MISSION-051 lands as the non-takeover flag) —
   confirm it stays up, logs cleanly, and does not touch `.chump/state.db`
   or claim any leases.
4. Flip the target host's chumpd to active mode.
5. **Stop chumpd/workers on the laptop.** (Today: the tmux fleet-worker
   panes + whatever daemon zoo MISSION-051 absorbs.) This is the actual
   moment of substrate transfer.
6. Point the laptop's `chump` CLI / ChumpBar at the remote chumpd (socket
   over Tailscale or SSH port-forward — RESILIENT-176 AC #2, not designed by
   this PREP slice).
7. Ship one real gap end-to-end with the laptop lid **closed** (RESILIENT-176
   AC #1) — the actual proof this worked.

### Both-on double-spawn hazard — OPEN QUESTION for the full gap

`chumpd`'s single-instance guard (whatever MISSION-051 lands — presumably a
PID file or `KeepAlive` launchd singleton) prevents **two chumpd processes
on the same machine** from double-spawning workers. It does **not**,
by itself, prevent **two different machines** (laptop + remote host) from
each running a chumpd that claims gaps out of the same canonical
`.chump/state.db` simultaneously — that's a cross-machine coordination
problem, not a per-machine one. Today's atomic-claim primitive
(`try_claim_gap`, INFRA-468) should still make double-claiming *safe*
(one loses the race), but it does **not** make it *free* — two chumpd
instances both spinning up workers against the same gap pool wastes a full
worker's context on the loser every time. This PREP slice does **not**
design the cross-machine guard (e.g. a leader-election lock, a
"this-machine-is-canonical" flag, or NATS-based mutual exclusion per
`docs/design/A2A_ROADMAP.md`) — it is flagged here as unresolved so the full
RESILIENT-176 cutover slice tackles it explicitly rather than discovering it
live during step 5 above.

**Recommended interim discipline** (until the guard is designed): the
cutover checklist above is written as *stop-then-start*, not
*start-then-stop* — always stop the laptop's chumpd (step 5) before or
immediately after flipping the remote host active (step 4), never run both
in active mode intentionally, even briefly.

---

## 6. Rollback

If the remote host misbehaves (auth failure, network partition, unexpected
cost, disk pressure):

1. `scripts/setup/provision-chumpd-host.sh --uninstall` on the remote host
   stops + removes the chumpd service (leaves the repo clone in place for
   diagnosis).
2. Re-enable the laptop's chumpd/worker path (reverse of cutover step 5).
3. Laptop resumes grind mode via the existing `chump-mode` dial
   (`~/.local/bin/chump-mode grind`) — no new mechanism needed; this is the
   same lid-close-safe path RESILIENT-169 already built as insurance.
4. File a gap capturing what went wrong on the remote host before retrying.

Rollback is designed to be **at least as safe as today** — nothing in this
PREP slice removes or weakens the laptop's existing ability to run the
fleet solo.

---

## 7. Wake-test analog

RESILIENT-169 proved lid-close/sleep recovery *on the laptop* (a pause, not
an outage) by: close lid → wait → open lid → assert the fleet resumes within
a bounded window, with an ambient-stream receipt. The off-laptop substrate
needs the equivalent proof for the **remote host's** failure modes once
chumpd exists there:

- **Reboot test**: reboot the remote host → assert chumpd (via `systemctl
  --user` linger or launchd `KeepAlive`) comes back within N seconds,
  without operator intervention.
- **Network-partition test**: sever the remote host's network for a few
  minutes (simulating a cloud provider blip or a Pi's flaky wifi) → assert
  chumpd holds state and resumes claiming gaps once connectivity returns,
  rather than corrupting `.chump/state.db` or double-claiming with the
  laptop.
- **kill -9 chumpd test**: same as MISSION-051 AC #4 (`kill -9 chumpd` →
  revived within 60s), run on the actual remote host, not just locally.

These are **not implemented by this PREP slice** — they're the acceptance
tests the full RESILIENT-176 cutover slice should write once MISSION-051 and
a host decision both land.

---

## References

- `docs/design/GROUND_UP_2026-07-19.md` — step 5 of the migration sequence
- `docs/strategy/DISK_AWARE_FLEET_2026-05-29.md` — capacity/disk planning architecture (META-128)
- `docs/process/DISK_COST_MODEL.yaml` — per-action disk cost estimates
- `docs/process/SELF_HOSTED_RUNNER_DO.md` — DigitalOcean droplet path (existing, operator-authorized)
- `scripts/setup/install-self-hosted-runner-pi.sh` + INFRA-1543 — Pi-mesh installer (shipped, unracked)
- `CLAUDE.md` → "GitHub credentials for agents (INFRA-AGENT-CREDS)" — auth mode contract
- RESILIENT-173 — no secrets in argv (env files only)
- RESILIENT-169 — sleep/wake recovery on the laptop (the pattern this doc's §7 extends)
- MISSION-051 — chumpd supervisor umbrella (this gap's blocking dependency)
