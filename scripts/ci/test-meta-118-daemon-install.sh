#!/usr/bin/env bash
# scripts/ci/test-meta-118-daemon-install.sh — INFRA-2280
#
# Smoke test for install-meta-118-daemons.sh.
# Runs in dry-run mode: generates plists to a temp dir, validates content.
# Does NOT call launchctl (safe in CI / non-macOS environments).
#
# Tests:
#   1. Dry-run install generates both plist files
#   2. novel-wedge-classifier plist has StartInterval=900
#   3. cascade-unblock-detector plist has StartInterval=300
#   4. Both plists reference correct executable paths
#   5. Both plists reference correct log paths (~/Library/Logs/chump/)
#   6. Both plists have required Label key
#   7. Both plists have WorkingDirectory set to REPO_ROOT
#   8. ProgramArguments uses /bin/bash + script path
#
# Usage:
#   bash scripts/ci/test-meta-118-daemon-install.sh
#   VERBOSE=1 bash scripts/ci/test-meta-118-daemon-install.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL_SCRIPT="$REPO_ROOT/scripts/setup/install-meta-118-daemons.sh"
VERBOSE="${VERBOSE:-0}"

PASS=0
FAIL=0
ERRORS=()

log()  { [[ "$VERBOSE" == "1" ]] && printf '[test-meta-118] %s\n' "$*" >&2 || true; }
pass() { PASS=$(( PASS + 1 )); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$(( FAIL + 1 )); ERRORS+=("$1"); printf 'FAIL  %s\n' "$1"; }

# ── Validate install script exists ───────────────────────────────────────────

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FATAL: install script not found: $INSTALL_SCRIPT" >&2
    exit 1
fi

# ── Create temp dirs to receive plists ────────────────────────────────────────

TMPDIR_PLISTS="$(mktemp -d)"
TMPDIR_LOGS="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_PLISTS" "$TMPDIR_LOGS"' EXIT

# ── Run install in dry-run mode with overridden paths ─────────────────────────
# We patch HOME so plist writes go to our temp dir instead of ~/Library/LaunchAgents/.
# dry-run flag prevents launchctl load from being called.

FAKE_HOME="$TMPDIR_PLISTS"
mkdir -p "$FAKE_HOME/Library/LaunchAgents"

log "running install --dry-run with FAKE_HOME=$FAKE_HOME"

CLASSIFIER_LABEL="com.chump.novel-wedge-classifier"
UNBLOCK_LABEL="com.chump.cascade-unblock-detector"
CLASSIFIER_PLIST="$FAKE_HOME/Library/LaunchAgents/${CLASSIFIER_LABEL}.plist"
UNBLOCK_PLIST="$FAKE_HOME/Library/LaunchAgents/${UNBLOCK_LABEL}.plist"

# Run the install script in dry-run mode. We override HOME so plist writes
# land in our temp dir. The script checks executable bits on the daemon scripts
# only in install mode (not dry-run), so we don't need those present in CI.
HOME="$FAKE_HOME" \
CHUMP_REPO_ROOT="$REPO_ROOT" \
    bash "$INSTALL_SCRIPT" --dry-run 2>/dev/null

DRY_RC=$?

if [[ "$DRY_RC" -ne 0 ]]; then
    fail "install --dry-run exited non-zero (rc=$DRY_RC)"
else
    pass "install --dry-run exited 0"
fi

# ── Test 1: Both plist files were generated ───────────────────────────────────

if [[ -f "$CLASSIFIER_PLIST" ]]; then
    pass "plist generated: $CLASSIFIER_LABEL"
else
    fail "plist NOT generated: $CLASSIFIER_LABEL (expected at $CLASSIFIER_PLIST)"
fi

if [[ -f "$UNBLOCK_PLIST" ]]; then
    pass "plist generated: $UNBLOCK_LABEL"
else
    fail "plist NOT generated: $UNBLOCK_LABEL (expected at $UNBLOCK_PLIST)"
fi

# Helper: extract value for a plist key (simple grep — plists are machine-generated)
plist_next_val() {
    local plist="$1" key="$2"
    # Matches: <key>KEY</key>\n    <string>VAL</string>
    #       or <key>KEY</key>\n    <integer>VAL</integer>
    #       or <key>KEY</key>\n    <true/>/<false/>
    python3 - "$plist" "$key" <<'PY' 2>/dev/null
import sys, xml.etree.ElementTree as ET
try:
    tree = ET.parse(sys.argv[1])
except Exception as e:
    print(f"PARSE_ERROR:{e}")
    sys.exit(0)
root = tree.getroot()
d = root.find("dict")
if d is None:
    sys.exit(0)
children = list(d)
for i, child in enumerate(children):
    if child.tag == "key" and child.text == sys.argv[2]:
        nxt = children[i + 1] if i + 1 < len(children) else None
        if nxt is not None:
            if nxt.tag in ("string", "integer"):
                print(nxt.text or "")
            else:
                print(nxt.tag)
        break
PY
}

plist_array_items() {
    local plist="$1" key="$2"
    python3 - "$plist" "$key" <<'PY' 2>/dev/null
import sys, xml.etree.ElementTree as ET
try:
    tree = ET.parse(sys.argv[1])
except Exception as e:
    print(f"PARSE_ERROR:{e}")
    sys.exit(0)
root = tree.getroot()
d = root.find("dict")
if d is None:
    sys.exit(0)
children = list(d)
for i, child in enumerate(children):
    if child.tag == "key" and child.text == sys.argv[2]:
        nxt = children[i + 1] if i + 1 < len(children) else None
        if nxt is not None and nxt.tag == "array":
            for item in nxt:
                print(item.text or "")
        break
PY
}

# ── Tests only run if both plists exist ───────────────────────────────────────

if [[ -f "$CLASSIFIER_PLIST" ]]; then
    # Test 2: StartInterval=900 for classifier
    classifier_interval="$(plist_next_val "$CLASSIFIER_PLIST" "StartInterval")"
    log "classifier StartInterval=$classifier_interval"
    if [[ "$classifier_interval" == "900" ]]; then
        pass "classifier StartInterval=900"
    else
        fail "classifier StartInterval expected 900, got '$classifier_interval'"
    fi

    # Test 4: correct executable path for classifier
    classifier_args=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && classifier_args+=("$line")
    done < <(plist_array_items "$CLASSIFIER_PLIST" "ProgramArguments")
    log "classifier ProgramArguments: ${classifier_args[*]+"${classifier_args[*]}"}"

    if [[ "${classifier_args[0]:-}" == "/bin/bash" ]]; then
        pass "classifier ProgramArguments[0]=/bin/bash"
    else
        fail "classifier ProgramArguments[0] expected /bin/bash, got '${classifier_args[0]:-MISSING}'"
    fi

    classifier_script_arg="${classifier_args[1]:-}"
    if [[ "$classifier_script_arg" == *"novel-wedge-classifier.sh" ]]; then
        pass "classifier ProgramArguments[1] references novel-wedge-classifier.sh"
    else
        fail "classifier ProgramArguments[1] expected novel-wedge-classifier.sh path, got '$classifier_script_arg'"
    fi

    # Test 5: log path contains Library/Logs/chump
    classifier_stdout="$(plist_next_val "$CLASSIFIER_PLIST" "StandardOutPath")"
    log "classifier StandardOutPath=$classifier_stdout"
    if [[ "$classifier_stdout" == *"Library/Logs/chump"* ]]; then
        pass "classifier log path contains Library/Logs/chump"
    else
        fail "classifier log path expected Library/Logs/chump, got '$classifier_stdout'"
    fi

    # Test 6: Label key
    classifier_label_val="$(plist_next_val "$CLASSIFIER_PLIST" "Label")"
    if [[ "$classifier_label_val" == "com.chump.novel-wedge-classifier" ]]; then
        pass "classifier Label=com.chump.novel-wedge-classifier"
    else
        fail "classifier Label expected com.chump.novel-wedge-classifier, got '$classifier_label_val'"
    fi

    # Test 7: WorkingDirectory = REPO_ROOT
    classifier_wd="$(plist_next_val "$CLASSIFIER_PLIST" "WorkingDirectory")"
    if [[ "$classifier_wd" == "$REPO_ROOT" ]]; then
        pass "classifier WorkingDirectory=$REPO_ROOT"
    else
        fail "classifier WorkingDirectory expected $REPO_ROOT, got '$classifier_wd'"
    fi
fi

if [[ -f "$UNBLOCK_PLIST" ]]; then
    # Test 3: StartInterval=300 for cascade-unblock-detector
    unblock_interval="$(plist_next_val "$UNBLOCK_PLIST" "StartInterval")"
    log "unblock StartInterval=$unblock_interval"
    if [[ "$unblock_interval" == "300" ]]; then
        pass "cascade-unblock-detector StartInterval=300"
    else
        fail "cascade-unblock-detector StartInterval expected 300, got '$unblock_interval'"
    fi

    # Test 4: correct executable path for unblock detector
    unblock_args=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && unblock_args+=("$line")
    done < <(plist_array_items "$UNBLOCK_PLIST" "ProgramArguments")
    log "unblock ProgramArguments: ${unblock_args[*]+"${unblock_args[*]}"}"

    if [[ "${unblock_args[0]:-}" == "/bin/bash" ]]; then
        pass "unblock ProgramArguments[0]=/bin/bash"
    else
        fail "unblock ProgramArguments[0] expected /bin/bash, got '${unblock_args[0]:-MISSING}'"
    fi

    unblock_script_arg="${unblock_args[1]:-}"
    if [[ "$unblock_script_arg" == *"cascade-unblock-detector.sh" ]]; then
        pass "unblock ProgramArguments[1] references cascade-unblock-detector.sh"
    else
        fail "unblock ProgramArguments[1] expected cascade-unblock-detector.sh path, got '$unblock_script_arg'"
    fi

    # Test 5: log path contains Library/Logs/chump
    unblock_stdout="$(plist_next_val "$UNBLOCK_PLIST" "StandardOutPath")"
    log "unblock StandardOutPath=$unblock_stdout"
    if [[ "$unblock_stdout" == *"Library/Logs/chump"* ]]; then
        pass "unblock log path contains Library/Logs/chump"
    else
        fail "unblock log path expected Library/Logs/chump, got '$unblock_stdout'"
    fi

    # Test 6: Label key
    unblock_label_val="$(plist_next_val "$UNBLOCK_PLIST" "Label")"
    if [[ "$unblock_label_val" == "com.chump.cascade-unblock-detector" ]]; then
        pass "unblock Label=com.chump.cascade-unblock-detector"
    else
        fail "unblock Label expected com.chump.cascade-unblock-detector, got '$unblock_label_val'"
    fi

    # Test 7: WorkingDirectory = REPO_ROOT
    unblock_wd="$(plist_next_val "$UNBLOCK_PLIST" "WorkingDirectory")"
    if [[ "$unblock_wd" == "$REPO_ROOT" ]]; then
        pass "unblock WorkingDirectory=$REPO_ROOT"
    else
        fail "unblock WorkingDirectory expected $REPO_ROOT, got '$unblock_wd'"
    fi
fi

# ── Test 8: bash -n syntax check on install script ────────────────────────────

if bash -n "$INSTALL_SCRIPT" 2>/dev/null; then
    pass "install-meta-118-daemons.sh passes bash -n"
else
    fail "install-meta-118-daemons.sh FAILS bash -n (syntax error)"
fi

if bash -n "$REPO_ROOT/scripts/coord/novel-wedge-classifier.sh" 2>/dev/null; then
    pass "novel-wedge-classifier.sh passes bash -n"
else
    fail "novel-wedge-classifier.sh FAILS bash -n (syntax error)"
fi

if bash -n "$REPO_ROOT/scripts/coord/cascade-unblock-detector.sh" 2>/dev/null; then
    pass "cascade-unblock-detector.sh passes bash -n"
else
    fail "cascade-unblock-detector.sh FAILS bash -n (syntax error)"
fi

# ── Results ───────────────────────────────────────────────────────────────────

echo ""
echo "=== test-meta-118-daemon-install: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    echo "FAILURES:"
    for e in "${ERRORS[@]}"; do
        echo "  - $e"
    done
    exit 1
fi

exit 0
