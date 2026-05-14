# CLI Test Coverage

Tracks which `chump` CLI subcommands have integration tests and at what level.

## Coverage levels

| Level | Description |
|---|---|
| **source** | `tests/` Rust integration test — verifies module wiring, flag parsing, function exports in source |
| **shell** | `scripts/ci/` bash test — runs the binary against fixtures, checks exit codes and output |
| **e2e** | Full end-to-end test via `scripts/ci/battle-cli-no-llm.sh` or similar |

## Product surface (CREDIBLE-036)

| Command | Source | Shell | e2e | Gap |
|---|---|---|---|---|
| `chump gen` | ✓ cli_product_surface.rs | — | — | CREDIBLE-036 |
| `chump mcp list` | ✓ cli_product_surface.rs | — | — | CREDIBLE-036 |
| `chump mcp install` | ✓ cli_product_surface.rs | — | — | CREDIBLE-036 |
| `chump waste-tally` | ✓ cli_product_surface.rs | — | — | CREDIBLE-036 |
| `chump lesson-grade` | ✓ cli_product_surface.rs | — | — | CREDIBLE-036 |
| `chump session-track` | ✓ cli_product_surface.rs | — | — | CREDIBLE-036 |

## Fleet + coord surface (CREDIBLE-035)

| Command | Source | Shell | e2e | Gap |
|---|---|---|---|---|
| `chump health` | ✓ cli_fleet_coord.rs | ✓ test-cli-fleet-coord.sh | — | CREDIBLE-035 |
| `chump fleet` | ✓ cli_fleet_coord.rs | ✓ test-cli-fleet-coord.sh | — | CREDIBLE-035 |
| `chump coord` | ✓ cli_fleet_coord.rs | ✓ test-cli-fleet-coord.sh | — | CREDIBLE-035 |

## General CLI hygiene

| Check | Script | Gap |
|---|---|---|
| Help consistency | scripts/ci/test-cli-help.sh | CREDIBLE-034 |
| Exit codes | scripts/ci/test-cli-exit-codes.sh | CREDIBLE-034 |
| Output format | scripts/ci/test-cli-output-format.sh | CREDIBLE-034 |
| Aliases | scripts/ci/test-cli-aliases.sh | CREDIBLE-034 |
| Arg validation | scripts/ci/test-cli-arg-validation.sh | CREDIBLE-034 |
