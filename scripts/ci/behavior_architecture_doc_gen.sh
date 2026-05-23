#!/usr/bin/env bash
# scripts/ci/behavior_architecture_doc_gen.sh — INFRA-1722
#
# Behavior test for the ARCHITECTURE.md generator. Synthesizes a tiny Rust
# repo with 3 modules + 2 deps + 5 pub fns, runs the generator with the
# Custodian content-bot disabled (--no-bot), and asserts that:
#
#   1. Generator exits 0.
#   2. Output file exists at <fixture>/docs/ARCHITECTURE.md.
#   3. All four expected deterministic section headings are present:
#        ## Module topology
#        ## Key primitives
#        ## Dependencies
#        ## Public surface
#   4. The Custodian placeholder marker `<!-- CUSTODIAN: fill in -->` is
#      present (since --no-bot suppresses the bot invocation).
#   5. Each of the 3 fixture modules is mentioned in the output.
#   6. At least one ambient event with kind=architecture_doc_regenerated
#      is appended to the supplied --ambient-log path.
#
# Honors $CHUMP_BIN discovery for parity with sibling tests, but the
# generator itself is pure bash so we just run it via absolute path.
#
# Exit codes:
#   0 all checks passed
#   1 one or more checks failed

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
GENERATOR="$REPO_ROOT/scripts/ops/generate-architecture-doc.sh"

PASS=0
FAIL=0

check() {
    local label="$1"
    local ok="$2"
    if [[ "$ok" == "ok" ]]; then
        echo "  PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $label — $ok" >&2
        FAIL=$((FAIL + 1))
    fi
}

if [[ ! -x "$GENERATOR" ]]; then
    echo "[arch-doc-smoke] FAIL: generator missing or not executable at $GENERATOR" >&2
    exit 1
fi

# ── 1. Synthesize a tiny multi-module Rust repo ────────────────────────────
FIXTURE="$(mktemp -d -t chump-arch-smoke.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT
echo "[arch-doc-smoke] fixture: $FIXTURE"

mkdir -p "$FIXTURE/src" "$FIXTURE/src/inner" "$FIXTURE/.chump-locks"

cat >"$FIXTURE/Cargo.toml" <<'TOML'
[package]
name = "arch-doc-fixture"
version = "0.1.0"
edition = "2021"

[dependencies]
anyhow = "1"
serde = "1"
TOML

# Module 1 — lib root with re-exports and one pub fn.
cat >"$FIXTURE/src/lib.rs" <<'RUST'
//! Fixture crate root.
pub mod widget;
pub mod gadget;

use anyhow::Result;

/// Create the default widget configuration.
pub fn default_config() -> Result<()> {
    Ok(())
}
RUST

# Module 2 — widget with a struct + two pub fns.
cat >"$FIXTURE/src/widget.rs" <<'RUST'
//! Widget primitives.
use serde::Serialize;

/// A widget for testing.
#[derive(Serialize)]
pub struct Widget {
    pub size: u32,
}

/// Construct a new widget.
pub fn make_widget(size: u32) -> Widget {
    Widget { size }
}

/// Resize an existing widget in place.
pub fn resize_widget(w: &mut Widget, size: u32) {
    w.size = size;
}
RUST

# Module 3 — gadget with a trait and two pub fns.
cat >"$FIXTURE/src/gadget.rs" <<'RUST'
//! Gadget abstraction.

/// Anything that can be flipped on or off.
pub trait Switchable {
    fn flip(&mut self);
}

/// Wrap a value as a switchable gadget.
pub fn wrap_gadget(v: u32) -> u32 {
    v + 1
}

/// Inspect a gadget without modifying it.
pub fn inspect_gadget(v: u32) -> u32 {
    v
}
RUST

# ── 2. Run the generator with --no-bot ─────────────────────────────────────
AMBIENT_LOG="$FIXTURE/.chump-locks/ambient.jsonl"
OUTPUT="$FIXTURE/docs/ARCHITECTURE.md"

echo "[arch-doc-smoke] running generator"
if "$GENERATOR" "$FIXTURE" --no-bot --ambient-log "$AMBIENT_LOG" >"$FIXTURE/gen.stdout" 2>"$FIXTURE/gen.stderr"; then
    check "generator exits 0" "ok"
else
    rc=$?
    check "generator exits 0" "exit code $rc"
    echo "--- gen.stderr ---" >&2
    cat "$FIXTURE/gen.stderr" >&2
    echo "------------------" >&2
fi

# ── 3. Output file lands ────────────────────────────────────────────────────
if [[ -f "$OUTPUT" ]]; then
    check "ARCHITECTURE.md exists at $OUTPUT" "ok"
else
    check "ARCHITECTURE.md exists at $OUTPUT" "missing"
    echo "[arch-doc-smoke] FAILED at output-existence check; aborting further assertions" >&2
    exit 1
fi

# ── 4. Four section headings present ────────────────────────────────────────
for heading in "## Module topology" "## Key primitives" "## Dependencies" "## Public surface"; do
    if grep -qF "$heading" "$OUTPUT"; then
        check "section heading present: '$heading'" "ok"
    else
        check "section heading present: '$heading'" "not found in $OUTPUT"
    fi
done

# ── 5. Custodian placeholder present (because --no-bot) ─────────────────────
if grep -qF "<!-- CUSTODIAN: fill in -->" "$OUTPUT"; then
    check "Custodian placeholder present" "ok"
else
    check "Custodian placeholder present" "not found"
fi

# ── 6. Each module file mentioned ───────────────────────────────────────────
for module in "src/lib.rs" "src/widget.rs" "src/gadget.rs"; do
    if grep -qF "$module" "$OUTPUT"; then
        check "module mentioned in output: $module" "ok"
    else
        check "module mentioned in output: $module" "not found"
    fi
done

# ── 7. Ambient event emitted ────────────────────────────────────────────────
if [[ -f "$AMBIENT_LOG" ]] && grep -q '"kind":"architecture_doc_regenerated"' "$AMBIENT_LOG"; then
    check "ambient event 'architecture_doc_regenerated' emitted" "ok"
else
    check "ambient event 'architecture_doc_regenerated' emitted" "not found in $AMBIENT_LOG"
    [[ -f "$AMBIENT_LOG" ]] && { echo "--- ambient.jsonl ---" >&2; cat "$AMBIENT_LOG" >&2; }
fi

# ── 8. Required ambient fields present ──────────────────────────────────────
if [[ -f "$AMBIENT_LOG" ]] && grep -q '"repo":' "$AMBIENT_LOG" && \
   grep -q '"lines_changed":' "$AMBIENT_LOG" && \
   grep -q '"sections_touched":' "$AMBIENT_LOG"; then
    check "ambient event has repo+lines_changed+sections_touched fields" "ok"
else
    check "ambient event has repo+lines_changed+sections_touched fields" "missing one or more required fields"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
if [[ $FAIL -gt 0 ]]; then
    echo "[arch-doc-smoke] FAILED: $FAIL check(s) failed, $PASS passed" >&2
    exit 1
fi
echo "[arch-doc-smoke] All $PASS checks passed"
