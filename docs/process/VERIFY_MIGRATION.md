# `chump verify` migration table — gate archipelago → unified policy engine

> CREDIBLE-155 (ground-up step 4, [GROUND_UP_2026-07-19.md](../design/GROUND_UP_2026-07-19.md) §3).
> One Rust engine (`src/verify/`), typed rules over **parsed** diff semantics,
> identical local + CI behavior from one implementation, machine-readable
> remediation, and ONE bypass surface: the commit trailer
> `Verify-Bypass: <rule-id>: <reason>` — every use appends one audited
> `kind=verify_bypassed` line to `.chump-locks/ambient.jsonl`.

## How the engine is wired

| Stage | Invocation | Bindingness |
|---|---|---|
| pre-commit | `chump verify --stage pre-commit` (from `scripts/git-hooks/pre-commit` block 3c dispatch) | Preview — git writes the commit message AFTER pre-commit (INFRA-1969), so trailer-aware rules cannot bind here; would-fail verdicts print, exit 0 (`--strict` flips to exit 1) |
| commit-msg | `chump verify --stage commit-msg --msg-file "$1"` (from `scripts/git-hooks/commit-msg`) | **Binding** — real message available; fails exit 1; `Verify-Bypass` trailers honored + audited |
| ci | `chump verify --stage ci --base origin/main` | **Binding** — trailers read from all commit bodies in `merge-base..HEAD`. Implemented + tested (`scripts/ci/test-credible-155.sh`); workflow step wiring deferred, see below |

Both hooks probe the installed binary's `--help` for `verify --stage` and run
the preserved legacy inline blocks when the binary predates the subcommand
(RESILIENT-172: hooks run the installed binary, not the repo) or when the
engine exits 2 (engine error — a broken engine must not silently disable a
gate, CREDIBLE-105).

**CI step deferral:** the `no-new-bypass-env-vars` gate already runs in CI via
`.github/workflows/audit.yml` → `scripts/ci/test-no-new-bypass-env-vars.sh`
(unchanged, so CI coverage did not regress), and `docs-delta`/`test-lag` were
local-hook-only before the port. Swapping the audit.yml step to
`chump verify --stage ci` requires building the chump binary in that workflow
lane (minutes of CI cost) — tracked as the follow-up gap named in this PR's
`Bypass-Followup` trailer, so the swap lands as its own reviewed change.

## Gate inventory (status as of 2026-07-19)

Rule ids are what `Verify-Bypass:` trailers name. "Legacy bypass" is the
pre-port env var, which remains only on the fallback path for ported gates.

| # | Gate | Incident receipt | Runs today | Legacy bypass | Status |
|---|---|---|---|---|---|
| 1 | docs-delta (net-new `docs/*.md` need `Net-new-docs: +N` trailer) | INFRA-009 / INFRA-124 / INFRA-1969, Red Letter #3 | commit-msg hook (+ pre-commit notice, + `src/preflight.rs` mirror) | `CHUMP_DOCS_DELTA_CHECK=0` | **PORTED** → rule `docs-delta` |
| 2 | test-lag (gap-implementing code wants `scripts/ci/test-<gap-id>.sh`) | META-032 | pre-commit block 3c | `CHUMP_TEST_LAG_CHECK=0` | **PORTED** → rule `test-lag` (semantics re-anchored: the original fired on docs/gaps YAML `status:done` flips; the YAML mirrors are retiring under ZERO-WASTE-020, so the rule now fires on new `src/`/`crates/` `.rs` files without a coverage signal — per-gap CI script, scripts/ci reference, or `#[test]` in the same diff) |
| 3 | no-new-bypass-env-vars (forbid new bypass-class `CHUMP_*` vars) | INFRA-2429 zero-bypass thesis | CI (`audit.yml`) via `scripts/ci/test-no-new-bypass-env-vars.sh` | none by design (allowlist file only) | **PORTED** → rule `no-new-bypass-env-vars` (now also enforced locally at commit-msg; the EFFECTIVE-094 debt-ceiling companion is a repo-wide count, not a diff property — it stays in the shell script until the ceiling becomes an engine-level input) |
| 4 | gaps-lock / gaps.yaml write discipline (title-hijack guard, closure discipline) | coordination audit 2026-04-17; false-positive class CREDIBLE-153 | pre-commit block 3 | `CHUMP_GAPS_LOCK=0` | **RETIRED by ZERO-WASTE-020** — the YAML mirrors it polices are being removed; do not port |
| 5 | lease-collision guard | AGENT_COORDINATION model | pre-commit block 1 | `CHUMP_LEASE_CHECK=0` | pending |
| 6 | off-rails claim-scope guard | RESILIENT-025/026, INFRA-189 | pre-commit + pre-push | `CHUMP_OFF_RAILS_CHECK=0` | pending |
| 7 | stomp-warning (stale staged files) | INFRA-WORKTREE-STAGING | pre-commit block 2 | `CHUMP_STOMP_WARN=0` | pending (advisory) |
| 8 | preregistration guard (EVAL-*/RESEARCH-* prereg) | RESEARCH-019 | pre-commit block 6b | env + trailer | pending |
| 9 | deviation-documentation guard | INFRA-824 | pre-commit block 3b' | env | pending |
| 10 | mechanism-kappa advisory | EVAL-093 | pre-commit block 3a | advisory | pending |
| 11 | submodule sanity (dangling gitlinks) | INFRA-018 | pre-commit block 4 | env | pending |
| 12 | book/src ↔ docs/process sync guard | INFRA-170 | pre-commit block 4b | env | pending |
| 13 | cargo-fmt auto-fix + cargo-check build guard | coordination audit 2026-04-17 | pre-commit blocks 5-6 | `CHUMP_CHECK_BUILD=0` | pending (candidate: stays in `chump preflight`, INFRA-1670) |
| 14 | credential-pattern guard | INFRA-018 | pre-commit block 8 | `CHUMP_CREDENTIAL_CHECK=0` | pending |
| 15 | pre-deploy smoke for infra changes | CREDIBLE-001 | pre-commit block 9 | env | pending |
| 16 | event-registry guard + effect_metric completeness | INFRA-754 / INFRA-1517 / INFRA-1237 | pre-commit blocks 10/10b + CI | `CHUMP_REGISTRY_GATE_MODE` | **PORTED (parallel-run)** → rule `event-registry` (CREDIBLE-157: diff-scoped, both directions — emit-without-register AND register-without-emit for entries added in the diff; scan limited to the INFRA-1287 production-path set so scripts/ci fixtures never false-positive; a registry entry for a kind already emitted elsewhere in the tree passes — reconciliation commits stay legal. Legacy shell gates stay: pre-commit block 10 and the repo-wide CI coverage audit catch history committed under bypass; effect_metric completeness (block 10b) stays shell — it checks entry fields, not pairing) |
| 17 | observability budget guard | INFRA-755 / INFRA-2425 | pre-commit block 11 | env + trailer | pending |
| 18 | default-flip advisory | INFRA-762 | pre-commit block 12 | advisory | pending |
| 19 | gap-divergence guard | INFRA-783 | pre-commit block 13 | env | pending |
| 20 | git-identity sanity guard | INFRA-787 | pre-commit block 14 | env | pending |
| 21 | hardcoded-date guard | INFRA-971 | pre-commit block 15 | env | pending |
| 22 | Rust-first decision rule | META-064 | pre-commit block 15a | `Rust-First-Bypass:` trailer | pending |
| 23 | main-worktree config guard | INFRA-1060 | pre-commit block 16 | env | pending |
| 24 | PWA index.html uniqueness guard | INFRA-1201 | pre-commit block 17a | env | pending |
| 25 | branch-protection / workflow-job alignment audit | CREDIBLE-058 | pre-commit block 17 | env | pending |
| 26 | preflight-vs-CI parity smoke | INFRA-2120 / INFRA-1867 | pre-commit block 18 + CI | `CHUMP_PREFLIGHT_PARITY_CHECK=0` | pending — dissolves as gates port (single implementation makes parity a non-problem, the CREDIBLE-155 end-state) |
| 27 | CSS token-discipline gate | INFRA-1590 | pre-commit block 19 | `Token-Discipline-Bypass:` trailer | pending |
| 28 | bypass-trailer schema validator | INFRA-2407 | commit-msg hook | `CHUMP_BYPASS_TRAILER_CHECK=0` | pending (candidate: fold into engine trailer parsing) |
| 29 | AC-completeness guard | pre-commit-ac-completeness.sh | pre-commit | env | pending |
| 30 | redundancy / no-new-duplicates gate | META-063 | pre-commit | env | pending |
| 31 | pipefail-race sweep (printf\|grep -q in hot-path scripts) | INFRA-1658 (6h debugging the INFRA-755 false-negative chain) | CI (`scripts/ci/test-pipefail-race-sweep.sh`) | `# pipefail-sweep-allowed` line marker | **PORTED (parallel-run)** → rule `pipefail-race` (CREDIBLE-157: diff-scoped over added lines in scripts/coord|git-hooks|dispatch, same marker semantics; repo-wide CI sweep stays to catch pre-existing occurrences) |
| 32 | path-filter allowlist structural coverage | INFRA-272 / INFRA-682 (skipped != passing wedges the merge) | CI (`scripts/ci/check-path-filter-coverage.sh` via test-path-filter-allowlist.sh) | none | **PORTED (parallel-run)** → rule `path-filter-allowlist` (CREDIBLE-157: fires on the diff that introduces paths under an uncovered top level; remediation names the exact `- 'dir/**'` line; repo-wide CI sweep stays as the tree-state invariant) |
| 33 | install-script manifest mapping | INFRA-1810 | CI (`scripts/ci/test-install-script-manifest.sh`) | none | **PORTED (parallel-run)** → rule `install-manifest` (CREDIBLE-157: fires on the diff that ADDS scripts/setup/install-*.sh; manifests read from the working tree so mapping in the same commit satisfies it; repo-wide CI audit stays) |

## Porting a gate (the recipe)

1. Add `src/verify/rules/<name>.rs` implementing `Rule` with the incident
   receipt copied verbatim from the shell gate.
2. Register it in `src/verify/rules/mod.rs::registry()`.
3. Unit-test with fixture `DiffFile`s (see existing rules' tests) and extend
   `scripts/ci/test-credible-155.sh` with an end-to-end fixture-repo case.
4. Wrap the legacy shell block in a `chump_verify_fallback_*` function guarded
   by the `chump_verify_probe` dispatch (see pre-commit block 3c).
5. Update this table; the legacy env bypass survives only on the fallback path.
