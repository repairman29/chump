# Fleet Vision: Distributed Agent Orchestration (2026 Q2+)

**Status:** Architecture planning  
**Scope:** Multi-gap initiative spanning 6+ quarters  
**Motivation:** Move from single-machine multi-agent to networked heterogeneous fleet with task decomposition and capability-aware work allocation

---

## The Vision

**Current state:** Chump runs multiple agents on a single machine, coordinated via filesystem leases + ambient stream.

**End state:** Agents run across a networked fleet (Tailscale VPN, local models on edge devices, potentially federated inference). Each agent can:
- Declare capabilities (model family, inference speed, memory, special skills)
- Assess tasks against its capabilities
- Decompose work into subtasks and post them to a shared board
- Claim work it's "the right fit" for
- Seek help when blocked (missing capability, resource exhausted, unknown task class)
- Eventually: coordinate inference across devices for larger models

---

## Architecture Layers

### Layer 1: Distributed Coordination (Q2–Q3)

**Problem:** Filesystem-based leases + ambient stream don't work across machines.

**Solution:**
- Replace filesystem coordination with NATS-backed distributed state
- Distributed TTL leases (claim a gap on any machine in the fleet)
- Ambient stream as NATS topics (every agent publishes events; all agents subscribe)
- Fallback to git for observability (commits/PRs are the distributed audit trail)

**Gaps:**
- **FLEET-006: Distributed ambient stream** — Bridge filesystem ambient.jsonl to NATS topics
- **FLEET-007: Distributed leases with TTL** — Replace `.chump-locks/*.json` with NATS-backed exclusive claims

### Layer 2: Work Decomposition & Claiming (Q3–Q4)

**Problem:** Agents don't know how to break work into subtasks, and can't post partial work for others.

**Solution:**
- Shared "work board" (NATS queue or git-backed)
- Agents post subtasks with metadata (required model, estimated time, difficulty)
- Gap decomposition heuristics (learn which task classes split well)
- Task-fitness scoring (should I claim this?)

**Gaps:**
- **FLEET-008: Work board / task queue** — Mechanism for posting subtasks, metadata schema
- **FLEET-009: Capability declaration & matching** — Agent publishes `{model, vram, inference_speed, supported_task_classes}`. Task declares requirements. Scoring function for fit.
- **FLEET-010: Help-seeking protocol** — Agent hits a blocker → posts help request → another agent claims it

### Layer 3: Intelligent Decomposition (Q4+)

**Problem:** Agents today ship entire PRs as monoliths. They don't learn when to break work.

**Solution:**
- Heuristics for recognizing decomposable work (multi-file refactors, sequential fixes, federated gap batches)
- Learning layer: track which decompositions succeeded
- Help-seeking triggers (timeout, memory pressure, capability gap)

**Gaps:**
- **FLEET-011: Decomposition heuristics & learning** — When should an agent break a task? Learn from outcomes.
- **FLEET-012: Blocker detection & help requests** — Agent recognizes it's stuck; posts structured help request; waits for peer to claim

### Layer 4: Secure Transport & Tailscale (Q4)

**Problem:** Agents across physical machines need secure networking.

**Solution:**
- Tailscale VPN for zero-config, encrypted inter-device communication
- Agent discovery via Tailscale IPs
- NATS runs on Tailscale network (not internet-exposed)

**Gap:**
- **FLEET-013: Tailscale integration & agent discovery** — Agents find each other via Tailscale; NATS endpoints auto-populated

### Layer 5: Distributed Inference (2027+)

**Problem:** Some models don't fit on a single edge device; inference latency becomes a bottleneck.

**Solution:**
- Model sharding across devices (e.g., split 14B into 7B + 7B across two Pis)
- Pipeline parallelism (device A encodes, device B decodes, etc.)
- Cooperative inference (agent A does embedding, asks device B for retrieval, etc.)

**Gaps:**
- **FLEET-014: Distributed model inference skeleton** — Framework for splitting inference across devices
- **FLEET-015: Load balancing & task placement** — Given fleet state + task requirements, choose optimal device

---

## Critical Path & Dependencies

```
FLEET-006 (distributed ambient)
FLEET-007 (distributed leases) ──┐
                                  ├─→ FLEET-008 (work board)
                                  │
                                  └─→ FLEET-009 (capability matching)
                                        │
                                        └─→ FLEET-010 (help-seeking)
                                              │
                                              └─→ FLEET-011 (decomposition learning)
                                                    │
                                                    └─→ FLEET-012 (blocker detection)
                                                          │
                                                          └─→ FLEET-013 (Tailscale integration)
                                                                │
                                                                └─→ FLEET-014/015 (distributed inference)
```

**Critical path to first distributed demo (2026 Q4):**
1. FLEET-006 + FLEET-007 (distributed coordination)
2. FLEET-009 (capability matching — agent can assess task fit)
3. FLEET-008 (work board — subtasks can be posted)

**Achievable in one sprint:** FLEET-006 (1–2 weeks, depends on NATS stability + API design)

---

## Effort & Timeline

| Gap | Domain | Effort | Timeline | Blocker |
|-----|--------|--------|----------|---------|
| FLEET-006 | Infra | L | 2–3 weeks | NATS operational; API design |
| FLEET-007 | Infra | M | 1–2 weeks | FLEET-006 + TTL semantics |
| FLEET-008 | Core | M | 1–2 weeks | FLEET-006/007 + queue semantics |
| FLEET-009 | Core | M | 2 weeks | Task metadata schema, scoring function |
| FLEET-010 | Core | M | 1–2 weeks | FLEET-009 + help-seeking RPC |
| FLEET-011 | ML | L | 4+ weeks | Heuristics + learning framework |
| FLEET-012 | Core | M | 2 weeks | FLEET-010 + timeout/resource monitoring |
| FLEET-013 | Infra | S | 1 week | Tailscale SDK + service discovery |
| FLEET-014 | ML/Infra | XL | 2+ months | Model sharding, pipeline APIs |
| FLEET-015 | Core | L | 4+ weeks | Placement algorithms, cost models |

---

## Capability Declaration Schema (Sketch)

```rust
#[derive(Serialize, Deserialize)]
pub struct AgentCapabilities {
    agent_id: String,
    location: TailscaleIP,
    model: {
        family: "anthropic" | "open-source" | "local",
        name: String,
        vram_gb: u32,
        inference_speed_tok_per_sec: f32,
    },
    resources: {
        available_disk_gb: u32,
        available_ram_gb: u32,
        gpu: Option<String>,
    },
    supported_task_classes: Vec<String>, // ["gap-filling", "refactor", "test-writing", ...]
    reliability_score: f32, // 0.0–1.0, learned from outcomes
    last_heartbeat: Timestamp,
}

#[derive(Serialize, Deserialize)]
pub struct TaskRequirement {
    gap_id: String,
    estimated_duration_sec: u32,
    required_model_family: Option<String>,
    min_vram_gb: Option<u32>,
    min_inference_speed: Option<f32>,
    task_class: String,
    decomposable: bool,
    help_available: bool, // can other agents help if this agent is blocked?
}

// Scoring function
fn task_fit_score(cap: &AgentCapabilities, req: &TaskRequirement) -> f32 {
    let mut score = 1.0;
    if let Some(required) = req.required_model_family {
        if cap.model.family != required {
            score *= 0.3; // can try, but not ideal fit
        }
    }
    if cap.resources.available_vram_gb < req.min_vram_gb.unwrap_or(0) {
        score *= 0.0; // can't run
    }
    if !cap.supported_task_classes.contains(&req.task_class) {
        score *= 0.5; // new territory
    }
    score * cap.reliability_score // discount by past reliability
}
```

---

## Work Board / Queue Schema

```
Topic: "chump/work-board"
Message:
{
  "subtask_id": "SUBTASK-001",
  "parent_gap": "PRODUCT-009",
  "title": "Blog draft external review",
  "description": "Get Gemini reviewer feedback on PRODUCT-009 draft",
  "requirement": {
    "task_class": "review",
    "required_model_family": null,
    "estimated_duration_sec": 3600,
    "decomposable": false
  },
  "posted_by": "agent-main-8c7f2e",
  "posted_at": "2026-04-24T15:30:00Z",
  "claimed_by": null,
  "status": "open" | "claimed" | "completed" | "failed",
  "help_requests": []
}
```

---

## First Demo: Single Sprint (2026 Q4)

**Goal:** Two agents on different machines, coordinated work.

**Scope:**
1. FLEET-006: Ambient stream → NATS
2. FLEET-007: Leases → NATS with TTL
3. FLEET-009: Capability matching (simple: model family + task class)
4. Manual work board (post a JSON, agents read and claim)

**Acceptance:**
- Agent A (claude-haiku-4-5 on Pi-1) claims gap DEMO-001
- Agent A discovers DEMO-001 is too large, posts SUBTASK-001
- Agent B (qwen3:14b on Pi-2) sees SUBTASK-001, checks fit (matches task class), claims it
- SUBTASK-001 completes on Agent B; result merged back into DEMO-001
- Ambient stream shows full timeline (session_start, bash_calls, commits, help_request, help_completion)

---

## Open Questions

1. **NATS reliability in air-gapped environments:** Can NATS run purely local, or do we need a fallback to git-backed queues?
2. **Help-seeking semantics:** When an agent asks for help, should it block (wait) or continue in parallel?
3. **Model sharding complexity:** Is pipeline-parallel inference worth the engineering cost for initial demo, or should we defer to 2027?
4. **Capability discovery:** Should agents register with a service discovery system (Consul, etc.) or publish via NATS heartbeat?
5. **Cost/benefit of decomposition:** At what task size does decomposition become more efficient than monolithic execution?

---

## Alignment with North Star

**North Star:** "Local-first, air-gapped capable, designed to run forever and grind."

**Fleet vision alignment:**
- ✅ Local-first: Tailscale VPN, no cloud dependency
- ✅ Air-gapped: NATS can run entirely offline
- ✅ Distributed grinding: Multiple agents, multiple devices, shared work board

**Risk:** Complexity increases significantly. Coordination bugs become harder to reproduce. Monitoring & observability become critical.

---

## Next Steps

1. File FLEET-006 through FLEET-013 in gaps.yaml
2. Prototype NATS integration (1–2 days, non-blocking)
3. Design capability schema (1 day review)
4. Run FLEET-006 to completion (2–3 weeks)
5. Use FLEET-006 output to unblock FLEET-007, FLEET-008, FLEET-009
