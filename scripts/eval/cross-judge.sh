#!/usr/bin/env bash
# cross-judge.sh — EVAL-097 — generate INFRA-079-compliant cross-judge JSONL
# using two cascade slots from different model families.
#
# Background: docs/RESEARCH_INTEGRITY.md ("any claim that depends on judge
# labels must include a cross-judge audit on the same JSONL before it is
# stamped as a result") and INFRA-079 (pre-commit guard) require ≥2 distinct
# judge families when closing EVAL-* or RESEARCH-* gaps. The enforcement
# guard (`scripts/ci/check-cross-judge.py`) already exists but had no
# production-tool to *generate* the audit JSONL — operators had to manually
# run AB harnesses with multiple judges configured. This script is that
# tool.
#
# What it does:
#   1. Loads cascade-slot config from .env (CHUMP_PROVIDER_*).
#   2. Sends the same judging prompt to slot A (Llama family by default) and
#      slot B (Qwen family by default), both via OpenAI-compatible HTTP.
#   3. Writes a JSONL file with one row per judge containing `judge_model`,
#      `verdict`, `latency_ms`, and the raw response. The file shape matches
#      what `check-cross-judge.py` expects so the resulting path can be
#      pasted directly into a gap as `cross_judge_audit: <path>`.
#
# Usage:
#   scripts/eval/cross-judge.sh \
#       --gap EVAL-097 \
#       --task "Is the result statistically significant given sample size 20?" \
#       --criteria "Reply YES or NO with one-sentence justification."
#
# Optional overrides:
#   --out <path>          where to write JSONL (default logs/ab/cross-judge-<GAP>-<ts>.jsonl)
#   --family-a <slot>     cascade slot name for judge A (default: groq)
#   --family-b <slot>     cascade slot name for judge B (default: hyperbolic)
#   --max-tokens N        per-call cap (default 256)
#
# Slot families today (per .env defaults):
#   groq        → llama-3.3-70b-versatile  (family: meta/Llama)
#   hyperbolic  → Qwen3-Coder-480B          (family: alibaba/Qwen)
#   openrouter  → qwen/qwen3-coder:free     (family: alibaba/Qwen)
#   gemini      → gemini-2.5-flash          (family: google/Gemini, 16 RPD!)
#   nvidia      → meta/llama-3.3-70b-instruct (family: meta/Llama)
#   github      → meta/Llama-3.3-70B-Instruct (family: meta/Llama)
#
# Pick A and B from *different* families — `check-cross-judge.py`'s family
# classifier rejects same-family pairs.
#
# Bypass: this script doesn't touch the gap registry; the operator decides
# whether to paste the resulting path into the gap YAML.

set -euo pipefail

# ── Default arg values ──────────────────────────────────────────────────────
GAP=""
TASK=""
CRITERIA=""
OUT=""
FAMILY_A="groq"
FAMILY_B="hyperbolic"
MAX_TOKENS=256

# ── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gap)        GAP="$2"; shift 2 ;;
        --task)       TASK="$2"; shift 2 ;;
        --criteria)   CRITERIA="$2"; shift 2 ;;
        --out)        OUT="$2"; shift 2 ;;
        --family-a)   FAMILY_A="$2"; shift 2 ;;
        --family-b)   FAMILY_B="$2"; shift 2 ;;
        --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
        --help|-h)
            sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "unknown arg: $1" >&2
            echo "see --help" >&2
            exit 2
            ;;
    esac
done

[[ -n "$GAP"      ]] || { echo "ERROR: --gap required (e.g. --gap EVAL-097)"      >&2; exit 2; }
[[ -n "$TASK"     ]] || { echo "ERROR: --task required (judging prompt text)"     >&2; exit 2; }
[[ -n "$CRITERIA" ]] || { echo "ERROR: --criteria required (judge instructions)"  >&2; exit 2; }

command -v jq    >/dev/null || { echo "ERROR: jq not on PATH"   >&2; exit 1; }
command -v curl  >/dev/null || { echo "ERROR: curl not on PATH" >&2; exit 1; }

# ── Load .env so CHUMP_PROVIDER_* slot config is available ──────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# .env lives in the *main* repo root (gitignored). When running from a
# linked worktree, --show-toplevel returns the worktree path which has no
# .env. Walk up via --git-common-dir's parent to find the canonical .env.
MAIN_REPO_ROOT="$REPO_ROOT"
if _common_dir=$(git rev-parse --git-common-dir 2>/dev/null); then
    if [[ "$_common_dir" != ".git" && "$_common_dir" != "$REPO_ROOT/.git" ]]; then
        MAIN_REPO_ROOT="$(cd "$_common_dir/.." && pwd)"
    fi
fi
for _env_path in "$REPO_ROOT/.env" "$MAIN_REPO_ROOT/.env"; do
    if [[ -f "$_env_path" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$_env_path"
        set +a
        break
    fi
done

# ── Resolve cascade slot config → (base, key, model) ────────────────────────
# Walks CHUMP_PROVIDER_1..10 looking for a slot whose NAME matches.
resolve_slot() {
    local target_name="$1"
    local i
    for i in $(seq 1 10); do
        # Use indirect expansion (ksh/bash 4-ish) to read CHUMP_PROVIDER_<i>_*.
        local name_var="CHUMP_PROVIDER_${i}_NAME"
        local base_var="CHUMP_PROVIDER_${i}_BASE"
        local key_var="CHUMP_PROVIDER_${i}_KEY"
        local model_var="CHUMP_PROVIDER_${i}_MODEL"
        local enabled_var="CHUMP_PROVIDER_${i}_ENABLED"
        if [[ "${!enabled_var:-}" != "1" ]]; then
            continue
        fi
        if [[ "${!name_var:-}" == "$target_name" ]]; then
            printf '%s\t%s\t%s' "${!base_var}" "${!key_var}" "${!model_var}"
            return 0
        fi
    done
    echo "ERROR: cascade slot '$target_name' not found or not enabled in .env" >&2
    echo "       (looked at CHUMP_PROVIDER_1..10 with NAME=$target_name and ENABLED=1)" >&2
    exit 1
}

# ── Build the unified prompt sent to each judge ─────────────────────────────
PROMPT="Task: ${TASK}

Criteria: ${CRITERIA}

Answer with the criteria followed by a one-sentence justification."

# ── Run one judge: fetch response + latency, build a JSONL row ──────────────
run_judge() {
    local family="$1"
    local slot_info base key model
    slot_info=$(resolve_slot "$family")
    base=$(echo "$slot_info" | cut -f1)
    key=$(echo "$slot_info" | cut -f2)
    model=$(echo "$slot_info" | cut -f3)

    local request_body raw t0 t1 latency_ms
    request_body=$(jq -n --arg m "$model" --arg p "$PROMPT" --argjson mt "$MAX_TOKENS" \
        '{model: $m, messages: [{role: "user", content: $p}], max_tokens: $mt}')
    t0=$(date +%s)
    raw=$(curl -sS --max-time 60 -X POST "$base/chat/completions" \
        -H "Authorization: Bearer $key" \
        -H "Content-Type: application/json" \
        -d "$request_body" 2>&1 || true)
    t1=$(date +%s)
    # Use second-resolution rather than nanoseconds — date +%s%N is GNU-only
    # and macOS's BSD date doesn't honor %N, leaving a literal "%N" in the
    # output that breaks arithmetic. Latency in seconds is fine for telemetry.
    latency_ms=$(( (t1 - t0) * 1000 ))

    local content
    content=$(printf '%s' "$raw" | jq -r '.choices[0].message.content // ""' 2>/dev/null || echo "")

    # Best-effort verdict extraction: first uppercase YES/NO/PASS/FAIL token.
    local verdict
    verdict=$(printf '%s' "$content" | grep -oE '\b(YES|NO|PASS|FAIL)\b' | head -1 || true)
    [[ -z "$verdict" ]] && verdict="UNCLEAR"

    # Emit one JSONL row. judge_model is the discriminator
    # check-cross-judge.py keys on for family classification.
    jq -nc \
        --arg gap        "$GAP" \
        --arg ts         "$(date -u +%FT%TZ)" \
        --arg judge_model "$model" \
        --arg slot       "$family" \
        --arg verdict    "$verdict" \
        --arg content    "$content" \
        --arg task       "$TASK" \
        --arg criteria   "$CRITERIA" \
        --argjson latency_ms "$latency_ms" \
        '{gap: $gap, ts: $ts, judge_model: $judge_model, slot: $slot,
          verdict: $verdict, content: $content, latency_ms: $latency_ms,
          task: $task, criteria: $criteria}'
}

# ── Output path ──────────────────────────────────────────────────────────────
TS=$(date -u +%Y%m%dT%H%M%SZ)
if [[ -z "$OUT" ]]; then
    OUT="$REPO_ROOT/logs/ab/cross-judge-${GAP}-${TS}.jsonl"
fi
mkdir -p "$(dirname "$OUT")"

echo "[cross-judge] gap=$GAP family-a=$FAMILY_A family-b=$FAMILY_B → $OUT" >&2

# ── Run both judges and append rows ─────────────────────────────────────────
{
    run_judge "$FAMILY_A"
    run_judge "$FAMILY_B"
} >> "$OUT"

# ── Summary on stderr ───────────────────────────────────────────────────────
echo "[cross-judge] wrote $(wc -l <"$OUT" | tr -d ' ') rows to $OUT" >&2
echo "" >&2
echo "Verdicts:" >&2
jq -r '"  " + .slot + " (" + .judge_model + "): " + .verdict + "  [" + (.latency_ms | tostring) + "ms]"' < "$OUT" >&2

# ── Print the path on stdout for paste-into-gap-yaml workflows ──────────────
echo "$OUT"
