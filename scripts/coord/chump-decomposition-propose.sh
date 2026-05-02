#!/usr/bin/env bash
# chump-decomposition-propose.sh — FLEET-027 (FLEET-011 v2).
#
# Given a gap ID, infer the gap's "task class" from its title + description
# + acceptance criteria, then print a 2-5 step decomposition plan. Heuristic
# only — no LLM call, no AI inference. The output is a starting point for
# the operator (or a sibling agent picking up the gap), not a final plan.
#
# Pairs with FLEET-025 v0 (size advisory) and FLEET-026 v1 (heeded/ignored
# tracker) to complete the FLEET-011 trajectory:
#   v0: warn after the fact if a PR is too big
#   v1: track which warnings were heeded
#   v2 (this): proactively suggest a decomposition BEFORE work starts
#
# Usage:
#   scripts/coord/chump-decomposition-propose.sh <GAP-ID>           # markdown
#   scripts/coord/chump-decomposition-propose.sh <GAP-ID> --json    # JSON
#
# Heuristic task classes (stack-additive — a gap can match multiple):
#   refactor       title/desc contains: refactor, rewrite, rename, codemod, migrate
#   multi-system   title/desc contains: + (across N systems), umbrella, L2, phase, all
#   tests          title/desc contains: tests, test coverage, audit, sweep, scorecard
#   doc-driven     title/desc contains: documented, doc, runbook, README, design doc
#   per-criterion  acceptance_criteria has ≥ 3 items (one slice per criterion)
#
# Each task class proposes a different decomposition pattern. When multiple
# classes match, the script proposes a stack of slices that work for all.
#
# Exit codes:
#   0  printed a plan
#   1  gap not found OR chump CLI unreachable

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <GAP-ID> [--json]" >&2
    exit 1
fi

GAP_ID="$1"
JSON_OUT=0
[[ "${2:-}" == "--json" ]] && JSON_OUT=1

if ! command -v chump >/dev/null 2>&1; then
    echo "chump CLI not on PATH; can't read gap" >&2
    exit 1
fi

GAP_JSON="$(chump gap list --json 2>/dev/null | python3 -c "
import json, sys
try:
    gaps = json.load(sys.stdin)
    g = next((x for x in gaps if x['id'] == '$GAP_ID'), None)
    if g is None:
        sys.exit(1)
    print(json.dumps(g))
except SystemExit:
    raise
except Exception:
    sys.exit(1)
" || true)"

if [[ -z "$GAP_JSON" ]]; then
    echo "[propose] gap $GAP_ID not found in chump gap list" >&2
    exit 1
fi

python3 - "$GAP_JSON" "$JSON_OUT" <<'PYEOF'
import json, sys, re

g = json.loads(sys.argv[1])
json_out = sys.argv[2] == "1"

gid = g["id"]
title = g.get("title", "") or ""
desc  = g.get("description", "") or ""
ac_raw = g.get("acceptance_criteria", "") or ""
priority = g.get("priority", "?")
effort   = g.get("effort", "?")

# acceptance_criteria is sometimes a JSON-encoded list-string, sometimes free text.
ac_items = []
try:
    parsed = json.loads(ac_raw)
    if isinstance(parsed, list):
        ac_items = [str(x).strip() for x in parsed if str(x).strip()]
except Exception:
    pass
if not ac_items and ac_raw:
    # Split free-text acceptance on bullet/newline markers
    for line in re.split(r'[\n;|]+|^\s*[-*]\s+', ac_raw, flags=re.M):
        line = line.strip().lstrip("- *").strip()
        if line:
            ac_items.append(line)

text_lc = (title + "\n" + desc).lower()

# ── Task-class detection (stack-additive) ────────────────────────────────────
classes = []
def matches(*kw):
    return any(k in text_lc for k in kw)

if matches("refactor", "rewrite", "rename", "codemod", "migrate", "port "):
    classes.append("refactor")
if matches("umbrella", "l2", "l3", "phase ", " phase", "across ", " across", "all "):
    classes.append("multi-system")
if matches("test coverage", "tests", "audit", "sweep", "scorecard", "kappa", "verify"):
    classes.append("tests")
if matches("documented", "runbook", "readme", "design doc", "design-doc", "wireframe"):
    classes.append("doc-driven")
if len(ac_items) >= 3:
    classes.append("per-criterion")
if not classes:
    classes.append("monolithic-ok")

# ── Build slice proposals ────────────────────────────────────────────────────
slices = []

if "refactor" in classes:
    slices.append({
        "step": "v0: instrumentation",
        "scope": "add the new pattern alongside the old one; do not remove old code",
        "size_hint": "small (2-3 files)",
    })
    slices.append({
        "step": "v1: migration codemod",
        "scope": "mechanical sweep — rename / rewrite call sites; ship as ONE PR per atomic-discipline rule",
        "size_hint": "small-medium (single logical change, may touch many files)",
    })
    slices.append({
        "step": "v2: cleanup",
        "scope": "delete the old pattern + dead code that the codemod left behind",
        "size_hint": "small (subtractive only)",
    })

if "multi-system" in classes and "refactor" not in classes:
    # Multi-system without refactor — stack by component
    slices.append({
        "step": "design",
        "scope": "design doc covering the contract between components; no code",
        "size_hint": "small (1 doc)",
    })
    slices.append({
        "step": "component A scaffold",
        "scope": "first component — minimal API + tests; other components stub against it",
        "size_hint": "medium (1 component)",
    })
    slices.append({
        "step": "component B + integration",
        "scope": "second component + first end-to-end smoke test",
        "size_hint": "medium",
    })
    slices.append({
        "step": "remaining components + cleanup",
        "scope": "fan-out to remaining components; replace stubs with real wiring",
        "size_hint": "small per remaining component",
    })

if "tests" in classes and "refactor" not in classes:
    slices.append({
        "step": "v0: instrumentation only",
        "scope": "add the test scaffold + 1-2 happy-path cases; ship + observe in CI",
        "size_hint": "small (1 test file)",
    })
    slices.append({
        "step": "v1: edge-case coverage",
        "scope": "add the cases the v0 happy-path missed; informed by initial CI runs",
        "size_hint": "small-medium",
    })

if "doc-driven" in classes:
    slices.append({
        "step": "doc + acceptance lock",
        "scope": "publish the doc with a 'how to verify' section; lock acceptance before code",
        "size_hint": "small (1 doc)",
    })

if "per-criterion" in classes and not slices:
    # Use the gap's own acceptance criteria as the slice plan
    for i, a in enumerate(ac_items[:5], 1):
        slices.append({
            "step": f"slice {i}",
            "scope": a,
            "size_hint": "small (one acceptance criterion)",
        })

if not slices:
    # Monolithic-ok — gap looks small enough for one PR
    slices.append({
        "step": "single PR",
        "scope": "no decomposition recommended; gap appears atomic",
        "size_hint": f"effort={effort}, priority={priority}",
    })

# ── Output ───────────────────────────────────────────────────────────────────
out = {
    "gap_id": gid,
    "title": title,
    "priority": priority,
    "effort": effort,
    "task_classes": classes,
    "n_acceptance_criteria": len(ac_items),
    "proposed_slices": slices,
    "advisory_only": True,
    "note": "Heuristic-derived. Operator should adapt — this is a starting point, not a final plan.",
}

if json_out:
    print(json.dumps(out, indent=2))
else:
    print(f"# Decomposition proposal: {gid}")
    print(f"_{title}_")
    print()
    print(f"**Priority:** {priority}  •  **Effort:** {effort}  •  **Acceptance items:** {len(ac_items)}")
    print(f"**Task classes:** {', '.join(classes)}")
    print()
    print("## Proposed slices")
    print()
    for i, s in enumerate(slices, 1):
        print(f"### {i}. {s['step']}")
        print(f"  - **scope:** {s['scope']}")
        print(f"  - **size hint:** {s['size_hint']}")
        print()
    print("---")
    print("_Heuristic only. No LLM call. Adapt the slices to the actual code surface — this is a starting point, not a final plan._")
    print(f"_Re-run with `--json` for tooling consumption._")
PYEOF
