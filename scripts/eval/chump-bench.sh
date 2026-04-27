#!/usr/bin/env bash
#
# chump-bench: public benchmark runner for Chump.
#
# Our answer to OpenJarvis's "88.7% of single-turn queries at interactive
# latency" headline. Runs a fixed scenario mix against the currently-
# configured LLM backend and reports:
#
#   - pass rate              — % scenarios that complete successfully
#   - interactive pct        — % scenarios finishing inside the per-scenario
#                              "interactive" budget (tunable; default 30s
#                              for chat, 180s for multi-tool)
#   - p50 / p95 wall latency — end-to-end time per scenario
#   - median tokens/sec      — throughput during generation
#   - total joules (opt)     — energy spent if src/telemetry_energy.rs has
#                              a working backend (Apple Silicon via
#                              powermetrics, NVIDIA scaffold pending)
#
# Scenario set is intentionally small (8 scenarios) so a full run finishes
# in ~15 min on a 24 GB MacBook with a 9 B 4-bit model. Reproducible;
# results land in logs/chump-bench/<ts>/{report.json,summary.md}.
#
# Usage:
#   ./scripts/eval/chump-bench.sh                       # all scenarios
#   ./scripts/eval/chump-bench.sh --scenario chat       # one scenario by name
#   ./scripts/eval/chump-bench.sh --list                # print the scenario set
#   ./scripts/eval/chump-bench.sh --interactive-budget-s 45  # tune the "fast" threshold
#
# Exit:
#   0  run completed (independent of pass/fail rate)
#   1  scenario filter matched nothing
#   2  setup failed (backend unreachable, build broken)
#
# Publish results: commit the generated docs/operations/BENCHMARKS.md and logs/...
# directory to make them citeable. The docs file is the human-readable
# one, the JSON report is for programmatic comparison across runs.

set -uo pipefail

ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"

# ---- arg parsing ---------------------------------------------------------
ONLY=""
LIST_ONLY=0
INTERACTIVE_BUDGET_S=30
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scenario) ONLY="$2"; shift 2 ;;
        --list) LIST_ONLY=1; shift ;;
        --interactive-budget-s) INTERACTIVE_BUDGET_S="$2"; shift 2 ;;
        -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ---- scenario matrix -----------------------------------------------------
# Format: name|timeout_s|interactive_s|prompt
# - timeout_s: hard ceiling (scenario declared FAIL after this)
# - interactive_s: upper bound for "felt interactive"; used for the
#   interactive-pct metric (tunable via --interactive-budget-s).
# - prompt: deterministic, short expected output so repeated runs are
#   comparable.
SCENARIOS=(
  "chat|60|${INTERACTIVE_BUDGET_S}|Say hi and tell me in one sentence what you are."
  "task-list|180|60|List all open tasks using the task tool."
  "read-small|180|60|Read Cargo.toml using read_file and tell me the package name."
  "read-line-range|240|90|Read src/main.rs lines 1-30 using read_file and count the mod declarations."
  "rg-search|240|90|Use run_cli to run 'rg --version' and report the version number."
  "multi-tool|360|150|List all open tasks using the task tool, then read Cargo.toml using read_file and report the package version."
  "code-explain|240|90|Read src/main.rs lines 1-40 using read_file and explain in two sentences what this program is."
  "math-reason|60|${INTERACTIVE_BUDGET_S}|What is 17 * 23? Show your reasoning in one sentence."
)

if [[ "$LIST_ONLY" == "1" ]]; then
    printf "%-20s %-9s %-13s %s\n" "SCENARIO" "TIMEOUT" "INTERACTIVE" "PROMPT"
    for s in "${SCENARIOS[@]}"; do
        IFS='|' read -r name timeout interactive prompt <<<"$s"
        printf "%-20s %-9s %-13s %s\n" "$name" "${timeout}s" "${interactive}s" "$prompt"
    done
    exit 0
fi

# ---- env ----------------------------------------------------------------
export CHUMP_TOOL_PROFILE=full
export CHUMP_REPO="$ROOT"
export CHUMP_HOME="$ROOT"
export CHUMP_AUTO_APPROVE_TOOLS="run_cli,read_file,write_file,patch_file,rg,task,memory_brain,list_files,list_dir"
export CHUMP_AUTO_APPROVE_LOW_RISK=1

# Preserve caller overrides
_PRESERVE="OPENAI_MODEL OPENAI_API_BASE OPENAI_API_KEY \
CHUMP_OLLAMA_NUM_CTX CHUMP_OLLAMA_KEEP_ALIVE \
CHUMP_COMPLETION_MAX_TOKENS CHUMP_MODEL_REQUEST_TIMEOUT_SECS \
VLLM_MAX_TOKENS VLLM_CACHE_PERCENT VLLM_MODEL"
_SAVED=""
for v in $_PRESERVE; do
    if [[ -n "${!v:-}" ]]; then
        _SAVED="$_SAVED export $v=$(printf %q "${!v}");"
    fi
done
if [[ -f "$ROOT/.env" ]]; then
    set -a; source "$ROOT/.env"; set +a
fi
eval "$_SAVED"

export CHUMP_COMPLETION_MAX_TOKENS="${CHUMP_COMPLETION_MAX_TOKENS:-2048}"

# ---- output --------------------------------------------------------------
TS=$(date +%Y%m%d-%H%M%S)
OUTDIR="$ROOT/logs/chump-bench/$TS"
mkdir -p "$OUTDIR"
REPORT="$OUTDIR/report.json"
SUMMARY="$OUTDIR/summary.md"
VLLM_LOG="$ROOT/logs/vllm-mlx-8000.log"

log() { echo "$@" | tee -a "$SUMMARY"; }

log "# chump-bench $TS"
log ""
log "- **repo**: \`$ROOT\`"
log "- **model**: \`${OPENAI_MODEL:-unknown}\`"
log "- **backend**: \`${OPENAI_API_BASE:-unknown}\`"
log "- **scenarios**: ${#SCENARIOS[@]}"
log "- **interactive budget**: ${INTERACTIVE_BUDGET_S}s (scenarios with tighter budgets use their own)"
log "- **host**: \`$(uname -rm)\`"
log ""

# ---- pre-flight ---------------------------------------------------------
BIN="$ROOT/target/release/chump"
if [[ ! -x "$BIN" ]]; then
    log "Building release binary..."
    if ! cargo build --release --bin chump 2>&1 | tail -3 | tee -a "$SUMMARY"; then
        log "SETUP-FAIL: cargo build failed"
        exit 2
    fi
fi

MODEL_BASE="${OPENAI_API_BASE:-http://127.0.0.1:8000/v1}"
if ! curl -fsS --max-time 5 "$MODEL_BASE/models" >/dev/null 2>&1; then
    log "SETUP-FAIL: model backend unreachable at $MODEL_BASE/models"
    exit 2
fi
log "Backend OK: \`$MODEL_BASE\`"
log ""

# ---- scenario runner -----------------------------------------------------
# Writes scenario.stdout + scenario.meta to $OUTDIR. Parses the
# "chump session end: N model requests (A in / B out tokens)" line for
# token count; falls back to 0 if absent.
run_scenario() {
    local name="$1" timeout_s="$2" interactive_s="$3" prompt="$4"
    local sout="$OUTDIR/$name.stdout"
    local svllm="$OUTDIR/$name.vllm"
    local meta="$OUTDIR/$name.meta"

    local vllm_before=0
    if [[ -f "$VLLM_LOG" ]]; then
        vllm_before=$(wc -c <"$VLLM_LOG" | tr -d ' ')
    fi

    local start_ms
    start_ms=$(python3 -c 'import time; print(int(time.time()*1000))')

    # timeout(1) not always available on macOS — gtimeout via brew, or fallback.
    local TIMEOUT_BIN
    if command -v timeout >/dev/null 2>&1; then
        TIMEOUT_BIN="timeout"
    elif command -v gtimeout >/dev/null 2>&1; then
        TIMEOUT_BIN="gtimeout"
    else
        TIMEOUT_BIN=""
    fi

    local exit_code=0
    if [[ -n "$TIMEOUT_BIN" ]]; then
        "$TIMEOUT_BIN" --preserve-status "${timeout_s}s" "$BIN" --chump "$prompt" >"$sout" 2>&1 || exit_code=$?
    else
        "$BIN" --chump "$prompt" >"$sout" 2>&1 || exit_code=$?
    fi

    local end_ms
    end_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
    local duration_ms=$((end_ms - start_ms))
    local duration_s_int=$((duration_ms / 1000))

    if [[ -f "$VLLM_LOG" ]]; then
        tail -c +"$((vllm_before + 1))" "$VLLM_LOG" >"$svllm" 2>/dev/null || : >"$svllm"
    else
        : >"$svllm"
    fi

    # Extract out tokens from "chump session end: N model requests (X in / Y out tokens)"
    local out_tokens=0
    local n_requests=0
    if grep -q "chump session end:" "$sout"; then
        out_tokens=$(grep -oE '[0-9]+ out tokens' "$sout" | head -1 | awk '{print $1}')
        out_tokens="${out_tokens:-0}"
        n_requests=$(grep -oE '[0-9]+ model requests' "$sout" | head -1 | awk '{print $1}')
        n_requests="${n_requests:-0}"
    fi

    # Pass criteria (aligned with dogfood-matrix.sh so regressions line up):
    #  - exit code 0
    #  - stdout does NOT contain "model HTTP unreachable"
    #  - vLLM slice has no Metal assertion
    #  - stdout has non-empty final content (not just whitespace)
    local status="pass" reason=""
    if [[ "$exit_code" == "124" ]]; then
        status="fail"; reason="timeout after ${timeout_s}s"
    elif [[ "$exit_code" != "0" ]]; then
        status="fail"; reason="chump exit=$exit_code"
    elif grep -q "model HTTP unreachable" "$sout" 2>/dev/null; then
        status="fail"; reason="backend unreachable mid-turn"
    elif grep -qE "MTLCommandBuffer|failed assertion|Metal assertion" "$svllm" 2>/dev/null; then
        status="fail"; reason="vLLM Metal crash in slice"
    elif ! [[ -s "$sout" ]] || [[ "$(tail -c 100 "$sout" | tr -d '[:space:]')" == "" ]]; then
        status="fail"; reason="empty output"
    fi

    local interactive="no"
    if [[ "$status" == "pass" && "$duration_s_int" -le "$interactive_s" ]]; then
        interactive="yes"
    fi

    # Tokens/sec for this scenario (int division; the JSON aggregation
    # recomputes a proper mean later).
    local tps=0
    if [[ "$duration_ms" -gt 0 && "$out_tokens" -gt 0 ]]; then
        tps=$(python3 -c "print(round(${out_tokens} / (${duration_ms}/1000), 2))")
    fi

    # Per-scenario meta in JSON lines.
    python3 - <<PY >"$meta"
import json
print(json.dumps({
    "name": "$name",
    "status": "$status",
    "reason": "$reason",
    "exit_code": $exit_code,
    "duration_ms": $duration_ms,
    "interactive": "$interactive",
    "interactive_budget_s": $interactive_s,
    "timeout_s": $timeout_s,
    "out_tokens": $out_tokens,
    "n_requests": $n_requests,
    "tokens_per_sec": $tps,
    "prompt": ${prompt@Q},
}))
PY

    printf "%-20s %-6s %8dms  tokens=%4d  tps=%6s  %s\n" \
        "$name" "$status" "$duration_ms" "$out_tokens" "$tps" "$reason" | tee -a "$SUMMARY"
}

# ---- main loop -----------------------------------------------------------
log ""
log "## Per-scenario results"
log ""
log '```'
log "scenario             status  duration     tokens  tps      reason"
log "-------------------- ------  -----------  ------  -------  ----------------"

MATCHED=0
for s in "${SCENARIOS[@]}"; do
    IFS='|' read -r name timeout_s interactive_s prompt <<<"$s"
    if [[ -n "$ONLY" && "$name" != "$ONLY" ]]; then
        continue
    fi
    MATCHED=$((MATCHED + 1))
    run_scenario "$name" "$timeout_s" "$interactive_s" "$prompt"
done
log '```'
log ""

if [[ "$MATCHED" == "0" ]]; then
    log "**No scenarios matched filter \`--scenario=$ONLY\`.**"
    exit 1
fi

# ---- aggregate -----------------------------------------------------------
python3 - "$OUTDIR" "$REPORT" "$SUMMARY" "$TS" "${OPENAI_MODEL:-unknown}" "$MODEL_BASE" "$INTERACTIVE_BUDGET_S" <<'PY'
import json, os, sys, statistics
outdir, report_path, summary_path, ts, model, base, interactive_budget_s = sys.argv[1:]
metas = []
for fname in sorted(os.listdir(outdir)):
    if fname.endswith(".meta"):
        with open(os.path.join(outdir, fname)) as f:
            metas.append(json.load(f))
total = len(metas)
passes = sum(1 for m in metas if m["status"] == "pass")
interactive = sum(1 for m in metas if m["interactive"] == "yes")
latencies_pass = [m["duration_ms"] for m in metas if m["status"] == "pass"]
tps_pass = [m["tokens_per_sec"] for m in metas if m["status"] == "pass" and m["tokens_per_sec"] > 0]
def pct(a, b): return round((a/b)*100, 1) if b else 0.0
def pN(xs, p):
    if not xs: return 0
    xs = sorted(xs)
    k = int(round((len(xs)-1) * p / 100))
    return xs[k]
report = {
    "timestamp": ts,
    "model": model,
    "backend": base,
    "interactive_budget_s": int(interactive_budget_s),
    "scenario_count": total,
    "passes": passes,
    "fails": total - passes,
    "pass_rate_pct": pct(passes, total),
    "interactive_pct": pct(interactive, total),
    "median_latency_ms_pass": statistics.median(latencies_pass) if latencies_pass else 0,
    "p95_latency_ms_pass": pN(latencies_pass, 95),
    "median_tokens_per_sec_pass": statistics.median(tps_pass) if tps_pass else 0,
    "scenarios": metas,
}
with open(report_path, "w") as f:
    json.dump(report, f, indent=2)
with open(summary_path, "a") as f:
    f.write("## Aggregate\n\n")
    f.write(f"| metric | value |\n|---|---|\n")
    f.write(f"| scenarios | {total} |\n")
    f.write(f"| pass rate | **{report['pass_rate_pct']}%** ({passes}/{total}) |\n")
    f.write(f"| interactive (≤{interactive_budget_s}s or scenario budget) | **{report['interactive_pct']}%** ({interactive}/{total}) |\n")
    f.write(f"| median latency (pass) | {report['median_latency_ms_pass']} ms |\n")
    f.write(f"| p95 latency (pass) | {report['p95_latency_ms_pass']} ms |\n")
    f.write(f"| median tokens/sec (pass) | {report['median_tokens_per_sec_pass']} |\n\n")
    f.write(f"Report: `{report_path}`\n\n")
print(f"\nReport JSON: {report_path}")
print(f"Summary MD:  {summary_path}")
print(f"Pass rate:   {report['pass_rate_pct']}%  Interactive: {report['interactive_pct']}%")
PY

exit 0
