# CI pipeline diagnosis — 2026-05-08

**Author:** Claude Opus 4.6 (pensive-wu session)
**Span:** 2026-05-08
**Outcome:** All 5 open PRs BLOCKED; 4 distinct root causes identified; 3 fixed on PR #1358, 4 gaps filed for the rest

---

## 1. The problem

As of 2026-05-08 21:25 UTC, every open PR was BLOCKED:

| PR | Title | Required check failing | Root cause |
|----|-------|----------------------|------------|
| #1358 | PRODUCT-063: worker.sh model-class export | `test` (cargo-test + fast-checks) | Neuromod test + undeclared env vars |
| #1356 | PRODUCT-063: decompose --verify | `test` (clippy + fast-checks) | nonminimal_bool lint + undeclared env vars |
| #1363 | INFRA-761: pre-push cargo-test gate | `test` (fast-checks) | Test fixture missing Cargo.toml |
| #1364 | EFFECTIVE-006: e2e test script | None (all required pass) | `ftue` fails but isn't required |
| #1365 | INFRA-762: default-flip guard | CI still running | `gap-status-check` (not required) |

The operator's observation: "it certainly feels like I keep having to get opus to rescue us."

---

## 2. Root causes

### A. Undeclared env vars (fast-checks audit)

Five env vars introduced in the model-class routing work were never added to
`.env.example` or `scripts/ci/env-vars-internal.txt`:

- `CHUMP_CASCADE_MAX_PREFERRED_WAITS`
- `CHUMP_PREFERRED_MODEL_CLASS`
- `CHUMP_VERIFY_API_BASE`
- `CHUMP_VERIFY_API_KEY`
- `CHUMP_VERIFY_MODEL`

**Fixed:** Registered in `env-vars-internal.txt` (commit be485cd5).

### B. Neuromod test regression

EVAL-026 (commit bff114b3) changed `chump_bypass_neuromod()` default from
`false` to `true` — neuromod is now OFF by default. But the test
`neuromod_enabled_default_on` in `src/neuromodulation.rs` still asserted
`neuromod_enabled()` returns `true` when env is unset.

**Fixed:** Updated test to expect `false` (commit be485cd5).

### C. Clippy nonminimal_bool (PR #1356 only)

The `is_cooling_down(slot)` check added to the filter chain in
`provider_cascade.rs:938` created a complex negated boolean that clippy
flags with `-D warnings`. Needs De Morgan simplification or an allow.

**Gap filed:** INFRA-780.

### D. FTUE `chump --version` requires Ollama

`chump --version` initializes the full runtime including local LLM
connectivity. On CI runners (no Ollama), it fails with:
```
Error: error sending request for url (http://127.0.0.1:11434/v1/chat/completions)
```

This breaks the FTUE workflow on every PR touching `scripts/dispatch/**`.

**Gap filed:** INFRA-777.

### E. Pre-push hook test fixture (PR #1363 only)

The CI test for the new pre-push cargo-test gate creates a temp git repo
but omits `Cargo.toml`, so `cargo test` in the hook fails immediately.

**Gap filed:** INFRA-779.

### F. Stale gap status on branch

PRODUCT-063 was shipped via PR #1353 (merged to main), but branches that
diverged before that merge still have `status: open` in their copy of
`docs/gaps/PRODUCT-063.yaml`.

**Fixed:** Updated to `status: done` (commit be485cd5).

---

## 3. Is the FTUE proving something other tests miss?

**Yes.** The FTUE is the only CI workflow that tests:

1. **Homebrew install from the Formula** — no other workflow runs `brew install`
2. **CLI routing end-to-end** — `chump gen`, `fleet start`, `fleet status --json`, `fleet stop`
3. **Clean-machine behavior** — runs on macOS-15 with no pre-existing state

The cargo-test suite, clippy, fast-checks, and audit workflows all validate
code correctness but not the install-and-run experience. The FTUE catches
regressions like broken Formula, missing binary entrypoints, or CLI routing
that silently fails.

**The FTUE is valuable; the bug is that `chump --version` shouldn't need an LLM backend.**

---

## 4. Systemic issue: no CI-fix feedback loop

The fleet has a ship pipeline (`bot-merge.sh --auto-merge`) but no
fix pipeline. When CI goes red:

1. No agent detects the failure
2. No agent is assigned to fix it
3. The PR rots in BLOCKED state
4. The operator manually intervenes with Opus

This is the #1 reason the automation feels broken. Filing INFRA-778 to
add a CI-fix pickup mode to the dispatcher.

---

## 5. Gaps filed

| ID | Pillar | Priority | Effort | Summary |
|----|--------|----------|--------|---------|
| INFRA-777 | RESILIENT | P1 | s | `chump --version` must not require Ollama |
| INFRA-778 | EFFECTIVE | P1 | m | Fleet CI-fix pickup — agents fix their own red PRs |
| INFRA-779 | RESILIENT | P1 | xs | PR #1363 pre-push hook test missing Cargo.toml |
| INFRA-780 | RESILIENT | P1 | xs | PR #1356 clippy nonminimal_bool in cascade filter |

---

## 6. Immediate actions for operator

1. **Merge PR #1364** — all required checks pass; it's only BLOCKED by non-required `ftue`
2. **Wait for PR #1358 CI rerun** — fixes pushed; should go green on `test`, `audit`, `ACP`
3. **PR #1365** — CI still running; may pass once complete
4. **PRs #1356, #1363** — need targeted fixes per INFRA-779 and INFRA-780

---

## 7. Single-line summary

> Diagnosed 5 BLOCKED PRs to 4 root causes (undeclared env vars, neuromod test regression, clippy lint, FTUE design bug), fixed 3 on this branch, filed 4 gaps for systemic issues including the missing CI-fix feedback loop.
