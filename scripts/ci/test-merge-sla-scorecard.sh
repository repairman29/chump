#!/usr/bin/env bash
# scripts/ci/test-merge-sla-scorecard.sh — RESILIENT-302

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/coord/merge-sla-scorecard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
[ -x "$SCRIPT" ] || fail "missing or not executable"

# Fake gh: only a liveness probe (command -v gh) + the lib/-internal
# cache-miss fallback. The seeded cache DB below means the script itself
# never has to shell out (INFRA-1274 cache-first).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
    "repo view") echo "fake/repo"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

mkdir -p "$TMP/repo/scripts/coord" "$TMP/repo/.chump-locks"
cp "$SCRIPT" "$TMP/repo/scripts/coord/merge-sla-scorecard.sh"
cp -r "$REPO_ROOT/scripts/coord/lib" "$TMP/repo/scripts/coord/lib"
chmod +x "$TMP/repo/scripts/coord/merge-sla-scorecard.sh"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" -c user.email=t@t -c user.name=t add -A
git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -q -m s

# INFRA-1274: seed the cache DB directly instead of faking `gh api`.
export CHUMP_CACHE_DB="$TMP/repo/.chump/github_cache.db"
mkdir -p "$(dirname "$CHUMP_CACHE_DB")"

old_ts="$(date -u -v -1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
fresh_ts="$(date -u -v -5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)"
now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

seed_pr() {
    local number="$1" created_at="$2" title="$3" head_ref="$4"
    python3 - "$CHUMP_CACHE_DB" "$number" "$head_ref" "$title" "$now_ts" "$created_at" <<'PY'
import json, sqlite3, sys
db_path, number, head_ref, title, now_ts, created_at = sys.argv[1:7]
payload = json.dumps({"number": int(number), "created_at": created_at,
                       "title": title, "head": {"ref": head_ref}})
conn = sqlite3.connect(db_path)
conn.executescript("""
CREATE TABLE IF NOT EXISTS pr_state (
    number INTEGER PRIMARY KEY,
    head_ref TEXT, head_sha TEXT, base_ref TEXT, base_sha TEXT,
    mergeable_state TEXT,
    auto_merge_enabled INTEGER NOT NULL DEFAULT 0,
    draft INTEGER NOT NULL DEFAULT 0,
    merged_at TEXT, title TEXT, user_login TEXT,
    updated_at_api TEXT NOT NULL, fetched_at_local TEXT NOT NULL,
    raw_payload_json TEXT
);
""")
conn.execute(
    "INSERT INTO pr_state (number, head_ref, title, merged_at, updated_at_api, fetched_at_local, raw_payload_json) "
    "VALUES (?,?,?,NULL,?,?,?)",
    (int(number), head_ref, title, now_ts, now_ts, payload),
)
conn.commit()
PY
}

# old unowned PR (created 1h ago) → BREACH
seed_pr 100 "$old_ts" "feat(INFRA-3001): old unowned PR" "chump/foo"
# fresh PR (5m ago) → SKIPPED (under threshold)
seed_pr 200 "$fresh_ts" "feat(INFRA-3002): fresh PR" "chump/bar"
# old owned PR (has an active claim lease) → SKIPPED (owned)
seed_pr 300 "$old_ts" "feat(INFRA-3003): old owned PR" "chump/baz"
mkdir -p "$TMP/repo/.chump-locks"
echo '{"session_id":"worker-9"}' > "$TMP/repo/.chump-locks/claim-infra-3003-abc.json"

# ── Test 1: dry-run identifies only the unowned breach ─────────────────────
out=$(cd "$TMP/repo" && CHUMP_CACHE_DB="$CHUMP_CACHE_DB" bash scripts/coord/merge-sla-scorecard.sh 2>&1)
echo "$out" | grep -q "WOULD BREACH #100" \
    || fail "expected to flag #100 as breach: $out"
if echo "$out" | grep -q "WOULD BREACH #200"; then
    fail "fresh PR (#200) must be skipped (under threshold)"
fi
if echo "$out" | grep -q "WOULD BREACH #300"; then
    fail "owned PR (#300) must be skipped (has claim lease owner)"
fi
echo "$out" | grep -q "OWNED #300" || fail "expected #300 reported as OWNED: $out"
ok "identifies only the unowned breach; skips fresh + owned"

# ── Test 2: --apply emits sla_breach ambient + writes dedup stamp ──────────
out2=$(cd "$TMP/repo" && CHUMP_CACHE_DB="$CHUMP_CACHE_DB" bash scripts/coord/merge-sla-scorecard.sh --apply 2>&1)
echo "$out2" | grep -q "BREACH #100" \
    || fail "apply mode should breach #100: $out2"
[ -f "$TMP/repo/.chump-locks/.sla-breach-sent/100.ts" ] \
    || fail "dedup stamp missing after apply"
grep -q '"kind":"sla_breach"' "$TMP/repo/.chump-locks/ambient.jsonl" \
    || fail "sla_breach event not written to ambient.jsonl"
grep -q '"pr":100' "$TMP/repo/.chump-locks/ambient.jsonl" \
    || fail "sla_breach event missing pr field"
ok "--apply emits sla_breach ambient event + writes dedup stamp"

# ── Test 3: re-run within cooldown skips re-paging but still counts ────────
out3=$(cd "$TMP/repo" && CHUMP_CACHE_DB="$CHUMP_CACHE_DB" bash scripts/coord/merge-sla-scorecard.sh --apply 2>&1)
echo "$out3" | grep -q "skipped-dedup=1" \
    || fail "second run should report 1 skipped via dedup: $out3"
ok "dedup cooldown prevents re-paging"

# ── Test 4: cooldown=0 → resend allowed ─────────────────────────────────────
out4=$(cd "$TMP/repo" && CHUMP_CACHE_DB="$CHUMP_CACHE_DB" bash scripts/coord/merge-sla-scorecard.sh --apply --cooldown 0 2>&1)
echo "$out4" | grep -q "escalated=1" \
    || fail "--cooldown 0 must let resend through: $out4"
ok "--cooldown 0 disables dedup"

echo
echo "All RESILIENT-302 merge-sla-scorecard tests passed."
