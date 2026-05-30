# CI Gates Inventory (INFRA-1762)

> **Goal.** Every deterministic CI gate either has a `chump preflight` mirror
> or a documented reason it cannot have one. The autonomy loop bleeds on every
> deterministic gate that fails post-push: ~5-10 min CI round-trip + force-push
> to fix. Mirrored locally, the same failure costs ~30 s.
>
> **Status as of 2026-05-23.** ~25 PR-required gates total. 5 mirrored
> (`cargo fmt`, `cargo clippy`, `cargo check`, scoped `test-*.sh`,
> event-registry-audit per INFRA-1731). 18 deterministic gates remain missing
> mirrors. 6-8 of those filed as per-gate follow-ups (see § Follow-up gaps).
> The rest are either low-frequency, low-cost-to-fail, or genuinely require
> GitHub state.

## Reading guide

- **Tier A** — gate has a `chump preflight` mirror. Caught locally in < 30 s.
- **Tier B** — gate has a pre-push or pre-commit hook mirror but is NOT in
  `chump preflight`. (Hooks run on push/commit; preflight runs on demand.
  The autonomy boost from also having it in preflight is small.)
- **Tier C** — deterministic, mirrorable, but **no local equivalent**. These
  are the ones the autonomy loop bleeds on. **Highest leverage for new gaps.**
- **Tier D** — cannot be mirrored locally (requires GitHub API state, a
  running service, or a Linux-only environment). Documented but not filed.

---

## Tier A — locally mirrored ✅

| Gate | Where | Local mirror | Notes |
|---|---|---|---|
| `cargo fmt --check` | `fast-checks` job + `cargo-test` job | `chump preflight` step 1 (INFRA-1670) | Sub-second on warm cache |
| `cargo clippy -D warnings` | `clippy` job | `chump preflight` step 2 | ~10-60 s warm |
| `cargo check --workspace` | `cargo-test` job (prereq) | `chump preflight` step 3 | ~5-30 s warm |
| `scripts/ci/test-*.sh` (changed-only) | `fast-checks` + `audit` jobs | `chump preflight --with-tests` (scoped to diff) | Opt-in flag |
| **event-registry-audit** | `audit` job | `chump preflight` (auto-gated on diff) | **INFRA-1731 shipped #2377** |

## Tier B — hook-mirrored, not in preflight

| Gate | CI location | Hook mirror | Reason no preflight mirror |
|---|---|---|---|
| `cargo test --bin chump --tests` | `cargo-test` job | `pre-push` Guard 0g (INFRA-761) capped at 600 s (INFRA-1744) | Test runtime too long for preflight's <60 s target; pre-push catches it before push |
| `git-identity` (jeffadkins1@ for commits) | not on CI (commit-time) | `pre-commit-git-identity.sh` | Pre-commit only — would be redundant in preflight |
| `hardcoded-date` (no `2025-` literals in new code) | `fast-checks` job (`test-hardcoded-date-guard.sh`) | `pre-commit-hardcoded-dates.sh` | Pre-commit catches at edit time |
| `ac-completeness` (filed gaps have AC) | `pr-hygiene` job | `pre-commit-ac-completeness.sh` (commit-time) | Pre-commit fires; CI is the backstop |

## Tier C — missing local mirror, MIRRORABLE 🎯

These are the high-leverage follow-up targets. Each PR failure I've watched
this week was one of these.

| # | Gate (CI script) | What it checks | Local mirror? | Frequency observed | Filed gap |
|---|---|---|---|---|---|
| 1 | `test-env-vars-internal-coverage.sh` | Every `CHUMP_*` env var referenced in code is documented in `scripts/ci/env-vars-internal.txt` (DOC-026) | NO | **5+ this week** (#2363, #2367, #2381, etc. all batch-allowlists) | **INFRA-1787** |
| 2 | `test-infra-124-docs-delta-trailer.sh` | PRs touching `docs/` carry a `Net-new-docs: +N` trailer (INFRA-124) | NO | 2+ this week | **INFRA-1788** |
| 3 | `test-chump-subcommand-help.sh` | Every `chump <subcmd> --help` exits 0 (INFRA-1246) | NO | Rare but high-blast-radius regression (shipped 2× this quarter) | **INFRA-1789** |
| 4 | `test-markdown-intra-doc-links.sh` (changed-only) | No broken `.md` links in files modified by this PR (DOC-039) | NO | 1-2 per week | **INFRA-1790** |
| 5 | `test-gap-preflight-ac-gate.sh` | Open gaps with vague/empty AC are unpickable (INFRA-1259) | NO | Indirectly via `chump gap audit-ac --open` | **INFRA-1791** |
| 6 | `check-pr-scope.sh` | PR doesn't touch too many disjoint paths | NO | Operator-disciplined; rare CI fail | **INFRA-1792** |
| 7 | `test-no-claude-leak.sh` (warn-only on CI today) | No new Claude-specific refs in product-layer code (INFRA-1051) | NO | Warn-only on CI; promotion to strict planned | **INFRA-1793** |
| 8 | `test-broad-canary-coverage.sh` | `docs/process/CLAUDE_GOTCHAS.md` is updated when known-failure-mode files are touched | NO | Operator-discipline; low-frequency | **INFRA-1794** |

## Tier D — cannot mirror locally ⛔

Documented for completeness; do **not** file follow-ups.

| Gate | Why no local mirror |
|---|---|
| `gap-status-guard.yml` (status flip on merge) | Requires GitHub PR merge state from the API |
| `branch-protection-drift.yml` | Reads live branch-protection rules from GitHub repo settings |
| `pr-rescue.yml` | Polls open PRs across the repo; needs GitHub API |
| `dependabot-auto-merge.yml` | Dependabot-only; runs against bot-authored PRs |
| `release-plz.yml` | Publishes to crates.io; needs registry credentials |
| `e2e-pwa-advisory.yml` | Spins up the PWA dev server + headless browser; too heavyweight for preflight |
| `acp-real-clients.yml` | Needs Zed/JetBrains ACP runtime |
| `cargo-audit-nightly.yml` | Cron-scheduled vulnerability scan; nightly cadence by design |
| `editor-integration.yml` | Needs editor process + IPC |
| `audit-weekly.yml` | Weekly summary of audit metrics; reads merged-PR history |
| `pr-triage-bot.yml` | Triages OTHER PRs; not gating this one |
| `queue-driver.yml` | Manipulates merge queue state |
| `ftue-clean-machine-2026.yml` | Requires a fresh VM |
| `no-anthropic-smoke.yml` | Validates chump-first contract under no-network |
| `sccache health probe` | Probes R2 remote-cache connectivity in CI runner environment; local dev has different network + credentials — meaningless to run locally (INFRA-2288) |

## Promotion criteria for Tier C → Tier A

Each follow-up gap (INFRA-1787..1794) ships when:

1. The gate runs under `chump preflight` with **the same exit semantics as
   CI** (same fail messages, same fail codes).
2. The gate is **scope-gated**: skipped when the staged diff doesn't include
   any of its trigger paths. Keeps preflight fast on docs-only PRs.
3. A **per-gate bypass env var** is documented (e.g.
   `CHUMP_PREFLIGHT_SKIP_ENVVARS=1`) and emits a `preflight_<gate>_bypassed`
   audit event when used.
4. A smoke test at `scripts/ci/test-preflight-<gate>-gate.sh` asserts
   the gate fires on synthetic failure + bypass-env produces a clean 0 exit
   with the audit emit.

This is the **INFRA-1731 pattern**: that's how the event-registry mirror
shipped, and how every Tier C gap should land.

## Tracking

Each per-gate gap emits `kind=ci_gate_mirrored` when it ships, queryable via
`chump-coord ci-gate-coverage` (per INFRA-1762 AC-4). When all of
INFRA-1787..1794 land, Tier A grows from 5 → 13 gates; the autonomy-tax
falls roughly proportionally.

## Update history

- **2026-05-23** — Initial inventory. INFRA-1731 just shipped as the
  first mirror beyond cargo gates. INFRA-1787..1794 filed as per-gate
  follow-ups.
