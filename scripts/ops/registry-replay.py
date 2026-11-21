#!/usr/bin/env python3
"""CREDIBLE-1700: replay the registry delta lost with cuphead onto the hub state.db.

  registry-replay.py --db STATE_DB [--artifact approvals.json] [--prs prs.json]
                     [--quarantine ID ...] [--dry-run]

artifact: {"outcomes":[{"id","title"}], "proposals":[{"title","description",
  "acceptance_criteria":[...],"outcome","external_repo","domain","spine"}],
  "p1":[{"id","title","outcome"}]}
prs: `gh pr list --json number,title,state,mergedAt,updatedAt` output.
Idempotent; every inserted row carries notes=replayed-from:<source>.
"""
import argparse, json, re, sqlite3, sys, time

DEFAULT_OUTCOMES = ["FROOGLE", "UPSHIFT", "UPSHIFT-CLI", "OLIVE", "HELIX",
                    "JEFFADKINS-DEV", "WHEREWITHAL", "POSSE", "HOLLER", "ALMANAC"]
ID_RE = re.compile(r"^\s*\[?([A-Z][A-Z0-9]*)-(\d+)\b")


def counter_bump(db, domain, num):
    db.execute("INSERT INTO gap_counters(domain,next_num) VALUES(?,?) "
               "ON CONFLICT(domain) DO UPDATE SET next_num=MAX(next_num,excluded.next_num)",
               (domain, num + 1))


def insert_gap(db, gid, title, status, source, **kw):
    if db.execute("SELECT 1 FROM gaps WHERE id=?", (gid,)).fetchone():
        return False
    now = int(time.time())
    iso = time.strftime("%Y-%m-%d", time.gmtime(now))
    db.execute(
        "INSERT INTO gaps(id,domain,title,description,priority,effort,status,"
        "acceptance_criteria,notes,created_at,opened_date,closed_at,closed_date,"
        "closed_pr,skills_required,outcome_id) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (gid, gid.rsplit("-", 1)[0], title, kw.get("description", ""),
         kw.get("priority", "P2"), kw.get("effort", ""), status,
         json.dumps(kw.get("ac", [])), "replayed-from:" + source, now, iso,
         now if status == "done" else None, iso if status == "done" else "",
         kw.get("closed_pr"), kw.get("skills", ""), kw.get("outcome")))
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--artifact")
    ap.add_argument("--prs")
    ap.add_argument("--quarantine", nargs="*", default=[])
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    db = sqlite3.connect(a.db)
    quarantined = set(a.quarantine)
    n = {"outcomes": 0, "proposals": 0, "pr_gaps": 0, "p1": 0}
    art = json.load(open(a.artifact)) if a.artifact else {}

    titles = {o["id"]: o.get("title", o["id"]) for o in art.get("outcomes", [])}
    for oid in DEFAULT_OUTCOMES:
        titles.setdefault(oid, oid)
    for oid, t in titles.items():
        if not db.execute("SELECT 1 FROM outcomes WHERE id=?", (oid,)).fetchone():
            db.execute("INSERT INTO outcomes(id,title,priority,definition_of_done,status,created_at) "
                       "VALUES(?,?,?,?,?,?)", (oid, t, "P2", "replayed-from:approvals-artifact", "open", int(time.time())))
            n["outcomes"] += 1

    # PR replay first so counters/ids are known before minting proposals.
    max_seen = {}
    for pr in json.load(open(a.prs)) if a.prs else []:
        m = ID_RE.match(pr.get("title", ""))
        if not m:
            continue
        dom, num = m.group(1), int(m.group(2))
        gid = f"{dom}-{num}"
        if gid in quarantined:
            continue
        max_seen[dom] = max(max_seen.get(dom, 0), num)
        state = pr.get("state", "").upper()
        if state == "MERGED":
            status = "done"
        elif state == "OPEN":
            status = "in_flight"
        else:
            continue
        title = pr["title"].split(":", 1)[-1].strip() or pr["title"]
        if insert_gap(db, gid, title, status, "pr-title", closed_pr=pr.get("number") if status == "done" else None):
            n["pr_gaps"] += 1
        elif status == "done":
            db.execute("UPDATE gaps SET status='done', closed_pr=COALESCE(closed_pr,?), "
                       "closed_date=CASE WHEN closed_date='' THEN date('now') ELSE closed_date END "
                       "WHERE id=? AND status IN ('open','in_flight','in_progress')", (pr.get("number"), gid))
    for dom, num in max_seen.items():
        counter_bump(db, dom, num)

    for p in art.get("proposals", []):
        dom = p.get("domain", "PRODUCT")
        row = db.execute("SELECT next_num FROM gap_counters WHERE domain=?", (dom,)).fetchone()
        num = row[0] if row else 1
        gid = p.get("id") or f"{dom}-{num}"
        if db.execute("SELECT 1 FROM gaps WHERE id=?", (gid,)).fetchone() or \
           db.execute("SELECT 1 FROM gaps WHERE title=? AND outcome_id IS ?", (p["title"], p.get("outcome"))).fetchone():
            continue
        skills = f"external_repo:{p['external_repo']}" if p.get("external_repo") else ""
        insert_gap(db, gid, p["title"], "open", "approvals-artifact",
                   description=p.get("description", ""), ac=p.get("acceptance_criteria", []),
                   priority="P1" if p.get("spine") else "P2", outcome=p.get("outcome"), skills=skills)
        counter_bump(db, dom, int(gid.rsplit("-", 1)[1]))
        n["proposals"] += 1

    for p in art.get("p1", []):
        gid = p["id"]
        insert_gap(db, gid, p.get("title", gid), "open", "memory", priority="P1", outcome=p.get("outcome"))
        db.execute("UPDATE gaps SET priority='P1', outcome_id=COALESCE(?,outcome_id) WHERE id=?",
                   (p.get("outcome"), gid))
        m = ID_RE.match(gid)
        counter_bump(db, m.group(1), int(m.group(2)))
        n["p1"] += 1

    if a.dry_run:
        db.rollback()
    else:
        db.commit()
    replayed = db.execute("SELECT COUNT(*) FROM gaps WHERE notes LIKE 'replayed-from:%'").fetchone()[0]
    print(f"replayed rows this run: outcomes={n['outcomes']} proposals={n['proposals']} "
          f"pr_gaps={n['pr_gaps']} p1={n['p1']}; total notes=replayed-from:* rows: {replayed}")
    if quarantined:
        print("quarantined (not imported): " + ", ".join(sorted(quarantined)))


if __name__ == "__main__":
    sys.exit(main())
