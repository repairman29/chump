#!/usr/bin/env bash
# test-hidden-gems-schema.sh — INFRA-1727
#
# Smoke test for docs/HIDDEN_GEMS.md schema invariants:
#   1. Every entry has all four required fields (where / when / example)
#   2. Every `where_to_find` path resolves to a real file in the repo
#   3. Build script is idempotent (re-running produces no drift)
#
# Run locally before push; CI runs it on every PR that touches the doc or
# the build script.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

DOC="docs/HIDDEN_GEMS.md"
CURATED="docs/HIDDEN_GEMS_CURATED.yaml"
BUILD="scripts/dev/build-hidden-gems.sh"

fail=0
_fail() { echo "FAIL: $1" >&2; fail=1; }
_ok() { echo "  ok: $1"; }

# ── Existence checks ────────────────────────────────────────────────────────
[[ -f "$DOC" ]] || { _fail "$DOC missing — run bash $BUILD first"; exit 1; }
[[ -f "$CURATED" ]] || _fail "$CURATED missing"
[[ -x "$BUILD" ]] || _fail "$BUILD not executable"
_ok "files present"

# ── Schema check: every entry has Where / When / Example ────────────────────
# Parser is intentionally regex-light — checks the rendered markdown shape
# the build script produces ("### `<name>`" header followed by three bullets).
python3 <<'PYEOF' || fail=1
import re, sys, pathlib
doc = pathlib.Path("docs/HIDDEN_GEMS.md").read_text()

# Split on "### `..." headers
entries = re.split(r"\n### `[^`]+`\n", doc)[1:]  # first chunk is the preamble
errors = []
for i, body in enumerate(entries):
    # Pull the matching header from the doc
    header_match = re.findall(r"\n### `([^`]+)`\n", doc)
    name = header_match[i] if i < len(header_match) else f"<entry-{i}>"
    if "- **Where:**" not in body:
        errors.append(f"  entry {name}: missing 'Where:' field")
    if "- **When to use:**" not in body:
        errors.append(f"  entry {name}: missing 'When to use:' field")
    if "- **Example:**" not in body:
        errors.append(f"  entry {name}: missing 'Example:' field")
if errors:
    print("FAIL: schema check failed", file=sys.stderr)
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
print(f"  ok: {len(entries)} entries pass schema check")
PYEOF

# ── Path resolution: every Where:-cited path is a real file ─────────────────
python3 <<'PYEOF' || fail=1
import re, sys, pathlib
doc = pathlib.Path("docs/HIDDEN_GEMS.md").read_text()
paths = re.findall(r"- \*\*Where:\*\* `([^`]+)`", doc)
missing = []
for p in paths:
    if p.startswith("ambient kind="):
        # Synthetic "name" entries map to the registry path; skip the kind itself
        continue
    if not pathlib.Path(p).exists():
        missing.append(p)
if missing:
    print(f"FAIL: {len(missing)} where_to_find paths do not resolve:", file=sys.stderr)
    for p in missing[:10]:
        print(f"  - {p}", file=sys.stderr)
    sys.exit(1)
print(f"  ok: all {len(paths)} where_to_find paths resolve")
PYEOF

# ── Idempotency: build --check exits 0 (no drift from committed doc) ────────
if bash "$BUILD" --check >/dev/null 2>&1; then
    _ok "build is idempotent (no drift)"
else
    _fail "build --check detected drift — re-run bash $BUILD and commit the result"
fi

if [[ $fail -eq 0 ]]; then
    echo "test-hidden-gems-schema: PASS"
    exit 0
else
    echo "test-hidden-gems-schema: FAIL" >&2
    exit 1
fi
