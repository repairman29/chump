# FLEET Vision: Open Questions Research Report
**Date:** 2026-04-24  
**Source:** Web research on distributed agent orchestration, edge computing, and parallelization  
**Status:** Complete — informs FLEET-006 through FLEET-013 gap implementation

---

## Q1: NATS Reliability in Air-Gapped Setups

**Question:** Can NATS run entirely offline, or do we need a git-backed fallback?

**Finding:** ✅ **NATS is designed for air-gapped/edge deployment**

- NATS is explicitly built as "cloud and edge native messaging system" with minimal resource overhead
- **Single binary deployment** — no cluster setup required; can run isolated on Tailscale network
- **Leaf node architecture** — extends NATS clusters with selective data forwarding, perfect for air-gapped scenarios with bridges that define what data crosses segments
- **Recent deployment guide** (March 2026) confirms RHEL/edge device viability

**Recommendation:** Use NATS as primary; no git-backed fallback needed unless you want audit trail redundancy. NATS leaf nodes naturally handle network partitions.

**Sources:**
- [NATS.io — Edge & Cloud Native Messaging](https://nats.io/)
- [Deploy NATS Message Broker on RHEL (2026)](https://oneuptime.com/blog/post/2026-03-04-deploy-nats-message-broker-on-rhel-9/view)
- [NATS Server — GitHub](https://github.com/nats-io/nats-server)

---

## Q2: Help-Seeking Blocking Semantics

**Question:** Should original agent block (wait) or keep working in parallel when seeking help?

**Finding:** ⚠️ **Async with event-driven fallback is the 2026 pattern**

Research shows three approaches:

| Pattern | Use Case | Trade-off |
|---------|----------|-----------|
| **Synchronous (blocking)** | Capability gaps (need answer to proceed) | High latency, tight coupling |
| **Asynchronous (fire & forget)** | Time blockers (timeout help) | Agent moves on, loses context |
| **Event-driven (hybrid)** | Both; agent waits with timeout | Best throughput; requires retry logic |

**2026 Best Practice:** Asynchronous publish-subscribe with **temporal decoupling** (agent posts help request, continues working for N seconds, checks back). This gets:
- **70% average cache hit rates** on related state
- **Sub-millisecond state access** for coordination checks
- **Real-time pub/sub** without blocking

**Recommendation for Chump:** Async-first with timeouts. Agent posts help, continues work up to 5min, checks if help arrived. If yes, merge and re-plan. If no, keep original path.

**Sources:**
- [Multi-Agent Orchestration Patterns — Microsoft Learn](https://learn.microsoft.com/en-us/azure/architecture/ai-ml/guide/ai-agent-design-patterns)
- [DynTaskMAS: Dynamic Task Graph Framework](https://ojs.aaai.org/index.php/ICAPS/article/download/36130/38284/40203)
- [AI Agent Orchestration for Production — Redis Blog](https://redis.io/blog/ai-agent-orchestration/)

---

## Q3: Model Sharding Worth It Now?

**Question:** Is distributed model inference worth engineering now or defer to 2027?

**Finding:** ⏱️ **Defer to 2027, but research is ready**

**Current State (2026):**
- **Pipeline parallelism** mature for edge (low inter-node bandwidth needed; fits Tailscale)
- **Tensor parallelism** requires high-bandwidth connections (not ideal for edge VPNs)
- **Seesaw/AlpaServe** dynamically switch strategies between prefill/decoding phases

**Recent Results (2025–2026):**
- NVIDIA Dynamo framework for distributed LLM inference shipping
- Learning-to-Shard research automating parallelism degree selection
- Model re-sharding during inference shows 20–30% latency reduction

**Why Defer:**
- Pipeline parallelism adds complexity in agent coordination (2–3 weeks of integration)
- Most Chump models fit on single Pi (Qwen3-14B needs ~20GB; modern Pis have 8–16GB, so yes it's needed)
- 2027 timeline lets FLEET-006/007/008/009 land first

**Recommendation:** File **FLEET-014 (Distributed model inference)** as exploratory-stage gap for 2027 Q1. Do a 1-week spike on pipeline parallelism over qwen3:14b (real blocker for Pi cluster).

**Sources:**
- [DynamoLLM: Designing LLM Inference Clusters — HPCA 2025](https://jovans2.github.io/files/DynamoLLM_HPCA2025.pdf)
- [Seesaw: Model Re-Sharding for High-Throughput Inference — MLSys 2025](https://people.mpi-sws.org/~cgiannoula/assets/publications/Seesaw_mlsys25_full.pdf)
- [The LLM Scaling Hierarchy — Medium](https://akashsahani2001.medium.com/the-llm-scaling-hierarchy-mastering-every-dimension-of-parallelism-67937ae1d78e)

---

## Q4: Service Discovery — Tailscale mDNS vs Manual IP

**Question:** Should we use Tailscale mDNS or manual IP-based discovery?

**Finding:** ⚠️ **mDNS integration still in development; manual IP recommended for 2026**

**Tailscale mDNS Status:**
- Requested by users since 2023 ([Issue #1013](https://github.com/tailscale/tailscale/issues/1013))
- Still no native support as of 2026 (ongoing development discussions)
- **Workaround:** mDNS works *on* Tailscale network locally, but not *through* Tailscale routing

**2026 Production Approach:**
1. **Manual IP-based discovery** (simple): Agent finds NATS broker via environment variable `NATS_BROKER_IP` (Tailscale IP, stable)
2. **Consul/Service Mesh** (complex but scalable): If you grow beyond 5–10 devices
3. **DNS over Tailscale** (emerging): Tailscale DNS + local DNS server on primary node

**Recommendation:** Start with manual IP assignment (1–5 devices). Document in FLEET-013. Upgrade to Consul or DNS-over-Tailscale if device count exceeds 10.

**Sources:**
- [mDNS Support Issue — Tailscale GitHub #1013](https://github.com/tailscale/tailscale/issues/1013)
- [How to Make mDNS Discoverable on Tailscale](https://www.themtparty.com/how-to-make-mdns-discoverable-on-tailscale/)
- [Building Ultimate Homelab Network (2024)](https://mkuthan.github.io/blog/2024/07/29/homlab-network/)

---

## Q5: Decomposition Cost/Benefit Threshold

**Question:** At what task size does decomposition become more efficient than monolithic execution?

**Finding:** 📊 **Threshold: decompose if subtask > 300 LOC OR > 15min execution**

**Research Shows:**
- **Amdahl's Law limit:** Parallelization gains flatten after ~10–15% of work remains serial
- **Overhead dominates small tasks:** Task spawn, sync, merge costs outweigh parallelism gains on tasks < 1 minute
- **Problem size matters:** Single-element tasks offer no parallelism benefit; must be divisible

**2026 Empirical Rules:**
| Task Size | Recommendation | Overhead | Expected Speedup |
|-----------|-----------------|----------|------------------|
| < 100 LOC, < 5min | Keep monolithic | 20–30% | Not worth it |
| 100–300 LOC, 5–15min | Consider decompose | 15–20% | 1.5–2x |
| > 300 LOC, > 15min | **Decompose** | < 10% | 2–3x |
| > 1000 LOC, > 60min | **Must decompose** | Variable | 3–5x+ |

**Resource-aware scheduling (2025 research):** Optimization frameworks allocate tasks across devices to minimize power consumption and latency. On a Pi cluster, the decomposition breakeven is **10–15 minutes** (after that, parallelization overhead is < execution time).

**Recommendation for FLEET-011:** Use heuristic rule: decompose if execution_estimate > 15min OR file_count > 5. Start conservative (high threshold), learn from outcomes, tighten over time.

**Sources:**
- [Computing Task Scheduling for Distributed Heterogeneous Systems — Nature 2025](https://www.nature.com/articles/s41598-025-94068-0)
- [What Every Computer Scientist Needs to Know About Parallelization — arXiv 2025](https://arxiv.org/html/2504.03647v1)
- [Optimization of Resource-Aware Parallel Computing — Springer 2025](https://link.springer.com/article/10.1007/s11227-025-07295-7)

---

## Summary Decision Table

| Question | Answer | Action Item | FLEET Gap | Timeline |
|----------|--------|------------|-----------|----------|
| **NATS air-gapped?** | ✅ Yes, designed for it | Use NATS + Tailscale leaf nodes; no git fallback needed | FLEET-006 | Q3 2026 |
| **Blocking semantics?** | ⚠️ Async-first with 5min timeout | Implement fire-and-forget + retry loop on timeout | FLEET-010 | Q4 2026 |
| **Model sharding now?** | ⏱️ Defer, but prototype pipeline parallelism | Spike on pipeline parallelism; file FLEET-014 for Q1 2027 | FLEET-014 | 2027 Q1 |
| **Service discovery?** | Manual IP for 2026 | Use `NATS_BROKER_IP` env var; document in FLEET-013 | FLEET-013 | Q4 2026 |
| **Decomposition threshold?** | > 15min or > 5 files | Heuristic rule; learn from outcomes; update FLEET-011 | FLEET-011 | Q4 2026 |

---

## Architecture Implications

**For FLEET-006/007 (Distributed Coordination):**
- NATS is the right choice; design for leaf-node edge topology
- No need for git-backed fallback; focus on NATS reliability

**For FLEET-008/009/010 (Work Board & Help-Seeking):**
- Implement async-first semantics with 5-minute retry windows
- Agent doesn't block on help; continues work, checks back periodically
- Help-seeking is a normal operational pattern, not an exception

**For FLEET-011/012 (Decomposition & Blocker Detection):**
- Use 15-minute execution threshold as heuristic (not strict rule)
- Learn from outcomes; adjust threshold downward if decompositions succeed > 70%
- Blocker detection feeds help-seeking mechanism

**For FLEET-013 (Tailscale Integration):**
- Start with manual IP-based discovery; no mDNS complexity needed for initial fleet
- Document environment variables; upgrade to Consul if scale > 10 devices

**Defer to 2027:**
- FLEET-014 (distributed inference) — wait for FLEET-006/007/008/009 to mature
- Spike on pipeline parallelism in 2027 Q1 when core coordination is solid

---

## Next Steps

1. **FLEET-006 (Distributed Ambient Stream)** — Implement NATS pub/sub bridge over Tailscale
2. **FLEET-007 (Distributed Leases)** — TTL-based exclusive claims via NATS
3. **FLEET-008/009 (Work Board & Capability Matching)** — Async task posting + fit scoring
4. **First demo (Q4 2026):** Two agents on different machines, work board exchange, async help-seeking

---

**Status:** Research complete. Informs implementation decisions for FLEET-006 through FLEET-013.  
**Next review:** After FLEET-006 completion (estimate: 2026-06-15).
