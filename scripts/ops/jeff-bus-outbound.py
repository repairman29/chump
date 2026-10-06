#!/usr/bin/env python3
"""jeff-bus-outbound.py — Phase A of "Mirror in the OS": the conversation bus OUTBOUND leg.

Mirrors fleet->operator messages (ambient.jsonl events that address the
operator) into the canonical ``chump_web_messages`` table, as ``assistant``
rows in one well-known session ("Fleet -> Operator"). The operator therefore
sees them in the same web/PWA surface that already lists chump_web_sessions,
next to the inbound transcript turns written by jeff-bus-ingest.py.

SCOPE: PASSIVE, APPEND-ONLY LOG. It never approves, decides, routes, or acts.

DESIGN NOTES
  * Idempotent: each ambient line is keyed by sha1(line); keys live in
    ``chump_bus_ingest_cursor`` (shared with the inbound leg, source
    ``fleet-ambient``), so cadence re-runs never double-insert.
  * Only operator-addressed kinds are mirrored (OPERATOR_KINDS); the rest of the
    ambient stream is ignored.

CONFIG (env)
  CHUMP_MEMORY_DB_PATH   path to chump_memory.db (default: ./sessions/chump_memory.db)
  CHUMP_AMBIENT_PATH     ambient stream (default: ./.chump-locks/ambient.jsonl)
  CHUMP_BUS_OUT_BOT      chump_web_sessions.bot for the outbound session (default: chump)
"""

from __future__ import annotations

import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util

_spec = importlib.util.spec_from_file_location(
    "jeff_bus_ingest", os.path.join(os.path.dirname(os.path.abspath(__file__)), "jeff-bus-ingest.py")
)
_ingest = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_ingest)

OUT_SESSION_ID = "fleet-to-operator"
OUT_SESSION_TITLE = "Fleet -> Operator"
OPERATOR_KINDS = (
    "operator_page",
    "operator_decision_needed",
    "operator_recall",
    "escalation_fired",
)


def ambient_path() -> str:
    return os.environ.get("CHUMP_AMBIENT_PATH") or os.path.join(
        os.getcwd(), ".chump-locks", "ambient.jsonl"
    )


def render(obj: dict) -> str:
    kind = obj.get("kind", "")
    body = (
        obj.get("message")
        or obj.get("summary")
        or obj.get("reason")
        or obj.get("title")
        or ""
    )
    head = f"[{kind}]"
    for k in ("severity", "priority"):
        if obj.get(k):
            head += f" {obj[k]}"
    extras = " ".join(
        f"{k}={obj[k]}" for k in ("gap_id", "gap", "pr_number", "decision_kind") if obj.get(k)
    )
    return " ".join(p for p in (head, str(body).strip(), extras) if p)


def main() -> int:
    conn = _ingest.connect(_ingest.db_path())
    _ingest.ensure_schema(conn)
    bot = os.environ.get("CHUMP_BUS_OUT_BOT", "chump")
    stats = {"lines_seen": 0, "messages_inserted": 0, "skipped_duplicate": 0}
    path = ambient_path()
    cur = conn.cursor()
    if os.path.isfile(path):
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                stats["lines_seen"] += 1
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(obj, dict) or obj.get("kind") not in OPERATOR_KINDS:
                    continue
                key = "ambient:" + hashlib.sha1(line.encode("utf-8")).hexdigest()
                if cur.execute(
                    "SELECT 1 FROM chump_bus_ingest_cursor WHERE source_uuid = ?", (key,)
                ).fetchone():
                    stats["skipped_duplicate"] += 1
                    continue
                cur.execute(
                    "INSERT OR IGNORE INTO chump_web_sessions (id, bot, title) VALUES (?, ?, ?)",
                    (OUT_SESSION_ID, bot, OUT_SESSION_TITLE),
                )
                cur.execute(
                    "INSERT INTO chump_web_messages (session_id, role, content, created_at) "
                    "VALUES (?, 'assistant', ?, COALESCE(?, datetime('now')))",
                    (OUT_SESSION_ID, render(obj), obj.get("ts")),
                )
                cur.execute(
                    "INSERT OR IGNORE INTO chump_bus_ingest_cursor "
                    "(source_uuid, source, session_id, file, message_id) "
                    "VALUES (?, 'fleet-ambient', ?, ?, ?)",
                    (key, OUT_SESSION_ID, path, cur.lastrowid),
                )
                cur.execute(
                    "UPDATE chump_web_sessions SET updated_at = datetime('now') WHERE id = ?",
                    (OUT_SESSION_ID,),
                )
                stats["messages_inserted"] += 1
        conn.commit()
    print(json.dumps(stats, separators=(",", ":")))
    conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
