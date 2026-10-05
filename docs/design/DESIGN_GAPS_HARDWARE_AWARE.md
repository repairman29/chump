# Design Gaps — hardware-aware self-organization

**Status:** scoped (2026-09-11), gap tree filed to the fleet. Design foundation,
not a rewrite. Companion to [`DESIGN_GAPS_SELF_RUNNING.md`](DESIGN_GAPS_SELF_RUNNING.md)
and the **wiring track** for [`NODE_FABRIC.md`](NODE_FABRIC.md).

These five architectural gaps keep ChumpOS from **organizing itself around the
hardware it actually runs on**. Each is grounded in a live receipt from tonight's
operator session — not a vibe. The order is diagnostic; the priority tracks are at
the bottom.

The through-line: **the fleet is role-DECLARED and host-PATCHED, not
hardware-DISCOVERED and self-organizing.** It hardcodes the shape of one machine
(helsinki) and breaks whenever the hardware changes. Tonight's entire class of
failures — `/home/ubuntu/Projects/chump` helsinki paths killing organs at CHDIR,
roster decay, the hardcoded "no cargo build on a 2-core box" rule, the fleet-server
binary that couldn't rebuild on cuphead — are all symptoms of the same root: a
system authored for one box that assumes its cores, its paths, and its role layout,
and has no live model of the boxes it is actually running on.

---

## The honest starting line — what already exists (mine-before-build)

This is **not greenfield.** [`NODE_FABRIC.md`](NODE_FABRIC.md) (RESILIENT-291,
2026-08-10) already scoped exactly this vision — "heterogeneous hardware →
self-optimizing fleet" — and **shipped the DECLARE half.** The gap is not that the
fleet can't see hardware; it is that **discovery was never wired into the one command
that brings a node up, nor into how organs get placed.** Every component below
*extends* a shipped piece; none rebuilds one.

Shipped and load-bearing today:

- **`scripts/dispatch/node-describe.sh`** (Node Fabric #1) — introspects THIS node
  (cores, RAM, disk, GPU/VRAM, always-on, `services_running`, `roles_fit`) and emits
  a JSON profile. Portable across Linux/macOS/termux. **The probe exists.**
- **`docs/fleet/nodes/*.json`** — the node registry (cuphead/mugman/closetjunky/pixel),
  with `hardware`, `capability.supported_task_classes`, `roles_fit`, `role_pin`,
  `role_assigned`. **The registry exists** — but it is git-committed static JSON,
  populated by a *manual* `node-describe.sh` run, with a **hand-set** `role_pin`
  ("topology decision 2026-09-07"). Not live, not periodic, not in `state.db`.
- **`scripts/dispatch/node-role-assign.sh`** (Node Fabric #2, RESILIENT-1031) — the
  placement kernel that reads `roles_fit` + capability and ASSIGNS one of
  brain/muscle/gpu-embed/operator into `role_assigned`, with a policy that can veto a
  raw fit (CJ *fits* build-worker but must never build). **Role derivation exists** —
  but as a batch script over the static JSON, not on the bring-up path.
- **`scripts/ops/node-capacity-plan.sh`** + **`node-orchestrator.sh`**
  (RESILIENT-291 PLACE half, RESILIENT-318) — a live SENSE→DECIDE→ACT loop that
  right-sizes *worker count* and *cargo `-j`* from live cores/RAM/disk/load/GPU.
  **Hardware IS probed live** — but only for local worker/build sizing, never for
  fleet role or organ placement.
- **`src/fleet_capability.rs`** (FLEET-009) — `AgentCapability` / `TaskRequirement` /
  `fit_score()`: a transport-agnostic capability-vs-requirement matcher. **The
  matching kernel exists** — for agent↔task fit, not node↔organ fit.
- **`crates/chump-fleet-server`** `GET /api/fleet/nodes` (RESILIENT-1055) — serves
  cross-node *organ health* from sentinel heartbeats. A serving surface exists, but it
  reports liveness, not a hardware topology.
- **`scripts/ops/organ-manifest.txt`** — the organ placement mechanism actually used
  by bring-up. Static `role=` tags (brain/muscle/data/janitor/trust) and a
  `requires=SPEC` precondition field supporting `bin:`/`env:`/`dep:`/`file:` specs.
  **A requirements grammar exists** — with no hardware spec kinds, and a header that
  still reads "desired systemd state on the PRIMARY node (helsinki)."

**The disconnect, verified:** `grep` of `scripts/setup/chump-node-install.sh` for
`node-describe` / `node-role-assign` / `node-capacity` / `role_assigned` / `roles_fit`
/ `fleet/nodes` returns **nothing.** The one command that turns a bare box into a node
takes `--role brain|muscle|all` as a **manual arg (default `brain`)** and never
consults the probe, the registry, the role-assigner, or the capacity plan that all
already exist. NODE_FABRIC component #3 (`chump node up` — the command that wires
describe→assign→install) is still roadmap. **That missing wire is this whole track.**

---

## The five gaps

### Gap 1 — Role is hand-declared, not hardware-derived

`chump-node-install.sh --role brain|muscle|all` takes the role as a manual argument
and defaults to `brain`. Nothing on the bring-up path probes cores/RAM/GPU to *decide*
the role, even though `node-describe.sh` + `node-role-assign.sh` already compute it.

**Receipt:** a fresh box is brought up by a human choosing `--role`. The shipped
placement kernel (`node-role-assign.sh`) that would pick brain/muscle/gpu-embed/operator
from the box's real hardware is **dark on the install path** — it runs as a batch job
over static JSON, disconnected from the command that installs organs. So the default
`brain` lands on any box, right or wrong.

### Gap 2 — No live node capability registry

The registry (`docs/fleet/nodes/*.json`) is git-committed static JSON, written by a
*manual* `node-describe.sh` run, with a **hand-set** `role_pin`. There is no periodic
re-probe, no `state.db` topology table, and no single served source of truth for
"what hardware is in the fleet right now."

**Receipt:** `cuphead.json` carries `"role_pin_reason": "topology decision 2026-09-07"`
— a human sentence, not a reading. When hardware changes (helsinki decommissioned, CJ
relocated, mugman joined), the registry only tracks it if someone re-runs the probe and
commits the JSON. `GET /api/fleet/nodes` serves organ *liveness*, not this topology, so
the machine has no live mirror of its own substrate. (This is the substrate half of
`DESIGN_GAPS_SELF_RUNNING.md` Gap 5 — RESILIENT-1113, no faithful self-model.)

### Gap 3 — Organs are placed by static role tags, not capability requirements

Organ placement runs off `organ-manifest.txt`'s static `role=` tags, whose header
still names "the PRIMARY node (helsinki)." An organ says `role=brain`; it does not say
*what it needs* (a GPU, N cores, root, a RAM floor). The `requires=` field understands
`bin:`/`env:`/`dep:`/`file:` but **no hardware spec kinds.**

**Receipt:** the "never build cargo on a 2-core box" rule — a real capability
constraint — lives as **prose plus a hardcoded install decision** in
`install-fleet-server-node.sh` ("On a 2-core Oracle node a local rebuild is
forbidden"), not as a declared requirement the placement kernel enforces. The rule is
true fleet-wide but is re-encoded by hand at each site instead of derived once from
`cores >= N`.

### Gap 4 — No self-distribution: work and organs don't re-home

Worker *count* is capacity-derived per node (the RESILIENT-291 PLACE half), but that is
the only self-distribution that exists. Nothing routes an *organ* to a capable peer
when its host dies or departs, and nothing pulls builds toward a joining builder.

**Receipt:** the entire `NODE_FABRIC.md` origin story — killing closetjunky's and
helsinki's ollama blind because "there is no registry of what runs where and what
depends on it," and this session's fleet-server that went stale on cuphead because a
2-core rebuild is forbidden and no peer builder was routed the work. When a node's
capability changes, its workload does not move; a human moves it.

### Gap 5 — The manifest is helsinki-shaped

The roster is authored for one machine. `organ-manifest.txt`'s own header reads
"desired systemd state on the PRIMARY node (helsinki)"; helsinki is decommissioned.
Role tags encode a helsinki-era brain/muscle split rather than a node-neutral,
capability-declared roster.

**Receipt:** tonight's CHDIR incidents traced to `/home/ubuntu/Projects/chump` and
`/home/jeff/...` paths baked in from the primary-node era, and roster decay because the
manifest describes a machine that no longer exists. A node-neutral roster would carry
no host's home path and no host's name — only capability requirements and roles.

---

## The track — one umbrella, five components

Each component becomes a sub-gap under the umbrella **"Hardware-aware
self-organization."** Every one *extends* a shipped Node Fabric piece.

### Component 1 — Node capability probe + live registry

Each node probes its hardware (cores, RAM, arch, GPU/VRAM, disk, builder-capable,
network/always-on) on bring-up **and periodically**, and registers into a **live fleet
topology** — a `state.db` table or a fleet-server-served endpoint — not a hand-committed
JSON file.

**Mine-before-build:** `node-describe.sh` already emits the exact profile (extend it to
self-register instead of print-to-stdout); `docs/fleet/nodes/*.json` is the schema to
promote from static-doc to live-row; `GET /api/fleet/nodes` is the serving surface to
extend from organ-liveness to hardware-topology.

### Component 2 — Capability-derived roles

Derive the role from capability — 2-core → worker/muscle floor; real CUDA GPU →
gpu-embed; 8-core builder → builder/muscle; always-on coordinator → brain. Keep
`--role` as an **override**, but **default to derivation** instead of `brain`.

**Mine-before-build:** `node-role-assign.sh` already computes exactly this
(brain/muscle/gpu-embed/operator, with a policy veto over raw fit). The work is wiring
its output into `chump-node-install.sh` (NODE_FABRIC #3, `chump node up`) so the
install path *asks* it rather than reading a manual arg.

### Component 3 — Capability-aware organ placement

Organs declare **requirements** (`needs-gpu`, `no-cargo-build-under-N-cores`,
`root-required`, `min-ram`); placement matches organs to *capable* nodes. This replaces
the static helsinki role-tagged manifest and **folds the no-cargo-on-2-core guard in as
a derived rule** rather than hardcoded prose.

**Mine-before-build:** `organ-manifest.txt`'s `requires=SPEC` grammar already gates
placement on `bin:`/`env:`/`dep:`/`file:` — add hardware spec kinds
(`cores:>=N`, `ram:>=N`, `gpu`, `arch:X`) and have `organ-reconcile.sh` evaluate them
against the Component-1 registry. `src/fleet_capability.rs::fit_score()` is the
matcher kernel to reuse for node↔organ fit.

### Component 4 — Self-distribution + re-organization

Work routes by capacity; a dying or departing node's organs **re-home** to a capable
peer; a joining builder routes builds to itself. The capacity loop already right-sizes
worker count — extend the same SENSE→DECIDE→ACT shape to organ placement across nodes.

**Mine-before-build:** `node-orchestrator.sh` (the loop) + `node-capacity-plan.sh` (the
brain) already do capacity-derived worker sizing on one node; `fleet_self_rescue_conductor.rs`
is the seeded ATC-as-daemon; the Component-1 live registry is the cross-node world-model
the re-home decision reads. This is NODE_FABRIC #4 (per-node role-aware ATC) + #5
(placement engine) made node-death-aware.

### Component 5 — De-helsinki the manifest

The roster becomes **node-neutral and capability-declared**: no "PRIMARY node
(helsinki)" header, no host home paths, no host names — only capability requirements
(Component 3) and roles (Component 2). A fresh box of any shape inherits the right
roster because the roster describes *capabilities*, not *helsinki*.

**Mine-before-build:** `organ-manifest.txt` is the file to rewrite; every
`/home/ubuntu/...` / `/home/jeff/...` / helsinki reference is a placement bug to convert
into a `file:` or hardware requirement. This is the roster half of the
`DESIGN_GAPS_SELF_RUNNING.md` Gap 5 self-model (RESILIENT-1113).

---

## Priority

Build **Component 1 (live registry) first** — it is the world-model every other
component reads; without it, roles are derived from stale JSON, organ requirements have
nothing to match against, and re-homing is blind. Then **Component 2** (wire derivation
into bring-up) and **Component 3** (capability requirements + fold in the 2-core guard),
which together make a fresh box come up correctly. **Components 4 and 5** (re-homing and
de-helsinki-ing) close the loop so the fleet re-organizes on hardware change rather than
on a human noticing.

## Acceptance

- **Fresh bare box, any shape, one command:** it probes itself, registers into the live
  topology, and comes up with the **correct role and organ set for its hardware** —
  **zero hand-declared role, zero helsinki assumptions.** A 2-core box comes up as a
  worker/muscle floor that never attempts a local cargo build; a GPU box comes up
  serving embeds; an 8-core box comes up as a builder; an always-on coordinator comes up
  as brain — all without anyone passing `--role`.
- **A dying node re-homes its work automatically:** when a node departs or loses a
  capability, its organs move to a capable peer and its builds route to a joining
  builder, with no human moving them.

---

## Gap tree filed to the fleet

- **RESILIENT-004 — Hardware-aware self-organization (umbrella)** + 5 sub-gaps:
  - **RESILIENT-005** — Node capability probe + live registry (Component 1)
  - **RESILIENT-006** — Capability-derived node roles (Component 2)
  - **RESILIENT-007** — Capability-aware organ placement (Component 3)
  - **RESILIENT-008** — Self-distribution + re-organization on node change (Component 4)
  - **RESILIENT-009** — De-helsinki the organ manifest (Component 5)

Every gap references this doc (`docs/design/DESIGN_GAPS_HARDWARE_AWARE.md`) and names
the umbrella (each sub-gap `depends_on` RESILIENT-004). This track is the substrate companion to `DESIGN_GAPS_SELF_RUNNING.md`
Gap 5 (RESILIENT-1113, no faithful self-model) — the topology registry is the hardware
half of that mirror — and the wiring track for `NODE_FABRIC.md`, whose DECLARE half
shipped but was never connected to bring-up or organ placement.
