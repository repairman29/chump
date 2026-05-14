#!/usr/bin/env python3
"""github-webhook-receiver.py — INFRA-1081

Tiny HTTP server (Python stdlib only) that accepts GitHub webhook deliveries
on POST /webhook, validates X-Hub-Signature-256 HMAC-SHA256 against
CHUMP_GITHUB_WEBHOOK_SECRET, and writes events into .chump/github_cache.db.

Designed for laptop fleet operator setup via smee.io tunnel:
  smee --url $CHUMP_SMEE_URL --target http://localhost:9097/webhook
  → forwards GitHub webhook deliveries to this local receiver
  → no public IP / DNS needed

Handled events (others 200-OK ignored):
  - pull_request (any action): upsert pr_state by .pull_request.number
  - check_suite (completed): bump fetched_at_local on referenced PRs
  - push (refs/heads/main only): mark all open PRs as stale
  - workflow_run (completed): same as check_suite

Schema: see _ensure_schema().

Run:
  CHUMP_WEBHOOK_PORT=9097 CHUMP_GITHUB_WEBHOOK_SECRET=... python3 scripts/ops/github-webhook-receiver.py

Env:
  CHUMP_WEBHOOK_PORT (default 9097)
  CHUMP_GITHUB_WEBHOOK_SECRET (required; HMAC-SHA256 key)
  CHUMP_CACHE_DB (default {repo_root}/.chump/github_cache.db)
  CHUMP_AMBIENT_LOG (default {repo_root}/.chump-locks/ambient.jsonl)

INFRA-1081.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import sqlite3
import sys
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("github-webhook-receiver")


def _repo_root() -> Path:
    return Path(__file__).resolve().parent.parent.parent


CACHE_DB = Path(os.environ.get("CHUMP_CACHE_DB", str(_repo_root() / ".chump" / "github_cache.db")))
AMBIENT = Path(os.environ.get("CHUMP_AMBIENT_LOG", str(_repo_root() / ".chump-locks" / "ambient.jsonl")))
SECRET = os.environ.get("CHUMP_GITHUB_WEBHOOK_SECRET", "")
PORT = int(os.environ.get("CHUMP_WEBHOOK_PORT", "9097"))


def _ensure_schema(conn: sqlite3.Connection) -> None:
    """Create pr_state table + index if missing. Idempotent."""
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS pr_state (
            number              INTEGER PRIMARY KEY,
            head_ref            TEXT,
            head_sha            TEXT,
            base_ref            TEXT,
            base_sha            TEXT,
            mergeable_state     TEXT,
            auto_merge_enabled  INTEGER NOT NULL DEFAULT 0,
            draft               INTEGER NOT NULL DEFAULT 0,
            merged_at           TEXT,
            title               TEXT,
            user_login          TEXT,
            updated_at_api      TEXT NOT NULL,
            fetched_at_local    TEXT NOT NULL,
            raw_payload_json    TEXT
        );
        CREATE INDEX IF NOT EXISTS pr_state_behind_armed
            ON pr_state(mergeable_state, auto_merge_enabled);
        """
    )
    conn.commit()


def _emit_ambient(event: dict) -> None:
    """Append one JSON line to ambient.jsonl. Best-effort; never raises."""
    try:
        AMBIENT.parent.mkdir(parents=True, exist_ok=True)
        with AMBIENT.open("a", encoding="utf-8") as f:
            f.write(json.dumps(event, separators=(",", ":")) + "\n")
    except Exception as e:
        log.warning("ambient emit failed: %s", e)


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _verify_signature(secret: str, payload: bytes, header: str | None) -> bool:
    """Verify GitHub's X-Hub-Signature-256 header. Constant-time compare."""
    if not secret or not header or not header.startswith("sha256="):
        return False
    expected = "sha256=" + hmac.new(secret.encode(), payload, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header)


def _upsert_pr(conn: sqlite3.Connection, pr: dict, payload: dict) -> None:
    """Upsert a pull_request row into pr_state."""
    now = _now_iso()
    conn.execute(
        """
        INSERT INTO pr_state (
            number, head_ref, head_sha, base_ref, base_sha,
            mergeable_state, auto_merge_enabled, draft, merged_at,
            title, user_login, updated_at_api, fetched_at_local, raw_payload_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(number) DO UPDATE SET
            head_ref           = excluded.head_ref,
            head_sha           = excluded.head_sha,
            base_ref           = excluded.base_ref,
            base_sha           = excluded.base_sha,
            mergeable_state    = excluded.mergeable_state,
            auto_merge_enabled = excluded.auto_merge_enabled,
            draft              = excluded.draft,
            merged_at          = excluded.merged_at,
            title              = excluded.title,
            user_login         = excluded.user_login,
            updated_at_api     = excluded.updated_at_api,
            fetched_at_local   = excluded.fetched_at_local,
            raw_payload_json   = excluded.raw_payload_json
        """,
        (
            pr.get("number"),
            (pr.get("head") or {}).get("ref"),
            (pr.get("head") or {}).get("sha"),
            (pr.get("base") or {}).get("ref"),
            (pr.get("base") or {}).get("sha"),
            pr.get("mergeable_state"),
            1 if pr.get("auto_merge") else 0,
            1 if pr.get("draft") else 0,
            pr.get("merged_at"),
            pr.get("title"),
            (pr.get("user") or {}).get("login"),
            pr.get("updated_at") or _now_iso(),
            now,
            json.dumps(payload),
        ),
    )
    conn.commit()


def _mark_open_prs_stale(conn: sqlite3.Connection) -> int:
    """On push to main, every open PR may have become BEHIND. Mark all open PRs
    as fetched_at_local=NULL so the next cache_lookup forces a re-fetch."""
    cur = conn.execute("UPDATE pr_state SET fetched_at_local = '1970-01-01T00:00:00Z' WHERE merged_at IS NULL")
    conn.commit()
    return cur.rowcount


class Handler(BaseHTTPRequestHandler):
    server_version = "ChumpWebhookReceiver/1.0"

    def log_message(self, format: str, *args) -> None:  # type: ignore[override]
        log.info("%s - %s", self.address_string(), format % args)

    def _respond(self, status: int, body: str = "") -> None:
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body.encode("utf-8"))

    def do_POST(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler convention)
        if self.path != "/webhook":
            self._respond(404, "not found\n")
            return

        length = int(self.headers.get("Content-Length", "0"))
        payload_bytes = self.rfile.read(length)
        sig_header = self.headers.get("X-Hub-Signature-256")

        if not _verify_signature(SECRET, payload_bytes, sig_header):
            _emit_ambient({
                "ts": _now_iso(),
                "kind": "webhook_event_rejected",
                "reason": "hmac_mismatch",
                "source_ip": self.client_address[0],
            })
            self._respond(401, "invalid signature\n")
            return

        event_type = self.headers.get("X-GitHub-Event", "unknown")
        try:
            payload = json.loads(payload_bytes.decode("utf-8"))
        except json.JSONDecodeError:
            self._respond(400, "invalid json\n")
            return

        try:
            with sqlite3.connect(str(CACHE_DB)) as conn:
                _ensure_schema(conn)
                if event_type == "pull_request":
                    pr = payload.get("pull_request") or {}
                    if pr:
                        _upsert_pr(conn, pr, payload)
                        _emit_ambient({
                            "ts": _now_iso(),
                            "kind": "webhook_event_received",
                            "event_type": event_type,
                            "action": payload.get("action"),
                            "pr_number": pr.get("number"),
                        })
                elif event_type in ("check_suite", "workflow_run"):
                    # Touch fetched_at_local for referenced PRs so consumers re-fetch.
                    suite = payload.get(event_type) or {}
                    prs = suite.get("pull_requests") or []
                    for pr in prs:
                        conn.execute(
                            "UPDATE pr_state SET fetched_at_local = ? WHERE number = ?",
                            (_now_iso(), pr.get("number")),
                        )
                    conn.commit()
                    _emit_ambient({
                        "ts": _now_iso(),
                        "kind": "webhook_event_received",
                        "event_type": event_type,
                        "action": payload.get("action"),
                        "pr_number": None,
                    })
                elif event_type == "push":
                    if payload.get("ref") == "refs/heads/main":
                        n = _mark_open_prs_stale(conn)
                        _emit_ambient({
                            "ts": _now_iso(),
                            "kind": "webhook_event_received",
                            "event_type": event_type,
                            "action": "push_to_main",
                            "pr_number": None,
                            "marked_stale_count": n,
                        })
                # Unknown event types: 200 OK, no DB write — GitHub retries forever
                # on non-2xx, so don't fail.
        except Exception as e:
            log.error("DB write failed: %s", e)
            self._respond(500, "internal\n")
            return

        self._respond(200, "ok\n")


def main() -> None:
    if not SECRET:
        log.error("CHUMP_GITHUB_WEBHOOK_SECRET is required")
        sys.exit(2)
    CACHE_DB.parent.mkdir(parents=True, exist_ok=True)
    log.info("listening on :%d cache=%s ambient=%s", PORT, CACHE_DB, AMBIENT)
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("shutting down")


if __name__ == "__main__":
    main()
