# cargo-gates (shard 1) — unmirrored script list (INFRA-4029, INFRA-3363 slice)

`docs/process/AUDIT_JOB_DECOMPOSITION.md` — the doc INFRA-4029's AC points at —
never landed on `main` (it was authored on several parallel META-086 fleet
attempts, none of which merged; see `git log --all -- docs/process/AUDIT_JOB_DECOMPOSITION.md`).
This file recovers the "cargo-gates (shard 1)" cluster content from the most
complete surviving attempt (commit `a9af84633`) and re-verifies it against the
current repo state, so INFRA-3363 has an accurate list to work from.

## Cluster: cargo-gates (shard 1) — 29 scripts, 29 unmirrored

All 29 scripts below are (a) invoked from `.github/workflows/audit.yml`'s
`fast-checks` job and (b) **not** present in `src/preflight.rs` as of this
audit — i.e. `chump preflight` does not run them locally, so a failure is
only caught in CI.

| script | purpose |
|---|---|
| `scripts/ci/test-gap-list-domain-summary.sh` | chump gap list domain summary + test-filter (INFRA-431) |
| `scripts/ci/test-gap-list-done-format.sh` | chump gap list done-format — closed-pr + closed-date (EFFECTIVE-024) |
| `scripts/ci/test-state-db-restore.sh` | state.db corruption recovery — restore from state.sql (INFRA-538) |
| `scripts/ci/test-pwa-e2e-gap-workflow.sh` | PWA gap workflow e2e — 4-phase stub + status transition (CREDIBLE-020) |
| `scripts/ci/test-waste-tally-domain.sh` | waste-tally --domain — token budget by domain, breach exit code (INFRA-934) |
| `scripts/ci/test-gap-audit-ac-open.sh` | gap audit-ac --open — warn on vague open gaps before claim (INFRA-936) |
| `scripts/ci/test-uuid-gap-id-compat.sh` | UUID gap-ID compatibility audit — preflight+show+auto-derive (INFRA-630) |
| `scripts/ci/test-gap-show-ac-render.sh` | gap show AC rendering — numbered list + json ac_count/ac_has_todos (CREDIBLE-033) |
| `scripts/ci/test-gap-add-note.sh` | chump gap set --add-note timestamped append (EFFECTIVE-020) |
| `scripts/ci/test-cli-output-format.sh` | CLI output format consistency — --quiet/--format/--json (EFFECTIVE-008) |
| `scripts/ci/test-gap-consolidate.sh` | gap consolidate — near-duplicate title detection (INFRA-935) |
| `scripts/ci/test-pwa-security.sh` | PWA gap endpoint security — rate limit, CSRF, headers, timeout (CREDIBLE-023) |
| `scripts/ci/test-release-lease-flag.sh` | release --lease <ID> flag — named session release (INFRA-1026) |
| `scripts/ci/test-gap-list-since.sh` | chump gap list --since filter (EFFECTIVE-018) |
| `scripts/ci/test-api-gap-queue-shape.sh` | /api/gap-queue fat shape — 15 fields, filters, sort, pillar derivation, ambient signal (INFRA-1197) |
| `scripts/ci/test-cross-pr-contract.sh` | cross-PR contract gate — refuse merge on cross-PR IPC schema mismatch (INFRA-2406) |
| `scripts/ci/test-gap-list-since-json-schema.sh` | gap list --json schema audit — required fields present in every gap object (CREDIBLE-061) |
| `scripts/ci/test-cli-version-debug.sh` | CLI version/debug flags (CREDIBLE-019) |
| `scripts/ci/test-run-fleet-cross-repo.sh` | run-fleet.sh cross-repo --repo/--locks-dir/--tmux-session flags (INFRA-634) |
| `scripts/ci/test-run-consolidation.sh` | run.sh consolidation — dispatcher + deprecation shims + README refs (INFRA-691) |
| `scripts/ci/test-tool-normalize.sh` | tool-call normalizer for weak LLMs (INFRA-740) |
| `scripts/ci/test-rollback-gap.sh` | gap rollback — runbook, rollback-gap.sh, ambient event (INFRA-899) |
| `scripts/ci/test-gap-rebalance.sh` | gap rebalance — P0 budget + pillar floor (INFRA-635) |
| `scripts/ci/test-pillar-balance.sh` | gap pillar-balance — pickable inventory per pillar (INFRA-604) |
| `scripts/ci/test-gap-quality-gate.sh` | gap quality gate — TODO/TBD ACs, invalid priority/effort (INFRA-904) |
| `scripts/ci/test-gap-templates.sh` | gap templates — pillar starter templates, gap-template.sh dispatcher (INFRA-905) |
| `scripts/ci/test-gap-profiling.sh` | per-gap performance profiling — timing wrapper, perf report, flame chart (INFRA-906) |
| `scripts/ci/test-gap-run-now.sh` | gap run-now — manual dispatch trigger, event schema, validation (INFRA-895) |
| `scripts/ci/test-gap-lifecycle-manager.sh` | gap lifecycle manager — abandoned gap detection (INFRA-870) |

## Cross-check against `.github/workflows/audit.yml` (AC2)

Re-verified 2026-09-03 against the current worktree:

- All 29 scripts above **still exist** under `scripts/ci/`.
- All 29 scripts are **still referenced** in `.github/workflows/audit.yml`'s
  `fast-checks` job.
- All 29 scripts are **still absent** from `src/preflight.rs` — no drift
  since the source survey (commit `a9af84633`, META-086). Count unchanged:
  29 scripts, 29 unmirrored.
- **No scripts added or removed** from this cluster relative to the
  recovered survey.

Verification command used:

```bash
for f in <29 script basenames>; do
  [ -f "scripts/ci/$f" ] || echo "MISSING: $f"
  grep -q "$f" .github/workflows/audit.yml || echo "NOT IN audit.yml: $f"
  grep -q "$f" src/preflight.rs && echo "NOW MIRRORED: $f"
done
```

No output from any of the three checks — the cluster is unchanged and ready
for INFRA-3363 to mirror into `src/preflight.rs`.
