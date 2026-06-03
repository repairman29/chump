# Commit→Merge Pipeline Audit (2026-06-03)

> **Verdict: we are doing it wrong — structurally over-engineered and fail-closed.**
> The *instinct* (quality gates, atomic claims, observability) is right. The
> *implementation* has accreted into a brittle, self-blocking gauntlet that an
> autonomous agent cannot survive — which is fatal for the 0→1 mission.
>
> Anchor gap: **INFRA-2521** (umbrella). Workstreams: INFRA-2522 / 2523 / 2524 / 2525.

## How this audit happened
A normal session of operator-directed work (NATS mesh, R2, warm-cache) turned
into ~6 hours of fighting the commit→merge pipeline. An **Opus, focused, with a
human operator on call** spent ~95% of effort fighting gates and ~5% writing the
actual fixes. That ratio is the finding. This doc traces the real path and the
numbers.

## The gauntlet (measured 2026-06-03)

| Stage | Gates an agent traverses |
|---|---|
| **Claim** (`chump claim`) | ~13 checks — incl. a main-health gate that blocks **all** claims fleet-wide |
| **Pre-commit** | a **2,021-line** hook with **45 block points** + **13** separate `pre-commit-*.sh` scripts |
| **Pre-push** | a **1,307-line** hook with **48 block points** |
| **Ship** | a **4,000-line** `bot-merge.sh` + integrator daemon + watchdog daemon (3 fragile daemons) |
| **CI** | **23 workflows, ~31 checks** per PR |
| **Escape hatches** | **113 distinct bypass env vars** (`CHUMP_*_(BYPASS\|SKIP\|IGNORE)`) |

**~93 local block-points + 31 CI checks + 113 bypasses to land one commit.**

## Pathology 1 — gate accretion
Every past incident added a gate; nobody removes one. The *same* concerns (lint,
audit, registry coverage, AC-completeness, obs-budget, rust-first, redundancy,
preflight-parity, bypass-trailers…) are enforced at **three layers** — pre-commit,
pre-push, *and* CI.

**The 113 bypass env vars are the receipts.** A system that needs 113 different
"skip this gate" knobs is telling you, 113 times, that its gates block legitimate
work. Earlier finding this quarter: **121 of 139** `Bot-Merge-Bypass` trailers
were *tooling-forced*, not discipline failures. The gates and their bypasses have
co-evolved into a stalemate where the bypass *is* the normal path.

## Pathology 2 — fail-CLOSED single points of failure (the dangerous one)
This entire session was one fail-closed SPOF after another, each **halting the
fleet** instead of degrading:

- **Watchdog parser bug** (extracted an em-dash `—` as a "failing gate") → marked
  main RED → **every agent's `chump claim` blocked fleet-wide for 5+ hours.**
- **`chump-integrator` binary never installed** → the default batched ship path
  silently never drained (gaps routed into a dead queue).
- **`chump-coord` binary a month stale** → the NATS work-routing mesh was dark
  the whole time despite the broker being up.
- **`audit.yml cancel-in-progress: false`** → audit runs piled up (13 vs 4
  runners) → every audit-gated merge wedged.

Your own `docs/design/A2A_ROADMAP.md` **principle #7** is literally *"Fail-open
over deadlock… never deadlocks the fleet on coordination errors."* The
claim/main-health gate, the integrator, and the watchdog all violate the
architecture's own stated principle.

### The deadlock that proves it
The fix *for* the watchdog false-RED (INFRA-2458 / PR #2981) **could not merge**,
because it was trapped in the *same* over-gated, saturated audit pipeline it was
meant to protect. The fix for the fragile pipeline was strangled by the fragile
pipeline. The escape was not "ship the fix faster" — it was to **fail the broken
watchdog OPEN** (disable it + clear its false state), which unblocked the fleet
*independent* of the stuck fix. The way out was the audit's own prescription.

## Target shape (world-class for an autonomous fleet)
1. **Local hooks: ≤3 fast checks** (fmt, `cargo check`/syntax, claim+identity),
   <10s total. Nothing else.
2. **All depth → CI, one layer**, parallel, observable. Delete the duplicated
   pre-commit/pre-push copies of CI checks.
3. **One ship path.** PR-auto-merge **or** a merge-queue — pick one, delete the
   other two (no `bot-merge`(4000 LOC) *and* integrator-queue *and* manual-PR).
4. **Every fleet-blocking daemon fails OPEN.** A broken/stale/missing health
   signal warns and gets out of the way — it never halts all claims.
5. **≤3 bypasses, not 113.** Rule: a gate that needs a routine bypass is *fixed
   or deleted*, not bypassed.

## Why this is the prerequisite for 0→1 autonomy
The mission is agents that build+deploy software with no human in the loop. An
autonomous agent cannot navigate a 93-local-gate, fail-closed gauntlet with a
6-trailer bypass dance — it wedges on gate #1 and there is no human to type the
escape. **Throughput is the product; this pipeline strangles throughput.** The
fix is mostly *subtraction*.

## Workstreams
- **INFRA-2522** — collapse local gates: ~93 block-points → ≤6; depth moves to CI.
- **INFRA-2523** — one canonical ship path; delete the other two.
- **INFRA-2524** — fail-open every fleet-blocking daemon (A2A principle #7).
- **INFRA-2525** — cull 113 bypass env vars → ≤3.

This is not "add a gate to catch the next miss." It is a deliberate **deletion
program**. Less machinery → less breakage → less maintenance → an agent can
actually ship.
