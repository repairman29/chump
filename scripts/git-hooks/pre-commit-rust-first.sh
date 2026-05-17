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

# ── INFRA-1580: CHUMP_RUST_FIRST_AUDIT=1 — backfill audit mode ───────────────
# When set, scan scripts/coord/*.sh for existing bypasses and emit per-file
# kind=rust_first_bypass_audit events to ambient.jsonl. Does NOT gate commits.
if [[ "${CHUMP_RUST_FIRST_AUDIT:-0}" == "1" ]]; then
    REPO_TOP_A="$(git rev-parse --show-toplevel)"
    AMBIENT_A="${CHUMP_AMBIENT_LOG:-$REPO_TOP_A/.chump-locks/ambient.jsonl}"
    _plist_ref_a() {
        local base="$1"
        if compgen -G "$HOME/Library/LaunchAgents/*.plist" > /dev/null 2>&1; then
            grep -l "$base" "$HOME"/Library/LaunchAgents/*.plist >/dev/null 2>&1 && return 0
        fi
        git ls-files '*.plist' 2>/dev/null | head -50 \
            | xargs grep -l "$base" 2>/dev/null | grep -q . && return 0
        return 1
    }
    while IFS= read -r af; do
        [[ -f "$af" ]] || continue
        grep -qE '^[[:space:]]*#?[[:space:]]*Rust-First-Bypass:' "$af" 2>/dev/null || continue
        base_a="$(basename "$af" .sh)"
        loc_a=$(wc -l < "$af" 2>/dev/null | tr -d ' ')
        viol_a=()
        [[ "${loc_a:-0}" -gt 200 ]] && viol_a+=("loc")
        grep -qE '\.chump-locks/[^[:space:]]+\.state|state\.db|ambient\.jsonl' "$af" 2>/dev/null \
            && viol_a+=("state")
        if grep -qE '^[[:space:]]*while[[:space:]]+true' "$af" 2>/dev/null \
            || _plist_ref_a "$base_a"; then
            viol_a+=("hot")
        fi
        [[ ! -f "$REPO_TOP_A/scripts/ci/test-${base_a}.sh" ]] && viol_a+=("test")
        (( ${#viol_a[@]} == 0 )) && continue
        has_ack_a=false
        grep -qE '^[[:space:]]*#?[[:space:]]*Rust-First-Bypass-Accept:' "$af" 2>/dev/null \
            && has_ack_a=true
        viol_csv_a="$(IFS=,; echo "${viol_a[*]}")"
        if [[ -d "$(dirname "$AMBIENT_A")" ]]; then
            printf '{"ts":"%s","kind":"rust_first_bypass_audit","file":"%s","criteria_failed":"%s","bypass_present":true,"has_acknowledgment":%s,"loc":%s}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                "$af" \
                "$viol_csv_a" \
                "$has_ack_a" \
                "${loc_a:-0}" \
                >> "$AMBIENT_A" 2>/dev/null || true
        fi
        printf '[audit] %s  violations=%s  ack=%s\n' "$af" "$viol_csv_a" "$has_ack_a"
    done < <(find "$REPO_TOP_A/scripts/coord" -maxdepth 1 -name '*.sh' -type f 2>/dev/null | sort)
    exit 0
fi

# ── INFRA-1580: second enforcement layer — modified files with bypass header ──
# When an EXISTING shell file that already has a Rust-First-Bypass: comment is
# being MODIFIED in this commit, machine-check the same 4 criteria. If 2+
# criteria fail AND the commit trailer doesn't acknowledge them via
# Rust-First-Bypass-Accept:, block.
#
# This runs BEFORE the new-file gate so it exits independently on its own
# result. If it blocks, the operator gets a clear message. If it passes, the
# new-file gate runs next.
_modified_bypass_gate() {
    local MODIFIED_SH_ALL
    MODIFIED_SH_ALL="$(git diff --cached --name-only --diff-filter=M 2>/dev/null \
        | grep -E '^scripts/[^/]+/[^/]+\.sh$' || true)"
    [[ -n "$MODIFIED_SH_ALL" ]] || return 0

    # Collect modified files that have a Rust-First-Bypass: header in content.
    local bypass_files=()
    while IFS= read -r mf; do
        [[ -z "$mf" ]] && continue
        [[ -f "$mf" ]] || continue
        grep -qE '^[[:space:]]*#?[[:space:]]*Rust-First-Bypass:' "$mf" 2>/dev/null \
            || continue
        bypass_files+=("$mf")
    done <<< "$MODIFIED_SH_ALL"

    [[ ${#bypass_files[@]} -gt 0 ]] || return 0

    # Read commit message once.
    local MOD_MSG_FILE
    MOD_MSG_FILE="$(git rev-parse --git-common-dir)/COMMIT_EDITMSG"
    local MOD_ACCEPT_CSV=""
    if [[ -f "$MOD_MSG_FILE" ]]; then
        MOD_ACCEPT_CSV="$(grep -E '^Rust-First-Bypass-Accept:' "$MOD_MSG_FILE" 2>/dev/null \
            | head -1 \
            | sed 's/^Rust-First-Bypass-Accept:[[:space:]]*//' \
            | tr 'A-Z' 'a-z' \
            | tr -d ' \t')"
    fi

    _mod_ack_has() {
        local tok="$1"
        [[ -z "$MOD_ACCEPT_CSV" ]] && return 1
        case ",$MOD_ACCEPT_CSV," in
            *",$tok,"*) return 0 ;;
            *) return 1 ;;
        esac
    }

    _mod_plist_ref() {
        local base="$1"
        if compgen -G "$HOME/Library/LaunchAgents/*.plist" > /dev/null 2>&1; then
            grep -l "$base" "$HOME"/Library/LaunchAgents/*.plist >/dev/null 2>&1 && return 0
        fi
        if git ls-files '*.plist' 2>/dev/null | head -50 \
                | xargs grep -l "$base" 2>/dev/null | grep -q .; then
            return 0
        fi
        return 1
    }

    local REPO_TOP_M
    REPO_TOP_M="$(git rev-parse --show-toplevel)"

    local MOD_BLOCKED_FILES=()
    local MOD_BLOCKED_DETAILS=()

    for mf in "${bypass_files[@]}"; do
        local absf="$REPO_TOP_M/$mf"
        [[ -f "$absf" ]] || absf="$mf"
        [[ -f "$absf" ]] || continue
        local base_m
        base_m="$(basename "$mf" .sh)"

        local failing_m=()

        # (1) LOC > 200
        local loc_m
        loc_m=$(wc -l < "$absf" 2>/dev/null | tr -d ' ')
        if [[ "${loc_m:-0}" -gt 200 ]]; then
            failing_m+=("loc:LOC=$loc_m>200")
        fi

        # (2) state mutation
        if grep -qE '\.chump-locks/[^[:space:]]+\.state|state\.db|ambient\.jsonl' "$absf" 2>/dev/null; then
            failing_m+=("state:writes to .chump-locks/*.state, state.db, or ambient.jsonl")
        fi

        # (3) hot path
        local hot_reason_m=""
        if grep -qE '^[[:space:]]*while[[:space:]]+true' "$absf" 2>/dev/null; then
            hot_reason_m="contains 'while true' loop"
        elif _mod_plist_ref "$base_m"; then
            hot_reason_m="referenced by launchd plist (KeepAlive candidate)"
        fi
        [[ -n "$hot_reason_m" ]] && failing_m+=("hot:$hot_reason_m")

        # (4) no scripts/ci/test-<basename>.sh
        if [[ ! -f "$REPO_TOP_M/scripts/ci/test-${base_m}.sh" ]]; then
            failing_m+=("test:no scripts/ci/test-${base_m}.sh sibling")
        fi

        # < 2 failures: bypass narrative alone is fine.
        (( ${#failing_m[@]} < 2 )) && continue

        # Check each failing key against ACCEPT_CSV.
        local unacked_m=()
        for entry_m in "${failing_m[@]}"; do
            local key_m="${entry_m%%:*}"
            _mod_ack_has "$key_m" || unacked_m+=("$entry_m")
        done

        if (( ${#unacked_m[@]} > 0 )); then
            MOD_BLOCKED_FILES+=("$mf")
            MOD_BLOCKED_DETAILS+=("$(IFS='|'; echo "${unacked_m[*]}")")
        fi
    done

    if (( ${#MOD_BLOCKED_FILES[@]} == 0 )); then
        return 0
    fi

    # Emit to ambient (best-effort).
    local MOD_AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_TOP_M/.chump-locks/ambient.jsonl}"
    if [[ -d "$(dirname "$MOD_AMBIENT")" ]]; then
        local _all_mod_unacked
        _all_mod_unacked="$(IFS='|'; echo "${MOD_BLOCKED_DETAILS[*]}")"
        printf '{"ts":"%s","kind":"rust_first_strict_blocked","files":"%s","unacknowledged":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$(IFS=,; echo "${MOD_BLOCKED_FILES[*]}")" \
            "$_all_mod_unacked" \
            >> "$MOD_AMBIENT" 2>/dev/null || true
    fi

    local red='\033[0;31m' nc='\033[0m'
    echo "" >&2
    echo -e "${red}❌ META-064 Rust-first STRICT gate (INFRA-1580) blocked this commit.${nc}" >&2
    echo "" >&2
    echo "Modified shell file(s) with Rust-First-Bypass: header fail 2+ machine-" >&2
    echo "checkable criteria. The bypass must acknowledge each failing criterion:" >&2
    for i in "${!MOD_BLOCKED_FILES[@]}"; do
        local f_m="${MOD_BLOCKED_FILES[$i]}" d_m="${MOD_BLOCKED_DETAILS[$i]}"
        echo "" >&2
        echo "  ${f_m}" >&2
        IFS='|' read -ra det_arr_m <<< "$d_m"
        for t_m in "${det_arr_m[@]}"; do echo "    - $t_m" >&2; done
    done
    echo "" >&2
    echo "Fix: add this trailer to acknowledge each unacked criterion:" >&2
    echo "     Rust-First-Bypass-Accept: <csv of criteria you accept>" >&2
    echo "  Valid keys: loc, state, hot, test" >&2
    echo "  Example:   Rust-First-Bypass-Accept: loc,state,hot,test" >&2
    echo "" >&2
    echo "Narrative Rust-First-Bypass: is still required in addition." >&2
    echo "Full rule: docs/process/CLAUDE_GOTCHAS.md → 'Rust-First-Bypass-Accept'" >&2
    echo "Disable (rare): CHUMP_RUST_FIRST_CHECK=0 git commit ..." >&2
    return 1
}

# Run the modified-bypass gate; exit 1 immediately if it blocks.
_modified_bypass_gate || exit 1

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
    # INFRA-1580: machine-acknowledgment gate. When a bypass trailer is
    # present, run the 4 strict machine-checkable criteria against each
    # violating file. If 2+ criteria fail AND the trailer doesn't include
    # `Rust-First-Bypass-Accept: <csv>` that covers each failing criterion,
    # reject the commit so narrative-only bypasses can't slip past hot/state/
    # large/untested daemons.
    #
    # Criteria keys (CSV values in Rust-First-Bypass-Accept):
    #   loc    — LOC > 200
    #   state  — writes to .chump-locks/<x>.state, state.db, or ambient.jsonl
    #   hot    — contains `while true` OR plist references the basename
    #   test   — no scripts/ci/test-<basename>.sh sibling exists
    #
    # Read the accept CSV (lowercase tokens, comma- or whitespace-separated).
    ACCEPT_CSV="$(grep -E '^Rust-First-Bypass-Accept:' "$MSG_FILE" 2>/dev/null \
        | head -1 \
        | sed 's/^Rust-First-Bypass-Accept:[[:space:]]*//' \
        | tr 'A-Z' 'a-z' \
        | tr -d ' \t')"

    # Helper: returns 0 (yes, acknowledged) iff $1 token is in ACCEPT_CSV.
    _ack_has() {
        local tok="$1"
        [[ -z "$ACCEPT_CSV" ]] && return 1
        case ",$ACCEPT_CSV," in
            *",$tok,"*) return 0 ;;
            *) return 1 ;;
        esac
    }

    # Helper: list plist files that reference this basename (KeepAlive daemons).
    # Searches ~/Library/LaunchAgents/*.plist plus repo-tracked plists.
    _plist_references_basename() {
        local base="$1"
        local found=0
        if compgen -G "$HOME/Library/LaunchAgents/*.plist" > /dev/null 2>&1; then
            grep -l "$base" "$HOME"/Library/LaunchAgents/*.plist >/dev/null 2>&1 && found=1
        fi
        if [[ $found -eq 0 ]]; then
            # Repo-tracked plist (e.g. ops/launchd/*.plist).
            if git ls-files '*.plist' 2>/dev/null | head -50 | xargs grep -l "$base" 2>/dev/null | grep -q .; then
                found=1
            fi
        fi
        [[ $found -eq 1 ]]
    }

    # Run per-file strict checks. Build STRICT_VIOLATIONS / STRICT_REASONS
    # arrays parallel to the existing VIOLATIONS array, but limited to files
    # with 2+ unacknowledged failures.
    STRICT_BLOCKED_FILES=()
    STRICT_BLOCKED_DETAILS=()
    REPO_TOP="$(git rev-parse --show-toplevel)"

    for vf in "${VIOLATIONS[@]}"; do
        # Only audit scripts/ shell files (the hot-paths the gate already gates).
        case "$vf" in
            scripts/*) ;;
            *) continue ;;
        esac
        [[ -f "$REPO_TOP/$vf" ]] || continue
        absf="$REPO_TOP/$vf"
        base="$(basename "$vf" .sh)"

        failing=()

        # (1) LOC > 200
        loc=$(wc -l < "$absf" 2>/dev/null | tr -d ' ')
        if [[ "${loc:-0}" -gt 200 ]]; then
            failing+=("loc:LOC=$loc>200")
        fi

        # (2) state mutation
        if grep -qE '\.chump-locks/[^[:space:]]+\.state|state\.db|ambient\.jsonl' "$absf" 2>/dev/null; then
            failing+=("state:writes to .chump-locks/*.state, state.db, or ambient.jsonl")
        fi

        # (3) hot path: `while true` OR plist KeepAlive reference
        hot_reason=""
        if grep -qE '^[[:space:]]*while[[:space:]]+true' "$absf" 2>/dev/null; then
            hot_reason="contains 'while true' loop"
        elif _plist_references_basename "$base"; then
            hot_reason="referenced by launchd plist (KeepAlive candidate)"
        fi
        if [[ -n "$hot_reason" ]]; then
            failing+=("hot:$hot_reason")
        fi

        # (4) no scripts/ci/test-<basename>.sh
        if [[ ! -f "$REPO_TOP/scripts/ci/test-${base}.sh" ]]; then
            failing+=("test:no scripts/ci/test-${base}.sh sibling")
        fi

        # If <2 failing, bypass narrative alone is fine (consistent with old behavior).
        if (( ${#failing[@]} < 2 )); then
            continue
        fi

        # Check each failing key against ACCEPT_CSV. Collect the unacknowledged ones.
        unacked=()
        for entry in "${failing[@]}"; do
            key="${entry%%:*}"
            if ! _ack_has "$key"; then
                unacked+=("$entry")
            fi
        done

        if (( ${#unacked[@]} > 0 )); then
            STRICT_BLOCKED_FILES+=("$vf")
            STRICT_BLOCKED_DETAILS+=("$(IFS='|'; echo "${unacked[*]}")")
        fi
    done

    if (( ${#STRICT_BLOCKED_FILES[@]} > 0 )); then
        AMBIENT="${CHUMP_AMBIENT_LOG:-$(git rev-parse --show-toplevel)/.chump-locks/ambient.jsonl}"
        if [[ -d "$(dirname "$AMBIENT")" ]]; then
            _all_unacked="$(IFS='|'; echo "${STRICT_BLOCKED_DETAILS[*]}")"
            printf '{"ts":"%s","kind":"rust_first_strict_blocked","files":"%s","unacknowledged":"%s"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                "$(IFS=,; echo "${STRICT_BLOCKED_FILES[*]}")" \
                "$_all_unacked" \
                >> "$AMBIENT" 2>/dev/null || true
        fi

        red='\033[0;31m'
        nc='\033[0m'
        echo "" >&2
        echo -e "${red}❌ META-064 Rust-first STRICT gate (INFRA-1580) blocked this commit.${nc}" >&2
        echo "" >&2
        echo "Your commit has 'Rust-First-Bypass:' trailer, but the following file(s)" >&2
        echo "fail 2+ machine-checkable criteria the narrative bypass doesn't cover:" >&2
        for i in "${!STRICT_BLOCKED_FILES[@]}"; do
            f="${STRICT_BLOCKED_FILES[$i]}"
            d="${STRICT_BLOCKED_DETAILS[$i]}"
            echo "" >&2
            echo "  ${f}" >&2
            IFS='|' read -ra det_arr <<< "$d"
            for t in "${det_arr[@]}"; do
                echo "    - $t" >&2
            done
        done
        echo "" >&2
        echo "Why: narrative-only bypasses (e.g. 'this is glue between gh+jq') don't" >&2
        echo "survive contact with reality when the file is also 339 LOC + mutates" >&2
        echo "state + runs forever + has no test. The bypass author must explicitly" >&2
        echo "acknowledge each tradeoff so the audit trail captures the call." >&2
        echo "" >&2
        echo "Fix one of:" >&2
        echo "  1. Port to Rust (see src/cmd/*/ for the chump-subcommand pattern)" >&2
        echo "  2. Acknowledge the tradeoffs explicitly — add this trailer:" >&2
        echo "       Rust-First-Bypass-Accept: <csv of criteria you accept>" >&2
        echo "     Valid keys: loc, state, hot, test" >&2
        echo "     Example: Rust-First-Bypass-Accept: loc,state,hot,test" >&2
        echo "  3. Reduce scope (split file, drop while-true loop, add a test)" >&2
        echo "" >&2
        echo "Narrative justification (Rust-First-Bypass:) is STILL required in" >&2
        echo "addition to the machine-acknowledgment trailer." >&2
        echo "" >&2
        echo "Full rule: docs/process/CLAUDE_GOTCHAS.md → 'Rust-First-Bypass-Accept'" >&2
        echo "Disable (rare): CHUMP_RUST_FIRST_CHECK=0 git commit ..." >&2
        exit 1
    fi

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

# Block. INFRA-1448: emit `rust_first_blocked` so the gate's *enforcement*
# path is visible in ambient.jsonl. The bypass-used emit above only fires
# on the success path; without this, 161k lines of ambient history showed
# zero rust_first_* events even though the gate had blocked commits — making
# the audit trail untrustworthy.
AMBIENT="${CHUMP_AMBIENT_LOG:-$(git rev-parse --show-toplevel)/.chump-locks/ambient.jsonl}"
if [[ -d "$(dirname "$AMBIENT")" ]]; then
    # Concatenate reasons with '|' across files so a single event captures
    # everything that fired (one violation can trigger multiple reasons:
    # hot-path AND state-mutator AND >200 LOC).
    _all_reasons="$(IFS='|'; echo "${REASONS[*]}")"
    printf '{"ts":"%s","kind":"rust_first_blocked","files":"%s","reasons":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$(IFS=,; echo "${VIOLATIONS[*]}")" \
        "$_all_reasons" \
        >> "$AMBIENT" 2>/dev/null || true
fi

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
