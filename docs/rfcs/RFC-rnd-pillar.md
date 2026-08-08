# RFC — R&D as the fifth pillar (license to explore)

**Status:** Draft — decisions marked ⬜ are the operator's
**Date:** 2026-08-07
**Related:** [SOFTWARE_FACTORY_MATRIX_2026-08-05.md](../strategy/SOFTWARE_FACTORY_MATRIX_2026-08-05.md) (DOC-079), [MISSION.md](../MISSION.md), READY-GATE / STRANGER-GATE outcomes, RESILIENT-048 (the FAFO name collision), META-328 (coherence verdict)

## Problem

Chump has four pillars — **EFFECTIVE, CREDIBLE, RESILIENT, ZERO-WASTE** — and every one of
them *restrains*: don't overclaim, don't break, don't waste, prove impact. None of them
licenses trying something nobody asked for. The registry can hold work but not wonder.

The consequence is measurable. Every outward-facing chair in the factory matrix is ❌
(L1 customer intake, L3 design, L7 growth) while every inward chair is ✅ or 🟡. Three
LIGHTHOUSE product outcomes carry 0, 0 and 1 gaps against MISSION-010's 2,621. A system
optimizes what it can measure, and the only thing this one can measure is itself.

Operator's own diagnosis, 2026-08-07: **"that last pillar has been me."** In a single
session, six operator questions redirected work that was otherwise heading somewhere
less useful. That is a single point of failure in exactly the sense the RESILIENT pillar
means it — and there are ~70 launchd jobs for reliability, zero for imagination.

**The mechanism is a category error we made ourselves.** This shop runs on receipts, and
the receipts rule got quietly applied to *ideation*, where it does not belong. A claim
about reality needs evidence; a hypothesis needs a label and a budget. Point
"verify before believing" at imagination and you get paralysis, so the safest available
move is always to count something that already exists. Audit feels rigorous; speculation
feels like unreceipted claiming. That is why the default is always inventory.

## Naming — R&D, not FAFO ⬜ DECISION

The operator's instinct was "FAFO as a pillar." **That name is already taken in this
fleet, with the opposite valence.** RESILIENT-048 is titled "auto-FAFO-check" and its
framing is *"what are we doing to validate that we've already FAFO on stuff?"* — there,
FAFO means **already tried**, and the check exists to stop the fleet redoing settled
work. Its shipped vocabulary includes `--force-fafo-bypass` and `kind=fafo_bypass_used`.

A FAFO pillar would invert the term: "FAFO check" would come to mean *may I explore*
rather than *did we already explore*. That is a collision in code, not taste.

**Recommendation: the pillar is `R&D`. FAFO stays as the license inside it** — the rule
that a null result ships as a win. R&D is the chair (legible to anyone, and the word
every business that uses integrated tech already has a line item for); FAFO is the
permission. Two words, two jobs.

## It already runs — unlabeled, unbudgeted, uncounted

The mechanism does not need inventing. Four instances exist today:

| Existing R&D | What it did |
|---|---|
| `~/Projects/.claude/workflows/venture-go-no-go.js` | 7 agents killed the posse-outward bet; survived 0 of 3 kill attempts; NO-GO accepted 2026-08-04 |
| posse (`bot.mjs` / `surveyor.mjs` / stranger agent) | cold-tests live surfaces; Tier 0 calibrated against two known states (17/27 dead on a known-broken site, 0/18 on a known-good one) |
| `almanac/scripts/embedder-ab.sh` | two-arm embedding-model A/B; the nomic-vs-embeddinggemma run came back a wash, which is a result |
| `almanac/scripts/eval-gate.sh` | killed a plausible-sounding fusion change and the cross-encoder reranker on measurement |

**The six NO-GOs are this pillar's existing trophy case.** They are currently filed as
failures. Under R&D they are the product: a fast NO-GO is a successful run.

## Mechanics

1. **Reuses the gap pipeline — it does NOT need a parallel one.**
   ⚠️ **CORRECTED 2026-08-08.** This RFC originally claimed R&D "runs outside the picker"
   because it has a hypothesis and a ceiling rather than acceptance criteria. That is
   wrong on inspection. `privateer`'s `voyage.mjs` writes **"What would count as
   treasure"** and **"What would count as a chart"** into every pending chart, and those
   two sections *are* specific, testable acceptance criteria. They are
   **machine-generated** — the same move `EFFECTIVE-386` (AC-writer, shipped 2026-08-07)
   makes for gaps, arrived at independently from the other direction.
   So a voyage can ride what already exists: pick, claim, worktree, dispatch, ship.
   Building R&D its own scheduler and dispatcher would be a **fifth hand-rolled cascade**
   of exactly the shape the first real voyage catalogued (completion, embedding, TTS, STT
   — `privateer/charts/2026-08-08-search-field.md`).
   **Honest caveat:** a voyage filed as an external-repo gap inherits `EFFECTIVE-353` and
   `EFFECTIVE-354` — external-repo execution currently hands agents placeholders and
   stubs. Reusing the pipeline is a genuine test of that machinery, not a safe bet. The
   interim, shipped 2026-08-08, is `privateer/tick.sh`: a monthly launchd tick that
   *prepares* a voyage and broadcasts it, and deliberately does not sail, because an
   unattended agent lacking a page-fetch tool would produce recall dressed as a chart.
2. **Admission form = hypothesis + spend ceiling, not ACs.** "I think X. Ceiling: N
   free-tier calls and one overnight local run. If false, we learn Y." Deliberately
   cheap to write — expensive intake is precisely what strands ideas in an agent's
   memory (EFFECTIVE-392).
3. **Output = a verdict**, GO / NO-GO / INCONCLUSIVE, with what was spent and what was
   learned. Backfill the six existing NO-GOs at creation so the pillar does not launch
   at 0% and read as neglect — the exact trap the LIGHTHOUSE outcomes are sitting in.
4. **Budget = free tier + sunk-cost local inference**, metered by the existing
   `chump-cost-tracker` (`TAVILY_CALLS`/`TAVILY_CREDITS`, `CHUMP_SESSION_BUDGET_TAVILY`,
   `CHUMP_COST_CEILING_USD`). helsinki and Ollama are already paid for at zero marginal
   cost per token. **R&D therefore cannot starve correctness work, because it is not
   competing for the same dollars** — which dissolves the governance problem a reserved
   budget would have created.
5. **Gated on telling, never on trying.** READY-GATE's three GOs (stranger-GO,
   bucket-GO, audience-GO) already gate what gets told. "We don't do janky work" is
   about what ships, not about what gets attempted, so R&D weakens no existing guard.

## ⚠️ The trap: R&D must be excluded from the mission-ship ratio

The mission scoreboard's gate ② is mission-linked merges ÷ total, target ≥ ⅔, currently
**15/28** (up from 5/18 on 2026-08-05). If R&D merges counted as mission-linked ships,
**the scaling gate becomes clearable by experimenting instead of shipping** — corrupting
the one number that says whether the factory has earned the right to point outward.

R&D must be counted for *balance and restock* and excluded from *the ship ratio*. Both,
explicitly, in `mission_grade.rs`.

## Blast radius

**37 files enumerate the four-pillar set**, including `mission_grade.rs`,
`roadmap_status.rs`, `kpi_report.rs`, `health.rs`, `execute_gap.rs`, `fleet_health.rs`,
`intent_parser.rs`, `completion.rs`. `mission_grade.rs` classifies by gap-title prefix
(`EFFECTIVE:` | `CREDIBLE:` | `RESILIENT:` | `ZERO-WASTE:`, case-insensitive; untagged
gaps are excluded). Mechanical, but not a doc change.

⬜ **DECISION: fifth pillar, or separate ledger?**
- *Fifth pillar* — inherits the curator's `balance_restock` machinery, so it cannot
  silently starve. Cost: the 37-file refactor, plus care that its success axis (learning
  per spend, kill = win) does not pollute pillar metrics built for delivered value.
- *Separate ledger* — no refactor, no metric pollution. But nothing balances it, which
  is precisely how the LIGHTHOUSE outcomes reached zero.
- **Recommendation: fifth pillar**, with an explicit ship-ratio exclusion. The
  starvation risk is proven; the refactor risk is mechanical.

## Dependency

**Blocked on RESILIENT-246.** The curator — which does `balance_restock` — has been dead
since 2026-07-26, exiting 78 every 600s. A fifth pillar whose anti-starvation mechanism
is a dead organ starves on day one.

## Open questions ⬜

- Where do R&D verdicts live? Not the gap registry (it holds work, not findings). A
  `docs/rnd/` ledger, or holler with a distinct kind?
- Cadence: what fires an R&D run when nobody asks? Monthly seems right for
  idea-generation (`frontier-correspondent`, `market-scout` — both currently have no
  cadence, no inbox, and no destination); the A/B and eval harnesses already have theirs.
- Does R&D get a pillar floor (minimum open items) as well as a ceiling? The failure
  mode is R&D going to zero, which a floor detects and `balance_restock` fixes.
- Retro-tagging: do the six NO-GOs get R&D gap IDs, or are they referenced in place?
