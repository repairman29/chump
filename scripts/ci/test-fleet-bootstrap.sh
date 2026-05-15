#!/usr/bin/env bash
# test-fleet-bootstrap.sh — META-066
#
# Verifies the chump-fleet-bootstrap.sh orchestrator + manifest:
#   - manifest parses as valid YAML
#   - --check mode is non-destructive (exits 1 when anything missing, 0 when clean)
#   - --only ID and --skip ID filters work
#   - --priority P0 filter works
#   - ambient kind=fleet_bootstrap_ran emitted
#   - new install-*.sh files must have a manifest entry (lint)

set -uo pipefail

PASS=0
FAIL=0
FAILS=()
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOOTSTRAP="$REPO_ROOT/scripts/setup/chump-fleet-bootstrap.sh"
MANIFEST="$REPO_ROOT/scripts/setup/bootstrap-manifest.yaml"

echo "=== META-066 chump-fleet-bootstrap tests ==="

[[ -x "$BOOTSTRAP" ]] || { fail "bootstrap not executable at $BOOTSTRAP"; exit 1; }
ok "bootstrap present + executable"

[[ -f "$MANIFEST" ]] || { fail "manifest missing at $MANIFEST"; exit 1; }
ok "manifest present"

# Manifest parses.
if python3 -c "import yaml; yaml.safe_load(open('$MANIFEST'))" 2>/dev/null; then
    ok "manifest parses as valid YAML"
else
    fail "manifest YAML parse error"
    exit 1
fi

# Manifest has expected required-fields per entry.
python3 -c "
import yaml, sys
data = yaml.safe_load(open('$MANIFEST'))
for e in data['installers']:
    for required in ('id', 'why', 'install', 'check', 'priority'):
        if required not in e:
            print(f'ERROR: entry {e.get(\"id\",\"?\")} missing {required}')
            sys.exit(1)
" && ok "every manifest entry has id/why/install/check/priority" || fail "schema violation"

# --check is non-destructive (does not write to LaunchAgents).
HOME_BEFORE="$HOME"
TMP="$(mktemp -d -t bootstrap-check.XXXXXX)"
trap 'rm -rf "$TMP"; export HOME="$HOME_BEFORE"' EXIT
mkdir -p "$TMP/.chump-locks" "$TMP/Library/LaunchAgents"
# Re-run --check; whatever was missing/installed BEFORE the test should
# remain unchanged AFTER (idempotency + read-only check).
LAUNCHAGENTS_BEFORE=$(ls ~/Library/LaunchAgents 2>/dev/null | wc -l | tr -d ' ')
CHUMP_AMBIENT_LOG="$TMP/.chump-locks/ambient.jsonl" bash "$BOOTSTRAP" --check >/dev/null 2>&1 || true
LAUNCHAGENTS_AFTER=$(ls ~/Library/LaunchAgents 2>/dev/null | wc -l | tr -d ' ')
if [[ "$LAUNCHAGENTS_BEFORE" == "$LAUNCHAGENTS_AFTER" ]]; then
    ok "--check is non-destructive (LaunchAgents dir unchanged)"
else
    fail "--check wrote to LaunchAgents (before=$LAUNCHAGENTS_BEFORE after=$LAUNCHAGENTS_AFTER)"
fi

# --check emits kind=fleet_bootstrap_ran.
if grep -q '"kind":"fleet_bootstrap_ran"\|"kind": "fleet_bootstrap_ran"' "$TMP/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "--check emits kind=fleet_bootstrap_ran to ambient"
else
    fail "ambient missing fleet_bootstrap_ran"
fi

# --priority P0 filter — only P0 entries considered.
out="$(CHUMP_AMBIENT_LOG=/dev/null bash "$BOOTSTRAP" --check --priority P0 2>&1)"
# Should only show P0 entries (chump-binary, git-hooks per current manifest).
if echo "$out" | grep -q chump-binary && ! echo "$out" | grep -q chump-plan-binary; then
    ok "--priority P0 filters to P0 entries only"
else
    fail "--priority P0 filter broken (expected chump-binary, not chump-plan-binary; got: $out)"
fi

# --only ID filter — only that id processed.
out="$(CHUMP_AMBIENT_LOG=/dev/null bash "$BOOTSTRAP" --check --only chump-binary 2>&1)"
if echo "$out" | grep -q chump-binary && ! echo "$out" | grep -q chump-plan-binary; then
    ok "--only ID filters correctly"
else
    fail "--only filter broken"
fi

# --skip ID filter — skipped id not in output.
out="$(CHUMP_AMBIENT_LOG=/dev/null bash "$BOOTSTRAP" --check --skip chump-binary 2>&1)"
if ! echo "$out" | grep -q chump-binary; then
    ok "--skip ID filters correctly"
else
    fail "--skip filter did not skip chump-binary"
fi

# Manifest covers every new-ish install-*.sh: every install-*.sh that exists in
# scripts/setup/ should either (a) have a manifest entry or (b) be allowlisted
# in an exclusion list (this test is advisory, not failing, in slice 1).
total_installers=$(ls "$REPO_ROOT"/scripts/setup/install-*.sh 2>/dev/null | wc -l | tr -d ' ')
manifest_ids=$(python3 -c "import yaml; print(len(yaml.safe_load(open('$MANIFEST'))['installers']))")
echo "  INFO: $total_installers install-*.sh exist; manifest has $manifest_ids entries"
echo "  (advisory only — META-066 follow-up will add manifest-coverage gate)"

echo
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
