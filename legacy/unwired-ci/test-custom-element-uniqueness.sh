#!/usr/bin/env bash
# test-custom-element-uniqueness.sh — INFRA-1332
#
# Enumerates all customElements.define('chump-*', ...) calls across web/v2/
# and asserts no element name is registered more than once.
#
# Ignores:
#   - node_modules/
#   - web/v2/tests/  (test harness may stub/reassign)
#   - Comment lines (lines beginning with //)
#
# Exit: 0 = no duplicates found
#       1 = one or more duplicates detected

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
WEB_DIR="$REPO_ROOT/web/v2"

# Collect all define calls (file:line:content), excluding tests/ and comments.
raw="$(grep -rn "customElements\.define" "$WEB_DIR" \
    --include='*.js' \
    --exclude-dir=node_modules \
    --exclude-dir=tests 2>/dev/null || true)"

[ -z "$raw" ] && { echo "[PASS] No customElements.define calls found"; exit 0; }

python3 - "$WEB_DIR" <<'PYEOF'
import sys, re

web_dir = sys.argv[1]

import subprocess
result = subprocess.run(
    ["grep", "-rn", "customElements.define", web_dir,
     "--include=*.js", "--exclude-dir=node_modules", "--exclude-dir=tests"],
    capture_output=True, text=True
)

seen = {}  # name -> "file:lineno"
violations = 0

for line in result.stdout.splitlines():
    # Format: path/file.js:lineno:content
    parts = line.split(":", 2)
    if len(parts) < 3:
        continue
    fpath, lineno, content = parts
    trimmed = content.strip()
    # Skip comment lines.
    if trimmed.startswith("//"):
        continue
    # Extract element name.
    m = re.search(r"define\(['\"]([a-z][a-z0-9-]*)['\"]", content)
    if not m:
        continue
    name = m.group(1)
    if not name.startswith("chump-"):
        continue
    loc = f"{fpath}:{lineno}"
    if name in seen:
        print(f"[FAIL] Duplicate customElements.define for '{name}':")
        print(f"       first:  {seen[name]}")
        print(f"       second: {loc}")
        violations += 1
    else:
        seen[name] = loc

if violations == 0:
    print(f"[PASS] No duplicate customElements.define calls found ({len(seen)} elements registered)")
    sys.exit(0)
else:
    print(f"[FAIL] {violations} duplicate(s) found — each chump-* element must be defined exactly once")
    sys.exit(1)
PYEOF
