---
doc_tag: audit
owner_gap: PRODUCT-311
status: plan-staged-decomposed
---

# PRODUCT-311 — PWYW productization first wave: plan + decomposition

## 0. What this gap is, and isn't

Jeff's ask (2026-09-26): automate publishing owned pages/products/services
pay-what-you-want (PWYW), and **tell people**. Per
[`PORTFOLIO_READINESS.md`](https://github.com/repairman29/workspace-docs/blob/main/PORTFOLIO_READINESS.md)
(repairman29/workspace-docs), the portfolio's bottleneck across almost every
asset is **Usage and Told, not Loop or Live** — things work, almost nobody
has heard. `GIVEAWAY_SOP.md` names this law directly: *built ≠ shipped ≠
told*, and **Phase E (tell a real person) is the point, not prep**.

This gap does not publish anything. It (a) inventories the first-wave
candidates, (b) applies the go/no-go evidence gate to each, (c) points at
the reusable PWYW/tip-jar pattern already drafted, (d) states the
release-auditor + revoke-before-publish gate every candidate must clear
before going public, (e) names the crown metric (a real person told +
reached) per candidate, and (f) decomposes the remaining fleet-workable
prep into sub-gaps. Account creation (Sponsors/Ko-fi/Stripe), `npm
publish`, repo-visibility flips, and the pre-publish secrets sweep stay
Jeff-gated in every sub-gap, per CLAUDE.md rules 4/7 and GIVEAWAY_SOP Phase
C.

## 1. Inventory — first-wave candidates (AC #1)

Source: `SITES.md` / `DOMAINS.md` / `PROJECTS.md` / `PORTFOLIO_READINESS.md`
in `repairman29/workspace-docs` (the portfolio source-of-truth repo; these
files do not live in `chump`). Scope is the 4 candidates named in this
gap's description.

| Candidate | Repo | Visibility | PWYW-readiness | Told yet? |
|---|---|---|---|---|
| **bulwark** | `repairman29/bulwark` | private | **GO** (scoped name) | No — never published |
| **coloringbook** | `repairman29/coloringbook` | private | **NO-GO** (productization debt) | No |
| **dice** | `repairman29/dice` | private, **archived** | **CONDITIONAL** (bug fixed, blocked on archive) | No |
| **upshift-cli** | `repairman29/upshift-cli` | **public**, on npm (`0.5.6`) | **DROPPED from PWYW** (real paywall already exists) | No — Phase E (posting) sitting unposted for months |

Re-verified live this session (2026-10-02): `dice` is still
`isArchived:true`; `bulwark`/`coloringbook` are still private, unpublished;
`upshift-cli` is public on npm. `npm view bulwark` still returns the 2019
unpublish 404; `@repairman29/bulwark` is unclaimed and available.

## 2. Go/no-go per candidate (AC #2)

Full per-candidate assessment already written: `pwyw-readiness.md` in
**`repairman29/workspace-docs#2`** (open, cloud agent, 2026-09-26) — *"PWYW
readiness (PRODUCT-311): assessment + reusable tip-jar wiring"*. Summary,
applying the six-NO-GO evidence gate (license clarity, secrets/backend
audit, voice/honesty, static-vs-service reality, test depth, distribution
fit):

- **bulwark — GO.** Apache-2.0 clean, zero deps, 10 passing tests, no
  secrets. One real blocker: `npm publish bulwark` will likely be rejected
  (name unpublished 2019, npm holds it against reuse) → publish scoped
  `@repairman29/bulwark`.
- **coloringbook — NO-GO.** Three-way license contradiction (LICENSE
  proprietary vs README MIT vs Apache-2.0 floor), hype README with a
  feature marked "simulated" presented as real, a live FastAPI/OpenCV
  Python backend (not a static site) that is unaudited, plus a committed
  `.zip`. Tip-jar is the last 5%, not the first step.
- **dice — CONDITIONAL.** Advantage/disadvantage logic bug found and fixed
  (`PRODUCT-312`, commit `6a2c8c2` on branch `fix/disadvantage-roll-logic`)
  — but push is blocked because **the repo is archived on GitHub**
  (`This repository was archived so it is read-only`), confirmed still
  archived today. Needs an operator action (unarchive) before the fix, the
  rest of the Phase-B/C audit, or the tip-jar can land.
- **upshift-cli — dropped from PWYW by design.** `src/lib/credits.ts`
  meters AI features against a credit bank and exits non-zero when
  exhausted; `pricing.json` defines paid Stripe subscriptions. A
  name-your-price tip jar on top of a metered paywall is contradictory
  messaging — it stays freemium. Its only remaining step is **Phase E**
  (Jeff posts it), unrelated to PWYW engineering.

## 3. Reusable PWYW/tip-jar wiring pattern (AC #3)

Drafted and staged in **`repairman29/workspace-docs#2`**,
`proposals/pwyw-tipjar/`: one config (`tipjar.config.example.json`) + two
zero-dependency renderers — `tip-jar.js` (a `<tip-jar>` custom element for
static sites: coloringbook, dice) and `tipjar.mjs` (`showTip()` for CLIs:
bulwark). Anti-paywall contract is built into the code, not just
documented: no metering, every link is name-your-price
(Sponsors/Ko-fi/Stripe-PWYW-mode/Liberapay), CLI prints only after success
at most once/day and is TTY-gated and silenceable, web bar is a dismissible
footer never a modal. This PR is **open, unmerged** — merging it, and
copying the three files into each candidate repo, is part of the per-repo
sub-gaps below.

## 4. Release-auditor + revoke-before-publish gate (AC #4)

Stated as a hard precondition on every sub-gap below, per
`GIVEAWAY_SOP.md` Phase C and the `RELEASE_CHECKLIST.md` in
`workspace-docs`: push the carved/prepped repo private, run the secrets
gate (security-sweep + hardcoded-literal grep + liveness-test any
key-shaped hit), run an **independent second scan**, confirm
allowlist-only + zero secrets, **then** flip public. None of the four
candidates have run this yet — none are ready to (bulwark needs AC work
first; coloringbook and dice have their own pre-gate blockers; upshift-cli
is already public and out of PWYW scope).

## 5. Crown metric — a real person told (AC #5)

| Candidate | Phase E status |
|---|---|
| bulwark | not built yet — no publish to tell from |
| coloringbook | not built yet — productization gate first |
| dice | not built yet — archived repo blocks even the fix landing |
| upshift-cli | **built, public, on npm for months — zero posts sent.** This is the one candidate where Phase E is the *entire* remaining gap. Out of PWYW scope per §2, but it is the fleet's clearest "tell people" opportunity and is a pure Jeff action (HN/reddit/Substack/LinkedIn, drafts reportedly ready per `PORTFOLIO_READINESS.md`). |

No candidate in this wave has reached a real person yet. The crown metric
is 0/4. The nearest candidate to it is upshift-cli, and it is blocked on
nothing but a captain action.

## 6. Decomposition (AC #6)

One sub-gap per first-wave candidate that still has **fleet-workable**
prep (Jeff-only steps — account signups, npm publish, repo-visibility
flips, the final secrets sweep — are named but excluded from scope in each
sub-gap, matching GIVEAWAY_SOP's captain-gated Phase C/E):

| Candidate | Sub-gap | Why this shape |
|---|---|---|
| bulwark | **PRODUCT-319** — scoped npm rename + DEPTH.md + README Support section + tip-jar wiring | Cleanest GO; everything short of the actual `npm publish` is fleet-workable |
| coloringbook | **PRODUCT-320** — productization gate: license fix + de-hype README + backend/`.zip` audit + cost-model decision | NO-GO verdict means the tip-jar isn't the next step; this *is* the next step |
| dice | **PRODUCT-312** (already filed and shipped 2026-09-xx) — logic bug fixed, fix committed to `fix/disadvantage-roll-logic`, **push blocked on the repo being archived** | No new sub-gap needed; the existing one already captures the state and the blocker. Operator action required: unarchive `repairman29/dice` so the fix can land and the rest of the Phase-B/C audit can proceed. |
| upshift-cli | none filed | Explicitly dropped from PWYW scope (§2); its only gap is Phase E, which is a captain action, not an engineering task |

## 7. What's still Jeff-gated (do not do in prep, per every sub-gap above)

- Standing up any Sponsors/Ko-fi/Stripe account or payment link (credentials).
- `npm publish`, flipping any repo public, deploying, DNS/Pages changes.
- Unarchiving `repairman29/dice`.
- The release-auditor GO + revoke-before-publish secrets check immediately
  before any repo goes public.
- Posting to HN/reddit/Substack/LinkedIn (Phase E, captain action).
