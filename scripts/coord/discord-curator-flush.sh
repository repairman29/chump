#!/usr/bin/env bash
# discord-curator-flush.sh — RESILIENT-1093: single-voice curation layer.
#
# notify-operator.sh's page-verdict path defers page-worthy signals into a
# JSONL queue instead of dialing Discord immediately (see
# _notify_curate_enqueue in scripts/coord/lib/notify-operator.sh). This script
# drains that queue and sends ONE combined DM, so N organs firing in one
# window produce one curated voice instead of N separate posts — the surface-2
# invariant in docs/DISCORD_OPERATOR_CONSOLE.md ("one curated voice, never a
# firehose").
#
# Run this on a cadence (a beat/cron tick) rather than per-signal; the window
# it curates is simply "whatever landed in the queue since the last flush".
#
# shellcheck shell=bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/notify-operator.sh
source "${SCRIPT_DIR}/lib/notify-operator.sh"

queue="$(_notify_queue_path)"
[[ -s "$queue" ]] || exit 0

# Move the queue aside first so signals enqueued *during* this flush land in a
# fresh file for the next tick, rather than racing this read.
processing="${queue}.processing.$$"
mv "$queue" "$processing" 2>/dev/null || exit 0

combined="$(python3 -c '
import json, sys
from collections import OrderedDict

seen = OrderedDict()      # content -> [kinds] in first-seen order, deduped
sources = OrderedDict()   # distinct kinds seen at all

with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except ValueError:
            continue
        content = (row.get("content") or "").strip()
        kind = row.get("kind") or "unclassified"
        if not content:
            continue
        seen.setdefault(content, []).append(kind)
        sources[kind] = True

if not seen:
    sys.exit(0)

n_signals = sum(len(v) for v in seen.values())
n_sources = len(sources)
lines = [f"Fleet update ({n_signals} signal(s) from {n_sources} source(s)):"]
for content, kinds in seen.items():
    tag = ",".join(sorted(set(kinds)))
    lines.append(f"[{tag}] {content}")
print("\n".join(lines))
' "$processing")"
rc=$?

rm -f "$processing" 2>/dev/null || true

if [[ $rc -ne 0 || -z "$combined" ]]; then
    exit 0
fi

# Deliver directly — these signals already passed escalation classification
# once (that's how they got into the queue); re-classifying the combined
# message would be wrong (it has no single `kind`).
_notify_deliver "$combined"
