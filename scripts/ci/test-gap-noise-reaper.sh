#!/usr/bin/env bash
# RESILIENT-111 regression test for scripts/ops/gap-noise-reaper.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
DB="$T/state.db"; CACHE="$T/cache.db"
sqlite3 "$DB" "CREATE TABLE gaps(id TEXT, title TEXT, description TEXT, status TEXT);
INSERT INTO gaps VALUES('N-1','PR #101 failing CI','','open');
INSERT INTO gaps VALUES('N-2','PR #102 failing CI','','open');
INSERT INTO gaps VALUES('N-3','PR #103 failing CI','','open');
INSERT INTO gaps VALUES('N-4','EFFECTIVE: Wire foo','this is already wired','open');
INSERT INTO gaps VALUES('N-5','EFFECTIVE: Wire bar','not yet','open');
INSERT INTO gaps VALUES('N-6','tidy worktree cleanup','','open');
INSERT INTO gaps VALUES('N-7','real work','','open');"
sqlite3 "$CACHE" "CREATE TABLE pr_state(number INTEGER PRIMARY KEY, merged_at TEXT, raw_payload_json TEXT);
INSERT INTO pr_state VALUES(101,'2026-01-01','{\"state\":\"closed\"}');
INSERT INTO pr_state VALUES(102,NULL,'{\"state\":\"open\"}');"
# PR 103 is a cache miss and gh fails -> UNKNOWN -> skipped
printf '#!/usr/bin/env bash\necho "$@" >> "%s/closed.txt"\n' "$T" > "$T/bin/chump"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/gh"
chmod +x "$T/bin/chump" "$T/bin/gh"
run() { PATH="$T/bin:$PATH" CHUMP_STATE_DB="$DB" CHUMP_NOISE_CACHE_DB="$CACHE" \
  CHUMP_NOISE_REAPER_LOG="$T/log.jsonl" CHUMP_NOISE_REAPER_LOCK="$T/lock" bash "$ROOT/scripts/ops/gap-noise-reaper.sh" "$@"; }
run --dry-run | grep -q 'closed=3' || { echo "FAIL dry-run count"; exit 1; }
[[ ! -e "$T/closed.txt" ]] || { echo "FAIL dry-run wrote"; exit 1; }
run | grep -q 'closed=3' || { echo "FAIL real count"; exit 1; }
for g in N-1 N-4 N-6; do grep -q "gap close $g --reason superseded" "$T/closed.txt" || { echo "FAIL $g not closed"; exit 1; }; done
for g in N-2 N-3 N-5 N-7; do ! grep -q "$g " "$T/closed.txt" || { echo "FAIL $g wrongly closed"; exit 1; }; done
[[ "$(wc -l < "$T/log.jsonl")" -eq 3 ]] || { echo "FAIL log"; exit 1; }
run --limit 1 | grep -q 'closed=1' || { echo "FAIL limit"; exit 1; }
echo "PASS test-gap-noise-reaper"
