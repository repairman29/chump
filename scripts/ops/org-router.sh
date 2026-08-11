#!/usr/bin/env bash
# org-router.sh — route a business intent to the org chair whose job-to-be-done owns it.
# The REVERSE model: need -> classify -> the chair that claims it (mirrors BUILD's gap->worker
# router in chump-coord assign). Reads class/route_keywords/status from org/**/*.md. Keyword
# match here; the production version swaps in an LLM intent classifier on free inference.
intent="$*"
[ -z "$intent" ] && { echo "usage: org-router.sh <intent text>"; exit 1; }
best_f=""; best_cls=""; best_st=""; best_score=0
while IFS= read -r f; do
  cls=$(grep -m1 '^class:' "$f" 2>/dev/null | sed 's/class:[[:space:]]*//'); [ -z "$cls" ] && continue
  st=$(grep -m1 '^status:' "$f" 2>/dev/null | sed 's/status:[[:space:]]*//')
  kws=$(grep -m1 '^route_keywords:' "$f" 2>/dev/null | sed 's/route_keywords:[[:space:]]*//;s/[][]//g')
  score=0; IFS=',' read -ra arr <<< "$kws"
  for kw in "${arr[@]}"; do kw="$(echo "$kw"|sed 's/^ *//;s/ *$//')"; [ -z "$kw" ] && continue
    echo "$intent" | grep -qiF "$kw" && score=$((score+1)); done
  [ "$score" -gt "$best_score" ] && { best_score=$score; best_f="$f"; best_cls="$cls"; best_st="$st"; }
done < <(find org -name '*.md' 2>/dev/null)
echo "intent: \"$intent\""
if [ "$best_score" -gt 0 ]; then
  echo "  -> class=$best_cls  chair=$best_f  (status: $best_st)"
  case "$best_st" in
    *online*) echo "     staffed — a live chair takes it." ;;
    *) echo "     DORMANT — the need routes correctly but nobody's staffed. Activation demanded here." ;;
  esac
else echo "  -> no chair owns this intent yet."; fi
