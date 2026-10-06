#!/usr/bin/env bash
# test-jeff-bus-outbound.sh — META-1029: operator-addressed ambient events land
# in chump_web_messages (idempotently); unrelated kinds are ignored.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
command -v python3 >/dev/null || { echo "SKIP: python3"; exit 0; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
DB="$W/s/chump_memory.db"; AMB="$W/ambient.jsonl"
cat > "$AMB" <<'J'
{"ts":"2026-09-25T10:00:00Z","kind":"operator_page","severity":"block","message":"merge queue wedged","gap_id":"FOO-1"}
{"ts":"2026-09-25T10:01:00Z","kind":"heartbeat","message":"noise"}
{"ts":"2026-09-25T10:02:00Z","kind":"operator_decision_needed","summary":"needs sign-off","priority":"P1","pr_number":42}
J
run() { CHUMP_MEMORY_DB_PATH="$DB" CHUMP_AMBIENT_PATH="$AMB" python3 "$REPO_ROOT/scripts/ops/jeff-bus-outbound.py"; }
fail=0
sqlite3() { python3 -c "import sqlite3,sys; [print(r[0]) for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2])]" "$1" "$2"; }
run >/dev/null || { echo "FAIL: exit"; exit 1; }
n=$(sqlite3 "$DB" "SELECT COUNT(*) FROM chump_web_messages WHERE session_id='fleet-to-operator' AND role='assistant';")
[ "$n" = 2 ] && echo "ok: 2 operator messages mirrored" || { echo "FAIL: expected 2, got $n"; fail=1; }
sqlite3 "$DB" "SELECT content FROM chump_web_messages ORDER BY id LIMIT 1;" | grep -q "merge queue wedged" && echo "ok: content rendered" || { echo "FAIL: content"; fail=1; }
run >/dev/null
n=$(sqlite3 "$DB" "SELECT COUNT(*) FROM chump_web_messages;")
[ "$n" = 2 ] && echo "ok: idempotent" || { echo "FAIL: rerun gave $n"; fail=1; }
echo '{"ts":"2026-09-25T10:03:00Z","kind":"operator_recall","reason":"trunk red"}' >> "$AMB"
run >/dev/null
n=$(sqlite3 "$DB" "SELECT COUNT(*) FROM chump_web_messages;")
[ "$n" = 3 ] && echo "ok: only delta appended" || { echo "FAIL: delta gave $n"; fail=1; }
exit $fail
