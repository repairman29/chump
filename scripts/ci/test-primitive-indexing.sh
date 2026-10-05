#!/usr/bin/env bash
# test-primitive-indexing.sh — INFRA-1864 AC4
#
# Smoke-tests scripts/arsenal/build.py's per-file primitive scanner
# (scan_repo_primitives) against a synthetic fixture repo, so it never
# touches the real docs/arsenal/ catalog or a live local clone.
#
# Verifies: a Rust file containing `use tree_sitter;` is indexed as an
# `ast` primitive hit with a correct file + line ref (AC1/AC2/AC4), and
# that a Python file with `import stripe` is indexed as `payment` (AC2's
# "language-keyed" requirement — not just a single-language smoke test).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1864: primitive per-file indexing smoke test ==="

FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/src"
cat > "$FIXTURE/src/shredder.rs" <<'RS'
use tree_sitter::Parser;

fn parse(_src: &str) {}
RS

cat > "$FIXTURE/src/billing.py" <<'PY'
import stripe

stripe.api_key = "sk_test_xxx"
PY

OUT="$(python3 - "$REPO_ROOT" "$FIXTURE" <<'PYEOF'
import json
import sys
from pathlib import Path

repo_root, fixture = sys.argv[1], sys.argv[2]
sys.path.insert(0, str(Path(repo_root) / "scripts" / "arsenal"))
import build  # noqa: E402

signatures = build._load_signatures()
entries = build.scan_repo_primitives(Path(fixture), signatures)
print(json.dumps(entries))
PYEOF
)"
rc=$?

if [ "$rc" -ne 0 ]; then
    bad "scanner invocation exited non-zero"
    echo "=== $PASS passed, $FAIL failed ==="
    exit 1
fi

if echo "$OUT" | grep -q '"primitive": "ast"'; then
    ok "scanner produced an ast primitive entry"
else
    bad "scanner did not produce an ast primitive entry (got: $OUT)"
fi

if echo "$OUT" | python3 -c "
import json, sys
entries = json.load(sys.stdin)
hits = [e for e in entries if e['primitive'] == 'ast' and e['file'] == 'src/shredder.rs' and e['line'] == 1]
sys.exit(0 if hits else 1)
"; then
    ok "ast entry cites src/shredder.rs:1 (correct file + line ref)"
else
    bad "ast entry missing correct file/line ref (got: $OUT)"
fi

if echo "$OUT" | grep -q '"primitive": "payment"'; then
    ok "scanner produced a payment primitive entry (multi-language signature file works)"
else
    bad "scanner did not produce a payment primitive entry (got: $OUT)"
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
