# CREDIBLE-222 — almanac drift-backlog triage

ROADMAP O2 calls almanac's CONFIG-organ DRIFT count "the organ's flagship
claim" and flags it as unverified at scale. As of 2026-08-07 that count was
211 flags on chump, up from 181, still untriaged. This is that verification.

## Method

1. **Extract** — `scripts/dev/drift-flag-extract.sh` pulls the raw
   `almanac comprehend --repo <chump> --findings-json` output (CREDIBLE-569,
   already shipped).
2. **Triage** — `scripts/dev/drift-flag-triage.py` reads the extracted JSON
   and, for every `kind=drift` finding, classifies it NOISE or REAL. Full
   rules are documented in the script's module docstring; summary:
   - almanac itself already folds exact unset-sentinel spellings before
     counting drift (INFRA-3472, landed 2026-08-31 upstream in
     `repairman29/almanac`) — `""` / `"(unset)"` / `"none"` / ... already
     collapse to one entry before this script ever sees the data.
   - This script folds what that pass misses: spellings INFRA-3472's fixed
     list doesn't cover (`"<unset>"`, `"_unset_"`, `"MISSING"`,
     `"<none specified>"`, `"not set"`, `"unknown"`, `"/dev/null"`) and
     test/mock placeholder literals (`sk-ant-mock-key-for-tests`,
     `mlx-local-dummy`, `not-needed`).
   - `$VAR`-interpolated path defaults are compared by resolved **shape**
     (leading `$VAR`/`${VAR}`/`{var}`/`.` root token stripped) rather than
     literal text, so 30+ spellings of "the lock dir" via 30+ different
     local shell-variable names compare equal.
   - A flag is REAL only if more than one shape survives AND no single
     shape accounts for ≥65% of the surviving raw variants — a landslide
     majority plus a couple of one-off outliers is still noise, not
     evidence of two code paths assuming different real behavior.

## Result (measured 2026-09-08, current almanac `comprehend` build,
   `crates/almanac-organs` @ commit `cb63334` / INFRA-3472)

| | count |
|---|---|
| Total DRIFT flags reported | **220** |
| NOISE (representation artifact) | **113** |
| **REAL** (survives triage) | **107** |

The flagship claim was over-claiming by roughly half. Re-running
`scripts/dev/drift-flag-triage.py --in <extract-output> --json` reproduces
this split against any future extraction.

### NOISE examples confirmed (verbatim from the gap's acceptance criteria)

- `ANTHROPIC_API_KEY` — `''` / `'<unset>'` / `'sk-ant-mock-key-for-tests'`
  (78 reads): three spellings of "no default configured", none of them a
  real behavioral fork.
- `CARGO_MANIFEST_DIR` — `''` / `'unknown'`: same case, two spellings.
- `CHUMP_AMBIENT_LOG` — 31 raw defaults, 307 reads: 19 are
  `<VAR>/.chump-locks/ambient.jsonl` under 19 different local variable
  names, the rest are unset/dynamic/near-miss variants of the same path.
- `CARGO_TARGET_DIR` — 12 raw defaults, 171 reads: `$REPO_ROOT/target` /
  `$ROOT/target` / `./target` / bare `target` all resolve to the same
  shape once the root token is stripped.

### REAL examples confirmed (survive triage)

- `CHUMPBAR_SSH_TIMEOUT` — `15` vs `6`, an even split, no dominant value:
  genuinely different assumed timeouts.
- `FLEET_TIMEOUT_S` — `1800` vs `600`.
- `CHUMP_WEB_PORT` — `3000` / `3001` / `3847`, three genuinely different
  ports.
- `OPENAI_API_BASE`, `REPO_ROOT`, `CHUMP_BIN`, `CHUMP_HOME`, `CHUMP_REPO`
  and 100+ others — see the full REAL list via
  `scripts/dev/drift-flag-triage.py --in <extract-output>` (non-JSON mode
  prints it sorted by reads).

The AC's own worked BEAST_MODE examples (endpoint/typo-domain/model drift)
are exercised as regression fixtures in
`scripts/ci/test-drift-flag-triage.sh` rather than reproduced here, since
`BEAST_MODE_*` flags are not currently present in chump's own codebase (they
were illustrative of the REAL class from the same triage pass done upstream
in almanac's own repo against the BEAST-MODE demo target).

## Known limitation (not fixed here — scoped out)

A number of the surviving 107 REAL flags are large multi-way "path" drifts
(`REPO_ROOT`, `CHUMP_BIN`, `CHUMP_HOME`, `CHUMP_REPO`) whose variant lists
mix genuine defaults with **per-machine/per-worktree absolute-path
snapshots** (`/Users/jeffadkins/Projects/Chump`, `/private/tmp/chump-infra-990/...`).
Those are arguably a fourth noise class (same failure mode as the $VAR
case, but the "variable" is which developer's machine or which ephemeral
worktree ran the scan) and would very likely shrink the REAL count further
under a machine-path-normalization pass. That pass is left as explicit
follow-up rather than folded in here, to avoid re-tuning the dominance
threshold against a class of data this gap's acceptance criteria didn't
call out.
