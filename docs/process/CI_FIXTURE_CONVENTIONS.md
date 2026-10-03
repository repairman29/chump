# CI test fixture conventions (INFRA-505)

Moved out of `AGENTS.md` by ZERO-WASTE-125 (rulebook line-budget cut).

Tests under `scripts/ci/` must not couple to real gap IDs or live file
paths as fixtures — every architectural change cascades into test fixes
otherwise (5 cascading breaks during the YAML-deletion arc, INFRA-499).

**Allowed patterns:**

- **Self-contained reservation:** reserve a fresh gap on-the-fly with
  `chump gap reserve` (e.g. `coord-surfaces-smoke.sh`).
- **Synthetic IDs:** use placeholder IDs that can never be real gaps:
  `INFRA-B1`, `EVAL-TEST`, `TEST-A` — uppercase `TEST` prefix or a letter
  suffix signals synthetic.
- **Isolated temp repo:** create a `$(mktemp -d)` git repo with arbitrary
  fixture data; the fixture IDs are contained within that temp tree.
- **Fixture-as-argument:** accept `--gap-id <ID>` so CI can pass any ID.

**Required when you break a rule:**

If a test references a real gap ID or a live `docs/gaps/<ID>.yaml` path,
add a `# why this is OK:` comment immediately before the reference that
explains: (a) what the fixture is, (b) why it cannot be replaced, and (c)
that the file is not actually read from the live repo.

Violation without a comment is a PR review blocker. See
`scripts/ci/test-ci-fixture-coupling.sh` for the automated lint.
