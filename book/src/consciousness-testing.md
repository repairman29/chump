# Consciousness utility pass (Architecture vs proof)

**Purpose:** Run the same **short scripted** interactions with `CHUMP_CONSCIOUSNESS_ENABLED=0` vs `1`, compare **wall time**, **pass/fail**, and optional **baseline JSON** deltas. Feeds [ROADMAP.md](ROADMAP.md) **Architecture vs proof → Consciousness utility pass**.

**Scope:** Runtime toggles only — no new consciousness features.

---

## Prerequisites

- Release binary: `cargo build --release --bin chump`
- Local model on **:8000** or **:11434** (same as [scripts/eval/consciousness-ab-mini.sh](../scripts/eval/consciousness-ab-mini.sh))
- Optional: `CHUMP_HEALTH_PORT` set so `scripts/eval/consciousness-baseline.sh` captures `/health` dashboard JSON

---

## Procedure

1. **Mini A/B (recommended default):**

   ```bash
   ./scripts/eval/consciousness-ab-mini.sh
   ```

   Note printed **ON vs OFF** seconds and keep `logs/baseline-AB-ON.json` / `logs/baseline-AB-OFF.json`.

2. **Deeper prompt set (optional):** [ROAD_TEST_VALIDATION.md](ROAD_TEST_VALIDATION.md) — `consciousness-exercise.sh` / full A/B off-peak.

3. **Interpretation:** If OFF is dramatically faster with **no** quality regression on your fixed prompts, consider `CHUMP_CONSCIOUSNESS_ENABLED=0` for latency-sensitive hosts until a module-level win is proven ([CHUMP_TO_CHAMP.md](CHUMP_TO_CHAMP.md) §gates).

---

## Log (append rows)

| Date (UTC) | Host profile | ON wall (s) | OFF wall (s) | Δ% | Pass/fail parity | Notes |
|------------|--------------|-------------|--------------|-----|------------------|-------|
| | | | | | | |

---

## Related

- [METRICS.md](METRICS.md) — phi / surprisal / A/B testing.  
- [MISTRALRS_AGENT_POWER_PATH.md](MISTRALRS_AGENT_POWER_PATH.md) §8 — cross-links inference A/B.  
- `src/context_assembly.rs` — `CHUMP_CONSCIOUSNESS_ENABLED` gate.
