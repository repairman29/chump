# Pilot handoff — ready for ~5 users (without them on call today)

**Intent:** “Ready to hand off” means **another person can succeed cold** with what you give them—not that you’ve already run five blind studies. Market blinds ([ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md), [MARKET_EVALUATION.md](MARKET_EVALUATION.md) §6) improve **story and pricing truth**; this checklist improves **pilot survival**.

---

## What you prepare *before* anyone clones

| # | Deliverable | Why |
|---|-------------|-----|
| 1 | **Default path is one screen of commands** | [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) + README Quick start; no Discord required for v1. |
| 2 | **CI green on `main`** | [PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md) launch gate L1 — you are not handing off a broken trunk. |
| 3 | **`.env.example` + a “pilot `.env`” snippet** | Minimal keys only; link executive / cascade / auto-push warnings; optional `CHUMP_GOLDEN_PATH_OLLAMA=1` for heavy defaults. |
| 4 | **Web + token story** | If pilots use PWA: `CHUMP_WEB_TOKEN`, HTTPS or Tailscale note, “rotate if leaked.” [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md). |
| 5 | **“Known rough edges” one-pager** | Inference latency (model-bound; see [PERFORMANCE.md](PERFORMANCE.md) §8), optional **`CHUMP_LIGHT_CONTEXT=1`** for snappier PWA chat, first `cargo build` time, optional Discord, where to get help—reduces “is it broken?” panic. |
| 6 | **Support channel** | One place (email, Discord server, Slack)—**you** respond for the first week; set expectation. |
| 7 | **Rollback** | Tag or release SHA; “to go back: `git checkout <tag>`” + how to stop processes (`OPERATIONS.md`). |

Optional but strong: run **`./scripts/print-repo-metrics.sh`** once and attach output to an internal “release notes” note so nobody argues from invented counts.

---

## Per-user packet (copy-paste minimal)

Send each pilot **the same bundle**:

1. Link to repo (or tarball / DMG when packaging exists — see **P5.5** in [ROADMAP_UNIVERSAL_POWER.md](ROADMAP_UNIVERSAL_POWER.md)).
2. **EXTERNAL_GOLDEN_PATH** only for first day; “after day 1” pointer to [OPERATIONS.md](OPERATIONS.md) if they want Discord/roles.
3. Their **own** `OPENAI_API_BASE` / model choice (Ollama local vs their key)—never share *your* keys.
4. One sentence: **“If `curl /api/health` isn’t 200, stop and message me with the last 20 lines of `logs/web.log`.”**

---

## First-week success (define this so you’re not guessing)

Pick **one** definition, tell pilots explicitly:

- **Example A:** “You complete golden path + one PWA chat + one task create from the UI.”  
- **Example B:** “You run one `autonomy_once` on a sample task with approval.”  

Avoid “use everything.” Five people × one narrow success path = real proof.

---

## Relationship to “pushback” (built vs proven)

- **Built** = code + docs exist.  
- **Proven for handoff** = a stranger-class user can hit your **one** success definition without you in the room.  
- **Blind sessions** = extra rigor for **market** narrative; they are **not** a prerequisite for inviting five friends/colleagues on a **pilot** if L1–L6 style gates above are met.

When pilots finish week one, **then** backfill B1–B5 in the friction log using their feedback—you’ve earned the blind rows without needing volunteers upfront.

---

## Related

- [PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md) — launch gate  
- [PRODUCT_REALITY_CHECK.md](PRODUCT_REALITY_CHECK.md) — metrics hygiene for any “state of product” write-up  
- [ROADMAP.md](ROADMAP.md) — **Architecture vs proof** (latency/soak when you want numbers, not vibes)
