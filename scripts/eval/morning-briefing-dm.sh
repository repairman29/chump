#!/usr/bin/env bash
# Fetch GET /api/briefing and send a short plain-text summary as a Discord DM via chump --notify.
# Run from the Chump repo (Mac) after the web server is up; schedule with launchd/cron if desired.
#
# Requires: .env with CHUMP_WEB_TOKEN, DISCORD_TOKEN, CHUMP_READY_DM_USER_ID; jq; chump binary built.
# Optional: CHUMP_WEB_HOST (default 127.0.0.1), CHUMP_WEB_PORT (default 3000).

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

HOST="${CHUMP_WEB_HOST:-127.0.0.1}"
PORT="${CHUMP_WEB_PORT:-3000}"
TOKEN="${CHUMP_WEB_TOKEN:-}"
BIN="$ROOT/target/release/chump"
[[ -x "$BIN" ]] || BIN="$ROOT/target/debug/chump"

if [[ -z "$TOKEN" ]]; then
  echo "morning-briefing-dm: set CHUMP_WEB_TOKEN in .env" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "morning-briefing-dm: jq is required" >&2
  exit 1
fi

JSON=$(curl -sf -H "Authorization: Bearer $TOKEN" "http://${HOST}:${PORT}/api/briefing") || {
  echo "morning-briefing-dm: curl failed (is web server on ${HOST}:${PORT}?)" >&2
  exit 1
}

MSG=$(echo "$JSON" | jq -r '
  (
    ["Morning briefing " + .date]
    + [ .sections[]?
        | select(.title=="Tasks")
        | .items[]?
        | .assignee as $a
        | .tasks[]?
        | "• [\($a)] " + .title + " (" + .status + ")"
      ]
    + [ .sections[]?
        | select(.title=="Recent episodes")
        | .items[0:5][]?
        | "• " + (if (.summary | length) > 120 then .summary[0:120] + "…" else .summary end)
      ]
    + [ .sections[]?
        | select(.title=="Watch alerts")
        | .items[]?
        | "⚠ " + .list + ": " + (if (.line | length) > 150 then .line[0:150] + "…" else .line end)
      ]
    + [ .sections[]?
        | select(.title=="Watchlists")
        | .items[]?
        | "○ " + .list + ": " + (.count | tostring) + " items"
      ]
  ) | join("\n")
')

if [[ -z "${MSG//[$'\n\r']/}" ]]; then
  MSG="Morning briefing $(echo "$JSON" | jq -r .date)

(no sections in JSON — check task DB / brain path)"
fi

# Discord hard limit ~2000 chars
MSG="${MSG:0:1900}"

echo "$MSG" | "$BIN" --notify
echo "morning-briefing-dm: sent (${#MSG} chars)"
