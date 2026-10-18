#!/usr/bin/env bash
# CREDIBLE-1550 (Phase R R2) — gap-doctor-reconcile.py --check-merged-pr-links
# closes a gap ONLY via the typed gap_prs FK, never a PR title.
#
# Fixtures (all in a throwaway state.db; fake gh + chump on PATH, no network):
#   CREDIBLE-9000  umbrella, OPEN, NO gap_prs row
#   CREDIBLE-9001  slice,    OPEN, gap_prs → merged PR #100 (title names the UMBRELLA)
#   CREDIBLE-9002  docs gap, OPEN, NO gap_prs row (a docs PR #300 titles it, no link)
#   CREDIBLE-9003  slice,    OPEN, gap_prs → merged PR #200 whose body is "AC1 only"
#
# Asserts:
#   AC1  only the FK-linked slice CREDIBLE-9001 closes; the umbrella CREDIBLE-9000
#        (title-named by #100 but unlinked) does NOT.
#   AC5  the docs gap CREDIBLE-9002 (no gap_prs row) does NOT close.
#   AC1(e) the partial-delivery PR #200 closes nothing; CREDIBLE-9003 stays open
#        and a gap_close_skipped_partial_pr event is emitted.

set -euo pipefail
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/coord/gap-doctor-reconcile.py"
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: sqlite3 unavailable"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# git-init the fixture so the reconciler's REPO_ROOT (git toplevel, resolved at
# import) is $TMP — keeps its ambient.jsonl writes inside the fixture, not the
# real repo. The reconciler still reads the gap store via $CHUMP_STATE_DB.
git init --quiet "$TMP" 2>/dev/null || { echo "SKIP: git init failed"; exit 0; }

STATE_DB="$TMP/state.db"
sqlite3 "$STATE_DB" <<'SQL'
CREATE TABLE gaps (id TEXT PRIMARY KEY, status TEXT, title TEXT);
INSERT INTO gaps VALUES ('CREDIBLE-9000','open','umbrella');
INSERT INTO gaps VALUES ('CREDIBLE-9001','open','slice one');
INSERT INTO gaps VALUES ('CREDIBLE-9002','open','docs gap');
INSERT INTO gaps VALUES ('CREDIBLE-9003','open','slice three');
CREATE TABLE gap_prs (gap_id TEXT, pr_number INTEGER, head_sha TEXT,
                      opened_at INTEGER, state TEXT,
                      PRIMARY KEY (gap_id, pr_number));
INSERT INTO gap_prs VALUES ('CREDIBLE-9001',100,'deadbeef',100,'open');
INSERT INTO gap_prs VALUES ('CREDIBLE-9003',200,'cafef00d',200,'open');
SQL

# ── fake gh ───────────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# repo view → test/repo
if [[ "$1" == "repo" && "$2" == "view" ]]; then echo "test/repo"; exit 0; fi
# api repos/.../pulls/<N> → "<state> <merged_at>"  (both PRs are merged)
if [[ "$1" == "api" ]]; then
  case "$*" in
    *"/pulls/100"*) echo "closed 2026-10-18T00:00:00Z"; exit 0 ;;
    *"/pulls/200"*) echo "closed 2026-10-18T00:30:00Z"; exit 0 ;;
    *) echo "closed -"; exit 0 ;;
  esac
fi
# pr view <N> --json body → body text
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  case "$3" in
    100) echo "Implements the slice fully. Closes the gap." ;;
    200) echo "This PR delivers AC1 ONLY; AC2-AC4 remain open as later slices." ;;
    *)   echo "" ;;
  esac
  exit 0
fi
echo ""; exit 0
EOF
chmod +x "$TMP/bin/gh"

# ── fake chump: record `gap ship` calls to a file ──────────────────────────────
cat >"$TMP/bin/chump" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "gap" && "\$2" == "ship" ]]; then
  echo "\$3" >> "$TMP/shipped.txt"
fi
exit 0
EOF
chmod +x "$TMP/bin/chump"

export PATH="$TMP/bin:$PATH"
export CHUMP_STATE_DB="$STATE_DB"
export CHUMP_REPO_ROOT="$TMP"
mkdir -p "$TMP/.chump-locks"
AMBIENT="$TMP/.chump-locks/ambient.jsonl"

# Run the link-based closer (apply mode) from inside the fixture repo so the
# reconciler's git-toplevel REPO_ROOT (and thus its ambient.jsonl) is $TMP.
( cd "$TMP" && python3 "$SCRIPT" --check-merged-pr-links ) >/dev/null 2>&1 || true

SHIPPED="$(cat "$TMP/shipped.txt" 2>/dev/null || true)"

# AC1: the FK-linked slice closes.
if grep -qx 'CREDIBLE-9001' <<<"$SHIPPED"; then
  pass "AC1: FK-linked slice CREDIBLE-9001 closed"
else
  fail "AC1: FK-linked slice CREDIBLE-9001 was NOT closed (shipped='$SHIPPED')"
fi

# AC1: the umbrella (title-named by #100 but unlinked) does NOT close.
if grep -qx 'CREDIBLE-9000' <<<"$SHIPPED"; then
  fail "AC1: umbrella CREDIBLE-9000 closed by title — must require a gap_prs row"
else
  pass "AC1: umbrella CREDIBLE-9000 NOT closed (no gap_prs row)"
fi

# AC5: the docs gap with no gap_prs row does NOT close.
if grep -qx 'CREDIBLE-9002' <<<"$SHIPPED"; then
  fail "AC5: docs gap CREDIBLE-9002 closed without a gap_prs row"
else
  pass "AC5: docs gap CREDIBLE-9002 NOT closed (no gap_prs row)"
fi

# AC1(e): the partial-delivery PR closes nothing + emits the skip event.
if grep -qx 'CREDIBLE-9003' <<<"$SHIPPED"; then
  fail "AC1(e): partial-delivery slice CREDIBLE-9003 was closed — must be skipped"
else
  pass "AC1(e): partial-delivery slice CREDIBLE-9003 NOT closed"
fi
if grep -q '"kind":"gap_close_skipped_partial_pr"' "$AMBIENT" 2>/dev/null \
   && grep -q 'CREDIBLE-9003' "$AMBIENT" 2>/dev/null; then
  pass "AC1(e): gap_close_skipped_partial_pr emitted for CREDIBLE-9003"
else
  fail "AC1(e): no gap_close_skipped_partial_pr event for CREDIBLE-9003"
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
echo "[no-title-closer-reconcile] ALL PASS"
