# Node Fabric — heterogeneous hardware → self-optimizing fleet (RESILIENT-291)

**Status:** design + component #1 shipped (this PR). Components #2–#5 are the roadmap below.

## The thesis (operator, 2026-08-10)

> "The fleet should always be making choices about what lives where to optimize —
> that's how real businesses work. We're all about mad-max cyberpunk rescuing and
> maxxing on any hardware we can find."

Any rescued box — an old GPU, a spare VM, a laptop — joins the fleet, **declares
what it can do**, gets assigned the jobs it fits, and the fleet **continuously
decides what workload lives where**. Bringing up a node must be a product, not a
runbook that "revs devs." Nodes may have different jobs; ATC runs on all of them.

## Why now — two incidents that prove the gap (2026-08-10)

Both happened in one ATC session, both because **there is no registry of what runs
where and what depends on it**:

1. Stopped **closetjunky's ollama** "to reclaim disk" — it was the GPU node already
   serving almanac embeddings (set up by another session). Proposed the embeddings
   as a *new* idea, blind to what was running.
2. Stopped **helsinki's ollama** "to reclaim disk" — it was almanac's query-embed
   endpoint (`ALMANAC_EMBED_URL`). almanac's semantic search silently degraded to
   keyword-only until the next session noticed.

A node registry with a `services_running` field would have stopped both cold:
"helsinki:ollama = almanac embed endpoint — load-bearing, do not kill."

## What already exists (mine-before-build receipts)

- **`src/fleet_capability.rs`** — `AgentCapability` (`vram_gb`, `model_family`,
  `supported_task_classes`, `reliability_score`) + **`fit_score()`** + `CLAIM_THRESHOLD`.
  The **placement kernel is already built** — it answers "should this node claim this
  work?" (FLEET-009, `docs/architecture/FLEET_CAPABILITY_DESIGN.md`).
- **`src/fleet_self_rescue_conductor.rs`** — "durable replacement for the human-run
  conductor." **ATC-as-a-daemon, already seeded.**
- **`scripts/setup/provision-chumpd-host.sh`** — node provisioning seed.
- **`scripts/ops/node-heartbeat-check.sh`** (RESILIENT-290) — per-node ATC self-monitor seed.

The capability *model* exists. What's missing is auto-declaration, a role+dependency
registry, and the placement loop that runs continuously.

## The five components

| # | Component | What it adds | Status |
|---|-----------|--------------|--------|
| 1 | **Node self-describe** (`scripts/dispatch/node-describe.sh`) | introspect GPU/VRAM/cores/disk/always-on → declare capability + `services_running` + `roles_fit`. Populates `docs/fleet/nodes/*.json`. | ✅ this PR |
| 2 | **Node registry + roles + service-deps** (`scripts/dispatch/node-role-assign.sh`) | placement kernel: reads each node's declared capability + `roles_fit` and ASSIGNS + persists the policy `role_assigned` (brain/muscle/gpu-embed/operator) into `docs/fleet/nodes/*.json`; `--check` mode surfaces drift for organ-reconcile/the governor. | ✅ RESILIENT-1031 |
| 3 | **`chump node up`** | one command: introspect → declare → assign role → install *only that role's* daemons → self-test → join. The dev-facing bring-up product; extends `provision-chumpd-host.sh`. | roadmap |
| 4 | **Per-node ATC** | `fleet_self_rescue_conductor` + heartbeat, **role-aware**, on every node — each node keeps its own role's daemons healthy. | roadmap (extends existing) |
| 5 | **Placement engine** | read registry + live load + cost → decide/rebalance what lives where (embeddings→GPU, builds→high-disk, *never build on CJ*). `fit_score` is the kernel; this is the loop around it. | ✅ first slice: `scripts/ops/node-capacity-plan.sh` (RESILIENT-291 place-half) — see below |

## Findings from component #1 (first run, all three nodes)

- **`roles_fit` ≠ `role_assigned`.** closetjunky reports `build-worker` as a *fit*
  (46G free, 4 cores) — but it must **never** build (that disk is Jeff's data; builds
  wedged it to 198M free this session). Raw-hardware fit is necessary but not
  sufficient; the registry needs an **intended role (policy)** that can veto a fit.
  This is the #2 refinement, caught on run one.
- The `services_running` guardrail is real and populated: the registry now shows
  `closetjunky: ollama:embed` and `helsinki: (no ollama)` — the exact fact that was
  invisible when both ollamas got killed.

## Sequence

`describe (✅) → registry+role_assigned (✅ #2) → chump node up (#3) → per-node ATC (#4) → placement engine (#5)`

Each is a shippable slice; the placement engine (#5) is the payoff — the fleet
"always making choices about what lives where," with `fit_score` as its scoring
kernel and the registry as its world-model.

## The PLACE half — capacity planner (RESILIENT-291, 2026-09-07)

Component #1 (`node-describe.sh`) + `capability.rs` DECLARE what a node IS. Nothing
PLACED work against that declaration: worker counts were set by `AUTONOMY_LEVEL`
(`run-fleet.sh` ~L245, an autonomy-only ceiling that is blind to cores) plus
hand-written per-node scripts (`/home/jeff/cj-worker*.sh`). So no organ right-sized
a box to its real cores/mem/GPU/load — closetjunky (4 cores) ran the orchestration
farm (16 organs) + a CPU-bound ollama embed pair + build workers and sat pinned at
load ~5 (142%/core), its orchestrator oscillating 1↔2 workers.

**`scripts/ops/node-capacity-plan.sh`** is the first slice of the placement engine —
the *brain*; `node-orchestrator.sh` (SENSE/HEAL/SCALE/ENFORCE) is the *loop* around
it. Per node it reads the DECLARED manifest (`docs/fleet/nodes/<host>.json`, falling
back to live introspection) + live signals (nproc, load, RAM, disk, `nvidia-smi`) and
computes a **placement budget**:

- **worker_budget** (the capacity-derived ceiling):
  `floor((cores − orch_reserve − embed_reserve) × HEADROOM_PCT/100)`, clamped
  `1..cores−1`, pinned to `1` under disk pressure (`root% ≥ 90`).
  `orch_reserve=1` when the box hosts ≥3 heavy orchestration organs (fleet-server,
  discord-gateway, pr-lander, node-orchestrator, postgrest); `embed_reserve=1` when a
  CPU-bound ollama/llama-server competes for build cores. This subtraction of fixed
  overhead is *why* an orchestration+embed host needs fewer than `cores−1` workers.
- **GPU disposition** — `assigned` (resident MiB in use) | `reserved-idle` (+ a
  *computed* reason from a live reading) | `none`. Never silently idle.
- **rebalance posture** — `oversubscribed` (load saturated even at/under budget →
  shed / don't add) vs `capacity_sink` (load headroom, at/under budget, disk OK →
  can absorb more routed work). Makes rebalance visible in *both* directions.

**Enforcement:** `node-orchestrator.sh`'s `effective_max()` now consumes the plan's
`worker_budget` (precedence: plan > `CHUMP_ORCH_WORKER_MAX` env > `cores−1`), and the
loop re-runs the planner every `PLAN_REFRESH_EVERY` ticks. `enforce_cap()`/`scale()`
already hold the worker count to `effective_max()` every tick, so the capacity-derived
ceiling is enforced with no new enforcement path. This reconciles the ad-hoc
`cj-worker*.sh` units: the *scripts* stay as `ExecStart`, but *how many run* is now
planner-derived, not a human starting `worker2`/`worker3` by hand.

**Dogfood, live (2026-09-07, `--print` on real nodes):**

| node | cores | declared load | worker_budget | posture | GPU |
|---|---|---|---|---|---|
| closetjunky | 4 | 142%/core (saturated) | **1** (orch+embed reserve) | `oversubscribed` | `reserved-idle` — GTX 970 CC 5.2, ollama's bundled cuda_v12/v13 dropped Maxwell → embeds CPU-bound |
| cuphead | 2 | 11%/core | **1** (disk-brake) | not a sink (root 96%) | none |
| mugman | 2 | 20%/core | **1** | **`capacity_sink`** (can take more) | none |

The place-half surfaces the exact rebalance the fleet was blind to: CJ is over budget
(hold at 1, stop the 1↔2 flap), mugman is an idle sink, and cuphead — though its CPU
is idle — is correctly *not* offered work because its boot disk is at 96%. The GTX 970
is documented-reserved with a factual hardware reason, not left silently dark.

**Known factual limitation:** the GTX 970 (Maxwell, compute capability 5.2) cannot be
reclaimed for GPU embeds without a legacy-CUDA ollama/llama build — modern ollama's
bundled `cuda_v12`/`cuda_v13` runtimes drop pre-Pascal cards (ollama journal:
`llama-server GPU discovery watchdog timed out` → `inference compute id=cpu`). Until
then CJ's embeds are CPU-bound and correctly count toward `embed_reserve`.
