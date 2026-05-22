#!/usr/bin/env bash
# INFRA-1691: source-contract test for `chump nugget` CLI surface.
#
# This is a source-contract test (not a behavioral test) because the binary
# requires network + CHUMP_TEAM_URL + Supabase credentials to run end-to-end.
# We assert:
#   1. The dispatch arm exists in src/main.rs and wires `chump nugget` →
#      nugget::run, parallel to how `chump preflight` is wired.
#   2. src/nugget.rs exposes a `pub fn run(argv: &[String]) -> i32` entry point.
#   3. The five canonical subcommands (add/list/search/keep/delete) are all
#      reachable through the source — drift between docs and code is what
#      this guard exists to catch.
#   4. The --help body advertises every documented subcommand.
#
# Behavioral test (real Supabase round-trip) lives under INFRA-1694.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

fail() {
    echo "[test-chump-nugget-cli] FAIL: $1" >&2
    exit 1
}

# 1. Dispatch arm wired in main.rs.
if ! grep -q 'Some("nugget")' src/main.rs; then
    fail "src/main.rs is missing the \`Some(\"nugget\")\` dispatch arm"
fi
if ! grep -q 'nugget::run' src/main.rs; then
    fail "src/main.rs does not call nugget::run"
fi
if ! grep -Eq '^mod nugget;' src/main.rs; then
    fail "src/main.rs is missing \`mod nugget;\`"
fi

# 2. Entry point shape — `pub fn run(argv: &[String]) -> i32`.
if [ ! -f src/nugget.rs ]; then
    fail "src/nugget.rs does not exist"
fi
if ! grep -Eq 'pub fn run\(argv: &\[String\]\) -> i32' src/nugget.rs; then
    fail "src/nugget.rs is missing \`pub fn run(argv: &[String]) -> i32\`"
fi

# 3. Each documented subcommand has a do_<sub> implementation.
for sub in add list search keep delete; do
    if ! grep -Eq "async fn do_${sub}\\(" src/nugget.rs; then
        fail "src/nugget.rs is missing async fn do_${sub}(...)"
    fi
done

# 4. Help body covers every subcommand by name. The string check guards
#    against drift where someone removes a subcommand from --help but leaves
#    the dispatch arm — both must remain in sync for users to find it.
for sub in add list search keep delete; do
    if ! grep -Eq "^[[:space:]]+${sub}[[:space:]]" src/nugget.rs; then
        fail "src/nugget.rs --help body does not mention subcommand '${sub}'"
    fi
done

# 5. The five canonical NuggetKind values are listed in --help so users know
#    what to pass to --kind. (failure_mode + dead_end with underscores is
#    the on-the-wire format from the Rust API.)
for kind in gotcha pattern dead_end failure_mode convention other; do
    if ! grep -q "$kind" src/nugget.rs; then
        fail "src/nugget.rs is missing NuggetKind '${kind}' in help/parser"
    fi
done

# 6. Confidence levels are surfaced.
for c in low medium high; do
    if ! grep -q "\"$c\"" src/nugget.rs; then
        fail "src/nugget.rs is missing Confidence '${c}' in parser"
    fi
done

# 7. The Cargo dep is in place so `cargo build --bin chump` can compile us.
if ! grep -Eq '^chump-team = \{ path = "crates/chump-team"' Cargo.toml; then
    fail "Cargo.toml is missing the chump-team path dependency"
fi

echo "[test-chump-nugget-cli] PASS"
