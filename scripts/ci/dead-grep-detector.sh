#!/usr/bin/env bash
# scripts/ci/dead-grep-detector.sh — CREDIBLE-332 (CREDIBLE-274 slice)
#
# CREDIBLE-237 postmortem: a CI gate that greps for a symbol in a
# hardcoded source path degrades silently the moment that path moves —
# a positive assertion just false-fails (noisy), but a *negative*
# assertion (`grep -q X "$path" && fail "..."`) false-PASSES forever the
# instant "$path" stops containing X, including when the path itself
# still exists but the code moved out of it, or when the path is flat
# out gone. This script is the cheap first line of defense: scan
# scripts/ci for grep invocations, extract the heuristic file-path
# target, and flag any target that does not exist on disk relative to
# the repo root.
#
# Usage: dead-grep-detector.sh [repo-root]   (defaults to cwd)
#
# Heuristic for "the target": the last argument to a grep invocation
# that does not start with '-' and is not the pattern immediately
# following a bare '-e' flag. Grep calls that read from stdin (piped
# in, no file argument) are skipped, as are targets that resolve to a
# bare word with no path shape (no '/' and no leading '$') — those are
# almost always leftover fragments of a multi-word quoted pattern, not
# a real file argument.

set -uo pipefail

ROOT="${1:-$(pwd)}"
if ! ROOT="$(cd "$ROOT" 2>/dev/null && pwd)"; then
    echo "dead-grep-detector: repo root '$1' does not exist" >&2
    exit 1
fi
SCAN_DIR="$ROOT/scripts/ci"

# Allowlist for known false positives (heuristic can't see a surrounding
# `[[ -f ... ]]` guard, a glob expansion, or a heredoc fixture that embeds
# example grep calls as literal text). Format: "rel/path:line  # reason".
# Kept narrow and per-line so it can't silently absorb a real dead target.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOWLIST_FILE="${DEAD_GREP_ALLOWLIST:-$SELF_DIR/dead-grep-detector-allowlist.txt}"
declare -A ALLOWLISTED
if [[ -f "$ALLOWLIST_FILE" ]]; then
    while IFS= read -r aline || [[ -n "$aline" ]]; do
        aline="${aline%%#*}"
        aline="$(printf '%s' "$aline" | tr -d '[:space:]')"
        [[ -z "$aline" ]] && continue
        ALLOWLISTED["$aline"]=1
    done < "$ALLOWLIST_FILE"
fi

if [[ ! -d "$SCAN_DIR" ]]; then
    echo "dead-grep-detector: no scripts/ci directory under $ROOT" >&2
    echo "Total absent targets: 0"
    exit 0
fi

# Truncate a post-"grep" segment at the earliest command-boundary
# delimiter (";", "|", "&&") that occurs OUTSIDE quotes, so trailing
# shell keywords / follow-on commands never get mistaken for the
# grep's own arguments — while a "|" used for regex alternation inside
# a quoted pattern (e.g. 'foo|bar') is left alone.
truncate_at_delims() {
    local s="$1"
    local out="" q="" ch nextch
    local i=0
    local len=${#s}
    while (( i < len )); do
        ch="${s:i:1}"
        if [[ -n "$q" ]]; then
            out+="$ch"
            [[ "$ch" == "$q" ]] && q=""
            i=$((i + 1))
            continue
        fi
        if [[ "$ch" == "'" || "$ch" == '"' ]]; then
            q="$ch"
            out+="$ch"
            i=$((i + 1))
            continue
        fi
        if [[ "$ch" == ';' || "$ch" == '|' ]]; then
            break
        fi
        nextch="${s:i+1:1}"
        if [[ "$ch" == '&' && "$nextch" == '&' ]]; then
            break
        fi
        out+="$ch"
        i=$((i + 1))
    done
    printf '%s' "$out"
}

# Strip quotes and trailing shell punctuation picked up by naive
# whitespace tokenization (";", ")", ",", "\").
clean_token() {
    local t="$1"
    while true; do
        case "$t" in
            *\;) t="${t%;}" ;;
            *\)) t="${t%)}" ;;
            *,) t="${t%,}" ;;
            *\\) t="${t%\\}" ;;
            *\") t="${t%\"}" ;;
            *\') t="${t%\'}" ;;
            *) break ;;
        esac
    done
    t="${t#\"}"
    t="${t#\'}"
    printf '%s' "$t"
}

is_dynamic() {
    [[ "$1" == *'$'* || "$1" == *'`'* ]]
}

is_path_shaped() {
    [[ "$1" == */* || "$1" == '$'* ]]
}

# Shell redirection tokens ("2>/dev/null", ">/dev/null", "2>&1") are not
# grep arguments at all — a naive tokenizer sees them as trailing
# non-dash words and must not mistake them for the file target.
is_redirect() {
    case "$1" in
        [0-9]'>'*|[0-9]'<'*|'>'*|'<'*|'&>'*) return 0 ;;
        *) return 1 ;;
    esac
}

is_skippable_literal() {
    case "$1" in
        then|do|done|fi|else|elif|esac|true|false|'') return 0 ;;
        *) return 1 ;;
    esac
}

findings_count=0
allowlisted_count=0
findings_out=""

while IFS= read -r -d '' file; do
    rel_file="${file#"$ROOT"/}"
    line_no=0
    prev_ends_pipe=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))

        cur_trim="$line"
        while [[ "$cur_trim" == *[[:space:]] ]]; do cur_trim="${cur_trim% }"; cur_trim="${cur_trim%	}"; done
        # A trailing line-continuation backslash can sit after the pipe
        # ("| \"); strip it before checking for a trailing pipe.
        [[ "$cur_trim" == *'\' ]] && cur_trim="${cur_trim%\\}"
        while [[ "$cur_trim" == *[[:space:]] ]]; do cur_trim="${cur_trim% }"; cur_trim="${cur_trim%	}"; done
        this_ends_pipe=false
        [[ "$cur_trim" == *'|' ]] && this_ends_pipe=true
        continuation_fed_by_pipe=$prev_ends_pipe
        prev_ends_pipe=$this_ends_pipe

        case "$line" in
            *grep*) ;;
            *) continue ;;
        esac

        # Comment-only lines (e.g. "# ...source-grep.sh...") trip the
        # substring match on "grep" without being a real invocation.
        trimmed_line="$line"
        while [[ "$trimmed_line" == [[:space:]]* ]]; do trimmed_line="${trimmed_line# }"; trimmed_line="${trimmed_line#	}"; done
        [[ "$trimmed_line" == \#* ]] && continue

        prefix="${line%%grep*}"
        p="$prefix"
        while [[ "$p" == *[[:space:]] ]]; do p="${p% }"; p="${p%	}"; done
        if [[ "$p" == *'|' ]]; then
            # grep is fed via a pipe (stdin) — no file argument to check.
            continue
        fi
        if [[ -z "$p" ]] && $continuation_fed_by_pipe; then
            # grep is the first word on this line, and the previous
            # (continuation) line ended in a pipe — still stdin-fed.
            continue
        fi
        if [[ -n "$p" && "${p: -1}" =~ [A-Za-z0-9_] ]]; then
            # "grep" is glued to a preceding word (pgrep, zgrep, ...) —
            # not the plain grep invocation we're heuristically scanning.
            continue
        fi
        # "grep" glued to a following word (grep_lines(...) in embedded
        # non-shell source) is a different identifier, not the command.
        suffix="${line#*grep}"
        if [[ -n "$suffix" && "${suffix:0:1}" =~ [A-Za-z0-9_] ]]; then
            continue
        fi
        # A herestring (<<<) feeds grep's stdin — no file argument.
        case "$line" in
            *'<<<'*) continue ;;
        esac

        segment="${line#*grep}"
        segment="$(truncate_at_delims "$segment")"

        # shellcheck disable=SC2206
        tokens=($segment)

        target=""
        skip_next=false
        for tok in "${tokens[@]}"; do
            if $skip_next; then
                skip_next=false
                continue
            fi
            if [[ "$tok" == "-e" ]]; then
                skip_next=true
                continue
            fi
            if [[ "$tok" == -* ]]; then
                continue
            fi
            if is_redirect "$tok"; then
                continue
            fi
            c="$(clean_token "$tok")"
            if is_skippable_literal "$c"; then
                continue
            fi
            target="$c"
        done

        [[ -n "$target" ]] || continue
        is_path_shaped "$target" || continue

        resolved="$target"
        case "$resolved" in
            '$REPO_ROOT/'*) resolved="$ROOT/${resolved#\$REPO_ROOT/}" ;;
            '${REPO_ROOT}/'*) resolved="$ROOT/${resolved#\$\{REPO_ROOT\}/}" ;;
        esac
        is_dynamic "$resolved" && continue

        # Runtime scratch paths (/tmp, .chump-locks/*.jsonl, docs/gaps/
        # fixture YAMLs) are created by the test at execution time, not
        # committed source — not a dead reference.
        case "$resolved" in
            /tmp/*|/var/tmp/*|/dev/*|/proc/*) continue ;;
            .chump-locks/*|*/.chump-locks/*) continue ;;
        esac

        candidate=""
        case "$resolved" in
            /*)
                if [[ "$resolved" == "$ROOT"/* ]]; then
                    candidate="$resolved"
                else
                    echo "WARN: absolute grep target '$resolved' at $rel_file:$line_no treated as relative to repo root ($ROOT)" >&2
                    candidate="$ROOT/${resolved#/}"
                fi
                ;;
            *)
                candidate="$ROOT/$resolved"
                ;;
        esac

        if [[ ! -e "$candidate" ]]; then
            key="${rel_file}:${line_no}"
            if [[ -n "${ALLOWLISTED[$key]:-}" ]]; then
                allowlisted_count=$((allowlisted_count + 1))
                continue
            fi
            findings_out+="${rel_file}:${line_no}  target=${resolved}
    ${line#"${line%%[![:space:]]*}"}
"
            findings_count=$((findings_count + 1))
        fi
    done < "$file"
done < <(find "$SCAN_DIR" -type f -print0 | sort -z)

if [[ "$findings_count" -gt 0 ]]; then
    echo "Dead grep targets found:"
    printf '%s' "$findings_out"
fi

echo "Total absent targets: $findings_count"
if [[ "${allowlisted_count:-0}" -gt 0 ]]; then
    echo "Allowlisted (known false positives, see $ALLOWLIST_FILE): $allowlisted_count"
fi

[[ "$findings_count" -eq 0 ]]
