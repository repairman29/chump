---
doc_tag: log
owner_gap: REMOVAL-007
last_audited: 2026-05-02
---

# REMOVAL-007 — `src/phi_proxy.rs` + `src/holographic_workspace.rs` wiring trace

**Date:** 2026-05-02
**Gap:** REMOVAL-007
**Status:** COMPLETE — split decision: **phi_proxy KEEP** (gated but real); **holographic_workspace REMOVAL CANDIDATE** (write-only in production; no consumer for the encoded data)
**Outcome:** Per-module decisions below; one follow-up filed (REMOVAL-009: holographic_workspace either remove or wire a real retrieval consumer).

---

## TL;DR

Same shape as REMOVAL-006: the original gap (filed 2026-04-26) said both modules "appear in the binary but are never invoked from agent_loop or any tool dispatch path." Trace finds the situation is more nuanced:

| Module | In request path? | Affects LLM behavior? | Verdict |
|---|---|---|---|
| `phi_proxy` | Yes (via `consciousness_traits::substrate()` from `tool_runner` + via `context_assembly`) | Yes — but gated on regime ≠ Exploit AND `consciousness_enabled` AND `!light_interactive` AND `phi.active_coupling_pairs > 0` | **KEEP** |
| `holographic_workspace` | Encode side: yes (every tool dispatch). **Read side: no** | **No** — encoded data is never queried back in production code | **REMOVAL CANDIDATE** (file as REMOVAL-009 — defer decision because retrieval-augmented context is a plausible future consumer) |

---

## phi_proxy.rs (252 LOC, 7 public exports)

### Call graph

| Caller | Purpose | Affects prompt? |
|---|---|---|
| `context_assembly.rs:716` | `phi.active_coupling_pairs > 0` → write "Integration metric: …" line | **Yes** (gated by full_consciousness regime) |
| `context_assembly.rs:849` | `record_session_consciousness_metrics` — telemetry | No (per-session telemetry only) |
| `consciousness_traits.rs:170-176` | substrate trait impl | Caller-dependent |
| `tool_runner.rs:80/246/308` | calls `consciousness_traits::substrate()` | Indirect — substrate methods include phi |
| `tool_middleware.rs:1136/1180/1199` | substrate calls | Indirect |
| `health_server.rs:143` | telemetry surface | No (HTTP-only) |
| `consciousness_exercise.rs:446/461` | exercise/test runner | No (specialized) |

### Gating chain (context_assembly:643-715)

```
if consciousness_enabled && !light_interactive {       // top guard
    let regime = precision_controller::current_regime();
    let full_consciousness = !matches!(regime, Exploit);
    …
    if full_consciousness {                             // skipped in Exploit mode
        let phi = phi_proxy::compute_phi();
        if phi.active_coupling_pairs > 0 {              // empirical: usually 0 early in session
            writeln!(out, "Integration metric: {}.", …);
        }
    }
}
```

**Default operation:** in `Exploit` regime (the common steady state), phi never reaches the prompt. In `Balanced` / `Explore` regimes with active coupling, phi contributes a one-line "Integration metric" to the system prompt.

### Decision: KEEP

phi is wired correctly; the gating is intentional (compute is "expensive, context-heavy" per the inline comment). The original gap's claim "never invoked" is false. Alternative would be to remove the gating (always compute) — that's a behavioral change requiring its own ablation, out of scope.

---

## holographic_workspace.rs (314 LOC, 8 public exports)

### Call graph

| Caller | Direction | Production consumer? |
|---|---|---|
| `consciousness_traits.rs:326` (`substrate.encode`) | **Write** | Called from `tool_middleware.rs` + `tool_runner.rs` on every tool dispatch |
| `consciousness_traits.rs:329` (`substrate.query`) | **Read** | **NO PRODUCTION CALLER** — only used in `holographic_workspace.rs`'s own tests |
| `consciousness_traits.rs:332` (`substrate.capacity`) | **Read** (metrics) | Telemetry only |
| `health_server.rs:188` (`metrics_json`) | **Read** (metrics) | Telemetry only |

`grep -rn 'substrate\(\).query\|query_similarity' src/*.rs` returns zero production callers. The data goes in (encoded on every tool dispatch); nothing reads it back to influence agent behavior.

### Decision: REMOVAL CANDIDATE — defer to follow-up

This is exactly the REMOVAL-002 (surprisal_ema) precedent: a write-only research scaffold with no read-side consumer. Two paths:

1. **Remove** — drop both the module and the encode-side wiring in `consciousness_traits::DefaultHolographicStore`. ~314 LOC + ~10 LOC at callsite. Risk: minimal (no consumer, no behavior change).
2. **Wire a real read-side consumer** — e.g. retrieval-augmented context that uses `query_similarity` to surface recent similar tool calls when assembling context. This would make the existing encode-side cost (~one HRR per tool dispatch) actually pay off.

Path (2) is the more interesting research direction (RAG-on-tool-history is a known-useful pattern), but it's a real feature, not an audit close-out. Filing as **REMOVAL-009** with both options laid out so the next operator picking it up knows what's involved.

In the interim: **document the write-only state in CHUMP_FACULTY_MAP.md and README** so the "nine engineering proxies" framing is honest about what's wired.

---

## Acceptance vs the gap

| REMOVAL-007 acceptance | Status |
|---|---|
| Trace each module — is it called from any path that runs during a normal chat turn? | ✅ both yes; phi gated, holographic write-only |
| Decide per-module — dead-code remove, wire+test, or document as research-scaffold | ✅ phi: KEEP; holographic: REMOVAL CANDIDATE filed as REMOVAL-009 |
| Update README and CHUMP_FACULTY_MAP.md to reflect outcome | ⏳ filed as DOC-010 already (nine-proxies reframe) — coordinate with that gap rather than touch docs twice |
| Pair with DOC-010 (nine-proxies reframe) | ✅ DOC-010 is filed; this audit links to it as the natural doc-update vehicle |
