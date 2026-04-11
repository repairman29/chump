# Onboarding friction log (cold clone)

**Purpose:** Time each step of the [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) from a machine that did **not** set up Chump before. Record friction so we can lower time-to-first-success.

**Who runs it:** Ideally someone who is **not** the doc author. The maintainer can do a “dry run” to seed the log, but a **naive reviewer** pass is required before claiming the [launch gate](PRODUCT_CRITIQUE.md#launch-gate-external-ready) is met.

---

## How to run a session

1. Use a fresh clone (or `git clean -fdx` only if you accept losing local artifacts—usually use a VM, second user account, or spare machine).
2. Start a timer at `git clone` completion.
3. For each step below, note **elapsed minutes** and **friction** (what confused you, missing link, wrong command, etc.).

### Template

| Step | Target time (min) | Actual (min) | Friction / notes |
|------|-------------------|----------------|------------------|
| Clone complete | 0 | | |
| `setup-local.sh` + edit `.env` | 5 | | |
| Ollama serve + pull model | 10 | | |
| First `cargo build` | 15 | | |
| `./run-web.sh` + `curl /api/health` OK | 3 | | |
| Browser: PWA loads + one chat turn | 5 | | |
| **Total to first successful chat** | **≤ 40** | | |

(Add rows if you deviate from the golden path.)

---

## Maintainer dry run (2026-04-09)

**Method:** Doc/code review only (no second physical machine in this session). Findings fed into [PRODUCT_CRITIQUE.md](PRODUCT_CRITIQUE.md).

| Issue | Severity |
|-------|----------|
| Root [README.md](../README.md) did not describe Chump or link golden path; read as unrelated “template” | Blocker (addressed by README update) |
| `DISCORD_TOKEN=your-bot-token-here` in `.env.example` is non-empty → config summary lists `discord` as enabled though token is fake | Medium |
| Two health URLs: `GET /api/health` (web) vs `GET /health` (CHUMP_HEALTH_PORT sidecar) easy to confuse | Medium (documented in golden path) |
| `.env.example` is long; external users need a **minimal** subset | Low (golden path lists minimum) |

**Naive reviewer:** _Optional follow-up: have someone who did not write the docs run the template and append a dated section._

---

## Cold clone verification (2026-04-09)

**Method:** Fresh `git clone` to `/tmp` (no existing `target/`), then `cargo build` on the same machine as development (not a third-party reviewer). Validates that a clean tree compiles.

| Step | Target time (min) | Actual | Notes |
|------|-------------------|--------|-------|
| `git clone file://…` | 1 | &lt;1 | Local file URL |
| First `cargo build` (debug) | 15 | ~1.6 | ~93s wall; incremental LLVM from warm host caches |
| **Total to build OK** | **≤20** | **~1.6** | CI/cold CI may be slower without cache |

**Automation:** `./scripts/verify-external-golden-path.sh` runs `cargo build` and checks required files.

---

## Market research blind sessions (golden path)

**Purpose:** Support the [market evaluation sprint](MARKET_EVALUATION.md#6-primary-research-kit). Same steps as the template above, but participant receives **only** [README.md](../README.md) quick start + [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md)—no Discord, no fleet hints unless they discover docs on their own.

**Protocol:** Screen-record or scribe; time to `curl` **web** `/api/health` OK + one successful PWA chat turn. If stuck more than 10 minutes, one neutral hint allowed—mark **Rescue: Y** in notes.

### Session log (target: ≥5 sessions)

| Session # | Date | Participant type | Total (min) | Rescue? | Top friction | Synthesis → MARKET_EVALUATION §4 |
|-----------|------|------------------|-------------|---------|--------------|-----------------------------------|
| B1 | | | | | | |
| B2 | | | | | | |
| B3 | | | | | | |
| B4 | | | | | | |
| B5 | | | | | | |
| **Progress** | 2026-04-10 | Maintainer | — | — | Phase 2 tracker: **0/5** blinds complete, **0/12** interviews—fill B1–B5 after each blind session; update [MARKET_EVALUATION.md](MARKET_EVALUATION.md) §4.2 counts |

After each session, paste a one-line summary into [MARKET_EVALUATION.md](MARKET_EVALUATION.md) §4.2.

---

## After your session

- Open a PR or issue with deltas, or append a dated subsection below.
- If a step exceeded the target consistently, update [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) or scripts.
