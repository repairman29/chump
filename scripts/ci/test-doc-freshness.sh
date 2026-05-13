#!/usr/bin/env bash
# test-doc-freshness.sh — DOC-041
#
# Scans docs with `last_audited:` frontmatter and flags any older than a
# threshold (default 180 days). docs/archive/ is excluded.
#
# Default mode is WARN-ONLY (informational; never fails CI). Operator
# can flip to blocking once the long-tail cleanup happens by passing
# --strict or setting CHUMP_DOC_FRESHNESS_STRICT=1.
#
# Threshold:
#   --max-age-days N         override (default 180)
#   CHUMP_DOC_FRESHNESS_MAX_AGE_DAYS=N
#
# Output:
#   stdout — ranked list of stalest docs
#   exit 0 always (warn-only) or non-zero (strict) if any doc breaches
#
# Usage:
#   bash scripts/ci/test-doc-freshness.sh                 # warn-only
#   bash scripts/ci/test-doc-freshness.sh --strict        # blocking
#   bash scripts/ci/test-doc-freshness.sh --max-age-days 90 --strict
#   bash scripts/ci/test-doc-freshness.sh --json          # machine-readable

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

STRICT=0
WANT_JSON=0
MAX_AGE_DAYS="${CHUMP_DOC_FRESHNESS_MAX_AGE_DAYS:-180}"
prev=""
for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=1 ;;
        --json) WANT_JSON=1 ;;
        --max-age-days) ;;
    esac
    [[ "$prev" == "--max-age-days" ]] && MAX_AGE_DAYS="$arg"
    prev="$arg"
done
[[ "${CHUMP_DOC_FRESHNESS_STRICT:-0}" == "1" ]] && STRICT=1

export STRICT WANT_JSON MAX_AGE_DAYS
python3 - <<'PYEOF'
import os
import re
import sys
from datetime import datetime, timezone

strict = os.environ.get("STRICT") == "1"
want_json = os.environ.get("WANT_JSON") == "1"
max_age_days = int(os.environ.get("MAX_AGE_DAYS", "180"))
now = datetime.now(timezone.utc)

# Excluded dirs (still scanned for the existence of last_audited, but
# never flagged as stale — they're historical/snapshot).
EXCLUDED_PREFIXES = ("docs/archive/",)

stale = []
fresh_count = 0
scanned = 0

# Walk docs/ for any .md file
for d, _, fns in os.walk("docs"):
    if any(d.startswith(p.rstrip("/")) for p in EXCLUDED_PREFIXES):
        continue
    for fn in fns:
        if not fn.endswith(".md"):
            continue
        p = os.path.join(d, fn)
        try:
            head = open(p, encoding="utf-8", errors="replace").read(1024)
        except OSError:
            continue
        m = re.search(r"^last_audited:\s*['\"]?(\d{4}-\d{2}-\d{2})['\"]?", head, re.M)
        if not m:
            continue
        scanned += 1
        stamp = m.group(1)
        try:
            dt = datetime.strptime(stamp, "%Y-%m-%d").replace(tzinfo=timezone.utc)
        except ValueError:
            stale.append({"path": p, "stamp": stamp, "age_days": None, "reason": "unparseable date"})
            continue
        age = (now - dt).days
        if age > max_age_days:
            stale.append({"path": p, "stamp": stamp, "age_days": age, "reason": f"age {age} > threshold {max_age_days}"})
        else:
            fresh_count += 1

if want_json:
    import json as _j
    print(_j.dumps({
        "max_age_days": max_age_days,
        "scanned": scanned,
        "fresh": fresh_count,
        "stale_count": len(stale),
        "stale": sorted(stale, key=lambda x: -(x.get("age_days") or 0)),
        "strict": strict,
    }, indent=2))
else:
    mode = "STRICT" if strict else "WARN-ONLY"
    print(f"=== DOC-041 doc-freshness audit [{mode}, threshold {max_age_days}d] ===")
    print(f"Scanned: {scanned}    Fresh: {fresh_count}    Stale: {len(stale)}")
    if stale:
        print()
        for s in sorted(stale, key=lambda x: -(x.get("age_days") or 0))[:30]:
            age = s.get("age_days")
            age_s = f"{age:>4d}d" if age is not None else "  ??"
            print(f"  {age_s}  {s['stamp']}  {s['path']}")
        if len(stale) > 30:
            print(f"  ... +{len(stale)-30} more")

if stale and strict:
    sys.exit(1)
sys.exit(0)
PYEOF
