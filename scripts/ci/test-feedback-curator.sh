#!/usr/bin/env bash
# scripts/ci/test-feedback-curator.sh — INFRA-1272

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/coord/feedback-curator.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
[ -x "$SCRIPT" ] || fail "missing"

# Sandbox: fake repo + fake chump CLI.
mkdir -p "$TMP/repo/scripts/coord" "$TMP/repo/.chump-locks" "$TMP/bin"
cp "$SCRIPT" "$TMP/repo/scripts/coord/"

# Fake chump CLI: gap list returns canned JSON, reserve+set just log
cat > "$TMP/bin/chump" <<'EOF'
#!/usr/bin/env bash
# Args: gap list --json | gap reserve --domain X --title Y ... | gap set ID --add-note ...
case "$1 $2" in
    "gap list")
        cat "${FAKE_GAPS_FILE:-/dev/null}" 2>/dev/null || echo "[]"
        exit 0 ;;
    "gap reserve")
        echo "FAKE-1000" >> "$RESERVE_LOG"
        # The real `chump gap reserve` echoes the new gap-id on stdout.
        echo "FAKE-1000"
        exit 0 ;;
    "gap set")
        # gap set <ID> --add-note "..."
        echo "$*" >> "$ADDNOTE_LOG"
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/chump"
export PATH="$TMP/bin:$PATH"
export RESERVE_LOG="$TMP/reserve.log"
export ADDNOTE_LOG="$TMP/addnote.log"
: > "$RESERVE_LOG"; : > "$ADDNOTE_LOG"

FB="$TMP/repo/.chump-locks/feedback.jsonl"
AMB="$TMP/repo/.chump-locks/ambient.jsonl"
: > "$AMB"

# Helper: write a FEEDBACK entry
emit_fb() {
    local kind="$1" subject="$2" session="$3" rationale="$4"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 -c "
import json, sys
print(json.dumps({
    'event':'FEEDBACK','kind':sys.argv[1],'session':sys.argv[2],
    'ts':sys.argv[3],'subject':sys.argv[4],'rationale':sys.argv[5],
    'corr_id':sys.argv[4]
}))
" "$kind" "$session" "$ts" "$subject" "$rationale" >> "$FB"
}

# ── Test 1: below threshold → no action ───────────────────────────────────
emit_fb defect "POLICY-X" sess-1 "smells bad"
emit_fb defect "POLICY-X" sess-2 "broken"
out=$(cd "$TMP/repo" && bash scripts/coord/feedback-curator.sh 2>&1)
echo "$out" | grep -q "clusters_flagged\|flagged=0\|above threshold=3" \
    || echo "$out" | grep -q "0 above threshold=3" \
    || fail "below-threshold case: expected zero-flag output, got: $out"
ok "below threshold (n=2 < 3) → no cluster flagged"

# ── Test 2: at threshold → would file (dry-run) ────────────────────────────
emit_fb defect "POLICY-X" sess-3 "fix this please"
out=$(cd "$TMP/repo" && bash scripts/coord/feedback-curator.sh 2>&1)
echo "$out" | grep -q "WOULD reserve.*POLICY-X" \
    || fail "at-threshold case should propose reserve in dry-run, got: $out"
ok "at threshold (n=3) → dry-run proposes new gap"

# ── Test 3: --apply files the gap + adds note ──────────────────────────────
out=$(cd "$TMP/repo" && bash scripts/coord/feedback-curator.sh --apply 2>&1)
grep -q "FAKE-1000" "$RESERVE_LOG" \
    || fail "expected chump gap reserve call; reserve.log: $(cat "$RESERVE_LOG")"
grep -q "add-note" "$ADDNOTE_LOG" \
    || fail "expected chump gap set ... --add-note call; addnote.log: $(cat "$ADDNOTE_LOG")"
grep -q '"kind": "feedback_curated"' "$AMB" \
    || fail "audit event missing from ambient: $(cat "$AMB")"
ok "--apply: gap reserved + note added + audit emitted"

# ── Test 4: dedup — existing recent gap → add-note instead of new ─────────
# Reset and set FAKE_GAPS_FILE to include a recent gap citing the subject.
: > "$FB"; : > "$ADDNOTE_LOG"; : > "$RESERVE_LOG"; : > "$AMB"
today="$(date -u +%Y-%m-%d)"
cat > "$TMP/gaps.json" <<EOF
[
  {"id":"INFRA-2000","title":"existing for POLICY-X","notes":"covers POLICY-X","opened_date":"$today","status":"open"}
]
EOF
export FAKE_GAPS_FILE="$TMP/gaps.json"
emit_fb proposal "POLICY-X" sess-1 "alt"
emit_fb proposal "POLICY-X" sess-2 "alt"
emit_fb proposal "POLICY-X" sess-3 "alt"
out=$(cd "$TMP/repo" && bash scripts/coord/feedback-curator.sh --apply 2>&1)
grep -q "add-note" "$ADDNOTE_LOG" \
    || fail "dedup case: expected add-note to INFRA-2000, got addnote.log: $(cat "$ADDNOTE_LOG")"
if grep -q "FAKE-1000" "$RESERVE_LOG"; then
    fail "dedup case: should NOT reserve a new gap when an existing one is found"
fi
grep -qF "INFRA-2000" "$ADDNOTE_LOG" \
    || fail "add-note must target INFRA-2000 (the existing dedup hit)"
ok "dedup: existing recent gap → add-note instead of new reserve"

echo
echo "All INFRA-1272 feedback-curator tests passed."
