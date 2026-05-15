# Codebase dry-up — operator policy

> Today the fleet codebase is ~47% shell by lines of code. The Rust-native
> standard says: new fleet primitives ship as `chump <subcommand>` (Rust),
> not as a new bash script in `scripts/coord/`. This doc is the policy the
> CI lint gates enforce.

## The three Phase-1 lint gates

| Gate | Refuses | Filed as |
|---|---|---|
| `test-no-direct-auto-merge-arm.sh` | new `gh pr merge --auto` outside `auto-merge-armer.sh` | INFRA-1223 (shipped) |
| `test-no-raw-gh-in-hot-paths.sh` | new raw `gh api`/`gh pr` in `scripts/coord/dispatch/ops/` outside `lib/` | INFRA-1274 (shipped) |
| `test-no-new-coord-shell.sh` | **new `scripts/coord/*.sh` files** | **INFRA-1305 (this doc)** |
| `test-no-new-shell-tests-for-rust.sh` | new `scripts/ci/test-*.sh` for code that has a Rust subcommand | INFRA-1306 (pending) |
| `test-no-inline-ambient-printf.sh` | new inline `printf … >> ambient.jsonl` (must call `chump emit-ambient`) | INFRA-1307 (pending) |

## Why this matters

Bash is fine for what it's fine for — quick orchestration, one-shot operator
tools. It's a poor fit for the fleet coordination layer because:

1. **No compiler** — bugs surface at runtime. INFRA-1166's
   `python3 - <<HEREDOC` stdin-collision (filed as INFRA-1278) lived in
   production for weeks because shell.
2. **Pattern duplication** — 62 raw-gh callers cataloged by INFRA-1274 each
   re-implement throttle, criticality, cache.
3. **Hard to refactor without test coverage** — adding bash test coverage
   adds more bash, compounding the problem.
4. **Runtime feedback loop is fast, structural feedback is absent** — easy
   to debug one script, impossible to verify a cross-script invariant.

## When new shell is OK

The lint doesn't ban shell. It bans **new coord shell** without a stated
reason. Cases where adding shell is the right call:

- **One-shot operator recovery** — e.g. `scripts/coord/recover-worktree-by-hand.sh`
  for the operator to run when a known failure mode happens. These should
  be small (<100 LOC) and call into existing `chump <subcommand>` for the
  actual work.
- **Thin wrapper around a Rust subcommand** — when muscle memory or shell
  PATH integration matters more than the wrapper's existence.
- **Bash-native tooling** — git hooks, where shell IS the runtime contract.
  These live in `scripts/git-hooks/` and are out of scope for this gate.

In all three cases:
1. Add the path to `scripts/ci/coord-shell-allowlist.txt` with a
   `# reason: <why>` comment.
2. File a follow-up migration gap referencing INFRA-1229 (umbrella) if the
   shell is medium-lived.

## When new Rust is OK

Almost always. Concretely:

- New fleet primitive (e.g. "scan for X every N seconds, react with Y") →
  `chump <verb>` subcommand in `src/main.rs` or its own module under
  `src/`.
- New API consumer (e.g. "post to GitHub if condition holds") → call the
  existing `chump_gh` Rust lib (or extend it).
- New ambient emit site → `chump emit-ambient --kind X` (planned, INFRA-1307).

## The migration umbrella

Phase 3 of the dry-up plan (3–6 months) ports the biggest shell scripts to
Rust. Filed gaps:

| Script | LOC | Rust target | Gap |
|---|---|---|---|
| `bot-merge.sh` | 2707 | `chump ship` | INFRA-1229 P1/xl |
| `chump-commit.sh` | 507 | `chump commit` via libgit2 | INFRA-1225 P1/m |
| `stuck-pr-filer.sh` | 662 | `chump pr stuck-scan` | INFRA-1227 P2/m |

Each port:
1. Lands the Rust subcommand with `cargo test` coverage
2. Keeps the original shell as a wrapper for one release
3. Deletes the shell after operators have re-trained their muscle memory

## Measure the drop

Operator-visible metric (TBD: surface in `chump health --slo-check`):

- **% shell of (shell + rust)** in production paths (`src/`, `crates/`,
  `scripts/coord|dispatch|ops/`)
- Today: 47.5%
- After Phase 2 lib-ification: ~40% target
- After INFRA-1229 lands: ~35% target
- After INFRA-1225/1227 land: ~30% target

The lint gates ensure the number only goes down.
