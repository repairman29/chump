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
| 5 | **Placement engine** | read registry + live load + cost → decide/rebalance what lives where (embeddings→GPU, builds→high-disk, *never build on CJ*). `fit_score` is the kernel; this is the loop around it. | roadmap — the new brain |

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
