---
doc_tag: canonical
owner_gap: PRODUCT-375
last_audited: 2026-11-27
---

# Execution Backends

Chump dispatches tool shell commands (`run_cli`) through pluggable execution backends implemented in `src/execution/`:

- **`local` (default):** Executes commands on the host OS via `crates/chump-pal` (`sh -c` on macOS/Linux, `cmd /C` on Windows) with process-group / Win32 Job Object cleanup.
- **`docker`:** Executes each command inside a fresh, ephemeral container (`docker run --rm`) with `--network=none` isolation by default.
- **`ssh`:** Executes commands on a remote build or GPU worker over OpenSSH (`BatchMode=yes`).

All backends use standard system binaries on `PATH`—no extra daemon or proprietary SDK is required.

---

## Selecting a Backend

Set `CHUMP_EXECUTION` in your environment or `[settings]` in `~/.chump/config.toml`:

```bash
CHUMP_EXECUTION=local   chump --once "cargo test --workspace"   # default
CHUMP_EXECUTION=docker  chump --once "pytest -q"
CHUMP_EXECUTION=ssh     chump --once "nvidia-smi"
```

Unrecognized values log a warning and fall back safely to `local`.

Command policy (`CHUMP_CLI_ALLOWLIST`, `CHUMP_CLI_BLOCKLIST`, and `CHUMP_TOOLS_ASK` approval prompts) runs **before** backend dispatch: a blocked or unapproved command never reaches `local`, `docker`, or `ssh`.

---

## Backend Reference

### 1. `local`

Runs commands directly in the working repository or claimed git worktree on macOS, Linux, or Windows. Output is capped and middle-trimmed when logs are huge so compiler output never overflows model context windows.

### 2. `docker`

Runs each command inside a disposable container (`docker run --rm`):

| Environment Variable | Default | Purpose |
|----------------------|---------|---------|
| `CHUMP_DOCKER_IMAGE` | `ubuntu:24.04` | Container image used for command execution |
| `CHUMP_DOCKER_MOUNT` | _(none)_ | Optional bind mount, e.g. `/path/to/worktree:/workspace` |
| `CHUMP_DOCKER_NETWORK` | `none` | Container network mode (`none` isolates network egress by default) |

Health check: runs `docker version` with a 5-second timeout and returns a clear diagnostic error if the Docker daemon is stopped.

### 3. `ssh`

Runs commands on a remote Linux/macOS host using your existing `~/.ssh/config` and `ssh-agent` keys (Chump never stores or prompts for SSH passwords):

| Environment Variable | Default | Purpose |
|----------------------|---------|---------|
| `CHUMP_SSH_HOST` | _(required)_ | Hostname or `~/.ssh/config` host alias |
| `CHUMP_SSH_USER` | Current OS user | Remote SSH username |
| `CHUMP_SSH_PORT` | `22` | Remote SSH port |
| `CHUMP_SSH_OPTIONS` | _(none)_ | Additional whitespace-separated `ssh` flags |

Health check: `ssh -o BatchMode=yes -o ConnectTimeout=5 <host> echo ok`.

---

## Security Considerations

- **`local`** runs with your OS user permissions. Keep `CHUMP_CLI_BLOCKLIST` and `CHUMP_TOOLS_ASK` enabled when running untrusted prompts.
- **`docker`** bounds filesystem and network blast radius to the ephemeral container; mounting host directories via `CHUMP_DOCKER_MOUNT` grants write access only to that mounted subtree.
- **`ssh`** inherits the remote account's permissions; scope SSH keys to dedicated build/worker accounts when isolating untrusted repositories.

---

## Extending `ExecutionBackend`

1. Implement the `ExecutionBackend` trait (`name()`, `execute()`, `health_check()`) under `src/execution/<backend>.rs`.
2. Register the module and `CHUMP_EXECUTION` match arm in `src/execution/mod.rs`.
3. Ensure `health_check()` returns a descriptive `Result::Err` rather than panicking when external binaries are absent, and add unit tests for argument construction.

---

## Related Guides

- [System Architecture](ARCHITECTURE.md)
- [Daemon & Service Operations](../operations/OPERATIONS.md)
