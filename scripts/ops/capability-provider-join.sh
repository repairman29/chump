#!/usr/bin/env bash
# capability-provider-join.sh — CREDIBLE-240
#
# Answers "which provider does this tool front?" by joining the two catalogs
# that each hold half the answer:
#
#   docs/CAPABILITIES_REGISTRY.json  — the TOOLS chump exposes
#   ../privateer/charter.json        — the capability NEEDS and which provider
#                                      currently backs each one
#
# Until now neither file mentioned the other, so the question had no answer in
# either place. This script is the executable form of the `join` field in
# CAPABILITIES_REGISTRY.related_registries.
#
# The join: charter.needs[].incumbent is a "<repo>:<path>" string. When the
# repo part is "chump", the path is matched against — in order —
# crate_apis[].crate_path, crate_apis[].entry_file, primitives[].file_paths.
#
# Honest about misses. A need can fail to resolve for three different reasons
# and they mean different things:
#   - the incumbent lives in another repo (almanac, olive) — not chump's tool
#   - the incumbent is plain source chump does not catalogue as a primitive
#     (e.g. src/provider_cascade.rs) — the capability exists, the join target
#     does not
#   - the need is unexplored — nobody has built it anywhere
# None of these mean "chump cannot do this".
#
# Usage:
#   bash scripts/ops/capability-provider-join.sh
#   bash scripts/ops/capability-provider-join.sh --charter /path/to/charter.json
#   bash scripts/ops/capability-provider-join.sh --json
#
# Exit codes: 0 always when both files are readable (this is a report, not a
# gate); 2 when the registry or the charter cannot be read.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
REGISTRY="$REPO_ROOT/docs/CAPABILITIES_REGISTRY.json"
JSON_OUT=0

# Locate the sibling charter. In a linked worktree $REPO_ROOT can sit somewhere
# like /tmp, so also try the PRIMARY checkout's parent — git-common-dir points
# at the real .git regardless of which worktree we are standing in.
default_charter() {
    if [[ -n "${CHUMP_PRIVATEER_CHARTER:-}" ]]; then
        printf '%s' "$CHUMP_PRIVATEER_CHARTER"
        return
    fi
    local common primary
    if [[ -f "$REPO_ROOT/../privateer/charter.json" ]]; then
        printf '%s' "$REPO_ROOT/../privateer/charter.json"
        return
    fi
    common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [[ -n "$common" ]]; then
        primary="$(dirname "$common")"
        [[ -f "$primary/../privateer/charter.json" ]] && {
            printf '%s' "$primary/../privateer/charter.json"; return; }
    fi
    printf '%s' "$REPO_ROOT/../privateer/charter.json"
}
CHARTER="$(default_charter)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --registry) REGISTRY="$2"; shift 2 ;;
        --charter)  CHARTER="$2";  shift 2 ;;
        --json)     JSON_OUT=1;    shift ;;
        -h|--help)  sed -n '2,35p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)          echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ ! -f "$REGISTRY" ]]; then
    echo "[join] capabilities registry not found: $REGISTRY" >&2
    echo "       Generate it: bash scripts/dev/build-capabilities-registry.sh" >&2
    exit 2
fi

if [[ ! -f "$CHARTER" ]]; then
    echo "[join] privateer charter not readable at: $CHARTER"
    echo "       It lives in a sibling repo, so this is expected on a machine"
    echo "       that has chump checked out alone. Clone repairman29/privateer"
    echo "       next to chump, or pass --charter <path>."
    exit 2
fi

REGISTRY="$REGISTRY" CHARTER="$CHARTER" JSON_OUT="$JSON_OUT" python3 - <<'PYEOF'
import json, os, sys

reg = json.load(open(os.environ["REGISTRY"]))
charter = json.load(open(os.environ["CHARTER"]))
as_json = os.environ["JSON_OUT"] == "1"

crate_by_path = {c.get("crate_path"): c for c in reg.get("crate_apis", [])}
crate_by_entry = {c.get("entry_file"): c for c in reg.get("crate_apis", [])}
prims_by_path = {}
for p in reg.get("primitives", []):
    for fp in p.get("file_paths") or []:
        prims_by_path.setdefault(fp, []).append(p.get("primitive_id"))

rows = []
for need in charter.get("needs", []):
    inc = (need.get("incumbent") or "").strip()
    repo, sep, path = inc.partition(":")
    row = {
        "need": need.get("need"),
        "charter_status": need.get("status"),
        "incumbent": inc or None,
        "match_kind": None,
        "chump_primitive": None,
        "why_no_match": None,
    }
    if not inc:
        row["why_no_match"] = "unexplored — no incumbent recorded anywhere"
    elif not sep or repo != "chump":
        row["why_no_match"] = f"incumbent is outside chump ({inc})"
    elif path in crate_by_path:
        row["match_kind"] = "crate_apis.crate_path"
        row["chump_primitive"] = crate_by_path[path]["crate_name"]
    elif path in crate_by_entry:
        row["match_kind"] = "crate_apis.entry_file"
        row["chump_primitive"] = crate_by_entry[path]["crate_name"]
    elif path in prims_by_path:
        row["match_kind"] = "primitives.file_paths"
        row["chump_primitive"] = ", ".join(prims_by_path[path])
    else:
        exists = os.path.exists(os.path.join(os.path.dirname(os.environ["REGISTRY"]), "..", path))
        row["why_no_match"] = (
            "path is real chump source but is not catalogued as a primitive"
            if exists else "path not found in chump"
        )
    rows.append(row)

if as_json:
    print(json.dumps({"registry_generated_at": reg.get("generated_at"), "needs": rows}, indent=2))
    sys.exit(0)

matched = sum(1 for r in rows if r["chump_primitive"])
print(f"capability need -> chump tool   (registry generated_at={reg.get('generated_at')})")
print("=" * 78)
for r in rows:
    if r["chump_primitive"]:
        print(f"  {r['need']:<14} [{r['charter_status']}]")
        print(f"    fronted by : {r['chump_primitive']}  (via {r['match_kind']})")
        print(f"    incumbent  : {r['incumbent']}")
    else:
        print(f"  {r['need']:<14} [{r['charter_status']}]  no chump primitive")
        print(f"    reason     : {r['why_no_match']}")
print("=" * 78)
print(f"{matched}/{len(rows)} charter needs resolve to a catalogued chump primitive.")
print("A miss is not evidence of a missing capability — read the reason line.")
PYEOF
