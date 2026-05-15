#!/usr/bin/env bash
# pre-commit-rust-first.sh — META-064
#
# Enforces the "Rust-first" rule for new shell scripts in critical paths.
# When a commit ADDS a new *.sh file under scripts/coord/, scripts/dispatch/,
# or scripts/ops/, the hook checks if the script meets the Rust-first criteria
# (state-mutating, hot-path-callable, or > 200 LOC). If yes, the commit is
# blocked unless the commit body has a `Rust-First-Bypass: <reason>` trailer.
#
# Criteria — Rust-first triggers when ANY hold:
#   1. Writes to canonical state: state.db, .chump-locks/*.json,
#      ambient.jsonl, docs/gaps/
#   2. Lives in a hot-path dir (scripts/coord/ or scripts/dispatch/)
#   3. Is > 200 LOC on first commit
#
# Bypass: include `Rust-First-Bypass: <reason>` in commit body. Reason is
# logged so audit can attribute the choice.
#
# Bypass env (rare, for unusual flows): CHUMP_RUST_FIRST_CHECK=0
#
# Source: META-064 (2026-05-14 rust-first decision rule).

set -uo pipefail

# Disable env hatch — useful for synthetic test fixtures.
if [[ "${CHUMP_RUST_FIRST_CHECK:-1}" == "0" ]]; then
    exit 0
fi

# Operate against the staged diff.
# Find NEW files only (status=A) ending in .sh under hot-path dirs.
NEW_SH="$(git diff --cached --name-only --diff-filter=A 2>/dev/null \
    | grep -E '^scripts/(coord|dispatch|ops)/[^/]+\.sh$' || true)"

if [[ -z "$NEW_SH" ]]; then
    exit 0
fi

VIOLATIONS=()
REASONS=()

while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ -f "$f" ]] || continue

    triggers=()

    # Trigger 1: state-mutating patterns
    if grep -qE '>>?\s*[^|]*\.chump/state\.db|>>?\s*[^|]*\.chump-locks/[^/]+\.json|>>?\s*[^|]*ambient\.jsonl|>>?\s*[^|]*docs/gaps/[A-Z]+-' "$f" 2>/dev/null; then
        triggers+=("writes to canonical state (state.db / .chump-locks/ / ambient.jsonl / docs/gaps/)")
    fi

    # Trigger 2: hot-path dir
    case "$f" in
        scripts/coord/*.sh|scripts/dispatch/*.sh)
            # All new shell in these dirs IS hot-path by definition.
            triggers+=("hot-path directory (scripts/coord or scripts/dispatch)")
            ;;
    esac

    # Trigger 3: > 200 LOC
    loc=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
    if [[ "${loc:-0}" -gt 200 ]]; then
        triggers+=("$loc lines (> 200 threshold)")
    fi

    if (( ${#triggers[@]} > 0 )); then
        VIOLATIONS+=("$f")
        # shellcheck disable=SC2207
        REASONS+=("$(IFS='|'; echo "${triggers[*]}")")
    fi
done <<< "$NEW_SH"

if (( ${#VIOLATIONS[@]} == 0 )); then
    exit 0
fi

# Check for Rust-First-Bypass trailer in the staged commit message.
# When the hook runs from `git commit`, COMMIT_EDITMSG is the source.
#
# INFRA-1309: use --git-common-dir (not --git-dir) so the bypass trailer is
# found in linked worktrees (/tmp/chump-<GAP>). In a linked worktree,
# git writes COMMIT_EDITMSG to the common gitdir (.git/), not the per-worktree
# gitdir (.git/worktrees/<name>/). --git-dir returns the per-worktree path and
# the file is never found, silently failing every bypass attempt.
MSG_FILE="$(git rev-parse --git-common-dir)/COMMIT_EDITMSG"
HAS_BYPASS=0
if [[ -f "$MSG_FILE" ]] && grep -qE '^Rust-First-Bypass:' "$MSG_FILE" 2>/dev/null; then
    HAS_BYPASS=1
fi

if [[ "$HAS_BYPASS" == "1" ]]; then
    # Log to ambient (best-effort, never block).
    AMBIENT="${CHUMP_AMBIENT_LOG:-$(git rev-parse --show-toplevel)/.chump-locks/ambient.jsonl}"
    reason="$(grep -E '^Rust-First-Bypass:' "$MSG_FILE" | head -1 | sed 's/^Rust-First-Bypass:[[:space:]]*//')"
    if [[ -d "$(dirname "$AMBIENT")" ]]; then
        printf '{"ts":"%s","kind":"rust_first_bypass_used","files":"%s","reason":%s}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$(IFS=,; echo "${VIOLATIONS[*]}")" \
            "$(printf '%s' "$reason" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo '"unparseable"')" \
            >> "$AMBIENT" 2>/dev/null || true
    fi
    exit 0
fi

# Block.
red='\033[0;31m'
nc='\033[0m'
echo "" >&2
echo -e "${red}❌ META-064 Rust-first gate blocked this commit.${nc}" >&2
echo "" >&2
echo "New shell file(s) in a critical path meet the Rust-first criteria:" >&2
for i in "${!VIOLATIONS[@]}"; do
    f="${VIOLATIONS[$i]}"
    r="${REASONS[$i]}"
    echo "" >&2
    echo "  ${f}" >&2
    IFS='|' read -ra reason_arr <<< "$r"
    for t in "${reason_arr[@]}"; do
        echo "    - $t" >&2
    done
done
echo "" >&2
echo "Why: scripts/coord/ + scripts/dispatch/ + state-mutating shell has" >&2
echo "shipped 16k+ LOC of port-debt in the last quarter. Type-safe Rust" >&2
echo "(via 'chump <verb>' subcommands) prevents the next round." >&2
echo "" >&2
echo "Fix one of:" >&2
echo "  1. Implement as a 'chump <verb>' Rust subcommand instead" >&2
echo "     (see src/cmd/*/ for the pattern)" >&2
echo "  2. Bypass with a reason — add this trailer to the commit body:" >&2
echo "       Rust-First-Bypass: <one-sentence reason>" >&2
echo "" >&2
echo "Full rule: docs/process/CLAUDE_GOTCHAS.md or AGENTS.md" >&2
echo "  → 'Rust-first vs. shell-OK (META-064)'" >&2
echo "" >&2
echo "Disable (rare): CHUMP_RUST_FIRST_CHECK=0 git commit ..." >&2
exit 1
