#!/usr/bin/env bash
# check-pr-drift.sh — INFRA-104 PR title-vs-implementation drift detector.
#
# Problem
# -------
# PR #565 (2026-04-26) titled "INFRA-087..090: …" reserved four gap IDs
# by name only — the actual implementation for INFRA-088/089/090 landed
# in parallel PRs. The merge queue can't catch this; the PR is mechanically
# valid, just semantically empty for the gaps it cites.
#
# Heuristic
# ---------
# For each gap-ID found in the PR title (matching `[A-Z]+-[0-9]+`):
#   1. Skip if the PR title prefix declares ledger-only intent
#      (`chore(gaps): file|close|backfill|sync`) — those are filing PRs.
#   2. Load gap acceptance_criteria + description from docs/gaps/<ID>.yaml
#      on origin/main; extract file-shape hints (paths, well-known
#      keywords like "workflow", "hook", "ci", "gaps.yaml", …).
#   3. Bucket the PR's changed files into source / test / doc / script /
#      registry-only.
#   4. ALERT cases:
#        - filing-only:  PR title doesn't start with `chore(gaps): file`
#                        but the only changed file is `docs/gaps/<ID>.yaml`.
#        - null-impact:  zero source/test/doc/script changes (only
#                        registry / lock / state files).
#        - hint-miss:    gap has hints, none match any changed path.
#
# Exit codes
# ----------
#   0  no drift
#   1  drift detected (advisory; CI doesn't fail unless CHUMP_DRIFT_FAIL=1)
#   2  usage / fatal
#
# Usage
# -----
#   scripts/ci/check-pr-drift.sh --pr <NUMBER>
#   scripts/ci/check-pr-drift.sh --pr <NUMBER> --dry-run
#   scripts/ci/check-pr-drift.sh --title "<T>" --files "a,b,c"   # offline
#   scripts/ci/check-pr-drift.sh --recent 25                      # backtest
#
# Env
# ---
#   GAPS_DIR             default docs/gaps
#   REMOTE / BASE        default origin / main
#   DRIFT_LABEL          default title-diff-drift
#   CHUMP_DRIFT_FAIL=1   exit 1 on drift (CI default: exit 0, advisory only)
#   CHUMP_AMBIENT_LOG    override ambient.jsonl path (test fixture)

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
REMOTE="${REMOTE:-origin}"
BASE="${BASE:-main}"
GAPS_DIR="${GAPS_DIR:-docs/gaps}"
DRIFT_LABEL="${DRIFT_LABEL:-title-diff-drift}"
DRY_RUN=0
PR_NUMBER=""
RECENT=0
OFFLINE_TITLE=""
OFFLINE_BODY=""
OFFLINE_FILES=""
OUTPUT_FORMAT="text"

usage() {
    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)        PR_NUMBER="$2"; shift 2 ;;
        --recent)    RECENT="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=1; shift ;;
        --title)     OFFLINE_TITLE="$2"; shift 2 ;;
        --body)      OFFLINE_BODY="$2"; shift 2 ;;
        --files)     OFFLINE_FILES="$2"; shift 2 ;;
        --json)      OUTPUT_FORMAT="json"; shift ;;
        -h|--help)   usage ;;
        *)           echo "unknown arg: $1" >&2; usage ;;
    esac
done

if [[ -z "$PR_NUMBER" && -z "$OFFLINE_TITLE" && "$RECENT" -eq 0 ]]; then
    echo "Need --pr <N>, --recent <N>, or --title/--files for offline." >&2
    usage
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT_EMIT="${AMBIENT_EMIT:-$REPO_ROOT/scripts/dev/ambient-emit.sh}"

# ── Helpers ─────────────────────────────────────────────────────────────────
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
info()   { printf '  %s\n' "$*"; }

# extract_gap_ids <text>  →  newline-sep unique IDs (sorted)
extract_gap_ids() {
    printf '%s\n' "$1" | grep -oE '\b[A-Z]{2,}-[0-9]{1,4}[a-z]?\b' \
        | sort -u || true
}

# first_gap_id <text>  →  the FIRST gap ID in left-to-right order
first_gap_id() {
    printf '%s\n' "$1" | grep -oE '\b[A-Z]{2,}-[0-9]{1,4}[a-z]?\b' \
        | head -n 1 || true
}

# load_gap_yaml <ID> — print docs/gaps/<ID>.yaml (origin/main, then worktree)
load_gap_yaml() {
    local gid="$1"
    local path="$GAPS_DIR/$gid.yaml"
    git show "$REMOTE/$BASE:$path" 2>/dev/null \
        || ( [[ -f "$REPO_ROOT/$path" ]] && cat "$REPO_ROOT/$path" ) \
        || true
}

# extract_file_hints <yaml> — pull path-shape tokens + scope keywords
extract_file_hints() {
    local yaml="$1"
    # Pull description + acceptance_criteria blocks.
    local body
    body="$(printf '%s\n' "$yaml" \
        | awk '
            /^[[:space:]]*description:/   { in_desc=1; next }
            /^[[:space:]]*acceptance_criteria:/ { in_ac=1; next }
            /^[a-z_]+:/ && !/^[[:space:]]/ { in_desc=0; in_ac=0 }
            in_desc || in_ac { print }
          ')"
    {
        printf '%s\n' "$body" \
            | grep -oE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]{1,5}\b' || true
        printf '%s\n' "$body" \
            | grep -oE '\b(scripts|src|docs|crates|tests|tools|\.github)/[A-Za-z0-9_/.-]+' \
            || true
        printf '%s\n' "$body" | tr 'A-Z' 'a-z' \
            | grep -oE '\b(workflow|workflows|hook|hooks|ci|gaps\.yaml|gitignore|cargo|rust|gh-pages|readme|cli|mdbook|preflight|pre-commit|launchd|cron|reaper|merge.queue|state\.db|chump-locks|ambient|bot-merge|coord|migration|label|comment|alert)\b' \
            || true
    } | sort -u
}

hint_to_path_fragment() {
    case "$1" in
        workflow|workflows) echo "\.github/workflows/" ;;
        hook|hooks)         echo "scripts/git-hooks/|/hooks/" ;;
        ci)                 echo "scripts/ci/|\.github/workflows/" ;;
        preflight)          echo "preflight" ;;
        pre-commit)         echo "pre-commit" ;;
        bot-merge)          echo "bot-merge" ;;
        reaper)             echo "reaper" ;;
        cargo)              echo "Cargo\.|\.toml" ;;
        rust)               echo "\.rs$" ;;
        readme)             echo "README" ;;
        gitignore)          echo "\.gitignore" ;;
        gh-pages)           echo "gh-pages|/blog/|/book/" ;;
        cli)                echo "src/cli|src/bin|src/main\.rs" ;;
        mdbook)             echo "mdbook|book\.toml|/book/" ;;
        launchd)            echo "launchd|\.plist|setup/install-" ;;
        cron)               echo "cron|launchd|schedule" ;;
        merge.queue)        echo "merge.queue|MERGE_QUEUE" ;;
        state.db|state\.db) echo "state\.db|state\.sql" ;;
        chump-locks)        echo "chump-locks" ;;
        ambient)            echo "ambient" ;;
        coord)              echo "scripts/coord/" ;;
        migration)          echo "migration" ;;
        gaps.yaml|gaps\.yaml) echo "gaps\.yaml|docs/gaps/" ;;
        label|comment|alert) echo "$1" ;;
        *)                  echo "$1" ;;
    esac
}

# Bucket files. Returns space-sep list of buckets with non-zero count.
bucket_files() {
    local files="$1"
    local src=0 test=0 doc=0 script=0 wf=0 reg=0 other=0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        case "$f" in
            docs/gaps/*.yaml|docs/gaps.yaml) reg=$((reg+1)) ;;
            .chump-locks/*|.chump/state.*) reg=$((reg+1)) ;;
            tests/*|*/tests/*|*_test.rs|test_*.sh) test=$((test+1)) ;;
            scripts/ci/test-*) test=$((test+1)) ;;
            src/*.rs|crates/*/src/*.rs|*.rs) src=$((src+1)) ;;
            scripts/*) script=$((script+1)) ;;
            .github/workflows/*) wf=$((wf+1)) ;;
            docs/*|*.md|book/*) doc=$((doc+1)) ;;
            *) other=$((other+1)) ;;
        esac
    done <<< "$files"
    local out=""
    [[ $src -gt 0 ]]    && out="$out src=$src"
    [[ $test -gt 0 ]]   && out="$out test=$test"
    [[ $doc -gt 0 ]]    && out="$out doc=$doc"
    [[ $script -gt 0 ]] && out="$out script=$script"
    [[ $wf -gt 0 ]]     && out="$out workflow=$wf"
    [[ $reg -gt 0 ]]    && out="$out registry=$reg"
    [[ $other -gt 0 ]]  && out="$out other=$other"
    echo "$out"
}

# Returns 0 if at least one file path matches a hint fragment.
diff_touches_any_hint() {
    local hints="$1" files="$2"
    [[ -z "$hints" ]] && return 0
    [[ -z "$files" ]] && return 1
    while IFS= read -r hint; do
        [[ -z "$hint" ]] && continue
        local frag
        frag="$(hint_to_path_fragment "$hint")"
        if printf '%s\n' "$files" | grep -Eqi -- "$frag"; then
            return 0
        fi
    done <<< "$hints"
    return 1
}

emit_alert() {
    local pr="$1" gaps="$2" reason="$3"
    if [[ -x "$AMBIENT_EMIT" ]]; then
        "$AMBIENT_EMIT" ALERT \
            kind=title_diff_drift \
            pr="$pr" \
            gaps="$gaps" \
            reason="$reason" \
            note="PR title cites gap(s) but diff has no matching files" \
            >/dev/null 2>&1 || true
    fi
}

# ── Per-PR check ────────────────────────────────────────────────────────────
check_one() {
    local pr="$1" title="$2" body="$3" files="$4"

    # Skip ledger-only by title prefix.
    case "$title" in
        "chore(gaps): file"*|"chore(gaps): close"*|\
        "chore(gaps): backfill"*|"chore(gaps): sync"*|\
        "chore(docs):"*|"docs:"*)
            echo "[skip-ledger] PR $pr — $title"
            return 0
            ;;
    esac

    # Only consider gap-IDs from the *primary* part of the title — the
    # leading prefix before the first colon. IDs after the colon (e.g.
    # "META-013: ... unblocks SECURITY-004") are typically references,
    # not subjects, and should not trigger drift on themselves.
    #
    # Within the primary segment we only check the FIRST gap-ID. Compound
    # titles like "FLEET-027 (FLEET-011 v2): …" pair a primary subject
    # with a parenthetical lineage tag — the implementation lives in the
    # first ID's scope, the second is just a cross-reference.
    local primary_segment
    primary_segment="${title%%:*}"
    local first_gap
    first_gap="$(first_gap_id "$primary_segment")"
    if [[ -z "$first_gap" ]]; then
        first_gap="$(first_gap_id "$title")"
    fi
    if [[ -z "$first_gap" ]]; then
        echo "[skip-no-gap] PR $pr — $title"
        return 0
    fi
    local gap_ids="$first_gap"

    # Bucket files for filing-only / null-impact heuristics.
    local buckets
    buckets="$(bucket_files "$files")"
    local file_count
    file_count="$(printf '%s\n' "$files" | sed '/^$/d' | wc -l | tr -d ' ')"

    local drifting=()
    local reasons=()

    # Heuristic 1: filing-only — only changed file is one docs/gaps/<ID>.yaml
    # but title doesn't start with `chore(gaps):`. (We already returned above
    # if it did, so any match here is definitionally a drift.)
    if [[ "$file_count" -le 2 ]] && \
       [[ "$buckets" =~ registry= ]] && \
       [[ ! "$buckets" =~ src=|test=|script=|workflow=|doc= ]]; then
        for gid in $gap_ids; do
            drifting+=("$gid")
            reasons+=("filing-only")
        done
    elif ! [[ "$buckets" =~ src=|test=|doc=|script=|workflow= ]]; then
        # Heuristic 2: null-impact — only registry/state/lock files changed.
        for gid in $gap_ids; do
            drifting+=("$gid")
            reasons+=("null-impact")
        done
    else
        # Heuristic 3: hint-miss — gap has hints, none represented in diff.
        # SUPPRESSED when the diff has clear implementation work (src+test,
        # or src+workflow, or substantial script+test). Real implementation
        # is a stronger signal than hint matching, and hint extraction is
        # known to miss freshly-introduced filenames the gap YAML didn't
        # mention. Backtest: this suppression eliminated 3/4 false positives
        # (PR #810, #809 INFRA-115; #801 SECURITY-004 secondary mention) on
        # the 25-PR sample.
        local has_impl=0
        if [[ "$buckets" =~ src= ]]; then has_impl=1; fi
        if [[ "$buckets" =~ test= ]] && [[ "$buckets" =~ script=|workflow= ]]; then has_impl=1; fi
        if [[ "$has_impl" -eq 0 ]]; then
            for gid in $gap_ids; do
                local yaml hints
                yaml="$(load_gap_yaml "$gid")"
                [[ -z "$yaml" ]] && continue  # gap not on main yet
                hints="$(extract_file_hints "$yaml")"
                [[ -z "$hints" ]] && continue  # no hints to compare against
                if ! diff_touches_any_hint "$hints" "$files"; then
                    drifting+=("$gid")
                    reasons+=("hint-miss")
                fi
            done
        fi
    fi

    if [[ ${#drifting[@]} -eq 0 ]]; then
        green "[ok] PR $pr — $gap_ids represented (buckets:$buckets)"
        return 0
    fi

    local csv
    csv="$(IFS=,; echo "${drifting[*]}")"
    local rcsv
    rcsv="$(IFS=,; echo "${reasons[*]}")"
    yellow "[drift] PR $pr — gaps=$csv reasons=$rcsv buckets:$buckets"
    yellow "        title: $title"

    if [[ "$DRY_RUN" -eq 0 && -n "$PR_NUMBER" ]]; then
        emit_alert "$PR_NUMBER" "$csv" "$rcsv"
        if command -v gh >/dev/null 2>&1; then
            gh label create "$DRIFT_LABEL" \
                --color "FBCA04" \
                --description "PR title cites a gap whose expected scope isn't in the diff (INFRA-104)" \
                >/dev/null 2>&1 || true
            gh pr edit "$PR_NUMBER" --add-label "$DRIFT_LABEL" \
                >/dev/null 2>&1 || true
            local comment_body
            comment_body=$(printf 'title-vs-diff drift detected (INFRA-104)\n\nThe PR title cites: `%s` (reasons: `%s`)\nbut the diff has no implementation signature for those gaps.\n\nFile buckets in this diff: `%s`\n\nEither (a) drop the unrelated IDs from the title, (b) add the\nimplementation for those gaps to this PR, or (c) split into separate PRs.\n\nThis check is advisory; auto-merge is **not** blocked. To re-run locally:\n`scripts/ci/check-pr-drift.sh --pr %s`\n' \
                "$csv" "$rcsv" "$buckets" "$PR_NUMBER")
            gh pr comment "$PR_NUMBER" --body "$comment_body" \
                >/dev/null 2>&1 || true
        fi
    fi

    return 1
}

# ── Main ────────────────────────────────────────────────────────────────────
DRIFT_FOUND=0

if [[ -n "$PR_NUMBER" ]]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "gh CLI not found — needed for --pr mode." >&2
        exit 2
    fi
    PR_JSON="$(gh pr view "$PR_NUMBER" --json title,body,files 2>/dev/null)" \
        || { red "Could not load PR #$PR_NUMBER"; exit 2; }
    TITLE="$(printf '%s' "$PR_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("title",""))')"
    BODY="$(printf '%s' "$PR_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("body",""))')"
    FILES="$(printf '%s' "$PR_JSON" | python3 -c 'import json,sys; [print(f["path"]) for f in json.load(sys.stdin).get("files",[])]')"
    check_one "$PR_NUMBER" "$TITLE" "$BODY" "$FILES" || DRIFT_FOUND=1
elif [[ "$RECENT" -gt 0 ]]; then
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        n="${line%%$'\t'*}"
        rest="${line#*$'\t'}"
        t="${rest%%$'\t'*}"
        # Fetch files separately (lighter than full --json files for each).
        f="$(gh pr view "$n" --json files -q '.files[].path' 2>/dev/null || true)"
        check_one "$n" "$t" "" "$f" || DRIFT_FOUND=1
    done < <(gh pr list --state all --limit "$RECENT" \
        --json number,title -q '.[] | "\(.number)\t\(.title)"')
else
    FILES_NL="$(printf '%s\n' "$OFFLINE_FILES" | tr ',' '\n' | sed '/^$/d')"
    check_one "offline" "$OFFLINE_TITLE" "$OFFLINE_BODY" "$FILES_NL" \
        || DRIFT_FOUND=1
fi

if [[ "$DRIFT_FOUND" -eq 1 && "${CHUMP_DRIFT_FAIL:-0}" == "1" ]]; then
    exit 1
fi
exit 0
