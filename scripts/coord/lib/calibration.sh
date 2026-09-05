#!/usr/bin/env bash
# scripts/coord/lib/calibration.sh — RESILIENT-974 (RESILIENT-422 slice)
#
# Generic Brier-score calibration component, extracted from the PR-merge-bet
# settle logic in scripts/coord/pr-book.sh (INFRA-1688 lineage). PR-merge bets
# were the first "this-will-break-to-P0" call this fleet scored — this lib
# lets ANY other prediction domain (incident-recall bets, gap-ship-success
# forecasts, NBA-engine risk calls, ...) reuse the same join+score+log
# machinery instead of re-deriving jq by hand.
#
# Source it:
#   source "$(dirname "$0")/lib/calibration.sh"
#
# API:
#   calibration_settle <ledger> <outcomes_map_json> <calib_out> <id_key> \
#                       <price_key> <prediction_kind> <summary_kind>
#     ledger            path to an append-only JSONL file; each line is a
#                       prediction record with at least {<id_key>, <price_key>}
#                       (later lines for the same id supersede earlier ones —
#                       "latest prediction wins", same as pr-book.sh)
#     outcomes_map_json JSON object mapping id (as string) -> 0 or 1
#                       (omit an id to leave it unresolved / excluded)
#     calib_out         path to (re)write the calibration log to — REWRITTEN
#                       (not appended) so repeat settles don't double-count
#     id_key            JSON field name identifying each prediction (e.g. "pr")
#     price_key         JSON field name holding the predicted probability
#                       (e.g. "price")
#     prediction_kind   "kind" value stamped on each per-prediction row
#     summary_kind      "kind" value stamped on the trailing summary row
#
#     stdout: a single JSON object —
#       {rows, predictions, resolved, matched:N, unmatched:N, brier}
#     (rows/predictions/resolved/brier mirror the shape pr-book.sh already
#     printed; matched/unmatched count outcome==1 / outcome==0 generically —
#     callers that want domain labels like "merged"/"closed" can derive them
#     from the outcome value themselves.)
#
#     Returns 0 always (an empty/no-op ledger yields brier:null, not a
#     failure) — callers decide what "nothing to settle" means for them.
calibration_settle() {
  local ledger="$1" outcomes_json="$2" calib_out="$3" id_key="$4" \
        price_key="$5" pred_kind="$6" summary_kind="$7"
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [[ ! -s "$ledger" ]]; then
    jq -cn --arg ts "$ts" --arg kind "$summary_kind" \
      '{rows:[], predictions:0, resolved:0, matched:0, unmatched:0, brier:null}'
    return 0
  fi

  local res
  res="$(jq -n --slurpfile L "$ledger" --argjson O "$outcomes_json" --arg ts "$ts" \
    --arg idk "$id_key" --arg pk "$price_key" --arg pkind "$pred_kind" '
    ($L | reduce .[] as $r ({}; .[($r[$idk]|tostring)] = $r)) as $latest
    | [ $latest[] | (.[$idk]|tostring) as $kk
        | select($O[$kk] != null)
        | {ts:$ts, kind:$pkind}
          + {($idk): .[$idk]}
          + {predicted:.[$pk], outcome:$O[$kk]} ]
      as $rows
    | ($rows | map((.predicted-.outcome)*(.predicted-.outcome))) as $sq
    | { rows: $rows,
        predictions: ($latest|length),
        resolved: ($rows|length),
        matched:   ([ $rows[] | select(.outcome==1) ] | length),
        unmatched: ([ $rows[] | select(.outcome==0) ] | length),
        brier: (if ($sq|length)>0 then (((($sq|add)/($sq|length))*10000)|round)/10000 else null end) }')"

  local tmp_cal
  tmp_cal="$(mktemp "${TMPDIR:-/tmp}/calib.XXXXXX" 2>/dev/null)" || tmp_cal="$calib_out.tmp.$$"
  echo "$res" | jq -c '.rows[]' > "$tmp_cal"
  echo "$res" | jq -c --arg ts "$ts" --arg kind "$summary_kind" \
    '{ts:$ts, kind:$kind, brier:.brier, n:.resolved, matched:.matched, unmatched:.unmatched}' >> "$tmp_cal"
  mv -f "$tmp_cal" "$calib_out"

  echo "$res"
}
