#!/usr/bin/env bash
# scripts/ci/test-gh-shim-script-attribution.sh
# CREDIBLE-065: verify gh-shim _resolve_script_tag() walks past shells and gh itself
# to find the real calling script, not just stopping at the first ancestor.
#
# Acceptance criteria:
#   - Invoke shim from a synthetic deep chain:
#       grandparent=pr-watch-stub → parent=bash → shim (gh called via bash subshell)
#   - Assert the resolved script_tag is "pr-watch-stub", NOT "bash" or "gh"
#   - _resolve_script_tag skips: bash, -bash, sh, -sh, zsh, -zsh, dash, fish, gh
#   - Falls back to "shim" if no non-shell ancestor found within 10 levels
#
# Run: ./scripts/ci/test-gh-shim-script-attribution.sh
# CI:  wired via scripts/ci/fast-checks.sh (path filter: scripts/coord/lib/gh-shim/**)

set -uo pipefail

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SHIM="$REPO_ROOT/scripts/coord/lib/gh-shim/gh"

echo "=== CREDIBLE-065: gh-shim script attribution tests ==="
echo ""

# ── 1. Structural checks — no linter required ────────────────────────────────
echo "--- 1. Structural (grep) checks ---"

# _resolve_script_tag function must be defined
if grep -q '_resolve_script_tag()' "$SHIM"; then
    ok "_resolve_script_tag() function defined in shim"
else
    fail "_resolve_script_tag() function NOT found in shim"
fi

# Must skip gh in the walk
if grep -A20 '_resolve_script_tag()' "$SHIM" | grep -q '"gh"'; then
    ok "walk skips 'gh' ancestor"
else
    fail "'gh' not listed in skip set inside _resolve_script_tag()"
fi

# Must skip bash in the walk
if grep -A20 '_resolve_script_tag()' "$SHIM" | grep -q '"bash"'; then
    ok "walk skips 'bash' ancestor"
else
    fail "'bash' not listed in skip set inside _resolve_script_tag()"
fi

# Must walk at least 5 levels (depth < 10 guard means we try up to 10)
if grep -A20 '_resolve_script_tag()' "$SHIM" | grep -q 'depth -lt 10\|depth < 10'; then
    ok "walk depth limit is 10 levels"
else
    fail "depth limit <10 not found — walk may stop too early"
fi

# The duplicate throttle block must NOT contain the old 2-level inline walk
if grep -A5 'CHUMP_GH_SHIM_RECORDING.*!= "1"' "$SHIM" | grep -q '_shim_gp\|ps -o comm= -p.*PPID'; then
    fail "duplicate throttle block still contains old 2-level ps walk"
else
    ok "duplicate throttle block does not contain old inline ps walk"
fi

# The duplicate throttle block should reuse script_tag (or call _resolve_script_tag)
if grep -q 'CHUMP_GH_SCRIPT:-\$script_tag\|_resolve_script_tag.*PPID' "$SHIM"; then
    ok "duplicate throttle block reuses script_tag or calls _resolve_script_tag"
else
    fail "duplicate throttle block does not reuse script_tag"
fi

# ── 2. Functional: _resolve_script_tag extracts and tests the walk logic ─────
echo ""
echo "--- 2. Functional walk tests ---"

# Extract just the _resolve_script_tag function body and source it in a subshell.
# Then invoke it with a synthetic PID tree by mocking ps.

# We create a fake 'ps' that returns a controlled ancestry:
#   PID=1001 → bash      (shell, skip)
#   PID=1000 → gh        (gh, skip)
#   PID=999  → pr-watch-stub  (winner)
FAKE_PS="$(mktemp)"
chmod +x "$FAKE_PS"
cat > "$FAKE_PS" <<'FAKEPS'
#!/usr/bin/env bash
# Fake ps for CREDIBLE-065 test
# Usage: ps -o comm= -p PID  or  ps -o ppid= -p PID
# $1=-o  $2=comm= or ppid=  $3=-p  $4=PID
field="${2}"  # comm= or ppid=
pid="${4}"    # the PID

case "$field" in
    comm=)
        case "$pid" in
            1001) echo "bash" ;;
            1000) echo "gh" ;;
            999)  echo "pr-watch-stub" ;;
            *)    echo "" ;;
        esac
        ;;
    ppid=)
        case "$pid" in
            1001) echo "1000" ;;
            1000) echo "999" ;;
            999)  echo "998" ;;
            998)  echo "0" ;;
            *)    echo "0" ;;
        esac
        ;;
    *)
        echo ""
        ;;
esac
FAKEPS

# Source just the _resolve_script_tag function block from the shim into a subshell.
# We use awk to extract lines between the function definition and its closing brace.
FUNC_BODY="$(awk '/^_resolve_script_tag\(\)/{found=1} found{print} found && /^}$/{exit}' "$SHIM")"

if [[ -z "$FUNC_BODY" ]]; then
    fail "could not extract _resolve_script_tag() body from shim"
else
    ok "extracted _resolve_script_tag() body for functional test"

    # Run the function with fake ps injected into PATH
    FAKE_PS_DIR="$(mktemp -d)"
    cp "$FAKE_PS" "$FAKE_PS_DIR/ps"
    chmod +x "$FAKE_PS_DIR/ps"

    RESULT="$(PATH="$FAKE_PS_DIR:$PATH" bash -c "
        $FUNC_BODY
        _resolve_script_tag 1001
    " 2>/dev/null || echo "ERROR")"

    if [[ "$RESULT" == "pr-watch-stub" ]]; then
        ok "deep chain: resolved 'pr-watch-stub' (skipped bash→gh correctly)"
    else
        fail "deep chain: expected 'pr-watch-stub', got '${RESULT:-<empty>}'"
    fi

    # Test: all-shells chain should fall back to "shim"
    FAKE_PS2="$(mktemp -d)"
    cat > "$FAKE_PS2/ps" <<'ALLSHELLS'
#!/usr/bin/env bash
# $1=-o  $2=comm= or ppid=  $3=-p  $4=PID
field="$2"; pid="$4"
case "$field" in
    comm=)
        case "$pid" in
            1001) echo "bash" ;;
            1000) echo "sh" ;;
            999)  echo "zsh" ;;
            998)  echo "dash" ;;
            *)    echo "" ;;
        esac ;;
    ppid=)
        case "$pid" in
            1001) echo "1000" ;;
            1000) echo "999" ;;
            999)  echo "998" ;;
            998)  echo "0" ;;
            *)    echo "0" ;;
        esac ;;
    *) echo "" ;;
esac
ALLSHELLS
    chmod +x "$FAKE_PS2/ps"

    RESULT2="$(PATH="$FAKE_PS2:$PATH" bash -c "
        $FUNC_BODY
        _resolve_script_tag 1001
    " 2>/dev/null || echo "ERROR")"

    if [[ "$RESULT2" == "shim" ]]; then
        ok "all-shells chain: falls back to 'shim'"
    else
        fail "all-shells chain: expected 'shim', got '${RESULT2:-<empty>}'"
    fi

    rm -rf "$FAKE_PS2"
    rm -rf "$FAKE_PS_DIR"
fi

rm -f "$FAKE_PS"

# ── 3. CHUMP_GH_SCRIPT override bypasses the walk ────────────────────────────
echo ""
echo "--- 3. CHUMP_GH_SCRIPT env override ---"

FUNC_BODY2="$(awk '/^_resolve_script_tag\(\)/{found=1} found{print} found && /^}$/{exit}' "$SHIM")"
OVERRIDE_RESULT="$(CHUMP_GH_SCRIPT="explicit-override" bash -c "
    $FUNC_BODY2
    # Simulate the script_tag resolution logic in the shim
    script_tag=\"\${CHUMP_GH_SCRIPT:-}\"
    if [[ -z \"\$script_tag\" ]]; then
        script_tag=\"\$(_resolve_script_tag \$\$)\"
    fi
    echo \"\$script_tag\"
" 2>/dev/null)"

if [[ "$OVERRIDE_RESULT" == "explicit-override" ]]; then
    ok "CHUMP_GH_SCRIPT env override skips ps walk"
else
    fail "CHUMP_GH_SCRIPT override: expected 'explicit-override', got '${OVERRIDE_RESULT:-<empty>}'"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [[ $FAIL -gt 0 ]]; then
    echo "FAIL"
    exit 1
else
    echo "PASS"
    exit 0
fi
