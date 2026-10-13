#!/usr/bin/env bash
# RESILIENT-1585: title fallback in _detect_ship_evidence must ignore PRs at/below
# the claim-time PR-number high-water mark (pr_state has no created_at column).
set -uo pipefail
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_ROOT/scripts/dispatch/worker.sh"
command -v sqlite3 >/dev/null || { echo "SKIP: no sqlite3"; exit 0; }
eval "$(sed -n '/^_pr_number_hwm() {/,/^}/p' "$WORKER")"
eval "$(sed -n '/^_detect_ship_evidence() {/,/^}/p' "$WORKER")"
shim="$(mktemp -d)"; repo="$(mktemp -d)"; export PATH="$shim:$PATH"
printf '#!/usr/bin/env bash\necho "  status: open"\n' > "$shim/chump"
printf '#!/usr/bin/env bash\necho ""\n' > "$shim/gh"
chmod +x "$shim/chump" "$shim/gh"
mkdir -p "$repo/.chump"
db="$repo/.chump/github_cache.db"
sqlite3 "$db" "CREATE TABLE pr_state (number INTEGER PRIMARY KEY, head_ref TEXT, title TEXT);
INSERT INTO pr_state VALUES (100,'old','GAP-1: old merged slice');"
export REPO_ROOT="$repo"

hwm="$(_pr_number_hwm)"
[[ "$hwm" == "100" ]] && ok "hwm taken from cache = 100" || fail "hwm=$hwm"

# no new PR this cycle -> no evidence
_cycle_pr_hwm=$hwm
out="$(_detect_ship_evidence GAP-1 chump/gap-1-x)"; rc=$?
[[ $rc -ne 0 && -z "$out" ]] && ok "old PR ignored -> unverified (no evidence)" || fail "old PR counted: rc=$rc out=$out"

# PR opened this cycle, branch deleted after merge (RESILIENT-1451) -> detected
sqlite3 "$db" "INSERT INTO pr_state VALUES (101,'deleted-branch','GAP-1: new slice');"
out="$(_detect_ship_evidence GAP-1 chump/gap-1-x)"; rc=$?
[[ $rc -eq 0 && "$out" == "101" ]] && ok "new PR (branch deleted) still detected" || fail "new PR missed: rc=$rc out=$out"

# gh search path respects hwm
rm -f "$db"
cat > "$shim/gh" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == "--search" ]] && echo '[{"number":90},{"number":120}]' && exit 0; done
echo ""
SH
cat > "$shim/gh" <<'SH'
#!/usr/bin/env bash
s=0; for a in "$@"; do [[ "$a" == "--search" ]] && s=1; done
if [[ $s -eq 1 ]]; then
  # emulate --jq filter by honouring only the final filter via jq
  jqf=""; prev=""; for a in "$@"; do [[ "$prev" == "--jq" ]] && jqf="$a"; prev="$a"; done
  echo "$GH_JSON" | jq -r "$jqf"
fi
SH
command -v jq >/dev/null && {
  export GH_JSON='[{"number":90}]'; _cycle_pr_hwm=100
  out="$(_detect_ship_evidence GAP-1 b)"; rc=$?
  [[ $rc -ne 0 ]] && ok "gh search: old PR ignored" || fail "gh old PR counted: $out"
  export GH_JSON='[{"number":90},{"number":120}]'
  out="$(_detect_ship_evidence GAP-1 b)"
  [[ "$out" == "120" ]] && ok "gh search: new PR detected" || fail "gh new PR: '$out'"
}
rm -rf "$shim" "$repo"
echo "=== $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
