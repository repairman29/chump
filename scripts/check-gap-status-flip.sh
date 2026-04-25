#!/usr/bin/env bash
#
# INFRA-066 — assert that PRs whose title is "<GAP-ID>: ..." have flipped
# the gap to status: done in docs/gaps.yaml. QUALITY-005 audit (2026-04-25)
# found 7 of 31 "open" gaps had already shipped on main without the flip;
# this guard closes that loop.
#
# Usage: check-gap-status-flip.sh "<PR_TITLE>" <gaps.yaml path>
#
# Exit codes:
#   0 — no gap-id prefix in title (skip), or gap is done, or pre-commit
#       guards already cover the case (gap already done before this PR)
#   1 — title implies close, but gap is still status: open in gaps.yaml
#
# Bypass at workflow level via the `gap-cleanup` label (handled in the
# GitHub Actions `if:` filter, not here).

set -euo pipefail

PR_TITLE="${1:-}"
GAPS_FILE="${2:-docs/gaps.yaml}"

if [[ -z "$PR_TITLE" ]]; then
  echo "::notice::No PR title provided — skipping gap-status check."
  exit 0
fi

# Match titles like "INFRA-047: foo", "EVAL-083: bar", "QUALITY-004: baz".
# Domain is letters; ID is digits. Underscore-titles like "infra(BUG): …" don't match.
if [[ ! "$PR_TITLE" =~ ^([A-Z]+)-([0-9]+): ]]; then
  echo "::notice::PR title does not start with '<DOMAIN>-<NUMBER>:' — skipping."
  exit 0
fi

GAP_ID="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
echo "Detected gap reference in PR title: $GAP_ID"

if [[ ! -f "$GAPS_FILE" ]]; then
  echo "::error::gaps file '$GAPS_FILE' missing in checkout — cannot verify status."
  exit 1
fi

# Find the gap's status field. We grep for the entry, then extract status:
# from its body (the first 'status:' after the matching '- id:' line).
gap_block=$(awk -v id="$GAP_ID" '
  $0 == "- id: " id { found = 1; print; next }
  found && /^- id: / { exit }
  found { print }
' "$GAPS_FILE")

if [[ -z "$gap_block" ]]; then
  # Could be a brand-new gap filed in this PR — accept it. The pre-commit
  # gaps.yaml-discipline guards already block hijacks/duplicates.
  echo "::notice::$GAP_ID not found in gaps.yaml — assumed new entry filed by this PR (acceptable)."
  exit 0
fi

status=$(echo "$gap_block" | awk '/^[[:space:]]*status:/ { sub(/^[[:space:]]*status:[[:space:]]*/, ""); print; exit }')

case "$status" in
  done)
    echo "::notice::$GAP_ID has status: done — guard satisfied."
    exit 0
    ;;
  open)
    cat <<EOF >&2
::error::Gap status drift — PR title implies close but gaps.yaml is still open.

  PR title: $PR_TITLE
  Gap ID:   $GAP_ID
  Status:   open

QUALITY-005 audit (2026-04-25) found 7 of 31 "open" gaps had already shipped
on main without the YAML status flip — a 22.6% stale-status rate. This guard
catches that drift before it lands.

Fix one of:
  (a) Edit $GAPS_FILE: change status: open -> status: done for $GAP_ID
      and add closed_date + closed_pr fields, then push.
  (b) If this PR references but does not close $GAP_ID, change the PR
      title prefix (e.g. "fix($GAP_ID-area): …" or drop the "<ID>:"
      prefix) so the guard knows it isn't a close.
  (c) If this is a legitimate exception (e.g. a multi-PR sequence where
      the close happens elsewhere), add the gap-cleanup label to bypass.

EOF
    exit 1
    ;;
  *)
    echo "::warning::$GAP_ID has unexpected status: '$status' — accepting but flagging."
    exit 0
    ;;
esac
