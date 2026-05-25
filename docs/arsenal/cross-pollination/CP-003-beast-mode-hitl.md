# CP-003: Vendor BEAST-MODE HITL approval flow → Chump preflight + bot-merge

**Target:** Chump Marcus trust gate ([INFRA-1486](../../gaps/INFRA-1486.yaml) P0) — per-gap approval before fleet claims
**Arsenal match:** BEAST-MODE HITL flow at `website/app/api/tasks/[id]/{approve,reject}/route.ts`
**Recommended route:** Vendoring (port shape + adapt to gap vocabulary)
**Status:** proposed (2026-05-23, [INFRA-1813](../../gaps/INFRA-1813.yaml))
**Source provenance:** `repairman29/BEAST-MODE @ 612ff45f73791` (2026-03-17)

## The Target

Per [`docs/strategy/HARVEST_GROWTH_DIRECTIONS_2026-05-23.md` Direction 3](../../strategy/HARVEST_GROWTH_DIRECTIONS_2026-05-23.md), the Marcus trust gate
([INFRA-1486](../../gaps/INFRA-1486.yaml), P0) is the disqualifying-behavior firewall:
Persona-1 (Marcus) refuses to leave a fleet unattended without per-gap budgets *and*
a human approval gate for sensitive work. INFRA-1486 (per-gap budgets) shipped 2026-05-22;
this gap (INFRA-1813) lands the *approval* half of the substrate.

What Marcus needs:

1. A gap can be flagged `requires_human_approval=true` at filing time.
2. While the flag is set, `chump gap preflight` must report **NotApproved** and `chump claim`
   must refuse — *no* fleet worker can pick it up.
3. A human (operator UI) calls `POST /api/gap/[id]/approve` to flip the flag and the gap
   joins the pickable pool. Or `POST /api/gap/[id]/reject` to close it cleanly with the
   reason captured.
4. Both actions emit an ambient event so the audit log is queryable.

This is the substrate. INFRA-1486's per-gap budget mechanism then reads the approval state
rather than re-implementing gating (per AC #9 of INFRA-1813).

## The Arsenal Match — BEAST-MODE HITL contract

BEAST-MODE shipped a working two-endpoint HITL flow in `website/app/api/tasks/[id]/`
that we mirror endpoint-shape and field-by-field. Below is the verbatim contract.

### Approve endpoint contract

Path: `POST /api/tasks/[id]/approve`
Source: `BEAST-MODE/website/app/api/tasks/[id]/approve/route.ts` (67 lines, lines 14–67).

Method, body, response, side effects:

```typescript
// Lines 25-34: precondition check
// Verify task requires approval
if (!task.requiresHumanApproval && task.assigneeType !== 'HUMAN') {
  return NextResponse.json(
    {
      error: 'Task does not require approval',
      message: 'This task is not configured for human approval'
    },
    { status: 400 }
  );
}

// Lines 37-38: body shape — both fields optional
const body = await request.json().catch(() => ({}));
const { executionMode = 'SOVEREIGN', notes } = body;

// Lines 41-49: side-effect — atomic 5-field update
const updatedTask = await taskService.updateTask(params.id, {
  requiresHumanApproval: false,
  assigneeType: 'BOT',
  executionMode: executionMode as 'DRAFT' | 'SOVEREIGN',
  status: 'IN_PROGRESS', // Continue execution
  description: notes
    ? `${task.description}\n\n✅ APPROVED: ${notes}\n\nApproved at: ${new Date().toISOString()}`
    : `${task.description}\n\n✅ APPROVED at: ${new Date().toISOString()}`
});

// Lines 51-55: success shape
return NextResponse.json({
  success: true,
  message: 'Task approved and switched to autonomous mode',
  task: updatedTask
});
```

Failure path: error caught → `500` with `{ error: 'Failed to approve task', message }`
(lines 57–66). Precondition miss → `400` (line 32).

### Reject endpoint contract

Path: `POST /api/tasks/[id]/reject`
Source: `BEAST-MODE/website/app/api/tasks/[id]/reject/route.ts` (62 lines, lines 14–62).

Same precondition (lines 25–34) — only HITL-tagged tasks are rejectable. Then:

```typescript
// Lines 37-38: body — single optional field
const body = await request.json().catch(() => ({}));
const { reason = 'Rejected by human reviewer' } = body;

// Lines 41-44: side-effect — 2-field update
const updatedTask = await taskService.updateTask(params.id, {
  status: 'CANCELLED',
  description: `${task.description}\n\n❌ REJECTED: ${reason}\n\nRejected at: ${new Date().toISOString()}`
});
```

### Task type fields

Source: `BEAST-MODE/website/lib/coordination/types.ts` (118 lines).

The three approval-flow fields (lines 9–10, 20, 50, 53):

```typescript
export type AssigneeType = 'HUMAN' | 'BOT';        // line 9
export type ExecutionMode = 'DRAFT' | 'SOVEREIGN'; // line 10

export interface Task {
  // …
  assigneeType: AssigneeType;                       // line 20
  // …
  executionMode?: ExecutionMode;                    // line 50
  //   DRAFT: Fast (<5s), SOVEREIGN: Full review (10-20s)
  requiresHumanApproval?: boolean;                  // line 53
  //   If true, requires human approval before execution
}
```

`updateTask` is the workhorse — `BEAST-MODE/website/lib/coordination/taskService.ts:263`
auto-flips `assignee_type` when `requiresHumanApproval` toggles (lines 284–291):

```typescript
if (updates.requiresHumanApproval !== undefined) {
  updateData.requires_human_approval = updates.requiresHumanApproval;
  // Auto-set assignee_type if switching to/from HITL
  if (updates.requiresHumanApproval && updates.assigneeType === undefined) {
    updateData.assignee_type = 'HUMAN';
  } else if (!updates.requiresHumanApproval && updates.assigneeType === undefined
             && existingTask.assigneeType === 'HUMAN') {
    updateData.assignee_type = 'BOT';
  }
}
```

This auto-flip is the *single state invariant* Chump must preserve: an approved gap MUST
become claimable (assignee back to `BOT`); an un-approved gap MUST become un-claimable
(assignee stays `HUMAN`).

### Audit-log integration

Source: `BEAST-MODE/lib/enterprise/auditLogger.js` (185 lines).

Entry shape (lines 32–46):

```javascript
const auditEntry = {
  id: `audit-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`,
  action,
  userId,
  timestamp: new Date().toISOString(),
  ip: details.ip || null,
  userAgent: details.userAgent || null,
  resource: details.resource || null,
  resourceId: details.resourceId || null,
  changes: details.changes || null,
  result: details.result || 'success',
  metadata: details.metadata || {}
};
```

In-memory ring buffer, `maxLogs = 10000` (line 26). BEAST-MODE keeps logs in process;
Chump's equivalent is the durable `.chump-locks/ambient.jsonl` stream. We do NOT vendor
auditLogger.js as code — INFRA-1842 (filed) owns the full audit-store harvest. For
INFRA-1813 we emit one canonical ambient event per decision (see endpoint design below)
and INFRA-1842 reads from ambient.

## Mapping to Chump gap state

Chump stores gap rows in `.chump/state.db` (`crates/chump-gap-store/src/lib.rs:260-274`):

```sql
CREATE TABLE IF NOT EXISTS gaps (
    id                  TEXT PRIMARY KEY,
    domain              TEXT NOT NULL DEFAULT '',
    title               TEXT NOT NULL DEFAULT '',
    description         TEXT NOT NULL DEFAULT '',
    priority            TEXT NOT NULL DEFAULT '',
    effort              TEXT NOT NULL DEFAULT '',
    status              TEXT NOT NULL DEFAULT 'open',
    acceptance_criteria TEXT NOT NULL DEFAULT '',
    depends_on          TEXT NOT NULL DEFAULT '',
    notes               TEXT NOT NULL DEFAULT '',
    source_doc          TEXT NOT NULL DEFAULT '',
    created_at          INTEGER NOT NULL DEFAULT 0,
    closed_at           INTEGER
);
```

Preflight today (`crates/chump-gap-store/src/lib.rs:1519-1566`) returns:
`Available | NotFound | Done | Claimed(session_id)`.

Mapping table:

| BEAST-MODE field | Chump equivalent | Schema action |
|---|---|---|
| `requiresHumanApproval: bool` | **new column** `requires_human_approval INTEGER NOT NULL DEFAULT 0` | ADD COLUMN migration in `chump-gap-store/src/lib.rs` |
| `executionMode: 'DRAFT'\|'SOVEREIGN'` | **new column** `execution_mode TEXT NOT NULL DEFAULT 'SOVEREIGN'` | ADD COLUMN migration; also expose via `chump gap reserve --execution-mode draft` flag |
| `assigneeType: 'HUMAN'\|'BOT'` | **derived** from `requires_human_approval` + lease table — no new column. When `requires_human_approval=1`, no `leases` row may be inserted (the preflight returns the new `NotApproved` variant before any worker tries to claim). | None; lease table already exists |
| `status: 'CANCELLED'` (reject path) | existing `status='closed'` + `notes` carries `Rejection-Reason:` trailer | None |
| `notes: 'Rejected by …'` body field | append to existing `notes` column with trailer format `Rejection-Reason: <text>` for grep/parsing | None |
| audit entry | ambient event `gap_approval_decision` to `.chump-locks/ambient.jsonl` | EVENT_REGISTRY.yaml entry |
| `PreflightResult` enum | **new variant** `NotApproved` added to the enum at line 3041 | enum extension |

Two new columns, one new enum variant, one EVENT_REGISTRY entry. No new tables.

## Chump endpoint design

Endpoints live in `src/web_server.rs` alongside `handle_gap_claim`
(`src/web_server.rs:6684`). Both mirror the BEAST-MODE shape with the same precondition
+ atomic-update + ambient-emit pattern.

### POST /api/gap/[id]/approve

**Request:**
```http
POST /api/gap/INFRA-1486/approve
Content-Type: application/json
X-CSRF-Token: <token>     // existing check_csrf middleware
Authorization: Bearer <token>  // existing check_auth middleware

{ "execution_mode": "sovereign",   // optional, default "sovereign"
  "notes": "approved for fleet pickup; budget already capped at $5" }
```

**Preconditions** (matches BEAST-MODE lines 25–34):
- gap row exists
- `requires_human_approval = 1`
- CSRF + auth + rate-limit middleware (same as `handle_gap_claim` lines 6689–6708)
- if precondition fails → `400 { error: "Gap does not require approval" }`

**Side effects (atomic):**
1. `UPDATE gaps SET requires_human_approval=0, execution_mode=?, updated_at=? WHERE id=?`
2. Append to `notes`:
   `\n\nApproved at: <ISO8601> | Mode: <mode> | Notes: <notes>`
3. Emit to `.chump-locks/ambient.jsonl`:
   ```json
   {"ts":"<ISO8601>","kind":"gap_approval_decision",
    "gap_id":"INFRA-1486","decision":"approve",
    "decided_by":"<auth identity>","decided_at":"<ISO8601>",
    "execution_mode":"sovereign","reason":"<notes or null>"}
   ```

**Response:**
```json
{ "success": true,
  "message": "Gap approved; now claimable by fleet",
  "gap": { "id": "INFRA-1486", "requires_human_approval": false,
           "execution_mode": "sovereign", "status": "open" } }
```

### POST /api/gap/[id]/reject

**Request:**
```http
POST /api/gap/INFRA-1486/reject
Content-Type: application/json
X-CSRF-Token: <token>
Authorization: Bearer <token>

{ "reason": "scope too broad; decompose first" }   // optional; defaults to "Rejected by human reviewer"
```

**Preconditions:** identical to `/approve` (same enforcement that only HITL-flagged gaps are
rejectable through this path — un-flagged gaps close via the existing `chump gap close` path).

**Side effects (atomic):**
1. `UPDATE gaps SET status='closed', closed_at=?, requires_human_approval=0 WHERE id=?`
2. Append to `notes`: `\n\nRejection-Reason: <reason>\nRejected at: <ISO8601>`
3. Emit to `.chump-locks/ambient.jsonl`:
   ```json
   {"ts":"<ISO8601>","kind":"gap_approval_decision",
    "gap_id":"INFRA-1486","decision":"reject",
    "decided_by":"<auth identity>","decided_at":"<ISO8601>",
    "execution_mode":null,"reason":"scope too broad; decompose first"}
   ```

**Response:**
```json
{ "success": true, "message": "Gap rejected and closed",
  "gap": { "id": "INFRA-1486", "status": "closed",
           "requires_human_approval": false } }
```

### Preflight integration

`PreflightResult` enum (`crates/chump-gap-store/src/lib.rs:3041`) gains one variant:

```rust
pub enum PreflightResult {
    Available,
    NotApproved,    // NEW: requires_human_approval=1
    NotFound,
    Done,
    Claimed(String),
}
```

`preflight()` check (line 1549, before the existing `Done`/`Claimed` checks):

```rust
let row: Option<(String, i64)> = self.conn.query_row(
    "SELECT status, requires_human_approval FROM gaps WHERE id=?1",
    params![gap_id],
    |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)),
).optional()?;
match row {
    None => return Ok(PreflightResult::NotFound),
    Some((s, _)) if s == "done" || s == "closed" => return Ok(PreflightResult::Done),
    Some((_, 1)) => return Ok(PreflightResult::NotApproved),   // NEW
    _ => {}
}
```

`handle_gap_claim` (`src/web_server.rs:6722`) gains the matching match-arm:

```rust
Ok(gap_store::PreflightResult::NotApproved) => {
    Ok(Json(json!({
        "error": "Gap requires human approval; call /api/gap/<id>/approve first",
        "status": "not_approved"
    })))
}
```

## Smoke test spec — `scripts/ci/test-gap-hitl.sh`

Mirrors the shape of `scripts/ci/test-gap-audit-priorities.sh` (single file, `set -euo
pipefail`, exits non-zero on any AC violation). Cleanup trap purges fixtures regardless
of outcome.

Step-by-step:

1. **Setup**
   - `tmpdir=$(mktemp -d); export CHUMP_REPO=$tmpdir`
   - `chump init` (creates empty state.db)
   - `trap 'rm -rf $tmpdir' EXIT`

2. **File HITL-flagged fixture gap**
   - `gap_id=$(chump gap reserve --domain INFRA --title "HITL: smoke fixture" --requires-human-approval --json | jq -r .id)`
   - Assert: `chump gap show $gap_id | grep -q "requires_human_approval: true"`

3. **Assert preflight blocks**
   - `out=$(chump gap preflight $gap_id 2>&1)` (must exit non-zero)
   - Assert: `echo "$out" | grep -q "not_approved"`

4. **Assert claim blocks**
   - `out=$(chump claim $gap_id 2>&1)` (must exit non-zero)
   - Assert: no lease file created (`! ls .chump-locks/*.json`)

5. **Approve via endpoint**
   - Start `chump server` background; curl `POST /api/gap/$gap_id/approve` with
     `{"execution_mode":"sovereign","notes":"smoke"}`
   - Assert: response includes `"success":true`

6. **Assert preflight now Available**
   - `chump gap preflight $gap_id` exits 0
   - Output contains `Available`

7. **Assert claim succeeds**
   - `chump claim $gap_id` exits 0; lease file present

8. **Assert ambient event emitted**
   - `grep -q '"kind":"gap_approval_decision"' .chump-locks/ambient.jsonl`
   - `grep -q '"decision":"approve"' .chump-locks/ambient.jsonl`
   - `grep -q "\"gap_id\":\"$gap_id\"" .chump-locks/ambient.jsonl`

9. **Reject path (separate fixture)**
   - File second HITL-flagged gap; call `/reject` with `{"reason":"smoke reject"}`
   - Assert: `chump gap show $gap2 | grep -q "status: closed"`
   - Assert: notes contain `Rejection-Reason: smoke reject`
   - Assert: ambient stream has `"decision":"reject"` entry

10. **Negative — reject on non-HITL gap returns 400**
    - File gap without `--requires-human-approval`
    - `POST /reject` → HTTP 400, response includes `does not require approval`

Total runtime: ~3-5s. Wires into `scripts/ci/run-all-tests.sh` like other gap tests.

## Vendoring lineage

Every ported source file MUST carry the lineage comment at the top:

```rust
// Vendored from repairman29/BEAST-MODE @ 612ff45f73791
// (refactor(website): IA consolidation, 2026-03-17)
// Original: website/app/api/tasks/[id]/approve/route.ts (CP-003, INFRA-1813)
// Adapted: task → gap vocabulary; TypeScript → Rust axum handler;
//   in-memory updateTask → SQLite UPDATE + ambient emit.
```

(Adjust the `Original:` line per file: `reject/route.ts`, `lib/coordination/types.ts`,
`lib/coordination/taskService.ts`.)

This is the contract from AC #8 of INFRA-1813 — non-negotiable, the
`scripts/ci/test-vendor-lineage.sh` gate (filed separately as part of META-064
follow-up) will read for it.

## Lineage / Risk

- **Risk: JS-to-Rust translation drift.** BEAST-MODE uses Supabase + a JS service layer
  that auto-updates `updated_at`, auto-handles JSON-to-DB column mapping, and serializes
  enums opaquely. Chump uses rusqlite + explicit column maps. The atomic-update guarantee
  must be preserved with an explicit transaction (`BEGIN; UPDATE …; COMMIT;`) — easy to
  miss when each statement looks like it stands alone in JS.
- **Risk: stale lineage.** BEAST-MODE was last pushed 2026-03-17 (~2 months ago);
  approve/reject route files have been static since IA refactor. If BEAST-MODE ever
  evolves the contract, the lineage comment is the trace to re-sync. Re-harvest
  cadence: review at the next major Chump release.
- **Risk: approval-flag re-set after approval.** The auto-flip in `updateTask` lines
  287–291 of `taskService.ts` is bidirectional. If Chump permits a later
  `gap update --requires-human-approval` after the initial approval, the gap could
  silently re-block an in-flight worker. Mitigation: `chump gap update` rejects
  `requires_human_approval` changes when a live lease exists; smoke test step 7 covers it.
- **Risk: ambient stream replaces audit log poorly.** auditLogger captures `userId`, `ip`,
  `userAgent`. The ambient `kind=gap_approval_decision` event records `decided_by` only
  (whatever the `check_auth` middleware surfaces — today a bearer-token identity, not a
  full session). INFRA-1842 (filed) widens this when the full audit harvest lands.

## What this brief does *not* do

It does not write Rust code, modify `src/web_server.rs`, add migrations, register the
ambient event, or commit. It maps the BEAST-MODE contract onto Chump's gap state and
specifies the smoke test. Execution is the body of the implementation gap that follows
this brief — same INFRA-1813 — picked up by a separate sonnet worker.
