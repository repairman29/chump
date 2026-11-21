#!/usr/bin/env bash
# test-almanac-audit.sh — CREDIBLE-209
#
# Builds a synthetic fixture repo + Almanac index (no network, no live
# Ollama needed) and asserts the grounded/ungrounded/unverifiable verdicts
# almanac-audit.py produces are correct — including the "enterprise
# platform"-shaped false claim from acceptance criterion 2 (BEAST-MODE class
# of ungrounded capability claim), so the logic is proven without depending
# on an external repo's index being present in this environment.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/fixture-repo"
INDEX_DIR="$WORK/indexes"
mkdir -p "$REPO/src" "$INDEX_DIR"

cat > "$REPO/README.md" <<'EOF'
# fixture-repo

Call `real_symbol` to do the thing. This tool provides an enterprise platform for orchestrating everything.
It also implements grounded_capability which is covered by a real test.
It also handles untestedstuff processing but nothing verifies that path.
EOF

cat > "$REPO/src/main.rs" <<'EOF'
fn real_symbol() {}
fn grounded_capability() {}
fn untestedstuff_handler() {}
EOF

cat > "$REPO/src/main_test.rs" <<'EOF'
fn test_grounded_capability() {}
EOF

python3 - "$INDEX_DIR/fixture-repo.db" "$REPO" <<'PYEOF'
import sqlite3, sys
db_path, repo_root = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db_path)
conn.executescript("""
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE files (id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, language TEXT NOT NULL, imports TEXT NOT NULL DEFAULT '[]');
CREATE TABLE symbols (id INTEGER PRIMARY KEY, file_id INTEGER NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL, start_line INTEGER NOT NULL, end_line INTEGER NOT NULL, doc TEXT, snippet TEXT NOT NULL DEFAULT '');
""")
conn.execute("INSERT INTO meta VALUES ('repo_root', ?)", (repo_root,))
conn.execute("INSERT INTO files VALUES (1, 'src/main.rs', 'rust', '[]')")
conn.execute("INSERT INTO files VALUES (2, 'src/main_test.rs', 'rust', '[]')")
conn.execute("INSERT INTO symbols VALUES (1, 1, 'real_symbol', 'fn', 1, 1, NULL, '')")
conn.execute("INSERT INTO symbols VALUES (2, 1, 'grounded_capability', 'fn', 2, 2, NULL, '')")
conn.execute("INSERT INTO symbols VALUES (3, 2, 'test_grounded_capability', 'fn', 1, 1, NULL, '')")
conn.execute("INSERT INTO symbols VALUES (4, 1, 'untestedstuff_handler', 'fn', 3, 3, NULL, '')")
conn.commit()
conn.close()
PYEOF

OUT="$(python3 scripts/dev/almanac-audit.py fixture-repo --index-dir "$INDEX_DIR" --json)"

echo "$OUT" | python3 -c "import json,sys; json.load(sys.stdin)" \
  || { echo "FAIL: tool did not emit valid JSON"; exit 1; }

VERDICT_FOR() {
  echo "$OUT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
needle = sys.argv[1]
for c in d['claims']:
    if needle.lower() in c['text'].lower():
        print(c['verdict'])
        break
else:
    print('MISSING')
" "$1"
}

v="$(VERDICT_FOR real_symbol)"
[ "$v" = "grounded" ] || { echo "FAIL: 'real_symbol' should be grounded (exists at path:line), got $v"; exit 1; }
echo "PASS: exact symbol reference grounded with citation"

v="$(VERDICT_FOR "enterprise platform")"
[ "$v" = "ungrounded" ] || { echo "FAIL: 'enterprise platform' capability claim should be ungrounded (no matching symbol/impl), got $v — this is the BEAST-MODE-class false claim from AC2"; exit 1; }
echo "PASS: unsupported capability claim ('enterprise platform') correctly flagged ungrounded"

v="$(VERDICT_FOR "grounded_capability which is covered")"
[ "$v" = "grounded" ] || { echo "FAIL: capability claim with matching impl AND test symbol should be grounded, got $v"; exit 1; }
echo "PASS: capability claim with impl + test evidence correctly grounded"

v="$(VERDICT_FOR "untestedstuff processing")"
[ "$v" = "unverifiable" ] || { echo "FAIL: capability claim with a matching impl symbol but NO test symbol should be unverifiable, got $v"; exit 1; }
echo "PASS: capability claim with impl but no test evidence correctly flagged unverifiable"

echo "PASS: fixture produced $(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['summary']['total'])") claims total"

# Unknown repo name — should report an error, not crash (exit 0, MISSION-045 signal-not-gate).
OUT2="$(python3 scripts/dev/almanac-audit.py definitely-not-a-real-repo --index-dir "$INDEX_DIR" --json)"
echo "$OUT2" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('error'), 'expected an error field for an unindexed repo'
" || { echo "FAIL: unindexed repo should report an error field, not crash"; exit 1; }
echo "PASS: unindexed repo name reports a clean error instead of crashing"
