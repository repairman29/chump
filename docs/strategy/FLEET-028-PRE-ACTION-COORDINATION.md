---
doc_tag: coordination
owner_gap: FLEET-028
last_updated: 2026-05-03
---

# Pre-Action Coordination: Multi-Tier Collision Prevention (FLEET-028 Umbrella)

**Status:** Umbrella coordination gap; three implementation tiers filed and awaiting dispatch  
**Motivation:** 2026-05-02 collision incident revealed blind spots in agent visibility before gap reservation and PR creation  
**Vision:** Three-tier system where agents broadcast intent at observation time, investigation time, and semantic-match time — not just at lease-claim time

---

## The Problem (2026-05-02 Incident)

Three independent collisions surfaced in one evening where agents started the same work minutes apart, neither aware of the other:

- **INFRA-226 ↔ INFRA-227**: Both fixed bot-merge.sh's auto-close path post-INFRA-188 with different patches
- **INFRA-240 ↔ INFRA-241**: Both audited per-file YAML drift; complementary scopes but neither saw the other investigating
- **FLEET-024 close-flip**: Manual close overlapped with INFRA-241 backfill auto-close via PR title heuristic

**Root cause:** Agents have three coordination signals (leases, ambient.jsonl, open PRs) but none broadcast "I'm investigating problem X but haven't reserved a gap yet." The trajectory is:

```
observe-bug → form-intent → reserve-gap → claim-lease → code → PR
```

Coordination signals fire only from `claim-lease` onward. The `observe-bug` and `form-intent` phases are agent-local.

---

## Three-Tier Solution

### Tier 1: Forced Re-Glance (FLEET-029)

**Implementation:** Shell-based, ~1 day effort  
**What it does:** Forces ambient.jsonl + open-PR scan at two critical moments where collisions happened:

1. **At `chump gap reserve`** — moment when a new ID is allocated
2. **After `gh pr create`** — moment when a branch is pushed and PR opens

**How it works:**
- Tail `.chump-locks/ambient.jsonl` for INTENT events in the last 300 seconds
- Scan `gh pr list` for exact ID + substring title matches
- Warn operator (non-blocking for Tier 1) if overlaps detected
- Operator can `--force` past or pick an existing gap to claim instead

**Catches:** Exact ID collisions, substring-overlap cases (e.g., both titles contain "bot-merge auto-close fix")

**Doesn't catch:** "Same problem, different words" (e.g., "fix bot-merge.sh auto-close path" vs "patch docs/gaps.yaml ref in bot-merge auto-close")

---

### Tier 2: New Ambient Event Kinds (FLEET-030)

**Implementation:** SDK + ambient stream changes, ~2 days effort  
**What it does:** Extends ambient.jsonl event vocabulary to cover pre-action signals

**New event kinds:**

1. **`OBSERVED kind=<topic-hash>`** — Emitted when an agent recognizes a gap-worthy problem but hasn't yet reserved a gap
   - Trigger: operator reads CI failure, cold-water audit detects pattern, bot-merge error heuristic triggers
   - Receivers: other agents glance ambient, see "agent X is investigating <topic>" before their own reservation

2. **`INVESTIGATING gap=<id>`** — Emitted between gap-reserve and first code edit
   - Signals "I have an ID and worktree; I'm scoping the fix"
   - Fills the 5–30 minute visibility gap between INTENT (lease claim) and first file_edit

**Implementation:**
- New event kinds in `src/ambient_stream.rs` + JSON schema validation
- Emission hooks in `chump gap reserve` / `chump gap claim` (INVESTIGATING)
- Emission hooks in orchestrator loop + CLI (OBSERVED)
- Claude SDK skill adds `chump observe "<topic>"` slash command

**How it helps:** Combined with Tier 1, catches the "I'm investigating X, you weren't watching" case within 5–10 minutes

---

### Tier 3: Semantic Title Similarity (FLEET-031)

**Implementation:** TF-IDF or embedding model, ~3 days effort  
**What it does:** Computes title-similarity scoring (≥0.7 threshold) for proposed gaps against open + recently-merged PRs

**Two paths:**
- **Path A (recommended v1):** TF-IDF + cosine similarity (no model required, ~5ms per reserve)
- **Path B (high-quality):** Small embedding model (Qwen-0.5B-Embedding, ~50ms per reserve)

**How it works:**
- On `chump gap reserve --title "..."`, compute similarity against all open PR titles + last 30 days merged
- If matches ≥0.7 detected, print `[WARN-similar]` with top-3 candidates
- Operator can `--force` past or pick an existing gap to claim instead

**Catches:** "Different words, same problem" (e.g., INFRA-226 ↔ INFRA-227 paraphrase case)

---

## Integration & Dispatch

| Tier | Gap | Effort | Dependency | Acceptance Criteria |
|------|-----|--------|------------|---------------------|
| 1 | FLEET-029 | m | FLEET-028 | `chump gap reserve` tails ambient + scans PRs; warns on overlap; test in `scripts/ci/test-reserve-glance.sh` |
| 2 | FLEET-030 | m | FLEET-028, FLEET-029 | OBSERVED + INVESTIGATING events defined + emitted; CLI subcommand + SDK hook; schema validation passes |
| 3 | FLEET-031 | l | FLEET-028, FLEET-029, FLEET-030 | Title-similarity scoring at reserve time; ≥0.7 threshold; test against INFRA-226/227 corpus |

**End-to-end smoke test:** Two agents independently form intent to "fix bot-merge.sh post-188" within 60 seconds:
1. Agent A runs `chump observe "bot-merge post-188"` → OBSERVED event fires
2. Agent A runs `chump gap reserve --title "fix bot-merge auto-close..."` → reads ambient, sees Agent B's OBSERVED, warns
3. Agent B runs `chump gap reserve --title "patch bot-merge docs/gaps ref..."` → Tier 3 similarity flags Agent A's INFRA-227 at ≥0.7, warns
4. Both agents see each other's signals before either reserves, coordinate or defer

---

## Out of Scope

**Tier 4: Live Presence Feed** — Deferred until Tier 1+2+3 are in and operational. NATS infrastructure already exists; Tier 4 becomes an obvious add-on once we measure what's still missing (e.g., "I'm typing the same gap ID as you right now" sub-second handoff). Candidate follow-up gap: FLEET-NNN.

---

## Design Rationale

**Why three tiers, not one?**
- Tier 1 is pure shell work; lands fast; catches simple overlaps
- Tier 2 adds structured event vocabulary; more infrastructure but more precision
- Tier 3 adds semantic intelligence; state-of-the-art but highest cost

**Why optional `--force` instead of blocking?**
- Operators may have strong reasons to reserve a gap even if overlap detected (intentional split, different scope)
- Non-blocking warning preserves operator agency while surfacing awareness

**Why TF-IDF before embedding?**
- TF-IDF is deterministic, reproducible, no model memory needed
- 5ms cost is negligible vs. coordination latency saved
- Embedding path is a clear upgrade path if TF-IDF recall is insufficient

**Why now?**
- The coordination layer (ambient.jsonl, NATS, leases) is mature enough that pre-action signals are actionable
- Single-night three-collision incident demonstrates this is load-bearing, not nice-to-have

---

## Measurement & Tuning

Post-Tier-1 ship:
- Count `[WARN]` events in ambient.jsonl for 2 weeks
- Measure false-positive rate (operator force-passed but no actual overlap)
- Measure false-negative rate (collisions still happened despite system operational)
- Publish results in cycle-end synthesis

---

## Related Work

**Multi-agent coordination literature:**
- Overture theorem (agent visibility at decision points)
- STRIPE paper (agents sharing intent signals reduces thrashing)
- NASA JPL Mars rover rover multi-rover coordination (pre-commit consensus mechanisms)

This system combines STRIPE intent-sharing (Tier 2) with pre-flight glance (Tier 1) and semantic similarity (Tier 3) adapted for git-backed code coordination.
