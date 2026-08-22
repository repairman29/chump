#!/usr/bin/env bash
# pr-book.sh — the PR casino book. "Manage PRs like it's your life." (INFRA-1688 lineage;
# sibling to race-control.sh which classifies the work-MIX; this prices the ODDS + EV.)
# Prices every open PR P(merge) via pr-book-model.jq (inspectable), names the cheapest EV-raising
# action, prints portfolio EV + bands, and appends each prediction to ~/.chump/pr-book-ledger.jsonl
# for SETTLEMENT (calibration). Run --settle to score resolved bets against the ledger.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; M="$(cat "$DIR/pr-book-model.jq")"
LEDGER="$HOME/.chump/pr-book-ledger.jsonl"; mkdir -p "$HOME/.chump"; TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RAW=$(gh pr list --state open --limit 40 --json number,title,mergeStateStatus,createdAt,isDraft,statusCheckRollup,headRefOid 2>/dev/null)
echo "== PR BOOK  $TS =="
printf "  %-6s %-4s %-8s %-2s %-4s %-22s %s\n" PR P MERGE F AGE ACTION TITLE
echo "$RAW" | jq -r "$M"' [.[]|{n:.number,p:((price*100)|floor),ms:.mergeStateStatus,f:(fails|length),a:(age|floor),act:action,t:(.title[0:38])}]|sort_by(-.p)|.[]|"\(.n)\t\(.p)\t\(.ms)\t\(.f)\t\(.a)\t\(.act)\t\(.t)"' 2>/dev/null | \
  while IFS=$'\t' read -r n p ms f a act t; do printf "  #%-5s %-4s %-8s %-2s %-4s %-22s %s\n" "$n" "${p}%" "$ms" "$f" "$a" "$act" "$t"; done
EV=$(echo "$RAW" | jq "$M"' [.[]|price]|add' 2>/dev/null); N=$(echo "$RAW" | jq 'length' 2>/dev/null)
printf "  -- EV %.1f of %s open  |  " "${EV:-0}" "${N:-0}"
echo "$RAW" | jq -r "$M"' "lock>=70:"+([.[]|select(price>=0.70)]|length|tostring)+" flip:"+([.[]|select(price>=0.40 and price<0.70)]|length|tostring)+" long<40:"+([.[]|select(price<0.40)]|length|tostring)' 2>/dev/null
echo "$RAW" | jq -c "$M"' .[]|{ts:"'"$TS"'",pr:.number,sha:.headRefOid,price:(price),state:.mergeStateStatus}' 2>/dev/null >> "$LEDGER"
