#!/usr/bin/env bash
# test-ci-fleet-health-sweep.sh — CREDIBLE-220 smoke test.
#
# Exercises ci-fleet-health-sweep.sh against a fake `gh` on PATH (no live
# network calls) plus a synthetic GLOBAL_ARSENAL.json fixture. Verifies:
#   1. script exists and is executable
#   2. archived/fork/other-owner repos are excluded from the scan
#   3. a repo first seen red is tracked (first_red_at) but NOT filed yet
#   4. a repo red >= threshold days gets filed exactly once (dedupe via
#      state "filed" flag — a second run does not refile)
#   5. a repo that recovers (conclusion=success) has its state cleared
#   6. launchd plist exists

set -euo pipefail

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/coord/ci-fleet-health-sweep.sh"
TMPDIR_LOCAL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

echo "=== CREDIBLE-220 ci-fleet-health-sweep smoke test ==="
echo

# ── 1. Script exists and is executable ───────────────────────────────────────
if [[ -x "$SCRIPT" ]]; then
    ok "ci-fleet-health-sweep.sh exists and is executable"
else
    fail "ci-fleet-health-sweep.sh missing or not executable at $SCRIPT"
fi

# ── Fixtures: fake gh + arsenal ──────────────────────────────────────────────
mkdir -p "$TMPDIR_LOCAL/bin"
FAKE_GH="$TMPDIR_LOCAL/bin/gh"
GH_CONCLUSION_FILE="$TMPDIR_LOCAL/gh-conclusion"
echo "failure" > "$GH_CONCLUSION_FILE"
cat > "$FAKE_GH" <<WRAP
#!/usr/bin/env bash
if [[ "\$1" == "api" ]]; then
  echo "main"
  exit 0
fi
if [[ "\$1" == "run" && "\$2" == "list" ]]; then
  concl="\$(cat "$GH_CONCLUSION_FILE")"
  echo "[{\"conclusion\":\"\$concl\",\"createdAt\":\"2026-08-25T00:00:00Z\",\"databaseId\":1}]"
  exit 0
fi
if [[ "\$1" == "run" && "\$2" == "view" ]]; then
  echo "npm ERR! missing script: lint"
  exit 0
fi
exit 1
WRAP
chmod +x "$FAKE_GH"

cat > "$TMPDIR_LOCAL/arsenal.json" <<'EOF'
{
  "repos_by_name": {
    "watched-repo": {"name":"watched-repo","archived":false,"fork":false,"url":"https://github.com/repairman29/watched-repo"},
    "archived-repo": {"name":"archived-repo","archived":true,"fork":false,"url":"https://github.com/repairman29/archived-repo"},
    "forked-repo": {"name":"forked-repo","archived":false,"fork":true,"url":"https://github.com/repairman29/forked-repo"},
    "other-owner-repo": {"name":"other-owner-repo","archived":false,"fork":false,"url":"https://github.com/someoneelse/other-owner-repo"}
  }
}
EOF

STATE="$TMPDIR_LOCAL/state.json"
AMBIENT="$TMPDIR_LOCAL/ambient.jsonl"

run_sweep() {
    PATH="$TMPDIR_LOCAL/bin:$PATH" \
    CHUMP_CI_FLEET_SWEEP_ARSENAL="$TMPDIR_LOCAL/arsenal.json" \
    CHUMP_CI_FLEET_SWEEP_STATE="$STATE" \
    CHUMP_AMBIENT_LOG="$AMBIENT" \
    bash "$SCRIPT" --dry-run --json --days 3 "$@"
}

# ── 2. Filtering: only watched-repo should be scanned ────────────────────────
out2="$(run_sweep 2>&1)"
if grep -q "scanning 1 non-archived" <<<"$out2"; then
    ok "archived/fork/other-owner repos excluded (scanned=1)"
else
    fail "expected exactly 1 repo scanned, got: $out2"
fi

# ── 3. First-seen red repo is tracked but not filed ──────────────────────────
if [[ -f "$STATE" ]] && grep -q '"filed": false' "$STATE" && grep -q "watched-repo" "$STATE"; then
    ok "first-seen red repo tracked with filed=false"
else
    fail "state file did not track first-seen red repo as unfiled: $(cat "$STATE" 2>/dev/null)"
fi

# ── 4. Backdate first_red_at past threshold, rerun -> files exactly once ────
python3 -c "
import json
d = json.load(open('$STATE'))
d['watched-repo']['first_red_at'] = '2026-08-20T00:00:00Z'
d['watched-repo']['filed'] = False
json.dump(d, open('$STATE', 'w'))
"
out4a="$(run_sweep 2>&1)"
if grep -q "FILING: CI red" <<<"$out4a" && grep -q "missing_script" <<<"$out4a"; then
    ok "red-past-threshold repo files with missing_script classification"
else
    fail "expected a FILING line with missing_script, got: $out4a"
fi
out4b="$(run_sweep 2>&1)"
if ! grep -q "FILING:" <<<"$out4b"; then
    ok "second run does not refile (dedupe via state 'filed' flag)"
else
    fail "second run refiled a repo already marked filed: $out4b"
fi

# ── 5. Recovery clears state ─────────────────────────────────────────────────
echo "success" > "$GH_CONCLUSION_FILE"
run_sweep >/dev/null 2>&1
if ! grep -q "watched-repo" "$STATE" 2>/dev/null; then
    ok "recovered repo (conclusion=success) has its state entry cleared"
else
    fail "recovered repo state was not cleared: $(cat "$STATE" 2>/dev/null)"
fi

# ── 6. launchd plist exists ──────────────────────────────────────────────────
PLIST="$REPO_ROOT/launchd/com.chump.ci-fleet-health-sweep.plist"
if [[ -f "$PLIST" ]]; then
    ok "launchd plist exists at $PLIST"
else
    fail "launchd plist missing at $PLIST"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
