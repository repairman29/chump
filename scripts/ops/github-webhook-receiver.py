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
import shutil
import sqlite3
import subprocess
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
    """Create pr_state + check_runs tables + indexes if missing. Idempotent."""
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
    # INFRA-1368: add merge_state_status column (idempotent — ignore duplicate-column error).
    # Stores the webhook pull_request.mergeable_state value so consumers can
    # look it up from the column rather than parsing the raw_payload_json blob
    # (which has inconsistent shape between webhook and REST sources).
    try:
        conn.execute("ALTER TABLE pr_state ADD COLUMN merge_state_status TEXT")
        conn.commit()
    except Exception:
        pass  # column already exists — safe to ignore
    conn.executescript(
        """
        -- INFRA-1107: per (head_sha, check_name) CI status, populated by
        -- check_suite.completed + workflow_run.completed webhook events.
        -- Unlocks bot-merge's per-PR check_runs polling.
        CREATE TABLE IF NOT EXISTS check_runs (
            head_sha          TEXT NOT NULL,
            name              TEXT NOT NULL,
            status            TEXT,
            conclusion        TEXT,
            started_at        TEXT,
            completed_at      TEXT,
            fetched_at_local  TEXT NOT NULL,
            PRIMARY KEY (head_sha, name)
        );
        CREATE INDEX IF NOT EXISTS check_runs_sha
            ON check_runs(head_sha);
        """
    )
    conn.commit()


def _upsert_check_runs(conn: sqlite3.Connection, head_sha: str, runs: list) -> int:
    """INFRA-1107: write/update check_runs rows for a given head SHA."""
    if not head_sha or not runs:
        return 0
    now = _now_iso()
    n = 0
    for r in runs:
        name = r.get("name") or r.get("check_run", {}).get("name")
        if not name:
            continue
        conn.execute(
            """
            INSERT INTO check_runs (head_sha, name, status, conclusion, started_at, completed_at, fetched_at_local)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(head_sha, name) DO UPDATE SET
                status           = excluded.status,
                conclusion       = excluded.conclusion,
                started_at       = excluded.started_at,
                completed_at     = excluded.completed_at,
                fetched_at_local = excluded.fetched_at_local
            """,
            (head_sha, name, r.get("status"), r.get("conclusion"),
             r.get("started_at"), r.get("completed_at"), now),
        )
        n += 1
    conn.commit()
    return n


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


def _extract_gap_ids(pr: dict) -> list[str]:
    """Extract gap IDs from PR title + body.

    Looks for patterns like 'INFRA-1234' or 'CREDIBLE-001' anywhere in the
    PR title or body. Returns a deduped list preserving first-seen order.
    """
    import re

    pattern = re.compile(r"\b([A-Z][A-Z-]+-\d+)\b")
    seen: set[str] = set()
    ordered: list[str] = []
    for field in ("title", "body"):
        text = pr.get(field) or ""
        for match in pattern.findall(text):
            if match not in seen:
                seen.add(match)
                ordered.append(match)
    return ordered


def _auto_release_sibling_leases(pr: dict, payload: dict) -> int:
    """INFRA-1444: on a merged PR, release any sibling lease matching the
    gap ID(s) parsed from the PR title/body.

    Behavior:
    - Only fires when action=closed AND merged=true.
    - For each gap ID found in the PR title/body, scans .chump-locks/claim-*.json
      for files whose gap_id field matches.
    - Identifies the "PR author session" via the PR head commit author email
      heuristic (CHUMP_LEASE_RELEASE_KEEP_AUTHOR=1 to preserve the original
      claimant's lease if they were the actual PR shipper); default: release ALL
      matching leases since the gap is done regardless of who shipped it.
    - Deletes matched lease files and emits kind=lease_orphaned_by_sibling_merge
      for each release.

    Returns the count of leases released.

    Bypass: CHUMP_LEASE_NO_AUTO_RELEASE=1 disables entirely.
    """
    if os.environ.get("CHUMP_LEASE_NO_AUTO_RELEASE") == "1":
        return 0
    if payload.get("action") != "closed" or not pr.get("merged"):
        return 0

    gap_ids = _extract_gap_ids(pr)
    if not gap_ids:
        return 0

    locks_dir = _repo_root() / ".chump-locks"
    if not locks_dir.is_dir():
        return 0

    released = 0
    pr_number = pr.get("number")
    for lease_file in locks_dir.glob("claim-*.json"):
        try:
            with lease_file.open("r", encoding="utf-8") as f:
                lease = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue
        lease_gap_id = lease.get("gap_id") or ""
        if lease_gap_id not in gap_ids:
            continue
        lease_session_id = lease.get("session_id") or "unknown"
        try:
            lease_file.unlink()
            released += 1
            _emit_ambient({
                "ts": _now_iso(),
                "kind": "lease_orphaned_by_sibling_merge",
                "gap_id": lease_gap_id,
                "released_session_id": lease_session_id,
                "merged_pr": pr_number,
                "lease_file": lease_file.name,
            })
            log.info("released orphaned lease: gap=%s session=%s (merged via PR #%s)",
                     lease_gap_id, lease_session_id, pr_number)
        except OSError as e:
            log.warning("failed to release lease %s: %s", lease_file, e)
    return released


def _auto_prune_worktree_on_merge(pr: dict, payload: dict) -> int:
    """INFRA-1705: on a merged PR, prune the corresponding /tmp/chump-<slug>/
    worktree immediately instead of waiting for the periodic prune-worktrees.sh
    sweep.

    Fires AFTER _auto_release_sibling_leases (which clears the lease entry for
    this gap), so the lease-check safety condition is already satisfied. Other
    safety checks:
      - head_ref must match chump/<slug>-claim convention (otherwise we don't
        know where the worktree lives)
      - worktree directory must exist under /tmp/
      - no uncommitted changes (git diff --quiet HEAD)

    Emits kind=worktree_orphan_pruned (success) or kind=worktree_orphan_skipped
    (safety-check blocked) — same kinds the periodic sweep emits — with an
    extra `trigger: pr_merge_webhook` field so consumers can distinguish.

    Returns 1 if pruned, 0 otherwise.

    Bypass: CHUMP_NO_AUTO_PRUNE_WORKTREE=1
    """
    if os.environ.get("CHUMP_NO_AUTO_PRUNE_WORKTREE") == "1":
        return 0
    if payload.get("action") != "closed" or not pr.get("merged"):
        return 0
    head_ref = (pr.get("head") or {}).get("ref") or ""
    if not (head_ref.startswith("chump/") and head_ref.endswith("-claim")):
        return 0
    slug = head_ref[len("chump/"):-len("-claim")]
    if not slug:
        return 0
    worktree_path = Path("/tmp") / f"chump-{slug}"
    if not worktree_path.is_dir():
        return 0
    pr_number = pr.get("number")
    repo_root = _repo_root()

    # Safety: skip if there are uncommitted changes in the worktree.
    try:
        diff = subprocess.run(
            ["git", "-C", str(worktree_path), "diff", "--quiet", "HEAD"],
            check=False,
            capture_output=True,
            timeout=10,
        )
        if diff.returncode != 0:
            _emit_ambient({
                "ts": _now_iso(),
                "kind": "worktree_orphan_skipped",
                "path": str(worktree_path),
                "branch": head_ref,
                "reason": "uncommitted_changes",
                "trigger": "pr_merge_webhook",
                "merged_pr": pr_number,
            })
            log.info("INFRA-1705: skipped prune of %s — uncommitted changes (PR #%s)",
                     worktree_path, pr_number)
            return 0
    except (subprocess.TimeoutExpired, OSError) as e:
        log.warning("INFRA-1705: git diff check failed for %s: %s", worktree_path, e)
        return 0

    # Primary path: git worktree remove --force (also prunes the linked-worktree
    # gitdir back-reference under .git/worktrees/).
    method = "git_worktree_remove"
    try:
        result = subprocess.run(
            ["git", "worktree", "remove", "--force", str(worktree_path)],
            cwd=str(repo_root),
            check=False,
            capture_output=True,
            timeout=15,
        )
        if result.returncode != 0:
            # Fallback: rm + git worktree prune. Mirrors the bash sweep's
            # fallback path for worktrees whose gitdir back-ref is corrupt.
            method = "rm_fallback"
            shutil.rmtree(worktree_path, ignore_errors=True)
            subprocess.run(
                ["git", "worktree", "prune"],
                cwd=str(repo_root),
                check=False,
                timeout=10,
            )
    except (subprocess.TimeoutExpired, OSError) as e:
        log.warning("INFRA-1705: worktree remove failed for %s: %s", worktree_path, e)
        return 0

    if worktree_path.exists():
        log.warning("INFRA-1705: worktree %s still present after prune attempt", worktree_path)
        return 0

    _emit_ambient({
        "ts": _now_iso(),
        "kind": "worktree_orphan_pruned",
        "path": str(worktree_path),
        "branch": head_ref,
        "trigger": "pr_merge_webhook",
        "merged_pr": pr_number,
        "method": method,
    })
    log.info("INFRA-1705: pruned worktree %s after PR #%s merge", worktree_path, pr_number)
    return 1


def _verify_signature(secret: str, payload: bytes, header: str | None) -> bool:
    """Verify GitHub's X-Hub-Signature-256 header. Constant-time compare."""
    if not secret or not header or not header.startswith("sha256="):
        return False
    expected = "sha256=" + hmac.new(secret.encode(), payload, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header)


def _upsert_pr(conn: sqlite3.Connection, pr: dict, payload: dict) -> None:
    """Upsert a pull_request row into pr_state."""
    now = _now_iso()
    # INFRA-1368: store merge_state_status in its own column so the gh-shim can
    # look it up directly without parsing raw_payload_json (whose format differs
    # between webhook and REST sources). pr.get("mergeable_state") is the correct
    # path inside the pull_request sub-object of a GitHub pull_request webhook.
    merge_state_status = pr.get("mergeable_state")
    conn.execute(
        """
        INSERT INTO pr_state (
            number, head_ref, head_sha, base_ref, base_sha,
            mergeable_state, auto_merge_enabled, draft, merged_at,
            title, user_login, updated_at_api, fetched_at_local, raw_payload_json,
            merge_state_status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            raw_payload_json   = excluded.raw_payload_json,
            merge_state_status = excluded.merge_state_status
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
            merge_state_status,
        ),
    )
    conn.commit()


def _mark_open_prs_stale(conn: sqlite3.Connection) -> int:
    """On push to main, every open PR may have become BEHIND. Mark all open PRs
    as fetched_at_local=NULL so the next cache_lookup forces a re-fetch."""
    cur = conn.execute("UPDATE pr_state SET fetched_at_local = '1970-01-01T00:00:00Z' WHERE merged_at IS NULL")
    conn.commit()
    return cur.rowcount


# INFRA-1110: process-lifetime counters for /health endpoint.
_health_started_at = _now_iso()
_health_events_received_total = 0
_health_last_event_at: str | None = None


class Handler(BaseHTTPRequestHandler):
    server_version = "ChumpWebhookReceiver/1.0"

    def log_message(self, format: str, *args) -> None:  # type: ignore[override]
        log.info("%s - %s", self.address_string(), format % args)

    def _respond(self, status: int, body: str = "", content_type: str = "text/plain; charset=utf-8") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body.encode("utf-8"))

    def do_GET(self) -> None:  # noqa: N802
        # INFRA-1110: /health for operator liveness probe.
        if self.path == "/health":
            from datetime import timedelta
            stale_threshold_s = 24 * 3600
            status_ok = True
            if _health_last_event_at:
                try:
                    last = datetime.strptime(_health_last_event_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                    if (datetime.now(timezone.utc) - last).total_seconds() > stale_threshold_s:
                        status_ok = False
                except Exception:
                    pass
            body = json.dumps({
                "status": "ok" if status_ok else "stale",
                "pid": os.getpid(),
                "started_at": _health_started_at,
                "events_received_total": _health_events_received_total,
                "last_event_at": _health_last_event_at,
                "cache_db_path": str(CACHE_DB),
            }, indent=2) + "\n"
            self._respond(200 if status_ok else 503, body, content_type="application/json")
            return
        self._respond(404, "not found\n")

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
                        # INFRA-1444: on PR merge, auto-release sibling leases
                        # whose gap_id matches a gap referenced in the PR title/body.
                        # Closes the "orphan lease + worktree after sibling shipped
                        # the same gap" pattern observed today (2026-05-15).
                        released = _auto_release_sibling_leases(pr, payload)
                        if released > 0:
                            log.info("INFRA-1444: auto-released %d orphaned lease(s) for PR #%s",
                                     released, pr.get("number"))
                        # INFRA-1705: on PR merge, prune the corresponding
                        # /tmp/chump-<slug>/ worktree immediately so the
                        # 5-10min "orphan window" before the next periodic
                        # prune sweep is closed.
                        pruned = _auto_prune_worktree_on_merge(pr, payload)
                        if pruned > 0:
                            log.info("INFRA-1705: auto-pruned worktree for PR #%s",
                                     pr.get("number"))
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
                    # INFRA-1107: cache check_runs per head SHA so bot-merge can
                    # read CI status from sqlite instead of polling gh api.
                    # The check_suite payload's `check_runs` URL points at a list;
                    # the workflow_run payload has `jobs` with similar shape. For
                    # check_suite, we use the head_sha + the workflow conclusion
                    # as a single check-row (named after the workflow).
                    head_sha = suite.get("head_sha") or suite.get("head_commit", {}).get("id")
                    runs_to_cache = []
                    if event_type == "check_suite":
                        # check_suite payload has aggregate status/conclusion;
                        # use the workflow name(s) as check_run names.
                        name = suite.get("app", {}).get("slug") or "check_suite"
                        runs_to_cache.append({
                            "name": name,
                            "status": suite.get("status"),
                            "conclusion": suite.get("conclusion"),
                            "started_at": suite.get("created_at"),
                            "completed_at": suite.get("updated_at"),
                        })
                    elif event_type == "workflow_run":
                        runs_to_cache.append({
                            "name": suite.get("name") or "workflow_run",
                            "status": suite.get("status"),
                            "conclusion": suite.get("conclusion"),
                            "started_at": suite.get("run_started_at"),
                            "completed_at": suite.get("updated_at"),
                        })
                    cached_n = _upsert_check_runs(conn, head_sha or "", runs_to_cache)
                    _emit_ambient({
                        "ts": _now_iso(),
                        "kind": "webhook_event_received",
                        "event_type": event_type,
                        "action": payload.get("action"),
                        "pr_number": None,
                        "check_runs_cached": cached_n,
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
            # INFRA-1110: bump counters AFTER successful processing.
            global _health_events_received_total, _health_last_event_at
            _health_events_received_total += 1
            _health_last_event_at = _now_iso()
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
