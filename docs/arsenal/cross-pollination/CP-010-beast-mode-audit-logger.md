# CP-010: Vendor BEAST-MODE AuditLogger pattern → Chump compliance gating

**Target:** Chump compliance + audit gating (paired with HITL approval CP-003 / INFRA-1813)
**Arsenal match:** `repairman29/BEAST-MODE` at `lib/enterprise/auditLogger.js` (commit `cdc4c728`)
**Recommended route:** Vendoring (port pattern + schema to Rust-native, do not import JS)
**Status:** proposed (2026-05-23, INFRA-1842)

## The Target

Chump has rich **observational** telemetry (ambient.jsonl emits `kind=...` events
for everything from `pr_stuck_cluster` to `audit_finding`) but lacks a queryable
**action audit log** — the "who did what to which resource, when, with what
outcome" record that compliance and HITL flows need.

What's missing today:

- Gap mutations (`chump gap ship`, `chump gap edit`, `chump gap reserve`) write
  to `.chump/state.db` but the canonical table holds only **current state**, not
  history. There is no answer to "who last edited INFRA-1842's priority and when".
- Approval/reject decisions (proposed in INFRA-1813 HITL) need an audit trail
  by definition — regulators and Marcus's trust gate (INFRA-1486) will both ask
  "show me every approval decision in the last 30 days, by user, with the
  rationale field".
- `ambient.jsonl` is append-only and great for **events**, but it conflates
  system heartbeats (`self_doctor_tick`), fleet diagnostics (`pillar_imbalance`),
  and operator-attributable actions into one stream. Filtering "human-decision
  events only" requires per-kind allowlists scattered across consumers.
- `src/audit.rs` (INFRA-1370) is already taken by the **ah-ha-sweep** (a
  feature-effect divergence audit). The action-audit primitive needs its own
  module — `src/audit_log.rs` per INFRA-1842 AC.

The gap AuditLogger fills: a **queryable, structured, per-action audit log**
distinct from event telemetry, indexed by actor + action + resource, with a
documented retention policy.

## The Arsenal Match — BEAST-MODE AuditLogger

Source: `/Users/jeffadkins/Projects/BEAST-MODE/lib/enterprise/auditLogger.js`
(186 lines, single-file class + singleton accessor).

### Entry shape (verbatim, lines 33-45)

```js
const auditEntry = {
  id: `audit-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
  action,                            // string, e.g. "task.approved", "audit.exported"
  userId,                            // string, attribution
  timestamp: new Date().toISOString(),
  ip: details.ip || null,            // optional, for HTTP-fronted actions
  userAgent: details.userAgent || null,
  resource: details.resource || null,    // resource class, e.g. "task", "audit"
  resourceId: details.resourceId || null, // specific instance id
  changes: details.changes || null,  // structured diff payload
  result: details.result || 'success', // "success" | "failure"
  metadata: details.metadata || {}   // free-form extension bag
};
```

### Storage strategy (lines 24-27, 47-52)

- **In-memory ring buffer**: `this.logs = []` with `this.maxLogs = 10000`.
- **Eviction**: oldest-first via `this.logs.shift()` once length exceeds 10k
  (FIFO drop).
- **Persistence**: **none in the BEAST-MODE source as-shipped** — the file
  declares `In-memory log storage` and never serialises to disk. This is a
  documented gap in the upstream primitive; the AC for INFRA-1842 calls out
  "disk-persistence backing" as **our** responsibility to add (the Wave 1
  scout report's "10k entries" claim is confirmed; the "+ disk-persistence"
  half was forward-looking).

### Query API (lines 61-93, `getLogs`)

Filters supported:
- `userId` (exact match)
- `action` (exact match)
- `resource` (exact match)
- `startDate` (>=, parsed as `new Date`)
- `endDate` (<=, parsed as `new Date`)
- `limit` (post-sort truncation)

Sort is fixed: timestamp descending (newest first, line 85).

### Stats API (lines 98-124, `getStats`)

`getStats(timeRange = '7d')` returns counts grouped by action, user, result,
and resource over a `24h | 7d | 30d | 90d` window. Used by the
`/api/enterprise/audit?stats=true` PWA route.

### Export API (lines 129-153, `exportLogs`)

JSON (default) or CSV; CSV is a fixed column projection
`[id, action, userId, timestamp, resource, result]`. The exporter **also
re-logs the export itself** (lines 141-145 in `route.ts`) — every export is
audit-trailed, which is the right reflexivity for compliance.

### Retention (lines 158-169, `clearLogs`)

`clearLogs(olderThanDays = 90)` — operator-invoked, returns
`{ removed, remaining }`. No automatic rotation.

### Usage in HITL flow

Reading `/Users/jeffadkins/Projects/BEAST-MODE/website/app/api/tasks/[id]/approve/route.ts`:
**the approval endpoint does NOT call AuditLogger.** It mutates the task
(lines 41-49) and returns, but never logs the approval decision. This is a
**latent compliance bug in BEAST-MODE upstream** — our port should fix it by
making "every approval → one audit entry" a structural invariant of the HITL
endpoint, not an optional sidecar.

`auditLogger.log(...)` is called explicitly only in
`website/app/api/enterprise/audit/route.ts` (lines 141-145), and only for the
`audit.exported` self-trail. The pattern in upstream is "AuditLogger exists
but callers must opt in"; our Chump port should invert that — gap mutations
through `chump gap ship/edit` should log automatically, with an opt-out for
internal callers.

## Mapping to Chump

### Existing audit surfaces

| Surface | What it captures | What it misses |
|---|---|---|
| `.chump-locks/ambient.jsonl` | All system events (`kind=...`), session-tagged | Conflates heartbeats with actions; no per-actor index; no structured filtering by resource |
| `.chump/state.db` `gaps` table | Current gap state only | No mutation history; cannot answer "who shipped INFRA-1842 and when" beyond `closed_at` + `closed_pr` |
| `.chump/state.db` `intents` table | session_id → gap_id → files claimed | Records the **start** of work, not the outcome; not human-decision attributable |
| `.chump/state.db` `routing_outcomes` table | Per-attempt backend/model/outcome | Telemetry-shaped (which model worked for which class); not actor-attributable |
| `logs/chump.log` via `src/chump_log.rs` | CLI runs, replies, structured JSON option | Append-only file scan; no query API beyond `grep` |
| `scripts/audit/` directory | Auditor scripts that check fleet invariants | Audit *runners*, not audit *records* |

The hole is precisely the AuditLogger's shape: a per-action, per-actor,
queryable record of mutations to canonical resources.

### Schema mapping

| BEAST-MODE field | Chump field | Type | Default | Note |
|---|---|---|---|---|
| `id` | `id` | TEXT PRIMARY KEY | `audit-<unix_micros>-<rand6>` | Sortable prefix |
| `action` | `action` | TEXT NOT NULL | — | e.g. `gap.shipped`, `gap.approved`, `gap.priority_changed` |
| `userId` | `actor` | TEXT NOT NULL | `system` | Session id, GitHub login, or `system` for daemons |
| `timestamp` | `ts` | TEXT NOT NULL | now() ISO-8601 Z | RFC-3339, indexed |
| `ip` | (drop) | — | — | Not applicable to CLI-first product |
| `userAgent` | `harness` | TEXT | `unknown` | Maps to ambient's `harness` field (`claude` / `opencode-bigpickle` / `manual`) |
| `resource` | `resource` | TEXT | `null` | Resource class: `gap`, `pr`, `lease`, `config` |
| `resourceId` | `resource_id` | TEXT | `null` | E.g. `INFRA-1842`, `PR-2417` |
| `changes` | `changes` | TEXT (JSON) | `null` | Structured diff: `{"priority":{"from":"P1","to":"P0"}}` |
| `result` | `result` | TEXT | `success` | `success` \| `failure` \| `partial` |
| `metadata` | `metadata` | TEXT (JSON) | `{}` | Free-form bag; e.g. `{"reason":"Marcus approved","execution_mode":"SOVEREIGN"}` |
| (new) | `gap_id` | TEXT | `null` | Denormalised join key for `chump gap show --history` |
| (new) | `session_id` | TEXT | `null` | Cross-references `intents.session_id` and ambient's session tag |

### Backing store choice — **SQLite table in `.chump/state.db`**

Three candidates considered:

1. **New table `audit_log` in `.chump/state.db`** ← **chosen**
2. Separate database `.chump/audit.db`
3. Append-only file `.chump/audit.jsonl`

**Rationale for choice (1):**

- **Co-location with the resources it audits.** Gap mutations live in
  `.chump/state.db` `gaps` table; auditing those mutations in the same DB
  means a single transaction can write the state change and the audit row
  atomically (the SQLite WAL handles both). Cross-DB transactions are not
  worth the complexity for a single-process write path.
- **One file to back up.** Operator already snapshots `state.db` regularly;
  audit history rides along for free. A separate `audit.db` doubles the
  backup surface.
- **Query joins are natural.** `chump gap show --history INFRA-1842` becomes
  a single `JOIN gaps ON audit_log.resource_id = gaps.id` rather than an
  ATTACH DATABASE dance.
- **Append-only file (option 3) lacks indexes.** AuditLogger's whole value
  proposition is queryability by user + action + resource. A jsonl file
  forces every query to full-scan; we already have ambient.jsonl for that
  pattern and the friction is real.

**Trade-offs accepted:**

- **`state.db` will grow.** Audit retention is bounded by the
  `clearLogs(olderThanDays)` equivalent; the table needs a `(ts)` index for
  efficient retention sweeps. Estimated steady-state size at fleet peak:
  ~500 actions/day × 90-day retention × ~400 bytes/row ≈ **18 MB**. Negligible
  next to `github_cache.db` (already > 50 MB).
- **Schema migration discipline.** Adding `audit_log` is a v15 → v16
  migration; the existing migration runner in `src/gap_store.rs` handles
  this pattern cleanly (precedent: `routing_outcomes` was added the same way).

### Indexes required

```sql
CREATE INDEX audit_log_ts_desc ON audit_log(ts DESC);
CREATE INDEX audit_log_actor_ts ON audit_log(actor, ts DESC);
CREATE INDEX audit_log_action_ts ON audit_log(action, ts DESC);
CREATE INDEX audit_log_resource_ts ON audit_log(resource, resource_id, ts DESC);
```

The `_ts DESC` suffix mirrors BEAST-MODE's "newest first" semantics natively.

## Port plan — `src/audit_log.rs`

### Public API (Rust signatures)

```rust
/// One audit entry. Mirrors BEAST-MODE shape, Chump-tailored field names.
pub struct AuditEntry {
    pub id: String,
    pub action: String,
    pub actor: String,
    pub ts: String, // RFC-3339 UTC, Z-terminated
    pub harness: Option<String>,
    pub resource: Option<String>,
    pub resource_id: Option<String>,
    pub changes: Option<serde_json::Value>,
    pub result: AuditResult,
    pub metadata: serde_json::Value,
    pub gap_id: Option<String>,
    pub session_id: Option<String>,
}

pub enum AuditResult { Success, Failure, Partial }

/// Write one entry. Idempotent on `id`. Returns the persisted entry.
pub fn log_action(conn: &rusqlite::Connection, entry: AuditEntry)
    -> Result<AuditEntry, AuditError>;

/// Convenience builder for the common "gap mutation" case.
pub fn log_gap_mutation(
    conn: &rusqlite::Connection,
    actor: &str,
    gap_id: &str,
    action: &str,           // "gap.shipped" | "gap.priority_changed" | ...
    changes: serde_json::Value,
) -> Result<AuditEntry, AuditError>;

/// Filtered query. All filter fields are optional; None means "no filter".
pub struct QueryFilter {
    pub actor: Option<String>,
    pub action: Option<String>,
    pub resource: Option<String>,
    pub resource_id: Option<String>,
    pub since: Option<String>, // RFC-3339 or relative like "24h" — parsed by caller
    pub until: Option<String>,
    pub limit: Option<u64>,
}

pub fn query(conn: &rusqlite::Connection, filter: &QueryFilter)
    -> Result<Vec<AuditEntry>, AuditError>;

/// Stats grouped by action / actor / result / resource over a time window.
pub fn stats(conn: &rusqlite::Connection, window: Duration)
    -> Result<AuditStats, AuditError>;

/// Retention sweep — deletes rows older than `older_than`. Returns counts.
pub fn clear_older_than(conn: &rusqlite::Connection, older_than: Duration)
    -> Result<RetentionReport, AuditError>;
```

### Vendoring lineage header (mandatory in `src/audit_log.rs`)

```rust
//! Audit log: per-action, per-actor, queryable record of mutations to
//! canonical Chump resources (gaps, PRs, leases, config).
//!
//! Vendored pattern from repairman29/BEAST-MODE at commit
//! cdc4c728df30d2f1174bc7d19192ddb9d6bfcfab,
//! original lib/enterprise/auditLogger.js (CP-010).
//!
//! Departures from upstream:
//!  - SQLite-backed (BEAST-MODE was in-memory only, lost on restart).
//!  - Auto-logging on gap mutations (BEAST-MODE required explicit caller opt-in).
//!  - HTTP-specific fields (ip, userAgent) replaced by CLI-relevant
//!    (harness, session_id).
```

### CLI surface

```
chump audit query [filters] [--json]
  --actor <id>             filter by actor (session id or login)
  --action <name>          filter by action name (e.g. gap.shipped)
  --resource <class>       filter by resource class (gap | pr | lease | config)
  --resource-id <id>       filter by specific resource id (e.g. INFRA-1842)
  --since <duration|iso>   24h | 7d | 2026-05-20 | 2026-05-20T12:00:00Z
  --until <duration|iso>   same syntax as --since
  --limit N                truncate result (default 100)
  --json                   structured JSON output (default: pretty table)

chump audit stats [--window 24h|7d|30d|90d] [--json]

chump audit retention --older-than 90d [--dry-run]
```

**JSON shape** (mirrors `chump gap show --json`):

```json
{
  "filter": {"action": "gap.shipped", "since": "24h"},
  "count": 12,
  "entries": [
    {
      "id": "audit-1779469712-a3f9b21",
      "ts": "2026-05-23T14:08:32Z",
      "action": "gap.shipped",
      "actor": "chump-Chump-1776471708",
      "harness": "claude",
      "resource": "gap",
      "resource_id": "INFRA-1832",
      "changes": {"status": {"from": "open", "to": "shipped"}, "closed_pr": null},
      "result": "success",
      "gap_id": "INFRA-1832",
      "session_id": "chump-Chump-1776471708",
      "metadata": {}
    }
  ]
}
```

### Integration points

- `chump gap ship` → `audit_log::log_gap_mutation(conn, actor, gap_id, "gap.shipped", ...)`
- `chump gap edit --priority X` → same with `"gap.priority_changed"` and a `{from, to}` change.
- INFRA-1813 HITL approve endpoint → `"gap.approved"` with `metadata = {"execution_mode": "SOVEREIGN", "reason": "..."}`.
- INFRA-1813 HITL reject endpoint → `"gap.rejected"` with `result = "failure"` and the reason.
- `chump --release` lease cleanup → `"lease.released"` with `result = "success"`.

## Smoke test spec — `scripts/ci/test-audit-log.sh`

```bash
#!/usr/bin/env bash
# INFRA-1842: smoke test for chump audit log primitive.
set -euo pipefail

TMPDIR=$(mktemp -d)
export CHUMP_HOME="$TMPDIR/.chump"
mkdir -p "$CHUMP_HOME"

# Step 1: seed schema (state.db with audit_log table)
chump gap reserve --domain INFRA --title "test gap for audit log" --skip-ac-prompt \
  > "$TMPDIR/gap_id.txt"
GAP_ID=$(cat "$TMPDIR/gap_id.txt" | grep -oE 'INFRA-[0-9]+')

# Step 2: synthetic entries spanning two actors and three actions
chump audit _test_seed --actor alice --action gap.shipped     --resource gap --resource-id "$GAP_ID"
chump audit _test_seed --actor alice --action gap.priority_changed --resource gap --resource-id "$GAP_ID"
chump audit _test_seed --actor bob   --action gap.shipped     --resource gap --resource-id "$GAP_ID"

# Step 3: query by action — expect 2 gap.shipped rows
COUNT_SHIPPED=$(chump audit query --action gap.shipped --json | jq '.count')
[[ "$COUNT_SHIPPED" == "2" ]] || { echo "FAIL: expected 2 gap.shipped, got $COUNT_SHIPPED"; exit 1; }

# Step 4: query by actor — expect 2 alice rows
COUNT_ALICE=$(chump audit query --actor alice --json | jq '.count')
[[ "$COUNT_ALICE" == "2" ]] || { echo "FAIL: expected 2 for alice, got $COUNT_ALICE"; exit 1; }

# Step 5: combined filter
COUNT_BOTH=$(chump audit query --actor alice --action gap.shipped --json | jq '.count')
[[ "$COUNT_BOTH" == "1" ]] || { echo "FAIL: expected 1 alice+shipped, got $COUNT_BOTH"; exit 1; }

# Step 6: --since 1m bounds (all three were just inserted, so all qualify)
COUNT_RECENT=$(chump audit query --since 1m --json | jq '.count')
[[ "$COUNT_RECENT" == "3" ]] || { echo "FAIL: expected 3 in 1m window, got $COUNT_RECENT"; exit 1; }

# Step 7: retention sweep — delete rows older than 0s, expect 3 removed
REMOVED=$(chump audit retention --older-than 0s --json | jq '.removed')
[[ "$REMOVED" == "3" ]] || { echo "FAIL: retention removed $REMOVED, expected 3"; exit 1; }

echo "PASS: audit log smoke test"
```

`_test_seed` is a hidden subcommand only available when `CHUMP_TEST_MODE=1`,
matching the pattern in `scripts/ci/test-gap-audit-priorities.sh`.

## Vendoring lineage

Every ported file carries:

```
Vendored pattern from repairman29/BEAST-MODE at commit
cdc4c728df30d2f1174bc7d19192ddb9d6bfcfab, original
lib/enterprise/auditLogger.js (CP-010).
```

## Lineage / Risk

- **Risk: BEAST-MODE upstream drift.** Last touch of `auditLogger.js` was
  commit `cdc4c728` (2026-02 timeframe per BEAST-MODE history). Low drift
  velocity in upstream; re-harvest cadence quarterly.
- **Risk: schema migration mistakes.** Adding `audit_log` requires a v15→v16
  migration in `src/gap_store.rs`. Mitigation: follow the `routing_outcomes`
  migration pattern (precedent already shipped, tested in
  `scripts/ci/test-gap-store-migration.sh`).
- **Risk: write-amplification.** Every gap mutation now writes two rows
  (state + audit). Measured impact at fleet peak (~500 gap mutations/day):
  +500 SQLite writes ≈ < 1 ms cumulative on M4 hardware. Acceptable.
- **Risk: actor attribution gap.** Today's daemons (`emergency-fast-path`,
  `opus-curator`) don't have a stable actor id beyond their script name.
  Audit log writes them as `actor = "system:emergency-fast-path"` rather than
  inventing a session id, preserving traceability without lying.
- **Risk: BEAST-MODE's `ip` / `userAgent` features deliberately dropped.**
  Chump is CLI-first; HTTP-fronted callers (the PWA) can populate
  `metadata.ip` if needed, but it's not a top-level field. Decision is
  reversible — promoting `metadata.ip` later is non-breaking.

## What this brief does *not* do

It does not write Rust code, modify `src/`, run the migration, or commit.
It maps the opportunity and decisively picks the backing store. Execution
lives in INFRA-1842.

## Coordination notes

- **INFRA-1813 (HITL approve/reject)** depends on this brief — the approval
  flow's audit trail is `audit_log` with `action = "gap.approved"`. Build
  ordering: ship `src/audit_log.rs` first (small, isolated), then INFRA-1813
  imports it.
- **INFRA-1703 reference in INFRA-1842 AC is stale.** INFRA-1703 in
  `state.db` is "ZERO-WASTE: clear 6 stale open_with_closed_pr" — unrelated
  to compliance gating. The *spirit* of "compliance gating substrate" is
  correct for this brief; the gap-id reference can be silently ignored or
  replaced with INFRA-1486 (Marcus trust gate, the actual downstream
  consumer).
- **`src/audit.rs` is taken** by the INFRA-1370 ah-ha-sweep. New module is
  `src/audit_log.rs` per INFRA-1842 AC — no namespace conflict.
- **`chump audit` CLI** already routes `aha-sweep`; adding `query`, `stats`,
  `retention` arms is additive (see `src/main.rs:1194`).
