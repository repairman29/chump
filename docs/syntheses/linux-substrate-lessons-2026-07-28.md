# Linux substrate lessons — what deploying chumpd off the laptop taught us

> Synthesis, 2026-07-28. Consolidates the scattered lessons from moving chumpd
> from Jeff's MacBook onto commodity Linux (Helsinki EU host + closetjunky cabinet
> box). Sources: RESILIENT-176/183/184/185/186/187/189/190/191/200, MISSION-051/
> 065/066/072/073, and [`OFF_LAPTOP_SUBSTRATE.md`](../process/OFF_LAPTOP_SUBSTRATE.md)
> + [`ADD_A_FLEET_NODE.md`](../process/ADD_A_FLEET_NODE.md).
>
> **Why this doc exists:** the lessons live across ~8 gaps + 2 runbooks. This puts
> the real cost of ChumpOS **Phase 0** — and the tail still open — in one place, so
> it isn't re-derived on the next bringup. Each lesson below is a bug we actually
> hit, not a hypothetical.

## The frame: this IS ChumpOS Phase 0 → Phase 7

The [ChumpOS arc](../ROADMAP.md) is: an agentic OS that runs a fleet of swappable
harnesses on commodity hardware, human at ring-0. Phase 0 is "substrate &
governance"; the North Star (Phase 7) is "one-command install on commodity Linux +
local-model lane." **Every lesson here is a step from *"runs on Jeff's Mac"* to
*"installs on any box."*** The deployment work is not self-referential meta — it is
the OS becoming real. (Contrast: the comprehension-organs / LLM-service series is
harder to tie to "installs on a box"; the substrate work is the legitimate core.)

## The lessons, clustered

### 1. A fresh Linux box is a long tail of missing pieces
Each new host surfaced a new gap; the provisioner absorbed them one at a time.
- Missing system libs: `libssl-dev` → openssl-sys build fail (RESILIENT-186); GTK
  webview dev libs (RESILIENT-183). `provision-chumpd-host.sh --install-deps` now
  installs build-essential, libssl-dev, GTK libs, pkg-config, sqlite3, gh, rustup.
- **Low-RAM OOM:** boxes < 12 GB OOM on `cargo build` unless LTO off / 16
  codegen-units / 3 jobs + an 8 GB swapfile. Provisioner auto-detects and does it.
  (closetjunky + Helsinki are 4-core / ~7.6 GB — both low-RAM.)
- **`CHUMP_REPO` phantom-path bug (RESILIENT-189):** without it chumpd defaults to
  `$HOME/Projects/Chump` and drives a path that doesn't exist on the node ("root-of-
  roots" bug from the EU migration). The env template pins it; never remove it.

### 2. Cross-machine coordination is the hard part — and it fails SILENTLY
This is the class that bites worst because nothing errors; it just degrades.
- **NATS connect timeout (default 500 ms is too short).** A home-NAT → cloud-hub
  link is DERP-relayed at 300–800 ms RTT; the multi-roundtrip handshake times out
  and claims **silently fall back to local-only = two nodes can claim the same gap.**
  Fix: `CHUMP_NATS_TIMEOUT_MS=8000`.
- **`async_nats` ignored URL credentials (RESILIENT-190).** Symptom: `authorization
  violation`. Fixed by parsing creds from the URL into `ConnectOptions` — but a node
  on a **stale binary** still fails, which is why currency (lesson 5) matters.
- **NATS must be tailnet-only.** Broker binds to the Tailscale interface; never
  exposed to the public internet. Coordination rides the private mesh.
- **The "both-active" hazard is still discipline, not mechanism.** NATS-KV atomic
  claims make double-claiming *safe* (one loses the race) but not *free* (the loser
  burns a worker's context). A cross-machine leader-election guard is still unbuilt
  (flagged in OFF_LAPTOP_SUBSTRATE §5); the interim rule is stop-then-start on cutover.

### 3. Auth is oauth — and the trap recurs
- `CLAUDE_CODE_OAUTH_TOKEN` (long-lived, from `claude setup-token`) is the **whole**
  auth story for the `claude` backend. No refreshing token file to manage.
- **Set `CHUMP_AUTH_MODE=oauth`** so a stale/absent API key can't outrank the valid
  oauth token — the exact trap behind the multi-day silent outages.
- Credentials never in chat/argv (RESILIENT-173): env files (`~/.chump/chumpd.env`,
  0600), streamed machine-to-machine.

### 4. The free-tier lane is real but weak (two-tier reality)
- `chump-local` (open models via the EFFECTIVE-314 cost ladder) shipped **0/10** on
  the EU host at first (RESILIENT-187); the picker even mis-routed hard gaps to it
  (RESILIENT-184). `claude` is the reliable shipper; `chump-local` is the ~$0 lane
  that lands thin-spec gaps only. This is Phase 7's "local-model lane" learning its
  actual ceiling — plan for a two-tier fleet, not a free-tier-only one.

### 5. Portability + currency are their own friction
- `state.db` is gitignored; the registry travels as `.chump/state.sql` and rebuilds
  via `chump restore --from-sql` — but **restore probes an LLM at startup** and errors
  if none is reachable (durable fix still pending; workaround: `scp` a known-good
  `state.db`).
- **Stale binaries silently break coordination** (the async_nats fix needs a rebuild).
  This is why RESILIENT-200 (systemd `--user` timer that keeps each node current with
  `origin/main`, 30 min) and the Mac-side auto-deploy (RESILIENT-198/199) matter — a
  node that drifts stale is a node that quietly stops coordinating.

### 6. Fail-closed autonomy is the governance spine
- `~/.chump/AUTONOMY_LEVEL` (0 or absent = stop, ≥1 = go) gates `chump claim` and the
  mission loop. A node does nothing until the operator opts in.
- Proven 2026-07-28: all three nodes set to 0, `claim` verified refusing — the fleet
  paused without an outage. `fleet-mode` (grind/travel = 2 workers, off = 0) is the
  second dial.

## Current state (2026-07-28)
- **Two NATS-coordinated nodes live** over Tailscale: Helsinki (broker + chump-local,
  x86_64 4-core) and closetjunky (BEAST mission loop, x86_64 4-core). Both currently
  **paused** (AUTONOMY_LEVEL=0) by operator decision; PR-merge plumbing stays on.
- **Phase 0 (MISSION-065) is marked done, but the tail is open:** RESILIENT-185
  (provisioner actually *installs*, in_review), MISSION-068 (Hetzner config),
  MISSION-073 (systemd signal handling), restore-needs-LLM, the both-active guard.
- **Phase 1 (MISSION-066, prove hands-off on BEAST) is open** — closetjunky's mission
  loop is the vehicle and it's built; it just needs to be un-paused and verified
  zero-touch for a bounded window.

## The remaining Phase-0 tail (what "substrate solid" actually requires)
1. RESILIENT-185 — provisioner installs the Linux service, not just preps (in_review).
2. MISSION-073 — systemd signal handling (daemon parity with launchd).
3. `chump restore --from-sql` should not need an LLM (portability blocker).
4. A real cross-machine "both-active" guard (leader election / canonical-node flag),
   so coordination is a mechanism, not a discipline.
5. The RESILIENT-169-style wake/reboot/network-partition tests, run on the *remote*
   host (OFF_LAPTOP_SUBSTRATE §7), not just the laptop.

Close that tail and Phase 1's hands-off proof is mostly a matter of flipping
AUTONOMY_LEVEL back on and watching the scoreboard — the machinery already exists.
