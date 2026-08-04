# e2e test depth ledger

Shop rule #8: **green ≠ covered.** Every row names its depth tier AND its gaps.
Tiers: D1 smoke · D2 happy path (state asserted server-side) · D3 edges · D4
adversarial. Updated in the same commit as the suites it describes.

**What the required PR check actually proves (read this first):** the `e2e (pwa)`
shard runs ONLY the two API suites and the header-structure check — 16 tests.
Every browser-driven UI flow is either quarantined (INFRA-1332, advisory-only)
or `fixme`-skipped (INFRA-2128). A green `test-e2e` on a PR proves API contracts
and one DOM-shape invariant. It proves nothing about the PWA actually working
in a browser. That is the honest floor this chart is built on.

## Suites

| Suite | Runs where | Depth | What it actually proves | Gaps (named, not vibes) |
|---|---|---|---|---|
| `api-and-pwa` › API block (7 tests) | **required** PR check | D1–D3 | health/stack-status/repo-context/jobs/analytics answer with sane shapes; unknown-message feedback → 404; approve contract is idempotent — **proven by calling twice** (depth pass 2026-08-02; the old test claimed it in the name and called once) | analytics is shape-only — numbers are never cross-checked against writes ("returns six numbers" ≠ "counts are right"); stack-status `tool_policy` asserted as array, not against the actual policy file; no auth-failure path (`check_auth` 401s are untested end-to-end) |
| `daily-driver-api` (6 tests) | **required** PR check | D2–D3, one D4-lite | sessions: create ×2 then list contains BOTH ids (server-side); tasks: created row present **by id** in the `open` list (fixed 2026-08-02 — see below); chat input edges: empty → 400, >20k chars → 400; `/task` via API persists user+assistant rows server-side; 3 parallel `/task` calls all complete | the parallel test proves completion, NOT isolation — it never asserts 3 distinct tasks landed or that sessions didn't cross-contaminate (a real D4 would); no delete/update lifecycle coverage (`PUT/DELETE /api/tasks/{id}` untouched); `/task` asserts reply text + row count, not task-db row |
| `api-and-pwa` › PWA shell / mobile viewport / Chat-`/task` (8 tests) | **quarantined** — advisory job only (`CHUMP_E2E_INCLUDE_FLAKES=1`), failures are warnings | D1–D2 *when they run* | composer/sidebar/settings render; touch-target ≥40px; `/task` produces an assistant bubble in-thread | **zero PR protection since INFRA-1332** — flake root-cause (INFRA-1335) still open; assertions are `isVisible`-style, which auto-scrolls and cannot catch paint/overlap regressions (see olive's `elementFromPoint` pattern); "New chat clears thread" asserts message COUNT, not content |
| `pwa-onboarding-consolidation` (3 tests) | **all `test.fixme`** since INFRA-2128 | none (was D2–D3) | nothing — the suite is skipped everywhere | the duplicate-onboarding-surface regression this guarded is **currently unguarded**; the localStorage-migration branch (legacy welcome keys suppress the wizard) has NO other test anywhere; root-cause gap for the TimeoutError flake never filed beyond the comment |
| `pwa-header-dedup` (3 viewports) | **required** PR check | D1–D2 | `#app-header` has ≤4 children at 1440/640/375px; the four deduped chips absent; title/repo-switcher/heartbeat present | count-based: proves absence from header, not that chips didn't reappear visibly elsewhere; presence ≠ painted (no visibility/overlap assert); nothing asserts the header is usable (clickable) at 375px |
| `daily-driver-llm` (1 test) | opt-in only (`CHUMP_E2E_LLM=1`) — off in CI | D2 when run | real inference round-trip: model echoes a marker into the chat thread | effectively a manual test — no cadence guarantees it ever runs; single marker echo proves the pipe, not conversation state, tool calls, or streaming |
| `chumpbench/` (6 YAML tracks) | manual / harness — not a Playwright suite, not in CI | scenario (outside D1–D4) | zero-touch OS-capability acceptance: CREATE ×3, COMPREHEND, RESCUE, FINISH tracks with self-contained grading commands. The shared grading + scorecard logic in `src/bench.rs` now carries Rust **unit** assertions: spirit-verdict parse (credible192), engine-drive-failure→FAIL not stale-clone-PASS (credible193), spirit diff-range on commit-on-main laps (credible194), grounded spirit prompt (credible195), agent-effort/iteration-cap parse (credible190), stop-when-done prompt (effective352). Scorecard now carries `spirit_verdict`/`spirit_reason` + `tool_calls` + `hit_iteration_cap`. | the per-track YAML *acceptance* is still bespoke and the tracks run on no schedule — a track can rot green-less for weeks, and there's no ledger of last pass/fail per track. The shared grading/scorecard-parse logic is unit-covered (above); the end-to-end tracks themselves are not (they drive a live cascade agent). |

## Found by this depth pass (2026-08-02)

1. **`?status=pending` is not a real status.** Task statuses are
   `open|blocked|in_progress|done|abandoned`; `task_list` silently treats unknown
   filters as "all active" (`src/task_db.rs:194`). The old test's filter did
   nothing, and its `length > 0` assert passed on any pre-existing task — the
   created task was never looked up. Fixed: assert the created row by id in the
   `open` list. *Open product question (not changed here): should `task_list`
   400 on unknown statuses instead of silently widening?*
2. **The "idempotent" approve test called once.** Now calls twice and asserts
   the contract both times.

## Cadence map (where green can hide)

- **PR-required**: API block + daily-driver-api + header-dedup (16 tests). ARM
  runner with Ollama qwen2.5:7b; retries:2, so a pass may contain absorbed flakes
  — check the run log before calling a marginal suite stable.
- **Advisory** (non-blocking): the quarantined PWA/chat blocks, JSON artifact
  kept 14 days (INFRA-1335's audit trail).
- **Nightly only**: battle-sim and golden-path shards (RESILIENT-016) plus the
  dogfood matrix — their check names appear in ci.yml but do NOT gate PRs.
- **Never automatically**: `daily-driver-llm`, `chumpbench/`, and everything
  `fixme`'d.

**Honest state:** the UI layer of Chump's e2e has been effectively untested on
the PR path since INFRA-1332 (quarantine) and INFRA-2128 (fixme). The API layer
is genuinely D2–D3 with the two fixes above. Raising the floor means
root-causing INFRA-1335 and un-quarantining, not adding more API tests.
