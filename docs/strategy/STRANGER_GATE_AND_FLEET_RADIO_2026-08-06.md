---
doc_tag: canonical
owner_gap: DOC-089
last_audited: 2026-08-08
---

# The Stranger Gate and the Fleet Radio — inventory-first roadmaps

> **What this is.** The two pointed missions the operator selected 2026-08-06 from
> the novel-tools slate (the games+posse+holler lane was confirmed alongside as a
> standing lane, not a hobby). Filed as **DOC-087** (outcome: CHUMPOS). Implementing
> umbrellas: **EFFECTIVE-368** (→ outcome STRANGER-GATE), **EFFECTIVE-369**
> (→ outcome FLEET-RADIO).
>
> **Format law.** Every step is marked **EXISTS** (with a receipt), **WIRE**
> (connect two existing things), or **BUILD** (genuinely new). The operator's
> hypothesis — *"put a good detailed roadmap out there and you might find it's
> nearly done"* — is tested by counting: if BUILD outnumbers EXISTS, the mission
> was mis-scoped. Evidence gathered via almanac (fleet-survey method, 2026-08-06).

---

## Mission 1 — The Stranger Gate (EFFECTIVE-368)

**Thesis.** Nothing we tell people about ships without a stranger having tried it
cold. Receipt for urgency: `upshift-cli` 0.5.5 sat **dead on npm for 14 days** —
726 downloads of a tarball missing `dist/` — because no stranger ever ran it.

**Binding boundary.** The 2026-08-04 outward go/no-go returned **NO-GO, accepted
by the operator: posse points inward only.** Foreign surfaces are never scanned,
never filed at. `targets.json` is an allowlist of repairman29-owned surfaces.
The same verdict declared the inward tool "a keeper" — this mission is that keeper,
generalized.

| Step | Status | Receipt |
|---|---|---|
| Three-agent core: bot (*stuck*), surveyor (coverage), stranger agent (*lost*) | **EXISTS** | `posse:bot.mjs`, `surveyor`, `STRANGER_AGENT.md` |
| Proven game adapters ×4 + genre playbook | **EXISTS** | `posse:adapters/{grave-dancer,realm-of-shadows,crystal-rush,space-shooter}.mjs`, `ADAPTER_GUIDE.md` |
| Portfolio sweep runner | **EXISTS** | `posse:scan-portfolio.mjs` (Tier 0 across `targets.json`) |
| Dedupe filing into holler | **EXISTS** | `posse:report-holler.mjs` (Supabase, dedupe-hash) |
| holler→chump bridge, generalized beyond games | **EXISTS** | `games/shared/playtest/holler-to-chump.mjs`; re-verified 2026-08-05 against a 26-row live snapshot, 5 real bugs fixed |
| Cold zero-adapter scanning | **EXISTS** | vite.dev: 88 elements, 0 findings, no adapter (OUTWARD_READINESS §Verdict) |
| Olive adapter | **WIRE** | `posse:adapters/olive.draft.mjs` — draft exists, finish it |
| Nightly launchd sweep over the allowlist | **WIRE** | scan-portfolio + launchd; holler *drains stay session-driven* (operator decision 2026-08-02: no `HOLLER_SERVICE_KEY`) |
| Bridge `--apply` re-run post-fix | **WIRE** | The 5-bug fix was snapshot-verified but never applied (TODO.md §games) |
| Stranger-GO line in RELEASE_CHECKLIST | **WIRE** | release-auditor reads the latest posse report for any surface entering Phase E (GIVEAWAY_SOP) |
| **Product-tier stranger adapter**: clean-env `npx` cold-install + README-walk | **BUILD** | The one genuinely new artifact class — the 0.5.5-killer |

**Count: 6 EXISTS / 4 WIRE / 1 BUILD.** Hypothesis confirmed.

**Success metric:** every Phase E surface carries a stranger-GO receipt;
time-to-detect a dead public artifact drops from 14 days to <24h.

---

## Mission 2 — The Fleet Radio (EFFECTIVE-369)

**Thesis.** The operator of a hands-off factory should *hear* it, not poll
dashboards. Voice input is already habit; spoken output is the unbuilt half.

| Step | Status | Receipt |
|---|---|---|
| Edge voice pipeline, mic→wake-word→VAD→Whisper→gateway→TTS | **EXISTS** | `jarvis:scripts/voice_node.py` (+ PIXEL_VOICE_RUNBOOK, EDGE_NATIVE_VOICE_NODE docs) |
| Browser/Mac TTS with rate/pitch | **EXISTS** | `jarvis:apps/jarvis-ui/lib/voice.ts`; macOS `say` as floor |
| Wake-word engine, Swift, tested | **EXISTS** | `openclaw:Swabble/` (SwabbleKitTests) |
| Gateway-connected TTS demo | **EXISTS** | `jarvis:scripts/voice-node-demo.py` |
| Brief content assembly in Chump | **EXISTS** | `chump:web/v2/daily-brief.js` (ChumpViewBrief) + `scripts/ci/test-pwa-daily-brief.sh` |
| Live content sources | **EXISTS** | mission-scoreboard.sh, `ambient.jsonl`, holler inbox, gap registry |
| `chump brief --spoken` — ~60s script from scoreboard verdict + 24h ships + holler arrivals + waiting-on-Jeff | **WIRE** | Reuse the daily-brief data path; new output mode, not new data |
| Mac speaker + launchd morning schedule + on-demand CLI | **WIRE** | `say`/voice.ts + SCHEDULING_LAYERS (fleet-durable → launchd) |
| Pixel node as second speaker | **WIRE** | voice_node gateway already streams; point it at the brief |
| Script voice: first-mate register, receipts spoken, no vibes | **BUILD** | Small: a script template honoring the write-as-jeff twin ("4 zero-touch merges", never "crushing it") |
| Approval-queue announcements ("your one click is needed on…") | **BUILD** | Feeds from EFFECTIVE-364/365 when they land; radio is their operator surface |

**Count: 6 EXISTS / 3 WIRE / 2 BUILD.** Hypothesis confirmed.

**Success metric:** the operator hears the fleet daily without opening a screen;
zero-touch spans get measured by radio, not dashboard visits.

---

## Sequencing and the loop

Stranger Gate first by one beat: its product-tier adapter immediately protects the
told-loop (upshift, arcade, guides) that every other strategy thread depends on.
Fleet Radio lands second and then *announces* stranger findings each morning.
Both umbrellas decompose at claim time (two-phase doctrine); both become first
cargo for `chump intake` (EFFECTIVE-357) when the front door opens. The
games+posse+holler lane keeps running underneath as the confirmed GAME-domain
loop: posse sweeps, holler routes, chump fixes, the arcade grows.

_Filed 2026-08-06 under DOC-087. Siblings: DOC-079 (factory matrix), DOC-083
(artifact organization). Outcomes: STRANGER-GATE, FLEET-RADIO._
