# CLI Exit Code Convention (CREDIBLE-017)

All `chump` CLI commands follow a consistent exit code convention:

| Exit code | Meaning       | When used                                           |
|-----------|---------------|-----------------------------------------------------|
| `0`       | Success       | Command completed successfully                      |
| `1`       | Runtime error | I/O error, server unreachable, operation failed     |
| `2`       | Usage error   | Missing/invalid arguments, unknown subcommand       |

## Rationale

Standard exit codes make `chump` composable with shell scripts, CI pipelines,
and monitoring systems. The convention mirrors common Unix practice (EXIT_FAILURE=1)
and adds `exit(2)` to distinguish user mistakes from system failures.

## Maintenance

- `exit(0)`: only at the end of successful `fn main()` or explicit success paths
- `exit(1)`: any error that isn't a usage mistake — file not found, API error, etc.
- `exit(2)`: errors that indicate the caller used the wrong syntax — missing args,
  unknown subcommand, invalid flag combination

All 134 `std::process::exit()` calls across the codebase were audited in CREDIBLE-017.
