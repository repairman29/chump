#!/usr/bin/env bash
# Smoke test for mission-doc-keeper.sh (EFFECTIVE-514).
# Asserts:
#   (a) script is executable
#   (b) it fails loudly against an HTML file missing the markers
#   (c) it regenerates the dynamic block in a fixture HTML with live numbers
#       (open-gap count + live_pct + debt), replacing prior placeholder content
#   (d) content outside the markers is left untouched
#   (e) re-running is idempotent in shape (markers still present, exactly once)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/dev/mission-doc-keeper.sh"

[[ -x "$SCRIPT" ]] || { echo "[test] FAIL: mission-doc-keeper.sh not found/executable"; exit 1; }
echo "[test] (a) executable: OK"

TMP_HTML="$(mktemp /tmp/mission-tote-board.XXXXXX.html)"
trap 'rm -f "$TMP_HTML"' EXIT

# --- (b) missing markers is a hard failure ---------------------------------
cat > "$TMP_HTML" <<'EOF'
<html><body><p>no markers here</p></body></html>
EOF
if "$SCRIPT" --html "$TMP_HTML" >/dev/null 2>&1; then
  echo "[test] FAIL: expected non-zero exit for HTML missing markers"
  exit 1
fi
echo "[test] (b) missing markers -> non-zero exit: OK"

# --- (c)/(d) regenerates dynamic block, preserves surrounding content ------
cat > "$TMP_HTML" <<'EOF'
<html><body>
<p id="keep-me">untouched header content</p>
<!-- MISSION-DOC-KEEPER:BEGIN dynamic -->
<p>(placeholder — never generated)</p>
<!-- MISSION-DOC-KEEPER:END dynamic -->
<p id="keep-me-too">untouched footer content</p>
</body></html>
EOF

out="$("$SCRIPT" --html "$TMP_HTML" 2>&1)" || { echo "[test] FAIL: script exited non-zero on valid fixture: $out"; exit 1; }

grep -q 'untouched header content' "$TMP_HTML" || { echo "[test] FAIL: content before markers was clobbered"; exit 1; }
grep -q 'untouched footer content' "$TMP_HTML" || { echo "[test] FAIL: content after markers was clobbered"; exit 1; }
echo "[test] (d) content outside markers preserved: OK"

grep -q 'placeholder — never generated' "$TMP_HTML" && { echo "[test] FAIL: placeholder text was not replaced"; exit 1; }
grep -qE 'stat-open-gaps.*Open gaps: <strong>[0-9]+</strong>' "$TMP_HTML" || { echo "[test] FAIL: open-gap count not rendered"; exit 1; }
grep -qE 'stat-live-pct.*live_pct: <strong>[0-9]+\.[0-9]%</strong>' "$TMP_HTML" || { echo "[test] FAIL: live_pct not rendered"; exit 1; }
grep -qE 'stat-debt.*debt: <strong>-?[0-9]+\.[0-9]{2}</strong>' "$TMP_HTML" || { echo "[test] FAIL: debt not rendered"; exit 1; }
echo "[test] (c) dynamic block regenerated with live numbers: OK"

# --- (e) idempotent shape across repeated runs -----------------------------
"$SCRIPT" --html "$TMP_HTML" >/dev/null 2>&1 || { echo "[test] FAIL: second run failed"; exit 1; }
begin_count=$(grep -c 'MISSION-DOC-KEEPER:BEGIN dynamic' "$TMP_HTML")
end_count=$(grep -c 'MISSION-DOC-KEEPER:END dynamic' "$TMP_HTML")
[[ "$begin_count" -eq 1 && "$end_count" -eq 1 ]] || { echo "[test] FAIL: markers duplicated across runs (begin=$begin_count end=$end_count)"; exit 1; }
echo "[test] (e) idempotent across repeated runs: OK"

# --- canonical in-repo asset also has the markers (regression guard) -------
CANON="$REPO_ROOT/docs/mission-tote-board.html"
[[ -f "$CANON" ]] || { echo "[test] FAIL: canonical docs/mission-tote-board.html missing"; exit 1; }
grep -q 'MISSION-DOC-KEEPER:BEGIN dynamic' "$CANON" || { echo "[test] FAIL: canonical HTML missing BEGIN marker"; exit 1; }
grep -q 'MISSION-DOC-KEEPER:END dynamic' "$CANON" || { echo "[test] FAIL: canonical HTML missing END marker"; exit 1; }
echo "[test] canonical docs/mission-tote-board.html has markers: OK"

echo "[test-mission-doc-keeper] PASS"
