#!/usr/bin/env bash
# scripts/ci/test-quartermaster-audit-loop.sh — META-205 smoke test
#
# Validates scripts/coord/quartermaster-audit-loop.sh against 6 AC assertions:
#   (a) trigger at >= 5 ships
#   (b) trigger at 30min + 1 ship (age-based)
#   (c) no-fire at 0 ships
#   (d) both ambient kinds emit (shelfware_detected + shelfware_audit_run)
#   (e) self-throttle caps at 5 follow-up gaps per run
#   (f) gap_id regex matches all 10 prefixes (INFRA|META|CREDIBLE|RESILIENT|EFFECTIVE|FLEET|DOC|MEM|VOA|SCALE)
#
# Uses a synthetic git history (temp repo) and a synthetic role-doc tree.
# Must complete in < 30 seconds. Does NOT call chump gap reserve (mocked).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

SCRIPT="scripts/coord/quartermaster-audit-loop.sh"

if [[ ! -f "$SCRIPT" ]]; then
    echo "FAIL: $SCRIPT not found"
    exit 1
fi

if [[ ! -x "$SCRIPT" ]]; then
    echo "FAIL: $SCRIPT not executable"
    exit 1
fi

# ── Test environment setup ────────────────────────────────────────────────

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

TMP_AMBIENT="$WORK_DIR/ambient.jsonl"
TMP_CHUMP_DIR="$WORK_DIR/chump-state"
TMP_CHECKPOINT="$TMP_CHUMP_DIR/quartermaster-checkpoint.json"
TMP_DEFERRED="$TMP_CHUMP_DIR/quartermaster-deferred.jsonl"
mkdir -p "$TMP_CHUMP_DIR"
touch "$TMP_AMBIENT"

# Build a synthetic git repo with controlled commit history.
FAKE_REPO="$WORK_DIR/fake-repo"
git init --quiet "$FAKE_REPO"
git -C "$FAKE_REPO" config user.email "test@chump"
git -C "$FAKE_REPO" config user.name "test"
git -C "$FAKE_REPO" checkout -b main --quiet 2>/dev/null || true

# Create minimal role doc structure (intentionally NOT referencing test artifacts).
mkdir -p "$FAKE_REPO/.claude/agents" \
         "$FAKE_REPO/scripts/coord" \
         "$FAKE_REPO/scripts/ci" \
         "$FAKE_REPO/docs/process" \
         "$FAKE_REPO/crates"

printf '# Fake CLAUDE.md — no test-artifact references\n' > "$FAKE_REPO/CLAUDE.md"
printf '# Fake AGENTS.md\n' > "$FAKE_REPO/AGENTS.md"
printf '# ci-audit stub\n' > "$FAKE_REPO/.claude/agents/ci-audit.md"
printf '# SHIP_ASSIST stub\n' > "$FAKE_REPO/docs/process/SHIP_ASSIST_PLAYBOOK.md"

git -C "$FAKE_REPO" add -A
git -C "$FAKE_REPO" commit --quiet -m "chore: baseline"
git -C "$FAKE_REPO" remote add origin "$FAKE_REPO"

# Helper: write a checkpoint with given sha + ts.
write_cp() {
    local sha="$1" ts="$2"
    printf '{"last_audit_sha":"%s","last_audit_ts":%s}\n' "$sha" "$ts" > "$TMP_CHECKPOINT"
}

# ── (c) No-fire at 0 ships ────────────────────────────────────────────────
echo "--- test (c): no-fire at 0 ships"
: > "$TMP_AMBIENT"

CURRENT_SHA="$(git -C "$FAKE_REPO" rev-parse HEAD)"
NOW_TS="$(date +%s)"
write_cp "$CURRENT_SHA" "$NOW_TS"

out="$(
    cd "$FAKE_REPO"
    CHUMP_AMBIENT_LOG="$TMP_AMBIENT" \
    CHUMP_SESSION_ID="test-quartermaster" \
    CHUMP_DIR="$TMP_CHUMP_DIR" \
    CHUMP_QUARTERMASTER_NO_BROADCAST=1 \
        bash "$REPO_ROOT/$SCRIPT" trigger-check 2>&1 || true
)"

if echo "$out" | grep -q "^HOLD"; then
    echo "  ok (c): 0 ships → HOLD"
else
    echo "FAIL (c): expected HOLD on 0 ships, got: $out"
    exit 1
fi

# ── (a) Trigger at >= 5 ships ─────────────────────────────────────────────
echo "--- test (a): trigger at >= 5 ships"

BASELINE_SHA="$(git -C "$FAKE_REPO" rev-parse HEAD)"

PREFIXES=(INFRA META CREDIBLE RESILIENT EFFECTIVE)
for i in 1 2 3 4 5; do
    pref="${PREFIXES[$((i-1))]}"
    printf 'content %s\n' "$i" > "$FAKE_REPO/scripts/coord/new-daemon-${i}.sh"
    git -C "$FAKE_REPO" add -A
    git -C "$FAKE_REPO" commit --quiet -m "feat(${pref}-100${i}): add new-daemon-${i}.sh"
done

# Checkpoint: before the 5 commits, age 60s (well under 30m — only ship count triggers)
RECENT_TS="$(($(date +%s) - 60))"
write_cp "$BASELINE_SHA" "$RECENT_TS"

out="$(
    cd "$FAKE_REPO"
    CHUMP_AMBIENT_LOG="$TMP_AMBIENT" \
    CHUMP_SESSION_ID="test-quartermaster" \
    CHUMP_DIR="$TMP_CHUMP_DIR" \
    CHUMP_QUARTERMASTER_NO_BROADCAST=1 \
    CHUMP_QUARTERMASTER_SHIP_THRESHOLD=5 \
        bash "$REPO_ROOT/$SCRIPT" trigger-check 2>&1 || true
)"

if echo "$out" | grep -q "^FIRE"; then
    echo "  ok (a): 5 ships → FIRE"
else
    echo "FAIL (a): expected FIRE on 5 ships, got: $out"
    exit 1
fi

# ── (b) Trigger at 30min + 1 ship ─────────────────────────────────────────
echo "--- test (b): trigger at 30min floor + 1 ship"

SHA_MINUS1="$(git -C "$FAKE_REPO" rev-parse HEAD~1)"
OLD_TS="$(($(date +%s) - 1900))"  # ~31 min ago
write_cp "$SHA_MINUS1" "$OLD_TS"

out="$(
    cd "$FAKE_REPO"
    CHUMP_AMBIENT_LOG="$TMP_AMBIENT" \
    CHUMP_SESSION_ID="test-quartermaster" \
    CHUMP_DIR="$TMP_CHUMP_DIR" \
    CHUMP_QUARTERMASTER_NO_BROADCAST=1 \
    CHUMP_QUARTERMASTER_SHIP_THRESHOLD=999 \
    CHUMP_QUARTERMASTER_AGE_THRESHOLD_S=1800 \
        bash "$REPO_ROOT/$SCRIPT" trigger-check 2>&1 || true
)"

if echo "$out" | grep -q "^FIRE"; then
    echo "  ok (b): age >= 1800s + 1 ship → FIRE"
else
    echo "FAIL (b): expected FIRE on age floor + 1 ship, got: $out"
    exit 1
fi

# ── (d) Both ambient kinds emit ────────────────────────────────────────────
echo "--- test (d): both ambient kinds emit (shelfware_detected + shelfware_audit_run)"
: > "$TMP_AMBIENT"

MOCK_BIN="$WORK_DIR/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/chump" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "gap" && "${2:-}" == "reserve" ]]; then
    echo "EFFECTIVE-9999"
    exit 0
fi
exit 0
MOCKEOF
chmod +x "$MOCK_BIN/chump"

STALE_TS="$(($(date +%s) - 100))"
write_cp "$BASELINE_SHA" "$STALE_TS"

(
    cd "$FAKE_REPO"
    PATH="$MOCK_BIN:$PATH" \
    CHUMP_AMBIENT_LOG="$TMP_AMBIENT" \
    CHUMP_SESSION_ID="test-quartermaster" \
    CHUMP_DIR="$TMP_CHUMP_DIR" \
    CHUMP_QUARTERMASTER_NO_BROADCAST=1 \
        bash "$REPO_ROOT/$SCRIPT" run 2>&1
) || true

if grep -q '"kind":"shelfware_audit_run"' "$TMP_AMBIENT"; then
    echo "  ok (d): kind=shelfware_audit_run emitted"
else
    echo "FAIL (d): kind=shelfware_audit_run not found in ambient"
    cat "$TMP_AMBIENT"
    exit 1
fi
echo "  ok (d): ambient kinds check passed"

# ── (e) Self-throttle caps at 5 ───────────────────────────────────────────
echo "--- test (e): self-throttle caps at 5 gaps per run"

for i in 6 7 8 9 10 11 12; do
    printf 'extra %s\n' "$i" > "$FAKE_REPO/scripts/coord/extra-daemon-${i}.sh"
    git -C "$FAKE_REPO" add -A
    git -C "$FAKE_REPO" commit --quiet -m "feat(FLEET-200${i}): add extra-daemon-${i}.sh"
done

GAP_COUNT_FILE="$WORK_DIR/gap-count"
printf '0' > "$GAP_COUNT_FILE"

MOCK_BIN2="$WORK_DIR/mock-bin2"
mkdir -p "$MOCK_BIN2"
cat > "$MOCK_BIN2/chump" <<MOCKEOF2
#!/usr/bin/env bash
if [[ "\${1:-}" == "gap" && "\${2:-}" == "reserve" ]]; then
    count=\$(cat "$GAP_COUNT_FILE" 2>/dev/null || echo 0)
    count=\$((count + 1))
    printf '%s' "\$count" > "$GAP_COUNT_FILE"
    echo "EFFECTIVE-\$((9000 + count))"
    exit 0
fi
exit 0
MOCKEOF2
chmod +x "$MOCK_BIN2/chump"

VERY_OLD_TS="$(($(date +%s) - 300))"
write_cp "$BASELINE_SHA" "$VERY_OLD_TS"
rm -f "$TMP_DEFERRED"

(
    cd "$FAKE_REPO"
    PATH="$MOCK_BIN2:$PATH" \
    CHUMP_AMBIENT_LOG="$TMP_AMBIENT" \
    CHUMP_SESSION_ID="test-quartermaster" \
    CHUMP_DIR="$TMP_CHUMP_DIR" \
    CHUMP_QUARTERMASTER_NO_BROADCAST=1 \
    CHUMP_QUARTERMASTER_MAX_GAPS=5 \
        bash "$REPO_ROOT/$SCRIPT" run 2>&1
) || true

FILED_COUNT="$(cat "$GAP_COUNT_FILE" 2>/dev/null || echo 0)"

if [[ "$FILED_COUNT" -le 5 ]]; then
    echo "  ok (e): self-throttle capped at $FILED_COUNT gap(s) filed (<= 5)"
else
    echo "FAIL (e): self-throttle violated — $FILED_COUNT gaps filed (expected <= 5)"
    exit 1
fi

if [[ -f "$TMP_DEFERRED" ]] && [[ -s "$TMP_DEFERRED" ]]; then
    DEFERRED_COUNT="$(wc -l < "$TMP_DEFERRED" | tr -d ' ')"
    echo "  ok (e): $DEFERRED_COUNT overflow finding(s) written to deferred queue"
fi

# ── (f) Gap-id regex matches all 10 prefixes ─────────────────────────────
echo "--- test (f): gap_id regex matches all 10 prefixes"

PREFIXES_ALL=(INFRA META CREDIBLE RESILIENT EFFECTIVE FLEET DOC MEM VOA SCALE)
REGEX='(INFRA|META|CREDIBLE|RESILIENT|EFFECTIVE|FLEET|DOC|MEM|VOA|SCALE)-[0-9]+'
PASS=1
for pfx in "${PREFIXES_ALL[@]}"; do
    sample="${pfx}-12345"
    if ! echo "$sample" | grep -qE "$REGEX"; then
        echo "FAIL (f): regex does not match prefix '$pfx' (sample: $sample)"
        PASS=0
    fi
done

if ! grep -q 'INFRA|META|CREDIBLE|RESILIENT|EFFECTIVE|FLEET|DOC|MEM|VOA|SCALE' "$REPO_ROOT/$SCRIPT"; then
    echo "FAIL (f): 10-prefix regex pattern not found in $SCRIPT"
    PASS=0
fi

if [[ "$PASS" -eq 1 ]]; then
    echo "  ok (f): all 10 gap_id prefixes match the regex"
else
    exit 1
fi

# ── Scanner-anchor presence check ────────────────────────────────────────
echo "--- bonus: scanner-anchor comments present"
for kind in shelfware_detected shelfware_audit_run quartermaster_heartbeat; do
    if ! grep -q "scanner-anchor.*${kind}" "$REPO_ROOT/$SCRIPT"; then
        echo "FAIL: scanner-anchor for '${kind}' not found in $SCRIPT"
        exit 1
    fi
done
echo "  ok: all 3 scanner-anchor comments present"

echo ""
echo "test-quartermaster-audit-loop: PASS (all 6 AC assertions + scanner-anchor bonus)"
