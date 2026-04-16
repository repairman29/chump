# Execution Backends

Chump can dispatch shell commands (the `run_cli` tool family) through pluggable
backends. Phase 3.3 ships three: **local** (default), **docker**, and **ssh**.
Future phases may add Daytona, Modal, and Singularity once cloud SDK integration
is justified.

All backends shell out to system binaries. There are **no new Rust crate
dependencies** for Phase 3.3 — `docker` and `ssh` must be installed and on PATH
on the host running Chump.

## Selecting a backend

Set the `CHUMP_EXECUTION` environment variable before launching Chump:

```bash
CHUMP_EXECUTION=local   chump   # default
CHUMP_EXECUTION=docker  chump
CHUMP_EXECUTION=ssh     chump
```

Unknown values fall back to `local` (with a warning logged).

The allowlist / blocklist (`CHUMP_CLI_ALLOWLIST`, `CHUMP_CLI_BLOCKLIST`) is
applied **before** dispatch — a command rejected by the allowlist never reaches
the backend, regardless of which backend is selected.

## Backend reference

### local

Default. Runs commands on the host via `sh -c` (or `cmd /c` on Windows). This
mirrors the existing behaviour of `cli_tool::CliTool::run`. No additional
configuration.

### docker

Runs each command inside a fresh, ephemeral container (`docker run --rm`). The
container is removed after the command exits.

| Variable                | Default       | Purpose                                                         |
| ----------------------- | ------------- | --------------------------------------------------------------- |
| `CHUMP_DOCKER_IMAGE`    | `ubuntu:22.04`| Image to launch the container from.                             |
| `CHUMP_DOCKER_MOUNT`    | (none)        | Bind mount, e.g. `/host/path:/container/path`.                  |
| `CHUMP_DOCKER_NETWORK`  | `none`        | Container network mode. Default isolates the container.         |

Health check: `docker version` with a 5-second timeout. If the binary or daemon
is missing, the backend returns a clear error rather than panicking.

### ssh

Executes commands on a remote host via the system `ssh` client. Uses the user's
existing `~/.ssh/config` and key material — Chump never handles passwords.

| Variable             | Default        | Purpose                                            |
| -------------------- | -------------- | -------------------------------------------------- |
| `CHUMP_SSH_HOST`     | (required)     | Remote hostname or alias.                          |
| `CHUMP_SSH_USER`     | `$USER`        | Remote username.                                   |
| `CHUMP_SSH_PORT`     | `22`           | Remote port.                                       |
| `CHUMP_SSH_OPTIONS`  | (none)         | Extra ssh flags (whitespace-separated).            |

`BatchMode=yes` is always passed so a missing key fails fast instead of
prompting interactively.

Health check: `ssh -o BatchMode=yes -o ConnectTimeout=5 <host> echo ok`.

## Security considerations

- **local** has full host authority. The existing `CHUMP_CLI_ALLOWLIST`
  /`CHUMP_CLI_BLOCKLIST` and the heuristic risk checks in `cli_tool.rs` apply.
- **docker** runs in an isolated container with `--network=none` by default. The
  blast radius of a runaway command is limited to the container; nothing
  persists after `--rm`. If you mount the host filesystem via
  `CHUMP_DOCKER_MOUNT`, that isolation is reduced accordingly.
- **ssh** executes commands on a remote machine you trust. Chump assumes the
  host is allowed to act with the configured key's privileges. Key management
  is out of scope — use `ssh-agent` and `~/.ssh/config` as you would normally.

## Adding a new backend

1. Create `src/execution/<name>.rs` implementing the `ExecutionBackend` trait
   from `src/execution/mod.rs`. The trait requires `name()`, `execute()`, and
   `health_check()`.
2. Register the module in `src/execution/mod.rs` (`pub mod <name>;`).
3. Add a match arm in `get_backend()` for the new `CHUMP_EXECUTION` value.
4. Document the new backend's environment variables here.
5. Add unit tests covering the factory branch and the new backend's argument
   construction. Backends that depend on external binaries should fail
   gracefully in `health_check()` when the binary is missing — see
   `docker.rs::tests::health_check_returns_helpful_error_when_docker_missing`
   for the pattern.
