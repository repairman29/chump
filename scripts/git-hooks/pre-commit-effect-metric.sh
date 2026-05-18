#!/usr/bin/env bash
# pre-commit-effect-metric.sh — INFRA-1517
#
# Enforces that every NEW entry added to docs/observability/EVENT_REGISTRY.yaml
# has an `effect_metric:` field. Prevents silent observability blind-spots
# where a kind is registered but no metric proves the emit is doing its job.
#
# Background: INFRA-1399 added bot_merge_stall_detected + bot_merge_test_gate_skipped
# without effect_metric, causing audit CI exit-code-3 on 8+ PRs on 2026-05-16.
#
# What counts as an effect_metric:
#   - Any non-empty string value including "self" (the kind is its own metric).
#
# Bypass:
#   CHUMP_EFFECT_METRIC_CHECK=0 git commit ...
#   (commit body should include `Effect-Metric-Bypass: <reason>` trailer)

set -uo pipefail

if [[ "${CHUMP_EFFECT_METRIC_CHECK:-1}" == "0" ]]; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
REGISTRY_REL="docs/observability/EVENT_REGISTRY.yaml"
REGISTRY="$REPO_ROOT/$REGISTRY_REL"

# Nothing to check if the registry is not staged.
if ! git diff --cached --name-only | grep -qF "$REGISTRY_REL"; then
    exit 0
fi

# Nothing to check if registry file doesn't exist yet.
if [[ ! -f "$REGISTRY" ]]; then
    exit 0
fi

# Find newly added `kind:` entries in the staged diff.
NEW_KINDS=$(git diff --cached -U0 -- "$REGISTRY_REL" 2>/dev/null \
    | grep '^+  - kind:' \
    | sed -E 's/^\+  - kind:[[:space:]]*//' \
    | tr -d '"' \
    | sort -u)

if [[ -z "$NEW_KINDS" ]]; then
    exit 0
fi

# For each new kind, verify the staged file content has an effect_metric block.
# We read the full staged content (`:path` in git show = index version).
STAGED_CONTENT=$(git show ":$REGISTRY_REL" 2>/dev/null) || {
    # If index read fails (e.g. untracked — shouldn't happen), skip check.
    exit 0
}

MISSING=()

while IFS= read -r kind; do
    [[ -z "$kind" ]] && continue

    # Extract the YAML block for this kind from the staged file:
    # lines from "  - kind: <kind>" up to (not including) the next "  - kind:".
    block=$(awk "
        /^  - kind:[[:space:]]*${kind}[[:space:]]*\$/ { found=1; print; next }
        found && /^  - kind:/ { found=0 }
        found { print }
    " <<< "$STAGED_CONTENT")

    if ! echo "$block" | grep -qE '^[[:space:]]+effect_metric:'; then
        MISSING+=("$kind")
    fi
done <<< "$NEW_KINDS"

if [[ "${#MISSING[@]}" -eq 0 ]]; then
    exit 0
fi

# Block the commit.
echo "──────────────────────────────────────────────────────────────────────" >&2
echo "❌ INFRA-1517 effect-metric guard blocked this commit." >&2
echo "" >&2
echo "New EVENT_REGISTRY entries missing effect_metric field:" >&2
for k in "${MISSING[@]}"; do
    echo "    kind: $k" >&2
done
echo "" >&2
echo "Every registered kind must declare which metric proves the emit works." >&2
echo "Use 'effect_metric: self' if the kind's own count is the signal." >&2
echo "See docs/observability/EVENT_REGISTRY_FORMAT.md for examples." >&2
echo "" >&2
echo "Fix: add to each new entry in EVENT_REGISTRY.yaml:" >&2
echo "      effect_metric: <metric-name>   # or 'self'" >&2
echo "" >&2
echo "Bypass (sparingly):" >&2
echo "      CHUMP_EFFECT_METRIC_CHECK=0 git commit ..." >&2
echo "  and add to commit body:" >&2
echo "      Effect-Metric-Bypass: <reason>" >&2
echo "──────────────────────────────────────────────────────────────────────" >&2

exit 1
