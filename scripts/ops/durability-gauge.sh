#!/usr/bin/env bash
# durability-gauge.sh — the DURABILITY GAUGE: "hours-unattended-before-stall".
#
# THE NORTH-STAR QUESTION. How many hours can the factory run with NO human
# touch before it stalls and needs a person to clear it? On 2026-09-09 the
# answer was ~half a day: production (merges to origin/main) stopped after
# 2026-09-09T05:54Z and did not resume until 2026-09-09T20:54Z — a ~15h
# productive silence caused by a git-untracked frozen worker filter
# (FLEET_DOMAIN_FILTER=EFFECTIVE,CREDIBLE) plus a disabled self-heal
# (CHUMP_STARVE_AUTO_RELAX), and ONLY the human operator noticed. This gauge
# exists so the NEXT one pages from the machine, not from a person's gut.
#
# It is an ORGAN, not a one-shot. A chump-durability-gauge.timer drives it every
# 15m; it writes ~/.chump/durability-gauge.json, emits a `durability_gauge`
# ambient heartbeat (so a dead/frozen gauge is itself observable), and on a live
# unhealed stall it PAGES the operator via notify-operator.sh with
# kind=durability_stall (registered `page` in operator-escalation-registry.txt).
#
# METRIC DEFINITION
#   productive action = a merge to origin/main (node-agnostic ground truth; the
#     signal ATC watches and vital-signs' merge_throughput counts) PLUS any
#     ambient ship event (gap_shipped/ship_merged/ship_landed) if present.
#   human touch       = an operator/manual intervention from the ambient stream
#     (operator_recall / operator_page* / manual_rescue / …) — see
#     lib/human-touch-timeline.sh for the canonical kind-set.
#   stall             = production stopped with no human clearing it: a gap
#     between consecutive productive actions longer than STALL_THRESHOLD_HOURS.
#     Default 3.0h is the ~p95 of the real inter-merge gap distribution
#     (median 0.44h, p90 2.2h, p95 ~3.0h over the trailing 400 merges) — high
#     enough to ignore routine overnight lulls, low enough to catch a
#     half-day outage. Configurable via CHUMP_DURABILITY_STALL_HOURS.
#   HEADLINE  hours_unattended_before_stall = elapsed from the last human touch
#     to the stall onset (falls back to the stall's own duration when no human
#     touch precedes it in-window — an honestly-flagged basis, not a fake 0).
#   Also exposed: current unattended streak (now − last human touch),
#     is_stalled, longest stall, mean-time-to-stall, longest clean streak.
#
# Usage:
#   scripts/ops/durability-gauge.sh              # collect + write + maybe page
#   scripts/ops/durability-gauge.sh --dry-run    # print JSON, no writes/pages
#   scripts/ops/durability-gauge.sh --json       # alias of --dry-run
#
# Env overrides (all optional):
#   CHUMP_REPO_ROOT / REPO_ROOT        repo checkout root
#   CHUMP_DURABILITY_OUT               out json (default ~/.chump/durability-gauge.json)
#   CHUMP_AMBIENT_LOG                  ambient jsonl (default REPO_ROOT/.chump-locks/ambient.jsonl)
#   CHUMP_GH_REPO                      owner/repo (default repairman29/chump)
#   CHUMP_DURABILITY_STALL_HOURS       stall threshold hours (default 3.0)
#   CHUMP_DURABILITY_WINDOW_DAYS       lookback window days (default 7)
#   CHUMP_DURABILITY_HUMAN_KINDS       override human-touch kind-set (see lib)
#   CHUMP_DURABILITY_NO_PAGE=1         never page (collect only)
# Deterministic-test injectables:
#   CHUMP_DURABILITY_NOW=<iso>              override "now"
#   CHUMP_DURABILITY_MERGES_FIXTURE=<file>  ISO ts per line, skip gh/cache
#   CHUMP_DURABILITY_HUMAN_FIXTURE=<file>   ISO ts per line, skip ambient scan
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"

# ── HOST-ASSUMPTION HARDENING (mirrors vital-signs.sh / faculty-collector.sh) ─
# systemd units hardcode Environment=HOME=/root even when User=jeff; resolve the
# RUN-USER's real home so every $HOME-relative read resolves, and prepend the
# user's bins so gh/jq/chump/sqlite3 are found under a minimal service PATH.
REAL_HOME="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)"
[[ -z "$REAL_HOME" || ! -d "$REAL_HOME" ]] && REAL_HOME="$HOME"
export HOME="$REAL_HOME"
export PATH="$REAL_HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# REPO-ROOT HARDENING: if the env-derived root does not hold this script's own
# organ manifest, self-heal to the run-user's canonical checkout so a bad caller
# env (torn-down worktree, /root-mapped path) can never blind the gauge.
if [[ ! -f "$REPO_ROOT/scripts/ops/durability-gauge.sh" ]]; then
  for _cand in "$REAL_HOME/Projects/chump" "$SCRIPT_DIR/../.."; do
    if [[ -f "$_cand/scripts/ops/durability-gauge.sh" ]]; then
      REPO_ROOT="$(cd "$_cand" && pwd)"; break
    fi
  done
fi

# shellcheck source=scripts/ops/lib/merge-timeline.sh
source "$SCRIPT_DIR/lib/merge-timeline.sh"
# shellcheck source=scripts/ops/lib/human-touch-timeline.sh
source "$SCRIPT_DIR/lib/human-touch-timeline.sh"

OUT="${CHUMP_DURABILITY_OUT:-$REAL_HOME/.chump/durability-gauge.json}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
GH_REPO="${CHUMP_GH_REPO:-repairman29/chump}"
STALL_HOURS="${CHUMP_DURABILITY_STALL_HOURS:-3.0}"
WINDOW_DAYS="${CHUMP_DURABILITY_WINDOW_DAYS:-7}"

# AMBIENT-LOG HARDENING: fall back to the canonical checkout's stream if the
# resolved path is missing, so the human-touch scan reads the truth.
if [[ ! -e "$AMBIENT_LOG" && -e "$REPO_ROOT/.chump-locks/ambient.jsonl" ]]; then
  AMBIENT_LOG="$REPO_ROOT/.chump-locks/ambient.jsonl"
fi

DRY_RUN=0
case "${1:-}" in --dry-run|--json) DRY_RUN=1 ;; esac

command -v python3 >/dev/null 2>&1 || { echo "[durability-gauge] FATAL: python3 not found" >&2; exit 1; }

NOW="${CHUMP_DURABILITY_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
# window start = now - WINDOW_DAYS
SINCE="$(python3 -c "
import datetime as dt
now=dt.datetime.fromisoformat('$NOW'.replace('Z','+00:00'))
print((now-dt.timedelta(days=float('$WINDOW_DAYS'))).strftime('%Y-%m-%dT%H:%M:%SZ'))
")"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/durability.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT
MERGES_F="$TMPD/merges.txt"
HUMAN_F="$TMPD/human.txt"

# ── gather PRODUCTIVE timeline (merges to origin/main + ambient ship events) ──
if [[ -n "${CHUMP_DURABILITY_MERGES_FIXTURE:-}" ]]; then
  cp "$CHUMP_DURABILITY_MERGES_FIXTURE" "$MERGES_F" 2>/dev/null || : > "$MERGES_F"
else
  merge_timeline "$REPO_ROOT" "$GH_REPO" "$SINCE" > "$MERGES_F" 2>/dev/null || : > "$MERGES_F"
  # Supplementary: ambient ship events, if this node emits any (forward-compat;
  # the Mac node does not today, so this is additive, never subtractive).
  if [[ -f "$AMBIENT_LOG" ]]; then
    grep -hE '"kind":"(gap_shipped|ship_merged|ship_landed|ship_merged_to_main)"' "$AMBIENT_LOG" 2>/dev/null \
      | awk -v c="$SINCE" -F'"ts":"' '{split($2,a,"\""); if(a[1]!="" && a[1]>=c) print a[1]}' \
      >> "$MERGES_F" 2>/dev/null || true
  fi
fi

# ── gather HUMAN-TOUCH timeline (ambient interventions) ──────────────────────
if [[ -n "${CHUMP_DURABILITY_HUMAN_FIXTURE:-}" ]]; then
  cp "$CHUMP_DURABILITY_HUMAN_FIXTURE" "$HUMAN_F" 2>/dev/null || : > "$HUMAN_F"
else
  human_touch_timeline "$AMBIENT_LOG" "$SINCE" > "$HUMAN_F" 2>/dev/null || : > "$HUMAN_F"
fi

# ── COMPUTE (embedded python core — the one place the stall math lives) ───────
DOC="$(NOW="$NOW" SINCE="$SINCE" STALL_HOURS="$STALL_HOURS" WINDOW_DAYS="$WINDOW_DAYS" \
       MERGES_F="$MERGES_F" HUMAN_F="$HUMAN_F" python3 <<'PYCORE'
import os, json, datetime as dt

def parse(ts):
    ts = ts.strip()
    if not ts:
        return None
    try:
        return dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except Exception:
        return None

def load(path):
    out = []
    try:
        with open(path) as f:
            for line in f:
                t = parse(line)
                if t is not None:
                    out.append(t)
    except FileNotFoundError:
        pass
    return sorted(set(out))

NOW = parse(os.environ["NOW"])
SINCE = parse(os.environ["SINCE"])
THR = float(os.environ["STALL_HOURS"])      # stall threshold, hours
WINDOW_DAYS = float(os.environ["WINDOW_DAYS"])

prod = [t for t in load(os.environ["MERGES_F"]) if t <= NOW]
human = [t for t in load(os.environ["HUMAN_F"]) if t <= NOW]

def hours(a, b):
    return (b - a).total_seconds() / 3600.0

def iso(t):
    return None if t is None else t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def r2(x):
    return None if x is None else round(x, 2)

def last_touch_at_or_before(t):
    prev = [h for h in human if h <= t]
    return prev[-1] if prev else None

# ── stall detection ──────────────────────────────────────────────────────────
# A stall = a span with NO productive action longer than THR hours. Consider the
# gaps between consecutive productive actions AND the trailing gap (last -> now).
stalls = []
if not prod:
    # No production at all in the window: one big ongoing stall from window start.
    dur = hours(SINCE, NOW)
    if dur > THR:
        stalls.append({"onset": SINCE, "resumed_at": None, "dur": dur, "ongoing": True})
else:
    seq = prod + [NOW]
    for i in range(len(seq) - 1):
        a, b = seq[i], seq[i + 1]
        g = hours(a, b)
        if g > THR:
            ongoing = (b == NOW)
            stalls.append({
                "onset": a,
                "resumed_at": None if ongoing else b,
                "dur": g,
                "ongoing": ongoing,
            })

# per-stall unattended-before figure = onset - last human touch at/before onset
stall_objs = []
for s in stalls:
    lt = last_touch_at_or_before(s["onset"])
    if lt is not None:
        unattended = hours(lt, s["onset"])
        basis = "last_human_touch_to_onset"
    else:
        # No human touch precedes this onset in-window: the machine had already
        # been running unattended. Fall back to the stall's own duration (the
        # honest lower-bound "how long it ran dark") rather than a fake 0.
        unattended = s["dur"]
        basis = "no_human_touch_in_window:stall_duration"
    stall_objs.append({
        "onset": iso(s["onset"]),
        "resumed_at": iso(s["resumed_at"]),
        "ongoing": s["ongoing"],
        "duration_hours": r2(s["dur"]),
        "hours_unattended_before_stall": r2(unattended),
        "unattended_basis": basis,
    })

# ── current state ────────────────────────────────────────────────────────────
last_prod = prod[-1] if prod else None
current_silence = hours(last_prod, NOW) if last_prod else hours(SINCE, NOW)
is_stalled = current_silence > THR

last_h = human[-1] if human else None
unattended_streak = hours(last_h, NOW) if last_h else hours(SINCE, NOW)
unattended_streak_basis = ("since_last_human_touch" if last_h
                           else "no_human_touch_in_window:since_window_start")

# ── rolling stats ────────────────────────────────────────────────────────────
# clean (healthy) segments = spans of the window containing no stall.
seg_bounds = [SINCE]
for s in stalls:
    seg_bounds.append(("onset", s["onset"]))
    if s["resumed_at"] is not None:
        seg_bounds.append(("resume", s["resumed_at"]))
# Reconstruct healthy segments: window_start -> stall1.onset,
# stall1.resume -> stall2.onset, ..., lastResume -> now.
healthy = []
cursor = SINCE
ended_in_stall = []   # healthy runs that terminate in a stall (for MTTS)
for s in stalls:
    seg = hours(cursor, s["onset"])
    if seg > 0:
        healthy.append(seg)
        ended_in_stall.append(seg)
    cursor = s["resumed_at"] if s["resumed_at"] is not None else NOW
# trailing healthy segment (only if the last stall actually resumed)
if stalls and stalls[-1]["resumed_at"] is not None:
    tail = hours(stalls[-1]["resumed_at"], NOW)
    if tail > 0:
        healthy.append(tail)
elif not stalls:
    healthy.append(hours(SINCE, NOW))

def mean(xs):
    return (sum(xs) / len(xs)) if xs else None

# inter-merge cadence sanity
gaps = [hours(prod[i], prod[i + 1]) for i in range(len(prod) - 1)] if len(prod) > 1 else []

# headline = the MOST RECENT stall's unattended-before figure (what pages), and
# the longest stall duration in the window (the worst dark stretch observed).
most_recent = stall_objs[-1] if stall_objs else None
longest_stall = max((s["duration_hours"] for s in stall_objs), default=0.0)

doc = {
    "generated_at": iso(NOW),
    "window": {"since": iso(SINCE), "days": WINDOW_DAYS},
    "stall_threshold_hours": THR,
    "productive_count": len(prod),
    "human_touch_count": len(human),
    "last_productive_ts": iso(last_prod),
    "last_human_touch_ts": iso(last_h),
    "current_silence_hours": r2(current_silence),
    "is_stalled": is_stalled,
    "unattended_streak_hours": r2(unattended_streak),
    "unattended_streak_basis": unattended_streak_basis,
    "headline": {
        # THE number: how long the fleet ran unattended before the most-recent
        # stall. When production is currently stalled this is the live streak.
        "hours_unattended_before_stall": (most_recent["hours_unattended_before_stall"]
                                          if most_recent else None),
        "longest_stall_hours": r2(longest_stall),
        "most_recent_stall": most_recent,
    },
    "stats": {
        "stall_count": len(stall_objs),
        "mean_stall_duration_hours": r2(mean([s["duration_hours"] for s in stall_objs])),
        "mean_time_to_stall_hours": r2(mean(ended_in_stall)),
        "longest_clean_streak_hours": r2(max(healthy) if healthy else None),
        "mean_inter_merge_gap_hours": r2(mean(gaps)),
    },
    "stalls": stall_objs,
}
print(json.dumps(doc, indent=2))
PYCORE
)"

if ! printf '%s' "$DOC" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  echo "[durability-gauge] FATAL: core produced invalid JSON" >&2
  exit 1
fi

if [[ "$DRY_RUN" == 1 ]]; then
  printf '%s\n' "$DOC"
  exit 0
fi

# ── write the board ──────────────────────────────────────────────────────────
mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
tmp="$(mktemp "${TMPDIR:-$REAL_HOME/.chump}/durability-gauge.XXXXXX.json" 2>/dev/null || echo "$OUT.tmp")"
printf '%s\n' "$DOC" > "$tmp" && mv -f "$tmp" "$OUT"

# ── ambient heartbeat: a dead/frozen gauge is itself observable ──────────────
# scanner-anchor: "kind":"durability_gauge"
mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
IS_STALLED="$(printf '%s' "$DOC" | python3 -c 'import json,sys;print(str(json.load(sys.stdin)["is_stalled"]).lower())')"
HEADLINE_H="$(printf '%s' "$DOC" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["headline"]["hours_unattended_before_stall"] if d["headline"]["hours_unattended_before_stall"] is not None else "null")')"
STREAK_H="$(printf '%s' "$DOC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["unattended_streak_hours"])')"
LONGEST_H="$(printf '%s' "$DOC" | python3 -c 'import json,sys;print(json.load(sys.stdin)["headline"]["longest_stall_hours"])')"
printf '{"ts":"%s","kind":"durability_gauge","is_stalled":%s,"unattended_streak_hours":%s,"hours_unattended_before_stall":%s,"longest_stall_hours":%s,"stall_threshold_hours":%s,"out":"%s"}\n' \
  "$NOW" "$IS_STALLED" "$STREAK_H" "$HEADLINE_H" "$LONGEST_H" "$STALL_HOURS" "$OUT" >> "$AMBIENT_LOG" 2>/dev/null || true

echo "[durability-gauge] wrote $OUT (is_stalled=$IS_STALLED, unattended_streak=${STREAK_H}h, longest_stall=${LONGEST_H}h) @ $NOW"

# ── ALERT on a LIVE unhealed stall via the existing escalation path ──────────
# Only page when production is CURRENTLY stalled (not for historical stalls the
# fleet already recovered from). Debounce on the stall onset so a multi-hour
# outage pages ONCE, not every timer tick.
if [[ "$IS_STALLED" != "true" || "${CHUMP_DURABILITY_NO_PAGE:-0}" == "1" ]]; then
  exit 0
fi

ONSET="$(printf '%s' "$DOC" | python3 -c 'import json,sys;s=json.load(sys.stdin)["stalls"];print(s[-1]["onset"] if s else "")')"
PAGE_STATE="${CHUMP_DURABILITY_PAGE_STATE:-$REAL_HOME/.chump/durability-gauge.last-paged}"
LAST_PAGED_ONSET="$(cat "$PAGE_STATE" 2>/dev/null || true)"
if [[ -n "$ONSET" && "$ONSET" == "$LAST_PAGED_ONSET" ]]; then
  echo "[durability-gauge] stall onset $ONSET already paged — debounced." >&2
  exit 0
fi

NOTIFY="$REPO_ROOT/scripts/coord/lib/notify-operator.sh"
MSG="DURABILITY STALL: production has stopped for ${STREAK_H}h (no merge to origin/main since ${ONSET}; threshold ${STALL_HOURS}h). The factory is running unattended-but-dead — a human likely needs to clear a wedge (frozen worker filter / disabled self-heal / dead daemon). Gauge: ${OUT}"
if [[ -f "$NOTIFY" ]]; then
  # kind=durability_stall is registered `page` in operator-escalation-registry.txt,
  # so this emits operator_paged AND flows through the single-voice curation queue
  # (RESILIENT-1093) + global page-rate ceiling (RESILIENT-1095) like every other
  # page — no `halt` bypass, a stall is important but not exempt from coalescing.
  # Pass CHUMP_AMBIENT_LOG through so the operator_paged escalation lands in the
  # same stream this gauge writes its heartbeat to.
  CHUMP_NOTIFY_KIND="durability_stall" CHUMP_AMBIENT_LOG="$AMBIENT_LOG" \
    bash "$NOTIFY" "$MSG" || true
  printf '%s' "$ONSET" > "$PAGE_STATE" 2>/dev/null || true
  echo "[durability-gauge] PAGED operator (durability_stall, onset=$ONSET)" >&2
else
  echo "[durability-gauge] WARN: notify-operator.sh not found at $NOTIFY — cannot page" >&2
fi
