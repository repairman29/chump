#!/usr/bin/env bash
# test-plist-no-tmp-paths.sh — INFRA-2419
#
# CI gate: ensure no plist template bakes ephemeral temp paths into
# ProgramArguments or WorkingDirectory keys.
#
# Root cause this prevents: com.chump.integrator-daemon crash-looped 145 times
# over 37+ hours (2026-06-01) because the plist had
#   cd /private/tmp/chump-install
# baked into ProgramArguments. That directory was reaped after install,
# causing every 15-minute daemon invocation to fail silently.
#
# SCOPE:
#   - scripts/launchd/*.plist   (checked-in plist templates, Method A)
#   - .chump/launchd/*.plist    (dot-dir plist templates, Method A)
#   - scripts/setup/install-*-launchd.sh  (installer-generated plists, Method B)
#     Method B: static grep for ProgramArguments/WorkingDirectory context
#     containing forbidden patterns in the heredoc-generated plist content.
#     No --print-plist flag exists on these installers; static grep is safe.
#
# FORBIDDEN PATTERNS (inside ProgramArguments or WorkingDirectory XML):
#   /tmp/          /private/tmp/    /var/folders/    $TMPDIR    ${TMPDIR}
#
# Note: /tmp/ in StandardOutPath / StandardErrorPath (log file paths) is
# NOT flagged by this gate. Those paths are intentional and survivable:
# if a log file dir is reaped, the daemon simply recreates it; the daemon
# does not cd into a log dir. The crash-loop root cause was a cd target
# inside ProgramArguments, not a log path.
#
# Usage:
#   bash scripts/ci/test-plist-no-tmp-paths.sh
#   REPO_ROOT=/path bash scripts/ci/test-plist-no-tmp-paths.sh
#
# Exit codes:
#   0 — all checked files are clean (or violations are allowlisted)
#   1 — at least one unallowlisted violation found

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
EXEMPT_LIST="${REPO_ROOT}/scripts/ci/plist-lint-exempt.txt"

# Forbidden patterns (must not appear in ProgramArguments or WorkingDirectory)
FORBIDDEN_PATTERNS=(
    '/tmp/'
    '/private/tmp/'
    '/var/folders/'
    '$TMPDIR'
    '${TMPDIR}'
)

fail=0
pass=0
exempt=0
VIOLATIONS=()

# ── Helper: load exemption list ───────────────────────────────────────────────
_is_exempt() {
    local file="$1"
    local key="$2"
    local pattern="$3"
    local basename
    basename="$(basename "$file")"
    if [[ ! -f "$EXEMPT_LIST" ]]; then
        return 1
    fi
    # Match lines like: <filename> <key> <pattern>  # reason: ...
    # OR lines that just match the filename for broad exemption
    while IFS= read -r line; do
        # Skip comments and blank lines
        case "$line" in
            '#'*|'') continue ;;
        esac
        entry="${line%%  #*}"  # strip inline comment
        entry="${entry%%	#*}"  # strip tab-preceded comment
        entry="${entry%% }"    # trim trailing space
        if [[ "$entry" == "$basename $key $pattern" || "$entry" == "$basename" ]]; then
            return 0
        fi
    done < "$EXEMPT_LIST"
    return 1
}

# ── Method A: lint checked-in plist XML templates ─────────────────────────────
# Parse the XML and check only ProgramArguments and WorkingDirectory values.
_check_plist_xml() {
    local plist_file="$1"
    local fname
    fname="$(basename "$plist_file")"

    # Use python3 for reliable XML plist parsing (available on macOS + CI)
    python3 - "$plist_file" <<'PYEOF'
import sys, os

plist_path = sys.argv[1]
fname = os.path.basename(plist_path)

try:
    import xml.etree.ElementTree as ET
    tree = ET.parse(plist_path)
    root = tree.getroot()
except Exception as e:
    print(f"PARSE_ERROR:{plist_path}:{e}")
    sys.exit(0)

# Find top-level dict
top_dict = root.find('dict')
if top_dict is None:
    sys.exit(0)

FORBIDDEN = ['/tmp/', '/private/tmp/', '/var/folders/', '$TMPDIR', '${TMPDIR}']
TARGET_KEYS = {'ProgramArguments', 'WorkingDirectory'}

children = list(top_dict)
current_key = None
in_target = False
violations = []

for child in children:
    if child.tag == 'key':
        current_key = child.text
        in_target = current_key in TARGET_KEYS
    elif in_target:
        # Inspect all text content under this element
        texts = []
        if child.text:
            texts.append(child.text)
        for elem in child.iter():
            if elem.text and elem.text != child.text:
                texts.append(elem.text)
        for text in texts:
            for pat in FORBIDDEN:
                if pat in text:
                    violations.append(f"{fname}:{current_key}:{pat}:{text.strip()}")
        if child.tag != 'array':
            in_target = False  # WorkingDirectory is a single element
    else:
        if child.tag == 'key':
            pass  # handled above
        elif not in_target:
            in_target = False

for v in violations:
    print(f"VIOLATION:{v}")
PYEOF
}

echo "=== plist-no-tmp-paths lint (INFRA-2419) ==="
echo "    repo: ${REPO_ROOT}"
echo ""

# Scan both plist template dirs
PLIST_DIRS=(
    "${REPO_ROOT}/scripts/launchd"
    "${REPO_ROOT}/.chump/launchd"
)

echo "[Method A] Scanning checked-in plist XML templates..."
PLIST_FOUND=0
for pdir in "${PLIST_DIRS[@]}"; do
    [[ -d "$pdir" ]] || continue
    for pfile in "$pdir"/*.plist; do
        [[ -f "$pfile" ]] || continue
        PLIST_FOUND=$(( PLIST_FOUND + 1 ))
        output="$(_check_plist_xml "$pfile")"
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            case "$line" in
                PARSE_ERROR:*)
                    echo "  WARN: could not parse ${line#PARSE_ERROR:}" >&2
                    ;;
                VIOLATION:*)
                    # Format: VIOLATION:filename:key:pattern:value
                    v="${line#VIOLATION:}"
                    vfile="${v%%:*}"; vrest="${v#*:}"
                    vkey="${vrest%%:*}"; vrest="${vrest#*:}"
                    vpat="${vrest%%:*}"; vval="${vrest#*:}"
                    if _is_exempt "$pfile" "$vkey" "$vpat"; then
                        echo "  EXEMPT: $vfile ($vkey contains $vpat) — allowlisted"
                        exempt=$(( exempt + 1 ))
                    else
                        echo "  FAIL: $vfile: key=$vkey contains forbidden pattern '$vpat'" >&2
                        echo "        value: ${vval:0:120}" >&2
                        VIOLATIONS+=("$vfile:$vkey:$vpat")
                        fail=$(( fail + 1 ))
                    fi
                    ;;
            esac
        done <<< "$output"
        pass=$(( pass + 1 ))
    done
done
echo "    Scanned $PLIST_FOUND plist file(s)"
echo ""

# ── Method B: static grep of installer-generated plists ──────────────────────
# These installers generate plist content via heredoc (cat > "$PLIST" <<PLIST).
# We grep for ProgramArguments/WorkingDirectory context containing temp paths.
echo "[Method B] Scanning install-*-launchd.sh for inline-generated plist temp paths..."

SETUP_DIR="${REPO_ROOT}/scripts/setup"
INSTALL_SCRIPTS_FOUND=0
IN_BLOCK=0
CURRENT_KEY=""

_check_installer() {
    local script="$1"
    local sname
    sname="$(basename "$script")"
    local in_prog_args=0
    local in_work_dir=0
    local lineno=0

    while IFS= read -r line; do
        lineno=$(( lineno + 1 ))
        stripped="${line#"${line%%[![:space:]]*}"}"  # ltrim

        # Detect key context in heredoc plist content
        case "$stripped" in
            *'<key>ProgramArguments</key>'*)
                in_prog_args=1; in_work_dir=0 ;;
            *'<key>WorkingDirectory</key>'*)
                in_work_dir=1; in_prog_args=0 ;;
            *'<key>'*'</key>'*)
                # Another key resets work_dir (prog_args persists until </array>)
                if [[ "$in_work_dir" -eq 1 ]]; then
                    in_work_dir=0
                fi
                ;;
            *'</array>'*)
                in_prog_args=0 ;;
        esac

        if [[ $(( in_prog_args + in_work_dir )) -gt 0 ]]; then
            case "$stripped" in *'<string>'*)
                for pat in "${FORBIDDEN_PATTERNS[@]}"; do
                    case "$stripped" in *"$pat"*)
                        local ctx="ProgramArguments"
                        [[ "$in_work_dir" -eq 1 ]] && ctx="WorkingDirectory"
                        if _is_exempt "$script" "$ctx" "$pat"; then
                            echo "  EXEMPT: $sname:$lineno ($ctx contains $pat) — allowlisted"
                            exempt=$(( exempt + 1 ))
                        else
                            echo "  FAIL: $sname:$lineno: key=$ctx contains forbidden pattern '$pat'" >&2
                            echo "        line: ${stripped:0:120}" >&2
                            VIOLATIONS+=("$sname:$lineno:$ctx:$pat")
                            fail=$(( fail + 1 ))
                        fi
                        ;;
                    esac
                done
                ;;
            esac
        fi
        # Reset work_dir after its <string> was consumed
        if [[ "$in_work_dir" -eq 1 ]]; then
            case "$stripped" in *'</string>'*) in_work_dir=0 ;; esac
        fi
    done < "$script"
}

if [[ -d "$SETUP_DIR" ]]; then
    for installer in "$SETUP_DIR"/install-*-launchd.sh; do
        [[ -f "$installer" ]] || continue
        INSTALL_SCRIPTS_FOUND=$(( INSTALL_SCRIPTS_FOUND + 1 ))
        _check_installer "$installer"
    done
fi
echo "    Scanned $INSTALL_SCRIPTS_FOUND installer script(s)"
echo ""

# ── Synthetic smoke tests (self-verification) ─────────────────────────────────
echo "[Smoke] Self-verification scenarios..."

_smoke_plist_xml() {
    local label="$1"
    local xml="$2"
    local expect="$3"  # "PASS" or "FAIL"
    local tmpf
    tmpf="$(mktemp /tmp/chump-plist-lint-smoke-XXXXXX.plist)"
    printf '%s' "$xml" > "$tmpf"
    local result
    result="$(_check_plist_xml "$tmpf")"
    rm -f "$tmpf"
    if [[ "$expect" == "FAIL" ]]; then
        if echo "$result" | grep -q '^VIOLATION:'; then
            echo "  SMOKE OK: $label → detected violation (expected)"
        else
            echo "  SMOKE FAIL: $label → expected violation but none found" >&2
            fail=$(( fail + 1 ))
        fi
    else
        if echo "$result" | grep -q '^VIOLATION:'; then
            echo "  SMOKE FAIL: $label → unexpected violation: $result" >&2
            fail=$(( fail + 1 ))
        else
            echo "  SMOKE OK: $label → clean (expected)"
        fi
    fi
}

# Scenario 1: ProgramArguments with /tmp/ → should detect violation
_smoke_plist_xml "synthetic-tmp-in-ProgramArguments" '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.test.bad</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>cd /tmp/chump-install &amp;&amp; ./run.sh</string>
  </array>
</dict></plist>' "FAIL"

# Scenario 2: WorkingDirectory with /private/tmp/ → should detect violation
_smoke_plist_xml "synthetic-private-tmp-in-WorkingDirectory" '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.test.bad2</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>run.sh</string>
  </array>
  <key>WorkingDirectory</key>
  <string>/private/tmp/chump-install</string>
</dict></plist>' "FAIL"

# Scenario 3: $HOME/Projects/Chump in WorkingDirectory → should be clean
_smoke_plist_xml "synthetic-stable-path-in-WorkingDirectory" '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.test.good</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>run.sh</string>
  </array>
  <key>WorkingDirectory</key>
  <string>/Users/jeffadkins/Projects/Chump</string>
</dict></plist>' "PASS"

# Scenario 4: /tmp/ only in StandardOutPath → should be clean (not in scope)
_smoke_plist_xml "synthetic-tmp-in-log-path-only" '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.test.logonly</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>/Users/jeffadkins/Projects/Chump/run.sh</string>
  </array>
  <key>StandardOutPath</key>
  <string>/tmp/chump-daemon.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/chump-daemon.err.log</string>
</dict></plist>' "PASS"

echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
if [[ ${#VIOLATIONS[@]} -gt 0 ]]; then
    echo "=== VIOLATIONS SUMMARY ==="
    for v in "${VIOLATIONS[@]}"; do
        echo "  $v"
    done
    echo ""
fi

echo "=== Results ==="
echo "  Files checked (Method A plists): $PLIST_FOUND"
echo "  Scripts checked (Method B installers): $INSTALL_SCRIPTS_FOUND"
echo "  Exemptions applied: $exempt"
echo "  Violations: $fail"

if [[ "$fail" -gt 0 ]]; then
    echo ""
    echo "FAIL: $fail violation(s) found in ProgramArguments or WorkingDirectory."
    echo ""
    echo "Remediation:"
    echo "  1. Replace the temp path with a stable path:"
    echo "     ProgramArguments: use REPO_ROOT or absolute stable path"
    echo "     WorkingDirectory: use /Users/\$(whoami)/Projects/Chump or equivalent"
    echo "  2. If this file genuinely requires a temp path (rare), add to:"
    echo "     scripts/ci/plist-lint-exempt.txt"
    echo "     Format:  <basename> <key> <pattern>  # reason: <why>"
    exit 1
fi

echo ""
echo "PASS: no forbidden temp paths in ProgramArguments or WorkingDirectory."
exit 0
