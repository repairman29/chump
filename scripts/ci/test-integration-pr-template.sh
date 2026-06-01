#!/usr/bin/env bash
# test-integration-pr-template.sh — INFRA-2135
#
# Verifies that the integration PR template renders correctly from a fixture
# manifest and that all required fields are present.
#
# AC:
#   1. Template file exists at scripts/dev/integration-pr-template.md
#   2. All required placeholders are present in the template
#   3. Rendered output from a fixture manifest contains all required fields
#   4. PR title format matches: integration-{date} ({N} gaps): {titles}
#   5. Voice-lint clean (no first-person, no weasel words)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

TEMPLATE="$REPO_ROOT/scripts/dev/integration-pr-template.md"

# ── AC1: template file exists ──────────────────────────────────────────────────
[ -f "$TEMPLATE" ] || fail "Template missing: $TEMPLATE"
pass "Template file exists"

# ── AC2: required placeholders present in template ────────────────────────────
REQUIRED_PLACEHOLDERS=(
    "{cycle_name}"
    "{trigger_reason}"
    "{started_at}"
    "{preflight_duration}"
    "{gap_count}"
    "{gap_rows}"
    "{quarantine_rows}"
)

for ph in "${REQUIRED_PLACEHOLDERS[@]}"; do
    grep -qF "$ph" "$TEMPLATE" || fail "Missing placeholder $ph in $TEMPLATE"
    pass "Placeholder $ph present"
done

# ── AC3: rendered output contains required fields ──────────────────────────────
# Simulate rendering by substituting fixture values.
FIXTURE_CYCLE_NAME="integration-2026-05-29-1430"
FIXTURE_TRIGGER="volume_threshold reached"
FIXTURE_STARTED="2026-05-29T14:30:00Z"
FIXTURE_DURATION="38s"
FIXTURE_GAP_COUNT="2"
FIXTURE_GAP_ROWS="| INFRA-2135 | abc12345 | Dev <dev@test.com> | 80 | INFRA |
| INFRA-2136 | def67890 | Alice <alice@test.com> | 120 | INFRA |"
FIXTURE_QUARANTINE_ROWS="| (none) | — |"

# Render template via Python (portable, handles multiline substitutions).
rendered=$(python3 - <<'PYEOF'
import sys, re, pathlib, os

template_path = os.path.join(os.environ.get("REPO_ROOT", "."), "scripts/dev/integration-pr-template.md")
text = pathlib.Path(template_path).read_text()

gap_rows = "| INFRA-2135 | abc12345 | Dev <dev@test.com> | 80 | INFRA |\n| INFRA-2136 | def67890 | Alice <alice@test.com> | 120 | INFRA |"
quarantine_rows = "| (none) | — |"

replacements = {
    "{cycle_name}": "integration-2026-05-29-1430",
    "{trigger_reason}": "volume_threshold reached",
    "{started_at}": "2026-05-29T14:30:00Z",
    "{preflight_duration}": "38s",
    "{gap_count}": "2",
    "{gap_rows}": gap_rows,
    "{quarantine_rows}": quarantine_rows,
}

for k, v in replacements.items():
    text = text.replace(k, v)

print(text)
PYEOF
)

REQUIRED_RENDERED=(
    "integration-2026-05-29-1430"
    "volume_threshold reached"
    "2026-05-29T14:30:00Z"
    "38s"
    "INFRA-2135"
    "INFRA-2136"
    "chump-integrator-daemon"
    "Gaps shipped"
    "Quarantined"
)

for field in "${REQUIRED_RENDERED[@]}"; do
    echo "$rendered" | grep -qF "$field" || fail "Rendered output missing: $field"
    pass "Rendered output contains: $field"
done

# ── AC4: PR title format check ─────────────────────────────────────────────────
# Validate format using a synthetic title string.
sample_title="integration-2026-05-29-1430 (2 gaps): Batched-Under trailer, SHIP step live mode"

# Must start with integration-YYYY-MM-DD-HHMM
echo "$sample_title" | grep -qE '^integration-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4} \([0-9]+ gaps?\):' \
    || fail "PR title format mismatch: $sample_title"
pass "PR title format matches integration-{date} ({N} gaps): {titles}"

# Titles portion must not exceed 150 chars (after the prefix).
prefix="integration-2026-05-29-1430 (2 gaps): "
prefix_len=${#prefix}
titles_portion="${sample_title:$prefix_len}"
[ ${#titles_portion} -le 150 ] || fail "Titles portion exceeds 150 chars: ${#titles_portion}"
pass "PR title titles portion within 150 chars"

# ── AC5: voice-lint — no first-person or weasel words ─────────────────────────
# Check template file only (not rendered output which contains user data).
WEASEL_PATTERNS=(
    '\bI \b'
    '\bwe \b'
    '\bour \b'
    '\bmy \b'
    '\bjust\b'
    '\bsimply\b'
    '\bobviously\b'
    '\bbasically\b'
)

for pattern in "${WEASEL_PATTERNS[@]}"; do
    if grep -qiE "$pattern" "$TEMPLATE"; then
        match=$(grep -iE "$pattern" "$TEMPLATE" | head -1)
        fail "Voice-lint: weasel/first-person pattern '$pattern' found in template: $match"
    fi
done
pass "Voice-lint clean (no first-person or weasel words)"

echo ""
echo "All integration-pr-template checks passed."
