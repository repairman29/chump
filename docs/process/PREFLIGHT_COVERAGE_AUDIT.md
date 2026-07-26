# Preflight Coverage Audit (INFRA-2350 / META-269)

> Snapshot of which CI gates from `.github/workflows/ci.yml` are mirrored
> locally by `chump preflight` (and which intentionally are NOT). Refreshed
> any time the list changes. Pairs with the INFRA-2120 / INFRA-1867
> preflight-vs-CI parity gate so unmirrored gates can't silently drift back
> in without a classification.

## Why this exists

Operator's META-269 framing: "I just keep asking myself why we don't know
something is 'off-track' and then make an agent go figure it out." The
detection layer for off-track CI was the slowest leg — every push that
failed CI on GitHub cost ~15 minutes of round-trip vs. <60s caught locally.
The INFRA-1670 preflight tool exists; this doc tracks _which gates it
covers_ so coverage holes are visible.

## Coverage taxonomy

Every required CI gate falls into one of:

| Bucket | Meaning | Action when adding a new CI step |
|--------|---------|----------------------------------|
| **Mirrored** | Gate also runs in `chump preflight`. Same command, same exit semantics. | None — already covered. |
| **Tier-D** | Gate cannot run locally (talks to GitHub APIs, merge queue, branch protection). | Add to `docs/process/CI_GATES_INVENTORY.md` Tier-D section. |
| **Allowlist** | Gate could mirror but is currently exempt (advisory, fixture-only, etc.). | Add to `scripts/ci/preflight-ci-parity-exceptions.txt` with reason. |

The pre-commit hook (block 18) and the CI step `preflight-vs-CI parity
smoke (INFRA-1867)` enforce that every new `run:` step lands in exactly
one bucket.

## INFRA-2350 (this audit) added the following mirrors

These three gates ran in CI but **not** in `chump preflight` until this
session. They each fire in <1s and cover failure classes that previously
required a CI round-trip to surface:

| Gate | CI step (ci.yml line) | Mirror (preflight.rs gate name) | Skip env var |
|------|----------------------|--------------------------------|--------------|
| INFRA-1658 pipefail-race-sweep | `scripts/ci/test-pipefail-race-sweep.sh` (L874) | `pipefail-race-sweep` | `CHUMP_PREFLIGHT_SKIP_PIPEFAIL` |
| INFRA-682 path-filter-coverage | `scripts/ci/check-path-filter-coverage.sh` (L1702) | `path-filter-coverage` | `CHUMP_PREFLIGHT_SKIP_PATHFILTER` |
| INFRA-1810 install-script-manifest | `scripts/ci/test-install-script-manifest.sh` (L554) | `install-manifest` | `CHUMP_PREFLIGHT_SKIP_INSTALLMAP` |

All three live under `GateKind::Scripts` so they fire when scripts/setup
or .github/workflows files are staged. Each bypass env var emits a
`preflight_<gate>_bypassed` ambient event for audit-trail (same pattern
as INFRA-1731 #2377).

## Already-mirrored gates (snapshot at INFRA-2350 time)

| CI step | preflight gate |
|---------|----------------|
| cargo fmt --check | `cargo fmt --check` (Rust scope) |
| cargo clippy -D warnings | `cargo clippy -D warnings` (Rust scope) |
| cargo check --workspace | `cargo check` (Rust scope) |
| INFRA-1731 event-registry-coverage | `event-registry-audit` (Rust scope) |
| INFRA-1787 env-var-coverage | `env-var-coverage` (Rust scope) |
| INFRA-1789 chump-subcommand-help | `chump-subcommand-help` (Rust scope) |
| INFRA-1791 gap-preflight-ac-gate | `gap-preflight-ac-gate` (Rust scope) |
| INFRA-1831 gaps-integrity (META-070) | `gaps-integrity` (Rust scope) |
| INFRA-1790 markdown-intra-doc-links (DOC-039) | `markdown-intra-doc-links` (Rust scope) |
| INFRA-1855 cargo-test workspace (META-070) | `cargo-test` (Rust scope) |
| INFRA-1857 system-integration-test (INFRA-849) | `integration-test` (Rust scope) |
| INFRA-1858 chump-first-contract (CREDIBLE-046) | `chump-first-contract` (Rust scope) |
| INFRA-1859 acp-smoke | `acp-smoke` (Rust scope) |
| INFRA-1854 pr-hygiene (CREDIBLE-027 + INFRA-1568) | `pr-hygiene` (Scripts scope) |
| **INFRA-2350 pipefail-race-sweep (INFRA-1658)** | **`pipefail-race-sweep` (Scripts scope) — NEW** |
| **INFRA-2350 path-filter-coverage (INFRA-682)** | **`path-filter-coverage` (Scripts scope) — NEW** |
| **INFRA-2350 install-manifest (INFRA-1810)** | **`install-manifest` (Scripts scope) — NEW** |
| INFRA-1788 docs-delta-trailer | `docs-delta-trailer` (--pre-commit only) |
| pre-commit-ac-completeness.sh (META-070) | `ac-completeness` (--pre-commit only) |
| pre-commit-css-token-discipline.sh (INFRA-1590, META-070) | `css-token-discipline` (--pre-commit only) |
| pre-commit-default-flip.sh (INFRA-762, META-070) | `default-flip` (--pre-commit only) |
| pre-commit-effect-metric.sh (META-070) | `effect-metric` (--pre-commit only) |
| pre-commit-event-registry.sh (INFRA-754, META-070) | `event-registry-staged` (--pre-commit only) |
| pre-commit-gap-divergence.sh (INFRA-783, META-070) | `gap-divergence` (--pre-commit only) |
| pre-commit-git-identity.sh (INFRA-787, META-070) | `git-identity` (--pre-commit only) |
| pre-commit-hardcoded-dates.sh (INFRA-971, META-070) | `hardcoded-dates` (--pre-commit only) |
| pre-commit-main-worktree-config.sh (INFRA-1060, META-070) | `main-worktree-config` (--pre-commit only) |
| pre-commit-obs-budget.sh (INFRA-755/INFRA-2425, META-070) | `obs-budget` (--pre-commit only) |
| pre-commit-preflight-ci-parity.sh (INFRA-2120, META-070) | `preflight-ci-parity` (--pre-commit only) |
| pre-commit-pwa-index-uniq.sh (META-070) | `pwa-index-uniq` (--pre-commit only) |
| pre-commit-redundancy.sh (META-070) | `redundancy` (--pre-commit only) |
| pre-commit-rust-first.sh (META-064, META-070) | `rust-first` (--pre-commit only) |

## INFRA-3377 (META-070) added: commit-content-guards mirrors

The AC for INFRA-3377 pointed at
`docs/process/AUDIT_JOB_DECOMPOSITION.md#commit-content-guards-infra-3377`
for the canonical list of 22 scripts to mirror. That doc does not exist on
`origin/main` (verified via `git ls-tree origin/main` at implementation
time) — it was never written before the gap was filed. Rather than block
on a doc that doesn't exist, this slice scoped "commit-content-guards" to
the concrete, currently-invoked inventory: every
`scripts/git-hooks/pre-commit-*.sh` script, each of which greps
`git diff --cached` directly (the literal definition of a commit-content
guard). That inventory is 14 scripts, all now mirrored into
`chump preflight --pre-commit` (see table above, all tagged META-070).

Unlike the INFRA-2350 mirrors above, these do NOT get their own
per-gate preflight-level opt-out toggle — each underlying script already
owns a `CHUMP_<NAME>_CHECK=0` disable var, and
`scripts/ci/test-no-new-bypass-env-vars.sh`'s EFFECTIVE-094 debt-ceiling
means a second layer of skip vars would only grow the bypass-var count
with no new capability. Disable at the source script instead.

Verification: `bash scripts/ci/test-preflight-content-guard-mirrors.sh`
asserts all 14 gates are reachable from `preflight.rs` AND that every
`pre-commit-*.sh` script on disk is accounted for (catches a new hook
script landing without a preflight mirror).

If a future session decomposes AUDIT_JOB_DECOMPOSITION.md's original
22-script list and it differs from this 14-script inventory, extend
`CONTENT_GUARD_MIRRORS` in `src/preflight.rs` and the `EXPECTED_GATES`
array in the test script above.

## Known coverage holes (filed as follow-ups)

These CI gates are not yet mirrored. Each is reasonable to mirror once
either (a) the gate's runtime drops below the speed-target budget for its
scope or (b) the failure-class frequency justifies the round-trip cost
saved. Filed under META-269 follow-up:

- `test-workflow-linux-guard.sh` (INFRA-1539) — Scripts scope candidate.
- `test-no-claude-leak.sh` — Scripts scope candidate.
- `check-mass-deletion.sh` (CREDIBLE-027) — Scripts scope candidate (already
  partially covered via pr-hygiene wrapper).
- `test-self-hosted-runner-deps.sh` — Tier-D-eligible (runner-specific).

When wiring any of these, follow the established pattern in `src/preflight.rs`:
1. Conditional `if std::env::var("CHUMP_PREFLIGHT_SKIP_<NAME>")` guard.
2. Audit-trail emit on bypass.
3. `steps.push(step(...))` in the appropriate GateKind scope block.
4. Update this audit doc + add help-text entry.

## Verification

The integration test at `scripts/ci/test-preflight-coverage.sh` (INFRA-2350)
asserts that the three new gates are wired into the preflight binary —
keeps this doc honest by catching silent removal.

```bash
bash scripts/ci/test-preflight-coverage.sh
# Exits 0 when all three gates are reachable from preflight.
```
