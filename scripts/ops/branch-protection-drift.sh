#!/usr/bin/env bash
# branch-protection-drift.sh — INFRA-121
#
# Detect drift between the live `main` branch-protection config on GitHub and
# the checked-in baseline at docs/baselines/branch-protection-main.json.
#
# Why: auto-merge ("auto-merge IS the default", CLAUDE.md) is load-bearing,
# but it silently disarms when required-check names change, contexts get
# added/removed, or the branch-protection rule is altered in the GitHub UI.
# The original "merge queue" framing in MERGE_QUEUE_SETUP.md is aspirational —
# what actually keeps PRs landing today is this branch-protection rule and
# its three required checks (`test`, `audit`, ACP smoke test). Drift here is
# the silent failure mode INFRA-121 is closing.
#
# What this does:
#   - Fetches the current rule via `gh api repos/<repo>/branches/main/protection`.
#   - Strips derived URL fields (`url`, `contexts_url`) and sorts keys so the
#     diff is purely semantic.
#   - Diffs against docs/baselines/branch-protection-main.json.
#   - On drift: emits ALERT kind=queue_config_drift to ambient.jsonl with the
#     field-level diff and writes a record to .chump/health.jsonl.
#   - On clean: writes an "ok" record to .chump/health.jsonl (matches
#     queue-health-monitor.sh quiet-on-healthy convention).
#
# Usage:
#   scripts/ops/branch-protection-drift.sh             # live run
#   scripts/ops/branch-protection-drift.sh --dry-run   # show diff; no writes
#   scripts/ops/branch-protection-drift.sh --quiet     # suppress stdout (launchd)
#   scripts/ops/branch-protection-drift.sh --update-baseline
#                                                     # overwrite baseline with
#                                                     # current live config
#                                                     # (use after an INTENTIONAL
#                                                     # config change — commit
#                                                     # the new baseline so the
#                                                     # detector goes quiet again)
#
# Environment:
#   BRANCH_PROTECTION_REPO   repo for `gh api` (default: derived from origin)
#   BRANCH_PROTECTION_BRANCH protected branch (default: main)
#   BRANCH_PROTECTION_BASELINE  override baseline path
#
# Exit codes:
#   0  clean OR drift detected and written (script always succeeds so launchd
#      doesn't restart-spam — drift is signalled via ALERT, not exit code).
#   2  invocation error (gh missing, baseline missing, can't reach API).

set -euo pipefail

DRY_RUN=0
QUIET=0
UPDATE_BASELINE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --quiet)   QUIET=1; shift ;;
        --update-baseline) UPDATE_BASELINE=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
CHUMP_DIR="$MAIN_REPO/.chump"
HEALTH_JSONL="$CHUMP_DIR/health.jsonl"
ALERTS_LOG="$CHUMP_DIR/alerts.log"
EMIT="$MAIN_REPO/scripts/dev/ambient-emit.sh"
BASELINE="${BRANCH_PROTECTION_BASELINE:-$REPO_ROOT/docs/baselines/branch-protection-main.json}"

mkdir -p "$CHUMP_DIR"

say()  { [[ "$QUIET" -eq 1 ]] || printf '\033[1;36m[branch-protection-drift]\033[0m %s\n' "$*"; }
warn() { [[ "$QUIET" -eq 1 ]] || printf '\033[1;33m[branch-protection-drift]\033[0m %s\n' "$*" >&2; }
die()  { warn "$*"; exit 2; }

command -v gh >/dev/null || die "gh CLI not found"
command -v python3 >/dev/null || die "python3 not found"

# Resolve repo (owner/name).
REPO="${BRANCH_PROTECTION_REPO:-}"
if [[ -z "$REPO" ]]; then
    ORIGIN_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
    REPO="$(printf '%s' "$ORIGIN_URL" | python3 -c '
import sys, re
url = sys.stdin.read().strip()
m = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?/?$", url)
print(m.group(1) if m else "")
')"
fi
[[ -n "$REPO" ]] || die "could not derive repo (set BRANCH_PROTECTION_REPO=owner/name)"
BRANCH="${BRANCH_PROTECTION_BRANCH:-main}"

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

say "fetching branch protection for $REPO:$BRANCH ..."
RAW_LIVE="$(gh api "repos/$REPO/branches/$BRANCH/protection" 2>/dev/null || true)"
if [[ -z "$RAW_LIVE" ]] || ! printf '%s' "$RAW_LIVE" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    die "could not fetch live branch protection (gh auth? rule deleted?)"
fi

# Normalize: strip derived URL fields, sort keys.
NORMALIZE_PY='
import json, sys
def strip(o):
    if isinstance(o, dict):
        return {k: strip(v) for k, v in o.items() if k not in ("url", "contexts_url")}
    if isinstance(o, list):
        return [strip(x) for x in o]
    return o
data = json.load(sys.stdin)
print(json.dumps(strip(data), indent=2, sort_keys=True))
'

LIVE_NORM="$(printf '%s' "$RAW_LIVE" | python3 -c "$NORMALIZE_PY")"

if [[ "$UPDATE_BASELINE" -eq 1 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        say "(dry-run) would write live config to $BASELINE"
        printf '%s\n' "$LIVE_NORM"
        exit 0
    fi
    mkdir -p "$(dirname "$BASELINE")"
    printf '%s\n' "$LIVE_NORM" > "$BASELINE"
    say "wrote new baseline: $BASELINE"
    say "commit it so the detector goes quiet:"
    say "  scripts/coord/chump-commit.sh $BASELINE -m 'INFRA-121: refresh branch-protection baseline'"
    exit 0
fi

[[ -f "$BASELINE" ]] || die "baseline missing: $BASELINE (run with --update-baseline to seed)"

BASELINE_NORM="$(python3 -c "$NORMALIZE_PY" < "$BASELINE")"

# Diff. Use python's difflib for stable, parseable output.
DIFF_PY='
import json, sys, difflib
live, base = sys.argv[1], sys.argv[2]
ll = open(live).read().splitlines(keepends=True)
bl = open(base).read().splitlines(keepends=True)
diff = list(difflib.unified_diff(bl, ll, fromfile="baseline", tofile="live", n=3))
if diff:
    sys.stdout.write("".join(diff))
'

LIVE_TMP="$(mktemp -t bp-live.XXXXXX)"
BASE_TMP="$(mktemp -t bp-base.XXXXXX)"
trap 'rm -f "$LIVE_TMP" "$BASE_TMP"' EXIT
printf '%s\n' "$LIVE_NORM" > "$LIVE_TMP"
printf '%s\n' "$BASELINE_NORM" > "$BASE_TMP"

DIFF_OUT="$(python3 -c "$DIFF_PY" "$LIVE_TMP" "$BASE_TMP")"

if [[ -z "$DIFF_OUT" ]]; then
    say "ok — branch protection matches baseline"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        printf '{"ts":"%s","check":"branch_protection_drift","status":"ok","repo":"%s","branch":"%s"}\n' \
            "$TS" "$REPO" "$BRANCH" >> "$HEALTH_JSONL"
    fi
    exit 0
fi

# Drift!
warn "DRIFT detected for $REPO:$BRANCH"
[[ "$QUIET" -eq 1 ]] || printf '%s\n' "$DIFF_OUT" >&2

if [[ "$DRY_RUN" -eq 1 ]]; then
    say "(dry-run) skipping ALERT + health.jsonl writes"
    exit 0
fi

# Compose a compact one-liner for the ambient ALERT (digest-budget-friendly).
SHORT_SUMMARY="$(printf '%s' "$DIFF_OUT" | grep -E '^[+-][^+-]' | head -8 | tr '\n' ' ' | cut -c1-300)"

printf '%s\tqueue_config_drift\trepo=%s branch=%s diff=%s\n' \
    "$TS" "$REPO" "$BRANCH" "$SHORT_SUMMARY" >> "$ALERTS_LOG"

if [[ -x "$EMIT" ]]; then
    "$EMIT" ALERT "kind=queue_config_drift" "repo=$REPO" "branch=$BRANCH" "note=${SHORT_SUMMARY:0:200}" 2>/dev/null || true
fi

# Full diff also recorded in health.jsonl (escaped) for forensic replay.
DIFF_OUT_ESCAPED="$(printf '%s' "$DIFF_OUT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
printf '{"ts":"%s","check":"branch_protection_drift","status":"drift","repo":"%s","branch":"%s","diff":%s}\n' \
    "$TS" "$REPO" "$BRANCH" "$DIFF_OUT_ESCAPED" >> "$HEALTH_JSONL"

say "ALERT written to $ALERTS_LOG and ambient.jsonl"
say "to accept this drift as the new baseline:"
say "  scripts/ops/branch-protection-drift.sh --update-baseline"
say "then commit docs/baselines/branch-protection-main.json"

exit 0
