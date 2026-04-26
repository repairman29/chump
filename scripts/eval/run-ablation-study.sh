#!/usr/bin/env bash
# run-ablation-study.sh — 4-condition partial ablation using existing env flags.
#
# Conditions:
#   A: all-on     (CHUMP_CONSCIOUSNESS_ENABLED=1, CHUMP_NEUROMOD_ENABLED=1)
#   B: all-off    (CHUMP_CONSCIOUSNESS_ENABLED=0, CHUMP_NEUROMOD_ENABLED=0)
#   C: framework-on, neuromod-off  (CHUMP_CONSCIOUSNESS_ENABLED=1, CHUMP_NEUROMOD_ENABLED=0)
#   D: framework-off, neuromod-on  (CHUMP_CONSCIOUSNESS_ENABLED=0, CHUMP_NEUROMOD_ENABLED=1)
#
# This isolates the neuromodulation contribution from the rest of the framework.
# Compare A vs B = full framework effect
# Compare A vs C = neuromod contribution within framework
# Compare C vs B = framework-without-neuromod effect
# Compare D vs B = neuromod-alone effect
#
# Usage:
#   scripts/eval/run-ablation-study.sh
#   scripts/eval/run-ablation-study.sh --model qwen2.5:14b --limit 20
#   scripts/eval/run-ablation-study.sh --dry-run
#
# Env:
#   CHUMP_ABLATION_MODEL   default "qwen3:8b"
#   CHUMP_STUDY_LIMIT      default 20
#   OLLAMA_BASE            default http://127.0.0.1:11434
#   CHUMP_BIN              default ./target/release/chump

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/.env" ]]; then
  set -a; source "$ROOT/.env"; set +a
fi

MODEL="${CHUMP_ABLATION_MODEL:-qwen3:8b}"
LIMIT="${CHUMP_STUDY_LIMIT:-20}"
FIXTURE="${CHUMP_ABLATION_FIXTURE:-scripts/ab-harness/fixtures/neuromod_tasks.json}"
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
    --fixture) FIXTURE="$2"; shift 2 ;;
    --model)   MODEL="$2"; shift 2 ;;
    --limit)   LIMIT="$2"; shift 2 ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
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
RESULTS_JSON="$OUT_DIR/ablation-${TS}.json"

if [[ -n "$JUDGE_CLAUDE_MODEL" ]]; then
  JUDGE_DESC="claude:$JUDGE_CLAUDE_MODEL"
else
  JUDGE_DESC="ollama:$JUDGE_OLLAMA_MODEL"
fi

echo "[ablation] $(date -u +%H:%M:%S) start"
echo "[ablation] model=$MODEL  fixture=$(basename $FIXTURE)  limit=$LIMIT"
echo "[ablation] judge=$JUDGE_DESC"
echo "[ablation] results → $RESULTS_JSON"
echo
echo "[ablation] Conditions:"
echo "  A: all-on    (CONSCIOUSNESS=1, NEUROMOD=1)"
echo "  B: all-off   (CONSCIOUSNESS=0, NEUROMOD=0)"
echo "  C: fw-on, nm-off  (CONSCIOUSNESS=1, NEUROMOD=0)"
echo "  D: fw-off, nm-on  (CONSCIOUSNESS=0, NEUROMOD=1)"
echo

run_condition() {
  local label="$1"
  local consciousness="$2"
  local neuromod="$3"
  local tag="ablation-${label}-${MODEL//[:.]/-}"

  # All progress to stderr so $(run_condition ...) captures only the path
  echo "[ablation] $(date -u +%H:%M:%S) running condition $label..." >&2

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] would run condition $label: CONSCIOUSNESS=$consciousness NEUROMOD=$neuromod" >&2
    return 0
  fi

  existing=$(ls "$ROOT/logs/ab/${tag}-"*.summary.json 2>/dev/null | head -1)
  if [[ -n "$existing" ]]; then
    echo "  SKIP — $existing already exists (idempotent)" >&2
    echo "$existing"
    return 0
  fi

  OPENAI_API_BASE="${OLLAMA_BASE}/v1" \
  OPENAI_API_KEY=ollama \
  OPENAI_MODEL="$MODEL" \
  CHUMP_OLLAMA_NUM_CTX=8192 \
  CHUMP_HOME="$ROOT" \
  CHUMP_REPO="$ROOT" \
  CHUMP_CONSCIOUSNESS_ENABLED="$consciousness" \
  CHUMP_NEUROMOD_ENABLED="$neuromod" \
    scripts/ab-harness/run.sh \
      --fixture "$FIXTURE" \
      --flag ABLATION_CONDITION \
      --tag "$tag" \
      --limit "$LIMIT" \
      --chump-bin "$CHUMP_BIN" >&2 || {
    echo "[ablation] FAIL — condition $label harness exited nonzero" >&2; return 1
  }

  JSONL=$(ls -t "$ROOT/logs/ab/${tag}-"*.jsonl 2>/dev/null | head -1)
  [[ -z "$JSONL" ]] && { echo "[ablation] FAIL — no jsonl for $label" >&2; return 1; }

  echo "[ablation] scoring condition $label..." >&2
  if [[ -n "$JUDGE_CLAUDE_MODEL" ]]; then
    scripts/ab-harness/score.py "$JSONL" "$FIXTURE" --judge-claude "$JUDGE_CLAUDE_MODEL" >&2 || \
    scripts/ab-harness/score.py "$JSONL" "$FIXTURE" --judge "$JUDGE_OLLAMA_MODEL" >&2 || \
    scripts/ab-harness/score.py "$JSONL" "$FIXTURE" >&2 || return 1
  else
    scripts/ab-harness/score.py "$JSONL" "$FIXTURE" --judge "$JUDGE_OLLAMA_MODEL" >&2 || \
    scripts/ab-harness/score.py "$JSONL" "$FIXTURE" >&2 || return 1
  fi

  SUMMARY=$(ls -t "$ROOT/logs/ab/${tag}-"*.summary.json 2>/dev/null | head -1)
  echo "$SUMMARY"   # only the path goes to stdout
}

[[ $DRY_RUN -eq 1 ]] && { run_condition A 1 1; run_condition B 0 0; run_condition C 1 0; run_condition D 0 1; echo "[dry-run] done"; exit 0; }

SUMMARY_A=$(run_condition A 1 1)
SUMMARY_B=$(run_condition B 0 0)
SUMMARY_C=$(run_condition C 1 0)
SUMMARY_D=$(run_condition D 0 1)

echo
echo "[ablation] $(date -u +%H:%M:%S) aggregating..."

python3 - <<PY
import json
from pathlib import Path

def load(path):
    if not path or not Path(path).exists():
        return {}
    return json.loads(Path(path).read_text())

def mode_stats(summary, mode_key="A"):
    bm = (summary.get("by_mode") or {})
    m = bm.get(mode_key, {})
    return {
        "rate": m.get("rate"),
        "avg_tool_calls": m.get("avg_tool_calls"),
        "mean_judge_score": m.get("mean_judge_score"),
        "passed": m.get("passed", 0),
        "failed": m.get("failed", 0),
    }

a = load("$SUMMARY_A")
b = load("$SUMMARY_B")
c = load("$SUMMARY_C")
d = load("$SUMMARY_D")

def pct(v):
    return f"{v*100:.1f}%" if v is not None else "—"
def tc(v):
    return f"{v:.2f}" if v is not None else "—"

# Each condition ran as its own A/B job; we want the "A" mode stats (the ON half)
# For the all-off condition B, use the "B" mode stats (the OFF half)
sa = mode_stats(a, "A")
sb = mode_stats(b, "B")
sc = mode_stats(c, "A")
sd = mode_stats(d, "A")

results = {
    "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "model": "$MODEL",
    "fixture": "$FIXTURE",
    "limit": $LIMIT,
    "conditions": {
        "A_all_on":         {**sa, "CONSCIOUSNESS": 1, "NEUROMOD": 1},
        "B_all_off":        {**sb, "CONSCIOUSNESS": 0, "NEUROMOD": 0},
        "C_fw_on_nm_off":   {**sc, "CONSCIOUSNESS": 1, "NEUROMOD": 0},
        "D_fw_off_nm_on":   {**sd, "CONSCIOUSNESS": 0, "NEUROMOD": 1},
    },
}

def delta(r1, r2):
    if r1 is None or r2 is None: return None
    return round(r1 - r2, 3)

results["deltas"] = {
    "A_vs_B_full_effect":           delta(sa.get("rate"), sb.get("rate")),
    "A_vs_C_neuromod_within_fw":    delta(sa.get("rate"), sc.get("rate")),
    "C_vs_B_fw_without_neuromod":   delta(sc.get("rate"), sb.get("rate")),
    "D_vs_B_neuromod_alone":        delta(sd.get("rate"), sb.get("rate")),
}

Path("$RESULTS_JSON").write_text(json.dumps(results, indent=2))

print(f"  wrote → $RESULTS_JSON")
print()
print("  Condition            | Pass Rate | Avg Tools | C=? N=?")
print("  ---------------------|-----------|-----------|--------")
for k, v in results["conditions"].items():
    print(f"  {k:<20} | {pct(v.get('rate')):>9} | {tc(v.get('avg_tool_calls')):>9} | C={v.get('CONSCIOUSNESS')} N={v.get('NEUROMOD')}")
print()
print("  Deltas:")
for k, v in results["deltas"].items():
    sign = "+" if (v or 0) >= 0 else ""
    val = f"{sign}{v*100:.1f}pp" if v is not None else "—"
    print(f"  {k}: {val}")
PY

echo
echo "[ablation] $(date -u +%H:%M:%S) done."
