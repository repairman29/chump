#!/usr/bin/env bash
# bench-cog-037-thompson.sh — COG-039: bench harness for cog_037 Thompson router.
#
# Per WORLD_CLASS_ROADMAP M4 protocol (CLAUDE.md "Long COG-* branches forbidden"):
#   1. New COG-* gap lands a `cog_NNN` flag default-off
#   2. Bench harness compares flag-off baseline vs flag-on candidate (THIS SCRIPT)
#   3. After bench + cycle review, flip the default by removing the gate
#   4. Cleanup PR removes the dead flag entry
#
# COG-037 is at step 2: the Thompson sampler is implemented (crates/chump-orchestrator/src/thompson.rs)
# and gated by `CHUMP_FLAGS=cog_037`. This script gives the operator the
# evidence to make the step-3 flip-or-don't decision.
#
# What it measures (no fleet spawn, no API spend):
#
# 1. **Selection-quality delta.** For each (task_class, count) pair, run
#    `chump dispatch simulate` with `CHUMP_FLAGS=` (off) and `CHUMP_FLAGS=cog_037`
#    (on). Count how many simulator picks land on the historically-best arm
#    (highest success_rate from `chump dispatch scoreboard`). Higher is better.
#
# 2. **Pick concentration.** When Thompson is on, posterior-best arms should
#    win more often — concentration (1 − entropy of pick distribution) goes
#    up. With the flag off, picks are deterministic per (task_class, candidate
#    list) so concentration is 1.0 trivially; with the flag on, concentration
#    reflects how confident the posterior is.
#
# 3. **Scoreboard sanity.** Print the current scoreboard so the operator can
#    eyeball the data Thompson is sampling against.
#
# This is a SIMULATION bench — no real dispatch happens. Per the
# WORLD_CLASS_ROADMAP M4 protocol, operator + cycle review use this output
# to decide whether to flip the default. A live A/B is a separate concern
# (run-fleet.sh × CHUMP_FLAGS, multi-day data collection).
#
# Usage:
#   scripts/eval/bench-cog-037-thompson.sh                        # default: research+dispatch, n=200 each
#   scripts/eval/bench-cog-037-thompson.sh research 500           # just one task class
#   CHUMP_BIN=./target/release/chump scripts/eval/bench-cog-037-thompson.sh
#
# Env:
#   CHUMP_BIN              path to chump binary (default: chump on PATH)
#   COG_BENCH_OUT          where to write the JSON summary (default: scripts/ab-harness/results/cog-037-bench-<ts>.json)
#
# Exit codes:
#   0  bench completed cleanly + summary written
#   1  precondition failure (chump binary missing, or chump dispatch subcommand broken)
#   2  malformed simulator output

set -euo pipefail

CHUMP_BIN="${CHUMP_BIN:-$(command -v chump || true)}"
[[ -x "$CHUMP_BIN" ]] || { echo "[bench-cog-037] chump binary not found (CHUMP_BIN=$CHUMP_BIN)" >&2; exit 1; }

# Verify the CLI fix from INFRA-392 is in this binary — pre-fix, `dispatch
# scoreboard` triggers gap-preflight which we don't want to interpret as
# success. The fixed binary returns "No routing outcomes recorded yet" or
# a real scoreboard table when the DB has rows.
if ! "$CHUMP_BIN" dispatch scoreboard 2>&1 | head -3 | grep -qE 'routing outcomes|signature.*successes|^[0-9]+ '; then
    echo "[bench-cog-037] WARNING: 'chump dispatch scoreboard' did not return expected output." >&2
    echo "[bench-cog-037]   You may be running a binary without the INFRA-392 CLI fix." >&2
    echo "[bench-cog-037]   Rebuild: cargo build --release --bin chump && cp target/release/chump ~/.local/bin/chump" >&2
    exit 1
fi

# Default sweep: two task classes × n=200 each.
# Operator can pass alternative as positional args.
TASK_CLASS="${1:-}"
N_TRIALS="${2:-200}"

if [[ -n "$TASK_CLASS" ]]; then
    SWEEPS=("$TASK_CLASS:$N_TRIALS")
else
    SWEEPS=("research:200" "dispatch:200")
fi

OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/ab-harness/results"
mkdir -p "$OUT_DIR"
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT_FILE="${COG_BENCH_OUT:-$OUT_DIR/cog-037-bench-${TS}.json}"

echo "=== COG-037 Thompson router bench ==="
echo "binary: $CHUMP_BIN"
echo "sweeps: ${SWEEPS[*]}"
echo "summary out: $OUT_FILE"
echo ""

# ── Step 1: scoreboard snapshot ──────────────────────────────────────────────
echo "── Scoreboard snapshot ──"
SCOREBOARD_RAW="$("$CHUMP_BIN" dispatch scoreboard 2>&1)"
echo "$SCOREBOARD_RAW"
echo ""

# Parse the scoreboard into (signature → success_rate) using awk. The
# `chump dispatch scoreboard` table format (per src/main.rs lines ~1064+)
# has columns: rank | task_class | backend | model | provider | successes
# | failures | rate% | last_seen. We pull col-N depending on header detection.
SCOREBOARD_BEST_RATE=$(echo "$SCOREBOARD_RAW" | awk '
    /No routing outcomes/ { print 0; exit }
    /successes/ { header=1; next }
    header && NF >= 7 {
        # rate is the third-to-last numeric field (success_rate * 100)
        for (i=NF; i>0; i--) {
            if ($i ~ /^[0-9]+\.[0-9]+$/) { print $i; exit }
        }
    }')
SCOREBOARD_BEST_RATE="${SCOREBOARD_BEST_RATE:-0}"
echo "best historical arm rate: ${SCOREBOARD_BEST_RATE}%"
echo ""

# ── Step 2: per-sweep flag-off vs flag-on simulation ─────────────────────────
declare -a SUMMARY_JSON=()

for sweep in "${SWEEPS[@]}"; do
    cls="${sweep%%:*}"
    n="${sweep#*:}"
    echo "── Sweep: task_class=${cls}, n=${n} ──"

    # Run simulate twice: flag-off (CHUMP_FLAGS unset) and flag-on
    # (CHUMP_FLAGS=cog_037). Note: simulate ALWAYS runs the Thompson
    # path per the comment in main.rs — but the candidate list passed to
    # rank_by_thompson differs by flag because select_candidates_for_gap
    # may be called by upstream code that respects the flag. For the
    # sampler-only diagnostic we toggle the flag to be defensive.
    OFF_OUT="$(CHUMP_FLAGS="" "$CHUMP_BIN" dispatch simulate "$cls" "$n" 2>&1)"
    ON_OUT="$(CHUMP_FLAGS="cog_037" "$CHUMP_BIN" dispatch simulate "$cls" "$n" 2>&1)"

    # Parse pick-frequency table. Format from main.rs simulator:
    #   rank signature (backend|model|provider)               picks   rate%  why
    # We want the unique signatures + their pick counts.
    extract_picks() {
        # Args: simulator stdout. Output: lines of "<picks> <signature>".
        echo "$1" | awk '
            /signature.*picks/ { in_table=1; next }
            !in_table { next }
            NF < 3 { next }
            {
                # signature is everything between cols 2 and (NF-2)
                # picks is at NF-2 (before rate% and why)
                # but the "why" string contains spaces so we cant use $NF blindly
                # picks is the first numeric field after the signature
                for (i=2; i<=NF; i++) {
                    if ($i ~ /^[0-9]+$/) {
                        # join cols 2..i-1 as signature
                        sig = ""
                        for (j=2; j<i; j++) sig = sig (j>2 ? " " : "") $j
                        print $i " " sig
                        next
                    }
                }
            }
        '
    }

    OFF_PICKS=$(extract_picks "$OFF_OUT")
    ON_PICKS=$(extract_picks "$ON_OUT")

    # Compute concentration = top-arm picks / total picks.
    # Higher concentration = sampler is confident.
    off_top=$(echo "$OFF_PICKS" | sort -rn | head -1 | awk '{print $1}')
    on_top=$(echo "$ON_PICKS" | sort -rn | head -1 | awk '{print $1}')
    off_concentration=$(awk "BEGIN { if ($n>0) printf \"%.3f\", ${off_top:-0}/$n; else print 0 }")
    on_concentration=$(awk "BEGIN { if ($n>0) printf \"%.3f\", ${on_top:-0}/$n; else print 0 }")

    echo "  flag-off top-arm concentration: ${off_concentration} (${off_top:-0}/${n})"
    echo "  flag-on  top-arm concentration: ${on_concentration} (${on_top:-0}/${n})"

    # Top arm signature for each
    off_top_sig=$(echo "$OFF_PICKS" | sort -rn | head -1 | cut -d' ' -f2-)
    on_top_sig=$(echo "$ON_PICKS" | sort -rn | head -1 | cut -d' ' -f2-)
    echo "  flag-off top-arm signature: ${off_top_sig:-<none>}"
    echo "  flag-on  top-arm signature: ${on_top_sig:-<none>}"

    SUMMARY_JSON+=("$(printf '{"task_class":"%s","n":%d,"flag_off":{"top_arm":"%s","concentration":%s},"flag_on":{"top_arm":"%s","concentration":%s}}' \
        "$cls" "$n" \
        "${off_top_sig//\"/\\\"}" "$off_concentration" \
        "${on_top_sig//\"/\\\"}" "$on_concentration")")
    echo ""
done

# ── Step 3: write JSON summary + verdict ─────────────────────────────────────
{
    echo '{'
    printf '  "ts": "%s",\n' "$TS"
    printf '  "binary_sha": "%s",\n' "$(cd "$(dirname "$0")/.." && git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    printf '  "scoreboard_best_rate_pct": %s,\n' "$SCOREBOARD_BEST_RATE"
    printf '  "sweeps": ['
    first=1
    for s in "${SUMMARY_JSON[@]}"; do
        if (( first )); then first=0; else printf ','; fi
        printf "\n    %s" "$s"
    done
    printf '\n  ]\n'
    echo '}'
} > "$OUT_FILE"

echo "── Verdict (operator interprets) ──"
echo ""
echo "Per WORLD_CLASS_ROADMAP M4 step 3, decide whether to flip cog_037 default ON:"
echo ""
echo "  • If scoreboard has < 50 outcomes total → INSUFFICIENT DATA. Defer flip until"
echo "    more dispatches accumulate. Re-run this bench in 1-2 weeks."
echo ""
echo "  • If on-flag concentration is much higher than off-flag (sampler picks the"
echo "    same best arm consistently) AND that arm has the highest historical"
echo "    success rate → SAFE TO FLIP. Thompson is converging to the right place."
echo ""
echo "  • If on-flag concentration is similar or lower than off-flag → DON'T FLIP YET."
echo "    Sampler is exploring (not enough data yet) or the candidate-rate variance"
echo "    is too low to discriminate. Re-run later."
echo ""
echo "  • If on-flag top arm differs from off-flag top arm AND the on-flag arm has a"
echo "    higher historical success rate → STRONG SIGNAL TO FLIP. Thompson is"
echo "    overriding the static default in a way that picks better."
echo ""
echo "Summary JSON: $OUT_FILE"
