#!/usr/bin/env bash
# test-gap-templates.sh — CI gate for INFRA-905
#
# Verifies:
#   1. scripts/ops/gap-template.sh exists and is executable
#   2. docs/gaps/TEMPLATES/ directory exists
#   3. All 3 template files are present
#   4. Each template has required YAML fields: id, domain, title, status, priority, effort, acceptance_criteria
#   5. AC examples in each template are non-empty
#   6. gap-template.sh --pillar EFFECTIVE outputs the EFFECTIVE template
#   7. gap-template.sh --pillar CREDIBLE outputs the CREDIBLE template
#   8. gap-template.sh --pillar RESILIENT outputs the RESILIENT template
#   9. gap-template.sh --pillar ZERO-WASTE outputs content (aliases to EFFECTIVE style)
#  10. gap-template.sh --pillar MISSION outputs content (aliases to CREDIBLE style)
#  11. gap-template.sh --list lists available templates
#  12. gap-template.sh with unknown pillar exits non-zero
#  13. gap-template.sh --pillar with no PILLAR arg exits non-zero
#  14. gap-template.sh with no args exits non-zero

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCRIPT="$REPO_ROOT/scripts/ops/gap-template.sh"
TEMPLATES_DIR="$REPO_ROOT/docs/gaps/TEMPLATES"

pass=0
fail=0

ok()  { echo "  PASS $1"; pass=$((pass + 1)); }
err() { echo "  FAIL $1"; fail=$((fail + 1)); }

echo "=== test-gap-templates.sh ==="

# Test 1: script exists and is executable
if [[ -x "$SCRIPT" ]]; then
    ok "1: gap-template.sh exists and is executable"
else
    err "1: gap-template.sh missing or not executable (path: $SCRIPT)"
fi

# Test 2: TEMPLATES directory exists
if [[ -d "$TEMPLATES_DIR" ]]; then
    ok "2: docs/gaps/TEMPLATES/ directory exists"
else
    err "2: docs/gaps/TEMPLATES/ directory missing"
fi

# Test 3: all 3 template files present
for tpl in EFFECTIVE CREDIBLE RESILIENT; do
    f="$TEMPLATES_DIR/${tpl}-gap-template.md"
    if [[ -f "$f" ]]; then
        ok "3-${tpl}: ${tpl}-gap-template.md exists"
    else
        err "3-${tpl}: ${tpl}-gap-template.md missing"
    fi
done

# Test 4: each template has required YAML fields
_required_fields="id domain title status priority effort acceptance_criteria"
for tpl in EFFECTIVE CREDIBLE RESILIENT; do
    f="$TEMPLATES_DIR/${tpl}-gap-template.md"
    [[ -f "$f" ]] || continue
    for field in $_required_fields; do
        if grep -q "^${field}:" "$f"; then
            ok "4-${tpl}-${field}: ${tpl} template has '${field}:' field"
        else
            err "4-${tpl}-${field}: ${tpl} template missing '${field}:' field"
        fi
    done
done

# Test 5: AC examples non-empty in each template
for tpl in EFFECTIVE CREDIBLE RESILIENT; do
    f="$TEMPLATES_DIR/${tpl}-gap-template.md"
    [[ -f "$f" ]] || continue
    # Count lines under acceptance_criteria that start with '  -'
    ac_count=$(grep -c '^  - ' "$f" 2>/dev/null || echo 0)
    if [[ "$ac_count" -ge 2 ]]; then
        ok "5-${tpl}: ${tpl} template has ${ac_count} AC example(s) (≥2)"
    else
        err "5-${tpl}: ${tpl} template has only ${ac_count} AC example(s) (need ≥2)"
    fi
done

# Test 6: --pillar EFFECTIVE outputs EFFECTIVE template content
if [[ -x "$SCRIPT" ]]; then
    _out=$(REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --pillar EFFECTIVE 2>/dev/null)
    if echo "$_out" | grep -q "EFFECTIVE"; then
        ok "6: --pillar EFFECTIVE outputs EFFECTIVE template"
    else
        err "6: --pillar EFFECTIVE did not output EFFECTIVE content"
    fi
fi

# Test 7: --pillar CREDIBLE outputs CREDIBLE template content
if [[ -x "$SCRIPT" ]]; then
    _out=$(REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --pillar CREDIBLE 2>/dev/null)
    if echo "$_out" | grep -q "CREDIBLE"; then
        ok "7: --pillar CREDIBLE outputs CREDIBLE template"
    else
        err "7: --pillar CREDIBLE did not output CREDIBLE content"
    fi
fi

# Test 8: --pillar RESILIENT outputs RESILIENT template content
if [[ -x "$SCRIPT" ]]; then
    _out=$(REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --pillar RESILIENT 2>/dev/null)
    if echo "$_out" | grep -q "RESILIENT"; then
        ok "8: --pillar RESILIENT outputs RESILIENT template"
    else
        err "8: --pillar RESILIENT did not output RESILIENT content"
    fi
fi

# Test 9: --pillar ZERO-WASTE outputs content (alias)
if [[ -x "$SCRIPT" ]]; then
    _out=$(REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --pillar ZERO-WASTE 2>/dev/null)
    if [[ -n "$_out" ]]; then
        ok "9: --pillar ZERO-WASTE outputs content (alias)"
    else
        err "9: --pillar ZERO-WASTE produced no output"
    fi
fi

# Test 10: --pillar MISSION outputs content (alias)
if [[ -x "$SCRIPT" ]]; then
    _out=$(REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --pillar MISSION 2>/dev/null)
    if [[ -n "$_out" ]]; then
        ok "10: --pillar MISSION outputs content (alias)"
    else
        err "10: --pillar MISSION produced no output"
    fi
fi

# Test 11: --list lists available templates
if [[ -x "$SCRIPT" ]]; then
    _out=$(REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --list 2>/dev/null)
    if echo "$_out" | grep -qE "(EFFECTIVE|CREDIBLE|RESILIENT)"; then
        ok "11: --list lists available templates"
    else
        err "11: --list did not list templates (got: $_out)"
    fi
fi

# Test 12: unknown pillar exits non-zero
if [[ -x "$SCRIPT" ]]; then
    if ! REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" --pillar BADPILLAR >/dev/null 2>&1; then
        ok "12: unknown pillar exits non-zero"
    else
        err "12: unknown pillar should exit non-zero but exited 0"
    fi
fi

# Test 13: no args exits non-zero
if [[ -x "$SCRIPT" ]]; then
    if ! REPO_ROOT="$REPO_ROOT" bash "$SCRIPT" >/dev/null 2>&1; then
        ok "13: no args exits non-zero"
    else
        err "13: no args should exit non-zero but exited 0"
    fi
fi

# Test 14: INFRA-905 referenced in gap-template.sh
if grep -q "INFRA-905" "$SCRIPT" 2>/dev/null; then
    ok "14: INFRA-905 referenced in gap-template.sh"
else
    err "14: INFRA-905 not referenced in gap-template.sh"
fi

echo ""
echo "Results: $pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
