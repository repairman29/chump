#!/usr/bin/env bash
# scripts/design/design-pass.sh — EFFECTIVE-358 (L3 design chair).
#
# Harness-neutral CLI that fills the "design" chair identified in
# docs/strategy/SOFTWARE_FACTORY_MATRIX_2026-08-05.md (DOC-079): the only
# design capability before this gap was the CSS token lint gate
# (INFRA-1590) — a gate, not a designer. This script runs AFTER intake
# (EFFECTIVE-357) has produced requirements + AC for a user-facing gap, and
# BEFORE implement starts writing UI code: it emits a written
# UI/brand/interaction spec, graded against
# docs/design/DESIGN_PASS_CHECKLIST.md, that the implement stage consumes.
#
# Rust-First-Bypass: glue between `chump gap show` + `claude -p` (same
# pattern as scripts/coord/opus-curator.sh Decision 2) + a markdown file
# write. Read-mostly; no canonical-state mutation (spec files are advisory
# artifacts under docs/design/specs/, not state.db rows).
#
# Usage:
#   scripts/design/design-pass.sh spec <GAP-ID> [--out <path>]
#   scripts/design/design-pass.sh help
#
# Exit codes:
#   0 — spec written
#   1 — missing/bad arg, gap not found
#   2 — bad subcommand
#   3 — chump CLI unreachable
#   4 — claude CLI unreachable or produced an unusable spec

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="${CHUMP_LOCK_DIR:-$MAIN_REPO/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
CHECKLIST="${CHUMP_DESIGN_CHECKLIST:-$ROOT/docs/design/DESIGN_PASS_CHECKLIST.md}"
SPEC_DIR="${CHUMP_DESIGN_SPEC_DIR:-$ROOT/docs/design/specs}"

usage() {
    sed -n '2,25p' "$0"
}

emit_ambient() {
    # emit_ambient <kind> <json-body-without-leading-brace>
    mkdir -p "$LOCK_DIR" 2>/dev/null || true
    printf '{"ts":"%s","kind":"%s",%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$AMBIENT_LOG" 2>/dev/null || true
}

cmd=${1:-help}
[ $# -gt 0 ] && shift || true

case "$cmd" in
    help|-h|--help)
        usage
        exit 0
        ;;
    spec)
        gap_id="${1:-}"
        [[ -n "$gap_id" ]] || { echo "design-pass.sh spec: missing GAP-ID" >&2; exit 1; }
        shift || true

        out_path="$SPEC_DIR/${gap_id}-design-spec.md"
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --out) out_path="$2"; shift 2 ;;
                *) echo "design-pass.sh spec: unknown arg $1" >&2; exit 1 ;;
            esac
        done

        command -v chump >/dev/null 2>&1 || { echo "design-pass.sh: chump CLI not on PATH" >&2; exit 3; }
        command -v claude >/dev/null 2>&1 || { echo "design-pass.sh: claude CLI not on PATH" >&2; exit 4; }
        [[ -f "$CHECKLIST" ]] || { echo "design-pass.sh: missing checklist $CHECKLIST" >&2; exit 1; }

        gap_yaml="$(chump gap show "$gap_id" 2>/dev/null || true)"
        [[ -n "$gap_yaml" ]] || { echo "design-pass.sh: gap $gap_id not found" >&2; exit 1; }

        title="$(printf '%s\n' "$gap_yaml" | awk '/^[[:space:]]*title:/ {sub(/^[[:space:]]*title:[[:space:]]*/, ""); print; exit}')"
        description="$(printf '%s\n' "$gap_yaml" | awk '/^[[:space:]]*description:/ {sub(/^[[:space:]]*description:[[:space:]]*/, ""); print; exit}')"
        ac="$(printf '%s\n' "$gap_yaml" | awk '/^[[:space:]]*acceptance_criteria:/ {sub(/^[[:space:]]*acceptance_criteria:[[:space:]]*/, ""); print; exit}')"
        checklist_body="$(cat "$CHECKLIST")"

        prompt="$(printf '%s' "You are the L3 design chair on a software factory. A gap has cleared
intake (requirements + acceptance criteria exist) and is about to enter
implement. Write a UI/brand/interaction design spec for it, graded against
the checklist below.

Gap: ${gap_id}
Title: ${title:-(untitled)}
Description: ${description:-(none provided)}
Acceptance criteria: ${ac:-(none provided)}

--- CHECKLIST ---
${checklist_body}
--- END CHECKLIST ---

Output a markdown document with EXACTLY these sections, each with a
concrete checkable statement (not a restatement of the question):

## Layout
## Spacing
## Typography / output hierarchy
## Interaction
## Brand-token compliance
## Consistency with the rest of the product
## Consumed by implement

The last section must name the specific file(s)/component(s) the implement
stage should treat as governed by this spec. Output ONLY the markdown
document — no preamble, no commentary outside the sections.")"

        spec_body="$(printf '%s\n' "$prompt" | claude -p --bare 2>/dev/null || true)"

        if [[ -z "$spec_body" ]] || ! grep -q '^## Consumed by implement' <<<"$spec_body"; then
            # scanner-anchor: "kind":"design_pass_spec_failed"
            emit_ambient "design_pass_spec_failed" "\"gap_id\":\"$gap_id\""
            echo "design-pass.sh: claude produced an unusable spec (missing required sections)" >&2
            exit 4
        fi

        mkdir -p "$SPEC_DIR"
        {
            printf '# Design spec — %s\n\n' "$gap_id"
            printf '> Generated by scripts/design/design-pass.sh against docs/design/DESIGN_PASS_CHECKLIST.md.\n'
            printf '> Gap title: %s\n\n' "${title:-(untitled)}"
            printf '%s\n' "$spec_body"
        } > "$out_path"

        # scanner-anchor: "kind":"design_pass_spec_emitted"
        emit_ambient "design_pass_spec_emitted" "\"gap_id\":\"$gap_id\",\"spec_path\":\"${out_path#"$ROOT"/}\""
        echo "$out_path"
        exit 0
        ;;
    *)
        echo "design-pass.sh: unknown subcommand '$cmd'" >&2
        usage >&2
        exit 2
        ;;
esac
