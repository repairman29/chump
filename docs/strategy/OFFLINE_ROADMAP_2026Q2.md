---
doc_tag: strategy-roadmap
audience: operator, fleet, external collaborators
purpose: Single source of truth for the offline-first / air-gapped-capable mission. Consolidates existing offline-first design docs and the 10+ tracking gaps into one phased plan, with a clear boundary between public chump and internal sibling repo (robotics mission layer).
status: v1 (2026-05-29) — proposed; replaces ad-hoc planning across 4 docs + 10 gaps
owners: operator (Jeff), curator-opus-shepherd (drives), external-collab curator (Marcus arc tie-in)
last_audited: 2026-05-29
---

# Offline-First Roadmap (2026 Q2-Q3)

> **TL;DR.** Chump's strategic mission includes Pi-mesh / air-gapped operation (existing memory + `docs/design/OFFLINE_FIRST.md`). The internal repo already has the load-bearing primitives (durable mission intent, autonomous decision-making, mesh transport including LoRa) — they were built for robotics. The public-side work is **(a)** lifting the trait + serde interfaces so public users get a working single-node default, **(b)** building the GitHub-decoupled infrastructure (local CI gate, local merge queue, sync daemon, mode knob), and **(c)** wiring internal sibling repo in as the reference implementation behind those interfaces. Today's sccache R2 incident (40 PRs wedged 90+ min on a remote service hiccup) is the evidence-driven proof that this isn't aspirational — it's overdue.

## 0. Scope boundary — what's IN public chump vs internal sibling repo

This is the most important section. Skip it and you'll either build the wrong thing or duplicate internal-only work.

| Layer | Public chump (this repo) | internal sibling repo (private) |
|---|---|---|
| **Infrastructure-level offline resilience** | ✅ owned here | n/a |
| Local CI gate (`run-local-ci.sh`) | INFRA-2251 P0 | n/a |
| Local merge queue | INFRA-2252 / INFRA-1323 | n/a |
| Network sync daemon | INFRA-1322 | n/a |
| `CHUMP_GITHUB_MODE=offline` knob + auto-detect | INFRA-1325 | n/a |
| Mutation routing via NATS | INFRA-1319 | n/a |
| **Mission/intent trait surfaces** | ✅ trait + serde (this doc) | reference implementation |
| `Mission` / `PersistentMission` shapes | INFRA-2247 | unchanged |
| `MeshTransport` trait + `Channel` | INFRA-2248 + INFRA-1118 (already shipped slice 1/4 via INFRA-1758) | unchanged |
| `BandwidthBudget` / `MessageQueue` | INFRA-1804 (already filed) | unchanged |
| `MissionReplanner` trait + default `Abort` impl | bundled under INFRA-2247 | full strategy logic |
| **Mission-layer reference implementation** | not owned here | ✅ owned in the internal sibling |
| Robot-grade behavior tree runtime | out of scope (could lift later if curators want BT-style loops) | unchanged |
| Multi-robot consensus algorithms | out of scope | unchanged |
| LoRa transport (mesh-lora crate) | out of scope (public consumers slot in NATS or in-process) | unchanged |
| Hardware abstraction (`hal/`, `chassis-*/`) | out of scope | unchanged |
| Threat-classification mission replanner | out of scope | unchanged |

The interface design lives at [`docs/design/MISSION_LAYER_INTERFACE.md`](../design/MISSION_LAYER_INTERFACE.md).

## 1. Why offline-first is load-bearing (not aspirational)

From the operator's persistent memory:

> "Chump enables offline solo devs on local LLMs; bespoke coordination layer is load-bearing strategy, not tech debt; invert 'use GitHub Issues' advice."

From `docs/design/OFFLINE_FIRST.md`:

> "If GitHub disappeared tomorrow, could Chump still do useful work? Today: **no**. Bot-merge.sh hard-crashes on `git push` failures, workers stall waiting for GitHub Actions CI that never resolves, gap ships fail."

Today's incident proved this is not hypothetical. The sccache R2 secret pair mismatched (one half rotated, other 2 days stale), and every Rust CI job failed for 90+ minutes. Doc-only PRs limped through; Rust PRs queued. The fleet had no graceful degradation path — auto-merge couldn't fire, no one could ship, the operator was paged into a manual rotation.

If a remote service hiccup wedges the fleet for 90 min today, an actual GitHub outage wedges it for hours. An air-gapped deployment (the Pi-mesh / robotics target) doesn't work at all.

## 2. Two target scenarios (from OFFLINE_FIRST.md)

### Scenario A — Pi Mesh (local network, no internet)
4 Raspberry Pis, no internet, Llama running on each, NATS coord on the mesh. Pi 1 is the local git origin + the gap registry primary. When internet returns, Pi 1 optionally syncs to GitHub. Demonstrates: solo dev with local LLMs operating completely offline, fleet curator loop continuing without external dependency.

### Scenario B — Airplane Mode (completely isolated, single MacBook)
One MacBook running all workers, NATS on loopback, git local, Ollama for LLM. Commits land on local branches; `git push origin` deferred until WiFi returns. Demonstrates: minimum viable offline operation, regression-test target for every offline-first change.

Architecture is identical for both — they're points on a spectrum of network availability.

## 3. Phased plan

### Phase 1 — Local CI Gate (INFRA-2251, P0 after today)
- **Goal:** `bash scripts/ci/run-local-ci.sh && echo "ready"` returns 0 with no network calls.
- **Why P0:** today's incident proves a remote CI dependency is a single point of failure for the whole fleet.
- **What ships:** unified script that runs `cargo fmt --check`, `cargo clippy`, `cargo test --workspace`, plus all `scripts/ci/test-*.sh` that don't touch GitHub. Exclusion list for GitHub-API-dependent checks (those go in `scripts/ci/run-remote-ci.sh`).
- **Acceptance:** runs on airplane Mac with WiFi off, exit 0 = "mergeable to local main."
- **Pairs with:** existing self-hosted runner work (INFRA-1534), the `scripts/preflight.rs` `chump preflight` tool.

### Phase 2 — Local Mission Layer Interface (INFRA-2247 + INFRA-2248)
- **Goal:** public chump-coord exposes `Mission`, `MeshTransport`, `BandwidthBudget`, etc. as trait + serde definitions. Default `LocalProcessTransport` + `FileBackedMissionStore` impls.
- **Why now:** these are derived from the internal sibling's mission layer (which already exists and works); the cost to lift the interfaces is small, and they unblock Phase 3 + Phase 4.
- **What ships:** `crates/chump-coord/src/mission/` module, `crates/chump-coord/src/mesh/` module, integration tests with the local-process default. INFRA-1804's `BandwidthBudget`/`MessageQueue` lift folds in here.
- **Pairs with:** INFRA-1758 (already shipped — `subscribe_events` stub, slice 1/4 of A2A Layer 1a) — `MeshTransport` is the natural extension.

### Phase 3 — Local Merge Queue (INFRA-2252 / INFRA-1323)
- **Goal:** when `CHUMP_GITHUB_MODE=offline`, gap shipping merges to local main via a NATS-KV-serialized queue instead of `gh pr merge --auto`. Replays to GitHub when sync daemon flips online.
- **What ships:** `scripts/coord/local-merge-queue.sh` + (eventually) Rust implementation that uses the Phase 2 mission layer to track pending merges as `PersistentMission`s.
- **Pairs with:** `bot-merge.sh` grows a `CHUMP_GITHUB_MODE` branch that routes to local-merge-queue when set.

### Phase 4 — Network Sync Daemon (INFRA-1322)
- **Goal:** background process bidirectionally syncs local main ↔ GitHub when network is available. Detects reconnect, replays buffered merges, handles conflicts via the fleet-state event log (which is NATS-replayable).
- **What ships:** `scripts/coord/network-sync-daemon.sh` + launchd plist. Emits `kind=network_sync_*` ambient events for observability.
- **Pairs with:** existing webhook cache (INFRA-1081), `chump_gh` criticality (INFRA-1080) — both already shipped.

### Phase 5 — GitHub Mode Knob + Auto-Detect (INFRA-1325)
- **Goal:** `CHUMP_GITHUB_MODE` is operator-controllable AND auto-detected by reachability probe. `chump fleet doctor` reports current mode. Existing scripts gracefully degrade without operator intervention.
- **What ships:** mode knob env var + auto-detect helper + audit in every `chump_gh` call site (which already exists per INFRA-1080).

### Phase 6 — Mutation Routing via NATS (INFRA-1319, longer-term)
- **Goal:** worker nodes never call GitHub directly; all mutations go via NATS request/reply to a Liaison node that batches GitHub calls.
- **Why later:** requires Phases 2-5 to be stable; not a near-term need on the airplane scenario but the right end-state for the Pi mesh.

## 4. Cross-references — existing public-side gaps with classification

The following gaps were already filed across multiple sessions. Each gets a one-line classification noting public vs internal boundary:

| Gap | Title | Phase | Classification |
|---|---|---|---|
| INFRA-1118 | A2A Layer 1a — NATS-primary delivery, file-fallback secondary | 2 | public-side; sliced into 4 sub-tasks, slice 1 (INFRA-1758) shipped today |
| INFRA-1319 | mutation routing via NATS | 6 | public-side; longer-term |
| INFRA-2251 | local CI gate (`run-local-ci.sh`) | 1 | public-side; **promote to P0 after today** |
| INFRA-2252 | local merge queue script (was referenced as INFRA-1321 in OFFLINE_FIRST.md but never filed under that ID) | 3 | public-side |
| INFRA-1322 | network sync daemon | 4 | public-side |
| INFRA-1323 | local merge queue NATS-KV serialized git merge | 3 | public-side (Rust impl of 1321) |
| INFRA-1325 | auto-detect `CHUMP_GITHUB_MODE=offline` | 5 | public-side |
| INFRA-1804 | `BandwidthBudget` + `MessageQueue` lift from internal sibling repo | 2 | **public-side, derived from internal**; pairs with INFRA-2247/2248 |
| INFRA-1758 | `chump-coord subscribe_events()` stub + `EventFilter` enum (Layer 1a slice 1/4) | 2 | public-side; shipped 2026-05-29 |
| INFRA-2247 (new this PR) | lift `Mission` / `PersistentMission` / `ObjectiveState` type shapes | 2 | **public-side trait + serde, derived from internal** |
| INFRA-2248 (new this PR) | lift `MeshTransport` trait + `LocalProcessTransport` default | 2 | **public-side trait + serde, derived from internal**; extends INFRA-1758 |

Each gap's own YAML gets a one-line note linking back here.

## 5. What this roadmap does NOT cover

- **Behavior-tree runtime for curators.** Internal has `crates/behavior/` (composites, decorators, leaves). Whether curator loops would benefit from BT-style execution vs the current `/loop` cron pattern is an open question. File as a follow-up if the experiment seems worth it; don't bake into offline-first.
- **Distributed consensus for multi-machine coord.** NATS KV CAS already covers atomic gap claims (`try_claim_gap`, FLEET-034). Lift the internal sibling's full consensus only when a public use case demands it.
- **Local LLM model training.** Out of scope — see model-strategy memory note for the open-source-vs-fine-tuning thinking.
- **Robot hardware integration.** Stays internal entirely.

## 6. Success metrics (what "done" looks like)

| Metric | Today | After Phase 1 | After Phase 2-3 | After Phase 4-5 |
|---|---|---|---|---|
| Bash `scripts/ci/run-local-ci.sh` and ship a Rust PR with WiFi off | impossible | ✅ | ✅ | ✅ |
| `chump claim INFRA-X` works with `gh` unreachable | partial (lease + state.db local) | ✅ | ✅ | ✅ |
| `chump gap ship X` lands a merge on local main with GitHub down | impossible | impossible | ✅ | ✅ |
| Fleet curator loop continues 24h with no internet | impossible | partial (state mutations work; PR ops fail) | ✅ (uses local merge queue) | ✅ |
| Auto-sync local→GitHub when network returns | manual | manual | manual | ✅ |
| Pi mesh demo (4 Pis, no internet, ships work) | impossible | doesn't yet | partial | ✅ |

## 7. Risks + mitigations

- **Mission-layer interface bleeds internal-only IP.** Mitigation: lift only trait shapes + serde fields; no IP-bearing algorithms (replanners, consensus, threat-classification logic). Reviewable in `docs/design/MISSION_LAYER_INTERFACE.md`.
- **Two diverging code paths (online vs offline) double the bug surface.** Mitigation: `CHUMP_GITHUB_MODE` switches a single code path; the offline path is the canonical one and online mode is "offline + extra remote sync." That's the OFFLINE_FIRST.md design and we hold to it.
- **Public users without internal get a less-capable default.** Mitigation: the public default is good enough for solo dev on a single machine (airplane mode). Pi-mesh / multi-machine deployments need the internal sibling's transport implementations (which is fine — they're the target customer for the robotics work anyway).
- **Roadmap rots if Phase 1 doesn't ship soon.** Mitigation: INFRA-2251 promoted to P0 in this PR; today's incident is the evidence. If Phase 1 hasn't shipped by 2026-06-15, re-audit.

## 8. References

- `docs/design/OFFLINE_FIRST.md` — architecture (Pi Mesh + Airplane Mode scenarios, the 4 "missing pieces")
- `docs/design/MISSION_LAYER_INTERFACE.md` — public interface design (companion to this doc)
- `docs/OFFLINE_FIRST_WORKFLOW.md` — operator workflow under offline mode
- `docs/QUICKSTART_OFFLINE.md` — onboarding
- `docs/strategy/OFFLINE_COMPLIANCE_RUBRIC.md` — gap-filing rubric + INFRA-1418 linter
- `docs/design/A2A_ROADMAP.md` (META-061) — A2A comms roadmap; this offline-first roadmap is the substrate
- `docs/strategy/FLEET_VISION_2026Q2.md` — broader fleet vision
- Internal sibling repo robotics mission roadmap (reference implementation source-of-truth, private)
- 2026-05-29 incident retrospective (this PR's commit message) — sccache R2 wedge as evidence
