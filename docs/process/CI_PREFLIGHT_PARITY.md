# CI ↔ preflight parity matrix (META-071)

**Filed:** 2026-05-23 by `curator-opus-shepherd-2026-05-23` per orchestrator dispatch during the #2422 keystone wait.
**Parent epic:** [META-070](../gaps/META-070.yaml) — quality firewall completion.
**Purpose:** enumerate every CI gate in `.github/workflows/*.yml` against the local mirror in [`src/preflight.rs`](../../src/preflight.rs), so the next round of "discovered only on remote CI" cascades can be pre-empted by filing the missing preflight mirrors.

Today's cascade (2026-05-23) layered three distinct CI-only failure modes that surfaced one-by-one only after each fix landed — YAML integrity, `events.rs` Debug bug in tests, and pre-existing fmt drift in 7 `chump-coord` files — each consuming a ~15 min CI round-trip. The pattern repeats because the operator-facing "what does `chump preflight` actually catch" surface has never been written down.

## Legend

| Status | Meaning |
|---|---|
| ✅ mirrored | Same gate runs locally via `chump preflight` |
| 🟡 partial | Some sub-checks mirrored, others not (e.g. `fast-checks` covers fmt+clippy+check+5 audits but not pr-hygiene) |
| ❌ unmirrored — easy | Shell/Python script, scope-filterable; same pattern as INFRA-1731/1787/1791/1831 |
| ❌ unmirrored — heavy | Needs full Rust build, real network, or large fixture setup |
| 🚫 NA — cloud-only | Genuinely cloud-bound (codecov upload, GH API, browser env, container builds) — do not mirror |
| 🔁 rollup | Required-marker variant of an underlying gate (e.g. `clippy-required`) — mirrors when the underlying gate does |

## Parity table

| Workflow | CI gate (job `name:`) | Preflight gate | Status | Follow-up gap |
|---|---|---|---|---|
| `ci.yml` | `changes` | — | 🚫 NA — paths-filter (always runs first) | — |
| `ci.yml` | `pr-hygiene` | — | ❌ unmirrored — easy | [`INFRA-1854`](../gaps/INFRA-1854.yaml) |
| `ci.yml` | `fast-checks` | `cargo fmt --check` + `cargo clippy -D warnings` + `cargo check` + `event-registry-audit` + `env-var-coverage` + `chump-subcommand-help` + `gap-preflight-ac-gate` + `gaps-integrity` | 🟡 partial — missing pr-hygiene sub-step | covered by `INFRA-1854` |
| `ci.yml` | `clippy` | `cargo clippy -D warnings` | ✅ mirrored | — |
| `ci.yml` | `clippy-required` | (rollup) | ✅ mirrored | — |
| `ci.yml` | `cargo-test` | — | ❌ unmirrored — heavy (full workspace test) | [`INFRA-1855`](../gaps/INFRA-1855.yaml) |
| `ci.yml` | `cargo-test-required` | (rollup) | 🔁 mirrors when `cargo-test` does | — |
| `ci.yml` | `test` | — | ❌ unmirrored — heavy (same as `cargo-test`) | rolls into `INFRA-1855` |
| `ci.yml` | `coverage` | — | 🚫 NA — codecov upload | — |
| `ci.yml` | `e2e-pwa` | — | 🚫 NA — browser env | — |
| `ci.yml` | `e2e-battle-sim` | — | 🚫 NA — heavy sim, large state | — |
| `ci.yml` | `e2e-golden-path` | — | 🚫 NA — cloud orchestration | — |
| `ci.yml` | `test-e2e` | — | 🚫 NA — cloud | — |
| `ci.yml` | `audit` | `event-registry-audit` (partial) | 🟡 partial — missing dependency audit + ip-protection audit | [`INFRA-1856`](../gaps/INFRA-1856.yaml) |
| `ci.yml` | `audit-required` | (rollup) | 🔁 mirrors when `audit` does | — |
| `ci.yml` | `*-stub` | — | 🚫 NA — placeholder for path-filter routing | — |
| `ci.yml` | `*-required` | (rollup) | 🔁 mirrors underlying | — |
| `ci.yml` | `integration-test` (System integration test INFRA-849) | — | ❌ unmirrored — heavy (needs synthetic state.db fixture) | [`INFRA-1857`](../gaps/INFRA-1857.yaml) |
| `ci.yml` | `tauri-cowork-e2e` | — | 🚫 NA — Tauri build, GUI env | — |
| `gap-status-guard.yml` | `gap-status-check` | `gap-preflight-ac-gate` (sibling, not identical) | 🟡 partial — different check class | reasonable as-is; flag if drift |
| `gap-status-guard.yml` | `gaps-integrity` | `gaps-integrity` (INFRA-1831) | ✅ mirrored | — |
| `no-anthropic-smoke.yml` | `chump-first contract — coordination layer works without Anthropic` | — | ❌ unmirrored — heavy (needs env scrub + binary spawn) | [`INFRA-1858`](../gaps/INFRA-1858.yaml) |
| `editor-integration.yml` | `ACP protocol smoke test (Zed / JetBrains compatible)` | — | ❌ unmirrored — heavy (acp protocol harness) | [`INFRA-1859`](../gaps/INFRA-1859.yaml) |
| `pr-rescue.yml` | `scan and rebase stale PRs` | — | 🚫 NA — cloud daemon (operator-facing) | — |
| `queue-driver.yml` | `drive` | — | 🚫 NA — cloud daemon | — |
| `branch-protection-drift.yml` | `drift` | — | 🚫 NA — GH API only | — |
| `audit-weekly.yml` | `audit` | — | 🚫 NA — scheduled CI only | — |
| `cargo-audit-nightly.yml` | `audit` | — | 🚫 NA — `cargo audit` against advisory db | — |
| `ftue-clean-machine-2026.yml` | `ftue` | — | 🚫 NA — clean-machine fixture, cloud-only | — |
| `release.yml` | `plan` / `build-*-artifacts` / `host` / `publish-homebrew-formula` / `announce` | — | 🚫 NA — release pipeline | — |
| `release-plz.yml` | `Test and verify` / `Release (dry-run)` / `Publish to crates.io` | — | 🚫 NA — crates.io release | — |
| `dependabot-auto-merge.yml` | `arm` | — | 🚫 NA — dependabot armer | — |
| `pr-triage-bot.yml` | `auto-fix-lint` / `file-fix-gap` / `half-impl-detector` | — | 🚫 NA — bot triage (operator-facing) | — |
| `repo-health.yml` | `fast-checks` (annotations job) | (annotation rollup only; warnings-as-failure noise) | 🟡 partial — see [INFRA-1846 separate gap](../gaps/INFRA-1846.yaml) for the warning-as-failure pattern that broke PR #2416 | meta |
| `ci-flake-rerun.yml` | `rerun` | — | 🚫 NA — flake harness | — |
| `ci-advisory.yml` | `tauri-cowork-e2e` / `e2e-battle-sim` / `e2e-golden-path` / `advisory-drift-gate` | — | 🚫 NA — advisory-only | — |
| `ci-nightly.yml` | `tauri-cowork-e2e` / `e2e-*` / `nightly-e2e-status` | — | 🚫 NA — nightly | — |
| `e2e-pwa-advisory.yml` | `PWA flake advisory (non-blocking)` | — | 🚫 NA — advisory | — |
| `e2e-dogfood-nightly.yml` | `dogfood-matrix` | — | 🚫 NA — dogfood matrix, nightly | — |
| `acp-real-clients.yml` | `ACP real-client — *` / `ACP force-fire fixture (CREDIBLE-057)` | — | 🚫 NA — real-client integration | — |
| `test-bot-autonomous.yml` | `assert pr-triage-bot commits auto-fix` | — | 🚫 NA — bot self-test | — |

## Score

| Bucket | Count |
|---|---|
| ✅ mirrored | 5 |
| 🟡 partial | 4 |
| ❌ unmirrored — easy | 1 (pr-hygiene) |
| ❌ unmirrored — heavy | 5 (cargo-test/test, audit-full, integration-test, no-anthropic-smoke, acp-smoke) |
| 🚫 NA — cloud-only | 30+ |
| 🔁 rollup | 6 |

## Filed follow-ups (6 new gaps)

These were created by this audit. Each is P1 (per META-070 ownership rule: any unmirrored gate blocking a fresh cascade gets P1).

1. **[INFRA-1854](../gaps/INFRA-1854.yaml)** — `pr-hygiene` preflight mirror (easy, ~xs)
2. **[INFRA-1855](../gaps/INFRA-1855.yaml)** — `cargo-test` / `test` preflight mirror (heavy, ~m)
3. **[INFRA-1856](../gaps/INFRA-1856.yaml)** — full `audit` job preflight mirror (currently only event-registry sub-step mirrored; needs ip-protection + cargo-audit) (~m)
4. **[INFRA-1857](../gaps/INFRA-1857.yaml)** — `integration-test` (System integration test, INFRA-849) preflight mirror (heavy, ~m)
5. **[INFRA-1858](../gaps/INFRA-1858.yaml)** — `chump-first contract / no-anthropic-smoke` preflight mirror (heavy, ~m)
6. **[INFRA-1859](../gaps/INFRA-1859.yaml)** — `acp-smoke` editor-integration preflight mirror (heavy, ~m) AND the `repo-health.yml` warning-as-failure pattern that broke PR #2416 (bundled in same gap)

## How to read this for prioritization

- The 5 ❌ heavy gates above are the **most cascade-prone** — every PR that touches Rust or scripts pays the full CI round-trip when one of them is broken on main. Mirroring even the cheapest (cargo-test) would catch 60-80% of the "broken on main, every PR fails" pattern that produced today's cascade.
- The 🟡 partials are **second priority** — they appear mirrored but actually drift; `audit` is the worst offender (3 sub-checks, only 1 mirrored).
- 🚫 NA gates are intentionally remote-only and **should not** be mirrored. Document the reason on every entry so a future curator doesn't waste cycles trying.

## Verify locally

```bash
bash scripts/ci/test-meta-071-parity-doc.sh
```

Asserts: doc exists, parses as markdown, table contains every workflow `job name:` found by grep.
