#!/usr/bin/env bash
# test-external-repo-ship-emit.sh — INFRA-2169: external_repo_ship ambient event
#
# Tests:
#   1. After a successful cross-repo (fork) PR rescue, kind=external_repo_ship
#      is emitted to ambient.jsonl with all required fields.
#   2. Same-repo (non-fork) PR rescue does NOT emit kind=external_repo_ship.
#   3. A failed fork rescue does NOT emit kind=external_repo_ship.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESCUE="$REPO_ROOT/scripts/coord/pr-rescue.sh"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

[[ -f "$RESCUE" ]] || fail "pr-rescue.sh not found at $RESCUE"

TMP="$(mktemp -d -t test-ext-ship.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ── Fake bare upstream (serves as both upstream and fork in tests) ────────────
FAKE_UPSTREAM="$TMP/upstream.git"
git init --bare "$FAKE_UPSTREAM" -b main -q 2>/dev/null \
    || git init --bare "$FAKE_UPSTREAM" -q
FAKE_SEED="$TMP/seed"
git clone "$FAKE_UPSTREAM" "$FAKE_SEED" -q 2>/dev/null || true
git -C "$FAKE_SEED" config user.email "test@test.com" 2>/dev/null || true
git -C "$FAKE_SEED" config user.name  "Test" 2>/dev/null || true
echo "seed" > "$FAKE_SEED/README.md"
git -C "$FAKE_SEED" add -A
git -C "$FAKE_SEED" commit -m "init" -q 2>/dev/null || true
git -C "$FAKE_SEED" push origin HEAD:main -q 2>/dev/null || true
# Also push the "fork" branch so fetch succeeds
git -C "$FAKE_SEED" checkout -b fix-branch -q 2>/dev/null || git -C "$FAKE_SEED" checkout fix-branch -q
echo "fork change" > "$FAKE_SEED/fork.txt"
git -C "$FAKE_SEED" add -A
git -C "$FAKE_SEED" commit -m "fork change" -q 2>/dev/null || true
git -C "$FAKE_SEED" push origin HEAD:fix-branch -q 2>/dev/null || true
git -C "$FAKE_SEED" checkout main -q 2>/dev/null || true
# Also seed the same-branch used by test 2
git -C "$FAKE_SEED" checkout -b same-branch -q 2>/dev/null || git -C "$FAKE_SEED" checkout same-branch -q
echo "same change" > "$FAKE_SEED/same.txt"
git -C "$FAKE_SEED" add -A
git -C "$FAKE_SEED" commit -m "same change" -q 2>/dev/null || true
git -C "$FAKE_SEED" push origin HEAD:same-branch -q 2>/dev/null || true
git -C "$FAKE_SEED" checkout main -q 2>/dev/null || true

# ── Helper: build a fake REPO_ROOT with stub libs ────────────────────────────
make_fake_root() {
    local root="$1"
    mkdir -p "$root/.chump-locks"
    mkdir -p "$root/scripts/coord/lib"

    # ambient-write.sh — append JSON to the ambient file
    cat > "$root/scripts/coord/lib/ambient-write.sh" <<'EOF'
_ambient_write() { local f="$1"; shift; printf '%s\n' "$*" >> "$f"; }
EOF

    # github.sh — delegate to our mock gh binary
    cat > "$root/scripts/coord/lib/github.sh" <<'EOF'
chump_gh() { gh "$@"; }
export CHUMP_GH_SCRIPT="${CHUMP_GH_SCRIPT:-pr-rescue.sh}"
EOF

    # github_cache.sh — no-op
    cat > "$root/scripts/coord/lib/github_cache.sh" <<'EOF'
cache_lookup_pr() { echo ""; }
EOF

    # broadcast.sh stub
    cat > "$root/scripts/coord/broadcast.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$root/scripts/coord/broadcast.sh"

    # auto-merge-armer.sh stub
    cat > "$root/scripts/coord/auto-merge-armer.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$root/scripts/coord/auto-merge-armer.sh"

    # Fake git repo (so git remote get-url origin works)
    git -C "$root" init -q 2>/dev/null || true
    git -C "$root" remote add origin "$FAKE_UPSTREAM" 2>/dev/null || true

    # Copy rescue script into the fake tree
    cp "$RESCUE" "$root/scripts/coord/pr-rescue.sh"
}

# ── Build a Python-based gh mock (handles --jq natively) ─────────────────────
# Args: $1=mock_bin_dir, $2=cross_repo (true|false), $3=pr_num, $4=pr_branch,
#       $5=head_sha, $6=rescue_ok (0=fail-push 1=ok)
make_gh_mock() {
    local bin_dir="$1" cross_repo="$2" pr_num="$3" pr_branch="$4"
    local head_sha="$5" rescue_ok="${6:-1}"

    mkdir -p "$bin_dir"
    cat > "$bin_dir/gh" <<PYEOF
#!/usr/bin/env python3
import sys, os, json, subprocess, re

args = sys.argv[1:]
log_f = os.environ.get("GH_CALL_LOG", "")

def log(s):
    if log_f:
        open(log_f, "a").write(s + "\n")

def apply_jq(data_str, jq_expr):
    """Minimal jq shim for the expressions pr-rescue.sh uses."""
    data = json.loads(data_str)
    # .object.sha
    if jq_expr == ".object.sha":
        return data.get("object", {}).get("sha", "")
    # '[.[] | select(.auto_merge != null) | .number] | .[]'
    if "auto_merge" in jq_expr and "number" in jq_expr:
        nums = [str(x["number"]) for x in data if x.get("auto_merge") is not None]
        return "\n".join(nums)
    # '[.check_runs[] | select(.conclusion == "success") | .name] | .[]'
    if "check_runs" in jq_expr and "success" in jq_expr:
        names = [r["name"] for r in data.get("check_runs", [])
                 if r.get("conclusion") == "success"]
        return "\n".join(names)
    # '[.check_runs[] | select(.conclusion == "failure" or .conclusion == "timed_out") | .name] | .[]'
    if "check_runs" in jq_expr and "failure" in jq_expr:
        names = [r["name"] for r in data.get("check_runs", [])
                 if r.get("conclusion") in ("failure", "timed_out")]
        return "\n".join(names)
    # 'length'
    if jq_expr.strip() == "length":
        return str(len(data))
    return ""

CROSS_REPO   = "${cross_repo}"
PR_NUM       = ${pr_num}
PR_BRANCH    = "${pr_branch}"
HEAD_SHA     = "${head_sha}"
RESCUE_OK    = ${rescue_ok}

# PR meta JSON
pr_meta = {
    "number": PR_NUM,
    "state": "open",
    "mergeable": "MERGEABLE",
    "head": {"ref": PR_BRANCH, "sha": HEAD_SHA},
    "created_at": "2020-01-01T00:00:00Z",
    "auto_merge": {"merge_method": "squash"},
    "autoMergeRequest": {"mergeMethod": "squash"},
}

# fork meta JSON
fork_meta = {
    "isCrossRepository": CROSS_REPO == "true",
    "headRepositoryOwner": {"login": "externaluser" if CROSS_REPO == "true" else "chump"},
    "baseRepositoryOwner": {"login": "chump"},
}

# check-runs: failing on PR HEAD, passing on main
pr_checks = {"check_runs": [{"name": "ci-test", "conclusion": "failure", "status": "completed"}]}
main_checks = {"check_runs": [{"name": "ci-test", "conclusion": "success", "status": "completed"}]}
main_ref = {"object": {"sha": "mainsha" + "0" * 34}}
files_response = [{"filename": f"file{i}.rs"} for i in range(3)]

if not args:
    sys.exit(0)

subcmd = args[0]
rest   = args[1:]

log("gh " + " ".join(args))

if subcmd == "auth":
    sys.exit(0)

elif subcmd == "api":
    # parse --jq flag
    jq_expr = None
    path_args = []
    i = 0
    while i < len(rest):
        if rest[i] == "--jq" and i + 1 < len(rest):
            jq_expr = rest[i + 1]; i += 2
        elif rest[i] in ("-X", "-f"):
            i += 2  # skip method/field args
        else:
            path_args.append(rest[i]); i += 1

    path = path_args[0] if path_args else ""

    # route by path
    if re.search(r"pulls\?state=open", path):
        data = [pr_meta]
    elif re.search(r"pulls/" + str(PR_NUM) + r"/files", path):
        data = files_response
    elif re.search(r"pulls/" + str(PR_NUM) + r"/merge$", path):
        sys.exit(0)
    elif re.search(r"pulls/" + str(PR_NUM) + r"$", path):
        data = pr_meta
    elif re.search(r"commits/" + re.escape(HEAD_SHA) + r"/check-runs", path):
        data = pr_checks
    elif re.search(r"commits/.*/check-runs", path):
        data = main_checks
    elif re.search(r"git/ref", path):
        data = main_ref
    else:
        data = {}

    out = json.dumps(data)
    if jq_expr:
        out = apply_jq(out, jq_expr)
    print(out)

elif subcmd == "pr":
    pr_cmd = rest[0] if rest else ""
    if pr_cmd == "view":
        print(json.dumps(fork_meta))
    elif pr_cmd == "merge":
        sys.exit(0)
    else:
        sys.exit(0)

else:
    sys.exit(0)
PYEOF
    chmod +x "$bin_dir/gh"
}

# ── Test 1: fork PR — external_repo_ship emitted ─────────────────────────────
FAKE_ROOT1="$TMP/repo1"
make_fake_root "$FAKE_ROOT1"

MOCK1="$TMP/mock1"
make_gh_mock "$MOCK1" "true" "7" "fix-branch" "abc1234def5678abc1234def5678abc1234def56" "1"

# git stub: rewrite any https://github.com/... URL to FAKE_UPSTREAM so all
# clone/remote-add/fetch/push calls stay local and never hit the network.
cat > "$MOCK1/git" <<GITEOF
#!/usr/bin/env bash
newargs=()
for arg in "\$@"; do
    if [[ "\$arg" =~ ^https://github\.com/ ]]; then
        newargs+=("$FAKE_UPSTREAM")
    else
        newargs+=("\$arg")
    fi
done
exec /usr/bin/git "\${newargs[@]}"
GITEOF
chmod +x "$MOCK1/git"

AMBIENT1="$FAKE_ROOT1/.chump-locks/ambient.jsonl"
GH_TOKEN="fake-token" \
GH_CALL_LOG="$TMP/calls1.log" \
CHUMP_OFF_RAILS_CHECK=0 \
CHUMP_PR_RESCUE_REST_ONLY=1 \
CHUMP_SESSION_ID="test-session-001" \
CHUMP_GAP_ID="INFRA-2169" \
PATH="$MOCK1:$PATH" \
bash "$FAKE_ROOT1/scripts/coord/pr-rescue.sh" \
    --repo "chump/Chump" \
    2>"$TMP/stderr1.txt" || true

if grep -q '"kind":"external_repo_ship"' "$AMBIENT1" 2>/dev/null; then
    pass "Test 1: kind=external_repo_ship emitted for cross-repo PR"
else
    echo "=== stderr ===" >&2; cat "$TMP/stderr1.txt" >&2
    echo "=== ambient ===" >&2; cat "$AMBIENT1" 2>/dev/null >&2 || echo "(empty)" >&2
    fail "Test 1: kind=external_repo_ship NOT found in ambient.jsonl"
fi

LINE1="$(grep '"kind":"external_repo_ship"' "$AMBIENT1" | tail -1)"
for field in ts gap_id external_repo pr_url head_sha files_touched_count shipper_session; do
    echo "$LINE1" | grep -q "\"${field}\":" \
        || fail "Test 1: required field '${field}' missing from payload"
done
pass "Test 1: all required fields present"

echo "$LINE1" | grep -q '"external_repo":"externaluser/Chump"' \
    || fail "Test 1: external_repo field wrong (expected externaluser/Chump)"
pass "Test 1: external_repo=externaluser/Chump correct"

echo "$LINE1" | grep -q '"files_touched_count":3' \
    || fail "Test 1: files_touched_count should be 3"
pass "Test 1: files_touched_count=3 correct"

# ── Test 2: same-repo PR — external_repo_ship NOT emitted ────────────────────
FAKE_ROOT2="$TMP/repo2"
make_fake_root "$FAKE_ROOT2"

MOCK2="$TMP/mock2"
make_gh_mock "$MOCK2" "false" "8" "same-branch" "samesha00000000000000000000000000000000000" "1"
cat > "$MOCK2/git" <<GITEOF2
#!/usr/bin/env bash
newargs=()
for arg in "\$@"; do
    if [[ "\$arg" =~ ^https://github\.com/ ]]; then
        newargs+=("$FAKE_UPSTREAM")
    else
        newargs+=("\$arg")
    fi
done
exec /usr/bin/git "\${newargs[@]}"
GITEOF2
chmod +x "$MOCK2/git"

AMBIENT2="$FAKE_ROOT2/.chump-locks/ambient.jsonl"
GH_TOKEN="fake-token" \
CHUMP_OFF_RAILS_CHECK=0 \
CHUMP_PR_RESCUE_REST_ONLY=1 \
CHUMP_SESSION_ID="test-session-002" \
CHUMP_GAP_ID="INFRA-SAME" \
PATH="$MOCK2:$PATH" \
bash "$FAKE_ROOT2/scripts/coord/pr-rescue.sh" \
    --repo "chump/Chump" \
    2>"$TMP/stderr2.txt" || true

if grep -q '"kind":"external_repo_ship"' "$AMBIENT2" 2>/dev/null; then
    fail "Test 2: external_repo_ship erroneously emitted for same-repo PR"
fi
pass "Test 2: external_repo_ship NOT emitted for same-repo PR (correct)"

printf '\n[OK] All tests passed.\n'
