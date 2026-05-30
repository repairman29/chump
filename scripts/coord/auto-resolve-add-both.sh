#!/usr/bin/env bash
# scripts/coord/auto-resolve-add-both.sh — INFRA-2255
#
# Auto-resolve add-both / append-only conflicts on a fixed allowlist of file
# types that the merge-driver layer doesn't cover. Strips git conflict
# markers in-place, leaving content from BOTH sides intact.
#
# Allowlist (the only files this script will touch):
#   - scripts/ci/event-registry-reserved.txt
#   - Cargo.toml (workspace members list)
#   - docs/observability/EVENT_REGISTRY.yaml
#   - scripts/setup/bootstrap-manifest.yaml
#   - scripts/coord/cascade-rebase-trigger-paths.txt
#
# SAFETY CONTRACT — read before using:
#
# * Designed for ADDITIVE merges only. If HEAD added line X and the incoming
#   branch added line Y in the same conflict region, you end up with both
#   X and Y. That's correct for append-only registries.
# * REFUSES files outside the allowlist (exits non-zero). The caller must
#   classify files first; queue-driver.sh enforces this in cascade_rebase_if_hot.
# * Idempotent: running on an already-clean file is a no-op.
#
# Usage:
#   scripts/coord/auto-resolve-add-both.sh <file> [<file> ...]
#
# Exit codes:
#   0 — all files in allowlist + markers stripped
#   1 — usage error (no args)
#   2 — at least one file outside allowlist (no files modified)
#   3 — file not found / not readable
#   4 — internal sed/python failure

set -euo pipefail

usage() {
    cat <<'EOF'
usage: auto-resolve-add-both.sh <file> [<file> ...]

Strips git conflict markers from append-only files on a fixed allowlist,
preserving content from BOTH sides. Exits non-zero if any path is outside
the allowlist — caller (queue-driver.sh cascade_rebase_if_hot) is expected
to classify first.

Allowlist (exact basename or relative-to-repo path):
  - scripts/ci/event-registry-reserved.txt
  - Cargo.toml
  - docs/observability/EVENT_REGISTRY.yaml
  - scripts/setup/bootstrap-manifest.yaml
  - scripts/coord/cascade-rebase-trigger-paths.txt
EOF
}

if [[ $# -lt 1 ]]; then
    usage >&2
    exit 1
fi

# Allowlist — full repo-relative path OR basename match (for files moved by
# rename) is checked. Path-relative match wins; basename is fallback.
ALLOWLIST_PATHS=(
    "scripts/ci/event-registry-reserved.txt"
    "Cargo.toml"
    "docs/observability/EVENT_REGISTRY.yaml"
    "scripts/setup/bootstrap-manifest.yaml"
    "scripts/coord/cascade-rebase-trigger-paths.txt"
)

ALLOWLIST_BASENAMES=(
    "event-registry-reserved.txt"
    "Cargo.toml"
    "EVENT_REGISTRY.yaml"
    "bootstrap-manifest.yaml"
    "cascade-rebase-trigger-paths.txt"
)

is_allowlisted() {
    local f="$1"
    local rel base
    # Try repo-relative form (strip leading ./).
    rel="${f#./}"
    base="$(basename "$f")"
    for p in "${ALLOWLIST_PATHS[@]}"; do
        [[ "$rel" == "$p" || "$rel" == */"$p" ]] && return 0
    done
    for b in "${ALLOWLIST_BASENAMES[@]}"; do
        [[ "$base" == "$b" ]] && return 0
    done
    return 1
}

# Phase 1: classify ALL inputs before touching anything. Refuse the whole
# batch if any one is outside the allowlist — never partial-apply.
for f in "$@"; do
    if ! is_allowlisted "$f"; then
        printf 'auto-resolve-add-both: REFUSE — not in allowlist: %s\n' "$f" >&2
        exit 2
    fi
    if [[ ! -r "$f" || ! -w "$f" ]]; then
        printf 'auto-resolve-add-both: not readable/writable: %s\n' "$f" >&2
        exit 3
    fi
done

# Phase 2: strip markers in-place via python (portable across BSD/GNU sed).
for f in "$@"; do
    python3 - "$f" <<'PY' || exit 4
import re, sys
path = sys.argv[1]
with open(path, 'r') as fh:
    data = fh.read()
# Drop each marker line in full (including trailing newline).
data = re.sub(r'^<<<<<<< [^\n]*\n', '', data, flags=re.MULTILINE)
data = re.sub(r'^=======\n', '', data, flags=re.MULTILINE)
data = re.sub(r'^>>>>>>> [^\n]*\n', '', data, flags=re.MULTILINE)
with open(path, 'w') as fh:
    fh.write(data)
PY
    printf 'auto-resolve-add-both: stripped markers from %s\n' "$f"
done

exit 0
