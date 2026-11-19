#!/usr/bin/env bash
# scripts/ci/test-auto-resolve-add-both.sh — INFRA-2255
#
# Smoke test for the auto-resolve-add-both script and queue-driver.sh's
# cascade auto-resolve path.
#
# Verifies:
#   1. Script exists, executable, has shebang
#   2. No-args invocation exits 1 with usage message
#   3. Refuses files outside the allowlist (exit 2)
#   4. Strips markers + preserves both sides for each of 5 file types
#   5. Idempotent (running on clean file = no-op, exits 0)
#   6. queue-driver.sh references the script + emits the new event kinds

set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="$REPO/scripts/coord/auto-resolve-add-both.sh"
DRIVER="$REPO/scripts/coord/queue-driver.sh"

PASS=0; FAIL=0
pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 1. Script exists + executable + has shebang ──────────────────────────────
[[ -f "$TARGET" ]] || { fail "script missing: $TARGET"; exit 1; }
[[ -x "$TARGET" ]] || fail "script not executable"
head -1 "$TARGET" | grep -q '^#!/usr/bin/env bash' || fail "missing bash shebang"
grep -q 'INFRA-2255' "$TARGET" || fail "missing INFRA-2255 attribution"
pass "script exists, executable, shebang + INFRA-2255 attribution"

# ── 2. No-args usage error ───────────────────────────────────────────────────
if "$TARGET" 2>/dev/null; then
    fail "no-args invocation should exit non-zero"
else
    rc=$?
    [[ "$rc" -eq 1 ]] && pass "no-args exits 1" || fail "no-args exit code was $rc (want 1)"
fi

# ── 3. Refuse file outside allowlist (exit 2) ────────────────────────────────
OFF="$TMP/random.rs"
cat > "$OFF" <<'EOF'
fn x() {}
<<<<<<< HEAD
fn a() {}
=======
fn b() {}
>>>>>>> branch
EOF
if "$TARGET" "$OFF" 2>/dev/null; then
    fail "should refuse $OFF (.rs not in allowlist)"
else
    rc=$?
    [[ "$rc" -eq 2 ]] && pass "off-allowlist file refused with exit 2" || fail "off-allowlist exit code was $rc (want 2)"
fi
# And the file must be UNTOUCHED on refusal.
grep -q '<<<<<<<' "$OFF" || fail "refused file was mutated (must be untouched)"
pass "refused file left untouched"

# ── 4. Strip + preserve both sides — one fixture per allowlisted file type ──
run_strip_case() {
    local name="$1" path_in="$2" content="$3" must_a="$4" must_b="$5"
    mkdir -p "$(dirname "$path_in")"
    printf '%s' "$content" > "$path_in"
    if ! "$TARGET" "$path_in" >/dev/null 2>&1; then
        fail "$name: script returned non-zero"
        return
    fi
    if grep -qE '^(<<<<<<<|=======$|>>>>>>>)' "$path_in"; then
        fail "$name: markers still present after resolve"
        return
    fi
    grep -qF "$must_a" "$path_in" || { fail "$name: HEAD-side content missing"; return; }
    grep -qF "$must_b" "$path_in" || { fail "$name: incoming-side content missing"; return; }
    pass "$name: markers stripped, both sides preserved"
}

# (4a) event-registry-reserved.txt
ERR="$TMP/scripts/ci/event-registry-reserved.txt"
run_strip_case "event-registry-reserved.txt" "$ERR" \
"existing_kind  # already there
<<<<<<< HEAD
head_added_kind  # added on HEAD
=======
incoming_added_kind  # added on incoming
>>>>>>> branch
" "head_added_kind" "incoming_added_kind"

# (4b) Cargo.toml
CT="$TMP/Cargo.toml"
run_strip_case "Cargo.toml" "$CT" \
"[workspace]
members = [
<<<<<<< HEAD
    \"crates/chump-head\",
=======
    \"crates/chump-incoming\",
>>>>>>> branch
]
" "chump-head" "chump-incoming"

# (4c) EVENT_REGISTRY.yaml
EVT="$TMP/docs/observability/EVENT_REGISTRY.yaml"
run_strip_case "EVENT_REGISTRY.yaml" "$EVT" \
"existing_kind:
  trigger: foo
<<<<<<< HEAD
head_new_kind:
  trigger: head_path
=======
incoming_new_kind:
  trigger: incoming_path
>>>>>>> branch
" "head_new_kind" "incoming_new_kind"

# (4d) bootstrap-manifest.yaml
BM="$TMP/scripts/setup/bootstrap-manifest.yaml"
run_strip_case "bootstrap-manifest.yaml" "$BM" \
"items:
<<<<<<< HEAD
  - name: head_item
=======
  - name: incoming_item
>>>>>>> branch
" "head_item" "incoming_item"

# (4e) cascade-rebase-trigger-paths.txt
CRT="$TMP/scripts/coord/cascade-rebase-trigger-paths.txt"
run_strip_case "cascade-rebase-trigger-paths.txt" "$CRT" \
"src/lib.rs
<<<<<<< HEAD
src/head_added.rs
=======
src/incoming_added.rs
>>>>>>> branch
" "head_added.rs" "incoming_added.rs"

# ── 5. Idempotency — running on the now-clean file is a no-op + exit 0 ──────
if ! "$TARGET" "$ERR" >/dev/null 2>&1; then
    fail "idempotent re-run returned non-zero"
else
    pass "idempotent re-run exits 0"
fi
grep -qE '^(<<<<<<<|=======$|>>>>>>>)' "$ERR" && fail "idempotent run introduced markers" || \
    pass "idempotent re-run leaves file clean"

# ── 6. queue-driver wires through to script + emits new event kinds ─────────
grep -q 'auto-resolve-add-both' "$DRIVER" \
    && pass "queue-driver references auto-resolve-add-both" \
    || fail "queue-driver missing reference to auto-resolve-add-both"

grep -q 'cascade_auto_resolved' "$DRIVER" \
    && pass "queue-driver emits cascade_auto_resolved" \
    || fail "queue-driver missing cascade_auto_resolved emit"

grep -q 'cascade_resolve_skipped_semantic' "$DRIVER" \
    && pass "queue-driver emits cascade_resolve_skipped_semantic" \
    || fail "queue-driver missing cascade_resolve_skipped_semantic emit"

# ── Result summary ──────────────────────────────────────────────────────────
echo
echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]
