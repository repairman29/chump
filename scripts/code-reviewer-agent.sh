#!/usr/bin/env bash
#
# code-reviewer-agent.sh — automated code review for src/* PRs (INFRA-AGENT-CODEREVIEW MVP)
#
# Usage:
#   scripts/code-reviewer-agent.sh <PR_NUMBER> [--gap GAP-ID] [--dry-run] [--post]
#
# Default behaviour: prints the review verdict to stdout. Pass --post to actually
# call gh pr review / gh pr comment. --dry-run skips all gh writes AND skips the
# Anthropic API call (uses a stub response) — for offline smoke testing.
#
# Exit codes:
#   0  APPROVE  (auto-approval criteria met)
#   1  CONCERN  (concerns raised; merge should be blocked)
#   2  ESCALATE (escalation required — human eyes needed)
#   3  SKIP     (docs-only PR; no review needed)
#   4  ERROR    (could not fetch diff, missing API key, etc.)
#
# See docs/CODEREVIEW_POLICY.md for the auto-approve / concern / escalate matrix.

set -euo pipefail

# ── Args ──────────────────────────────────────────────────────────────────────
PR=""
GAP_ID=""
DRY_RUN=0
POST=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --gap)     GAP_ID="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --post)    POST=1; shift ;;
        --help|-h) sed -n '2,18p' "$0"; exit 0 ;;
        *)         PR="$1"; shift ;;
    esac
done

if [[ -z "$PR" ]]; then
    echo "usage: $0 <PR_NUMBER> [--gap GAP-ID] [--dry-run] [--post]" >&2
    exit 4
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
green() { printf '\033[0;32m%s\033[0m\n' "$*" >&2; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }
yellow(){ printf '\033[0;33m%s\033[0m\n' "$*" >&2; }
info()  { printf '  %s\n' "$*" >&2; }

# ── 1. Fetch changed file list — skip docs-only PRs ──────────────────────────
info "Fetching changed file list for PR #$PR …"
CHANGED_FILES=$(gh pr diff "$PR" --name-only 2>/dev/null || true)
if [[ -z "$CHANGED_FILES" ]]; then
    red "Could not fetch file list for PR #$PR (does it exist?)."
    exit 4
fi

# Docs-only filter: every line matches docs/, *.md, or .yaml in docs/.
DOCS_ONLY=1
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ ! "$f" =~ ^docs/ ]] && [[ ! "$f" =~ \.md$ ]] && [[ ! "$f" =~ ^README ]]; then
        DOCS_ONLY=0
        break
    fi
done <<< "$CHANGED_FILES"

if [[ $DOCS_ONLY -eq 1 ]]; then
    yellow "PR #$PR is docs-only — skipping code review."
    echo "SKIP: docs-only PR"
    exit 3
fi

# ── 2. Check for sensitive paths — escalate immediately ──────────────────────
ESCALATE_REASON=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in
        scripts/git-hooks/*|scripts/bot-merge.sh|scripts/code-reviewer-agent.sh|.claude/*|*CHUMP_TOOLS_ASK*)
            ESCALATE_REASON="touches sensitive infra path: $f"
            break ;;
    esac
done <<< "$CHANGED_FILES"

if [[ -n "$ESCALATE_REASON" ]]; then
    yellow "ESCALATE: $ESCALATE_REASON"
    echo "ESCALATE: $ESCALATE_REASON"
    if [[ $POST -eq 1 ]]; then
        gh pr comment "$PR" --body "🤖 **code-reviewer-agent**: ESCALATE — $ESCALATE_REASON. Human review required (per docs/CODEREVIEW_POLICY.md)." >&2 || true
    fi
    exit 2
fi

# ── 3. Fetch diff + LOC count ────────────────────────────────────────────────
DIFF=$(gh pr diff "$PR" 2>/dev/null || true)
if [[ -z "$DIFF" ]]; then
    red "Empty diff for PR #$PR."
    exit 4
fi
LOC=$(echo "$DIFF" | grep -cE '^[+-][^+-]' || true)
info "Diff size: $LOC LOC changed."

# ── 4. Pull gap acceptance criteria (if --gap given) ─────────────────────────
GAP_CRITERIA=""
REPO_ROOT="$(git rev-parse --show-toplevel)"
if [[ -n "$GAP_ID" ]]; then
    if [[ -f "$REPO_ROOT/docs/gaps.yaml" ]]; then
        # NB: regex is /^- id:/ (no leading spaces) — top-level YAML entries
        # in docs/gaps.yaml start at column 0. With a leading-space regex,
        # awk never matched the next gap and processed the entire 11k-line
        # file; `head -80` then closed the pipe early and awk SIGPIPE'd
        # (exit 141) under `set -euo pipefail`, breaking auto-merge on
        # every src/* PR. (INFRA-072, 2026-04-25.)
        GAP_CRITERIA=$(awk -v id="$GAP_ID" '
            $0 ~ "id: " id { found=1; print; next }
            found && /^- id:/ { exit }
            found { print }
        ' "$REPO_ROOT/docs/gaps.yaml" | head -80)
    fi
fi

# ── 4b. Workspace dependency pre-check ───────────────────────────────────────
# Extract new dependency names added to any Cargo.toml in the diff, then
# cross-reference against the workspace Cargo.toml. Only genuinely new
# dependencies (not already present in the workspace) should be flagged.
# This prevents false-positive CONCERN verdicts for deps like `serde` or
# `rusqlite` that are added to a crate-level Cargo.toml but already exist
# in the workspace root Cargo.toml.
NEW_DEPS_IN_DIFF=()
GENUINELY_NEW_DEPS=()
WORKSPACE_KNOWN_DEPS=()

if [[ -f "$REPO_ROOT/Cargo.toml" ]]; then
    # Parse added Cargo.toml lines from the diff (lines starting with + inside a
    # Cargo.toml file context). Match dep name at start of line: ^+<name> = ...
    # Also handles: ^+<name> = { ... }  and  ^+<name>.workspace = true
    while IFS= read -r line; do
        # Strip leading + and whitespace
        dep_line="${line#+}"
        dep_line="${dep_line# }"
        # Extract the dependency name: everything before the first = or .
        dep_name=$(echo "$dep_line" | sed -E 's/^([a-zA-Z0-9_-]+)[ ]*[.=].*/\1/')
        [[ -z "$dep_name" ]] && continue
        # Skip TOML section headers like [dependencies], [dev-dependencies], etc.
        [[ "$dep_name" == "["* ]] && continue
        NEW_DEPS_IN_DIFF+=("$dep_name")
    done < <(echo "$DIFF" | grep -E '^\+[a-zA-Z0-9_-]+[ ]*[.=]' | grep -v '^+++')

    # For each new dep name found in the diff, check the workspace Cargo.toml.
    # Guard the iteration: under bash 3.2 (default macOS) + `set -u`, expanding
    # an empty array via "${arr[@]}" errors with "unbound variable", which
    # caused PR #465 (REMOVAL-003) to fail review with no actual concerns.
    if (( ${#NEW_DEPS_IN_DIFF[@]} > 0 )); then
        for dep in "${NEW_DEPS_IN_DIFF[@]}"; do
            if grep -qE "^${dep}[ ]*[.=]" "$REPO_ROOT/Cargo.toml" 2>/dev/null; then
                WORKSPACE_KNOWN_DEPS+=("$dep")
            else
                GENUINELY_NEW_DEPS+=("$dep")
            fi
        done
    fi
fi

# Build a human-readable note for the LLM prompt
DEPS_NOTE=""
if [[ ${#NEW_DEPS_IN_DIFF[@]} -gt 0 ]]; then
    if [[ ${#WORKSPACE_KNOWN_DEPS[@]} -gt 0 ]]; then
        DEPS_NOTE+="Dependencies in diff already present in workspace Cargo.toml (do NOT flag these): ${WORKSPACE_KNOWN_DEPS[*]}"$'\n'
    fi
    if [[ ${#GENUINELY_NEW_DEPS[@]} -gt 0 ]]; then
        DEPS_NOTE+="Genuinely new dependencies NOT in workspace Cargo.toml (flag these as CONCERN): ${GENUINELY_NEW_DEPS[*]}"$'\n'
    fi
    if [[ ${#GENUINELY_NEW_DEPS[@]} -eq 0 && ${#NEW_DEPS_IN_DIFF[@]} -gt 0 ]]; then
        DEPS_NOTE+="All new Cargo.toml dependency entries in this diff already exist in the workspace Cargo.toml — no new external dependencies introduced."$'\n'
    fi
fi

# ── 5. Build review prompt ───────────────────────────────────────────────────
# Cap diff at ~80KB to keep prompt under model context limits.
DIFF_TRIMMED=$(echo "$DIFF" | head -c 80000)

PROMPT=$(cat <<EOF
You are reviewing this Chump PR. Reply with EXACTLY one of these formats on the first line:

APPROVE: <one-sentence reason>
CONCERN: <comma-separated list of concerns>
ESCALATE: <reason this needs human review>

Auto-approve criteria (ALL must hold):
  - Diff is under 200 LOC
  - No new unwrap()/expect() in production code paths (test code is fine)
  - No genuinely new external dependencies added (workspace-inherited deps are fine)
  - Diff matches gap acceptance criteria
  - No obvious bugs, security issues, or panics

Raise CONCERN if any of the above fail or if you spot bugs/issues worth a fix-up.
ESCALATE if changes touch security boundaries, change behaviour in non-obvious ways,
or you cannot confidently judge the change.

IMPORTANT — dependency evaluation: The pre-checker has already analysed Cargo.toml
changes in this diff. Use the workspace dependency notes below (if present) as the
authoritative source for whether a dependency is new. Do NOT flag a dep as new if it
appears in the "already present in workspace" list.

Gap ID: ${GAP_ID:-<none specified>}
Diff LOC: $LOC
Changed files:
$CHANGED_FILES

Workspace dependency analysis:
${DEPS_NOTE:-No Cargo.toml dependency changes detected.}

Gap acceptance criteria:
$GAP_CRITERIA

Diff:
\`\`\`diff
$DIFF_TRIMMED
\`\`\`

Your verdict (one line, one of APPROVE/CONCERN/ESCALATE):
EOF
)

# ── 6. Call Anthropic API (or stub for --dry-run) ────────────────────────────
if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run] skipping API call — using stub response."
    RESPONSE="APPROVE: dry-run stub response (LOC=$LOC, files=$(echo "$CHANGED_FILES" | wc -l | tr -d ' '))"
else
    # Source .env for ANTHROPIC_API_KEY if not already set. Check the worktree
    # root first, then the common-dir parent (main repo) since .env typically
    # lives in the main checkout, not in linked worktrees.
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        for _root in "$(git rev-parse --show-toplevel)" "$(git rev-parse --git-common-dir | xargs dirname 2>/dev/null)"; do
            if [[ -n "$_root" && -f "$_root/.env" ]]; then
                set -a; source "$_root/.env"; set +a
                [[ -n "${ANTHROPIC_API_KEY:-}" ]] && break
            fi
        done
    fi
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        red "ANTHROPIC_API_KEY not set — cannot call Claude API."
        exit 4
    fi

    info "Calling Claude API (claude-opus-4-5) …"
    REQUEST_JSON=$(python3 -c "
import json, sys
p = sys.stdin.read()
print(json.dumps({
    'model': 'claude-opus-4-5',
    'max_tokens': 1024,
    'messages': [{'role': 'user', 'content': p}],
}))" <<< "$PROMPT")

    API_RESPONSE=$(curl -s https://api.anthropic.com/v1/messages \
        -H "x-api-key: $ANTHROPIC_API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d "$REQUEST_JSON")

    RESPONSE=$(echo "$API_RESPONSE" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    if 'content' in d and d['content']:
        print(d['content'][0].get('text', '').strip())
    else:
        print('ESCALATE: Claude API returned no content — ' + json.dumps(d)[:200])
except Exception as e:
    print(f'ESCALATE: failed to parse Claude API response: {e}')
")
fi

# ── 7. Parse verdict ─────────────────────────────────────────────────────────
VERDICT_LINE=$(echo "$RESPONSE" | grep -E '^(APPROVE|CONCERN|ESCALATE):' | head -1)
if [[ -z "$VERDICT_LINE" ]]; then
    VERDICT_LINE="ESCALATE: code-reviewer response did not match expected format"
fi

VERDICT=$(echo "$VERDICT_LINE" | cut -d: -f1)
REASON=$(echo "$VERDICT_LINE" | cut -d: -f2- | sed 's/^ //')

green "Verdict: $VERDICT"
info "Reason: $REASON"
echo "$VERDICT_LINE"

# ── 8. Post review to GitHub (if --post) ─────────────────────────────────────
COMMENT_BODY="🤖 **code-reviewer-agent** (automated, INFRA-AGENT-CODEREVIEW MVP):

**Verdict:** $VERDICT
**Reason:** $REASON

Diff size: $LOC LOC. Changed files: $(echo "$CHANGED_FILES" | wc -l | tr -d ' ').

Full reasoning:
\`\`\`
$RESPONSE
\`\`\`

See \`docs/CODEREVIEW_POLICY.md\` for the auto-approve criteria."

if [[ $POST -eq 1 ]]; then
    case "$VERDICT" in
        APPROVE)
            info "Posting approval review …"
            gh pr review "$PR" --approve --body "$COMMENT_BODY" >&2 || \
                gh pr comment "$PR" --body "$COMMENT_BODY" >&2 ;;
        CONCERN)
            info "Posting concern as request-changes review …"
            gh pr review "$PR" --request-changes --body "$COMMENT_BODY" >&2 || \
                gh pr comment "$PR" --body "$COMMENT_BODY" >&2 ;;
        ESCALATE)
            info "Posting escalation comment …"
            gh pr comment "$PR" --body "$COMMENT_BODY" >&2 ;;
    esac
fi

# ── 9. Exit code ─────────────────────────────────────────────────────────────
case "$VERDICT" in
    APPROVE)  exit 0 ;;
    CONCERN)  exit 1 ;;
    ESCALATE) exit 2 ;;
    *)        exit 4 ;;
esac
