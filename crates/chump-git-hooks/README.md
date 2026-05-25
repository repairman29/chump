# chump-git-hooks

Rust-native git hook framework for Chump. **Phase 1 of INFRA-1997 /
META-107** (Rust-First Migration Blueprint).

## Why

[`scripts/git-hooks/pre-push`](../../scripts/git-hooks/pre-push) is a
1200-line bash script with ~57 direct `git` invocations. INFRA-1950
(2026-05-23 TRUNK_RED — 5 main CI failures over 16 hours) traced root
cause to **environment-variable leakage from GitHub Actions self-hosted
runner-listener**: `GIT_DIR`, `GIT_WORK_TREE`, and `GITHUB_WORKSPACE`
leaked into hook children, silently redirecting `git rev-parse
--show-toplevel` to the runner's own checkout. Guard 3
(force-with-lease race protection, INFRA-345) silently passed when it
should have blocked.

Bash's environment-inheritance model is the failure surface. This crate
moves the framework to Rust where:

- **Single env-scrub point**: `HookContext::new_from_stdin` removes the
  leak-class vars before any other code runs.
- **Centralised git invocation**: `HookContext::git()` returns a
  pre-configured `Command` with `env_clear()` and `-C <repo_root>` baked
  in — no guard can accidentally inherit env.
- **Typed Hook trait**: each guard is a `Hook` impl returning a typed
  `HookOutcome`.

## Phase 1 scope

- New crate skeleton: `HookContext`, `HookOutcome`, `BlockReason`, `Hook`
  trait, `run_hooks` runner.
- ONE concrete guard ported: `ForceWithLeaseRaceGuard` (the INFRA-345
  Guard 3 that INFRA-1950 bypassed under env-leak).
- Two **stub** Hook impls (`StdinDoubleDrainGuard`,
  `SilentNoopAlarmGuard`) that return `Pass`. Real ports land in
  follow-up sub-gaps.
- Binary `chump-pre-push` reads stdin and runs the phase-1 chain.
- Feature flag: `CHUMP_PREPUSH_RUST=1` in the bash shim selects Rust;
  otherwise bash hook runs unchanged.

## Phase 1 non-goals

- **NO new ambient event kinds.** The hook logs via `tracing` only.
- **NO touches to `scripts/ci/event-registry-reserved.txt`.**
- **NO cutover.** Both hooks run in parallel during 1-week validation.
- **NO port of the other 10 guards** (mass-deletion, fmt-drift, ratchet,
  broad-canary, etc.). Each gets its own sub-gap.

## Local quickstart

```bash
PATH=$HOME/.cargo/bin:$PATH cargo check -p chump-git-hooks
PATH=$HOME/.cargo/bin:$PATH cargo clippy -p chump-git-hooks -- -D warnings
PATH=$HOME/.cargo/bin:$PATH cargo test -p chump-git-hooks
bash scripts/ci/test-prepush-rust-env-immunity.sh
```

## Usage from the bash shim

```bash
# Activate Rust path:
CHUMP_PREPUSH_RUST=1 git push

# Bypass force-lease race guard (rare, intentional clobber):
CHUMP_FORCE_LEASE_CHECK=0 CHUMP_PREPUSH_RUST=1 git push
```

## Related gaps

- INFRA-1997: this Phase 1 (current).
- INFRA-1950: yesterday's bash patch — PR #2540 closed in favour of
  wizard's #2539.
- INFRA-1986: stdin double-drain (stub here, full port in follow-up).
- INFRA-1988: silent-noop alarm (stub here, full port in follow-up).
- META-107: Rust-First Migration Blueprint umbrella.
