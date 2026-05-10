# Free-tier dispatch testing — 2026-05-08

**Author:** Claude Opus 4.6 (pensive-wu session)
**Span:** 2026-05-08
**Outcome:** 0 of 6 provider attempts produced a commit; 3 root causes identified; 3 gaps filed

---

## 1. What we tested

After rebuilding the chump binary from current main (which includes INFRA-733:
free-tier dispatch harness), we tested the free-tier agent loop against every
available provider. The test gap (E2E-9999) asks the model to add a one-line
comment to `src/execute_gap.rs` — the simplest possible agentic task.

## 2. Results by provider

| Provider | Model | Free-tier path? | Tools called | Outcome |
|----------|-------|:---:|---|---|
| Cerebras | Qwen 3 235B (a22b) | Yes | read_file | RPM limit hit on 2nd API call |
| Groq | Llama 3.3 70B | Yes (aborted) | — | Daily token limit exhausted (100K TPD) |
| NVIDIA | Llama 3.3 70B | Yes | read_file → patch_file → git_commit | patch_file failed (bad diff), consecutive-fail abort |
| Hyperbolic | Llama 3.3 70B | Yes | read_file (wrong file) | Read docs/gaps.yaml instead of target; stopped |
| Gemini 2.5 Flash | — | N/A | — | 20 RPD limit; can't sustain agent loop |
| OpenRouter | Free Llama | N/A | — | Upstream rate limit (Venice provider) |
| GitHub Models | — | N/A | — | Model not found (API changed) |

### Key observation
Pre-rebuild (old binary without INFRA-733): models were exposed to the full
40-tool profile and got lost calling `memory_brain`, `run_cli`, etc. Post-rebuild
with the 4-tool slim profile, NVIDIA's Llama 3.3 called the right tools in the
right order — the quality improvement from INFRA-733 is real. The remaining
failures are rate limits (infrastructure) and patch format (model quality).

## 3. Root causes

### A. RPM/TPD limits too tight for agent loops
Free-tier providers enforce 10-30 RPM. A 3-step agentic task (read → patch →
commit) needs 4+ API calls (initial prompt + 3 tool responses). At Cerebras's
RPM, the second call fires within seconds and gets 429'd.

**Gap filed:** INFRA-784 — inter-request delay + exponential backoff for
free-tier mode.

### B. Llama 3.3 70B generates malformed patch_file inputs
NVIDIA test: model called `patch_file` with the right intent but the unified
diff was syntactically wrong. All 3 subsequent retries used the same bad format.

**Gap filed:** INFRA-785 — fuzzy patch matching + write_file fallback.

### C. E2E test script gap ID format incompatible
The e2e test script generates `E2E-TEST-<timestamp>` (two hyphens) but
`validate_gap_id()` requires `DOMAIN-DIGITS` (one hyphen, numeric suffix).
Every automated e2e test fails before dispatch.

**Gap filed:** INFRA-786 — fix ID format to `E2E-<timestamp>`.

## 4. Provider availability changes since last check

| Change | Detail |
|--------|--------|
| Cerebras dropped Llama 3.3 70B | Now offers: Qwen 3 235B, Llama 3.1 8B, zai-glm-4.7, gpt-oss-120b |
| Cerebras gpt-oss-120b, zai-glm-4.7 | Listed but return "model not found" on API calls |
| Groq added Qwen3-32B | Available as `qwen/qwen3-32b`; untested (TPD exhausted) |
| Groq added GPT-OSS-120B | Available as `openai/gpt-oss-120b`; untested |
| Groq added Llama 4 Scout | Available as `meta-llama/llama-4-scout-17b-16e-instruct` |
| GitHub Models | Previous endpoint returns 404 on /models; model ID "meta-llama-3.3-70b-instruct" not found |

## 5. Most promising path forward

**Cerebras Qwen 3 235B** is the strongest candidate:
- 235B parameters (3.4× Llama 3.3 70B)
- Blazing fast on Cerebras hardware (7ms for a simple completion)
- Correct read_file call on first attempt
- Only blocker is RPM limit (INFRA-784 fix)

If INFRA-784 ships (add 5s delay between agent iterations), Cerebras Qwen 3
235B should be able to complete the E2E-9999 test in ~25s (5 iterations × 5s
delay). This would be the first successful free-tier autonomous dispatch.

## 6. Gaps filed

| ID | Pillar | Priority | Effort | Summary |
|----|--------|----------|--------|---------|
| INFRA-784 | RESILIENT | P1 | xs | Free-tier agent loop inter-request delay |
| INFRA-785 | EFFECTIVE | P1 | s | patch_file fallback for bad diffs (Llama 3.3) |
| INFRA-786 | RESILIENT | P1 | xs | E2E test script gap ID format fix |

## 7. Binary version matters

The installed chump binary must include INFRA-733 (merged as PR #1355). The
pre-INFRA-733 binary exposes 40+ tools to free-tier models, causing them to
call `memory_brain`, `run_cli`, `session_search` etc. instead of the 4 tools
they need. After rebuilding from main, tool selection accuracy improved
dramatically — NVIDIA's Llama 3.3 called `read_file → patch_file → git_commit`
in the correct order.

**Operator action:** After any main merge that touches the dispatch path,
rebuild and reinstall: `cargo build --release && cp target/release/chump ~/.local/bin/`
