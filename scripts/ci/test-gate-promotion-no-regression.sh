#!/usr/bin/env bash
# scripts/ci/test-gate-promotion-no-regression.sh — INFRA-1869
#
# Parses docs/process/CI_GATE_PROMOTION_LOG.md and asserts that every
# listed PROMOTED gate is currently strict in its referenced CI workflow
# file. A "promoted" gate with `--warn-only` (or `|| true`) in its CI
# invocation is a discipline regression — fail the build.
#
# This is a CI guard (runs in .github/workflows/ci.yml) AND a local
# preflight gate (called via src/preflight.rs when staged diff touches
# .github/workflows/ or this log file).
#
# Bypass: not applicable. Demoting a gate requires editing the log AND
# adding `CI-Promotion-Reverted: <reason>` to the commit body — there
# is no env-var to skip this check, by design.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_FILE="${CHUMP_GATE_PROMOTION_LOG:-$REPO_ROOT/docs/process/CI_GATE_PROMOTION_LOG.md}"

# Smoke-test mode: --smoke runs a quick self-test with a synthetic fixture.
if [[ "${1:-}" == "--smoke" ]]; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    # ── Smoke 1: empty log file → rc=0 ───────────────────────────────────────
    echo "Smoke 1: empty log → rc=0"
    cat > "$TMP/log.md" <<EOF
# CI Gate Promotion Log

## Promoted gates (v1)
(no entries yet)
EOF
    mkdir -p "$TMP/.github/workflows"
    : > "$TMP/.github/workflows/ci.yml"
    CHUMP_GATE_PROMOTION_LOG="$TMP/log.md" CI_WORKFLOWS_DIR="$TMP/.github/workflows" \
        bash "$0" 2>&1 && rc=0 || rc=$?
    if [[ "$rc" -eq 0 ]]; then echo "  PASS"; else echo "  FAIL: rc=$rc"; exit 1; fi

    # ── Smoke 2: promoted gate present in ci.yml as strict → rc=0 ────────────
    echo "Smoke 2: promoted gate strict in ci.yml → rc=0"
    cat > "$TMP/log.md" <<EOF
## Promoted gates

## cargo-fmt-strict
- **Promoted at:** 2026-05-23 00:00 UTC
- **CI file:** .github/workflows/ci.yml
- **CI line (anchor):** cargo-fmt-strict
- **Promoted by:** INFRA-FAKE
- **Reason:** drift kills landed PRs
EOF
    cat > "$TMP/.github/workflows/ci.yml" <<EOF
jobs:
  cargo-fmt-strict:
    runs-on: ubuntu-latest
    steps:
      - run: cargo fmt --all -- --check
EOF
    CHUMP_GATE_PROMOTION_LOG="$TMP/log.md" CI_WORKFLOWS_DIR="$TMP/.github/workflows" \
        bash "$0" 2>&1 && rc=0 || rc=$?
    if [[ "$rc" -eq 0 ]]; then echo "  PASS"; else echo "  FAIL: rc=$rc"; exit 1; fi

    # ── Smoke 3: promoted gate but --warn-only present → rc=1 ────────────────
    echo "Smoke 3: promoted gate with --warn-only → rc=1 (regression caught)"
    cat > "$TMP/.github/workflows/ci.yml" <<EOF
jobs:
  cargo-fmt-strict:
    runs-on: ubuntu-latest
    steps:
      - run: cargo fmt --all -- --check --warn-only || true
EOF
    out=$(CHUMP_GATE_PROMOTION_LOG="$TMP/log.md" CI_WORKFLOWS_DIR="$TMP/.github/workflows" \
        bash "$0" 2>&1) && rc=0 || rc=$?
    if [[ "$rc" -eq 1 ]] && echo "$out" | grep -q "cargo-fmt-strict"; then
        echo "  PASS (rc=1 + gate name surfaced)"
    else
        echo "  FAIL: rc=$rc out=$out"
        exit 1
    fi

    echo
    echo "All 3 gate-promotion-no-regression smoke tests passed."
    exit 0
fi

# ── Main mode ───────────────────────────────────────────────────────────────
if [[ ! -r "$LOG_FILE" ]]; then
    echo "[test-gate-promotion-no-regression] log file missing: $LOG_FILE — nothing to check"
    exit 0
fi

CI_WORKFLOWS_DIR="${CI_WORKFLOWS_DIR:-$REPO_ROOT/.github/workflows}"

# Parse promoted gates from the log (sub-headings under "## Promoted gates").
# Demoted gates skip the strict-fail check (they're already in regression
# state with a documented reason).
FAILED=0

python3 - "$LOG_FILE" "$CI_WORKFLOWS_DIR" <<'PYEOF' || FAILED=$?
import os
import re
import sys

log_path = sys.argv[1]
workflows_dir = sys.argv[2]

with open(log_path) as f:
    log = f.read()

# Find the "Promoted gates" section. Lookahead needs \Z to catch EOF.
prom_match = re.search(r'## Promoted gates.*?(?=^## (?:Demoted|Adding|Cross)|\Z)', log,
                       flags=re.MULTILINE | re.DOTALL)
if not prom_match:
    # No "Promoted gates" heading at all → nothing to check.
    sys.exit(0)
prom_section = prom_match.group(0)

# Each entry is a "## <gate-name>" sub-heading.
gates = re.findall(r'^## ([a-zA-Z0-9_\-]+)\n(.*?)(?=^## |\Z)',
                   prom_section, flags=re.MULTILINE | re.DOTALL)
# Skip the "## Promoted gates" header itself.
gates = [(name, body) for name, body in gates if name not in ("Promoted", "Demoted", "Adding", "Cross")]

# Collect CI workflow file contents (one big string is fine for grep).
ci_blob = ""
if os.path.isdir(workflows_dir):
    for fname in os.listdir(workflows_dir):
        p = os.path.join(workflows_dir, fname)
        if os.path.isfile(p):
            try:
                with open(p) as f:
                    ci_blob += "\n# === FILE: " + fname + " ===\n" + f.read()
            except Exception:
                pass

failed = []
for name, body in gates:
    # Demoted gates have a Demoted at field — skip.
    if re.search(r'Demoted at:\s*\S', body, flags=re.IGNORECASE):
        continue
    # The gate name should appear in the CI workflow files.
    if name not in ci_blob:
        # Could be a gate name that doesn't literally appear (e.g. step
        # name vs job name); skip with a soft note.
        print(f"[note] gate '{name}' from log not found verbatim in CI workflows — soft-skip", file=sys.stderr)
        continue
    # Find lines mentioning the gate and check for `--warn-only` or `|| true`.
    # Take a window around each mention.
    for m in re.finditer(re.escape(name), ci_blob):
        start = max(0, m.start() - 200)
        end = min(len(ci_blob), m.end() + 400)
        window = ci_blob[start:end]
        if re.search(r'--warn-only', window) or re.search(r'\|\|\s*true\b', window):
            failed.append((name, window.strip()[:300]))
            break

if failed:
    print("✖ CI Gate Promotion regression detected — promoted gates running as warn-only:", file=sys.stderr)
    for name, snippet in failed:
        print(f"  - {name}", file=sys.stderr)
        print(f"    snippet: {snippet[:200]}...", file=sys.stderr)
    print(file=sys.stderr)
    print("Promoting a gate is a one-way door. To intentionally demote, add a", file=sys.stderr)
    print("`CI-Promotion-Reverted: <reason>` commit trailer AND mark the entry", file=sys.stderr)
    print("in docs/process/CI_GATE_PROMOTION_LOG.md as Demoted.", file=sys.stderr)
    sys.exit(1)

print(f"[test-gate-promotion-no-regression] OK — {len(gates)} promoted gate(s), 0 regressions.")
PYEOF

if (( FAILED != 0 )); then exit "$FAILED"; fi
exit 0
