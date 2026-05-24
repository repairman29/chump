---
doc_tag: contract
owner_gap: INFRA-1050
last_audited: 2026-05-13
companion_docs:
  - docs/process/HARNESS_CONTRACT.md
  - docs/process/CHUMP_FIRST_DOCTRINE.md
---

# Agent-Facing API Spec

The agent-facing API surface — what Chump GIVES TO any harness. Complements `HARNESS_CONTRACT.md` (which is what Chump NEEDS FROM any harness). Together they define the compliance bar for declaring a harness "Chump-compatible".

Versioned so harness implementers can target a stable surface. Breaking-change discipline: a `schema_version` field appears on every JSON output; bump on incompatible shape changes; keep an N-1 compat shim for one release cycle.

## Versioning

| Surface | schema_version | Stability |
|---|---|---|
| `--briefing` markdown output | n/a (free-form for now) | informally stable; render order ≠ contract |
| `--briefing --json` output | **1** — proposed | breaking changes bump the int |
| `ambient emit` event shape | inherited from `docs/observability/EVENT_REGISTRY.yaml` | per-kind, registry-enforced |
| `health --json` | **1** — current shipped output | breaking changes bump |
| `gap show --json` | **1** — current | breaking changes bump |

All three primary JSON surfaces (`--briefing --json`, `health --json`, `gap show --json`) now emit `schema_version: 1` (INFRA-1548). This is **contracted** — harnesses may assert its presence. Surfaces that have not yet been wired remain **stable in practice but not formally contracted** — pin to a specific chump release rather than `latest`.

## Breaking changes

A `schema_version` bump is **required** when:
- A field is removed from a JSON output
- A field's type changes (e.g. string → array)
- A field's meaning changes incompatibly

An N-1 compatibility shim must be maintained for one release cycle after a bump. Adding new fields is non-breaking and does not require a bump.

## 1. `chump --briefing <GAP-ID>`

**Purpose:** one-shot read of everything an agent needs to start work on a gap.

**Input:**
- positional: `<GAP-ID>` — e.g. `INFRA-1050`, `CREDIBLE-040`
- exit 2 on missing/malformed positional

**Output (markdown, default):**
- Gap title, priority, effort, domain, AC
- Recent ambient events scoped to this gap
- Differential reflections from past similar-gap sessions (COG-042)
- Recent path-edits on files mentioned in the gap (COG-051)
- Session ledger stats — median elapsed, range, shipped/abandoned counts (INFRA-477)

**Output (JSON, proposed `--json` flag):**

```json
{
  "schema_version": 1,
  "gap_id": "INFRA-1050",
  "gap_title": "MISSION: agent-facing API spec — ...",
  "gap_priority": "P1",
  "gap_effort": "s",
  "gap_domain": "INFRA",
  "gap_acceptance": "...",
  "depends_on": [],
  "gap_not_found": false,
  "recent_ambient_events": [],
  "recent_deltas": [],
  "recent_path_edits": [],
  "similar_closed_prs": [],
  "session_stats": {"n": 0, "median_secs": 0}
}
```

**Failure mode:** when the gap is not found, exits 0 with `gap_not_found: true` and renders a clear "not found" block. Reason: harness implementations need to differentiate "Chump is broken" from "user typed a wrong gap ID" — exit codes lump them together.

## 2. `chump --execute-gap <GAP-ID>`

**Purpose:** orchestrated wrapper for hands-off harnesses. The fleet worker calls this; manual operators don't usually need it.

**Behaviour:**
1. Validate config
2. Read `required_model` from gap registry; override `FLEET_MODEL` (INFRA-843)
3. Spawn the agent loop with the gap context pre-loaded
4. Stream agent reply to stdout
5. Exit 0 on success; 1 on agent-loop failure; 2 on usage; **classified non-zero on specific failure classes** (INFRA-302: 402 billing-exhausted, etc.) so the orchestrator's stderr-tailer can decide whether to retry against a different routing-table candidate

**Stderr markers:** specific failure-class strings (`[chump-execute-gap] kind=billing_exhausted`, etc.) — defined in `src/execute_gap.rs::classify_execute_gap_error()`. **These are part of the API contract**; orchestrators parse them.

**Why this exists alongside `--briefing`:** `--briefing` is read-only; `--execute-gap` is the do-it-all wrapper. A harness that wants the agent loop driven by Chump uses this; a harness that drives its own loop uses `--briefing` instead.

## 3. `chump ambient emit` (INFRA-1048 — proposed)

**Purpose:** harness-agnostic event-write CLI. Replaces the Claude-Code-specific PreToolUse/PostToolUse hooks for harnesses that don't have those.

**Proposed surface (INFRA-1048 will ship this):**

```bash
chump ambient emit <kind> \
    [--gap <GAP-ID>] \
    [--source <script-name>] \
    [--field key=value]...
```

**Constraints:**
- `<kind>` must exist in `docs/observability/EVENT_REGISTRY.yaml` (pre-commit guard enforces)
- Writes to `.chump-locks/ambient.jsonl` with atomic append (no torn lines under concurrent writes)
- Honors `CHUMP_AMBIENT_OVERRIDE` env for tests
- Adds `ts` (RFC3339 UTC) automatically; harness should not pre-populate

**Why this matters for harness-independence:** today the FLEET-019 ambient stream wiring uses Claude Code's hook spec. opencode-bigpickle and manual harnesses can't emit events without inline-writing to `ambient.jsonl` directly (fragile). This CLI gives every harness the same event-emit surface.

## 4. `chump health --json`

**Purpose:** capability probe — what's wired, what's broken, what should be flipped before claiming.

**Current shipped fields (schema_version: 1 — implicit):**

```json
{
  "ts": "2026-05-13T20:42:00Z",
  "kind": "fleet_health",
  "score": 92,
  "grade": "A",
  "worst_signal": "none",
  "active_leases": 14,
  "stale_leases": 0,
  "waste_incidents_2h": 0,
  "fleet_wedges_2h": 0,
  "pr_stuck_2h": 0,
  "silent_agents_2h": 0,
  "today_spend_usd": 0.0,
  "over_budget": false,
  "ghost_gaps": 0,
  "pillars_starved": 0,
  "auth_ok": true,
  "commits_behind": 0,
  "session_rescues_24h": 0
}
```

**Use case for harnesses:** before claiming a gap, a harness calls `chump health --slo-check` (exit 1 on breach). Aborts politely if disk is critical, auth is missing, or the fleet is wedged. Cheaper and more accurate than each harness re-implementing these checks.

**SLO checks:** `--slo-check` reads `docs/process/FLEET_SLOS.md` and exits 1 if any pillar is breached. See that doc for the SLO list.

## 5. Supporting CLIs

These aren't part of the agent-loop core but every harness uses them:

| CLI | Purpose | Contract notes |
|---|---|---|
| `chump claim <GAP-ID> [--paths CSV]` | atomic worktree+lease creation (INFRA-468) | Replaces the 6-step shell preflight |
| `chump --release` | surrender a lease voluntarily | Idempotent |
| `chump gap show <GAP-ID> [--json]` | registry read | `--json` schema versioned implicitly at 1 |
| `chump gap ship <GAP-ID> [--update-yaml] [--closed-pr N]` | mark done after merge | YAML mirror is best-effort; state.db is canonical |
| `chump gap list [--status open\|done] [--json]` | enumerate registry | `--json` shape stable in practice |
| `chump fleet status [--json]` | sibling activity | Used pre-claim by harnesses that batch |

## Compliance examples

### Manual harness session (the simplest implementer)

```bash
GAP=INFRA-XYZ

# 1. Read what to do
chump --briefing "$GAP"

# 2. Claim
chump claim "$GAP" --paths src/foo.rs

# 3. cd to the new worktree and edit (any editor)
cd /tmp/chump-$(echo "$GAP" | tr A-Z a-z)
$EDITOR src/foo.rs

# 4. Emit progress to ambient (INFRA-1048)
chump ambient emit file_edit --gap "$GAP" --field path=src/foo.rs

# 5. Commit + push with your own git identity
git commit -am "fix($GAP): description"
git push origin HEAD --force-with-lease

# 6. PR + ship
gh pr create --base main
# (CI runs, you merge manually, or use bot-merge.sh)
chump gap ship "$GAP" --closed-pr 1234 --update-yaml
```

No Claude Code, no opencode, no agent loop — pure CLI compliance. This is the minimum viable harness.

### opencode-bigpickle session (existing canonical non-Claude harness)

Same shape, but `bigpickle@chump.bot` is the git identity, and `--execute-gap` is wrapped by the opencode dispatcher in a tool-use loop. Ambient events are emitted via `chump ambient emit` directly (no Claude hook integration). Per-harness ship-rate eventually surfaces in `kpi-report` once INFRA-1049 lands.

### Claude Code session (reference, in fleet)

`worker.sh` invokes `claude -p "$(chump --briefing $GAP)"` (today; INFRA-1045 will route this through `harnesses/claude.sh`). Hooks emit ambient events automatically via the PreToolUse/PostToolUse plumbing. `chump --execute-gap` is the orchestrated entry point.

## Compliance checklist

A harness is "API-compatible" if it correctly handles every entry point in §1–4 (§5 is recommended but optional). The bigger compliance bar — including the OS-side contract — lives in `HARNESS_CONTRACT.md`.

When adding a new entry-point or changing an existing one's contract, bump the `schema_version` and update this doc in the same PR. The audit gate (INFRA-1051) will eventually enforce this; today it's discipline.
