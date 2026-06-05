# Multi-Repo Scale Strategy

> **Operator framing (2026-06-05):** *"I want this to scale to 100s of repos
> soon. I alone have 100 repos. So maybe we need 10,000s."*
>
> This document is the load-bearing answer. It maps out **where today's
> architecture works**, **where it breaks**, and **which gaps to ship in
> what order** to walk from 1 → 100 → 10,000 external repos without
> retrofitting under pressure.
>
> Filed as MISSION-032. Pairs with [`docs/MISSION.md`](../MISSION.md):
> MISSION-010 is the proof on N=1 (BEAST-MODE); MISSION-032 generalizes
> to N=10,000.

---

## TL;DR — the 3-phase model

| Phase | Repos | What's true | Load-bearing gaps |
|---|---|---|---|
| **A** | 1–10  | Today. Tag in `skills_required`, single state.db, flat `.chump-locks/`, manual scans. | MISSION-018 ✅ (flag), MISSION-028 ✅ (picker), MISSION-031 (workers running) |
| **B** | 10–100 | Operator's own portfolio. Real disk + lease + scan pressure. | MISSION-033 (repos table) · 034 (lease partition) · 035 (clone GC) · 036 (scan rotate) · 037 (scoreboard rollup) · 038 (onboard scout schedule) |
| **C** | 100–10,000 | Multi-customer commercial. SQLite contention, ambient.jsonl scan cost, per-customer privacy. | INFRA-1967 (state.db sharding) · INFRA-1973 (ambient partition) · INFRA-1721/1742 (per-repo config) · new: customer-curator + cascade-tier privacy + repo-affinity picker + shallow clone + cross-repo dep + scout economics |

**Default assumption:** **stay tag-based through Phase B.** SQLite handles
100k rows trivially; the per-repo directory tree handles ~10k entries before
filesystem listing gets sluggish. The work in Phase B is **operationalizing
what's already there** (rotation, GC, partitioning), not re-architecting.

**Sharding (Phase C)** is the only step that genuinely changes the data
model. Don't pre-optimize.

---

## Phase A (1–10 repos) — what today is

**Already shipped (or shipping):**
- Tag-based gap routing: `gap.skills_required` contains
  `external_repo:<owner>/<repo>` → picker honors `CHUMP_EXTERNAL_REPO_PICK_OK`
  (MISSION-018, today).
- Picker mission-rank: P0 MISSION gaps beat P0 substrate (MISSION-028, today).
- Per-repo disk tree: `~/.chump/external/<owner>/<repo>/{scans,memory,clone}/`.
- `ExternalRepoContract` typed handoff: in → `(external_repo,
  repo_local_path, base_branch, fork_owner)`, out → `(pr_url, head_ref,
  files_touched, commit_sha)`. Repo identity flows through the contract.
- Scout (Phase-0 onboard scan) writes to `scans/onboard-scan-<ts>.json`.
- Context-Keeper memory deltas in `memory/`.
- Single `.chump/state.db` (3.8 MB at 2,426 gaps).

**What's verified working:** N=1 (BEAST). The proof is the mission of record.

**What's NOT yet operational (Phase A keystone):** MISSION-031 — fleet has the
flag and the picker, but no workers running to claim BEAST gaps. Without
this, every Phase-A piece compounds into wasted ships.

---

## Phase B (10–100 repos) — operator's own portfolio

This is the **next** scale frontier. Six load-bearing pieces.

### B.1 — First-class `repos` table (MISSION-033)

**Problem:** Today the set of tracked external repos is **inferred** from
`SELECT DISTINCT skills_required LIKE '%external_repo:%' FROM gaps`. That's
a string-scan and gives no lifecycle ("last scanned", "active vs dormant",
"clone present").

**Fix:** Add a `repos` table:
```sql
CREATE TABLE repos (
  id              TEXT PRIMARY KEY,    -- "owner/repo"
  owner           TEXT NOT NULL,
  name            TEXT NOT NULL,
  added_at        INTEGER NOT NULL,
  last_scan_at    INTEGER,             -- onboard scout cadence input
  last_clone_at   INTEGER,             -- clone-GC LRU input
  last_ship_at    INTEGER,             -- mission-scoreboard rollup input
  cascade_tier    TEXT NOT NULL DEFAULT 'dogfood',  -- dogfood|trains|safe (operator)
  status          TEXT NOT NULL DEFAULT 'active'    -- active|paused|archived
);
```

Auto-populated from gap-tag scan on `chump gap import`. Drives onboard
scheduling (B.6), clone GC (B.3), scoreboard rollup (B.5).

### B.2 — Lease namespace partitioning (MISSION-034)

**Problem:** `.chump-locks/` is a single flat dir. 50 concurrent BEAST claims
listed alongside internal-Chump claims means every `ls .chump-locks/*.json`
becomes O(N×M) and lease-overlap audits get noisy.

**Fix:**
```
.chump-locks/
├── claim-*.json                            (internal Chump work)
└── external/
    └── <owner>/<repo>/claim-*.json         (per-repo namespace)
```
Update `chump claim` to write under the correct sub-tree based on
`external_repo:` tag. Backwards compat: search both trees.

### B.3 — Clone GC daemon (MISSION-035)

**Problem:** `~/.chump/external/<owner>/<repo>/clone/` is a full git clone.
BEAST is 318 MB. 100 repos × 50 MB avg = 5 GB. 100 repos × heavy = 50 GB.
No eviction policy.

**Fix:** New `scripts/ops/external-clone-reaper.sh` + launchd plist.
- LRU by `last_clone_at` (from `repos` table, B.1).
- Reap clones not touched in 14d; re-clone on demand on next pick.
- Operator-overridable disk budget (env var, default 20 GB).
- Emit `kind=external_clone_reaped` to ambient.

### B.4 — Onboard scan rotation (MISSION-036)

**Problem:** Each scout pass writes a new `onboard-scan-<ts>.json`. BEAST
already has 2 ; 100 repos × N scans accumulates fast and there's no
compaction.

**Fix:** Keep latest 5 per repo; delete older. Small script + cron. Same
shape as INFRA-2339 broad-scan reaper (shipped today).

### B.5 — Mission scoreboard rollup (MISSION-037)

**Problem:** `scripts/dev/mission-scoreboard.sh` reports BEAST as
the binary. With 100 repos there's no "per-repo BEAST" view, no
aggregate "% of tracked repos with a zero-touch PR this month."

**Fix:** Add `--per-repo` flag and aggregate rollup:
- Per-repo: ①/②/③/④ for each row in `repos` where `status='active'`.
- Aggregate: % repos with mission-ship this week, P50 last-ship-age,
  zero-touch ship count.
- Same exit-code semantics; new output sections.

### B.6 — Onboard scout scheduling (MISSION-038)

**Problem:** Onboard is operator-initiated (`chump onboard <repo-url>`).
For 100 repos, manual triggering doesn't scale; for 10,000 it's absurd.

**Fix:** `chump-onboard-scheduler-daemon` (launchd plist):
- Reads `repos` table; picks N stale-or-new per cadence.
- Cadence: `last_scan_at < 7d ago AND status='active'`.
- Rate-limited (default 5 scans/hour) to avoid GitHub API exhaustion.
- Emits `kind=onboard_scan_scheduled`; writes results to the per-repo `scans/`.

---

## Phase C (100–10,000 repos) — multi-customer commercial

This is the **commercial vision** territory. Each of these is a separate
umbrella decomposition; cross-refs to existing prior art where it exists.

### C.1 — state.db sharding (INFRA-1967, already P0)

Single-node SQLite via r2d2 pool. Read replicas help; writes don't shard
without redesign. Options: per-customer DB, per-machine DB federated via
NATS, or move write-path to a dedicated coordinator.

### C.2 — ambient.jsonl partition (INFRA-1973, already filed)

Today every consumer linearly greps the same append-only file. At fleet
scale this is O(N×M). Need topic-partitioned event stream (NATS-native?
or rolling per-day files with an index).

### C.3 — Per-repo config (INFRA-1721 + INFRA-1742, already filed)

INFRA-1721: per-repo `CAPABILITIES_REGISTRY.json` auto-generated on PR merge.
INFRA-1742: per-repo `.chump-config.toml` + isolated `.chump/` namespace.

### C.4 — Customer-curator abstraction (NEW)

Each customer's 100-repo group has its own curator-opus pool with its own
priority weighting + pillar mix. Routes work within the customer scope
unless cross-customer collaboration is opt-in.

### C.5 — Cascade-tier privacy enforcement (NEW — operator memory note)

Operator decision: Trains-tier slots OK for own dogfood, NOT OK for
third-party content. Per-repo `cascade_tier` (in `repos` table B.1)
governs which Anthropic auth path is used. Default `safe` for
external repos until operator promotes.

### C.6 — Repo-affinity picker (NEW)

Workers prefer gaps in repos they've already cloned (cache locality).
Avoid "switch context every 5 min, clone 50 GB every claim" pathology.

### C.7 — Shallow-clone strategy (NEW)

`--depth=1` + targeted refspecs. Today every clone is a full history; 100
× 50 MB = 5 GB just for git histories that aren't read.

### C.8 — Cross-repo dep tracking (NEW)

Today `gap.depends_on` assumes same registry. A BEAST gap can't depend on
a derelict gap. Either unified ID space with repo prefix or add
`cross_repo_depends_on` field.

### C.9 — Onboard scout economic prioritization (NEW)

10,000 repos × N scans/day = budget problem. Need a model for "which
repos are worth scouting" — last-ship-age, dormant-but-promising signals
(stars, recent issues), customer-specified priority.

### C.10 — Multi-machine substrate (existing FLEET-* lineage)

Pi mesh / model splitting (operator vision). NATS-published WorkEnvelopes
route to the node with disk + CPU headroom. Same routing layer that
exists today, scaled across nodes.

---

## Substrate decisions

These are commitments — not gaps to ship, but constraints to honor.

1. **state.db stays single-writer through Phase B.** No sharding decisions
   until Phase C entry triggers. SQLite handles 100k rows of gaps fine.
2. **Per-repo namespace is filesystem, not schema.** Phase B partitioning
   moves locks but not tables. Phase C considers per-customer DBs.
3. **Tag-based gap routing stays canonical.** `external_repo:<owner>/<repo>`
   in `skills_required` is the registry; `repos` table is a derived index.
4. **Privacy boundary is per-repo, not per-gap.** `repos.cascade_tier`
   governs all gaps for that repo. Operator-controlled.
5. **Onboard is push-pull, not pure push.** Scheduler picks candidates
   (push); operator can always `chump onboard <repo>` (pull).

---

## Phase-transition triggers

When do we know it's time to enter the next phase?

| Trigger | From | To |
|---|---|---|
| Track ≥ 5 external repos with active leases | A | B |
| Disk usage `~/.chump/external/` > 5 GB | A | B |
| Mission scoreboard wants per-repo view | A | B |
| Track ≥ 50 external repos | B | C |
| Multi-customer cascade-tier rules become operational | B | C |
| `lease_overlap` events > 10/day | B | C |
| state.db write contention >100ms p99 | B | C |

We are at **Phase A → B transition** today: BEAST proves N=1 works, the
operator's portfolio (100 repos) is on the horizon. Phase-B Tier-1 gaps
(MISSION-033 – MISSION-038) are the substrate to ship before claiming
the first non-BEAST external repo.

---

## What this doc does NOT decide

- **The customer offer.** Is this self-serve (chump onboard your own
  repos), white-glove (we onboard for you), or platform (host their
  fleet)? Different scale shapes.
- **The pricing model.** Influences which scaling pressures matter (a
  fleet that costs $1/repo/day shapes Phase C economics differently from
  $100/customer/month).
- **The Anthropic relationship at scale.** API key per customer? Shared
  cascade with isolation? Tier-2 routing for external work? Operator
  has notes on this; needs Anthropic conversation.

These are operator + strategy decisions, not fleet-engineering ones.
Filed for visibility but not for the gap registry.
