#!/usr/bin/env bash
# test-rot-reaper.sh — RESILIENT-324
#
# Proves the rot-reaper's SELECTION logic: it reaps genuinely-CONFLICTING PRs
# that are past the age gate, and NEVER touches fresh conflicts, BLOCKED-but-
# mergeable PRs, clean PRs, or gap-filing PRs.
#
# Runs scripts/ops/rot-reaper.sh in --dry-run against a synthetic PR fixture
# (CHUMP_ROT_REAPER_PR_JSON) with gh/chump stubbed on PATH — no live GitHub,
# no state mutation.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/rot-reaper.sh"
[[ -f "$REAPER" ]] || { echo "FAIL: $REAPER not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# stub gh (only `gh api user` is reached; PR list comes from the fixture) + chump
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "api" ]] && { echo "repairman29"; exit 0; }
exit 0
EOF
cat > "$STUB/chump" <<'EOF'
#!/usr/bin/env bash
# no gaps known in the test → `gap show` prints nothing
exit 0
EOF
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"

iso() { python3 -c "from datetime import datetime,timezone,timedelta;print((datetime.now(timezone.utc)-timedelta(hours=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }
OLD="$(iso 9)"      # past the 4h age gate
FRESH="$(iso 1)"    # inside the age gate

FIX="$TMP/prs.json"
cat > "$FIX" <<EOF
[
  {"number":201,"title":"RESILIENT-900: real conflicting work","mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","createdAt":"$OLD","headRefName":"rs-900"},
  {"number":202,"title":"RESILIENT-901: fresh conflict, owner may be rebasing","mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","createdAt":"$FRESH","headRefName":"rs-901"},
  {"number":203,"title":"RESILIENT-902: blocked but mergeable (needs CI/approval)","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","createdAt":"$OLD","headRefName":"rs-902"},
  {"number":204,"title":"RESILIENT-903: clean and ready","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","createdAt":"$OLD","headRefName":"rs-903"},
  {"number":205,"title":"chore(gaps): file RESILIENT-904","mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","createdAt":"$OLD","headRefName":"file-rs904"}
]
EOF

out="$(CHUMP_ROT_REAPER_PR_JSON="$FIX" bash "$REAPER" --dry-run 2>&1)"
echo "$out"
echo "---"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# #201: old CONFLICTING non-filing → REAPED
echo "$out" | grep -qE 'PR #201 — CONFLICTING, [0-9]+h old → REAP' && ok "#201 old-conflicting reaped" || bad "#201 not reaped"
# #202: fresh CONFLICTING → skipped by age gate, NOT reaped
echo "$out" | grep -q 'PR #202 — CONFLICTING but only' && ok "#202 fresh-conflict skipped" || bad "#202 not skipped by age"
echo "$out" | grep -qE 'PR #202 .*→ REAP' && bad "#202 wrongly reaped" || ok "#202 not reaped"
# #203: BLOCKED-but-MERGEABLE → never considered
echo "$out" | grep -q 'PR #203' && bad "#203 (blocked-mergeable) wrongly touched" || ok "#203 left alone"
# #204: clean/mergeable → never considered
echo "$out" | grep -q 'PR #204' && bad "#204 (clean) wrongly touched" || ok "#204 left alone"
# #205: filing PR (even though CONFLICTING+old) → skipped
echo "$out" | grep -q 'PR #205 — filing PR, skipping' && ok "#205 filing PR skipped" || bad "#205 filing PR not skipped"
# exactly one close
echo "$out" | grep -q 'closed=1' && ok "exactly one PR reaped (closed=1)" || bad "close count wrong"

echo ""
echo "=== rot-reaper selection: $pass passed, $fail failed ==="
[[ "$fail" -eq 0 ]]
