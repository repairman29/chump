---
doc_tag: rca
incident_date: 2026-05-02
gap_refs: [INFRA-274, INFRA-216, INFRA-246, INFRA-273, FLEET-006]
last_audited: 2026-05-02
---

# RCA — PR #874 / #880 Cross-Host Same-Gap Collision

## TL;DR

Two agent sessions on different hosts independently shipped the same fix
(INFRA-261 trigger fix: `regenerate-gaps-yaml.yml` switching from
`merge_group:` to `push: branches: [main]`) within a 3-minute window.
PR #874 (mine) was closed as superseded by PR #880 (sibling's). Net
duplicated effort: ~30 minutes of investigation + scripting + PR cycle.

**Root cause: lease coordination is invisible across hosts.**
`.chump-locks/<session>.json` files live on the local host's filesystem
only. Sibling agents on different machines could not see each other's
claims. The intended cross-host visibility path (FLEET-006 NATS
dual-emit) is conditional and was not active on either host.

## Timeline

| Time (UTC) | Event |
|---|---|
| 17:32:43 | Sibling agent on host B starts work on INFRA-261, branches `chump/infra-261-fleet-1-20260502-173243` |
| 17:32:?? | I (host A) start work on INFRA-261, branches `chump/infra-261-fix-trigger-on-main` |
| 17:32–17:35 | Both agents independently write the same `.github/workflows/regenerate-gaps-yaml.yml` change (`merge_group:` → `push:branches:[main]`) and the same INFRA-236 step rewrite |
| 17:35:?? | Sibling pushes; PR #880 opens with 13 files (workflow fix + 12 sibling-bundled gap filings) |
| 17:39:?? | I push; PR #874 opens with 2 files (workflow fix + INFRA-261 gap filing) |
| 17:51:?? | Operator notices both PRs and asks "shouldn't we have only one of these?" |
| 17:52:?? | I close #874 with a supersession comment; sibling's #880 carries the trigger fix forward |

## What went wrong

The lease-coordination flow assumes lease files are visible to all
agents that might pick the same gap. In practice:

1. `gap-claim.sh` writes `.chump-locks/<session_id>.json` to the
   **local repo's** `.chump-locks/` directory.
2. `gap-preflight.sh` reads `.chump-locks/*.json` from the **local
   repo's** directory before allowing work.
3. `.chump-locks/` is gitignored — leases never propagate via git.
4. The intended cross-host channel — FLEET-006 NATS dual-emit — is
   **conditional**: it requires `chump-coord` on PATH AND a reachable
   NATS broker. Neither dispatch host had both today.

Result: my host's lease file was invisible to the sibling's
`gap-preflight.sh` check, and vice versa. Both `preflight` calls
returned OK independently. Both agents proceeded. Both shipped the
same fix.

## Why this is the root cause (not the proximate ones)

We have many proximate "same-gap collision" patterns filed:

- **INFRA-216** — `chump gap reserve` cross-host race (atomic ID picker
  doesn't `git fetch` first)
- **INFRA-246** — per-file YAML mid-flight collision (concurrent edit
  of `docs/gaps/<ID>.yaml`)
- **INFRA-273** (sibling-filed today) — gap-preflight should
  cross-check open PRs by gap-ID

Each of those is a real failure mode but **all of them flow downstream
of the same architectural gap**: there is no cross-host shared store
for lease state. INFRA-216 is a race because the ID picker can't see
sibling reserves. INFRA-246 is a race because the file-edit detector
can't see sibling edits. INFRA-273 is reactive because it queries
GitHub instead of a shared coordination channel.

**INFRA-274** captures the architectural fix: move leases to a shared
store (NATS KV is the recommended option, since FLEET-006 already
needs NATS for the dual-emit broadcasting). With a shared lease store,
INFRA-216 and INFRA-246 collapse into "the lease is the ground truth
for who's working on what."

## Why prior layers didn't catch this

- **INFRA-085** (chump-commit.sh auto-leases from commit message) —
  works only AFTER a commit is being made. Both sibling agents got to
  the commit phase; both wrote the same lease just-in-time; neither
  saw the other's lease (cross-host invisibility again).
- **INFRA-104** (PR title-vs-implementation drift detector) — runs
  AFTER the PR exists. It would have caught the duplicate via
  cluster detection on next nightly run, but only as a post-incident
  ALERT, not prevention.
- **INFRA-249** (recurring-gap-pattern detector) — same. Flags the
  cluster after the fact.
- **gap-claim.sh + gap-preflight.sh** — works correctly within-host,
  fails silently across-host.

## Recovery cost

- ~30 minutes of duplicated work on my side (writing #874's diff,
  rescuing it from the INFRA-272 path-filter trap, then closing it)
- ~0 minutes of operator time (caught it via casual visual scan of
  the PR list)
- ~0 minutes of sibling time (theirs landed cleanly)
- 1 superseded PR (#874)
- Latent: the diagnosis-trail in INFRA-261's gap row would have been
  lost if sibling hadn't independently created the same gap row in
  their PR

## Structural prevention

| Gap | Status | Role |
|---|---|---|
| **INFRA-274** | open, P0, m, just filed | The architectural fix: shared lease store (recommend NATS KV bundled with FLEET-006 made non-conditional) |
| INFRA-216 | open, P1, m | Add `git fetch` to atomic ID picker — closes one race window |
| INFRA-246 | open, P1, m | File-level lock or auto-rebase on `docs/gaps/<ID>.yaml` — closes a different race window |
| INFRA-273 | open, P1, sibling-filed today | Belt-and-suspenders: query open PRs by gap-ID at preflight time |
| FLEET-006 | shipped (conditional) | NATS dual-emit; needs to become non-conditional per INFRA-274 |

## Learnings (the "behavioral" half)

- **Cross-host coordination requires explicit infrastructure, not
  filesystem conventions.** Local FS leases work for single-host
  fleets only; the FLEET vision (per `project_fleet_vision.md`)
  assumes Pi mesh with multi-host distribution. Coordination model
  needs to match the deployment model.
- **Conditional infrastructure is invisible-fail infrastructure.**
  FLEET-006's "if NATS reachable, dual-emit; else file-only" was
  documented as a fallback. In practice, the fallback is the
  default, which means the cross-host story is "we don't have one."
- **Per AGENTS.md "Filing meta-patterns" doctrine**: this incident
  is the third time a "same-gap collision" caused rework this cycle
  (PR #765 vs sibling INFRA-130 enrichment; PR #800 INFRA-216
  verification race; PR #874 vs #880 trigger fix). Pattern matches —
  exactly why INFRA-249 (recurring-gap-pattern detector) was filed.
  When the detector runs nightly, this cluster will surface as
  "collision/lease/race" keywords.

## Action items

| # | Action | Owner | Tracked as |
|---|---|---|---|
| 1 | Implement INFRA-274 (shared lease store via NATS KV) | unclaimed | INFRA-274 |
| 2 | Make FLEET-006 NATS non-conditional for multi-host dispatch | unclaimed | INFRA-274 (bundled) |
| 3 | Implement INFRA-273 (PR-list pre-claim check as belt-and-suspenders) | sibling-filed today | INFRA-273 |
| 4 | Document this RCA in CLAUDE.md "If you spot a same-gap collision" troubleshooting section | unclaimed | (no gap yet — file as INFRA-275 if INFRA-274 lands without docs) |
