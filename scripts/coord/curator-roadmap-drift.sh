#!/usr/bin/env bash
# curator-roadmap-drift.sh — INFRA-1286 (META-065 layer 3)
#
# Decision 6 (roadmap_drift): cross-references docs/ROADMAP.md milestone
# structure against the open P0/P1 gap registry and flags drift:
#   - "unanchored": a P0/P1 gap that isn't referenced by any milestone
#   - "starving": a milestone (not yet ✅ done) whose owning gaps include
#     zero open P0/P1 gaps
#
# Sourced by scripts/coord/opus-curator.sh; can also be run directly for
# ad-hoc / test invocation:
#   scripts/coord/curator-roadmap-drift.sh check
#
# Env:
#   CHUMP_CURATOR_ROADMAP_CHECK=0   escape hatch — disables the arm entirely
#   CHUMP_ROADMAP_PATH              path to ROADMAP.md (default: docs/ROADMAP.md)
#   CHUMP_ROADMAP_UNANCHORED_THRESHOLD   default 3 (drift when count > this)
#   CHUMP_ROADMAP_STARVING_THRESHOLD     default 1 (drift when count > this)
#   CHUMP_AMBIENT_LOG                default .chump-locks/ambient.jsonl
#   LOCK_DIR / REPO_ROOT              as used by opus-curator.sh
#   CHUMP_CURATOR_DRY_RUN=1          skip the `chump gap reserve` mutation

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RD_REPO_ROOT="${REPO_ROOT:-$(cd "$_SCRIPT_DIR/../.." && pwd)}"

_rd_amb() {
  printf '%s' "${CHUMP_AMBIENT_LOG:-${_RD_REPO_ROOT}/.chump-locks/ambient.jsonl}"
}

_rd_lock_dir() {
  printf '%s' "${LOCK_DIR:-${_RD_REPO_ROOT}/.chump-locks}"
}

_rd_roadmap_path() {
  printf '%s' "${CHUMP_ROADMAP_PATH:-${_RD_REPO_ROOT}/docs/ROADMAP.md}"
}

# Best-effort ambient emit; does not depend on opus-curator.sh being sourced.
_rd_log_ambient() {
  local kind="$1" data="$2"
  local amb; amb="$(_rd_amb)"
  mkdir -p "$(dirname "$amb")" 2>/dev/null || true
  printf '{"ts":"%s","kind":"%s",%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$data" \
    >> "$amb" 2>/dev/null || true
}

# _rd_parse_roadmap <path> — emits one JSON object per line to stdout:
#   {"milestone":"...","status":"done|open","target_date":"YYYY-MM-DD"|null,
#    "owning_gap_ids":["INFRA-123",...]}
# Milestone boundaries are `##` headings. Status is "done" when the heading
# or body contains a done-class marker (✅ / "done" / "shipped"); target_date
# is the first ISO date (YYYY-MM-DD) found in the heading, else null.
_rd_parse_roadmap() {
  local path="$1"
  [[ -f "$path" ]] || { echo '[]'; return; }
  python3 - "$path" <<'PY'
import json, re, sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()

sections = re.split(r'(?m)^##\s+', text)[1:]  # drop preamble before first ##
gap_re = re.compile(
    r'\b(?:INFRA|META|MISSION|EFFECTIVE|CREDIBLE|RESILIENT|ZERO-WASTE)-\d+\b'
)
date_re = re.compile(r'\b(20\d{2}-\d{2}-\d{2})\b')
done_re = re.compile(r'✅|\bdone\b|\bshipped\b', re.IGNORECASE)

milestones = []
for sec in sections:
    lines = sec.splitlines()
    heading = lines[0].strip() if lines else ""
    body = "\n".join(lines[1:])
    gap_ids = sorted(set(gap_re.findall(sec)))
    date_match = date_re.search(heading)
    target_date = date_match.group(1) if date_match else None
    # A milestone is "done" only when the heading itself declares it done
    # (body ✅ marks are per-row shipped bets, not whole-milestone status).
    status = "done" if done_re.search(heading) else "open"
    milestones.append({
        "milestone": heading[:200],
        "status": status,
        "target_date": target_date,
        "owning_gap_ids": gap_ids,
    })

print(json.dumps(milestones))
PY
}

# _rd_pattern_hash <unanchored_count> <starving_csv> — deterministic key for
# same-day dedup. Two different drift shapes on the same day both get filed
# (up to the daily .jsonl growing); an identical shape seen twice is skipped.
_rd_pattern_hash() {
  local unanchored="$1" starving_csv="$2"
  printf 'unanchored:%s;starving:%s' "$unanchored" "$starving_csv" \
    | shasum -a 1 2>/dev/null | awk '{print $1}' \
    || printf 'unanchored:%s;starving:%s' "$unanchored" "$starving_csv" | md5sum | awk '{print $1}'
}

_rd_decisions_file() {
  local today; today="$(date -u +%Y-%m-%d)"
  printf '%s/curator-decisions/%s.jsonl' "$(_rd_lock_dir)" "$today"
}

# Returns 0 (found) if pattern_hash already recorded today, 1 otherwise.
_rd_already_filed_pattern() {
  local pattern_hash="$1"
  local f; f="$(_rd_decisions_file)"
  [[ -f "$f" ]] || return 1
  grep -q '"decision":"roadmap_drift".*"pattern_hash":"'"$pattern_hash"'"' "$f"
}

_rd_mark_filed_pattern() {
  local pattern_hash="$1" gap_id="$2"
  local f; f="$(_rd_decisions_file)"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  printf '{"decision":"roadmap_drift","pattern_hash":"%s","gap_id":"%s","ts":"%s"}\n' \
    "$pattern_hash" "$gap_id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$f"
}

# curator_roadmap_drift_check — Decision 6. Best-effort: never raises.
# Prints a one-line summary to stdout for the curator's console log.
curator_roadmap_drift_check() {
  if [[ "${CHUMP_CURATOR_ROADMAP_CHECK:-1}" == "0" ]]; then
    echo "Decision 6: roadmap drift check DISABLED (CHUMP_CURATOR_ROADMAP_CHECK=0)"
    return 0
  fi
  command -v chump &>/dev/null || { echo "Decision 6: chump CLI unavailable — skipped"; return 0; }
  command -v python3 &>/dev/null || { echo "Decision 6: python3 unavailable — skipped"; return 0; }
  command -v jq &>/dev/null || { echo "Decision 6: jq unavailable — skipped"; return 0; }

  local roadmap_path; roadmap_path="$(_rd_roadmap_path)"
  local milestones_json; milestones_json="$(_rd_parse_roadmap "$roadmap_path")"

  local gaps_json
  gaps_json="$(chump gap list --status open --json 2>/dev/null || echo '[]')"

  local unanchored_threshold="${CHUMP_ROADMAP_UNANCHORED_THRESHOLD:-3}"
  local starving_threshold="${CHUMP_ROADMAP_STARVING_THRESHOLD:-1}"

  local drift_json
  drift_json="$(python3 - "$unanchored_threshold" "$starving_threshold" <<PY
import json, sys

unanchored_threshold = int(sys.argv[1])
starving_threshold = int(sys.argv[2])

milestones = json.loads('''$milestones_json''')
gaps = json.loads('''$gaps_json''')

anchored_ids = set()
for m in milestones:
    anchored_ids.update(m.get("owning_gap_ids", []))

p1p0 = [g for g in gaps if g.get("priority") in ("P0", "P1")]
p1p0_ids = {g.get("id") for g in p1p0 if g.get("id")}

unanchored = sorted(gid for gid in p1p0_ids if gid not in anchored_ids)

starving = []
for m in milestones:
    if m.get("status") == "done":
        continue
    owning = set(m.get("owning_gap_ids", []))
    if not owning:
        continue  # a milestone with no gap refs at all isn't "starving" — it's unmapped
    if not (owning & p1p0_ids):
        starving.append(m.get("milestone", "")[:120])

drift = len(unanchored) > unanchored_threshold or len(starving) > starving_threshold

print(json.dumps({
    "drift": drift,
    "unanchored_count": len(unanchored),
    "unanchored_ids": unanchored,
    "starving_milestones": starving,
}))
PY
)"

  local drift unanchored_count starving_csv starving_json
  drift="$(echo "$drift_json" | jq -r '.drift')"
  unanchored_count="$(echo "$drift_json" | jq -r '.unanchored_count')"
  starving_json="$(echo "$drift_json" | jq -c '.starving_milestones')"
  starving_csv="$(echo "$drift_json" | jq -r '.starving_milestones | sort | join(",")')"

  if [[ "$drift" != "true" ]]; then
    echo "Decision 6: roadmap drift within bounds (unanchored=${unanchored_count})"
    return 0
  fi

  echo "Decision 6: roadmap drift detected (unanchored=${unanchored_count}, starving=[${starving_csv}])"
  _rd_log_ambient "roadmap_drift_detected" \
    '"unanchored_count":'"$unanchored_count"',"starving_milestones":'"$starving_json"

  local pattern_hash; pattern_hash="$(_rd_pattern_hash "$unanchored_count" "$starving_csv")"

  if _rd_already_filed_pattern "$pattern_hash"; then
    echo "Decision 6: same drift pattern already filed today — dedup skip"
    if declare -F log_curator_decision >/dev/null 2>&1; then
      log_curator_decision "roadmap_drift" \
        "unanchored=${unanchored_count}, starving=[${starving_csv}]" \
        "dedup: same pattern already filed today"
    fi
    return 0
  fi

  if [[ "${CHUMP_CURATOR_DRY_RUN:-0}" == "1" ]]; then
    echo "Decision 6: [dry-run] would file META gap for roadmap drift"
    if declare -F log_curator_decision >/dev/null 2>&1; then
      log_curator_decision "roadmap_drift" \
        "unanchored=${unanchored_count}, starving=[${starving_csv}]" \
        "dry_run: would file META gap"
    fi
    return 0
  fi

  local title="ROADMAP drift: ${unanchored_count} unanchored P0/P1 gap(s), starving=[${starving_csv}]"
  local body
  body="$(cat <<EOF
Auto-filed by curator-opus-roadmap-drift (INFRA-1286).

Unanchored P0/P1 gap count: ${unanchored_count} (threshold: ${unanchored_threshold})
Starving milestones (no pickable P0/P1 progress): ${starving_csv:-none}

These gaps look strategically important (P0/P1) but are not referenced by
any docs/ROADMAP.md milestone, OR a milestone has zero open P0/P1 gaps
backing it. Re-anchor the gaps to a milestone, or update ROADMAP.md if the
milestone has shipped.
EOF
)"
  local out gap_id rc
  out="$(timeout 30 chump gap reserve --domain META --title "$title" --priority P2 --effort s 2>&1)" && rc=0 || rc=$?
  gap_id="$(printf '%s' "$out" | grep -oE '(META|INFRA)-[0-9]+' | head -1)"

  if [[ -n "$gap_id" ]]; then
    echo "Decision 6: filed ${gap_id} for roadmap drift"
    _rd_mark_filed_pattern "$pattern_hash" "$gap_id"
    if declare -F log_curator_decision >/dev/null 2>&1; then
      log_curator_decision "roadmap_drift" \
        "unanchored=${unanchored_count}, starving=[${starving_csv}]" \
        "filed ${gap_id}"
    fi
  else
    echo "Decision 6: roadmap drift gap-file FAILED (rc=${rc:-1})" >&2
    if declare -F log_curator_decision >/dev/null 2>&1; then
      log_curator_decision "roadmap_drift" \
        "unanchored=${unanchored_count}, starving=[${starving_csv}]" \
        "error: chump gap reserve exited ${rc:-1}"
    fi
  fi
}

# Direct-invocation entry point (for the test harness / ad-hoc runs).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-check}" in
    check) curator_roadmap_drift_check ;;
    *) echo "usage: $0 check" >&2; exit 1 ;;
  esac
fi
