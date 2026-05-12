#!/usr/bin/env bash
# credential-lifecycle.sh — INFRA-879
#
# Checks the age of API credentials (ANTHROPIC_API_KEY, GH_TOKEN) against
# a rotation policy and emits kind=credential_rotation_due alerts.
#
# Credential metadata is stored in CHUMP_CRED_META_PATH
# (default: ~/.chump/credential-meta.json) as:
#   {
#     "ANTHROPIC_API_KEY": {"creation_ts": "2026-01-01T00:00:00Z"},
#     "GH_TOKEN": {"creation_ts": "2026-02-01T00:00:00Z"}
#   }
#
# Usage:
#   credential-lifecycle.sh [--dry-run] [--rotate-dry-run] [--register CRED_NAME]
#                           [--max-age-days N] [--json]
#
# Environment:
#   CHUMP_CRED_META_PATH    Path to credential metadata JSON
#   CHUMP_CRED_MAX_AGE_DAYS Max credential age in days (default: 90)
#   CHUMP_AMBIENT_LOG       Path to ambient.jsonl
#   REPO_ROOT               Repo root

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
META_PATH="${CHUMP_CRED_META_PATH:-$HOME/.chump/credential-meta.json}"
MAX_AGE_DAYS="${CHUMP_CRED_MAX_AGE_DAYS:-90}"
DRY_RUN=0
JSON_OUT=0
REGISTER_CRED=""
ALERTS=0

# Credentials to check (space-separated list of env var names)
CRED_NAMES="ANTHROPIC_API_KEY GH_TOKEN GITHUB_TOKEN"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|--rotate-dry-run) DRY_RUN=1; shift ;;
        --register)    REGISTER_CRED="$2"; shift 2 ;;
        --max-age-days) MAX_AGE_DAYS="$2"; shift 2 ;;
        --json)        JSON_OUT=1; shift ;;
        -h|--help)
            echo "Usage: credential-lifecycle.sh [--dry-run] [--rotate-dry-run] [--register CRED] [--max-age-days N] [--json]"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Helpers ────────────────────────────────────────────────────────────────────

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_age_days() {
    local creation_ts="$1"
    python3 -c "
from datetime import datetime, timezone
try:
    created = datetime.fromisoformat('$creation_ts'.replace('Z','+00:00'))
    now = datetime.now(timezone.utc)
    print((now - created).days)
except Exception:
    print(0)
" 2>/dev/null || echo "0"
}

_emit_alert() {
    local cred_name="$1" age_days="$2"
    local ts ev
    ts="$(_ts)"
    ev=$(printf '{"ts":"%s","kind":"credential_rotation_due","cred_name":"%s","age_days":%d,"max_age_days":%d}' \
        "$ts" "$cred_name" "$age_days" "$MAX_AGE_DAYS")
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] would emit: $ev" >&2
    else
        mkdir -p "$(dirname "$AMBIENT")" 2>/dev/null || true
        printf '%s\n' "$ev" >> "$AMBIENT" 2>/dev/null || true
    fi
}

# ── Load metadata ─────────────────────────────────────────────────────────────
_meta='{}'
if [[ -f "$META_PATH" ]]; then
    _meta=$(cat "$META_PATH" 2>/dev/null || echo '{}')
fi

# ── Register a credential (record creation timestamp) ─────────────────────────
if [[ -n "$REGISTER_CRED" ]]; then
    ts="$(_ts)"
    mkdir -p "$(dirname "$META_PATH")" 2>/dev/null || true
    _new=$(python3 - <<PYEOF
import json, sys
meta = json.loads('''$_meta''')
meta['$REGISTER_CRED'] = {'creation_ts': '$ts'}
print(json.dumps(meta, indent=2))
PYEOF
)
    printf '%s\n' "$_new" > "$META_PATH"
    echo "[credential-lifecycle] Registered $REGISTER_CRED creation_ts=$ts"
    exit 0
fi

# ── Check each credential ─────────────────────────────────────────────────────
_report_lines=""

for cred_name in $CRED_NAMES; do
    # Check if credential is present in environment
    env_val="${!cred_name:-}"
    if [[ -z "$env_val" ]]; then
        continue  # Skip credentials not configured
    fi

    # Look up creation_ts in metadata via python3
    creation_ts=$(python3 -c "
import json
try:
    meta = json.loads('''$_meta''')
    entry = meta.get('$cred_name', {})
    print(entry.get('creation_ts', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")

    if [[ -z "$creation_ts" ]]; then
        echo "  $cred_name: present but no creation_ts in $META_PATH"
        echo "    → Register with: credential-lifecycle.sh --register $cred_name"
        _report_lines="${_report_lines}${cred_name}|present|unknown|unknown|no_metadata\n"
        continue
    fi

    age_days=$(_age_days "$creation_ts")
    if (( age_days > MAX_AGE_DAYS )); then
        ALERTS=$((ALERTS+1))
        _emit_alert "$cred_name" "$age_days"
        echo "  $cred_name: age=${age_days}d > max=${MAX_AGE_DAYS}d ← ROTATION DUE"
        _report_lines="${_report_lines}${cred_name}|present|${creation_ts}|${age_days}|rotation_due\n"
    else
        remaining=$(( MAX_AGE_DAYS - age_days ))
        echo "  $cred_name: age=${age_days}d, ${remaining}d until rotation (max=${MAX_AGE_DAYS}d)"
        _report_lines="${_report_lines}${cred_name}|present|${creation_ts}|${age_days}|ok\n"
    fi
done

# ── JSON output ───────────────────────────────────────────────────────────────
if [[ "$JSON_OUT" -eq 1 ]]; then
    python3 - <<PYEOF
import json
report_raw = """$_report_lines"""
rows = []
for line in report_raw.strip().split('\\n'):
    if not line.strip():
        continue
    parts = line.split('|')
    if len(parts) >= 5:
        rows.append({
            'cred_name': parts[0],
            'presence': parts[1],
            'creation_ts': parts[2],
            'age_days': parts[3],
            'status': parts[4],
        })
print(json.dumps({'credentials': rows, 'max_age_days': $MAX_AGE_DAYS, 'alerts': $ALERTS}, indent=2))
PYEOF
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ "$ALERTS" -gt 0 ]]; then
    echo "  $ALERTS credential(s) due for rotation — rotate and re-register with --register"
    exit 1
else
    echo "  All credentials within rotation policy."
    exit 0
fi
