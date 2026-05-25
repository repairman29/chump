#!/usr/bin/env bash
# scripts/ci/test-messaging-rust-parity.sh — INFRA-1998 Phase 1
#
# Asserts the new chump-broadcast Rust binary writes the same inbox JSONL
# (modulo timestamps) as the legacy scripts/coord/broadcast.sh callsite,
# across 5 representative messages including:
#   - special-char body (pipe | newline \n backslash)
#   - JSON-shaped body ({"nested":"json"})
#   - INTENT with comma-separated files
#   - DONE with commit sha
#   - ALERT with kind= + reason
#
# DOES NOT emit any new ambient event kinds — sets CHUMP_AMBIENT_DISABLE=1
# defensively in case the bash callsite emits inbox_advance during the
# parallel-run comparison.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Defensive: kill inherited workflow state that could redirect either path.
unset CHUMP_LOCK_DIR CHUMP_REPO CHUMP_REPO_ROOT 2>/dev/null || true
export CHUMP_AMBIENT_DISABLE=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
note() { printf '      %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Build the binaries up front.
# ---------------------------------------------------------------------------
echo "[test] building chump-messaging binaries..."
BUILD_LOG="$TMP/build.log"
if ! (cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" \
        cargo build --quiet -p chump-messaging --bin chump-broadcast --bin chump-inbox) \
        >"$BUILD_LOG" 2>&1; then
    echo "[test] BUILD FAILED — log below:"
    cat "$BUILD_LOG"
    exit 1
fi

# Locate binaries.
BROADCAST_BIN=""
INBOX_BIN=""
CARGO_TARGET_DIR_VAL="${CARGO_TARGET_DIR:-}"
for candidate_dir in \
    "$REPO_ROOT/target/debug" \
    "$REPO_ROOT/.cargo-test-target/debug" \
    "${CARGO_TARGET_DIR_VAL:+$CARGO_TARGET_DIR_VAL/debug}" \
    ; do
    [[ -z "$candidate_dir" ]] && continue
    if [[ -x "$candidate_dir/chump-broadcast" ]]; then
        BROADCAST_BIN="$candidate_dir/chump-broadcast"
    fi
    if [[ -x "$candidate_dir/chump-inbox" ]]; then
        INBOX_BIN="$candidate_dir/chump-inbox"
    fi
    [[ -n "$BROADCAST_BIN" && -n "$INBOX_BIN" ]] && break
done
if [[ -z "$BROADCAST_BIN" || -z "$INBOX_BIN" ]]; then
    fail "could not locate built binaries"
    exit 1
fi
note "chump-broadcast: $BROADCAST_BIN"
note "chump-inbox:     $INBOX_BIN"

# ---------------------------------------------------------------------------
# Create an isolated inbox dir for the Rust path. We isolate via a fake
# git-common-dir so chump-broadcast resolves its lock_dir there instead of
# the real REPO_ROOT/.chump-locks (avoids polluting the real inbox + dodges
# concurrent siblings).
# ---------------------------------------------------------------------------
RUST_ROOT="$TMP/rust-root"
mkdir -p "$RUST_ROOT"
(cd "$RUST_ROOT" && git init --quiet)
RUST_LOCK_DIR="$RUST_ROOT/.chump-locks"
RUST_INBOX_DIR="$RUST_LOCK_DIR/inbox"
mkdir -p "$RUST_INBOX_DIR"

BASH_ROOT="$TMP/bash-root"
mkdir -p "$BASH_ROOT"
(cd "$BASH_ROOT" && git init --quiet)
BASH_LOCK_DIR="$BASH_ROOT/.chump-locks"
BASH_INBOX_DIR="$BASH_LOCK_DIR/inbox"
mkdir -p "$BASH_INBOX_DIR"

RECIPIENT="recipient-fake-1998"
SENDER="sender-fake-1998"

# Helper: send via Rust path.
send_rust() {
    local level="$1"; shift
    local args=("$@")
    (cd "$RUST_ROOT" && \
        CHUMP_SESSION_ID="$SENDER" \
        CHUMP_AMBIENT_DISABLE=1 \
        CHUMP_MESSAGING_RUST=1 \
        "$BROADCAST_BIN" --to "$RECIPIENT" "$level" "${args[@]}") >/dev/null 2>&1
}

# Helper: send via bash path. We force CHUMP_MESSAGING_RUST=0 so the
# shim falls through to the legacy bash body.
send_bash() {
    local level="$1"; shift
    local args=("$@")
    (cd "$BASH_ROOT" && \
        CHUMP_SESSION_ID="$SENDER" \
        CHUMP_AMBIENT_DISABLE=1 \
        CHUMP_MESSAGING_RUST=0 \
        bash "$REPO_ROOT/scripts/coord/broadcast.sh" --to "$RECIPIENT" "$level" "${args[@]}") >/dev/null 2>&1
}

# Define the 5 representative messages. Each is (LEVEL, args...).
# We send each via Rust then via bash and compare the resulting inbox
# lines field-by-field (excluding the ts which obviously differs).

# Message 1: WARN with pipe / newline / backslash / quotes
M1_LEVEL="WARN"
M1_BODY='pipe | text and "quote" and \n backslash'

# Message 2: WARN with JSON-shaped body
M2_LEVEL="WARN"
M2_BODY='{"nested": "json", "more": [1,2,3]}'

# Message 3: INTENT with comma-separated files
M3_LEVEL="INTENT"
M3_GAP="INFRA-9999"
M3_FILES="src/foo.rs,src/bar.rs"

# Message 4: DONE with commit sha
M4_LEVEL="DONE"
M4_GAP="INFRA-9998"
M4_COMMIT="abc1234deadbeef"

# Message 5: ALERT with kind= + reason
M5_LEVEL="ALERT"
M5_KIND_ARG="kind=fleet_wedge"
M5_REASON="something is on fire"

# ---------------------------------------------------------------------------
# Step 1: Send all 5 via Rust path → RUST_INBOX_DIR/$RECIPIENT.jsonl
# ---------------------------------------------------------------------------
note "sending 5 messages via Rust path..."
send_rust "$M1_LEVEL" "$M1_BODY"               || fail "Rust send M1 failed"
send_rust "$M2_LEVEL" "$M2_BODY"               || fail "Rust send M2 failed"
send_rust "$M3_LEVEL" "$M3_GAP" "$M3_FILES"    || fail "Rust send M3 failed"
send_rust "$M4_LEVEL" "$M4_GAP" "$M4_COMMIT"   || fail "Rust send M4 failed"
send_rust "$M5_LEVEL" "$M5_KIND_ARG" "$M5_REASON" || fail "Rust send M5 failed"

RUST_INBOX_FILE="$RUST_INBOX_DIR/$RECIPIENT.jsonl"
if [[ ! -s "$RUST_INBOX_FILE" ]]; then
    fail "Rust path produced no inbox file at $RUST_INBOX_FILE"
    exit 1
fi
RUST_LINES=$(wc -l <"$RUST_INBOX_FILE" | tr -d ' ')
if [[ "$RUST_LINES" -ne 5 ]]; then
    fail "Rust inbox has $RUST_LINES lines, expected 5"
else
    ok "Rust path wrote 5 inbox lines"
fi

# ---------------------------------------------------------------------------
# Step 2: Send same 5 via bash path → BASH_INBOX_DIR/$RECIPIENT.jsonl
# ---------------------------------------------------------------------------
note "sending 5 messages via bash path..."
send_bash "$M1_LEVEL" "$M1_BODY"               || fail "Bash send M1 failed"
send_bash "$M2_LEVEL" "$M2_BODY"               || fail "Bash send M2 failed"
send_bash "$M3_LEVEL" "$M3_GAP" "$M3_FILES"    || fail "Bash send M3 failed"
send_bash "$M4_LEVEL" "$M4_GAP" "$M4_COMMIT"   || fail "Bash send M4 failed"
send_bash "$M5_LEVEL" "$M5_KIND_ARG" "$M5_REASON" || fail "Bash send M5 failed"

BASH_INBOX_FILE="$BASH_INBOX_DIR/$RECIPIENT.jsonl"
if [[ ! -s "$BASH_INBOX_FILE" ]]; then
    fail "Bash path produced no inbox file at $BASH_INBOX_FILE"
    exit 1
fi
BASH_LINES=$(wc -l <"$BASH_INBOX_FILE" | tr -d ' ')
if [[ "$BASH_LINES" -ne 5 ]]; then
    fail "Bash inbox has $BASH_LINES lines, expected 5"
else
    ok "Bash path wrote 5 inbox lines"
fi

# ---------------------------------------------------------------------------
# Step 3: Field-by-field comparison.
# We compare a stable projection of each line (drop ts, drop fields the
# bash path adds but the Rust path intentionally skips in Phase 1:
# operator_id, model, harness). The remaining fields must match exactly.
# ---------------------------------------------------------------------------
PROJ_KEYS=(event session gap files reason commit kind to corr_id urgency rationale subject)

extract_proj() {
    # Args: <jsonl-file> <line-number>
    local file="$1" lineno="$2"
    local line
    line="$(sed -n "${lineno}p" "$file")"
    [[ -n "$line" ]] || { echo ""; return; }
    python3 - "$line" "${PROJ_KEYS[@]}" <<'PY'
import json, sys
raw = sys.argv[1]
keys = sys.argv[2:]
try:
    obj = json.loads(raw)
except Exception:
    print("PARSE_ERROR")
    sys.exit(0)
proj = {}
for k in keys:
    v = obj.get(k)
    # Normalize: empty string and null both become absent for the projection.
    if v is None:
        continue
    if isinstance(v, str) and v == "":
        continue
    # Normalize auto-derived corr_id: bash falls back to "ts:..." or
    # "branch:..." when no gap-id; Rust leaves the field absent. Phase 1
    # parity ignores the auto-derived fallback shape.
    if k == "corr_id" and isinstance(v, str) and (v.startswith("ts:") or v.startswith("branch:")):
        continue
    proj[k] = v
print(json.dumps(proj, sort_keys=True))
PY
}

compare_line() {
    # Args: <line-number> <label>
    local lineno="$1" label="$2"
    local rp bp
    rp="$(extract_proj "$RUST_INBOX_FILE" "$lineno")"
    bp="$(extract_proj "$BASH_INBOX_FILE" "$lineno")"
    if [[ "$rp" == "$bp" ]]; then
        ok "M${lineno} ($label) projections match"
    else
        fail "M${lineno} ($label) projection mismatch"
        echo "      Rust : $rp"
        echo "      Bash : $bp"
    fi
}

compare_line 1 "WARN special-chars"
compare_line 2 "WARN JSON-shaped body"
compare_line 3 "INTENT gap+files"
compare_line 4 "DONE gap+commit"
compare_line 5 "ALERT kind+reason"

# ---------------------------------------------------------------------------
# Step 4: Round-trip test — chump-inbox binary reads back what
# chump-broadcast wrote (and produces valid JSON-per-line on stdout).
# ---------------------------------------------------------------------------
READBACK_OUT="$TMP/readback.txt"
(cd "$RUST_ROOT" && \
    CHUMP_SESSION_ID="$RECIPIENT" \
    "$INBOX_BIN" read --session "$RECIPIENT") >"$READBACK_OUT" 2>/dev/null || true
READBACK_LINES=$(grep -c '' <"$READBACK_OUT" || true)
if [[ "$READBACK_LINES" -eq 5 ]]; then
    ok "chump-inbox read returned 5 messages"
else
    fail "chump-inbox read returned $READBACK_LINES messages (expected 5)"
fi
# Verify each line is valid JSON.
INVALID=0
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if ! python3 -c "import json,sys; json.loads(sys.argv[1])" "$line" >/dev/null 2>&1; then
        INVALID=$((INVALID+1))
    fi
done <"$READBACK_OUT"
if [[ "$INVALID" -eq 0 ]]; then
    ok "all read-back lines are valid JSON"
else
    fail "$INVALID read-back lines failed JSON parse"
fi

# ---------------------------------------------------------------------------
# Step 5: cursor advance — second read should return zero new messages.
# ---------------------------------------------------------------------------
READBACK2_OUT="$TMP/readback2.txt"
(cd "$RUST_ROOT" && \
    CHUMP_SESSION_ID="$RECIPIENT" \
    "$INBOX_BIN" read --session "$RECIPIENT") >"$READBACK2_OUT" 2>/dev/null || true
READBACK2_LINES=$(grep -c '' <"$READBACK2_OUT" || true)
if [[ "$READBACK2_LINES" -eq 0 ]]; then
    ok "cursor advanced — second read returned 0 messages"
else
    fail "cursor failed to advance — second read returned $READBACK2_LINES messages"
fi

# ---------------------------------------------------------------------------
# Step 6: assert no new ambient event kinds emitted during the test.
# Phase 1 explicitly forbids new event kinds. We confirm the RUST inbox
# dir has no ambient.jsonl (or that any present file only has whitelisted
# kinds).
# ---------------------------------------------------------------------------
if [[ -f "$RUST_LOCK_DIR/ambient.jsonl" ]]; then
    NEW_KINDS=$(python3 - "$RUST_LOCK_DIR/ambient.jsonl" <<'PY'
import json, sys
allowed = {"INTENT","HANDOFF","STUCK","DONE","WARN","ALERT","FEEDBACK","inbox_advance"}
new = set()
with open(sys.argv[1]) as f:
    for line in f:
        line=line.strip()
        if not line: continue
        try:
            obj=json.loads(line)
        except Exception:
            continue
        k = obj.get("kind") or obj.get("event")
        if k and k not in allowed:
            new.add(k)
print(",".join(sorted(new)))
PY
    )
    if [[ -z "$NEW_KINDS" ]]; then
        ok "no new ambient event kinds emitted"
    else
        fail "new ambient event kinds emitted: $NEW_KINDS"
    fi
else
    ok "no ambient.jsonl created by Rust path (clean)"
fi

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
printf '\n'
printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
