#!/usr/bin/env bash
# META-1038: the SessionStart AGENT_START_HERE pointer prints once per session,
# does not duplicate on repeated hook runs, and degrades silently when the doc is
# absent. Also asserts it is wired first in .claude/settings.json.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/scripts/setup/session-start-agent-pointer.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { echo "  ok: $1"; pass=$((pass+1)); }; bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

mkdir -p "$T/repo/docs"
run() { env -u CHUMP_SESSION_ID -u CLAUDE_SESSION_ID CHUMP_REPO="$T/repo" "$@" bash "$HOOK" 2>&1; }

# 1. Doc absent: silent, exit 0, no marker.
out="$(run env)"; rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "doc absent: no output, exit 0" || bad "absent-doc output/rc: rc=$rc out=$out"
[[ ! -d "$T/repo/.chump-locks" ]] && ok "doc absent: no marker written" || bad "marker created without a doc"

# 2. Doc present: pointer printed, names the doc.
echo "# start" > "$T/repo/docs/AGENT_START_HERE.md"
out="$(run env CLAUDE_SESSION_ID=sess-1)"
grep -q 'docs/AGENT_START_HERE.md' <<<"$out" && [[ "$(wc -l <<<"$out" | tr -d ' ')" == "1" ]] && ok "doc present: one-line pointer to docs/AGENT_START_HERE.md" || bad "pointer: $out"

# 3. Idempotent: same session, repeated runs print nothing more.
out="$(run env CLAUDE_SESSION_ID=sess-1; run env CLAUDE_SESSION_ID=sess-1)"
[[ -z "$out" ]] && ok "same session: repeated hook runs do not duplicate" || bad "duplicated: $out"

# 4. A different session still gets it.
out="$(run env CLAUDE_SESSION_ID=sess-2)"
grep -q 'START HERE' <<<"$out" && ok "new session gets the pointer" || bad "new session missed it"

# 5. No session id: printed once, then suppressed within the TTL.
rm -rf "$T/repo/.chump-locks"
first="$(run env)"; second="$(run env)"
grep -q 'START HERE' <<<"$first" && [[ -z "$second" ]] && ok "no session id: once, then suppressed within TTL" || bad "anon dedupe: first=[$first] second=[$second]"

# 6. Root-level doc fallback and the disable switch.
rm -rf "$T/repo/.chump-locks"; mv "$T/repo/docs/AGENT_START_HERE.md" "$T/repo/AGENT_START_HERE.md"
out="$(run env CLAUDE_SESSION_ID=sess-3)"
grep -q ' AGENT_START_HERE.md' <<<"$out" && ok "falls back to ./AGENT_START_HERE.md" || bad "root fallback: $out"
out="$(run env CLAUDE_SESSION_ID=sess-4 CHUMP_AGENT_POINTER_DISABLE=1)"
[[ -z "$out" ]] && ok "CHUMP_AGENT_POINTER_DISABLE=1 silences it" || bad "disable ignored"

# 7. Wired first in SessionStart (near the top of session output).
python3 - "$REPO_ROOT/.claude/settings.json" <<'PY' && ok "wired as the first SessionStart hook" || bad "not first in SessionStart"
import json, sys
cmds = [h["command"] for g in json.load(open(sys.argv[1]))["hooks"]["SessionStart"] for h in g["hooks"]]
assert "session-start-agent-pointer.sh" in cmds[0], cmds[0]
PY

echo "=== session-start agent pointer: $pass passed, $fail failed ==="
[[ $fail -eq 0 ]]
