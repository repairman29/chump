#!/usr/bin/env bash
# scripts/coord/junk-pr-closer.sh — INFRA-8072
#
# Closes open PRs of a retired/no-outcome gap class so they stop piling up DIRTY:
#   (a) doc-wiring busywork   ("EFFECTIVE: wire X into role/curator doc")
#   (b) pillar-starved filler ("MISSION-<pillar>: ... pillar starved")
#   (c) any PR whose backing gap is superseded / already_satisfied
# NEVER closes a PR whose backing gap is still live (non-terminal status) AND
# outcome-linked. Always runs a dry-run classification pass first and emits
# kind=junk_pr_closer_scan with the count; PRs are closed only with --act.
# Closed PRs have no open PR, so the INFRA-8071 branch reaper can then reap them.
#
# Usage: junk-pr-closer.sh [--act] [--max-close N]
# Env (tests): CHUMP_JUNK_PR_FIXTURE=<json of PRs>, CHUMP_JUNK_GAP_FIXTURE=<json of gaps>,
#              CHUMP_AMBIENT_LOG
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/repo-paths.sh"
AMBIENT="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
ACT=0; MAX_CLOSE=60
while [[ $# -gt 0 ]]; do
    case "$1" in
        --act) ACT=1 ;;
        --dry-run) ACT=0 ;;
        --max-close) shift; MAX_CLOSE="$1" ;;
        -h|--help) sed -n 2,16p "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
    shift
done

REPO="${CHUMP_JUNK_PR_REPO:-$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]||; s|\.git$||')}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if [[ -n "${CHUMP_JUNK_PR_FIXTURE:-}" ]]; then
    cp "$CHUMP_JUNK_PR_FIXTURE" "$TMP/prs.json"
else
    [[ -n "$REPO" ]] || { echo "[junk-pr-closer] cannot resolve repo; skipping" >&2; exit 0; }
    gh api --paginate "repos/$REPO/pulls?state=open&per_page=100" \
        --jq '[.[] | {number, title, head_ref: .head.ref}]' 2>/dev/null \
        | python3 -c "import sys,json
out=[]
dec=json.JSONDecoder();s=sys.stdin.read().strip();i=0
while i<len(s):
    o,j=dec.raw_decode(s,i);out+=o;i=j
    while i<len(s) and s[i].isspace(): i+=1
print(json.dumps(out))" > "$TMP/prs.json" || { echo "[junk-pr-closer] gh failed; skipping" >&2; exit 0; }
fi
if [[ -n "${CHUMP_JUNK_GAP_FIXTURE:-}" ]]; then
    cp "$CHUMP_JUNK_GAP_FIXTURE" "$TMP/gaps.json"
else
    chump gap list --json > "$TMP/gaps.json" 2>/dev/null || { echo "[junk-pr-closer] gap list failed; skipping" >&2; exit 0; }
fi

# Emits one TSV line per PR to close: number<TAB>class<TAB>reason<TAB>title
python3 - "$TMP/prs.json" "$TMP/gaps.json" > "$TMP/plan.tsv" <<'PY'
import sys, json, re
prs = json.load(open(sys.argv[1])); gaps = {g["id"]: g for g in json.load(open(sys.argv[2]))}
TERMINAL_SUPERSEDED = {"superseded", "already_satisfied"}
LIVE = {"open", "in_progress", "in-progress", "in_review", "in_flight", "ready_to_ship", "blocked", "decomposed", "perpetual"}
WIRE = re.compile(r"\bwire\b.+\binto\b.+\b(role|curator|agents?)\b", re.I)
STARVED = re.compile(r"pillar[- ]starved", re.I)
for pr in prs:
    title = pr.get("title", "")
    m = re.search(r"\b[A-Z][A-Z0-9]*-\d+\b", title)
    gap = gaps.get(m.group(0)) if m else None
    if gap and gap.get("status") in LIVE and gap.get("outcome_id"):
        continue  # protected: live, outcome-linked gap
    cls = None
    if gap and gap.get("status") in TERMINAL_SUPERSEDED:
        cls, why = "gap-" + gap["status"], f"its backing gap {gap['id']} is {gap['status']}"
    elif STARVED.search(title):
        cls, why = "pillar-starved", "it is a retired 'pillar starved' filler-gap PR (no outcome)"
    elif WIRE.search(title):
        cls, why = "doc-wiring", "it is a retired 'wire X into role doc' busywork PR (no outcome)"
    if cls:
        print(f"{pr['number']}\t{cls}\t{why}\t{title.replace(chr(9), ' ')}")
PY

COUNT="$(wc -l < "$TMP/plan.tsv" | tr -d ' ')"
TOTAL="$(python3 -c "import json;print(len(json.load(open('$TMP/prs.json'))))")"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[junk-pr-closer] dry-run: $COUNT of $TOTAL open PR(s) match a junk class (mode=$([[ $ACT -eq 1 ]] && echo act || echo dry-run))"
cut -f1,2,4 "$TMP/plan.tsv" | sed 's/^/[junk-pr-closer]   would close #/'
printf '{"ts":"%s","kind":"junk_pr_closer_scan","candidates":%s,"open_prs":%s,"act":%s}\n' \
    "$TS" "$COUNT" "$TOTAL" "$ACT" >> "$AMBIENT" 2>/dev/null || true
[[ "$ACT" -eq 1 && "$COUNT" -gt 0 ]] || exit 0

CLOSED=0
while IFS=$'\t' read -r num cls why _title; do
    [[ "$CLOSED" -lt "$MAX_CLOSE" ]] || { echo "[junk-pr-closer] --max-close $MAX_CLOSE reached; rest deferred to next run"; break; }
    body="Auto-closed by junk-pr-closer (INFRA-8072): $why. Reopen if this was closed in error."
    gh api "repos/$REPO/issues/$num/comments" -X POST -f body="$body" --silent 2>/dev/null \
        || echo "[junk-pr-closer] WARN: comment on #$num failed" >&2
    if gh api "repos/$REPO/pulls/$num" -X PATCH -f state=closed --silent 2>/dev/null; then
        CLOSED=$((CLOSED+1))
        printf '{"ts":"%s","kind":"junk_pr_closed","pr":%s,"class":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$num" "$cls" >> "$AMBIENT" 2>/dev/null || true
        echo "[junk-pr-closer] closed #$num ($cls)"
    else
        echo "[junk-pr-closer] WARN: close #$num failed" >&2
    fi
done < "$TMP/plan.tsv"
echo "[junk-pr-closer] closed $CLOSED PR(s)"
