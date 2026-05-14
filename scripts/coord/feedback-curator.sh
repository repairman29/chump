#!/usr/bin/env bash
# scripts/coord/feedback-curator.sh — INFRA-1272
#
# Reads $LOCK_DIR/feedback.jsonl (FEEDBACK events from INFRA-1271), groups
# them by kind+subject over a rolling 7-day window, and when a cluster
# reaches CHUMP_FEEDBACK_THRESHOLD distinct sessions, auto-files a gap
# with citations. Dedup: if a gap was already filed for the same subject
# within 30 days, add a note instead of filing again.
#
# Usage:
#   feedback-curator.sh             # dry-run
#   feedback-curator.sh --apply     # actually file gaps / add notes
#
# Cron-friendly. Emits kind=feedback_curated with counts.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
FB="$LOCK_DIR/feedback.jsonl"
AMBIENT="$LOCK_DIR/ambient.jsonl"

THRESHOLD="${CHUMP_FEEDBACK_THRESHOLD:-3}"
WINDOW_DAYS="${CHUMP_FEEDBACK_WINDOW_DAYS:-7}"
DEDUP_DAYS="${CHUMP_FEEDBACK_DEDUP_DAYS:-30}"

APPLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --window-days) WINDOW_DAYS="$2"; shift 2 ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "[feedback-curator] unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -f "$FB" ] || { echo "[feedback-curator] no feedback.jsonl yet"; exit 0; }

# Python does the heavy lifting: parse JSONL, group, gate by threshold,
# decide whether to file new gap vs add-note vs skip.
python3 - "$FB" "$THRESHOLD" "$WINDOW_DAYS" "$DEDUP_DAYS" "$APPLY" "$REPO_ROOT" "$AMBIENT" <<'PY'
import json, os, sys, time, subprocess
from collections import defaultdict
from datetime import datetime, timezone, timedelta

fb_path, threshold, window_days, dedup_days, apply, repo_root, ambient = sys.argv[1:8]
threshold = int(threshold)
window_days = int(window_days)
dedup_days = int(dedup_days)
apply = apply == "1"

now = datetime.now(timezone.utc)
window_cutoff = now - timedelta(days=window_days)

# Read feedback entries within the window.
entries = []
with open(fb_path) as f:
    for raw in f:
        raw = raw.strip()
        if not raw:
            continue
        try:
            e = json.loads(raw)
        except Exception:
            continue
        ts = e.get("ts", "")
        try:
            t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        except Exception:
            continue
        if t < window_cutoff:
            continue
        if e.get("event") != "FEEDBACK":
            continue
        entries.append(e)

# Group by (kind, subject); collect distinct sessions.
clusters = defaultdict(lambda: {"sessions": set(), "entries": []})
for e in entries:
    key = (e.get("kind", ""), e.get("subject", ""))
    if not key[0] or not key[1]:
        continue
    clusters[key]["sessions"].add(e.get("session", "?"))
    clusters[key]["entries"].append(e)

# Filter to clusters meeting the session-count threshold.
flagged = []
for (kind, subject), data in clusters.items():
    if len(data["sessions"]) >= threshold:
        flagged.append({
            "kind": kind,
            "subject": subject,
            "n_sessions": len(data["sessions"]),
            "entries": data["entries"],
        })

print(f"[feedback-curator] {len(entries)} feedback entries in last {window_days}d, "
      f"{len(clusters)} clusters, {len(flagged)} above threshold={threshold}")

# Dedup: check existing recent gaps that cite the subject. We use
# `chump gap list --json` and look for gaps whose notes contain the subject
# and whose opened_date is within dedup_days.
existing = subprocess.run(
    ["chump", "gap", "list", "--json"],
    capture_output=True, text=True
).stdout
try:
    all_gaps = json.loads(existing) if existing else []
except Exception:
    all_gaps = []

dedup_cutoff = now - timedelta(days=dedup_days)
# Subjects from flagged clusters (cluster key is (kind, subject)).
flagged_subjects = {f["subject"] for f in flagged}

recent_subject_gaps = {}  # subject -> [gap_ids]
for g in all_gaps:
    opened = g.get("opened_date") or g.get("created_at") or ""
    if not opened:
        continue
    try:
        # YAML "2026-05-14" plain-date OK; ISO too.
        if "T" in opened:
            t = datetime.fromisoformat(opened.replace("Z", "+00:00"))
        else:
            t = datetime.fromisoformat(opened + "T00:00:00+00:00")
    except Exception:
        continue
    if t < dedup_cutoff:
        continue
    haystack = (g.get("title", "") or "") + " " + (g.get("notes", "") or "")
    for s in flagged_subjects:
        if s and s in haystack:
            recent_subject_gaps.setdefault(s, []).append(g.get("id", ""))

filed_count = 0
noted_count = 0
for f in flagged:
    citations = "\n".join(
        f"  - [{e.get('session','?')} @ {e.get('ts','?')}] {e.get('rationale','(no rationale)')[:140]}"
        for e in f["entries"]
    )
    note_body = (
        f"INFRA-1272 feedback-curator (auto-filed):\n"
        f"  {f['n_sessions']} distinct session(s) reported FEEDBACK kind={f['kind']} subject={f['subject']} "
        f"in the last {window_days}d:\n{citations}\n"
        f"Source: $LOCK_DIR/feedback.jsonl"
    )

    existing_ids = recent_subject_gaps.get(f["subject"], [])
    if existing_ids:
        # Dedup: add-note to first existing
        target = existing_ids[0]
        if apply:
            try:
                subprocess.run(
                    ["chump", "gap", "set", target, "--add-note", note_body],
                    check=True, timeout=30,
                )
                print(f"[feedback-curator] add-note to {target} (cluster: {f['kind']} {f['subject']}, n={f['n_sessions']})")
                noted_count += 1
            except Exception as exc:
                print(f"[feedback-curator] add-note FAILED for {target}: {exc}", file=sys.stderr)
        else:
            print(f"[feedback-curator] WOULD add-note to {target} "
                  f"(cluster: {f['kind']} {f['subject']}, n={f['n_sessions']})")
    else:
        # File new gap. Domain: best-effort from subject prefix; fall back to INFRA.
        domain = "INFRA"
        subj = f["subject"]
        if "-" in subj:
            head = subj.split("-", 1)[0]
            if head.isalpha() and head.isupper():
                domain = head
        title = f"FEEDBACK[{f['kind']}] from {f['n_sessions']} sessions: {f['subject']}"
        if apply:
            try:
                # chump gap reserve prints just the new ID on stdout.
                proc = subprocess.run(
                    ["chump", "gap", "reserve", "--domain", domain, "--title", title,
                     "--priority", "P2", "--effort", "s", "--pillar", "credible"],
                    capture_output=True, text=True, timeout=30
                )
                new_id = proc.stdout.strip().splitlines()[-1] if proc.stdout else ""
                if not new_id:
                    print(f"[feedback-curator] reserve returned empty for {f['subject']}: {proc.stderr}", file=sys.stderr)
                    continue
                # Attach the rationale note
                subprocess.run(
                    ["chump", "gap", "set", new_id, "--add-note", note_body],
                    check=True, timeout=30,
                )
                print(f"[feedback-curator] filed {new_id} for cluster {f['kind']} {f['subject']} (n={f['n_sessions']})")
                filed_count += 1
            except Exception as exc:
                print(f"[feedback-curator] reserve FAILED for {f['subject']}: {exc}", file=sys.stderr)
        else:
            print(f"[feedback-curator] WOULD reserve {domain}-NEW for cluster {f['kind']} {f['subject']} "
                  f"(n={f['n_sessions']})")

# Audit
if apply:
    try:
        with open(ambient, "a") as a:
            a.write(json.dumps({
                "ts": now.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
                "kind": "feedback_curated",
                "window_days": window_days,
                "threshold": threshold,
                "clusters_total": len(clusters),
                "clusters_flagged": len(flagged),
                "filed": filed_count,
                "noted": noted_count,
            }) + "\n")
    except Exception:
        pass

print(f"[feedback-curator] filed={filed_count} noted={noted_count}")
PY
