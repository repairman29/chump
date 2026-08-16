#!/usr/bin/env bash
# bash-portability-lint.sh — INFRA-2351 (META-269 sub-2)
#
# Lints shell scripts for non-portable subprocess-call patterns that pass on
# the author's machine (GNU coreutils, GNU sed) but break on BSD/macOS
# runners or POSIX sh. Catches the class of bug BEFORE CI, not after.
#
# Checks:
#   1. GNU-only `sed -i` (in-place edit with no backup-suffix argument).
#      BSD/macOS sed requires an explicit (possibly empty) suffix arg;
#      omitting it is a GNU-only invocation that fails on macOS with
#      "sed: 1: ...: extra characters at the end of e command".
#   2. GNU-only `sed -r` (extended regex flag). BSD sed uses `-E`; `-r`
#      errors out on macOS.
#   3. GNU-only `date -d` / `date --date`. BSD/macOS date has no `-d` flag
#      (it uses `-j -f`); this is one of the most common cross-platform
#      script breakages in this repo's history.
#   4. Bashisms (`[[ ... ]]`, `local `, `function name()`) inside a script
#      whose shebang declares POSIX `sh` (`#!/bin/sh` or
#      `#!/usr/bin/env sh`) — these constructs are undefined behavior
#      under dash/POSIX sh even though they work under bash.
#
# Usage:
#   bash scripts/ci/bash-portability-lint.sh [file ...]
#   # no args: lints every scripts/**/*.sh tracked in git
#
# Exit 0 = clean. Exit 1 = at least one violation found (printed to stdout
# as `file:line: MESSAGE`).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

ALLOWLIST="$REPO_ROOT/scripts/ci/bash-portability-lint-allowlist.txt"

is_allowlisted() {
    local rel="$1"
    [[ -f "$ALLOWLIST" ]] || return 1
    while IFS= read -r entry; do
        entry="${entry%%#*}"
        entry="$(echo "$entry" | xargs)"
        [[ -z "$entry" ]] && continue
        [[ "$entry" == "$rel" ]] && return 0
    done < "$ALLOWLIST"
    return 1
}

VIOLATIONS=0

lint_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    local rel="${file#"$REPO_ROOT"/}"
    is_allowlisted "$rel" && return 0

    local shebang
    shebang="$(head -n1 "$file" 2>/dev/null || true)"
    local is_posix_sh=0
    if [[ "$shebang" == "#!/bin/sh" || "$shebang" == "#!/usr/bin/env sh" ]]; then
        is_posix_sh=1
    fi

    local lineno=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))

        # Skip comment-only lines (cheap heuristic, not a full shell parser).
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ "$trimmed" == \#* ]] && continue

        if [[ "$line" =~ sed[[:space:]]+-i[[:space:]] ]] && [[ ! "$line" =~ sed[[:space:]]+-i\'\' ]] && [[ ! "$line" =~ sed[[:space:]]+-i\.[A-Za-z0-9]+ ]]; then
            echo "$file:$lineno: GNU-only 'sed -i' with no backup-suffix arg (BSD/macOS sed requires one, e.g. sed -i '' or sed -i.bak)"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi

        if [[ "$line" =~ sed[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*[[:space:]] ]] && [[ "$line" == *"sed -r"* || "$line" == *"sed --regexp-extended"* ]]; then
            echo "$file:$lineno: GNU-only 'sed -r' (extended regex) — use portable 'sed -E'"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi

        if [[ "$line" =~ date[[:space:]]+(-d|--date)([[:space:]=]) ]]; then
            echo "$file:$lineno: GNU-only 'date -d/--date' — BSD/macOS date has no equivalent flag (use -j -f or a portable helper)"
            VIOLATIONS=$((VIOLATIONS + 1))
        fi

        if [[ "$is_posix_sh" == 1 ]]; then
            if [[ "$line" =~ \[\[ ]]; then
                echo "$file:$lineno: bashism '[[ ... ]]' in a #!/bin/sh script (undefined under POSIX sh/dash)"
                VIOLATIONS=$((VIOLATIONS + 1))
            fi
            if [[ "$line" =~ ^[[:space:]]*local[[:space:]] ]]; then
                echo "$file:$lineno: bashism 'local' in a #!/bin/sh script (not POSIX)"
                VIOLATIONS=$((VIOLATIONS + 1))
            fi
            if [[ "$line" =~ ^[[:space:]]*function[[:space:]] ]]; then
                echo "$file:$lineno: bashism 'function name()' in a #!/bin/sh script (use 'name()' for POSIX)"
                VIOLATIONS=$((VIOLATIONS + 1))
            fi
        fi
    done < "$file"
}

if [[ $# -gt 0 ]]; then
    for f in "$@"; do
        lint_file "$f"
    done
else
    while IFS= read -r f; do
        lint_file "$f"
    done < <(git -C "$REPO_ROOT" ls-files 'scripts/**/*.sh' 'scripts/*.sh' 2>/dev/null | sort -u)
fi

if [[ "$VIOLATIONS" -gt 0 ]]; then
    echo "bash-portability-lint: $VIOLATIONS violation(s) found" >&2
    exit 1
fi

exit 0
