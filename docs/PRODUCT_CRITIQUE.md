# Product critique matrix (external-ready)

**Scope:** Evaluate Chump for **external adoption**: a developer clones the repo, follows docs, and reaches first value without private context. Full ecosystem (fleet, Mabel, consciousness stack) is **out of scope for v1** except where it blocks trust or onboarding.

**Process:** Re-run lenses periodically (e.g. quarterly) or after major UX/doc changes. Route blockers to [ROADMAP.md](ROADMAP.md).

**Market / competitive evaluation:** [MARKET_EVALUATION.md](MARKET_EVALUATION.md) — ICP, competitive matrix (incl. fleet/hybrid), north-star metrics, interview kit, blind-session log pointer. **Speculative rollback (trust):** [TRUST_SPECULATIVE_ROLLBACK.md](TRUST_SPECULATIVE_ROLLBACK.md).

---

## Launch gate (external-ready)

**Five friendly pilots (no “blind” panel required):** Use [PILOT_HANDOFF_CHECKLIST.md](PILOT_HANDOFF_CHECKLIST.md) so handoff is repeatable before you line up users. Blind sessions in [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) strengthen **market** evidence; they are not the same gate as “safe to invite five people.”

Check all before advertising the repo to external developers:

| # | Criterion | Status |
|---|-----------|--------|
| L1 | Default branch **CI green** ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)) | Maintainer verifies each release |
| L2 | [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) completed on a **clean clone** (no `target/`) + build; third-party naive pass optional | **Done** — see [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) **Cold clone verification**; run [scripts/verify-external-golden-path.sh](../scripts/verify-external-golden-path.sh) in CI or locally |
| L3 | [README.md](../README.md) **Quick start** matches golden path (commands and ports) | **Done** (aligned 2026-04-09) |
| L4 | [LICENSE](../LICENSE) exists and README links it | **Done** (MIT + README link) |
| L5 | `.env.example` warns on **executive mode**, **auto-push**, **cascade privacy** for external users | **Done** (top-of-file banner) |
| L6 | [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md) has at least one naive session or documented schedule to run one | **Done** — template + maintainer dry run + **cold clone verification** table + `verify-external-golden-path.sh` |

### Review evidence (internal / memos)

Before publishing or circulating a “state of the product” write-up, run `./scripts/print-repo-metrics.sh` and paste the table (or attach CI log after **Repo metrics**). Keeps test counts, doc counts, and the **95-step / 3-week** plan reference aligned with the repo. Playbook: [PRODUCT_REALITY_CHECK.md](PRODUCT_REALITY_CHECK.md).

---

## Critique matrix

**Severity:** Blocker | High | Medium | Low  
**Owner:** doc | code | ops | community

| Lens | Finding | Severity | Evidence | Suggested fix |
|------|---------|----------|----------|-------------|
| **1. Positioning** | “Personal ops team” implies multi-user SaaS | Medium | [ECOSYSTEM_VISION.md](ECOSYSTEM_VISION.md), [DOSSIER.md](DOSSIER.md) | **Done Apr 2026:** README + golden path + [MARKET_EVALUATION.md](MARKET_EVALUATION.md) ICP “not SaaS” |
| **1. Positioning** | Rich feature surface obscures “start here” | Medium | Many docs in [README.md](README.md) index | **Partial Apr 2026:** web-first README + [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md); doc index still large |
| **2. Onboarding** | Root README was wrong template | Blocker | [README.md](../README.md) pre-fix | Replace with Chump summary + quick start (done) |
| **2. Onboarding** | Many env vars; easy to misconfigure | Medium | [.env.example](../.env.example) length | External safety banner + [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md) minimal set |
| **2. Onboarding** | Placeholder `DISCORD_TOKEN` marks discord “enabled” in logs | Medium | [config_validation.rs](../src/config_validation.rs) | **Done:** placeholders treated as unset + warning; tests in `config_validation` |
| **3. UX surfaces** | Three entry points (CLI, web, Discord) confuse default | Medium | [OPERATIONS.md](OPERATIONS.md) | **Partial Apr 2026:** README states web default; PWA Tasks wedge hint; ChumpMenu / long ops doc still dense |
| **3. UX surfaces** | Dashboard value requires web + optional brain/ship | Low | [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) | Document “empty dashboard until brain/ship configured” |
| **4. Reliability** | Model flaps (Ollama/vLLM) dominate failures | High | [INFERENCE_STABILITY.md](INFERENCE_STABILITY.md) | **Partial Apr 2026:** README **Troubleshooting** links INFERENCE_STABILITY + flap drill; product behavior unchanged |
| **4. Reliability** | `target/` disk use | Low | [STORAGE_AND_ARCHIVE.md](STORAGE_AND_ARCHIVE.md) | Already documented; `cleanup-repo.sh` |
| **4. Reliability** | Roles/launchd not required for external v1 | Low | [OPERATIONS.md](OPERATIONS.md) | Golden path explicitly defers roles |
| **5. Security** | Executive mode disables CLI guardrails | High | `CHUMP_EXECUTIVE_MODE` | Warn prominently in `.env.example` |
| **5. Security** | `CHUMP_AUTO_PUSH` can push without extra confirm | High | [OPERATIONS.md](OPERATIONS.md), `.env.example` | Warn in external banner |
| **5. Security** | Some cascade slots train on vendor data | High | [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md) | Banner + link to privacy flags |
| **5. Security** | RPC/autonomy auto-approve flags | High | `.env.example`, [TOOL_APPROVAL.md](TOOL_APPROVAL.md) | Keep opt-in; warn in banner |
| **5. Security** | Bearer token on web API | Medium | [WEB_API_REFERENCE.md](WEB_API_REFERENCE.md) | Document `CHUMP_WEB_TOKEN` for mutating routes |
| **6. Architecture** | Large Rust binary; long compile | Medium | `Cargo.toml` | README sets expectation; mention `cargo build --release` |
| **6. Architecture** | CI runs tests + clippy | Low | [.github/workflows/ci.yml](../.github/workflows/ci.yml) | Launch gate L1 |
| **7. Economics** | Cloud cascade = usage cost; local = hardware | Medium | [PROVIDER_CASCADE.md](PROVIDER_CASCADE.md) | Golden path defaults to **free local Ollama** |
| **7. Economics** | Tavily optional but referenced in heartbeats | Low | `.env.example` | Note optional for minimal path |
| **8. Support** | No stated platform matrix for externals | Low | [README.md](../README.md) | **Done Apr 2026:** README **Platform expectations** |
| **8. Support** | Minimal repro undefined | Low | [CONTRIBUTING.md](../CONTRIBUTING.md) | **Done Apr 2026:** CONTRIBUTING bug section + `git rev-parse` + pilot-summary when relevant |
| **9. GTM** | No screenshot/architecture in README | Medium | README | Optional follow-up: one diagram + PWA screenshot |
| **9. GTM** | Differentiation buried in DOSSIER | Low | [DOSSIER.md](DOSSIER.md) | README one-liner: tools + brain + web + self-hosted |
| **10. Market** | Competitive story not in one place | Low | [MARKET_EVALUATION.md](MARKET_EVALUATION.md) | **Done Apr 2026:** matrix + §8 bets + §2b baseline scores; refresh after interviews |

---

## Quarterly review log

| Pass | Date | Notes |
|------|------|------|
| Q2 2026 | 2026-04-10 | README troubleshooting; CONTRIBUTING repro; `GET /api/pilot-summary`; MARKET_EVAL §2b/4.2 tracker; PWA intent parity table in [PWA_WEDGE_PATH.md](PWA_WEDGE_PATH.md). Interview rows still empty—run [MARKET_EVALUATION.md](MARKET_EVALUATION.md) §6. |

---

## Outcome routing

| Severity | Action |
|----------|--------|
| Blocker | Fix immediately; add [ROADMAP.md](ROADMAP.md) item if tracking needed |
| High | Roadmap or security doc update within one release |
| Medium | Backlog / [ROADMAP_PRAGMATIC.md](ROADMAP_PRAGMATIC.md) Phase I or product polish |
| Low | Nice-to-have issues |

---

## Related docs

- [MARKET_EVALUATION.md](MARKET_EVALUATION.md)  
- [EXTERNAL_GOLDEN_PATH.md](EXTERNAL_GOLDEN_PATH.md)  
- [ONBOARDING_FRICTION_LOG.md](ONBOARDING_FRICTION_LOG.md)  
- [DOSSIER.md](DOSSIER.md)  
- [CHUMP_PROJECT_BRIEF.md](CHUMP_PROJECT_BRIEF.md)  
