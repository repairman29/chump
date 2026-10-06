#!/usr/bin/env bash
# doctrine-loom-daemon.sh — META-1044 (META-256 Doctrine Loom)
#
# One Loom tick: scan the playbook set -> build the reference graph -> run the
# missing-thread and frayed-edge detectors -> regenerate DOCTRINE_INDEX.md and
# DOCTRINE_GRAPH.md -> emit kind=doctrine_weave_tick.
#
# Stages (each is its own script, so each stays independently testable):
#   scripts/coord/doctrine-seam-finder.py      graph + topic overlap   (META-1040)
#   scripts/coord/doctrine-weave-detectors.py  asymmetry / frayed edge (META-1041)
#   scripts/coord/doctrine-publish.py          INDEX + GRAPH           (META-1044)
#
# No-escalation doctrine (META-207): the Loom FILES GAPS, it never pages. This
# script has no notification path at all; anything that merits the operator's
# attention is left in ambient.jsonl for the existing escalation pipeline,
# which alone decides whether a T4 trigger is met. Gap filing is opt-in
# (CHUMP_LOOM_FILE_GAPS=1) and de-duplicated by finding-count digest so an
# unchanged tree never files twice.
#
# Modes:
#   --once      one tick (default); exits 0 unless a stage itself crashes
#   --daemon    loop forever, sleeping CHUMP_LOOM_INTERVAL_S (default 1800)
#   --dry-run   run the stages, but write no INDEX/GRAPH, emit nothing, file nothing
#
# Environment:
#   CHUMP_LOOM_REPO_ROOT     tree to scan (default: this checkout)
#   CHUMP_LOOM_OUT_DIR       where INDEX/GRAPH are written (default <root>/docs/process)
#   CHUMP_LOOM_FILE_GAPS=1   file one META gap per changed finding set
#   CHUMP_LOOM_CHUMP_BIN     chump binary used for gap filing (default: chump)
#   CHUMP_AMBIENT_LOG        ambient.jsonl path override
# Bypass: CHUMP_DOCTRINE_LOOM=0 exits 0 silently.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CHUMP_LOOM_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
OUT_DIR="${CHUMP_LOOM_OUT_DIR:-$ROOT/docs/process}"
LOCK_DIR="${CHUMP_LOCK_DIR:-$ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"
STATE_FILE="$LOCK_DIR/doctrine-loom-state.json"
INTERVAL_S="${CHUMP_LOOM_INTERVAL_S:-1800}"
CHUMP_BIN="${CHUMP_LOOM_CHUMP_BIN:-chump}"

MODE="once"; DRY_RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --once) MODE="once"; shift ;;
        --daemon) MODE="daemon"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "doctrine-loom-daemon: unknown flag '$1'" >&2; exit 2 ;;
    esac
done

if [[ "${CHUMP_DOCTRINE_LOOM:-1}" == "0" ]]; then
    echo "[doctrine-loom] bypassed via CHUMP_DOCTRINE_LOOM=0"; exit 0
fi

tick() {
    local findings graph published
    graph="$(mktemp)"; findings="$(mktemp)"
    trap 'rm -f "$graph" "$findings"' RETURN

    python3 "$SCRIPT_DIR/doctrine-seam-finder.py" --root "$ROOT" --output "$graph"
    if [[ "$DRY_RUN" == "1" ]]; then
        python3 "$SCRIPT_DIR/doctrine-weave-detectors.py" --root "$ROOT" > "$findings"
        published=""
    else
        mkdir -p "$LOCK_DIR"
        python3 "$SCRIPT_DIR/doctrine-weave-detectors.py" --root "$ROOT" --emit \
            --ambient "$AMBIENT_LOG" > "$findings"
        published="$(python3 "$SCRIPT_DIR/doctrine-publish.py" --root "$ROOT" --out-dir "$OUT_DIR")"
    fi

    local summary
    summary="$(python3 - "$graph" "$findings" <<'PY'
import collections, hashlib, json, sys
g = json.load(open(sys.argv[1]))
f = json.load(open(sys.argv[2]))["findings"]
by = collections.Counter(x["kind"] for x in f)
digest = hashlib.sha256(json.dumps(
    sorted(json.dumps(x, sort_keys=True) for x in f)).encode()).hexdigest()[:16]
print(json.dumps({"playbooks": len(g["playbooks"]), "edges": len(g["edges"]),
                  "asymmetries": by.get("doctrine_weave_asymmetry", 0),
                  "frayed_edges": by.get("doctrine_weave_frayed_edge", 0),
                  "digest": digest}))
PY
)"
    echo "[doctrine-loom] tick: $summary"
    [[ "$DRY_RUN" == "1" ]] && return 0

    python3 - "$AMBIENT_LOG" "$summary" "$(printf '%s' "$published" | grep -c . || true)" <<'PY'
import datetime, json, sys
log, summary, published = sys.argv[1], json.loads(sys.argv[2]), int(sys.argv[3])
rec = {"ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
       "kind": "doctrine_weave_tick", "files_published": published}
rec.update(summary)
with open(log, "a") as fh:
    fh.write(json.dumps(rec, separators=(",", ":")) + "\n")
PY

    file_gap_if_changed "$summary"
}

# File ONE gap when the finding set changed since the last filing. Never pages.
file_gap_if_changed() {
    [[ "${CHUMP_LOOM_FILE_GAPS:-0}" == "1" ]] || return 0
    local summary="$1" digest asym frayed last
    digest="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["digest"])' "$summary")"
    asym="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["asymmetries"])' "$summary")"
    frayed="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["frayed_edges"])' "$summary")"
    [[ "$asym" == "0" && "$frayed" == "0" ]] && return 0
    last="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("filed_digest",""))
except Exception: print("")' "$STATE_FILE")"
    [[ "$last" == "$digest" ]] && return 0
    if "$CHUMP_BIN" gap reserve --domain META --priority P3 --effort s \
        --title "META: doctrine weave drift — ${asym} asymmetric refs, ${frayed} frayed edges" \
        --acceptance-criteria "Re-run scripts/coord/doctrine-weave-detectors.py and reduce the findings: add the missing back-references / fix the dead section and closed-gap citations it reports (see doctrine_weave_asymmetry and doctrine_weave_frayed_edge in ambient.jsonl)." \
        >/dev/null 2>&1; then
        printf '{"filed_digest":"%s"}\n' "$digest" > "$STATE_FILE"
        echo "[doctrine-loom] filed drift gap (digest $digest)"
    else
        echo "[doctrine-loom] WARN: gap filing failed; will retry next tick" >&2
    fi
}

if [[ "$MODE" == "daemon" ]]; then
    while true; do
        tick || echo "[doctrine-loom] tick failed; retrying in ${INTERVAL_S}s" >&2
        sleep "$INTERVAL_S"
    done
else
    tick
fi
