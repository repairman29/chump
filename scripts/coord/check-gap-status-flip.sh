#!/usr/bin/env bash
#
# INFRA-066 — assert that PRs whose title is "<GAP-ID>: ..." have flipped
# the gap to status: done in the gap registry. QUALITY-005 audit (2026-04-25)
# found 7 of 31 "open" gaps had already shipped on main without the flip;
# this guard closes that loop.
#
# INFRA-188 — updated to support per-file docs/gaps/<ID>.yaml layout
# (canonical post-cutover). Falls back to monolithic docs/gaps.yaml for
# backward compatibility during the transition.
#
# Usage: check-gap-status-flip.sh "<PR_TITLE>" [<gaps.yaml path or gaps/ dir>]
#
# Exit codes:
#   0 — no gap-id prefix in title (skip), or gap is done, or pre-commit
#       guards already cover the case (gap already done before this PR)
#   1 — title implies close, but gap is still status: open in registry
#
# Bypass at workflow level via the `gap-cleanup` label (handled in the
# GitHub Actions `if:` filter, not here).

set -euo pipefail

PR_TITLE="${1:-}"
GAPS_ARG="${2:-}"

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

# INFRA-188: resolve the gap's status from either per-file or monolithic layout.
status=""

# 1. Try per-file layout: docs/gaps/<ID>.yaml
# Only auto-detect docs/gaps/ when no explicit argument was provided.
# An explicit file argument always routes through the monolithic path below.
PER_FILE_PATH=""
if [[ -n "$GAPS_ARG" && -d "$GAPS_ARG" ]]; then
  # Explicit directory argument → per-file in that directory.
  PER_FILE_PATH="${GAPS_ARG%/}/${GAP_ID}.yaml"
elif [[ -z "$GAPS_ARG" && -d "docs/gaps" ]]; then
  # No argument → auto-detect per-file layout from CWD.
  PER_FILE_PATH="docs/gaps/${GAP_ID}.yaml"
fi

if [[ -n "$PER_FILE_PATH" && -f "$PER_FILE_PATH" ]]; then
  # Parse status from per-file YAML (field at 2-space indent, per format_gap_yaml)
  status=$(awk '/^  status:/ { sub(/^  status:[[:space:]]*/, ""); print; exit }' "$PER_FILE_PATH")
  echo "Reading from per-file layout: $PER_FILE_PATH"
fi

# 2. Fall back to monolithic docs/gaps.yaml
if [[ -z "$status" ]]; then
  GAPS_FILE="${GAPS_ARG:-docs/gaps.yaml}"
  if [[ -f "$GAPS_FILE" ]]; then
    gap_block=$(awk -v id="$GAP_ID" '
      $0 == "- id: " id { found = 1; print; next }
      found && /^- id: / { exit }
      found { print }
    ' "$GAPS_FILE")
    if [[ -n "$gap_block" ]]; then
      status=$(echo "$gap_block" | awk '/^[[:space:]]*status:/ { sub(/^[[:space:]]*status:[[:space:]]*/, ""); print; exit }')
      echo "Reading from monolithic layout: $GAPS_FILE"
    fi
  fi
fi

if [[ -z "$status" ]]; then
  # Could be a brand-new gap filed in this PR — accept it.
  echo "::notice::$GAP_ID not found in gap registry — assumed new entry filed by this PR (acceptable)."
  exit 0
fi

case "$status" in
  done)
    echo "::notice::$GAP_ID has status: done — guard satisfied."
    exit 0
    ;;
  open)
    cat <<EOF >&2
::error::Gap status drift — PR title implies close but gap is still open.

  PR title: $PR_TITLE
  Gap ID:   $GAP_ID
  Status:   open

QUALITY-005 audit (2026-04-25) found 7 of 31 "open" gaps had already shipped
on main without the status flip — a 22.6% stale-status rate. This guard
catches that drift before it lands.

Fix one of:
  (a) Run: chump gap ship $GAP_ID --closed-pr <PR-NUMBER> --update-yaml
      then add docs/gaps/${GAP_ID}.yaml to your commit.
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
