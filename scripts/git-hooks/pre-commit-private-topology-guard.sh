#!/usr/bin/env bash
# pre-commit-private-topology-guard.sh — RESILIENT-1546
#
# INFRA-7881 deliberately removed operator node topology from this PUBLIC
# repo: docs/fleet/nodes/*.json (per-node registry entries) and
# scripts/ops/fleet-nodes.conf (fleet topology) moved to
# $CHUMP_NODE_REGISTRY_DIR / $CHUMP_FLEET_NODES_CONF (default under $HOME,
# outside every git tree). Nothing GATED re-adding them — the orphaned
# RESILIENT-1032 branch (2026-10-06 audit) still carried a real node file
# (closetjunky.json) and would have re-leaked it if shipped. This guard
# makes re-adding those paths fail instead of relying on review.
#
# `git ls-files` reflects the INDEX, which already includes freshly staged
# adds before commit — so the same check works unchanged as a pre-commit
# hook (index) and as a CI step (checked-out tree after `actions/checkout`).
#
# Explicitly allowed (shape-only, no real topology): docs/fleet/nodes/README.md,
# docs/fleet/nodes/example-node.json, scripts/ops/fleet-nodes.conf.example.
#
# No bypass trailer. This is a leak guard, not a style gate — if a path
# genuinely needs to move back to the public tree, that is an INFRA-7881
# policy change, not a one-commit bypass.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT" || exit 1

VIOLATIONS=""

while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in
        docs/fleet/nodes/README.md|docs/fleet/nodes/example-node.json) ;;
        *) VIOLATIONS+="$f"$'\n' ;;
    esac
done < <(git ls-files -- 'docs/fleet/nodes/*.json' 2>/dev/null)

while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in
        scripts/ops/fleet-nodes.conf.example) ;;
        *) VIOLATIONS+="$f"$'\n' ;;
    esac
done < <(git ls-files -- 'scripts/ops/fleet-nodes.conf' 2>/dev/null)

if [[ -z "$VIOLATIONS" ]]; then
    exit 0
fi

echo "[private-topology-guard] private operator node topology found in the public tree (RESILIENT-1546):" >&2
echo "$VIOLATIONS" >&2
echo "" >&2
echo "INFRA-7881 moved operator node topology out of this public repo on purpose:" >&2
echo "  docs/fleet/nodes/*.json      -> \$CHUMP_NODE_REGISTRY_DIR (default ~/.chump/fleet/nodes)" >&2
echo "  scripts/ops/fleet-nodes.conf -> \$CHUMP_FLEET_NODES_CONF (default ~/.chump/fleet-nodes.conf)" >&2
echo "Remove the file(s) above from this commit/PR and keep the real topology in your local" >&2
echo "operator state dir. Shape-only examples (example-node.json, fleet-nodes.conf.example,"  >&2
echo "README.md) are fine; real per-node entries are not. There is no bypass for this gate." >&2
exit 1
