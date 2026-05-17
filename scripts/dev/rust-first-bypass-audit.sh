#!/usr/bin/env bash
# rust-first-bypass-audit.sh — INFRA-1580
#
# Read-only audit: walks scripts/coord/*.sh + scripts/setup/*.sh, applies the
# same 4 machine-checkable criteria the pre-commit STRICT gate uses, and
# emits one `kind=rust_first_bypass_audit` ambient event per violating file.
#
# Use case: backfill — which already-merged shell scripts would FAIL the
# stricter INFRA-1580 gate today? Helpful for prioritizing port-to-Rust work.
#
# This script does NOT mutate the offending files. It reads, classifies, and
# reports. No file is staged or modified.
#
# Output:
#   - stdout: one summary line per file, table-ish
#   - ambient.jsonl: one JSON event per violating file
#
# Usage:
#   scripts/dev/rust-first-bypass-audit.sh                  # default scan
#   scripts/dev/rust-first-bypass-audit.sh --json           # JSON-only output
#   scripts/dev/rust-first-bypass-audit.sh --paths "a b"    # custom paths

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "error: not in a git repo" >&2
    exit 2
}
cd "$REPO_ROOT"

AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
MODE="text"
PATHS=("scripts/coord" "scripts/setup")

while (( $# > 0 )); do
    case "$1" in
        --json)  MODE="json"; shift ;;
        --paths) shift; IFS=' ' read -r -a PATHS <<< "$1"; shift ;;
        *) echo "usage: $0 [--json] [--paths 'a b']" >&2; exit 2 ;;
    esac
done

_plist_references_basename() {
    local base="$1"
    if compgen -G "$HOME/Library/LaunchAgents/*.plist" > /dev/null 2>&1; then
        if grep -l "$base" "$HOME"/Library/LaunchAgents/*.plist >/dev/null 2>&1; then
            return 0
        fi
    fi
    if git ls-files '*.plist' 2>/dev/null | head -100 | xargs grep -l "$base" 2>/dev/null | grep -q .; then
        return 0
    fi
    return 1
}

_has_bypass() {
    local f="$1"
    grep -qE '^[[:space:]]*#?[[:space:]]*Rust-First-Bypass:' "$f" 2>/dev/null
}

_has_accept() {
    local f="$1"
    grep -qE '^[[:space:]]*#?[[:space:]]*Rust-First-Bypass-Accept:' "$f" 2>/dev/null
}

audit_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    local base
    base="$(basename "$f" .sh)"

    local viols=()

    # (1) LOC > 200
    local loc
    loc=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
    if [[ "${loc:-0}" -gt 200 ]]; then
        viols+=("loc")
    fi

    # (2) state mutation
    if grep -qE '\.chump-locks/[^[:space:]]+\.state|state\.db|ambient\.jsonl' "$f" 2>/dev/null; then
        viols+=("state")
    fi

    # (3) hot path
    if grep -qE '^[[:space:]]*while[[:space:]]+true' "$f" 2>/dev/null; then
        viols+=("hot")
    elif _plist_references_basename "$base"; then
        viols+=("hot")
    fi

    # (4) test sibling
    if [[ ! -f "$REPO_ROOT/scripts/ci/test-${base}.sh" ]]; then
        viols+=("test")
    fi

    if (( ${#viols[@]} == 0 )); then
        return 0
    fi

    local has_bypass=false has_ack=false
    if _has_bypass "$f"; then has_bypass=true; fi
    if _has_accept "$f"; then has_ack=true; fi

    local viol_csv
    viol_csv="$(IFS=,; echo "${viols[*]}")"

    if [[ "$MODE" == "text" ]]; then
        printf '%-55s violations=%-18s bypass=%-5s ack=%-5s loc=%s\n' \
            "$f" "$viol_csv" "$has_bypass" "$has_ack" "$loc"
    fi

    # Always emit to ambient (best-effort).
    if [[ -d "$(dirname "$AMBIENT")" ]]; then
        printf '{"ts":"%s","kind":"rust_first_bypass_audit","path":"%s","violations":"%s","has_bypass":%s,"has_acknowledgment":%s,"loc":%s}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$f" \
            "$viol_csv" \
            "$has_bypass" \
            "$has_ack" \
            "${loc:-0}" \
            >> "$AMBIENT" 2>/dev/null || true
    fi

    if [[ "$MODE" == "json" ]]; then
        printf '{"path":"%s","violations":"%s","has_bypass":%s,"has_acknowledgment":%s,"loc":%s}\n' \
            "$f" "$viol_csv" "$has_bypass" "$has_ack" "${loc:-0}"
    fi
}

count=0
violators=0
for p in "${PATHS[@]}"; do
    [[ -d "$REPO_ROOT/$p" ]] || continue
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        count=$((count + 1))
        before_lines=$(wc -l < "$AMBIENT" 2>/dev/null || echo 0)
        audit_file "$f"
        after_lines=$(wc -l < "$AMBIENT" 2>/dev/null || echo 0)
        if (( after_lines > before_lines )); then
            violators=$((violators + 1))
        fi
    done < <(find "$REPO_ROOT/$p" -maxdepth 1 -name '*.sh' -type f | sort)
done

if [[ "$MODE" == "text" ]]; then
    echo ""
    echo "scanned=$count violators=$violators"
fi
