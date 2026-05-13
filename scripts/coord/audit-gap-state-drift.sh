#!/usr/bin/env bash
# audit-gap-state-drift.sh — INFRA-970
#
# Detects drift between the canonical gap registry (.chump/state.db) and
# tracked YAML mirrors (docs/gaps/*.yaml). state.db is authoritative under
# INFRA-188; the YAMLs exist for git history + reviewability.
#
# Three drift classes:
#
#   1. MISSING_YAML  — gap is done w/ closed_pr in state.db, but
#                      docs/gaps/<ID>.yaml does not exist on disk.
#                      Indicates a misrouted `chump gap ship --update-yaml`
#                      (INFRA-969) or pre-INFRA-188 legacy.
#
#   2. STATUS_DRIFT  — gap status in state.db differs from YAML status.
#
#   3. RACE_FIXTURE  — YAML has `title: race-a` / `race-b` / etc. from
#                      leaked test fixtures. State.db has the real title.
#                      This check runs even without state.db access.
#
# Behaviour:
#   • If .chump/state.db is not available (CI checkouts), only RACE_FIXTURE
#     is reported — that check is fully YAML-local.
#   • Exit code: 0 if no drift OR --warn-only. 1 if drift > 0 without
#     --warn-only.
#
# Usage:
#   bash scripts/coord/audit-gap-state-drift.sh [--json] [--warn-only]
#                                                [--since-pr N] [--since-date YYYY-MM-DD]
#                                                [--repo PATH]

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GAPS_DIR="$REPO_ROOT/docs/gaps"

WARN_ONLY=0
WANT_JSON=0
SINCE_PR=0
SINCE_DATE=""
CHUMP_REPO_ARG=""
prev=""
for arg in "$@"; do
    case "$arg" in
        --warn-only) WARN_ONLY=1 ;;
        --json) WANT_JSON=1 ;;
        --since-pr|--since-date|--repo) ;;
    esac
    case "$prev" in
        --since-pr) SINCE_PR="$arg" ;;
        --since-date) SINCE_DATE="$arg" ;;
        --repo) CHUMP_REPO_ARG="$arg" ;;
    esac
    prev="$arg"
done

# Try to load state.db data. If unavailable, fall back to YAML-only check.
DUMP=""
STATE_DB_AVAILABLE=0
if [[ -n "$CHUMP_REPO_ARG" ]]; then
    CHUMP_REPO_TRY="$CHUMP_REPO_ARG"
else
    CHUMP_REPO_TRY="${CHUMP_REPO:-$REPO_ROOT}"
fi

if [[ -f "$CHUMP_REPO_TRY/.chump/state.db" ]] && command -v chump >/dev/null 2>&1; then
    if DUMP="$(CHUMP_REPO="$CHUMP_REPO_TRY" chump gap list --status done --json 2>/dev/null)"; then
        # Validate it's actually a non-empty array.
        if [[ -n "$DUMP" ]] && [[ "$DUMP" != "[]" ]]; then
            STATE_DB_AVAILABLE=1
        fi
    fi
fi

export GAPS_DIR SINCE_PR SINCE_DATE WANT_JSON WARN_ONLY STATE_DB_AVAILABLE
# DUMP can be >1MB which exceeds ARG_MAX for argv passing; stash in a
# temp file and have Python read it directly.
_AUDIT_DUMP_FILE="$(mktemp)"
trap 'rm -f "$_AUDIT_DUMP_FILE"' EXIT
printf '%s' "$DUMP" > "$_AUDIT_DUMP_FILE"
export _AUDIT_DUMP_FILE
python3 - <<'PYEOF'
import json, os, sys, re

gaps_dir = os.environ["GAPS_DIR"]
since_pr = int(os.environ.get("SINCE_PR") or 0)
since_date = os.environ.get("SINCE_DATE") or ""
want_json = os.environ.get("WANT_JSON") == "1"
warn_only = os.environ.get("WARN_ONLY") == "1"
state_db = os.environ.get("STATE_DB_AVAILABLE") == "1"

gaps_data = ""
dump_path = os.environ.get("_AUDIT_DUMP_FILE", "")
if state_db and dump_path and os.path.exists(dump_path):
    with open(dump_path, encoding="utf-8") as f:
        gaps_data = f.read().strip()
gaps = json.loads(gaps_data) if gaps_data else []

def in_scope(g):
    pr = g.get("closed_pr")
    if since_pr and (not pr or int(pr) < since_pr):
        return False
    if since_date and (g.get("closed_date") or "") < since_date:
        return False
    return True

missing_yaml = []
status_drift = []
race_fixture = []

title_re = re.compile(r"^\s*title:\s*(.+?)\s*$", re.M)
status_re = re.compile(r"^\s*status:\s*(\S+)\s*$", re.M)

# state.db-driven checks
state = {g["id"]: g for g in gaps if in_scope(g)}
for gid, g in state.items():
    p = os.path.join(gaps_dir, f"{gid}.yaml")
    if not os.path.exists(p):
        missing_yaml.append({"id": gid, "closed_pr": g.get("closed_pr"), "closed_date": g.get("closed_date")})
        continue
    body = open(p, encoding="utf-8", errors="replace").read()
    s_match = status_re.search(body)
    yaml_status = (s_match.group(1) if s_match else "").lower()
    if yaml_status and yaml_status != (g.get("status") or "").lower():
        status_drift.append({
            "id": gid,
            "db_status": g.get("status"),
            "yaml_status": yaml_status,
            "closed_pr": g.get("closed_pr"),
        })

# YAML-local race-fixture scan (works even without state.db).
if os.path.isdir(gaps_dir):
    for fn in sorted(os.listdir(gaps_dir)):
        if not fn.endswith(".yaml"): continue
        gid = fn[:-5]
        p = os.path.join(gaps_dir, fn)
        try:
            body = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        t_match = title_re.search(body)
        yaml_title = (t_match.group(1).strip().strip('"').strip("'") if t_match else "").lower()
        if yaml_title.startswith("race-") and len(yaml_title) <= 8:
            db_title = state.get(gid, {}).get("title", "") if state_db else ""
            race_fixture.append({
                "id": gid,
                "yaml_title": yaml_title,
                "db_title": db_title[:60] if db_title else "",
            })

total = len(missing_yaml) + len(status_drift) + len(race_fixture)

if want_json:
    print(json.dumps({
        "state_db_available": state_db,
        "scope": {"since_pr": since_pr, "since_date": since_date},
        "summary": {
            "missing_yaml": len(missing_yaml),
            "status_drift": len(status_drift),
            "race_fixture": len(race_fixture),
            "total": total,
        },
        "missing_yaml": missing_yaml,
        "status_drift": status_drift,
        "race_fixture": race_fixture,
    }, indent=2))
else:
    scope_str = ""
    if since_pr: scope_str += f" (closed_pr >= #{since_pr})"
    if since_date: scope_str += f" (closed_date >= {since_date})"
    print(f"=== gap state-vs-yaml drift audit{scope_str} ===")
    if not state_db:
        print("[INFO] state.db unavailable — only RACE_FIXTURE check ran.")
        print("       Pass --repo PATH or set CHUMP_REPO to enable full audit.")
    print(f"")
    print(f"MISSING_YAML  ({len(missing_yaml)})  — state.db says done w/ closed_pr; no docs/gaps/<id>.yaml")
    for m in missing_yaml[:10]:
        print(f"  {m['id']:15s} pr=#{m.get('closed_pr','?')!s:<5} closed={m.get('closed_date','?')}")
    if len(missing_yaml) > 10: print(f"  ... +{len(missing_yaml)-10} more")
    print(f"")
    print(f"STATUS_DRIFT  ({len(status_drift)})  — state.db status != YAML status")
    for s in status_drift[:10]:
        print(f"  {s['id']:15s} db={s['db_status']} yaml={s['yaml_status']} pr=#{s.get('closed_pr','?')}")
    if len(status_drift) > 10: print(f"  ... +{len(status_drift)-10} more")
    print(f"")
    print(f"RACE_FIXTURE  ({len(race_fixture)})  — YAML title is a leaked test fixture")
    for r in race_fixture[:10]:
        suffix = f"  db='{r['db_title']}'" if r["db_title"] else ""
        print(f"  {r['id']:15s} yaml='{r['yaml_title']}'{suffix}")
    if len(race_fixture) > 10: print(f"  ... +{len(race_fixture)-10} more")
    print(f"")
    print(f"TOTAL DRIFT: {total}")

if total > 0 and not warn_only:
    sys.exit(1)
PYEOF
