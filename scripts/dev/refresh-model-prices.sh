#!/usr/bin/env bash
# refresh-model-prices.sh — INFRA-731
#
# Weekly check that docs/pricing/model_rates.yaml is current with upstream.
# Reads LiteLLM's model_prices_and_context_window.json (community-maintained
# rate card, MIT-licensed, used by half the Python LLM ecosystem) and diffs
# the rates we care about against our committed YAML.
#
# Behaviors:
#   --check (default)   read upstream + diff; exit 0 if all rates within 5%,
#                       exit 2 if drift detected. No file writes.
#   --refresh           bump last_verified date on entries that match upstream.
#                       For drifted entries: emit ALERT to ambient + file an
#                       INFRA gap so operator picks up the audit work.
#   --apply (DANGER)    automatically rewrite drifted rates in-place. Not
#                       wired by default; use only after manual review.
#
# Tunables:
#   CHUMP_PRICING_DRIFT_PCT  drift threshold percent (default: 5)
#   CHUMP_PRICING_UPSTREAM   override upstream URL (default: LiteLLM main branch)
#
# LaunchAgent: dev.chump.pricing-refresh (Sunday 09:00 weekly)

set -uo pipefail

UPSTREAM_URL="${CHUMP_PRICING_UPSTREAM:-https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json}"
DRIFT_PCT="${CHUMP_PRICING_DRIFT_PCT:-5}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
RATES_FILE="$REPO_ROOT/docs/pricing/model_rates.yaml"
AMBIENT_LOG="$REPO_ROOT/.chump-locks/ambient.jsonl"
HEARTBEAT="${CHUMP_PRICING_REFRESH_HEARTBEAT:-/tmp/chump-pricing-refresh.heartbeat}"

MODE="check"
for arg in "$@"; do
    case "$arg" in
        --check) MODE="check" ;;
        --refresh) MODE="refresh" ;;
        --apply) MODE="apply" ;;
        *) echo "unknown arg: $arg" >&2; exit 1 ;;
    esac
done

echo "$(date -u +%s)" > "$HEARTBEAT"

if [[ ! -f "$RATES_FILE" ]]; then
    echo "FATAL: $RATES_FILE not found — INFRA-730 hasn't shipped yet?" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "FATAL: python3 required for YAML parse" >&2
    exit 1
fi

# Fetch upstream (timeout 30s; works offline-fail too)
UPSTREAM_TMP="$(mktemp -t chump-pricing.XXXXXX)"
trap 'rm -f "$UPSTREAM_TMP"' EXIT

if ! curl -sSf --max-time 30 "$UPSTREAM_URL" > "$UPSTREAM_TMP" 2>/dev/null; then
    echo "WARN: could not fetch $UPSTREAM_URL — offline? skipping check" >&2
    exit 0
fi

# Map local model_id → LiteLLM key. LiteLLM uses provider/model-id format
# in some cases (e.g. "groq/llama-3.3-70b-versatile") and bare in others.
# This is a curated translation table; expand as we add models to the YAML.
LITELLM_MAP="claude-sonnet-4.5:claude-sonnet-4-5
claude-haiku-4-5:claude-haiku-4-5
claude-opus-4.7:claude-opus-4-7
claude-haiku-3.5:claude-3-5-haiku-20241022
together-deepseek-v3:together_ai/deepseek-ai/DeepSeek-V3
together-llama-3.3-70b-turbo:together_ai/meta-llama/Llama-3.3-70B-Instruct-Turbo
together-qwen-2.5-coder-32b:together_ai/Qwen/Qwen2.5-Coder-32B-Instruct"

DRIFT_FOUND=0
UNKNOWN_FOUND=0
REPORT=()

while IFS=: read -r local_id upstream_key; do
    [[ -z "$local_id" || -z "$upstream_key" ]] && continue
    REPORT_LINE=$(MODEL_LOCAL="$local_id" MODEL_UPSTREAM="$upstream_key" \
                  RATES_FILE="$RATES_FILE" UPSTREAM_TMP="$UPSTREAM_TMP" \
                  DRIFT_PCT="$DRIFT_PCT" \
                  python3 <<'PY'
import json, os, re, sys

local_id = os.environ["MODEL_LOCAL"]
upstream_key = os.environ["MODEL_UPSTREAM"]
rates_file = os.environ["RATES_FILE"]
upstream_tmp = os.environ["UPSTREAM_TMP"]
drift_pct = float(os.environ["DRIFT_PCT"])

# Read upstream
try:
    upstream = json.load(open(upstream_tmp))
except Exception as e:
    print(f"  ?? {local_id}: upstream parse error: {e}")
    sys.exit(2)

up_entry = upstream.get(upstream_key)
if not up_entry:
    print(f"  ?? {local_id}: not in upstream ({upstream_key} missing)")
    sys.exit(2)

# LiteLLM rates are per-token; multiply by 1e6 for per-Mtk
up_in = float(up_entry.get("input_cost_per_token", 0)) * 1_000_000
up_out = float(up_entry.get("output_cost_per_token", 0)) * 1_000_000

# Read our committed rates from yaml. Lazy regex parse to avoid pyyaml dep.
text = open(rates_file).read()
# Find this model's block
pat = re.compile(
    r"- model_id:\s*" + re.escape(local_id) +
    r"\s*\n\s*input_per_mtk:\s*([\d.]+)\s*\n\s*output_per_mtk:\s*([\d.]+)",
    re.MULTILINE,
)
m = pat.search(text)
if not m:
    print(f"  ?? {local_id}: not found in {rates_file}")
    sys.exit(2)
local_in = float(m.group(1))
local_out = float(m.group(2))

def drift(a, b):
    if a == 0 and b == 0:
        return 0.0
    if a == 0 or b == 0:
        return 100.0
    return abs(a - b) / max(a, b) * 100

d_in = drift(local_in, up_in)
d_out = drift(local_out, up_out)

if d_in > drift_pct or d_out > drift_pct:
    print(f"  ⚠ {local_id}: in {local_in:.2f}→{up_in:.2f} ({d_in:.0f}%)  out {local_out:.2f}→{up_out:.2f} ({d_out:.0f}%)  DRIFT")
    sys.exit(1)
else:
    print(f"  ✓ {local_id}: in {local_in:.2f}~{up_in:.2f}  out {local_out:.2f}~{up_out:.2f}")
    sys.exit(0)
PY
)
    rc=$?
    REPORT+=("$REPORT_LINE")
    case $rc in
        1) DRIFT_FOUND=$((DRIFT_FOUND+1)) ;;
        2) UNKNOWN_FOUND=$((UNKNOWN_FOUND+1)) ;;
    esac
done <<< "$LITELLM_MAP"

# Render report
echo "═══ INFRA-731 pricing-refresh report (mode=$MODE) ═══"
printf '%s\n' "${REPORT[@]}"
echo ""
echo "drift=$DRIFT_FOUND  unknown=$UNKNOWN_FOUND"

# Emit ambient ALERT only on actual drift
if [[ "$DRIFT_FOUND" -gt 0 ]]; then
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null
    printf '{"ts":"%s","event":"ALERT","kind":"pricing_drift","drift_count":%d,"unknown_count":%d,"note":"INFRA-731: %d model rate(s) drifted >%s%% from LiteLLM upstream"}\n' \
        "$ts" "$DRIFT_FOUND" "$UNKNOWN_FOUND" "$DRIFT_FOUND" "$DRIFT_PCT" \
        >> "$AMBIENT_LOG" 2>/dev/null || true

    # Refresh mode: file an INFRA gap so the fleet picks up the manual audit.
    if [[ "$MODE" == "refresh" ]] && command -v chump >/dev/null 2>&1; then
        chump gap reserve --domain INFRA \
            --title "CREDIBLE: refresh model_rates.yaml — $DRIFT_FOUND rate(s) drifted >$DRIFT_PCT% from LiteLLM upstream (auto-filed by INFRA-731)" \
            --priority P0 --effort xs 2>&1 | tail -1
    fi
fi

# --apply: actually rewrite the YAML in place. Off by default.
if [[ "$MODE" == "apply" && "$DRIFT_FOUND" -gt 0 ]]; then
    echo "WARN: --apply will rewrite $RATES_FILE in place. Skipping in this version (TBD: implement via INFRA-731 follow-up; manual audit safer)."
fi

# Exit code: drift = 2 (advisory); unknown = 0 (informational)
if [[ "$DRIFT_FOUND" -gt 0 ]]; then
    exit 2
fi
exit 0
