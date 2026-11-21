#!/usr/bin/env bash
# test-ci-fixture-coupling.sh — INFRA-505 lint guard.
#
# Scans scripts/ci/ for hardcoded real gap IDs in docs/gaps/<ID>.yaml
# references that lack a "why this is OK" comment within 10 lines above.
#
# What is flagged: bare `docs/gaps/<DOMAIN>-NNN.yaml` references where
# the path is NOT preceded by a shell variable (i.e., not safely inside a
# FAKE_REPO / TMP / SANDBOX temp-dir context) AND there is no
# "why this is OK:" comment within 10 lines above.
#
# What is NOT flagged (explicitly safe):
#   - `$FAKE_REPO/docs/gaps/...`, `"$TMP/.../docs/gaps/..."`, etc. —
#     the `$` prefix signals an isolated temp-dir path.
#   - Synthetic ID prefixes: TEST-*, SANDBOX-* (can never be real gap IDs).
#   - Comment-only lines (already annotated).
#   - References already covered by a "why this is OK:" comment ≤10 lines above.
#
# Exit 0 = clean. Exit 1 = violations found.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CI_DIR="$REPO_ROOT/scripts/ci"

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-505 CI fixture-coupling lint ==="
echo ""

# Match docs/gaps/<DOMAIN>-NNN.yaml or docs/gaps/<uuid>--slug.yaml (INFRA-630).
REAL_GAP_PATTERN='docs/gaps/([A-Z]+-[0-9]{3,}|[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}|[0-9a-f]{8}).*\.yaml'

violations=()

while IFS= read -r match; do
    file="${match%%:*}"
    rest="${match#*:}"
    lineno="${rest%%:*}"
    linetext="${rest#*:}"

    # Skip lines that are themselves comments.
    if echo "$linetext" | grep -qE '^\s*#'; then
        continue
    fi

    # Skip lines where docs/gaps/ is preceded by a shell variable ($FAKE_REPO,
    # $TMP, $SANDBOX, $FAKE, $TMPDIR_BASE, etc.) — those are isolated temp paths.
    if echo "$linetext" | grep -qE '\$[A-Za-z_]+/[^"]*docs/gaps/'; then
        continue
    fi
    # Also handle quoted variable paths like "$VAR/..."
    if echo "$linetext" | grep -qE '"\$[A-Za-z_].*docs/gaps/'; then
        continue
    fi

    # Skip synthetic ID prefixes that can never be real gap IDs.
    if echo "$linetext" | grep -qE 'docs/gaps/(TEST|SANDBOX)-'; then
        continue
    fi

    # Skip if a "why this is OK:" comment exists within 10 lines before or after.
    # The ±10 window handles heredoc content where the comment must follow the
    # closing delimiter (the reference is inside the heredoc, comment is after).
    total_lines=$(wc -l < "$file")
    start=$((lineno - 10)); [[ $start -lt 1 ]] && start=1
    end=$((lineno + 10)); [[ $end -gt $total_lines ]] && end=$total_lines
    context=$(sed -n "${start},${end}p" "$file" 2>/dev/null)
    if echo "$context" | grep -qi "why this is OK"; then
        continue
    fi

    violations+=("$file:$lineno: $linetext")
done < <(grep -rn --include="*.sh" -E "$REAL_GAP_PATTERN" "$CI_DIR" 2>/dev/null || true)

if [[ ${#violations[@]} -eq 0 ]]; then
    ok "no uncovered real-gap-ID fixture references found in scripts/ci/"
else
    for v in "${violations[@]}"; do
        fail "uncovered fixture reference: $v"
    done
    echo ""
    echo "Each reference above needs a '# why this is OK:' comment within"
    echo "10 lines above it (or the path must use a \$VAR/docs/gaps/ form)."
    echo "See AGENTS.md § 'CI test fixture conventions (INFRA-505)'."
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
