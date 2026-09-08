#!/usr/bin/env bash
# EFFECTIVE-1543 — gap-doctor-reconcile.py --check-merged-pr-titles must close
# open gaps whose gap-ID leads a MERGED PR title (the async-merge ghost class:
# real work shipped, PR merged after the worker cycle ended, canonical state.db
# gap left open with closed_pr NULL → re-picked forever). Neither
# --check-closure-drift (needs closed_pr) nor --check-already-satisfied (no-op
# cycle-log signal only) catches this class.
#
# Uses a fake `gh` on PATH so the test needs no network/auth.

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/gap-doctor-reconcile.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fake gh: `gh repo view` → test/repo; `gh pr list --state merged` → fixture PRs.
mkdir -p "$TMP/fakebin"
cat >"$TMP/fakebin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "repo" && "$2" == "view" ]]; then echo "test/repo"; exit 0; fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
cat <<'JSON'
[
  {"number":4525,"title":"INFRA-100: implement the thing","mergedAt":"2026-09-08T04:49:24Z"},
  {"number":4600,"title":"INFRA-400: partial progress [no-close]","mergedAt":"2026-09-08T05:00:00Z"},
  {"number":4601,"title":"chore(gaps): file INFRA-500 and friends","mergedAt":"2026-09-08T05:10:00Z"},
  {"number":4602,"title":"INFRA-300: already done sibling","mergedAt":"2026-09-08T05:20:00Z"}
]
JSON
exit 0
fi
exit 0
EOF
chmod +x "$TMP/fakebin/gh"

# Build a state.db with the columns the pass reads/writes.
DB="$TMP/state.db"
sqlite3 "$DB" <<'SQL'
CREATE TABLE gaps (
  id TEXT PRIMARY KEY, status TEXT NOT NULL DEFAULT 'open',
  closed_pr INTEGER, closed_date TEXT NOT NULL DEFAULT '',
  evidence TEXT, title TEXT NOT NULL DEFAULT ''
);
INSERT INTO gaps(id,status,title) VALUES ('INFRA-100','open','implement the thing');
INSERT INTO gaps(id,status,title) VALUES ('INFRA-400','open','partial');   -- [no-close] → keep open
INSERT INTO gaps(id,status,title) VALUES ('INFRA-500','open','a filed gap'); -- filing PR → keep open
INSERT INTO gaps(id,status,closed_pr,closed_date,title) VALUES ('INFRA-300','done',4602,'2026-09-08','already done'); -- already done → untouched
INSERT INTO gaps(id,status,title) VALUES ('INFRA-900','open','no merged pr'); -- no PR → keep open
SQL

run() {
  PATH="$TMP/fakebin:$PATH" CHUMP_STATE_DB="$DB" \
    python3 "$SCRIPT" --check-merged-pr-titles "$@" 2>&1
}

# Dry-run: reports the ghost, writes nothing.
out="$(run --dry-run)"
echo "$out" | grep -q "GHOST INFRA-100" \
  && pass "dry-run identifies INFRA-100 as a merged-but-open ghost" \
  || fail "dry-run did not identify INFRA-100 ghost"
st="$(sqlite3 "$DB" "SELECT status FROM gaps WHERE id='INFRA-100'")"
[ "$st" = "open" ] && pass "dry-run made no writes (INFRA-100 still open)" \
  || fail "dry-run wrote to DB (INFRA-100 now $st)"

# Apply: closes only INFRA-100.
run >/dev/null
read -r st cp cd <<<"$(sqlite3 -separator ' ' "$DB" "SELECT status,closed_pr,closed_date FROM gaps WHERE id='INFRA-100'")"
[ "$st" = "done" ] && pass "INFRA-100 flipped to done" || fail "INFRA-100 status=$st (want done)"
[ "$cp" = "4525" ] && pass "INFRA-100 closed_pr=4525" || fail "INFRA-100 closed_pr=$cp (want 4525)"
[ "$cd" = "2026-09-08" ] && pass "INFRA-100 closed_date set" || fail "INFRA-100 closed_date=$cd"

# [no-close] PR must NOT close its gap.
st="$(sqlite3 "$DB" "SELECT status FROM gaps WHERE id='INFRA-400'")"
[ "$st" = "open" ] && pass "[no-close] PR left INFRA-400 open" || fail "INFRA-400 wrongly closed ($st)"

# Filing PR must NOT close its gap.
st="$(sqlite3 "$DB" "SELECT status FROM gaps WHERE id='INFRA-500'")"
[ "$st" = "open" ] && pass "filing PR left INFRA-500 open" || fail "INFRA-500 wrongly closed ($st)"

# Gap with no merged PR untouched.
st="$(sqlite3 "$DB" "SELECT status FROM gaps WHERE id='INFRA-900'")"
[ "$st" = "open" ] && pass "gap with no merged PR left open" || fail "INFRA-900 wrongly closed ($st)"

# Already-done gap untouched (idempotent).
cp="$(sqlite3 "$DB" "SELECT closed_pr FROM gaps WHERE id='INFRA-300'")"
[ "$cp" = "4602" ] && pass "already-done INFRA-300 untouched" || fail "INFRA-300 mutated (closed_pr=$cp)"

# Second apply is a no-op (queue already drained).
out="$(run)"
echo "$out" | grep -q "no merged-but-open ghosts" \
  && pass "idempotent: second run finds nothing to drain" \
  || fail "second run still reports ghosts"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
