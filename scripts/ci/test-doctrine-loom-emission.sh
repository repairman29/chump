#!/usr/bin/env bash
# test-doctrine-loom-emission.sh — META-1044
#
# Smoke test for scripts/coord/doctrine-loom-daemon.sh: a tick on a fixture
# tree exits 0, emits doctrine_weave_tick plus the detector kinds, regenerates
# DOCTRINE_INDEX.md / DOCTRINE_GRAPH.md, is idempotent, honours --dry-run and
# the bypass, files a gap only when opted in (once per finding set), and the
# daemon / plist carry no paging path and a 30-minute cadence.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DAEMON="$REPO_ROOT/scripts/coord/doctrine-loom-daemon.sh"
PLIST="$REPO_ROOT/scripts/launchd/com.chump.doctrine-loom.plist"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d -t test-meta-1044.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
R="$TMP/repo"; mkdir -p "$R/docs/process" "$R/docs/gaps"
printf '# Alpha\nSee BETA.md#nope and BETA.md §4. Done in FIX-1.\n' > "$R/docs/process/ALPHA.md"
printf '# Beta\n## 1. Only\n' > "$R/docs/process/BETA.md"
printf -- '- id: FIX-1\n  status: done\n' > "$R/docs/gaps/FIX-1.yaml"

export CHUMP_LOOM_REPO_ROOT="$R" CHUMP_LOCK_DIR="$TMP/locks" CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"

# --dry-run: no emission, no publish.
bash "$DAEMON" --dry-run >/dev/null || fail "dry-run exited non-zero"
[[ ! -e "$CHUMP_AMBIENT_LOG" && ! -e "$R/docs/process/DOCTRINE_INDEX.md" ]] || fail "dry-run wrote files"
pass "--dry-run emits and writes nothing"

CHUMP_DOCTRINE_LOOM=0 bash "$DAEMON" >/dev/null || fail "bypass exited non-zero"
[[ ! -e "$CHUMP_AMBIENT_LOG" ]] || fail "bypass emitted"
pass "CHUMP_DOCTRINE_LOOM=0 bypass is a silent no-op"

bash "$DAEMON" --once >/dev/null || fail "tick exited non-zero"
pass "tick exits 0"

python3 - "$CHUMP_AMBIENT_LOG" <<'PY' || fail "emitted kinds wrong"
import json, sys
ev = [json.loads(l) for l in open(sys.argv[1])]
kinds = {e["kind"] for e in ev}
want = {"doctrine_weave_tick", "doctrine_weave_asymmetry", "doctrine_weave_frayed_edge"}
assert want <= kinds, kinds
t = [e for e in ev if e["kind"] == "doctrine_weave_tick"][0]
assert t["playbooks"] == 2 and t["frayed_edges"] >= 2 and t["files_published"] == 2, t
PY
pass "emits doctrine_weave_tick + asymmetry + frayed_edge with counts"

for f in DOCTRINE_INDEX.md DOCTRINE_GRAPH.md; do
    [[ -s "$R/docs/process/$f" ]] || fail "$f not generated"
done
grep -q 'ALPHA.md' "$R/docs/process/DOCTRINE_INDEX.md" || fail "index missing playbook"
grep -q 'doctrine-loom-daemon.sh' "$R/docs/process/DOCTRINE_INDEX.md" || fail "index not self-referential"
grep -q '^```mermaid' "$R/docs/process/DOCTRINE_GRAPH.md" || fail "graph not mermaid"
pass "INDEX + GRAPH regenerated (index is self-referential, graph is Mermaid)"

bash "$DAEMON" --once >/dev/null
[[ "$(grep -c doctrine_weave_tick "$CHUMP_AMBIENT_LOG")" == "2" ]] || fail "second tick did not emit"
python3 - "$CHUMP_AMBIENT_LOG" <<'PY' || fail "second tick republished"
import json, sys
t = [json.loads(l) for l in open(sys.argv[1]) if "doctrine_weave_tick" in l]
assert t[1]["files_published"] == 0, t[1]
PY
pass "second tick on an unchanged tree republishes nothing"

# Gap filing: opt-in, once per finding set, stub chump binary.
cat > "$TMP/chump-stub" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$TMP/gap-calls.log"
STUB
chmod +x "$TMP/chump-stub"
bash "$DAEMON" --once >/dev/null
[[ ! -e "$TMP/gap-calls.log" ]] || fail "filed a gap without opt-in"
CHUMP_LOOM_FILE_GAPS=1 CHUMP_LOOM_CHUMP_BIN="$TMP/chump-stub" bash "$DAEMON" --once >/dev/null
CHUMP_LOOM_FILE_GAPS=1 CHUMP_LOOM_CHUMP_BIN="$TMP/chump-stub" bash "$DAEMON" --once >/dev/null
[[ "$(wc -l < "$TMP/gap-calls.log")" == "1" ]] || fail "expected exactly one gap filing, got: $(cat "$TMP/gap-calls.log")"
grep -q 'gap reserve --domain META' "$TMP/gap-calls.log" || fail "gap reserve not invoked as expected"
pass "gap filing is opt-in and de-duplicated per finding set"

if grep -Eqi 'notify-operator|notify_operator|pagerduty|osascript|discord' "$DAEMON"; then
    fail "daemon contains a paging path (no-escalation doctrine)"
fi
pass "daemon has no paging path"

grep -q '<integer>1800</integer>' "$PLIST" || fail "plist is not a 30-minute cadence"
grep -q 'doctrine-loom-daemon.sh --once' "$PLIST" || fail "plist does not run the daemon"
if command -v plutil >/dev/null 2>&1; then plutil -lint "$PLIST" >/dev/null || fail "plist invalid"; fi
python3 -c "import plistlib,sys; plistlib.load(open(sys.argv[1],'rb'))" "$PLIST" || fail "plist does not parse"
pass "launchd plist parses and schedules a 30-minute tick"

echo "=== META-1044: all checks passed ==="
