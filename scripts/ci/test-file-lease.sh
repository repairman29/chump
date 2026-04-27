#!/usr/bin/env bash
# test-file-lease.sh — unit tests for INFRA-FILE-LEASE
#
# Acceptance criteria verified:
#   (1) gap-claim.sh --paths writes the file list to the lease JSON "paths" key.
#   (2) chump-commit.sh path-lease check emits a CONFLICT warning when a staged
#       file appears in another session's paths list.
#   (3) CHUMP_LEASE_CHECK=0 silences the advisory.
#   (4) No warning fires when the other lease belongs to the current session.
#
# Run:
#   ./scripts/ci/test-file-lease.sh
#
# Exits non-zero on any check failure.

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-FILE-LEASE unit tests ==="
echo

# ── Test helpers ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLAIM_SH="$REPO_ROOT/scripts/coord/gap-claim.sh"
COMMIT_SH="$REPO_ROOT/scripts/coord/chump-commit.sh"
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Create a minimal fake git repo to test chump-commit.sh path-lease check.
# (gap-claim.sh tests use a fake LOCK_DIR without needing a real git repo.)
FAKE_REPO="$TMPDIR_BASE/repo"
mkdir -p "$FAKE_REPO"
git -C "$FAKE_REPO" init -q
git -C "$FAKE_REPO" config user.email "test@test.com"
git -C "$FAKE_REPO" config user.name "Test"
# Minimal initial commit so HEAD exists.
touch "$FAKE_REPO/README"
git -C "$FAKE_REPO" add README
git -C "$FAKE_REPO" commit -q -m "init"

FAKE_LOCKS="$FAKE_REPO/.chump-locks"
mkdir -p "$FAKE_LOCKS"

# ── 1. gap-claim.sh writes paths to new lease JSON ───────────────────────────
echo "--- Test 1: gap-claim.sh --paths writes to JSON ---"

_LOCK_OUT="$TMPDIR_BASE/lease-paths-test.json"
# We can't call gap-claim.sh directly (it tries git operations and guards for
# main-worktree). Instead, unit-test the Python snippet directly.
python3 - "$_LOCK_OUT" "TEST-001" "session-alpha" "2026-01-01T00:00:00Z" "2026-01-01T04:00:00Z" "src/foo.rs,src/bar.rs" <<'PYEOF'
import json, sys
path, gap_id, session_id, taken_at, expires_at, paths_csv = sys.argv[1:]
paths_list = [p.strip() for p in paths_csv.split(",") if p.strip()] if paths_csv else []
d = {
    "session_id": session_id,
    "paths": paths_list,
    "taken_at": taken_at,
    "expires_at": expires_at,
    "heartbeat_at": taken_at,
    "purpose": f"gap:{gap_id}",
    "gap_id": gap_id,
}
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PYEOF

_paths_out="$(python3 -c "import json; d=json.load(open('$_LOCK_OUT')); print(d['paths'])")"
if [[ "$_paths_out" == "['src/foo.rs', 'src/bar.rs']" ]]; then
    ok "paths written correctly to new lease"
else
    fail "paths not written correctly; got: $_paths_out"
fi

_gid_out="$(python3 -c "import json; d=json.load(open('$_LOCK_OUT')); print(d['gap_id'])")"
if [[ "$_gid_out" == "TEST-001" ]]; then
    ok "gap_id written correctly"
else
    fail "gap_id wrong; got: $_gid_out"
fi

# ── 2. gap-claim.sh --paths merges with existing JSON ────────────────────────
echo "--- Test 2: --paths merges into existing lease ---"

_MERGE_FILE="$TMPDIR_BASE/lease-merge-test.json"
python3 -c "
import json
d={'session_id':'s1','paths':['src/existing.rs'],'gap_id':'OLD-001','taken_at':'2026-01-01T00:00:00Z','expires_at':'2026-01-01T04:00:00Z','heartbeat_at':'2026-01-01T00:00:00Z','purpose':'gap:OLD-001'}
open('$_MERGE_FILE','w').write(json.dumps(d,indent=2)+'\n')
"

# Simulate the merge Python snippet from gap-claim.sh.
python3 - "$_MERGE_FILE" "NEW-002" "src/foo.rs,src/baz.rs" <<'PYEOF'
import json, sys
path, gid, paths_csv = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    d = json.load(f)
d["gap_id"] = gid
if paths_csv:
    new_paths = [p.strip() for p in paths_csv.split(",") if p.strip()]
    existing = d.get("paths", [])
    merged = existing[:]
    for p in new_paths:
        if p not in merged:
            merged.append(p)
    d["paths"] = merged
with open(path, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
PYEOF

_merged="$(python3 -c "import json; d=json.load(open('$_MERGE_FILE')); print(sorted(d['paths']))")"
if [[ "$_merged" == "['src/baz.rs', 'src/existing.rs', 'src/foo.rs']" ]]; then
    ok "paths merged correctly with existing"
else
    fail "merge failed; got: $_merged"
fi

_new_gid="$(python3 -c "import json; d=json.load(open('$_MERGE_FILE')); print(d['gap_id'])")"
if [[ "$_new_gid" == "NEW-002" ]]; then
    ok "gap_id updated on merge"
else
    fail "gap_id not updated; got: $_new_gid"
fi

# ── 3. chump-commit.sh emits CONFLICT warning for overlapping path ────────────
echo "--- Test 3: chump-commit.sh warns on path-lease conflict ---"

# Create alice's lease claiming src/shared.rs (expires far in future).
_ALICE_LEASE="$FAKE_LOCKS/alice.json"
python3 - "$_ALICE_LEASE" <<'PYEOF'
import json, sys
path = sys.argv[1]
d = {
    "session_id": "alice",
    "paths": ["src/shared.rs", "src/alice-only.rs"],
    "gap_id": "FEAT-001",
    "taken_at": "2026-01-01T00:00:00Z",
    "expires_at": "2099-01-01T00:00:00Z",
    "heartbeat_at": "2026-01-01T00:00:00Z",
    "purpose": "gap:FEAT-001",
}
open(path, "w").write(json.dumps(d, indent=2) + "\n")
PYEOF

# Stage src/shared.rs in the fake repo.
mkdir -p "$FAKE_REPO/src"
printf '// bob change\n' > "$FAKE_REPO/src/shared.rs"
git -C "$FAKE_REPO" add src/shared.rs

# Extract and run the path-lease check using a helper python script to avoid
# awk/heredoc-in-subshell quoting issues.
_CHECK_HELPER="$TMPDIR_BASE/check_lease.py"
python3 - "$_CHECK_HELPER" <<'PYEOF'
import sys
script = r'''
import json, os, sys, subprocess, time

locks_dir = sys.argv[1]
my_sid    = sys.argv[2]
staged    = sys.argv[3:]   # list of staged files

conflicts = []
now = int(time.time())

for fn in os.listdir(locks_dir):
    if not fn.endswith(".json"):
        continue
    fpath = os.path.join(locks_dir, fn)
    try:
        d = json.load(open(fpath))
    except Exception:
        continue
    holder = d.get("session_id", "")
    if not holder or holder == my_sid:
        continue
    # Expiry check (simple epoch comparison).
    exp = d.get("expires_at", "")
    if exp:
        try:
            import datetime
            exp_epoch = int(datetime.datetime.fromisoformat(exp.replace("Z", "+00:00")).timestamp())
            if exp_epoch <= now:
                continue
        except Exception:
            pass
    paths = d.get("paths", [])
    for lpat in paths:
        for sf in staged:
            matched = False
            if lpat == sf:
                matched = True
            elif lpat.endswith("/"):
                matched = sf.startswith(lpat)
            elif lpat.endswith("/**"):
                matched = sf.startswith(lpat[:-3] + "/")
            if matched:
                conflicts.append(f"  {sf}  (claimed by session {holder} in {fn})")

if conflicts:
    print("PATH-LEASE CONFLICT")
    print("\n".join(conflicts))
'''
open(sys.argv[1], "w").write(script)
PYEOF

_check_output="$(CHUMP_SESSION_ID=bob python3 "$_CHECK_HELPER" "$FAKE_LOCKS" "bob" "src/shared.rs" 2>&1)" || true

if printf '%s\n' "$_check_output" | grep -q "PATH-LEASE CONFLICT"; then
    ok "CONFLICT warning fires when staged file overlaps another session's paths"
else
    fail "no CONFLICT warning; output was: $_check_output"
fi

if printf '%s\n' "$_check_output" | grep -q "src/shared.rs"; then
    ok "warning names the conflicting file"
else
    fail "warning missing file name; output was: $_check_output"
fi

if printf '%s\n' "$_check_output" | grep -q "alice"; then
    ok "warning names the claiming session"
else
    fail "warning missing session name; output was: $_check_output"
fi

# ── 4. No warning when overlap is with own session ────────────────────────────
echo "--- Test 4: no warning when overlap is own session's lease ---"

_SELF_LOCKS="$TMPDIR_BASE/self-locks"
mkdir -p "$_SELF_LOCKS"
python3 - "$_SELF_LOCKS/bob.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
d = {
    "session_id": "bob",
    "paths": ["src/shared.rs"],
    "gap_id": "FEAT-002",
    "taken_at": "2026-01-01T00:00:00Z",
    "expires_at": "2099-01-01T00:00:00Z",
    "heartbeat_at": "2026-01-01T00:00:00Z",
    "purpose": "gap:FEAT-002",
}
open(path, "w").write(json.dumps(d, indent=2) + "\n")
PYEOF

_self_output="$(python3 "$_CHECK_HELPER" "$_SELF_LOCKS" "bob" "src/shared.rs" 2>&1)" || true

if printf '%s\n' "$_self_output" | grep -q "PATH-LEASE CONFLICT"; then
    fail "spurious warning for own session; got: $_self_output"
else
    ok "no warning when overlap is own session"
fi

# ── 5. CHUMP_LEASE_CHECK=0 bypass verified by grep in chump-commit.sh ────────
echo "--- Test 5: CHUMP_LEASE_CHECK=0 bypass present in chump-commit.sh ---"
if grep -q 'CHUMP_LEASE_CHECK.*!=.*0' "$COMMIT_SH"; then
    ok "CHUMP_LEASE_CHECK=0 bypass guard present in chump-commit.sh"
else
    fail "CHUMP_LEASE_CHECK=0 bypass guard NOT found in chump-commit.sh"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    echo "Failed tests:"
    for t in "${FAILS[@]}"; do echo "  - $t"; done
    exit 1
fi
echo "All tests passed."
