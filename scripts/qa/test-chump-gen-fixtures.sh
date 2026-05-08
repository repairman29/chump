#!/usr/bin/env bash
# test-chump-gen-fixtures.sh — INFRA-594: 10-fixture smoke suite for `chump gen`.
#
# Each fixture runs `chump gen "<task>"` in stub mode against an isolated Rust
# project; passes if the command exits 0 (which implies cargo check succeeded
# inside gen.rs). Timing and pass-rate are printed and emitted to ambient.jsonl
# as kind=gen_smoke_results.
#
# Env overrides:
#   CHUMP_BIN=/path/to/chump   — binary to test (default: target/release/chump)
#   CHUMP_GEN_SKIP_BUILD=1     — skip the binary existence check (for unit testing the script)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHUMP_BIN="${CHUMP_BIN:-$REPO_ROOT/target/release/chump}"

if [[ "${CHUMP_GEN_SKIP_BUILD:-}" != "1" ]] && [[ ! -x "$CHUMP_BIN" ]]; then
    echo "[gen-fixtures] ERROR: chump binary not found at $CHUMP_BIN" >&2
    echo "[gen-fixtures] Build with: cargo build --release" >&2
    exit 1
fi

PASS=0
FAIL=0
TOTAL=0
T_SUITE_START=$(date +%s%3N 2>/dev/null || echo 0)

# ── Fixture definitions (task description for each of the 10 fixtures) ────────
FIXTURES=(
    "add a comment explaining what this function does"
    "add #[derive(Debug)] to the Foo struct"
    "write a test for the foo function"
    "fix the off-by-one error in the loop bound"
    "rename the variable x to count"
    "add the missing std::collections::HashMap import"
    "write a Python helper script that prints hello world"
    "add a --verbose CLI flag using the clap crate"
    "write a README section explaining how to build and run the project"
    "refactor the calculate function to use early return"
)

# ── Shared fixture Rust project ───────────────────────────────────────────────
FIXTURE_DIR="$(mktemp -d -t chump-gen-fixtures.XXXXXX)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

mkdir -p "$FIXTURE_DIR/src"

cat > "$FIXTURE_DIR/Cargo.toml" <<'TOML'
[package]
name = "gen-fixture"
version = "0.1.0"
edition = "2021"
TOML

# Base source: contains a struct, a loop, a function with early-return, and a
# main — giving every fixture a real syntactic target even in stub mode.
BASE_RS='struct Foo {
    x: i32,
}

fn foo(items: &[i32]) -> i32 {
    let mut sum = 0;
    for i in 0..items.len() {
        sum += items[i];
    }
    sum
}

fn calculate(n: i32) -> i32 {
    if n < 0 {
        return -1;
    }
    if n == 0 {
        return 0;
    }
    n * n
}

fn main() {
    let x = vec![1, 2, 3];
    println!("{}", foo(&x));
}
'

git -C "$FIXTURE_DIR" init -q
git -C "$FIXTURE_DIR" config user.email "fixture@test.local"
git -C "$FIXTURE_DIR" config user.name  "Fixture Test"

printf '%s' "$BASE_RS" > "$FIXTURE_DIR/src/main.rs"
git -C "$FIXTURE_DIR" add --all
git -C "$FIXTURE_DIR" commit -q -m "initial fixture"

echo "=== test-chump-gen-fixtures.sh (INFRA-594) ==="
echo "[gen-fixtures] binary : $CHUMP_BIN"
echo "[gen-fixtures] fixture: $FIXTURE_DIR"
echo ""

# ── Per-fixture runner ────────────────────────────────────────────────────────
run_fixture() {
    local idx="$1"
    local task="$2"
    TOTAL=$((TOTAL + 1))

    # Restore main.rs to the base state so each fixture starts clean.
    printf '%s' "$BASE_RS" > "$FIXTURE_DIR/src/main.rs"
    git -C "$FIXTURE_DIR" add src/main.rs
    # Only commit if the working tree actually changed (no-op on first iteration).
    if ! git -C "$FIXTURE_DIR" diff --cached --quiet 2>/dev/null; then
        git -C "$FIXTURE_DIR" commit -q -m "fixture-${idx}: reset"
    fi

    local t0
    t0=$(date +%s%3N 2>/dev/null || echo 0)

    local output exit_code
    exit_code=0
    output="$(
        CHUMP_GEN_STUB_FILE="src/main.rs" \
            "$CHUMP_BIN" gen "$task" --work-dir "$FIXTURE_DIR" 2>&1
    )" || exit_code=$?

    local t1 elapsed_ms
    t1=$(date +%s%3N 2>/dev/null || echo 0)
    elapsed_ms=$((t1 - t0))

    if [[ $exit_code -eq 0 ]]; then
        echo "  PASS [$(printf '%2d' "$idx")/10]: $task  (${elapsed_ms}ms)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL [$(printf '%2d' "$idx")/10]: $task  (exit=${exit_code}, ${elapsed_ms}ms)" >&2
        printf '%s\n' "$output" | sed 's/^/    /' >&2
        FAIL=$((FAIL + 1))
    fi
}

# ── Run all 10 fixtures ───────────────────────────────────────────────────────
IDX=1
for task in "${FIXTURES[@]}"; do
    run_fixture "$IDX" "$task"
    IDX=$((IDX + 1))
done

T_SUITE_END=$(date +%s%3N 2>/dev/null || echo 0)
TOTAL_MS=$((T_SUITE_END - T_SUITE_START))
PASS_RATE=0
if [[ $TOTAL -gt 0 ]]; then
    PASS_RATE=$(( (PASS * 100) / TOTAL ))
fi

echo ""
echo "=== Results: ${PASS}/${TOTAL} passed (${PASS_RATE}%) in ${TOTAL_MS}ms ==="

# ── Emit gen_smoke_results to ambient.jsonl ───────────────────────────────────
EMIT_SCRIPT="$REPO_ROOT/scripts/dev/ambient-emit.sh"
if [[ -x "$EMIT_SCRIPT" ]]; then
    "$EMIT_SCRIPT" gen_smoke_results \
        pass_count="$PASS" \
        fail_count="$FAIL" \
        total="$TOTAL" \
        pass_rate="$PASS_RATE" \
        elapsed_ms="$TOTAL_MS" \
        gap="INFRA-594" 2>/dev/null || true
    echo "[gen-fixtures] emitted gen_smoke_results to ambient.jsonl"
fi

if [[ $FAIL -gt 0 ]]; then
    echo "[gen-fixtures] FAILED: ${FAIL} fixture(s) failed" >&2
    exit 1
fi

echo "[gen-fixtures] All ${PASS} fixtures passed"
