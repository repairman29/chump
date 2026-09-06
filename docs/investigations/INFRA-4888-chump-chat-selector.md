# INFRA-4888: Why `chump-chat` never appears in CI

## Root cause

The selector is **not stale** and the app **does mount fine** in the headless
CI environment. `chump-chat` is a live custom element registered at
`web/v2/chat.js:417` (`customElements.define('chump-chat', ChumpChat)`) and
used throughout `web/v2/app.js` / `web/v2/index.html`.

The reason it never shows up in CI logs is that **every Playwright spec that
references it is gated behind an opt-in env var that the per-PR `ci.yml`
workflow never sets**:

1. `e2e/tests/daily-driver-llm.spec.ts` — the entire test is
   `test.skip(!llmE2E, ...)` where `llmE2E` requires `CHUMP_E2E_LLM=1`
   (P4.3, "optional LLM e2e"). `ci.yml`'s `e2e` job (pwa shard) never sets
   `CHUMP_E2E_LLM`.
2. `e2e/tests/api-and-pwa.spec.ts` — the `chump-chat`-touching tests
   (`/task creates assistant reply in thread`, `New chat clears thread after
   a quick reply`) sit after `test.skip(!INCLUDE_PWA_FLAKES, ...)`, gated on
   `CHUMP_E2E_INCLUDE_FLAKES=1`. These were quarantined per INFRA-1332
   (flaked across 6+ unrelated PRs). `ci.yml` never sets this flag either.

`CHUMP_E2E_INCLUDE_FLAKES=1` **is** set — but only in
`.github/workflows/integrations.yml`'s advisory `e2e-pwa-flakes` job, which
runs on a daily schedule / path-gated trigger, not on the standard PR gate.
That job's results are advisory-only (non-blocking), so a searcher grepping
recent `ci.yml` PR-run logs will never find the string.

## Conclusion

Both acceptance criteria resolved:

- The selector is current, not renamed/stale.
- The app mounts fine under xvfb/headless Chromium — the tests simply never
  reach the `page.goto('/')` + selector-lookup step because they're skipped
  before that point on the PR path.

This is intentional quarantine/opt-in design (INFRA-1332, P4.3), not a bug —
no code change required. Filed as a documentation/investigation gap only.
