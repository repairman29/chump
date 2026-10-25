#!/usr/bin/env python3
"""ZERO-WASTE-125 rule registry + audit. Subcommands: generate | check | audit | prune."""
import argparse, glob, json, os, re, subprocess, sys, time
from datetime import datetime, timedelta, timezone

ROOT = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip() or "."
REG = os.path.join(ROOT, "docs/process/RULE_REGISTRY.tsv")
PROTECTED_RE = re.compile(r"never push|secret|proprietary|destructive|irreversible|escalat|no-operator", re.I)
KIND_RE = re.compile(r'"kind"\s*:\s*"([a-z0-9_]+)"|kind=([a-z0-9_]+)')


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:60]


def signal_for(path):
    try:
        text = open(os.path.join(ROOT, path), errors="ignore").read()
    except OSError:
        return "-"
    kinds = [a or b for a, b in KIND_RE.findall(text)]
    return kinds[0] if kinds else "-"


def gather():
    rows = []
    for doc in ("CLAUDE.md", "AGENTS.md"):
        p = os.path.join(ROOT, doc)
        if os.path.exists(p):
            for line in open(p, errors="ignore"):
                if line.startswith("## "):
                    h = line[3:].strip()
                    rows.append((f"doc:{doc}#{slug(h)}", "doc-rule", doc, "-", "protected" if PROTECTED_RE.search(h) else "-"))
    for kind, pats in (
        ("git-hook", ["scripts/git-hooks/*"]),
        ("workflow", [".github/workflows/*.yml"]),
        ("ci-gate", ["scripts/ci/test-*.sh", "scripts/ci/test-*.py"]),
    ):
        for pat in pats:
            for f in sorted(glob.glob(os.path.join(ROOT, pat))):
                rel = os.path.relpath(f, ROOT)
                if os.path.isdir(f) or rel.endswith("/lib"):
                    continue
                rows.append((f"{kind}:{rel}", kind, rel, signal_for(rel), "-"))
    src = os.path.join(ROOT, "src")
    if os.path.isdir(src):
        out = subprocess.run(["grep", "-rhoE", r"CHUMP_GAP_RESERVE_" + "NO_[A-Z_]+", src], capture_output=True, text=True).stdout
        for g in sorted(set(out.split())):
            short = g.lower().replace("chump_gap_reserve_", "").rstrip("_")
            rows.append((f"reserve-gate:{short}", "reserve-gate", "src/", "gap_reserve_bypass", "-"))
    return rows


def write_registry(rows):
    with open(REG, "w") as f:
        f.write("# id\tkind\tsource\tsignal\tprotected\n")
        for r in rows:
            f.write("\t".join(r) + "\n")


def read_registry():
    rows = []
    if os.path.exists(REG):
        for line in open(REG):
            if line.startswith("#") or not line.strip():
                continue
            rows.append(tuple(line.rstrip("\n").split("\t")))
    return rows


def cmd_check():
    have = {r[0] for r in read_registry()}
    missing = [r[0] for r in gather() if r[0] not in have and r[1] != "doc-rule"]
    if missing:
        print(f"FAIL: {len(missing)} gate(s) missing from docs/process/RULE_REGISTRY.tsv:")
        for m in missing[:20]:
            print("  " + m)
        print("Fix: python3 scripts/ops/rules-registry.py generate")
        return 1
    print(f"ok: all {len(have)} registered")
    return 0


def parse_window(w):
    m = re.fullmatch(r"(\d+)([dh])", w)
    if not m:
        sys.exit("bad --window (use 30d / 12h)")
    n = int(m.group(1))
    return timedelta(days=n) if m.group(2) == "d" else timedelta(hours=n)


def audit(window):
    cutoff = datetime.now(timezone.utc) - parse_window(window)
    path = os.environ.get("CHUMP_AMBIENT", os.path.expanduser("~/.chump/ambient.jsonl"))
    if not os.path.exists(path):
        path = os.path.join(ROOT, ".chump-locks/ambient.jsonl")
    fires, bypass = {}, {}
    if os.path.exists(path):
        for line in open(path, errors="ignore"):
            try:
                e = json.loads(line)
                ts = datetime.fromisoformat(e["ts"].replace("Z", "+00:00"))
            except Exception:
                continue
            if ts < cutoff:
                continue
            k = e.get("kind", "")
            if "bypass" in k:
                blob = line
                for r in read_registry():
                    base = os.path.basename(r[2])
                    if base and base in blob:
                        bypass[r[0]] = bypass.get(r[0], 0) + 1
            fires[k] = fires.get(k, 0) + 1
    out = []
    for rid, kind, src, sig, prot in read_registry():
        f = fires.get(sig, 0) if sig != "-" else None
        b = bypass.get(rid, 0)
        catches = None if f is None else max(f - b, 0)
        fp = None if not f else round(b / f, 2)
        cand = None
        if prot != "protected" and kind != "workflow":
            if f is None:
                cand = "unmeasured (no firing signal)"
            elif f == 0:
                cand = "0 fires in window"
            elif fp is not None and fp > 0.5:
                cand = f"bypass/false-positive rate {fp}"
        out.append(dict(id=rid, kind=kind, fires=f, bypasses=b, catches=catches, fp_rate=fp, cost="n/a", protected=prot == "protected", candidate=cand))
    return out


def cmd_audit(a):
    rows = audit(a.window)
    cands = [r for r in rows if r["candidate"]]
    rank = lambda r: (r["candidate"].startswith("unmeasured"), -(r["bypasses"]))
    cands.sort(key=rank)
    if a.json:
        print(json.dumps(dict(window=a.window, rules=rows, delete_candidates=cands), indent=1))
        return 0
    print(f"rules audit window={a.window}: {len(rows)} rules, {len(cands)} delete candidates, {sum(r['protected'] for r in rows)} protected")
    print("id\tfires\tcatches\tbypasses\tfp\tcost")
    for r in rows:
        if r["fires"] or r["bypasses"]:
            print(f"{r['id']}\t{r['fires']}\t{r['catches']}\t{r['bypasses']}\t{r['fp_rate']}\t{r['cost']}")
    print("\nDelete candidates (ranked):")
    for r in cands[: a.top]:
        print(f"  {r['id']}  <- {r['candidate']}")
    return 0


def cmd_prune(a):
    cands = [r for r in audit(a.window) if r["candidate"] and not r["protected"]][: a.batch]
    if not cands:
        print("no delete candidates")
        return 0
    body = "PRUNE batch (keep requires +1 citing a real catch): " + "; ".join(f"{c['id']} ({c['candidate']})" for c in cands)
    if a.dry_run:
        print(body)
        return 0
    corr = "rule-prune-" + time.strftime("%Y%m%d", time.gmtime())
    subprocess.run([os.path.join(ROOT, "scripts/coord/broadcast.sh"), "FEEDBACK", f"kind=proposal corr_id={corr} {body}"])
    amb = os.path.join(ROOT, ".chump-locks/ambient.jsonl")
    passed = False
    if os.path.exists(amb):
        passed = any(corr in l and "consensus_result" in l and "PASSED" in l for l in open(amb, errors="ignore"))
    if passed:
        subprocess.run(["chump", "gap", "reserve", "--domain", "ZERO-WASTE", "--priority", "P2",
                        "--title", f"ZERO-WASTE: delete pruned rules ({corr}) — rule + gate + doc text in one PR",
                        "--description", body])
    return 0


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("generate")
    sp.add_parser("check")
    for n in ("audit", "prune"):
        p = sp.add_parser(n)
        p.add_argument("--window", default="30d")
        p.add_argument("--json", action="store_true")
        p.add_argument("--top", type=int, default=30)
        p.add_argument("--batch", type=int, default=10)
        p.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if a.cmd == "generate":
        rows = gather()
        write_registry(rows)
        print(f"wrote {len(rows)} rules to {os.path.relpath(REG, ROOT)}")
        return 0
    return {"check": lambda: cmd_check(), "audit": lambda: cmd_audit(a), "prune": lambda: cmd_prune(a)}[a.cmd]()


if __name__ == "__main__":
    sys.exit(main())
