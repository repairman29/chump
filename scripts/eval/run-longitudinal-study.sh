#!/usr/bin/env bash
# run-longitudinal-study.sh — COG-017 longitudinal study driver.
#
# Hypothesis: Chump's memory graph and counterfactual subsystems compound value
# across sessions. A cold-start (fresh DB per session) cannot see this effect.
# This script runs the same fixture twice:
#   persistent: one SQLite DB shared across all 5 sessions
#   cold:       fresh DB per session (baseline / control)
# Then compares per-session pass rates between the two conditions.
#
# Usage:
#   scripts/eval/run-longitudinal-study.sh
#   scripts/eval/run-longitudinal-study.sh --dry-run
#   scripts/eval/run-longitudinal-study.sh --model qwen3:8b --limit 10
#
# Env:
#   CHUMP_MEMORY_DB_PATH        If set, Chump uses this SQLite DB. The persistent run
#                        sets this to a shared file; cold runs use a fresh file
#                        per session. NOTE: wire up CHUMP_MEMORY_DB_PATH in Chump if
#                        it is not yet supported — see src/main.rs or config.rs.
#   CHUMP_LONG_MODEL     default "qwen3:8b"
#   CHUMP_STUDY_LIMIT    default 50
#   OLLAMA_BASE          default http://127.0.0.1:11434
#   CHUMP_BIN            default ./target/release/chump
#   ANTHROPIC_API_KEY    If set, uses Claude as judge; else falls back to Ollama.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/.env" ]]; then
  set -a; source "$ROOT/.env"; set +a
fi

FIXTURE="${CHUMP_LONG_FIXTURE:-scripts/ab-harness/fixtures/longitudinal_tasks.json}"
MODEL="${CHUMP_LONG_MODEL:-qwen3:8b}"
LIMIT="${CHUMP_STUDY_LIMIT:-50}"
OLLAMA_BASE="${OLLAMA_BASE:-http://127.0.0.1:11434}"
CHUMP_BIN="${CHUMP_BIN:-./target/release/chump}"

JUDGE_CLAUDE_MODEL="${CHUMP_JUDGE_CLAUDE:-}"
JUDGE_OLLAMA_MODEL="${CHUMP_JUDGE_OLLAMA:-qwen2.5:14b}"
if [[ -z "$JUDGE_CLAUDE_MODEL" && -n "${ANTHROPIC_API_KEY:-}" ]]; then
  JUDGE_CLAUDE_MODEL="claude-sonnet-4-6"
fi

DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --model)   MODEL="$2"; shift 2 ;;
    --limit)   LIMIT="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -x "$CHUMP_BIN" ]]; then
  echo "ERROR: $CHUMP_BIN not executable. Build: cargo build --release" >&2; exit 2
fi
if [[ ! -f "$FIXTURE" ]]; then
  echo "ERROR: $FIXTURE not found" >&2; exit 2
fi
if ! curl -sf --connect-timeout 3 "$OLLAMA_BASE/api/tags" >/dev/null 2>&1; then
  echo "ERROR: ollama not reachable at $OLLAMA_BASE" >&2; exit 3
fi

OUT_DIR="$ROOT/logs/study"
mkdir -p "$OUT_DIR"
TS="$(date +%s)"
RESULTS_JSON="$OUT_DIR/longitudinal-${TS}.json"

JUDGE_DESC="${JUDGE_CLAUDE_MODEL:+claude:$JUDGE_CLAUDE_MODEL}"
JUDGE_DESC="${JUDGE_DESC:-ollama:$JUDGE_OLLAMA_MODEL}"

echo "[longitudinal] $(date -u +%H:%M:%S) start"
echo "[longitudinal] fixture=$FIXTURE  limit=$LIMIT  model=$MODEL"
echo "[longitudinal] judge=$JUDGE_DESC"
echo "[longitudinal] results → $RESULTS_JSON"
echo

run_pass() {
  local label="$1"   # "persistent" or "cold-sN"
  local db_path="$2" # path to SQLite DB file (fresh or shared)
  local tag="longitudinal-${label}-${MODEL//[:.]/-}"

  echo "[longitudinal] $(date -u +%H:%M:%S) running pass: $label (db=$db_path)" >&2

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] would run pass $label with CHUMP_MEMORY_DB_PATH=$db_path" >&2
    return 0
  fi

  local existing
  existing=$(ls "$ROOT/logs/ab/${tag}-"*.summary.json 2>/dev/null | head -1 || true)
  if [[ -n "$existing" ]]; then
    echo "  SKIP — $existing already exists (idempotent)" >&2
    echo "$existing"; return 0
  fi

  OPENAI_API_BASE="${OLLAMA_BASE}/v1" \
  OPENAI_API_KEY=ollama \
  OPENAI_MODEL="$MODEL" \
  CHUMP_OLLAMA_NUM_CTX=8192 \
  CHUMP_HOME="$ROOT" \
  CHUMP_REPO="$ROOT" \
  CHUMP_MEMORY_DB_PATH="$db_path" \
    scripts/ab-harness/run.sh \
      --fixture "$FIXTURE" \
      --flag CHUMP_LONGITUDINAL_SESSION \
      --tag "$tag" \
      --limit "$LIMIT" \
      --chump-bin "$CHUMP_BIN" >&2 || {
    echo "[longitudinal] FAIL — pass $label harness exited nonzero" >&2; return 1
  }

  local jsonl
  jsonl=$(ls -t "$ROOT/logs/ab/${tag}-"*.jsonl 2>/dev/null | head -1 || true)
  [[ -z "$jsonl" ]] && { echo "[longitudinal] FAIL — no jsonl for $label" >&2; return 1; }

  echo "[longitudinal] $(date -u +%H:%M:%S) scoring $label..." >&2
  if [[ -n "$JUDGE_CLAUDE_MODEL" ]]; then
    scripts/ab-harness/score.py "$jsonl" "$FIXTURE" --judge-claude "$JUDGE_CLAUDE_MODEL" >&2 || \
    scripts/ab-harness/score.py "$jsonl" "$FIXTURE" --judge "$JUDGE_OLLAMA_MODEL" >&2 || \
    scripts/ab-harness/score.py "$jsonl" "$FIXTURE" >&2 || return 1
  else
    scripts/ab-harness/score.py "$jsonl" "$FIXTURE" --judge "$JUDGE_OLLAMA_MODEL" >&2 || \
    scripts/ab-harness/score.py "$jsonl" "$FIXTURE" >&2 || return 1
  fi

  ls -t "$ROOT/logs/ab/${tag}-"*.summary.json 2>/dev/null | head -1 || true
}

# Persistent run: one DB for all 5 sessions (simulated via sequential task order).
PERSISTENT_DB="$OUT_DIR/longitudinal-persistent-${TS}.db"
SUMMARY_PERSISTENT=$(run_pass "persistent" "$PERSISTENT_DB")

# Cold-start baseline: fresh DB per session group (s1..s5).
# The harness runs all tasks sequentially; we approximate session isolation by
# running the full fixture five times with a fresh DB each time and filtering
# to one session category per run. Because the ab-harness run.sh does not yet
# support --category filtering, we run the full fixture with a fresh DB and
# rely on the fixture's session ordering. A future enhancement could add
# --category s1 .. s5 to run.sh and pass LIMIT=10 per session.
COLD_SUMMARIES=()
for sn in 1 2 3 4 5; do
  cold_db="$OUT_DIR/longitudinal-cold-s${sn}-${TS}.db"
  summary=$(run_pass "cold-s${sn}" "$cold_db")
  COLD_SUMMARIES+=("$summary")
done

[[ $DRY_RUN -eq 1 ]] && { echo "[dry-run] done"; exit 0; }

echo
echo "[longitudinal] $(date -u +%H:%M:%S) aggregating..."

python3 - <<PY
import json
from pathlib import Path

def load(path):
    if not path or not Path(path).exists():
        return {}
    return json.loads(Path(path).read_text())

def rate(summary):
    bm = summary.get("by_mode") or {}
    m = bm.get("A") or bm.get("B") or {}
    return m.get("rate")

def by_cat(summary):
    return summary.get("by_category") or {}

persistent = load("$SUMMARY_PERSISTENT")

cold_paths = [${COLD_SUMMARIES[@]+"${COLD_SUMMARIES[@]}"}]
cold_paths_py = """${COLD_SUMMARIES[*]:-}""".split()
colds = [load(p) for p in cold_paths_py]

per_session_persistent = by_cat(persistent)
per_session_cold = {}
for i, c in enumerate(colds):
    session_key = f"session{i+1}"
    cats = by_cat(c)
    per_session_cold[session_key] = cats.get(session_key, cats.get("A", {}))

results = {
    "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "model": "$MODEL",
    "fixture": "$FIXTURE",
    "limit": $LIMIT,
    "persistent_db_rate": rate(persistent),
    "cold_db_rates": [rate(c) for c in colds],
    "per_session": {
        "persistent": {k: v.get("rate") for k, v in per_session_persistent.items()},
        "cold": {k: v.get("rate") for k, v in per_session_cold.items()},
    },
    "hypothesis": "persistent DB should show improving pass rate across sessions vs flat cold baseline",
}

Path("$RESULTS_JSON").write_text(json.dumps(results, indent=2))

print(f"  wrote → $RESULTS_JSON")
print()
print(f"  Persistent DB overall pass rate: {results['persistent_db_rate']}")
cold_avg = [r for r in results['cold_db_rates'] if r is not None]
avg = sum(cold_avg)/len(cold_avg) if cold_avg else None
print(f"  Cold-start avg pass rate:        {avg}")
print()
print("  Per-session breakdown:")
print(f"  {'Session':<12} {'Persistent':>10} {'Cold':>10} {'Delta':>8}")
for sn in range(1, 6):
    key = f"session{sn}"
    p = (results['per_session']['persistent'] or {}).get(key)
    c = (results['per_session']['cold'] or {}).get(key)
    delta = round(p - c, 3) if (p is not None and c is not None) else None
    def fmt(v): return f"{v*100:.1f}%" if v is not None else "—"
    def fmtd(v): return f"{v*100:+.1f}pp" if v is not None else "—"
    print(f"  {key:<12} {fmt(p):>10} {fmt(c):>10} {fmtd(delta):>8}")
PY

echo
echo "[longitudinal] $(date -u +%H:%M:%S) done."
