#!/usr/bin/env bash
# test-doctrine-seam-finder.sh — META-1040
#
# Fixture test for scripts/coord/doctrine-seam-finder.py: builds a throwaway
# doc tree and asserts discovery, the cross-reference graph, asymmetry flags,
# topic-overlap scoring and JSON validity. Hermetic: no network, no repo reads.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FINDER="$REPO_ROOT/scripts/coord/doctrine-seam-finder.py"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp -d -t test-meta-1040.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
R="$TMP/repo"
mkdir -p "$R/docs/process" "$R/.claude/agents" "$R/docs/other"

cat > "$R/docs/process/ALPHA.md" <<'EOF'
# Alpha Playbook
Rescue stuck merge queue pull requests: rebase, rearm, cascade unblock.
See [Beta](BETA.md) and docs/process/GAMMA.md for escalation.
EOF
cat > "$R/docs/process/BETA.md" <<'EOF'
# Beta Playbook
Merge queue rescue: rebase stuck pull requests then rearm cascade.
EOF
cat > "$R/docs/process/GAMMA.md" <<'EOF'
# Gamma Playbook
Dashboard rendering colours typography layout widgets.
```
ignored fenced mention of ALPHA.md
```
EOF
cat > "$R/AGENTS.md" <<'EOF'
# Agents
Read docs/process/ALPHA.md first.
EOF
echo "# Role" > "$R/.claude/agents/role.md"
echo "# Out of scope" > "$R/docs/other/NOTES.md"

OUT="$TMP/graph.json"
python3 "$FINDER" --root "$R" --output "$OUT" || fail "finder exited non-zero"
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$OUT" || fail "output is not valid JSON"
pass "emits valid JSON"

q() { python3 - "$OUT" "$1" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"g": g}))
PY
}

[[ "$(q 'sorted(p["path"] for p in g["playbooks"])')" == \
   "['.claude/agents/role.md', 'AGENTS.md', 'docs/process/ALPHA.md', 'docs/process/BETA.md', 'docs/process/GAMMA.md']" ]] \
  || fail "scope discovery wrong: $(q '[p["path"] for p in g["playbooks"]]')"
pass "enumerates in-scope playbooks, skips out-of-scope docs"

# Auto-discovery: a new playbook appears with no code change.
echo "# Delta" > "$R/docs/process/DELTA.md"
python3 "$FINDER" --root "$R" --output "$OUT"
[[ "$(q 'any(p["path"]=="docs/process/DELTA.md" for p in g["playbooks"])')" == "True" ]] \
  || fail "new playbook not auto-discovered"
pass "auto-discovers a newly added playbook"

[[ "$(q 'sorted((e["from"],e["to"]) for e in g["edges"])')" == \
   "[('AGENTS.md', 'docs/process/ALPHA.md'), ('docs/process/ALPHA.md', 'docs/process/BETA.md'), ('docs/process/ALPHA.md', 'docs/process/GAMMA.md')]" ]] \
  || fail "edges wrong: $(q '[(e["from"],e["to"]) for e in g["edges"]]')"
pass "cross-reference graph: markdown links + path mentions, fenced code ignored"

[[ "$(q 'all(e["asymmetric"] for e in g["edges"])')" == "True" ]] \
  || fail "one-way edges should be flagged asymmetric"
pass "one-way references flagged asymmetric"

[[ "$(q '[p["inbound_count"] for p in g["playbooks"] if p["path"]=="docs/process/ALPHA.md"][0]')" == "1" ]] \
  || fail "inbound_count wrong"
pass "inbound counts computed"

top="$(q '(g["overlap"][0]["a"], g["overlap"][0]["b"], g["overlap"][0]["linked"])')"
[[ "$top" == "('docs/process/ALPHA.md', 'docs/process/BETA.md', True)" ]] \
  || fail "top overlap pair wrong: $top"
[[ "$(q 'any("GAMMA" in o["a"]+o["b"] for o in g["overlap"])')" == "False" ]] \
  || fail "unrelated playbook should not overlap"
pass "topic-overlap score ranks the related pair first; unrelated pair absent"

# Determinism: same input -> byte-identical output.
python3 "$FINDER" --root "$R" > "$TMP/a.json"
python3 "$FINDER" --root "$R" > "$TMP/b.json"
cmp -s "$TMP/a.json" "$TMP/b.json" || fail "output not deterministic"
pass "deterministic output"

# Real tree smoke: runs and finds a non-trivial playbook set.
python3 "$FINDER" --root "$REPO_ROOT" --output "$TMP/real.json" || fail "real-tree run failed"
python3 - "$TMP/real.json" <<'PY' || fail "real-tree graph implausible"
import json, sys
g = json.load(open(sys.argv[1]))
assert len(g["playbooks"]) >= 10, len(g["playbooks"])
assert any(p["path"] == "AGENTS.md" for p in g["playbooks"])
PY
pass "real tree scans cleanly"

echo "=== META-1040: all checks passed ==="
