# Build and test commands

Moved out of `AGENTS.md` by ZERO-WASTE-125 (rulebook line-budget cut).

```bash
cargo build                       # debug build of full workspace
cargo build --release             # release build
cargo build --bin chump           # CLI binary only (fastest iteration)
cargo check --bin chump --tests   # type-check without codegen (use this in tight loops)
```

## Linux-first setup (INFRA-3342)

If you are on Linux, standard installation via `brew` might be unavailable
or incomplete. Follow the Linux substrate path:

1. **System dependencies:** `bash scripts/setup/provision-chumpd-host.sh --install-deps`
   installs required GTK/Webkit libs, Rust, and `gh`.
2. **Supervisor daemon:** `bash scripts/setup/install-chumpd.sh` builds and
   registers the `chumpd` supervisor with `systemd --user`.
3. **Verify:** `systemctl --user status chumpd` should show "active (running)".

`chump demo [--seed N] [--duration 60m] [--dry-run] ...` (INFRA-2391) — the
META-072 Track-3 autonomous-throughput demo loop (crates/chump-demo), execs
the sibling `chump-demo` binary built by this workspace, so `cargo build`
(which builds both bins) is a prerequisite.

## Test commands

```bash
cargo test                        # full workspace test run
cargo test -p <crate>             # single crate
cargo test <name_substr>          # filter by test name
cargo test -- --nocapture         # show println! output during tests
```
