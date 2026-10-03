#!/usr/bin/env bash
# rules-registry-gen.sh — ZERO-WASTE-125 AC1
#
# Generates docs/process/RULE_REGISTRY.json: one entry per git hook, CI test
# gate, and known gap-reserve gate, each with a stable id, its source file,
# and the signal it fires (an ambient kind, or its own basename for gates
# with no ambient instrumentation yet — a gap `chump rules audit` surfaces).
#
# Re-run this whenever a new git hook or scripts/ci/test-*.sh gate lands.
# scripts/ci/test-rules-registry-coverage.sh fails CI if the committed
# registry is stale relative to what's actually on disk.
#
# Usage: scripts/coord/rules-registry-gen.sh [--out <path>]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

OUT="docs/process/RULE_REGISTRY.json"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

{
    printf '{\n'
    printf '  "_generated_by": "scripts/coord/rules-registry-gen.sh",\n'
    printf '  "_note": "ZERO-WASTE-125 AC1 — do not hand-edit; re-run the generator",\n'
    printf '  "rules": [\n'

    first=1
    emit() {
        local id="$1" source="$2" signal="$3" protected="$4"
        if [[ $first -eq 0 ]]; then printf ',\n'; fi
        first=0
        printf '    {"id": "%s", "source": "%s", "signal": "%s", "protected": %s}' \
            "$id" "$source" "$signal" "$protected"
    }

    # --- git hooks (scripts/git-hooks/*) ---------------------------------
    while IFS= read -r hook; do
        base="$(basename "$hook")"
        case "$base" in
            commit-msg|pre-commit|pre-push|post-checkout|post-commit|lib) continue ;;
        esac
        [[ -f "$hook" ]] || continue
        id="githook:${base}"
        emit "$id" "scripts/git-hooks/${base}" "kind=${base//-/_}_bypassed" false
    done < <(find scripts/git-hooks -maxdepth 1 -type f -name '*.sh' | sort)

    # --- CI test gates (scripts/ci/test-*.sh) ----------------------------
    while IFS= read -r t; do
        base="$(basename "$t" .sh)"
        id="ci:${base}"
        emit "$id" "scripts/ci/${base}.sh" "ci_check=${base}" false
    done < <(find scripts/ci -maxdepth 1 -type f -name 'test-*.sh' | sort)

    # --- gap-reserve intake gates (known, hand-enumerated — INFRA-code) --
    emit "reserve:outcome-required" "src/main.rs (chump gap reserve --priority P0|P1)" \
        "kind=gap_reserve_outcome_required_block" false
    emit "reserve:similarity-check" "src/main.rs (chump gap reserve, INFRA-1149)" \
        "kind=gap_reserve_similarity_block" false
    emit "reserve:evidence-required" "src/main.rs (chump gap reserve evidence gate)" \
        "kind=gap_reserve_evidence_block" false

    printf '\n  ],\n'
    printf '  "protected_floor_note": "protected:true rules are never auto-pruned regardless of audit data — see ZERO-WASTE-125 AC5 / docs/process/RULE_REGISTRY.md"\n'
    printf '}\n'
} > "$TMP"

mkdir -p "$(dirname "$OUT")"
cp "$TMP" "$OUT"
echo "wrote $(grep -c '"id"' "$OUT") rule entries to $OUT" >&2
