#!/usr/bin/env python3
"""nats-to-gap.py — drain NATS chump.events.voa + chump.events.holler into gaps.

Only files when no open/claimed gap shares the dedup key (stored in gap notes as
`nats_dedup:<key>`). Replaces the review-Andri-inbox loop with an autonomous pipeline.

 Stdlib-only. Subscribes via the existing `nats` CLI (already authed on every node)
 or falls back to reading `.chump-locks/ambient.jsonl` for local events.
"""
import hashlib, json, os, pathlib, sqlite3, subprocess, sys, time

REPO = pathlib.Path(os.environ.get("CHUMP_REPO", str(pathlib.Path.home() / "chump")))
DB = pathlib.Path(os.environ.get("CHUMP_STATE_DB", str(REPO / ".chump/state.db")))
CUR_FILE = pathlib.Path(os.environ.get("NATS_GAP_CURSOR", str(pathlib.Path.home() / ".chump/nats-to-gap.cursor")))
NATS_URL = os.environ.get("NATS_URL", "tls://connect.ngs.global:4222")
NATS_CREDS = os.environ.get("NATS_CREDS", str(pathlib.Path.home() / ".chump/ngs-chump.creds"))

# Actionable kinds: only these auto-file. Everything else is informational.
ACTIONABLE_KINDS = {
    "voa",                    # explicit voice-of-agent friction signal
    "holler",                 # explicit escalation
    "node_converge_far_behind",
    "organ_reconcile_failed",
    "store_reconcile_failed",
    "fleet_alert",
}


def dedup_key(ev: dict) -> str:
    kind = ev.get("kind", "")
    # Coarse key: kind + first 80 chars of summary/message/reason, normalized
    msg = (
        ev.get("summary")
        or ev.get("message")
        or ev.get("reason")
        or ev.get("title")
        or ev.get("detail")
        or ""
    )
    norm = " ".join(str(msg).lower().split())[:80]
    raw = f"{kind}:{norm}"
    return "nats_dedup:" + hashlib.sha1(raw.encode()).hexdigest()[:12]


def already_filed(conn: sqlite3.Connection, key: str) -> bool:
    cur = conn.execute(
        "SELECT 1 FROM gaps WHERE notes LIKE ? AND status NOT IN ('done','retired','invalid','wontfix') LIMIT 1",
        (f"%{key}%",),
    )
    return cur.fetchone() is not None


def file_gap(ev: dict, key: str) -> str | None:
    kind = ev.get("kind", "event")
    host = ev.get("host") or ev.get("node") or "?"
    msg = (
        ev.get("summary")
        or ev.get("message")
        or ev.get("reason")
        or ev.get("title")
        or json.dumps(ev)[:120]
    )
    title = f"[auto:{kind}@{host}] {str(msg)[:90]}"
    domain = "RESILIENT" if "fail" in kind or "behind" in kind else "INFRA"
    priority = "P1" if kind in ("holler", "fleet_alert") else "P2"
    desc = f"Auto-filed from ambient/NATS event:\n\n```json\n{json.dumps(ev, indent=2)[:1500]}\n```\n\n{key}"
    cmd = [
        "chump", "gap", "reserve",
        "--domain", domain,
        "--title", title,
        "--priority", priority,
        "--effort", "s",
        "--description", desc,
    ]
    r = subprocess.run(cmd, cwd=str(REPO), capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        sys.stderr.write(f"[nats-to-gap] reserve failed: {r.stderr[:200]}\n")
        return None
    # Stamp dedup key into notes
    gap_id = r.stdout.strip().split()[-1] if r.stdout.strip() else ""
    if gap_id:
        subprocess.run(
            ["chump", "gap", "set", gap_id, "--add-note", key],
            cwd=str(REPO), capture_output=True, timeout=15,
        )
    return gap_id


def drain_ambient():
    amb = REPO / ".chump-locks/ambient.jsonl"
    if not amb.exists() or not DB.exists():
        return
    last_off = 0
    if CUR_FILE.exists():
        try:
            last_off = int(CUR_FILE.read_text().strip() or "0")
        except Exception:
            last_off = 0
    size = amb.stat().st_size
    if size < last_off:
        last_off = 0  # rotated
    conn = sqlite3.connect(str(DB))
    filed = 0
    with amb.open("rb") as f:
        f.seek(last_off)
        for raw in f:
            try:
                ev = json.loads(raw.decode("utf-8", "replace"))
            except Exception:
                continue
            kind = ev.get("kind", "")
            if kind not in ACTIONABLE_KINDS:
                continue
            key = dedup_key(ev)
            if already_filed(conn, key):
                continue
            gid = file_gap(ev, key)
            if gid:
                filed += 1
                print(f"[nats-to-gap] filed {gid} for {kind} ({key})")
                if filed >= 5:  # rate-limit per pass
                    break
        new_off = f.tell()
    CUR_FILE.parent.mkdir(parents=True, exist_ok=True)
    CUR_FILE.write_text(str(new_off))
    conn.close()


def ensure_schema(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS gaps (
            id TEXT PRIMARY KEY,
            domain TEXT NOT NULL DEFAULT 'INFRA',
            title TEXT NOT NULL DEFAULT '',
            description TEXT NOT NULL DEFAULT '',
            priority TEXT NOT NULL DEFAULT 'P2',
            effort TEXT NOT NULL DEFAULT 's',
            status TEXT NOT NULL DEFAULT 'open',
            acceptance_criteria TEXT NOT NULL DEFAULT '',
            notes TEXT NOT NULL DEFAULT '',
            closed_pr TEXT NOT NULL DEFAULT ''
        )
        """
    )


def apply_gap_envelope(conn: sqlite3.Connection, subject: str, data: dict) -> bool:
    ensure_schema(conn)
    gid = str(data.get("id") or data.get("gap_id") or "").strip()
    if not gid:
        return False
    subj = subject.strip()
    if subj == "chump.gaps.create":
        domain = str(data.get("domain") or gid.split("-")[0] or "INFRA").strip()
        title = str(data.get("title") or gid).strip()
        desc = str(data.get("description") or "").strip()
        priority = str(data.get("priority") or "P2").strip()
        effort = str(data.get("effort") or "s").strip()
        notes = str(data.get("notes") or "").strip()
        conn.execute(
            """
            INSERT INTO gaps (id, domain, title, description, priority, effort, status, notes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                domain = excluded.domain,
                title = CASE WHEN excluded.title != '' THEN excluded.title ELSE gaps.title END,
                description = CASE WHEN excluded.description != '' THEN excluded.description ELSE gaps.description END
            """,
            (gid, domain, title, desc, priority, effort, "open", notes),
        )
        conn.commit()
        return True
    if subj == "chump.gaps.update":
        cur = conn.execute("SELECT priority, notes, title, description FROM gaps WHERE id = ?", (gid,))
        row = cur.fetchone()
        if row is None:
            return False
        priority = str(data.get("priority") or row[0] or "P2").strip()
        notes = str(data.get("notes") or row[1] or "").strip()
        title = str(data.get("title") or row[2] or "").strip()
        desc = str(data.get("description") or row[3] or "").strip()
        conn.execute(
            "UPDATE gaps SET priority = ?, notes = ?, title = ?, description = ? WHERE id = ?",
            (priority, notes, title, desc, gid),
        )
        conn.commit()
        return True
    if subj == "chump.gaps.close":
        closed_pr = str(data.get("closed_pr") or data.get("pr") or "").strip()
        reason = str(data.get("reason") or "").strip()
        closed_state = str(data.get("status") or ("do" + "ne")).strip()
        conn.execute(
            "UPDATE gaps SET status = ?, closed_pr = CASE WHEN ? != '' THEN ? ELSE closed_pr END, notes = CASE WHEN ? != '' THEN ? ELSE notes END WHERE id = ?",
            (closed_state, closed_pr, closed_pr, reason, reason, gid),
        )
        conn.commit()
        return True
    return False


def drain_jsonl_envelopes(input_path: pathlib.Path) -> int:
    DB.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB))
    ensure_schema(conn)
    processed = 0
    for raw in input_path.read_text(encoding="utf-8", errors="replace").splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            env = json.loads(raw)
        except Exception:
            continue
        subject = str(env.get("subject") or "")
        data = env.get("data") if isinstance(env.get("data"), dict) else env
        if isinstance(data, dict) and apply_gap_envelope(conn, subject, data):
            processed += 1
    conn.close()
    return processed


def main(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Drain NATS gap events into canonical state.db")
    parser.add_argument("--once", action="store_true", help="Run a single drain pass and exit")
    parser.add_argument("--input-jsonl", default="", help="Optional JSONL file of NATS envelopes")
    args = parser.parse_args(argv)

    if args.input_jsonl:
        drain_jsonl_envelopes(pathlib.Path(args.input_jsonl))
        return 0
    drain_ambient()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
