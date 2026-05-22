# PWA Cockpit Roadmap — PRODUCT-121

**Status:** v1.1 — Phase 1 partially shipped, doctrine added
**Owner:** the operator (currently Jeff)
**Date:** 2026-05-15 (updated end-of-day)

---

## Day-of-spec retrospective (added 2026-05-15 evening)

The principles below were authored at session start. By end of day **this
much had shipped or was in flight**:

| Phase | Item | Status |
|---|---|---|
| 1 | Cockpit landing shell (5-zone grid, 22-component composition) | ✅ merged (#2030) |
| 1 | Read/Signal/Noise intelligence layer | 🟡 in PR #2063 (auto-merge armed, sibling rebasing) |
| 1 | Wake-fleet + Dispatch-gap + Release-leases + Repair-drift action wires | 🟡 in PR #2063 |
| 1 | Operator-attention within-kind dedup | 🟡 in PR #2066 |
| — | Cockpit Action Model doctrine (7 rules) | ✅ merged (#2067) |
| — | Cockpit Synthesis algorithm spec | ✅ merged (#2067) |
| — | `target/` artifact reaper (disk-pressure fix) | 🟡 in PR #2083 |
| — | Failure-cascade docs in CLAUDE_GOTCHAS.md | ✅ merged (#2094) |

**What we learned that wasn't in the morning's spec:**

1. **"Intelligence vs surveillance" was a forcing function.** The operator's
   mid-day reaction ("this is just data, not intelligence") reshaped the
   center zone from "release notes + roadmap" lists into the Read/Signal/
   Noise framework. The framework only exists because that reaction
   happened on a real artifact.
2. **"Every surface answers 'do this now?'" became doctrine.** Captured in
   `COCKPIT_ACTION_MODEL.md` (7 rules + gap-review checklist). Rule 1 and
   Rule 2 ("direct action button; empty state IS the button") are the
   load-bearing ones — every cockpit gap reviewed against those.
3. **Bias mitigation has to be inspectable, not absent.** Documented in
   `COCKPIT_SYNTHESIS.md`: synthesis ladder, confidence calibration,
   counter-evidence requirement, evidence-on-demand, 🚩 wrong-card
   override. Operators can read exactly how the cockpit computes each
   card.

**What didn't ship:**

- PRODUCT-133 (right-zone action-first treatment) — filed, P2, blocked
  waiting for PR #2063's synthesis layer to land first
- INFRA-1349 target-reaper launchd install — script shipped but launchd
  job isn't running yet (operator-action item)
- Operator sign-off on Phase 1 ship-criterion ("operator reaches for
  cockpit before CLI in next 5 sessions") — pending real dogfood

---

---

## Why this doc exists

The PWA is the **operator cockpit** — the surface where a human drives the
autonomous fleet. Today there are ~17 open PWA-targeted gaps, picked in
whatever order the picker found easiest, and 22 components already shipped to
`web/v2/`. That's plenty of parts and no shape.

This roadmap gives the parts a shape: four named phases, each with a
ship-criterion the operator signs off on. Every existing PWA gap maps to a
phase. The picker works phases in order. Pure-polish work demotes inside its
phase — the *phase* stays P1.

**The PWA is the dogfood loop.** If the operator doesn't reach for it instead
of `claude code` in a terminal, Chump fails as a product. The cockpit-MVP
phase below is the *minimum* surface where the operator does reach for it.
Everything after that earns its priority by making that reach more frequent or
more pleasant.

---

## Cockpit principles

These guide every PWA decision; gaps that violate them get demoted.

1. **Operator-first, not fleet-first.** The PWA shows what the *human* needs to
   decide or notice, not everything the fleet is doing. Ambient stream is a
   detail panel, not the front page.

2. **Action over information.** Every surface answers "what should I do?"
   first, "what happened?" second. Dashboards without actions are dashboards
   that don't get opened.

3. **One reach, one decision.** Operator attention is the bottleneck. Each
   view should let the operator make a decision (approve, handoff, ack,
   dismiss) without context-switching to GitHub, the CLI, or another tab.

4. **Beautiful is load-bearing.** "Internal tool that ships" and "product
   worth using" are different bars. If the operator doesn't enjoy the cockpit,
   the dogfood loop breaks. Visual polish in the cockpit-MVP phase is *not*
   nice-to-have.

5. **Local-first stays visible.** Show when work is running offline, when it
   used remote, what it cost. Operator should always know which side of the
   privacy boundary their fleet is on.

---

## Current state — what's already shipped

`web/v2/` contains 22 components. Inventory (informal):

| Component | Surface |
|---|---|
| `app.js` | Shell, routing |
| `ambient-viewer.js` | Ambient stream tail |
| `autopilot-toggle.js` | Start/stop fleet (PRODUCT-115) |
| `chat.js` | Operator chat with active agent |
| `cost-meter.js` | $/hr + token spend |
| `error-ux.js` | Error toasts |
| `fleet-message.js` | Broadcast composer (PRODUCT-103) |
| `fleet-sidebar.js` | Fleet roster |
| `inbox.js` | Per-operator inbox (PRODUCT-104) |
| `inbox-notifications.js` | Inbox badge + toasts (PRODUCT-105) |
| `inference-profile.js` | Per-slot model settings |
| `notification-center.js` | Generic notification surface |
| `ootb-wizard.js` | First-run onboarding |
| `operator-attention.js` | Attention queue (PRODUCT-117) |
| `pillar-health.js` | Pillar grades |
| `pr-card.js` | PR row card |
| `prefs.js` | Settings |
| `quick-actions.js` | Verb-shaped nav (PRODUCT-083) |
| `sw.js` | Service worker (Web Push) |
| `welcome.js` | Splash |
| `workflow-timeline.js` | Per-gap timeline |

**The infrastructure exists.** The gap is composition + taste + the "I
reach for this instead of CLI" feel.

---

## Phase 1 — Cockpit-MVP (P1, ship next)

**Operator sign-off criterion:** *The operator opens the PWA at the start of
every session instead of running `chump gap list` + `tmux attach`. The PWA
answers the three first-thing questions without scrolling.*

The three first-thing questions:

1. **What needs my attention?** — pending approvals, stuck agents, expired
   leases, FEEDBACK flagged for me.
2. **What did the fleet do since I last looked?** — last-N shipped PRs, last-N
   FEEDBACK items, last-N stalls.
3. **What's running right now?** — active agents, what they're working on,
   estimated time to next decision-point.

### Scope

A single landing view that composes existing components into a cockpit:

- Top bar: cost-meter + pillar-health badges + autopilot toggle.
- Left column: operator-attention queue (PRODUCT-117) + inbox preview.
- Center: "since you were away" daily-brief (PRODUCT-078).
- Right column: active-fleet roster + ambient tail (collapsible).
- Footer: quick-actions verb nav (PRODUCT-083).

### Existing gaps in this phase

| Gap | Effort | Role in phase |
|---|---|---|
| PRODUCT-115 (P0) | xs | Autopilot toggle — already implemented; verify wired to landing |
| PRODUCT-117 | s | Operator-attention queue — *the* left-column primary |
| PRODUCT-078 | m | "While you were away" daily brief — *the* center primary |
| PRODUCT-083 | s | Verb-shaped nav — footer composition |
| PRODUCT-080 | s | Stuck items alerter — feeds attention queue |
| INFRA-1303 | s | `/docs/*` REST endpoint — needed for help/about links |

### What does NOT belong in Phase 1

- PR diff renderer (Phase 2)
- Outcome dashboard / impact aggregation (Phase 3)
- Onboarding wizard (Phase 4)
- Inference-profile editor (already shipped; settings live behind a gear icon)

### Ship criterion (mechanical)

- Operator opens `http://localhost:3000/v2/` and sees a coherent cockpit
  layout, not 22 disconnected components.
- All three first-thing questions answered above the fold on a 1440×900
  viewport.
- Operator confirms (FEEDBACK kind=preference vote=+1) they reach for the PWA
  before the CLI in the next 5 sessions.

---

## Phase 2 — Inbox & PR Loop (P1 after Phase 1 ships)

**Operator sign-off criterion:** *The operator approves/revises/merges PRs
from the PWA without opening github.com.*

GitHub round-trips are the single biggest context-switch in the operator's
day. Closing this loop turns the PWA from "monitor" into "control plane".

### Scope

- PR list view (PRODUCT-084) — replaces the `gh pr list` reach.
- PR diff renderer with AC-fit overlay (PRODUCT-085) — inline review.
- PR action panel (PRODUCT-086) — approve / revise / revert / comment via `gh`
  shelled from the server.
- Gap browser (PRODUCT-102) — scrollable filter table; needed to *trigger*
  work from the cockpit, not just react to it.

### Existing gaps in this phase

| Gap | Effort |
|---|---|
| PRODUCT-084 | s |
| PRODUCT-085 | m |
| PRODUCT-086 | s |
| PRODUCT-102 | m |

### Ship criterion

- Last 5 PRs approved + merged from PWA without opening github.com.
- Diff view shows AC checklist alongside file changes.

---

## Phase 3 — Fleet Grading & Outcome (P2)

**Operator sign-off criterion:** *The PWA tells the operator how the fleet is
doing against the 4 pillars in plain language, not just numbers.*

This is where the PWA becomes a credibility surface (and connects to the
public dashboard, CREDIBLE-068).

### Scope

- Outcome dashboard (PRODUCT-081) — impact today: PRs merged, FEEDBACK
  resolved, waste avoided.
- Pillar health visualization — interpret `chump health --slo-check` into
  plain-language grades.
- Per-slot inference metrics (PRODUCT-055) — latency, tok/s, $/req.
- Parallelism governor view (PRODUCT-060) — current fleet-size + decision
  channel inbox.

### Existing gaps in this phase

| Gap | Effort |
|---|---|
| PRODUCT-081 | m |
| PRODUCT-055 | s |
| PRODUCT-060 | s |

### Ship criterion

- Operator can answer "is the fleet healthy?" in under 5 seconds.
- Outcome dashboard data feeds CREDIBLE-068 public dashboard.

---

## Phase 4 — Demo Mode & Polish (P2-P3)

**Operator sign-off criterion:** *A first-time visitor can open the PWA in a
demo state, walk through the cockpit, and form an opinion in 5 minutes.*

This phase makes the cockpit pitch-ready. Connects to CREDIBLE-069 (demo
repo) and PRODUCT-120 (landing page).

### Scope

- Local-only onboarding wizard (PRODUCT-087) — Ollama setup + first-fleet
  walkthrough.
- Top-bar overlap fix on narrow viewport (INFRA-1276) — *demoted to P3 inside
  this phase*; nice but not pitch-blocking on 1440px.
- Demo-mode flag — synthetic ambient stream + sample gaps for screencast
  recording.

### Existing gaps in this phase

| Gap | New Pri | Effort | Note |
|---|---|---|---|
| PRODUCT-087 | P2 | m | Stays P2 |
| INFRA-1276 | **P3 ↓** | m | Polish, not pitch-blocking |

### Ship criterion

- New-user walks the demo flow without operator intervention.
- Demo-mode screencast recorded for CREDIBLE-069.

---

## Demotions (inside-phase, not pillar)

Per the cockpit principles: pure-polish demotes within its phase. The
*phase* stays at the priority listed.

| Gap | Old | New | Rationale |
|---|---|---|---|
| INFRA-1276 | P2 | P3 | Top-bar overlap on narrow viewport — visual polish, not first-thing-question. Stays in Phase 4. |

Other gaps stay at their current priority. Bumping is **PRODUCT-115** which
is already P0 and Phase 1.

---

## What does NOT go in any PWA phase

Things called "PWA" by accident or tag-collision:

- **INFRA-1142** — per-job path filters in `ci.yml`. CI infrastructure, not
  PWA. Stays in INFRA backlog.
- **INFRA-1285** — `chump gap show --yaml` colon-escaping. CLI bug. Stays in
  INFRA.
- **FLEET-037** — `chump fleet` subcommand CLI ergonomics. CLI, not PWA.

These should not show up under "PWA work" in pillar-balance.

---

## Operator sign-off checklist

Before any Phase 1 work picks up, the operator confirms:

- [ ] The three first-thing questions (above) are the right three.
- [ ] The Phase 1 left/center/right layout matches what the operator wants
      to see at session start.
- [ ] The Phase 1 ship criterion ("I reach for the PWA before the CLI in the
      next 5 sessions") is the right test.
- [ ] PR loop (Phase 2) is the right next phase after cockpit-MVP.
- [ ] Demotion of INFRA-1276 to P3-within-Phase-4 is acceptable.
- [ ] Phases ship in order; no leapfrogging Phase 1 just because a Phase 3
      gap is easier to pick.

Sign-off recorded as a FEEDBACK kind=preference vote=+1 from the operator
with subject=`PRODUCT-121 phase 1 scope`.

---

## How the picker uses this

1. The picker filters open PWA gaps by phase tag (added via `chump gap set
   --add-note "PWA phase: 1"`).
2. Phase 1 gaps win over Phase 2+ gaps regardless of effort.
3. Within a phase, normal priority + effort rules apply.
4. When all Phase 1 gaps are closed AND the operator has signed off the
   Phase 1 ship criterion, the picker advances to Phase 2.

Phase progression is gated on **operator sign-off**, not on gap count. A
phase isn't done because the gaps closed; it's done because the operator
says the cockpit-MVP works.

---

## Related work

- **CREDIBLE-068** — Public dashboard reuses Phase 3 outcome data.
- **CREDIBLE-069** — Demo repo reuses Phase 4 demo-mode flag.
- **PRODUCT-119** — External dogfooders need Phase 1 + Phase 2 before
  recruitment.
- **PRODUCT-120** — Landing page embeds a Phase 3 dashboard widget.
- **INFRA-1335 / 1336 / PRODUCT-048** — IDE extensions are *contributor*
  surfaces; they consume the same `/api/inbox` + `/api/broadcast` endpoints
  but do not replace the cockpit.

---

## Open questions for operator

1. Is the cockpit-MVP layout (left=attention, center=brief, right=fleet+ambient)
   the right composition, or is there a better mental model?
2. Should ambient stream be on the cockpit by default, or always collapsed
   behind a "details" toggle?
3. What's the right "I reach for this" verification — 5 sessions feels right
   but might be too low or too high.
4. Demo mode: is a synthetic fixture acceptable, or should demos always run
   against a real (sandboxed) fleet for credibility?

---

## How we work (PWA team — 2026-05-17)

> **Origin.** 2026-05-14 commit c64ddd676 silently shipped 5 truncated PWA
> classes; bug went unnoticed for 3 days because the PWA had no domain
> owner + no CI gate parsing `web/v2/app.js`. INFRA-1620 / 1621 / 1622 / 1623
> are the durable fix. This section documents how the team works going forward.

### Naming convention (every PWA gap)

Title prefix names the slice:

| Prefix | Means |
|---|---|
| `PWA-FRONTEND:` | Touches `web/v2/*.js` / `web/v2/*.css` / `web/v2/*.html` |
| `PWA-BACKEND:` | Adds or changes `/api/...` endpoint in `src/web_server.rs` |
| `PWA-TEST:` | Smoke / e2e / parse-gate work under `scripts/ci/test-pwa-*.sh` or `e2e/` |
| `PWA-INFRA:` | CI gates, build, deploy, runner-routing for PWA work |
| `PWA-DESIGN:` | Updates to `docs/design/OPERATOR_CONSOLE_V2.md` or component-level UX spec |

### Decomposition pattern

Every PWA epic (effort `m` or larger) decomposes at **claim time**, not at
filing time. File the epic with a rough shape in the `description` field:

```
Rough shape:
  (a) Backend: /api/audit endpoint returns {rows: [...]} from .chump/decisions.db
  (b) Frontend: <chump-view-audit> component + nav entry + filter chips
  (c) Test: scripts/ci/test-pwa-audit-view.sh smoke + e2e/audit.spec.ts
  (d) Infra: parse gate already in pr-hygiene (PWA-INFRA INFRA-1621)
```

When a worker claims, they run `chump gap decompose <ID>`. It reads the
description as context and produces concrete sub-gaps against the *current*
codebase. Better than pre-slicing because the codebase shifts between filing
and pickup.

### Worker pool

`scripts/dispatch/run-fleet.sh` automatically tags the first 2 workers in any
fleet launch with `WORKER_SKILLS=pwa,frontend,javascript` (the picker at
`scripts/dispatch/_pick_and_claim_gap.py:492` reads `WORKER_SKILLS` and filters
gaps by `skills_required` affinity). PWA-tagged workers preferentially pick
PWA-tagged gaps; non-PWA workers stay clear unless the PWA pool is idle.

| Worker pool | `WORKER_SKILLS` | Picks up |
|---|---|---|
| general (default) | unset / "any" | any gap without specialty skills |
| **PWA-tagged (workers 1-2)** | `pwa,frontend,javascript` | PWA-* prefixed gaps + skill-tagged |
| backend-tagged (existing) | `rust,axum,sqlite` | server gaps |

**Operational knob:** `CHUMP_PWA_WORKERS=N` at fleet launch overrides the
default of 2. Set to `0` to disable PWA tagging entirely (e.g. when the PWA
backlog is empty and you want all workers as general).

**Skills mapping for new PWA gaps** (set at filing time via
`chump gap reserve ... --skills-required <csv>` or after via
`chump gap set <ID> --skills-required <csv>`):

| Title prefix | `skills_required` |
|---|---|
| `PWA-FRONTEND:` | `pwa,frontend` |
| `PWA-BACKEND:` | `pwa,backend,rust` |
| `PWA-TEST:` | `pwa,test` |
| `PWA-INFRA:` | `pwa,ci` |
| `PWA-DESIGN:` | `pwa,frontend` (designer-flavored) |

**Fallback behavior:** when no PWA-tagged worker is available and a PWA gap
sits in queue >30 min, the picker relaxes the skill filter and any worker
can pick it up. This keeps the queue moving when the PWA pool is offline.

### Verifying PWA routing in flight

```bash
# Confirm the picker sees the skills affinity (use any open PWA gap)
WORKER_SKILLS=pwa,frontend,javascript python3 scripts/dispatch/_pick_and_claim_gap.py \
    --dry-run --owner test-worker 2>&1 | head -20

# Confirm fleet workers 1-2 carry the tag (after run-fleet.sh has spun up)
tmux capture-pane -p -t fleet-chump:fleet.0 | grep WORKER_SKILLS

# Count PWA gaps by skills coverage
chump gap list --status open --json | jq '[.[] | select(.title | test("PWA"; "i")) |
    {id, skills: (.skills_required // "(unset)")}] | group_by(.skills) |
    map({skill: .[0].skill, count: length})'
```

### Gates that protect PWA work

Three layers, all required-checks once stable (per `ROADMAP_WAVES.md`):

1. **Parse gate** (`node --check web/v2/app.js`) — INFRA-1621.
   Catches the c64ddd676 truncation class of bug in 1 PR.
2. **AC coverage gate** — INFRA-1541.
   Blocks merge when PR diff doesn't cover the gap's AC bullets.
3. **Broad canary** — INFRA-1568.
   Only fires when a PWA change touches a new runner lane.

### Ownership rule

Until the PWA team is more than 1-2 workers, PRs touching `web/v2/*` need:
- Either auto-approval via the Wave-0 gates (parse + AC + broad canary), OR
- A PWA-tagged worker as the picker (which the picker enforces automatically
  via `skills_required`)

This prevents the "non-PWA worker picks a PWA gap, ships broken JS, gates
don't catch a subtle bug" mode.

### Related gaps (live "team backlog")

- **INFRA-1620** — rebuild 5 truncated PWA classes (audit / network-audit / fleet-health / coord / roadmap)
- **INFRA-1621** — parse gate in pr-hygiene
- **INFRA-1622** — wire WORKER_SKILLS + backfill `skills_required`
- **INFRA-1623** — formalize this section into `docs/process/PWA_TEAM_CONTRACT.md` if it grows

### Cross-references

- [`docs/design/OPERATOR_CONSOLE_V2.md`](../design/OPERATOR_CONSOLE_V2.md) — UX spec
- [`docs/process/PWA_DEPLOYMENT.md`](../process/PWA_DEPLOYMENT.md) — deploy runbook
- [`docs/strategy/ROADMAP_WAVES.md`](../strategy/ROADMAP_WAVES.md) — what wave PWA gaps belong to
- [`CLAUDE.md` → Mission Driver](../../CLAUDE.md#mission-driver--every-session-not-just-when-asked) — pillar balance + EFFECTIVE bias when plumbing is healthy
