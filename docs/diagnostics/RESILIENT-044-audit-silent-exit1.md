# RESILIENT-044 — audit gate silent-exit-1 after 31 PASS lines

Filed 2026-05-30T09:55Z against the required `audit` CI gate: 31 visible
`[PASS]` lines then a silent `exit 1` with no `[FAIL]` marker, last visible
PASS being "Test 5: all docs/gaps/*.yaml files have acceptance_criteria"
(`scripts/ci/test-gap-ac-requirement.sh`).

## Root cause

At filing time, `audit` was still the pre-INFRA-2565 monolithic job: every
`scripts/ci/test-*.sh` ran as a step inside one long serial job, and any
sub-script that hit `set -euo pipefail` on a bare command failure (no
`pass()`/`fail()` wrapper) terminated the whole job silently — the failing
sub-script's own stdout just stopped, with no `[FAIL]` line, because that
sub-script never had one to print.

## Why it's no longer reproducible

`INFRA-2565` (merged 2026-06-03, see `.github/workflows/audit.yml` header
comment) split the single serial `audit` job into a 4-way `audit-shard`
matrix where **every** `scripts/ci/test-*.sh` invocation is its own named
`run:` step. A failing script now fails its own named GitHub Actions step —
attributable directly in the Actions UI (red X + step name), independent of
whether that script prints `[PASS]`/`[FAIL]` internally. Verified on today's
main (2026-08-19): `audit-shard (1..4)`, `audit`, and `audit-required` are all
green (run 32260670533).

## Residual risk + follow-up

19 of the 132 scripts referenced by `audit.yml`'s shard steps still lack any
`[PASS]`/`[FAIL]` marker convention internally (they rely on bare
`set -euo pipefail` exits). The step name narrows a future failure to one
script, but not to which assertion inside it. Follow-up filed: `META-023`.

## Closure (2026-09-02)

The gap record was left `status: open` in `docs/gaps/RESILIENT-044.yaml`
despite the diagnosis (#3733) and write-up (#3950) above already satisfying
every AC. Re-verified today: `scripts/ci/test-audit-step-isolation.sh` (the
regression guard added in #3733) still passes, and the last 100 `Audit`
workflow runs on GitHub show zero real failures (76 success / 18
superseded-cancelled / 0 red). Closing the gap record to match reality.
