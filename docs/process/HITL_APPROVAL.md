# HITL Approval Gate — Marcus M-B Trust Substrate (INFRA-1813)

> **Vendored from `repairman29/BEAST-MODE @ 612ff45f73791`**
> (`website/app/api/tasks/[id]/{approve,reject}/route.ts`).
> Lineage doc: [`docs/arsenal/cross-pollination/CP-003-beast-mode-hitl.md`](../arsenal/cross-pollination/CP-003-beast-mode-hitl.md).

This document explains the Human-In-The-Loop approval gate that lives in
`scripts/coord/bot-merge.sh`. It is the trust substrate for the Marcus
M-B demo (Day-28, 2026-06-25): a customer can hand Chump a repo, let the
fleet ship PRs, and **require human approval before any auto-merge fires**.

The pair to this gate is the per-gap budget gate
([INFRA-1486](../gaps/INFRA-1486.yaml), shipped 2026-05-22, M-A).

---

## Per-repo opt-in

The HITL gate is **OFF by default**. The Chump-internal repo stays full-auto.
Customer repos opt in via one of:

| Surface | Effect |
|---|---|
| Env: `CHUMP_REQUIRE_HITL=1` | Forces the gate for the current bot-merge invocation |
| File: `.chump/require-hitl` at repo root | Persistent per-repo opt-in (commit to revoke fleet-auto) |
| (future) `chump.fleet.yaml: require_hitl: true` | Declarative per-repo opt-in; tracked as follow-up |

When neither signal is present, bot-merge arms auto-merge as it always has.

---

## Approval signals

Once the gate is ON, bot-merge will **refuse to arm auto-merge** unless one
of these approval signals is present for the PR:

| # | Signal | Best for |
|---|---|---|
| 1 | Env: `CHUMP_HITL_APPROVED=1` | Operator one-shot (`CHUMP_HITL_APPROVED=1 scripts/coord/bot-merge.sh ...`) |
| 2 | File: `.chump-locks/hitl-approved-<PR>.flag` | PWA tray scripts / drop-and-rerun automations |
| 3 | PR label: `hitl-approved` | GitHub-native operator UX (web/mobile, one click) |

ANY one signal is sufficient. The signal type is recorded in the
`hitl_approval_granted` ambient event for audit.

---

## Operator flow

### Customer-side (Marcus persona)

1. Operator commits `.chump/require-hitl` to the repo root (one line, empty file).
2. Fleet runs as usual. Each ship-eligible PR reaches the `auto-merge arm`
   stage in `bot-merge.sh`. Before arming, the gate checks for an approval
   signal.
3. Without approval: bot-merge skips arming, leaves the PR open, posts a
   comment on the PR with the three approval methods, and emits
   `kind=hitl_approval_required` to `.chump-locks/ambient.jsonl` with:
   ```json
   {
     "ts": "...", "kind": "hitl_approval_required",
     "pr": 1234, "branch": "chump/...", "files": "scripts/...,src/...",
     "session": "claim-...",
     "approve_hint": "touch .../.chump-locks/hitl-approved-1234.flag OR gh pr edit 1234 --add-label hitl-approved"
   }
   ```
4. Operator (Marcus) reviews the PR via GitHub UI, the PWA tray, or
   `tail .chump-locks/ambient.jsonl | jq 'select(.kind=="hitl_approval_required")'`.
5. To approve: click the `hitl-approved` label on the PR, OR `touch` the flag file,
   OR set `CHUMP_HITL_APPROVED=1` and re-run bot-merge.
6. On re-run, the gate sees the signal, emits `kind=hitl_approval_granted`,
   and arms auto-merge per the usual path.

### Reject flow

To reject a PR (analog to the BEAST-MODE `/reject` route):

```bash
gh pr close <N> --comment "Rejected — <reason>"
chump gap ship <ID> --closed-pr <N>  # or: chump gap close <ID> --reason "<reason>"
```

The current MVP keeps reject as a manual `gh pr close` + gap-close action.
A future iteration will wire a `chump gap reject <ID>` CLI verb that
captures the rejection reason into the gap notes (per AC item 4).

---

## Ambient events

Both kinds are registered in [`docs/observability/EVENT_REGISTRY.yaml`](../observability/EVENT_REGISTRY.yaml)
with `scanner-anchor` comments at the emit site in `bot-merge.sh`:

- `hitl_approval_required` — emitted on block; carries PR, branch, files, approve_hint
- `hitl_approval_granted` — emitted on proceed; carries PR, signal type

Consumers: `ops-audit`, `pwa-hitl-tray`, `waste-tally`.

---

## Coordination with INFRA-1486 (per-gap budgets)

INFRA-1486 lands the **per-gap budget** gate (token/$/wall-clock caps) before
the fleet picks a gap. INFRA-1813 lands the **per-PR approval** gate before
bot-merge arms auto-merge. They sit at **different stages** of the pipeline
(pick vs. ship) and compose without coupling: a customer can opt into
budget-only, approval-only, or both.

The shared substrate is `.chump-locks/ambient.jsonl`. Future operator UIs
(PWA HITL tray) read both kinds and present a unified queue.

---

## BEAST-MODE provenance

The shape of this gate (approve/reject as the two operator verbs, the
`requiresHumanApproval` flag flip on approve, the `executionMode` knob
for SOVEREIGN vs DRAFT) was lifted from BEAST-MODE's task-coordination
HITL pattern. Mapping onto Chump's vocabulary:

| BEAST-MODE | Chump (this gate) |
|---|---|
| `Task.requiresHumanApproval: boolean` | per-repo `.chump/require-hitl` flag |
| `Task.assigneeType: HUMAN | BOT` | implicit — fleet is BOT, opt-in flips to HUMAN-supervised |
| `Task.executionMode: DRAFT | SOVEREIGN` | not modeled in MVP; future enhancement |
| `POST /api/tasks/[id]/approve` | `gh pr edit <N> --add-label hitl-approved` (or two alternates above) |
| `POST /api/tasks/[id]/reject` | `gh pr close <N> --comment "..."` (CLI verb future) |

Full mapping + verbatim contract: [CP-003](../arsenal/cross-pollination/CP-003-beast-mode-hitl.md).

---

## Bypass

There is no `CHUMP_BYPASS_HITL` env. The whole point of the gate is to be
unbypassable when ON. To turn it off entirely: remove the
`.chump/require-hitl` file (or unset `CHUMP_REQUIRE_HITL`).

To bypass for a single PR: approve it. That is the contract.

---

## Tests

- `scripts/ci/test-hitl-gate.sh` — table-driven decision-logic replay +
  structural presence + EVENT_REGISTRY coverage + this doc presence.

---

## Follow-ups (intentionally out-of-scope for INFRA-1813)

1. **PWA endpoints** (`/api/gap/[id]/{approve,reject}`) — AC item 4 of the
   parent gap. Wires the file-flag-drop into a Next.js route handler that
   matches the BEAST-MODE contract verbatim. Smaller follow-up gap, easier
   to test in isolation.
2. **`chump gap reject` CLI verb** — AC item 4 partial.
3. **Schema additions to `chump.fleet.yaml`** — declarative
   `require_hitl: true` field, parsed by `src/fleet_spec.rs`.
4. **`requires_human_approval` field on gap row** — would let preflight/claim
   refuse the gap pre-pickup (BEAST-MODE-faithful version of AC item 7).
   Current MVP gates at ship-time only; pick-time gating is the natural
   next slice.
