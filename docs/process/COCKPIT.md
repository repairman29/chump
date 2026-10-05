# ChumpOS Daily Cockpit — the one surface we actually use

*docs/process/COCKPIT.md · receipt-grounded · this doc is a spec, not a status page*

## 1. Verdict

**Build ONE static page — "The Manual, Live" — served by `chump-fleet-server` at `/` on cuphead, bound to tailnet, fed entirely by that server's existing JSON + WS on every load.** Reading order is doctrine-first, not throughput-first: **north-star → doctrine-as-live-gauges → roadmap → attention → durable corpus.** The page owns no truth. Delete it, lose nothing. Two new backend endpoints, max. No hand-authored state, ever — that reflex is what produced the orphans this replaces.

Why doctrine-first and not cockpit-first: the operator is the **Board/Chair, not ATC** (`i-am-the-board-chief-of-staff`, `keep-atc-alive-not-be-atc`). The fleet already ships autonomously and pages on stall via Discord (`autonomy-silence-unless-stalled`), so "is it moving?" is largely answered by silence. The daily job is **aim** — is the autonomous fleet still pointed at doctrine and at a real person? And the crown risk is **anti-Memento**: re-solving solved problems for 2000 PRs because fixes decay when not enforced-and-watched. A throughput cockpit shows green while the fleet re-solves the same thing. A live-annotated operating manual makes "are we still honoring the fix we made" a daily gauge — the missing muscle. From the cockpit-first design we keep its discipline: a frozen ~7-gauge set, a two-endpoint backend ceiling, and a phased build that ships against already-live endpoints first.

## 2. Foundation we reuse

**`chump-fleet-server`** (`crates/chump-fleet-server/`) — the only surface that is simultaneously live, on owned iron, systemd-supervised, auto-refreshed on HEAD move, and already serving real JSON. Verified live on cuphead: `chump-fleet-server.service active running` + `-refresh.timer` (30m, RESILIENT-1046) + `-health-sentinel.timer` (5m); `ss` → `LISTEN 127.0.0.1:7070`; `/api/dashboard-summary` returns real data.

Reuse, don't rebuild:
- **web/v2 design tokens** (`web/v2/index.html` `:root`, light/high-contrast, INFRA-1280) and **`web/v2/cockpit.js`** grid — as *reference for the skin and layout only*. Do **not** adopt web/v2 components: they bind to a phantom PWA backend (`/api/fleet-status|autopilot|chat|impact|brief`) that no crate serves.
- **The `render-vital-signs.sh` / `render-third-peer.sh` JSON contract** (`scripts/ops/`) — the `p_full_trek` hero, signs grouped `flow|quality|waste|trust|autonomy|mission`, each with status/threshold/`treatable_action`, **unwired ⇒ grey "unknown", never fake-green.** Lift the *contract* behind a live endpoint; retire the HTML-rendering-on-a-timer path (a timer-rendered snapshot is born stale — the exact failure mode).

Three gaps the foundation is missing (file as gaps, dispatch — don't hand-crank, per `ship-hand-cranked-fixes`):
1. **No static serving.** `build_router` has no `ServeDir`; `/` 404s; no `tower-http` dep. → add a `ServeDir` mount at `/`. Also **delete the stale `/scrubber` help claim in `main.rs`** — it advertises a mount that doesn't exist (`curl /scrubber` → 404).
2. **Localhost-only.** `CHUMP_FLEET_SERVER_BIND` unset. → set to tailnet IP (`resolve_bind_ip`, RESILIENT-1030, already tested — one env var).
3. **Reads are unauthed.** `events/segments/dashboard-summary/live/fleet/nodes` are open; only mutating routes + `/api/gaps` are Bearer-gated. **Safe only on tailnet.** No public bind without read-auth.

**Hosting: serve from fleet-server, expose over tailnet. $0, owned, zero new infra.** Reject Vercel — a static Vercel page can't reach `127.0.0.1:7070`, so it forces public API exposure + CORS + read-auth we don't have, recreating the orphan-rot this exists to kill. Reject Tauri/web/v2 as the *shared* surface — it needs a local `chump --web` per box. Keep web/v2 as the desktop app; this page is the shared web cockpit.

## 3. The daily surface

One screen, no scroll, no tabs, no config. Every tile carries an **age stamp**; any tile past its freshness window renders **grey/red so a rotted number looks broken.** Fixed gauge set — a new metric evicts one, never appends.

```
┌─ NORTH STAR / COVENANT ─────────────────────────────────── age ─┐
│  "tools people need for basic life and success"  (FIRST_MATE.md) │  ← biggest, top-left
│  PERSONS SERVED   [ unknown · 0 ]                                 │
│  the one real-user signal — Olive beta session / savings ledger  │
│  p_full_trek  ▓▓▓▓▓░░░░░  0.5x     hands-off-from-clean-install   │
└───────────────────────────────────────────────────────────────────┘
┌─ HOW WE RUN  (doctrine as live compliance gauges) ─────── age ─┐
│  merged≠running   nodes  cuphead● mugman? cj?   (1 of 3 report) │
│  manage-PRs-casino   EV band __ · Brier __                       │
│  silence-unless-stalled   stalled PRs (>4h): 0                   │
│  gaps-are-truth   open · blocked 588 · in-flight · Δcreate−close │
└─────────────────────────────────────────────────────────────────┘
┌─ WHAT WE'RE BUILDING ──────────────────────────────────── age ─┐
│  ROADMAP top items (docs/ROADMAP.md @ HEAD) + live gap status    │
│  ships/24h 3 · CI/QA 100% (n=50) OK   who's-working: leases ___  │
└─────────────────────────────────────────────────────────────────┘
┌─ ATTENTION  (humans only — EMPTY = HEALTHY) ───────────── age ─┐
│  • N decisions waiting on Jeff        [→ TODO.md]                │
│  • stalled PR >4h  INFRA-xxxx         [→ trace]                  │
└─────────────────────────────────────────────────────────────────┘
  DURABLE CORPUS (links, never copies):
  FIRST_MATE · CLAUDE.md · covenant · NORTH_STAR · MISSION_YIELD ·
  FACTORY_ORG_MODEL · node roster · third-peer ledger · BOARD_PULSE archive
```

Each panel and its **live** source:

| Panel | Source | Notes |
|---|---|---|
| **Persons served** (hero) | `GET /api/mission` | Empty today → honest **"unknown · 0"**. The north star leads even while dark — that emptiness at the literal top is the daily pressure. |
| **Covenant line** | `FIRST_MATE.md` @ git HEAD | Rendered, never typed. |
| **p_full_trek + pillar signs** | **new `GET /api/vital-signs`** ← faculty-collector | Adopts the vital-signs contract; unwired signs render grey. |
| **nodes (merged≠running)** | `GET /api/fleet/nodes` | Today `node_count:1`. **Must show mugman/CJ as `?`/missing, not hide them** — status = activation on the node, per `merged-not-running-disease`. |
| **casino EV + Brier** | `GET /api/events?kind=pr_book_odds` | pr-book already emits into ambient (`scripts/coord/pr-book.sh`). No new casino endpoint. |
| **stalled PRs** | `/api/events` / `/api/trace/pr/{n}` | Only BLOCKED >4h. Empty = healthy. |
| **gap pulse** | **new `GET /api/gap-pulse`** — one canonical `state.db` query | Resolves the split-brain vocab (`in-progress` vs `in_progress`, `closed` vs `closed_not_a_bug`, `gap-store-split-brain-swamp`). Emit open/blocked/in-flight + Δcreate−close. **Never a raw total.** |
| **ships/24h + CI/QA** | `GET /api/dashboard-summary` | `today_ships`, `ci_qa_score{pct,sample_size,status}` — live now. |
| **roadmap items** | `docs/ROADMAP.md` @ HEAD + gap status | Rendered from git, annotated live. |
| **who's working** | `dashboard-summary.active_leases` + `/api/sessions/active` | Live now. |
| **decisions waiting** | count from `~/Projects/TODO.md` | Flags "N waiting", **links out** — never holds the decisions. |
| **live tick / age stamps** | `WS /api/live` | Drives freshness; no client polling storm. |

New backend delta: **exactly two endpoints** (`/api/vital-signs`, `/api/gap-pulse`) + wiring `/api/mission` to actually emit. Nothing else.

**One-click-deep** (linked, not on-surface): `/api/trace/pr/{n}`, `/api/events` stream, third-peer capability ledger, the strategy corpus, the BOARD_PULSE tick archive, per-gap detail.

## 4. Wiki integration

Durable knowledge is **rendered from repo files at HEAD, never forked into the page.** Add a `/docs/*` route on the same fleet-server that renders `docs/ROADMAP.md`, `FIRST_MATE.md`, `CLAUDE.md`, `docs/strategy/{NORTH_STAR,MISSION_YIELD,FACTORY_ORG_MODEL,RUN_THE_BUSINESS}.md`, node roster, and runbooks straight from git — so it cannot drift.

Separation is **by volatility, not topic:**
- **Live pane** = state that changes *without a human* (fleet health, ships, gaps, gauges). Fetched every load. Read-only. If it's wrong, fix the *source*, not the page.
- **Wiki** = durable knowledge that changes *only when Jeff decides something* (doctrine, north-star definition, roster, runbooks) — a rendered *view* of files that already exist.

A live tile links *into* the doc that defines it (`blocked 588` → the doc explaining what blocked means). Do **not** serve `~/Projects/Chump/docs-site/` (stale mdBook HTML, Apr 22, 548KB `print.html`) — render the markdown source.

## 5. No-bloat guardrails

**The load-bearing rule: the page stores nothing it can't regenerate.** Live comes from APIs; durable comes from repo files rendered as views. **Delete-test — delete the page, lose zero truth.** Anything that fails that test doesn't belong. This is the single difference between an instrument and the 14th orphan.

**The addition rule:** the gauge set is **frozen at ~7.** A new metric earns a gauge only by *evicting* one — never by appending. New telemetry with no live feed does not get a tile. Every element is a number, a color, an age, or a link — **never a paragraph of human-typed prose.**

**EXCLUDE, explicitly:**
- **PR *count* as a success metric** — a lie by our own doctrine (`manage-prs-like-your-life`). Show P(merge)/EV/Brier.
- **Historical trend charts nobody acts on** — link to `chump kpi report`, don't embed.
- **Per-repo detail** — link to almanac, don't render.
- **Any human-typed "current status" prose** — the #1 orphan-maker.
- **Any tile without a live feed; any customization/config UI; tabs-of-tabs; per-user layouts.**
- **web/v2 cockpit tiles** hitting `/api/fleet-status|autopilot|chat|telemetry/cost|impact|brief` — no crate serves them; they render empty.
- **Full doc bodies inline** — link/expand-on-click only.
- **Completeness creep** — every added tile halves the glance-value of the rest.

## 6. Migration — retire the orphans

Honest correction to the "13 orphans" brief: `grep -ilE "prime operating state|tote board|self-improving job"` across all Chump dirs hit **zero HTML** — only strategy `.md` and gap YAMLs. Those named pages were already removed or live under other filenames. **Don't invent a migration list.** What is real and orphaned:

**Salvage-into-docs first (the thinking, not the HTML):** any real idea trapped in an orphan roadmap/system-map page gets folded into durable markdown (`docs/ROADMAP.md`, `docs/strategy/*`) as source — then the surface renders it. Never migrate one orphan HTML into another. Salvage as *parts*: web/v2 `:root` tokens + `cockpit.js` grid (reference only); the vital-signs/third-peer JSON contract (behind `/api/vital-signs`); the faculty-collector as the feeder.

**Just drop (retire as surfaces):** `web/v2/` as a *web* surface (keep as Tauri desktop app), `web/cockpit/*` (phantom-backend panels), `web/fleet-scrubber/` (fixture demo; its `/scrubber` mount is dead), `docs/landing/` (marketing), `~/Projects/Chump/docs-site/` built HTML, and any `visuals/html/*` / `scratchpad_*.html` / `content/launch-console.html`.

**Root-cause fix (helsinki decay, `helsinki-DECOMMISSIONED` + `fleet-stall-musher-stale-source`):** `scripts/coord/board-tick.sh` is hardcoded `HOME=/home/jeff` + `cd ~/Projects/chump` — dead paths on cuphead (`ubuntu@:~/chump`). The daily instrument runs against a nonexistent path today. File a gap to make it host-agnostic (`~/chump`); this is the roster-decay class to kill.

## 7. Build plan

**Phase 1 — smallest shippable cut (one owner, one PR through the gate).** The smallest thing that beats `ssh + curl` for the morning question and is live-not-stale:
1. Add `tower-http` + a `ServeDir` route at `/` to `chump-fleet-server` serving `web/cockpit-live/index.html`; delete the stale `/scrubber` help string in `main.rs`.
2. Ship one static `index.html` (web/v2 tokens) binding **only endpoints that already return real data**: `/api/dashboard-summary` (ships, CI/QA, leases), `/api/fleet/nodes` (nodes shown honestly, 1-of-3), `/api/events?kind=pr_book_odds` (casino line), `WS /api/live` (age stamps) — plus renders **two durable files** from HEAD: the covenant line (`FIRST_MATE.md`) and `docs/ROADMAP.md`. North-star tile renders **"unknown · 0"** from empty `/api/mission`. Gap-pulse + pillar tiles render grey until Phase 2.
3. Set `CHUMP_FLEET_SERVER_BIND` to the tailnet IP.

Phase 1 adds **zero new backend beyond the static mount** — every tile is a live endpoint that already returns data or an honest grey. It's an instrument on day one.

**Phase 2 — light the grey tiles.** `GET /api/gap-pulse` (one canonical `state.db` query, fixes split-brain vocab) → queue tile. `GET /api/vital-signs` (faculty-collector → contract JSON) → p_full_trek + pillar signs. `/docs/*` markdown route → folds in the wiki. Fix `board-tick.sh` host-assumption so the collector runs on cuphead.

**Phase 3 — only by earning it.** Per-node `systemctl is-active` roll-up (mugman/CJ actually reporting), third-peer ledger surfacing, board-tick verdict inline — each added only by evicting a gauge or clearly earning one.

**Needs Jeff (human-only decisions):**
- Confirm tailnet-only is the intended reach (Mac + phone over Tailscale) vs. any wider exposure — a wider bind requires read-auth first, which is out of scope for Phase 1.
- Name the **one real north-star signal** for "persons served" — Olive beta session? savings-ledger dollars? Chris-active? — so `/api/mission` has a defined thing to emit. Until then the tile is honestly dark.
- Confirm we retire web/v2 as the *web* surface (kept as desktop app), not delete it.

**Test to hold it to:** delete the page — did you lose any truth? If yes, it stored state it shouldn't. If no, it's a real instrument, and you'll open it every morning.

**Key receipts:** `crates/chump-fleet-server/src/{routes.rs,main.rs,dashboard.rs,gap_write.rs}` · `web/v2/{index.html,cockpit.js}` (tokens + grid, salvage only) · `scripts/ops/render-vital-signs.sh` + `render-third-peer.sh` (contract to lift) · `scripts/coord/board-tick.sh` (helsinki path bug) · `scripts/coord/pr-book.sh` (`kind=pr_book_odds` in ambient) · gap store `~/chump/.chump/state.db` · events `~/chump/.chump/fleet_events.db` · live server `127.0.0.1:7070` on cuphead (`/api/dashboard-summary` real, `/api/mission` empty, `/api/fleet/nodes` = 1 of 3). New file to create: `~/chump/web/cockpit-live/index.html`.
