#!/usr/bin/env bash
# INFRA-698: fail if any scripts/*.sh has a shebang but is missing the exec bit.
# Run in CI fast-checks; also usable locally.
set -euo pipefail

BAD=$(find scripts/ -name '*.sh' -not -perm -u+x 2>/dev/null \
      | xargs grep -l '^#!' 2>/dev/null || true)

if [[ -n "$BAD" ]]; then
    echo "FAIL: the following scripts have shebangs but are missing +x:"
    echo "$BAD" | sed 's/^/  /'
    echo "Fix with: chmod +x <files>"
    exit 1
fi
echo "OK: all shebang scripts are executable."
