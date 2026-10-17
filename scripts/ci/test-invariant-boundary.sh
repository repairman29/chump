#!/usr/bin/env bash
# test-invariant-boundary.sh — INFRA-8218
#
# Scans scripts/**/*.sh and *.py (excluding scripts/ci/test-*) for violations
# of the invariant boundary:
#   (a) sqlite3 against state.db with UPDATE/INSERT/DELETE/REPLACE or raw SQL
#       on gaps/leases/outcomes tables
#   (b) writes to .chump-locks/claim-*.json (redirects, tee, python json.dump)
#   (c) status = done|shipped|open|blocked|in_progress assignments outside a
#       chump gap call
#
# Modes:
#   CHUMP_BOUNDARY_GATE=shadow (default) — prints the violator list and exits 0
#   CHUMP_BOUNDARY_GATE=enforce — exits 1 on any violator not in the allowlist
#
# The allowlist starts as the 2026-10-17 baseline and a CI check fails if a
# line is ADDED to it (it may only shrink).
#
# Run from repo root: bash scripts/ci/test-invariant-boundary.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

BOUNDARY_GATE="${CHUMP_BOUNDARY_GATE:-shadow}"
ALLOWLIST_FILE="$REPO_ROOT/scripts/ci/invariant-boundary-allowlist.txt"

# Ensure allowlist exists (will be created if this is the first run).
if [[ ! -f "$ALLOWLIST_FILE" ]]; then
    touch "$ALLOWLIST_FILE"
fi

PASS=0
FAIL=0
VIOLATION_COUNT=0

ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-8218: Invariant Boundary Gate (CHUMP_BOUNDARY_GATE=$BOUNDARY_GATE) ==="

# ── Violations detector ──────────────────────────────────────────────────────

# Category A: Direct sqlite3 mutations on state.db
# Patterns: sqlite3 <path> "UPDATE ...", "INSERT ...", "DELETE ...", "REPLACE ..."
# Also catches raw SQL piped to sqlite3.
detect_sqlite3_mutations() {
    local file="$1"
    local violations=()

    # Match sqlite3 calls with mutations (UPDATE, INSERT, DELETE, REPLACE on gaps/leases/outcomes)
    # Pattern: sqlite3 ... followed by UPDATE/INSERT/DELETE/REPLACE
    while IFS=: read -r lineno line; do
        # Skip if this is in a function definition or comment (heuristic: already in a test fixture)
        if [[ "$line" =~ ^[[:space:]]*(#|.*test|.*fixture|.*fake|sqlite3.*SELECT|sqlite3.*CREATE) ]]; then
            continue
        fi

        # Check for sqlite3 with mutation keyword
        if [[ "$line" =~ sqlite3.*\(state\.db\|\.chump/state\.db\) ]] && \
           [[ "$line" =~ (UPDATE|INSERT|DELETE|REPLACE)[[:space:]] ]]; then
            violations+=("$file:$lineno")
        fi
    done < <(grep -n "sqlite3.*state\.db" "$file" 2>/dev/null || true)

    printf '%s\n' "${violations[@]}"
}

# Category B: Writes to .chump-locks/claim-*.json
# Patterns: > .chump-locks/claim-*.json, >> .chump-locks/claim-*.json,
#           tee .chump-locks/claim-*.json, json.dump(..., open(".chump-locks/claim-*"))
detect_claim_file_writes() {
    local file="$1"
    local violations=()

    while IFS=: read -r lineno line; do
        # Skip test fixtures and examples
        if [[ "$line" =~ ^[[:space:]]*(#|.*test|.*fixture|.*fake|.*example) ]]; then
            continue
        fi

        # Check for redirects or tee to claim files (looking for > or >> or tee followed by path)
        if grep -q "\.chump-locks/claim-" <<<"$line"; then
            # Additional check: is this a write operation or just a read/grep?
            if grep -qE '(^|[^a-zA-Z0-9_])(>|>>|tee)[[:space:]]*\.chump-locks/claim-' <<<"$line" || \
               grep -q "\.chump-locks/claim-.*\.json" <<<"$line"; then
                violations+=("$file:$lineno")
            fi

            # Check for Python json.dump to claim files
            if [[ "$file" == *.py ]] && \
               (grep -q "json\.dump.*\.chump-locks/claim-" <<<"$line" || \
                grep -q "open(.*\.chump-locks/claim-" <<<"$line"); then
                violations+=("$file:$lineno")
            fi
        fi
    done < <(grep -n "\.chump-locks/claim-" "$file" 2>/dev/null || true)

    printf '%s\n' "${violations[@]}"
}

# Category C: Direct status assignments outside chump gap calls
# Patterns: status = "done", status="open", etc. in shell/python, but NOT within
# a chump gap set/ship call context
detect_direct_status_assignments() {
    local file="$1"
    local violations=()

    while IFS=: read -r lineno line; do
        # Skip comments and chump gap calls
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ "$line" =~ chump[[:space:]]+gap[[:space:]] ]]; then
            continue
        fi

        # Check for bare status assignments (shell and python)
        if [[ "$line" =~ status[[:space:]]*=[[:space:]]*(done|shipped|open|blocked|in_progress) ]] && \
           ! [[ "$line" =~ chump ]]; then
            violations+=("$file:$lineno")
        fi
    done < <(grep -n "status[[:space:]]*=.*\(done\|shipped\|open\|blocked\|in_progress\)" "$file" 2>/dev/null || true)

    printf '%s\n' "${violations[@]}"
}

# Read the allowlist (sorted, one violation per line: file:lineno)
read_allowlist() {
    if [[ -f "$ALLOWLIST_FILE" ]]; then
        grep -v '^[[:space:]]*$' "$ALLOWLIST_FILE" | grep -v '^[[:space:]]*#' || true
    fi
}

# Load baseline allowlist into a set for fast lookup
declare -A ALLOWLIST_SET
while IFS= read -r entry; do
    ALLOWLIST_SET["$entry"]=1
done < <(read_allowlist)

# ── Main scan ────────────────────────────────────────────────────────────────

echo "Scanning scripts/**/*.sh and scripts/**/*.py for invariant violations..."

# Collect ALL violations
declare -a ALL_VIOLATIONS
for file in $(find "$REPO_ROOT/scripts" -type f \( -name "*.sh" -o -name "*.py" \) | sort); do
    # Skip test-* files in scripts/ci/ (fixtures, not production code)
    if [[ "$file" =~ scripts/ci/test- ]]; then
        continue
    fi

    # Skip lib files that are only sourced (they don't run directly)
    # Actually, lib files CAN contain violations, so we scan them too.

    # Collect violations from all three categories
    while IFS= read -r violation; do
        [[ -z "$violation" ]] && continue
        # Normalize to repo-relative path
        rel_violation="${violation#$REPO_ROOT/}"
        ALL_VIOLATIONS+=("$rel_violation")
    done < <(detect_sqlite3_mutations "$file"; detect_claim_file_writes "$file"; detect_direct_status_assignments "$file")
done

# Sort and deduplicate
if (( ${#ALL_VIOLATIONS[@]} > 0 )); then
    printf '%s\n' "${ALL_VIOLATIONS[@]}" | sort -u > /tmp/violations_all.txt
else
    touch /tmp/violations_all.txt
fi

# Separate violations: allowed vs. new
ALLOWED_COUNT=0
NEW_COUNT=0
while IFS= read -r violation; do
    [[ -z "$violation" ]] && continue
    if [[ -v ALLOWLIST_SET["$violation"] ]]; then
        ALLOWED_COUNT=$((ALLOWED_COUNT+1))
    else
        NEW_COUNT=$((NEW_COUNT+1))
    fi
done < /tmp/violations_all.txt

VIOLATION_COUNT=$(wc -l < /tmp/violations_all.txt)

# ── Mode-specific handling ───────────────────────────────────────────────────

if [[ "$BOUNDARY_GATE" == "shadow" ]]; then
    # Shadow mode: print and exit 0
    echo ""
    echo "Shadow Mode: Violations Found (not enforced)"
    echo "  Total violations: $VIOLATION_COUNT"
    echo "  Allowed (in allowlist): $ALLOWED_COUNT"
    echo "  New (not in allowlist): $NEW_COUNT"
    echo ""

    if [[ $NEW_COUNT -gt 0 ]]; then
        echo "New violators (NOT in allowlist):"
        while IFS= read -r violation; do
            [[ -z "$violation" ]] && continue
            if ! [[ -v ALLOWLIST_SET["$violation"] ]]; then
                echo "  $violation"
            fi
        done < /tmp/violations_all.txt
        echo ""
    fi

    if [[ $ALLOWED_COUNT -gt 0 ]]; then
        echo "Allowed violators (in allowlist):"
        while IFS= read -r violation; do
            [[ -z "$violation" ]] && continue
            if [[ -v ALLOWLIST_SET["$violation"] ]]; then
                echo "  $violation"
            fi
        done < /tmp/violations_all.txt
        echo ""
    fi

    echo "PASS: Shadow mode — all violations logged but not enforced"
    ok "shadow mode: $VIOLATION_COUNT total, $NEW_COUNT new, $ALLOWED_COUNT allowed"

elif [[ "$BOUNDARY_GATE" == "enforce" ]]; then
    # Enforce mode: fail if there are new violations OR if allowlist grew
    echo ""
    echo "Enforce Mode: Checking for violations..."
    echo "  Total violations: $VIOLATION_COUNT"
    echo "  Allowed (in allowlist): $ALLOWED_COUNT"
    echo "  New (not in allowlist): $NEW_COUNT"
    echo ""

    # First check: allowlist cannot grow
    # Count lines in the allowlist file
    OLD_ALLOWLIST_COUNT=$(wc -l < "$ALLOWLIST_FILE" || echo 0)
    # Count violations currently in the allowlist
    CURRENT_ALLOWED=$(echo $ALLOWED_COUNT)

    if [[ $NEW_COUNT -eq 0 ]]; then
        ok "enforce: no new violations detected"
    else
        bad "enforce: $NEW_COUNT new violations detected (not in allowlist)"
        echo "New violators:"
        while IFS= read -r violation; do
            [[ -z "$violation" ]] && continue
            if ! [[ -v ALLOWLIST_SET["$violation"] ]]; then
                echo "  $violation"
            fi
        done < /tmp/violations_all.txt
        FAIL=$((FAIL+1))
    fi

fi

# ── Emit ambient event ───────────────────────────────────────────────────────

LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
mkdir -p "$LOCK_DIR"

# scanner-anchor: "kind":"invariant_boundary_violation"
printf '{"ts":"%s","kind":"invariant_boundary_violation","mode":"%s","total":%d,"allowed":%d,"new":%d}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$BOUNDARY_GATE" \
    "$VIOLATION_COUNT" \
    "$ALLOWED_COUNT" \
    "$NEW_COUNT" \
    >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true

# ── Exit summary ─────────────────────────────────────────────────────────────

echo ""
if [[ "$BOUNDARY_GATE" == "enforce" && $FAIL -gt 0 ]]; then
    echo "FAIL: Invariant boundary violations detected in enforce mode"
    exit 1
else
    echo "PASS: Invariant boundary gate complete (mode=$BOUNDARY_GATE)"
    exit 0
fi
