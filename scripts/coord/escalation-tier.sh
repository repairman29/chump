#!/usr/bin/env bash
# escalation-tier.sh — INFRA-1890
#
# Detector escalation tier: when the same ambient signature fires N times
# in M hours without resolution, auto-file ONE follow-up gap. Turns silent
# detectors (gap_failed, pr_auto_rebase_failed, dirty_pr_unresolvable, ...)
# into actionable gaps instead of noise nobody reads.
#
# Rule set (seeded from the 2026-05-23 triage scan):
#   (a) kind=gap_failed, same gap_id >=10x in 24h, gap still open, and no
#       commit referencing the gap id since the first event → file a gap.
#   (b) kind=pr_auto_rebase_failed, same PR >=3x in 24h, PR still DIRTY
#       → file a gap.
#   (c) kind=dirty_pr_unresolvable, same conflict file across >=3 distinct
#       PRs in 24h → file a "hot-file" contention gap.
#   (d) any event kind that looks like a repeated failure signature but
#       matches no rule above → emit kind=escalation_uncategorized and log
#       to .chump/triage/uncategorized.jsonl for operator review only.
#
# Every candidate filing passes two gates before `chump gap reserve` runs:
#   1. Dedup: SHA256(normalize(title)) against a local seen-file, PLUS a
#      `chump gap list --status open --grep <keyword>` sweep. Any match →
#      kind=escalation_dedup_hit, no filing.
#   2. META-063 redundancy: token-overlap similarity of the candidate title
#      against every open gap title. >= threshold → kind=escalation_meta063_blocked,
#      no filing.
#
# Env overrides (test seams):
#   CHUMP_AMBIENT_LOG            — path to ambient.jsonl (default .chump-locks/ambient.jsonl)
#   CHUMP_ESCALATION_STATE_DIR   — dir for seen-file + suppressions (default .chump)
#   CHUMP_ESCALATION_WINDOW_H    — lookback window hours (default 24)
#   CHUMP_ESCALATION_DRY_RUN     — 1 = compute + log, never call `chump gap reserve`
#   CHUMP_BIN                    — chump binary override (default resolved via PATH)
#   CHUMP_ESCALATION_SIM_THRESHOLD — redundancy-gate threshold (default 0.7)
#
# Suppression: .chump/escalation-suppressions.json — {"<rule_id>": {"suppressed_at":..,"reason":..}}
#   Managed via `chump fleet escalation --suppress-rule <id> --reason "..."`.
#
# All kinds below are built dynamically in emit_ambient() (single call
# site, kind passed as a variable) — these anchors keep the EVENT_REGISTRY
# drift gate's static scanner honest about what this file actually emits.
# scanner-anchor: "kind":"escalation_fired"
# scanner-anchor: "kind":"escalation_dedup_hit"
# scanner-anchor: "kind":"escalation_meta063_blocked"
# scanner-anchor: "kind":"escalation_uncategorized"
# scanner-anchor: "kind":"escalation_rule_suppressed"

set -uo pipefail

REPO_ROOT="${CHUMP_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE_DIR="${CHUMP_ESCALATION_STATE_DIR:-$REPO_ROOT/.chump}"
WINDOW_H="${CHUMP_ESCALATION_WINDOW_H:-24}"
DRY_RUN="${CHUMP_ESCALATION_DRY_RUN:-0}"
SIM_THRESHOLD="${CHUMP_ESCALATION_SIM_THRESHOLD:-0.7}"
SEEN_FILE="$STATE_DIR/escalation-seen.jsonl"
SUPPRESSIONS_FILE="$STATE_DIR/escalation-suppressions.json"
TRIAGE_DIR="$STATE_DIR/triage"
UNCATEGORIZED_FILE="$TRIAGE_DIR/uncategorized.jsonl"

mkdir -p "$STATE_DIR" "$TRIAGE_DIR" "$(dirname "$AMBIENT")" 2>/dev/null || true
touch "$SEEN_FILE" "$AMBIENT" 2>/dev/null || true
[[ -f "$SUPPRESSIONS_FILE" ]] || echo '{}' > "$SUPPRESSIONS_FILE"

_chump="${CHUMP_BIN:-}"
if [[ -z "$_chump" ]]; then
    _chump="${HOME}/.cargo/bin/chump"
    command -v "$_chump" >/dev/null 2>&1 || _chump="chump"
fi

emit_ambient() {
    local kind="$1"; shift
    local extra="${1:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    local payload
    if [[ -n "$extra" ]]; then
        payload="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"source\":\"escalation-tier\",$extra}"
    else
        payload="{\"ts\":\"$ts\",\"kind\":\"$kind\",\"source\":\"escalation-tier\"}"
    fi
    echo "$payload" >> "$AMBIENT" 2>/dev/null || true
    echo "[escalation-tier] $payload"
}

rule_suppressed() {
    local rule_id="$1"
    python3 -c "
import json, sys
try:
    d = json.load(open('$SUPPRESSIONS_FILE'))
except Exception:
    sys.exit(1)
sys.exit(0 if '$rule_id' in d else 1)
" 2>/dev/null
}

# normalize(title) -> lowercase, strip non-alnum runs to single space, trim
normalize_title() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' ' ' | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

title_hash() {
    normalize_title "$1" | sha256sum | awk '{print $1}'
}

# Jaccard-ish token overlap between two titles, 0..1
title_similarity() {
    python3 -c "
a = set('$(normalize_title "$1")'.split())
b = set('$(normalize_title "$2")'.split())
if not a or not b:
    print(0.0)
else:
    print(len(a & b) / len(a | b))
"
}

# Returns 0 (found) if title_hash already in SEEN_FILE.
seen_locally() {
    local h="$1"
    grep -q "\"title_hash\":\"$h\"" "$SEEN_FILE" 2>/dev/null
}

# File the gap if it clears dedup + redundancy gates. Args: rule_id title priority effort
try_file_gap() {
    local rule_id="$1" title="$2" priority="${3:-P1}" effort="${4:-s}"

    if rule_suppressed "$rule_id"; then
        emit_ambient "escalation_rule_suppressed" "\"rule_id\":\"$rule_id\""
        return 0
    fi

    local h; h="$(title_hash "$title")"

    # Gate 1: dedup (local seen-file + live open-gap grep).
    if seen_locally "$h"; then
        emit_ambient "escalation_dedup_hit" "\"rule_id\":\"$rule_id\",\"reason\":\"local_seen\""
        return 0
    fi
    local keyword
    keyword="$(normalize_title "$title" | awk '{print $1, $2, $3}')"
    local grep_out
    grep_out="$("$_chump" gap list --status open --grep "$keyword" 2>/dev/null || true)"
    if [[ -n "$grep_out" ]]; then
        local matched_gap_id
        matched_gap_id="$(printf '%s\n' "$grep_out" | head -1 | grep -oE '[A-Z]+-[0-9]+' | head -1)"
        emit_ambient "escalation_dedup_hit" "\"rule_id\":\"$rule_id\",\"matched_gap_id\":\"${matched_gap_id:-unknown}\""
        printf '{"title_hash":"%s","rule_id":"%s"}\n' "$h" "$rule_id" >> "$SEEN_FILE"
        return 0
    fi

    # Gate 2: META-063 redundancy — token-overlap vs every open gap title.
    local open_titles
    open_titles="$("$_chump" gap list --status open 2>/dev/null || true)"
    local best_sim="0.0" best_gap=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local gid otitle sim
        gid="$(printf '%s' "$line" | grep -oE '[A-Z]+-[0-9]+' | head -1)"
        [[ -z "$gid" ]] && continue
        otitle="$(printf '%s' "$line" | sed -E 's/^\[[a-z_]+\] +[A-Z]+-[0-9]+ +— +//')"
        sim="$(title_similarity "$title" "$otitle")"
        if python3 -c "exit(0 if $sim >= $best_sim else 1)" 2>/dev/null; then
            best_sim="$sim"
            best_gap="$gid"
        fi
    done <<< "$open_titles"
    if python3 -c "exit(0 if $best_sim >= $SIM_THRESHOLD else 1)" 2>/dev/null; then
        emit_ambient "escalation_meta063_blocked" "\"rule_id\":\"$rule_id\",\"matched_gap_id\":\"$best_gap\",\"similarity\":$best_sim"
        printf '{"title_hash":"%s","rule_id":"%s"}\n' "$h" "$rule_id" >> "$SEEN_FILE"
        return 0
    fi

    # Clear to file.
    if [[ "$DRY_RUN" == "1" ]]; then
        emit_ambient "escalation_fired" "\"rule_id\":\"$rule_id\",\"gap_id_filed\":\"DRY_RUN\",\"dedup_checks_passed\":true"
        printf '{"title_hash":"%s","rule_id":"%s"}\n' "$h" "$rule_id" >> "$SEEN_FILE"
        return 0
    fi

    local reserve_out gap_id
    reserve_out="$("$_chump" gap reserve --domain INFRA --title "$title" --priority "$priority" --effort "$effort" 2>&1)"
    gap_id="$(printf '%s\n' "$reserve_out" | grep -oE '[A-Z]+-[0-9]+' | head -1)"
    if [[ -z "$gap_id" ]]; then
        echo "[escalation-tier] WARN: gap reserve for rule=$rule_id did not return a gap id: $reserve_out" >&2
        return 1
    fi
    printf '{"title_hash":"%s","rule_id":"%s","gap_id":"%s"}\n' "$h" "$rule_id" "$gap_id" >> "$SEEN_FILE"
    emit_ambient "escalation_fired" "\"rule_id\":\"$rule_id\",\"gap_id_filed\":\"$gap_id\",\"dedup_checks_passed\":true"
}

window_cutoff_epoch() {
    python3 -c "
import datetime
print(int((datetime.datetime.utcnow() - datetime.timedelta(hours=$WINDOW_H)).timestamp()))
"
}

CUTOFF="$(window_cutoff_epoch)"

events_in_window() {
    local kind="$1"
    python3 -c "
import json, sys, datetime
cutoff = $CUTOFF
try:
    f = open('$AMBIENT')
except Exception:
    sys.exit(0)
for line in f:
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    if e.get('kind') != '$kind':
        continue
    ts = e.get('ts', '')
    try:
        t = datetime.datetime.strptime(ts, '%Y-%m-%dT%H:%M:%SZ').timestamp()
    except Exception:
        continue
    if t >= cutoff:
        print(json.dumps(e))
"
}

# ── Rule (a): gap_failed same gap_id >=10x in 24h, still open, no recovery ──
rule_gap_failed() {
    local rule_id="gap_failed_stuck"
    rule_suppressed "$rule_id" && { emit_ambient "escalation_rule_suppressed" "\"rule_id\":\"$rule_id\""; return 0; }

    python3 -c "
import json, collections
counts = collections.Counter()
first_ts = {}
for line in '''$(events_in_window gap_failed)'''.splitlines():
    if not line.strip():
        continue
    e = json.loads(line)
    gid = e.get('gap_id')
    if not gid:
        continue
    counts[gid] += 1
    if gid not in first_ts or e.get('ts','') < first_ts[gid]:
        first_ts[gid] = e.get('ts','')
for gid, n in counts.items():
    if n >= 10:
        print(f'{gid}\t{n}\t{first_ts[gid]}')
" | while IFS=$'\t' read -r gap_id count first_ts; do
        [[ -z "$gap_id" ]] && continue
        local show_out
        show_out="$("$_chump" gap show "$gap_id" 2>/dev/null || true)"
        if ! grep -qi 'status.*open' <<< "$show_out"; then
            continue
        fi
        local commit_count
        commit_count="$(git -C "$REPO_ROOT" log --all --since="$first_ts" --grep="$gap_id" --oneline 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "${commit_count:-0}" -ne 0 ]]; then
            continue
        fi
        try_file_gap "$rule_id" "RESILIENT: $gap_id stuck — $count gap_failed events without recovery" "P1" "s"
    done
}

# ── Rule (b): pr_auto_rebase_failed same PR >=3x in 24h, still DIRTY ───────
rule_pr_auto_rebase_failed() {
    local rule_id="pr_auto_rebase_stuck"
    rule_suppressed "$rule_id" && { emit_ambient "escalation_rule_suppressed" "\"rule_id\":\"$rule_id\""; return 0; }

    python3 -c "
import json, collections
counts = collections.Counter()
for line in '''$(events_in_window pr_auto_rebase_failed)'''.splitlines():
    if not line.strip():
        continue
    e = json.loads(line)
    pr = e.get('pr')
    if pr is None:
        continue
    counts[str(pr)] += 1
for pr, n in counts.items():
    if n >= 3:
        print(f'{pr}\t{n}')
" | while IFS=$'\t' read -r pr count; do
        [[ -z "$pr" ]] && continue
        local merge_state=""
        if command -v gh >/dev/null 2>&1; then
            merge_state="$(gh pr view "$pr" --json mergeStateStatus -q .mergeStateStatus 2>/dev/null || true)"
        fi
        if [[ "$merge_state" != "DIRTY" ]]; then
            continue
        fi
        try_file_gap "$rule_id" "RESILIENT: PR #$pr stuck rebasing — $count pr_auto_rebase_failed events without recovery" "P1" "s"
    done
}

# ── Rule (c): dirty_pr_unresolvable same conflict file across >=3 PRs ──────
rule_dirty_pr_unresolvable() {
    local rule_id="hot_file_contention"
    rule_suppressed "$rule_id" && { emit_ambient "escalation_rule_suppressed" "\"rule_id\":\"$rule_id\""; return 0; }

    python3 -c "
import json, collections
file_prs = collections.defaultdict(set)
for line in '''$(events_in_window dirty_pr_unresolvable)'''.splitlines():
    if not line.strip():
        continue
    e = json.loads(line)
    pr = e.get('pr')
    files = e.get('conflict_files', '') or e.get('unresolvable', '')
    if not pr or not files:
        continue
    for f in str(files).split():
        file_prs[f].add(str(pr))
for f, prs in file_prs.items():
    if len(prs) >= 3:
        print(f'{f}\t{len(prs)}')
" | while IFS=$'\t' read -r path n; do
        [[ -z "$path" ]] && continue
        try_file_gap "$rule_id" "RESILIENT: hot-file $path blocking $n PRs — rebase contention pattern" "P1" "s"
    done
}

# ── Rule (d): novel/uncategorized failure-shaped kinds ─────────────────────
rule_uncategorized() {
    local known="gap_failed pr_auto_rebase_failed dirty_pr_unresolvable"
    python3 -c "
import json, collections
known = set('$known'.split())
counts = collections.Counter()
cutoff = $CUTOFF
import datetime
try:
    f = open('$AMBIENT')
except Exception:
    raise SystemExit
for line in f:
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    kind = e.get('kind', '')
    if not kind or kind in known or not kind.endswith(('_failed', '_stuck', '_unresolvable')):
        continue
    ts = e.get('ts', '')
    try:
        t = datetime.datetime.strptime(ts, '%Y-%m-%dT%H:%M:%SZ').timestamp()
    except Exception:
        continue
    if t >= cutoff:
        counts[kind] += 1
for kind, n in counts.items():
    if n >= 10:
        print(kind)
" | while IFS= read -r kind; do
        [[ -z "$kind" ]] && continue
        local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '{"ts":"%s","kind":"%s","note":"no escalation rule defined"}\n' "$ts" "$kind" >> "$UNCATEGORIZED_FILE" 2>/dev/null || true
        emit_ambient "escalation_uncategorized" "\"signature_kind\":\"$kind\""
    done
}

main() {
    rule_gap_failed
    rule_pr_auto_rebase_failed
    rule_dirty_pr_unresolvable
    rule_uncategorized
}

main "$@"
