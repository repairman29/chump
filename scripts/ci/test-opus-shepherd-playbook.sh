#!/usr/bin/env bash
# test-opus-shepherd-playbook.sh — META-094 smoke test
#
# Asserts docs/process/OPUS_SHEPHERD_PLAYBOOK.md exists, has all required
# sections, and its cross-refs resolve to real files.

set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

DOC="docs/process/OPUS_SHEPHERD_PLAYBOOK.md"
[[ -f "$DOC" ]] || { echo "FAIL: $DOC missing"; exit 1; }
echo "  ok: $DOC present"

# Required sections (per META-094 AC #2)
REQUIRED=(
    "What an Opus shepherd is — and isn't"
    "Session-start triage"
    "Predictive digest"
    "Parallel sub-fleet dispatch"
    "Ghost-gap sweep cookbook"
    "When to self-implement vs dispatch Sonnet"
    "a2a tier discipline"
    "Stop conditions"
)
for s in "${REQUIRED[@]}"; do
    if ! grep -q "$s" "$DOC"; then
        echo "FAIL: section missing: '$s'"
        exit 1
    fi
done
echo "  ok: all 8 required sections present"

# Cross-ref resolution: every relative link should resolve
python3 <<'PYEOF'
import re, sys, pathlib
doc_path = pathlib.Path("docs/process/OPUS_SHEPHERD_PLAYBOOK.md")
doc = doc_path.read_text()
# Markdown link pattern: [text](path) — capture just the path
paths = re.findall(r"\]\((\.\.?/[^)]+)\)", doc)
missing = []
for p in paths:
    # Resolve relative to the doc's directory
    resolved = (doc_path.parent / p).resolve()
    repo_root = pathlib.Path(".").resolve()
    # Check the path exists (use try in case of weird resolves)
    try:
        rel = resolved.relative_to(repo_root)
    except ValueError:
        # Outside repo, skip
        continue
    if not resolved.exists():
        missing.append(str(rel))
if missing:
    print(f"FAIL: {len(missing)} cross-refs do not resolve:", file=sys.stderr)
    for m in missing[:8]:
        print(f"  - {m}", file=sys.stderr)
    sys.exit(1)
print(f"  ok: all {len(paths)} cross-refs resolve")
PYEOF

echo "test-opus-shepherd-playbook: PASS"
