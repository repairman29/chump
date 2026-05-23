---
doc_tag: design
owner_gap: PRODUCT-NEW (canvas coordinator — see end of doc)
last_audited: 2026-05-14
status: proposal
---

# Chump Operator Console v2 — the canvas

> **Scope.** This doc proposes the next-generation PWA shell for `chump --web`.
> It supersedes the current 11-button feature-grouped nav with a four-cadence
> workflow-grouped surface, defines the four user archetypes the PWA serves,
> and resolves the three strategic decisions that gate all subsequent PWA
> work. The decomposition section at the end lists the gaps to file.
>
> **Not in scope.** Backend route changes (those land in the per-view gaps
> filed under the PWA arc). Tauri-specific work (the Tauri sidecar is opt-in
> per decision #3 below). Cognitive-control panel design (deliberately
> gated — see archetype 4 + decision #1).

## Mission framing

Chump exists to do agentic development **without** the constraints Claude Code
inherits from being locked to Anthropic:

- **Provider-agnostic.** OpenAI-compatible base URL, cascade slots, mistral.rs
  in-process, ACP for editor integration. Operators pick the LLM; the harness
  is the differentiator.
- **Offline-capable.** Air-gap mode is a first-class feature, not a side flag.
  Operators on local LLMs (qwen / llama / mistral) get the same workflow as
  operators on cloud models.
- **Fleet-native.** A single operator runs multiple agents in parallel via
  worktrees + leases + the gap registry. The Pi-mesh vision (`project_fleet_vision`)
  pushes this toward multi-host federation; the current single-machine model
  is temporary.
- **Auditable.** Every tool call, decision, and approval is on disk; every
  pillar (Effective / Credible / Resilient / Zero-Waste) is graded; the
  framework is defensible to a CTO.

The PWA is the **operator console** for this system. Today it confuses that
job with three other jobs (chat client, knowledge surface, settings page),
and the nav surfaces them as peer tabs. This doc fixes that.

## Who the operator actually is — four archetypes

The PWA must serve all four, but **archetypes 1 and 2 are the mission target**.
3 and 4 are acquisition channels and commercial gateways respectively.

### Archetype 1 — the offline solo dev (mission target)

**Profile.** Independent dev on an M-series Mac or a Pi cluster, running
`qwen2.5:14b` / `llama-3.1-70b` / `mistral-large` locally via ollama or
mistral.rs. Burned by cloud costs OR principled about sovereignty OR doing
work that legally can't leave the machine.

**Pain today.** Claude Code requires Anthropic. Cursor requires cloud. Aider
is line-editor-shaped, not agent-shaped. Most "local LLM agent" projects are
tech demos, not ship pipelines.

**What they need from the PWA.**
- Air-gap mode visible and provable — a green badge in the status footer,
  click → "no outbound network beyond GitHub since 14:00".
- First-run wizard that auto-detects ollama / mistral.rs / openai-compat at
  common addresses, picks one, says "ready."
- Cascade slot UI that explains *why* the local model was preferred over the
  cloud one (cost, RPD remaining, latency).
- Cost meter that shows **$0.00** prominently when actually offline — the win
  should be celebrated, not buried in JSON.

**Journey.**
```
install chump → chump init → PWA opens → first-run wizard detects qwen2.5:14b
  → "you're offline, ready to ship"
  → operator picks a TODO from their own repo → chump claim
  → agent works → PR opens → ship
  → status footer: "shipped 3 PRs today, $0.00 spent"
  → operator tells a friend
```

### Archetype 2 — the fleet operator (current dogfood)

**Profile.** Jeff today. Running 4–16 worker fleet on one machine. Cares
about throughput, waste rate, pillar grades, gap-queue health, lease
collisions, the merge queue.

**Pain today.** Operator awareness lives in 35 `chump` CLI commands + 61
coord scripts + `tail -f .chump-locks/ambient.jsonl`. The PWA surfaces a
sliver.

**What they need from the PWA.**
- `Now` view: what's claimed by whom right now, with last-heartbeat freshness
  + current workflow phase. (INFRA-1202, filed.)
- `Ambient` view: live tail of the firehose with kind filter + per-event
  drill-in. (INFRA-1198, filed.)
- `Health` view: pillar grades + KPI strip + SLO breaches + GraphQL budget.
  (INFRA-1203, filed.)
- `Coordination` view: inbox + INTENTs + PR-nudges in one pane. (INFRA-1204,
  filed.)
- One-click intervention buttons on every row: cancel lease, force-merge,
  override INTENT, release.

**Journey.**
```
operator opens PWA → status footer shows: 4 pillars green, fleet 4/4 green
  → `Now` shows 3 agents working, 1 silent
  → click silent agent → see its ambient tail → last event 12m ago
  → click "release lease" → ambient shows the release event firing
  → `Queue` shows the now-unclaimed gap → another worker picks it up
  → status footer stays green
```

### Archetype 3 — the Claude-Code dropout (acquisition channel)

**Profile.** Dev who's been on Claude Code for months, hitting
`--dangerously-skip-permissions` to keep flow, paying $20+/mo, frustrated
by tool-approval friction breaking attention, single-provider lock-in, no
way to run a fleet, no audit trail.

**Pain today.** They're already comfortable with agentic dev. The bar to
switch is "does Chump feel as good?" If the PWA is worse than CC's REPL,
they bounce in five minutes.

**What they need from the PWA.**
- Chat at parity with CC's REPL: SSE turn streams, inline tool approvals,
  attachments, session history. (We have all of these — they're fused
  awkwardly with the operator console.)
- Migration path: import Anthropic API key OR run local; their workflow
  shouldn't get worse on day one.
- ACP wired into Zed / JetBrains first-class. CREDIBLE-057 is the
  credibility test here.
- A "what the agent did" audit panel — every tool call, every approval,
  every COS decision. We have `/api/tool-approval-audit` and
  `/api/cos/decisions` but no UI.
- A reason to stay past chat parity: "you got 3 sessions running in
  parallel and CC can't do that."

**Journey.**
```
dev installs Chump alongside CC → connects same API key → does one chat turn
  → notices: SSE feels snappier, audit panel shows the diff BEFORE they
    hit accept, multi-session sidebar shows old sessions
  → tries fleet mode: spins up 2 workers on 2 toy bugs → 2 PRs in an hour
  → uninstalls CC the next week
```

### Archetype 4 — the enterprise auditor (commercial gateway)

**Profile.** Senior engineering manager or security-conscious team lead who
needs to defend "we let an AI commit code" to their CTO or a compliance
review. Not the daily user — but the gatekeeper.

**Pain today.** Most agent tools are trust-me-bro. No provenance, no
decision audit, no kill switch.

**What they need from the PWA.**
- Air-gap mode + bearer auth + tool-policy enforcement (`CHUMP_TOOLS_ASK`)
  all opt-in but defensible.
- Signed provenance per PR (INFRA-1123 — A2A Layer 4f, filed).
- Per-decision audit view showing the approval chain.
- Cost ceiling + kill switch with operator-tunable thresholds.
- A page they can screenshot for their CTO: "this fleet shipped N PRs,
  M were CI-green, 0 had unauthorized tool calls."

**Journey.**
```
manager runs Chump in a test repo → enables CHUMP_WEB_TOKEN +
  tool-policy=strict → cost budget $5/day → spins up 1 worker on a real ticket
  → opens `Audit` view → decision chain, every approval, every tool call
  → screenshots for next week's review → request approved → fleet runs in prod
```

## The canvas

Trash the current 11-button feature-grouped nav (Chat / Agents / Results /
Queue / Tasks / Decisions / Judgment / Events / Memory / Models / Settings).
Replace with **four cadences**, each a workflow stage:

```
┌─ NOW ──────────────────┬─ AMBIENT ───────────────┐
│ Chat (current session) │ Live event tail         │
│ My claimed gap         │ Fleet roster            │
│ Open tool-approvals    │ Active workflows        │
│ Recent ships           │ Coord (inbox/INTENT)    │
├─ LIBRARY ──────────────┼─ CONFIG ────────────────┤
│ Sessions transcript    │ Providers + cascade     │
│ Gap browser (filter)   │ Tool policy + approvals │
│ Roadmap + milestones   │ Repo / fleet size       │
│ Audit (decisions+tools)│ Air-gap + auth + budget │
└────────────────────────┴─────────────────────────┘

Persistent footer (always visible, every view):
[ ●qwen2.5:14b ] [ $0.00/0h ] [ ●AIR-GAP ] [ E:B+ C:A R:A Z:A ] [ ●FLEET 4/4 ] [ GHG:88% ]
```

### Cadence semantics

- **NOW** — foreground, attention-locked. Always shows what the operator is
  personally on the hook for. If a tool-approval interrupt arrives, it lands
  here. If the operator's claimed gap's workflow advances, the phase ticker
  updates here.
- **AMBIENT** — peripheral, the second-monitor view. SSE-driven tails +
  filtered fleet state. Polls only when SSE is closed. The view operators
  leave pinned.
- **LIBRARY** — reference, pull-based, low cadence. Sessions, gaps, audit,
  roadmap. Where you go when you want to *find* something.
- **CONFIG** — rarely-touched, never-during-flow. Providers, tool policy,
  fleet size, auth, air-gap, budget.

### The persistent footer — the operator HUD

Always visible across every view. One row. No nav cost.

| Slot | Source | What it shows |
|------|--------|---------------|
| Model | `/api/stack-status` → `llm_last_completion` | active model id + cascade slot |
| Cost | `/api/telemetry/cost` (INFRA-1012) | $X today / Yh elapsed |
| Air-gap | `/api/stack-status` → `air_gap_mode` | ● green if air-gap on, ○ grey otherwise |
| Pillars | `chump mission-grade --json` (planned, INFRA-1203) | E / C / R / Z letter grades, color per grade |
| Fleet | `/api/fleet-status` (planned, INFRA-1202) | N/M agents healthy, click → Now |
| GH budget | `gh api rate_limit` + cache | GraphQL % remaining, color thresholds |

Click any slot → drill into the corresponding LIBRARY or AMBIENT view. The
footer is the operator's instrument panel; the views are the gauges in
detail.

### First-run experience

**Canonical surface: `<chump-first-run-wizard>` (PRODUCT-108, `web/v2/app.js`).**

As of INFRA-1585 (2026-05-23) the PWA ships exactly ONE first-run surface.
The two legacy surfaces have been removed:

| Surface | Outcome |
|---------|---------|
| `<chump-welcome>` (PRODUCT-082, `web/v2/welcome.js`) | **Deleted.** The `welcome.js` module is now a <30 LOC stub that only runs the localStorage migration and defines no custom element. The body element and script tag are gone from `index.html`. |
| `<chump-ootb-wizard>` (`web/v2/ootb-wizard.js`) | **Tauri-specific steps folded** into `<chump-first-run-wizard>` via a `window.__TAURI__` detection branch. The Tauri-only rows (Ollama detection, native notification permission) render only when the Tauri runtime is present. The `<chump-ootb-wizard>` element tag is retained in `index.html` for Tauri's own full-screen OOTB setup flow (binary sidecar start), which runs before the PWA shell is interactive. |

**localStorage migration.** Users who completed the old `<chump-welcome>` flow
(`chump_first_visit` / `chump_first_visit_completed` keys set) are automatically
migrated: `ChumpFirstRunWizard#migrateLegacyWelcomeKeys()` runs on every
`connectedCallback` and writes `chump.firstrun.dismissed=true` so they never
see the new wizard again.

**`?welcome=force` override.** Appending `?welcome=force` to any `/v2/` URL
bypasses the dismissed flag. Useful for QA, demos, and the Playwright dedup
test (`e2e/tests/pwa-onboarding-consolidation.spec.ts`).

When the brain / heartbeat / repo trio is empty (no `chump-brain/`, no ship
heartbeat lines, no `current_repo`), the NOW view replaces its normal panels
with the **golden-path runner**:

```
WELCOME — let's get Chump ready.
[✓] Detected: qwen2.5:14b at http://127.0.0.1:11434
[✓] Detected: git repo /Users/jeff/projects/foo
[ ] Brain not initialized → [INIT BRAIN] one-click
[ ] No ship heartbeat → [START AUTOPILOT] one-click
[ ] No claimed gap yet → [BROWSE QUEUE]
[  Tauri only  ] Ollama ready → auto-detected via IPC
[  Tauri only  ] Native notifications → [Allow]
```

Each row links the relevant doc + offers a single-click action where safe.
When all steps are done or skipped, the checklist self-hides and stays
accessible via Config → Setup. Closes the brick-wall complaint where the
Dashboard today is "empty by design."

## Three strategic decisions

### Decision 1 — operator console with chat embedded, NOT chat with operator features

**Choice:** the PWA is an operator console first. Chat is one panel inside
NOW, not the centerpiece.

**Why:** the mission framing (offline-solo-dev + fleet) and the README's
verb taxonomy (reserve / claim / preflight / ship) point that way. Chat is
table-stakes for archetype 3; archetypes 1, 2, and 4 don't care about chat
parity, they care about awareness + control + audit.

**Implication:** the cadence nav above puts operator surfaces (Now /
Ambient) before reference + config. Chat is *within* Now, not a top-level
peer.

### Decision 2 — local-first, remote-capable

**Choice:** PWA binds `127.0.0.1` by default. Bearer auth + `0.0.0.0` bind
is one toggle in Config.

**Why:** archetype 1 (offline solo dev) is local-only by definition.
Archetype 2 (fleet operator) wants Tailscale-from-phone but not as default.
Archetype 4 (enterprise auditor) wants auth visible and provable. Making
the secure default the default builds trust; surfacing the toggle in
Config respects archetypes 2 + 4.

**Implication:** the existing `CHUMP_WEB_TOKEN` env var becomes a checkbox
in CONFIG → Auth with a clear "expose over Tailscale / shared network"
explanation. Default off. Click on → forces token-generation flow.

### Decision 3 — PWA primary, Tauri sidecar opt-in

**Choice:** PWA is the canonical operator surface. Tauri (`chump-desktop`)
stays as an opt-in for native notifications / tray / system-wide hotkeys.

**Why:** archetype 1's offline-solo-dev story works best in a browser (no
install friction, works from a phone on Tailscale, works on a Pi). Archetype
2 wants always-on awareness which Tauri's tray + native notifications
deliver better than browser permissions. Forking the surface forks the
work; keeping PWA primary keeps a single source of truth and lets Tauri
add value where it actually has it (system-level integration).

**Implication:** Tauri sidecar consumes the same HTTP routes as the PWA.
The Phase-2 native `emit` (contract only today) ships post-canvas, not as a
prerequisite. Per-view gaps build for the PWA; the Tauri shell wraps
whichever views the operator pins for native presentation.

## Composition with already-filed gaps

The PWA arc filed earlier this session (per `INFRA-1280`'s sibling list)
maps onto the cadence nav cleanly:

| Cadence bucket | Already-filed content gaps |
|----------------|----------------------------|
| **NOW** | INFRA-1196 (queue row PR-card + workflow-timeline embeds) — **MERGED**. Need: chat consolidation, claimed-gap drill, tool-approval tray. |
| **AMBIENT** | INFRA-1198 (events view), INFRA-1202 (agents roster), INFRA-1204 (coordination view). |
| **LIBRARY** | INFRA-1207 (roadmap view), INFRA-1209 (long-tail endpoint sweep — sessions transcript + brain graph + audit + watch). Add: gap browser + audit panel sub-gap. |
| **CONFIG** | INFRA-988 settings scaffold (MERGED). Add: tool-policy + fleet-size + air-gap toggle sub-gap. |
| **FOOTER** | INFRA-1203 (fleet-health → pillar quadrant slot). Pillars + cost + model + air-gap + fleet + GH budget all need a unified `<chump-status-footer>` component. |
| **STATE** | INFRA-1280 (persistence, MERGED) provides the `chumpPrefs` namespace + schema doc that every new toggle reads/writes through. |

This canvas doc gives the PWA arc gaps a coherent destination. Without it,
each view is filed-but-orphaned (which is what the current PWA feels like).

## The PRODUCT-NEW gap-set to file

To execute this canvas, file these gaps (priority + effort per pillar
balance + the dependency edges):

| ID (to-be-filed) | Title | Pillar / P / size |
|------------------|-------|--------------------|
| PRODUCT-NEW-CANVAS | EFFECTIVE: PWA navigation cadence rework — collapse 11-button nav to NOW / AMBIENT / LIBRARY / CONFIG four-cadence shell per OPERATOR_CONSOLE_V2.md | EFFECTIVE / P0 / m |
| PRODUCT-NEW-FOOTER | EFFECTIVE: `<chump-status-footer>` — persistent operator HUD (model / cost / air-gap / E:C:R:Z grades / fleet / GH budget) | EFFECTIVE / P1 / s |
| PRODUCT-NEW-FIRSTRUN | EFFECTIVE: PWA first-run golden-path wizard — replace empty-Dashboard with detect+init checklist (brain / autopilot / repo / model) | EFFECTIVE / P1 / m |
| PRODUCT-NEW-TOOL-TRAY | EFFECTIVE: PWA tool-approval tray — pull `tool_approval_request` SSE events out of chat scroll into a single tray with batch + policy-override + expired-deny-by-default | EFFECTIVE / P0 / m |
| PRODUCT-NEW-ACP-DEEPLINKS | EFFECTIVE: ACP deeplinks on every gap + PR row (`chump://acp/open?gap=X`) — competitive-differentiation surface vs Claude Code | EFFECTIVE / P1 / s |
| PRODUCT-NEW-AUDIT | CREDIBLE: PWA audit view — unify `/api/tool-approval-audit` + `/api/cos/decisions` into one chronological decision-chain panel for archetype 4 | CREDIBLE / P1 / m |
| PRODUCT-NEW-AIRGAP-BADGE | CREDIBLE: PWA air-gap mode badge + outbound-network audit page (no traffic since X) — archetype 1 trust signal | CREDIBLE / P2 / s |
| PRODUCT-NEW-COST-CEILING | CREDIBLE: cost-ceiling enforcement + kill switch with operator-tunable thresholds — composes with INFRA-1280 Sub-gap 7 (cost thresholds) | CREDIBLE / P1 / s |

**P0 budget impact:** CANVAS + TOOL-TRAY both rated P0. Current open P0
count is 0 (INFRA-1237 just merged) so this stays within the 5-P0 ceiling
per `CLAUDE.md`. The justification for each:

- **CANVAS P0** because every other PWA gap from here on either fits the
  cadence or doesn't, and we shouldn't ship more views into the wrong nav.
- **TOOL-TRAY P0** because tool-approval friction is the single biggest
  reason archetype 3 (CC dropout) bounces, and we have all the backend
  pieces — only the UI is missing.

## What this doc deliberately does NOT do

- It does **not** specify exact HTML / CSS / Web Component class names.
  Those live in each per-view gap's AC.
- It does **not** redesign the cognitive-control panel. Per archetype 4 +
  decision #1, that panel is research instrumentation, not load-bearing
  operator UX. Gate behind a "Lab" tab if surfaced at all.
- It does **not** prescribe Tauri features. Decision #3 keeps Tauri opt-in;
  any Tauri-specific work is filed as its own gap referring back to this
  doc for the canvas it wraps.
- It does **not** propose server-side multi-device preference sync. Per
  INFRA-1280's out-of-scope: localStorage-only for v1. If multi-device
  becomes a real ask, file `/api/preferences` separately.

## Living document conventions

- Any PWA gap filed from now on should declare its **cadence bucket** in
  the AC (NOW / AMBIENT / LIBRARY / CONFIG / FOOTER) so the nav implications
  are visible at filing time.
- Any new persistent preference goes through `chumpPrefs` and lands in
  `docs/api/PWA_STATE_SCHEMA.md` (INFRA-1280) before the PR that consumes it.
- Updates to this doc should bump `last_audited` and note the change in
  the relevant section. Use the `roadmap-status` doc-hygiene check.

## Open questions for the operator

1. **The CHAT panel inside NOW** — should it default to a *new* session or
   resume the last? Probably resume, with "new chat" as one click.
2. **MOBILE viewport** — the canvas above assumes desktop. On ≤640px the
   four-cadence layout should collapse to a tab bar at the bottom with
   the footer above it. Worth a dedicated sub-gap.
3. **THEME-aware status colors** — pillar grades are color-coded (green /
   amber / red); they need to remain WCAG-compliant in both light and
   high-contrast themes from INFRA-1280 Sub-gap 4.
4. **OFFLINE-first PWA install** — Service Worker is partially wired
   today (`sw.js`). Should the operator console install as a standalone
   PWA on iOS / Android so it survives a tab close? Yes — file as a
   composition gap with the manifest.json work.

---

*This is a living design doc. Update via PR with a short rationale section
("why this changed") at the top of the change.*
