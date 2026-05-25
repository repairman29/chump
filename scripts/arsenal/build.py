#!/usr/bin/env python3
"""Build GLOBAL_ARSENAL.json — Harvester's fleet catalog.

Reads:
  - docs/arsenal/raw/github_repos.json  (output of `gh repo list --json ...`)
  - ~/Projects/                          (local clones)

Writes:
  - docs/arsenal/GLOBAL_ARSENAL.json     (machine view)
  - docs/arsenal/GLOBAL_ARSENAL.md       (human view)

Reruns are cheap and idempotent — call before any cross-pollination brief.
"""
from __future__ import annotations

import datetime as _dt
import json
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ARSENAL = ROOT / "docs" / "arsenal"
RAW = ARSENAL / "raw" / "github_repos.json"
HOME = Path(os.path.expanduser("~"))
PROJECTS = HOME / "Projects"

# Cluster heuristics — name/description patterns → cluster label
CLUSTERS = [
    ("chump-engine",      r"^chump$|^chump-|^homebrew-chump$"),
    ("echeo-resonant",    r"^echeo"),
    ("jarvis-assistant",  r"^jarvis|^JARVIS"),
    ("beast-mode-qi",     r"^beast-mode|^BEAST-MODE"),
    ("smugglers-rpg",     r"^smuggler|smugglers|^MythSeeker|^mythseeker|^ai-gm-|^auth-platform|^combat-system|^character-system|^mission-engine|^chat-platform|^payment-platform|^economy-system|^marketplace-system|^code-generation|^asset-management|^audio-generation|^analytics-platform|^commercial-platform|^mock-services|^service-frontends|^services-dashboard|^bot-simulation|^internal-zendesk|^zendesk-background"),
    ("upshift-deps",      r"^upshift$"),
    ("content-apps",      r"^slidemate|^mixdown|^coloringbook|^postsub|^echeovid|^olive|^pvc|^dice|^berry-avenue|^sheckleshare|^biomeweavers|^messaging-demo|^trove"),
    ("political-strat",   r"^project2029|^2029|^ims$"),
    ("tools-platform",    r"^daisy-chain|^code-roach|^coderoach|^oracle|^neural-farm|^slides|^workbench|^pixel-edge|^openclaw"),
    ("marketing-sites",   r"^acg|^repairman29-website|^beast-mode-website|^echeo-web|^echeo-internal"),
    ("misc",              r".*"),
]

PRIMITIVE_PATTERNS = {
    "auth":          r"auth|oauth|login|jwt|session",
    "payment":       r"payment|stripe|billing|checkout|monetiz",
    "chat":          r"chat|messaging|discord|message",
    "ai-generation": r"ai-gm|code-generation|audio-generation|content-generation|llm|inferr|neural-farm",
    "ci-cd":         r"vercel|railway|github.*actions|cargo-dist|homebrew-chump",
    "marketplace":   r"marketplace|economy",
    "calendar":      r"calendar|scheduler|cron",
    "list-mgmt":     r"olive|trove|sheckleshare",
    "video":         r"echeovid|video",
    "rpg-mechanic":  r"mythseeker|smuggler|combat|character|mission",
}


def assign_cluster(name: str) -> str:
    for label, pat in CLUSTERS:
        if re.search(pat, name, re.IGNORECASE):
            return label
    return "misc"


def detect_primitives(name: str, desc: str) -> list[str]:
    blob = f"{name} {desc or ''}".lower()
    return [p for p, pat in PRIMITIVE_PATTERNS.items() if re.search(pat, blob)]


_LOCAL_CACHE: dict[str, str] | None = None


def _build_local_cache() -> dict[str, str]:
    """Map normalized-remote-repo-name → local path, scanning ~/Projects/ once."""
    global _LOCAL_CACHE
    if _LOCAL_CACHE is not None:
        return _LOCAL_CACHE
    cache: dict[str, str] = {}
    try:
        out = subprocess.check_output(
            ["find", str(PROJECTS), "-maxdepth", "4", "-name", ".git", "-type", "d"],
            stderr=subprocess.DEVNULL,
        ).decode()
    except subprocess.CalledProcessError:
        out = ""
    for line in out.splitlines():
        if "/node_modules/" in line or "/target/" in line or "/.venv/" in line:
            continue
        repo_root = str(Path(line).parent)
        cfg = Path(line) / "config"
        if not cfg.exists():
            continue
        m = re.search(r"github\.com[:/]([^/]+)/([^.\s]+?)(?:\.git)?[\s\"]", cfg.read_text(errors="ignore") + "\n")
        if not m:
            continue
        repo_name = m.group(2).lower()
        # Prefer top-level (~/Projects/<X>) clones over nested ones for the canonical local_clone
        if repo_name not in cache or repo_root.count("/") < cache[repo_name].count("/"):
            cache[repo_name] = repo_root
    _LOCAL_CACHE = cache
    return cache


def local_clone_for(name: str) -> dict | None:
    """Look for a local clone of this GH repo, by remote URL (handles case mismatch + dir-renames)."""
    cache = _build_local_cache()
    path = cache.get(name.lower())
    if not path:
        return None
    dir_name = Path(path).name
    return {
        "path": path,
        "dir_name_matches_repo": dir_name.lower() == name.lower(),
        "actual_dir_name": dir_name,
        "nested_in_chump": "/Projects/Chump/" in path,
    }


def scan_all_local_roots(known_paths: set[str]) -> list[dict]:
    """Return every local git root with redacted remote + flags. known_paths suppresses dupes."""
    found = []
    try:
        out = subprocess.check_output(
            ["find", str(PROJECTS), "-maxdepth", "4", "-name", ".git", "-type", "d"],
            stderr=subprocess.DEVNULL,
        ).decode()
    except subprocess.CalledProcessError:
        return found
    for line in out.splitlines():
        if "/node_modules/" in line or "/target/" in line or "/.venv/" in line:
            continue
        repo = str(Path(line).parent)
        cfg = Path(line) / "config"
        raw_remote = ""
        if cfg.exists():
            m = re.search(r"url\s*=\s*(\S+)", cfg.read_text(errors="ignore"))
            if m:
                raw_remote = m.group(1)
        has_token = bool(re.search(r"x-access-token:[A-Za-z0-9_]+@", raw_remote))
        remote_clean = re.sub(r"x-access-token:[^@]+@", "x-access-token:<REDACTED>@", raw_remote)
        found.append({
            "path": repo,
            "remote": remote_clean,
            "has_embedded_token": has_token,
            "is_primary_clone": repo in known_paths,
        })
    return found


def find_duplications(repos: list[dict]) -> list[dict]:
    """Find name-similar repos that may be duplicates."""
    dups = []
    # Echeo cluster
    echeo = [r["name"] for r in repos if re.match(r"^echeo", r["name"], re.IGNORECASE)]
    if len(echeo) > 1:
        dups.append({
            "pattern": "echeo-*",
            "variants": echeo,
            "recommendation": "consolidate to one active variant + archive the rest; pick the most recently pushed as primary",
        })
    # MythSeeker
    myth = [r["name"] for r in repos if re.search(r"mythseeker", r["name"], re.IGNORECASE)]
    if len(myth) > 1:
        dups.append({"pattern": "mythseeker-*", "variants": myth, "recommendation": "v1 vs v2 — pick survivor, archive other"})
    # Smugglers
    smug = [r["name"] for r in repos if re.search(r"^smuggler", r["name"], re.IGNORECASE)]
    if len(smug) > 1:
        dups.append({"pattern": "smuggler-*", "variants": smug, "recommendation": "core vs full — clarify which is the active engine"})
    # code-roach / coderoach
    cr = [r["name"] for r in repos if re.search(r"code-?roach", r["name"], re.IGNORECASE)]
    if len(cr) > 1:
        dups.append({"pattern": "coderoach/code-roach", "variants": cr, "recommendation": "rename collision — one is archived; archive the other or merge"})
    # project-forge / project_forge
    pf = [r["name"] for r in repos if re.search(r"project[-_]forge", r["name"], re.IGNORECASE)]
    if len(pf) > 1:
        dups.append({"pattern": "project[-_]forge", "variants": pf, "recommendation": "underscore vs hyphen — both archived; collapse"})
    # 2029 family
    yr = [r["name"] for r in repos if re.search(r"2029", r["name"], re.IGNORECASE)]
    if len(yr) > 1:
        dups.append({"pattern": "2029-*", "variants": yr, "recommendation": "three repos for one initiative — pick one canonical"})
    # JARVIS family
    jv = [r["name"] for r in repos if re.search(r"jarvis", r["name"], re.IGNORECASE)]
    if len(jv) > 1:
        dups.append({"pattern": "jarvis-*", "variants": jv, "recommendation": "platform variants (ROG Ally, Android, gateway, premium) — confirm intentional vs accidental fork"})
    return dups


def find_alerts(repos: list[dict], local_roots: list[dict]) -> list[dict]:
    alerts = []
    # Embedded token check
    leak_paths = [l["path"] for l in local_roots if l["has_embedded_token"]]
    if leak_paths:
        alerts.append({
            "severity": "high",
            "kind": "embedded_github_token",
            "paths": leak_paths,
            "action": "rotate the PAT at github.com/settings/tokens, then re-clone with ssh remote",
        })
    # Misplaced Projects/.git
    if (PROJECTS / ".git").is_dir():
        cfg = PROJECTS / ".git" / "config"
        remote = ""
        if cfg.exists():
            m = re.search(r"url\s*=\s*(\S+)", cfg.read_text(errors="ignore"))
            if m:
                remote = m.group(1)
        alerts.append({
            "severity": "low",
            "kind": "misplaced_clone",
            "path": str(PROJECTS),
            "remote": remote,
            "action": "Projects/ shouldn't itself be a git repo — likely an errant `git clone` at the wrong level. Move .git/ into the intended subdir or rm.",
        })
    # Stale vendored chump clones
    maclawd_chump = PROJECTS / "Maclawd" / "chump-repo"
    if maclawd_chump.exists():
        alerts.append({
            "severity": "medium",
            "kind": "stale_vendored_clone",
            "path": str(maclawd_chump),
            "action": "Maclawd contains a March 2026 clone of chump — Smart Harvest target: convert to git-submodule or Cargo dependency",
        })
    return alerts


def build():
    raw = json.loads(RAW.read_text())
    repos = []
    for r in raw:
        clone = local_clone_for(r["name"])
        repos.append({
            "name": r["name"],
            "visibility": r["visibility"],
            "language": (r.get("primaryLanguage") or {}).get("name"),
            "description": r.get("description") or "",
            "archived": r.get("isArchived", False),
            "fork": r.get("isFork", False),
            "pushed_at": r.get("pushedAt"),
            "url": r.get("url"),
            "disk_kb": r.get("diskUsage"),
            "topics": [t.get("name") for t in (r.get("repositoryTopics") or []) if t],
            "cluster": assign_cluster(r["name"]),
            "primitives": detect_primitives(r["name"], r.get("description") or ""),
            "local_clone": clone,
        })

    known_paths = {r["local_clone"]["path"] for r in repos if r["local_clone"]}
    local_roots = scan_all_local_roots(known_paths)
    unmatched_roots = [l for l in local_roots if not l["is_primary_clone"]]

    out = {
        "metadata": {
            "generated_at": _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "generator": "scripts/arsenal/build.py v0",
            "operator": "repairman29 (Jeff Adkins)",
            "fleet_size_github": len(repos),
            "fleet_size_local_clones": sum(1 for r in repos if r["local_clone"]),
            "fleet_size_unmatched_local_roots": len(unmatched_roots),
        },
        "clusters": {},
        "duplications": find_duplications(repos),
        "alerts": find_alerts(repos, local_roots),
        "primitives_index": {},
        "repos_by_name": {r["name"]: r for r in repos},
        "unmatched_local_roots": unmatched_roots,
    }

    # Cluster summaries
    for r in repos:
        c = r["cluster"]
        out["clusters"].setdefault(c, {"count": 0, "repos": [], "languages": {}, "active_last_30d": 0})
        out["clusters"][c]["count"] += 1
        out["clusters"][c]["repos"].append(r["name"])
        lang = r["language"] or "?"
        out["clusters"][c]["languages"][lang] = out["clusters"][c]["languages"].get(lang, 0) + 1
        if r["pushed_at"] and r["pushed_at"] >= (_dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(days=30)).strftime("%Y-%m-%d"):
            out["clusters"][c]["active_last_30d"] += 1

    # Primitives index — repos by primitive label
    for r in repos:
        for p in r["primitives"]:
            out["primitives_index"].setdefault(p, []).append(r["name"])

    (ARSENAL / "GLOBAL_ARSENAL.json").write_text(json.dumps(out, indent=2, sort_keys=False) + "\n")

    # Human view
    md = render_md(out)
    (ARSENAL / "GLOBAL_ARSENAL.md").write_text(md)

    print(f"wrote {ARSENAL / 'GLOBAL_ARSENAL.json'}")
    print(f"wrote {ARSENAL / 'GLOBAL_ARSENAL.md'}")
    print(f"fleet_size: {out['metadata']['fleet_size_github']} GH repos, {out['metadata']['fleet_size_local_clones']} cloned locally")
    print(f"clusters: {len(out['clusters'])}, duplications: {len(out['duplications'])}, alerts: {len(out['alerts'])}")


def render_md(out: dict) -> str:
    lines = []
    m = out["metadata"]
    lines.append("# Global Arsenal — Chump Fleet Codex\n")
    lines.append(f"_Generated {m['generated_at']} by {m['generator']}_\n")
    lines.append(f"**Operator:** {m['operator']}")
    lines.append(f"**GitHub repos:** {m['fleet_size_github']}  ")
    lines.append(f"**Cloned locally:** {m['fleet_size_local_clones']}  ")
    lines.append(f"**Unmatched local roots:** {m['fleet_size_unmatched_local_roots']}\n")

    if out["alerts"]:
        lines.append("## 🚨 Alerts\n")
        for a in out["alerts"]:
            lines.append(f"- **[{a['severity']}] {a['kind']}** — {a.get('action','')}")
            if "paths" in a:
                for p in a["paths"]:
                    lines.append(f"  - `{p}`")
            elif "path" in a:
                lines.append(f"  - `{a['path']}`")
        lines.append("")

    lines.append("## Clusters\n")
    lines.append("| Cluster | Count | Active (30d) | Languages |")
    lines.append("|---|---:|---:|---|")
    for c, info in sorted(out["clusters"].items(), key=lambda kv: -kv[1]["count"]):
        langs = ", ".join(f"{l}:{n}" for l, n in sorted(info["languages"].items(), key=lambda kv: -kv[1]))
        lines.append(f"| `{c}` | {info['count']} | {info['active_last_30d']} | {langs} |")
    lines.append("")

    lines.append("## Duplication Findings (DRY violations)\n")
    for d in out["duplications"]:
        lines.append(f"### `{d['pattern']}`")
        lines.append(f"**Variants:** {', '.join(d['variants'])}  ")
        lines.append(f"**Recommendation:** {d['recommendation']}\n")

    lines.append("## Primitives Index (Smart-Harvest source candidates)\n")
    for p, names in sorted(out["primitives_index"].items()):
        lines.append(f"- **{p}** → {', '.join(names)}")
    lines.append("")

    lines.append("## Cluster Deep-Dives\n")
    for c, info in sorted(out["clusters"].items(), key=lambda kv: -kv[1]["count"]):
        lines.append(f"### {c}")
        for name in info["repos"]:
            r = out["repos_by_name"][name]
            badge = []
            if r["archived"]: badge.append("ARCHIVED")
            if r["fork"]:     badge.append("FORK")
            if r["visibility"] == "PUBLIC": badge.append("PUBLIC")
            badge_str = " · ".join(badge) + " · " if badge else ""
            local = ""
            if r["local_clone"]:
                lc = r["local_clone"]
                rename_tag = "" if lc["dir_name_matches_repo"] else f" (dir renamed → `{lc['actual_dir_name']}`)"
                nested_tag = " [nested-in-Chump]" if lc["nested_in_chump"] else ""
                local = f" 📁 `{lc['path']}`{rename_tag}{nested_tag}"
            lines.append(f"- **{name}** [{r['language'] or '?'}] {badge_str}{r['description']}{local}")
        lines.append("")

    lines.append("## Unmatched Local Git Roots (no GitHub origin / third-party / accidental)\n")
    for l in out["unmatched_local_roots"]:
        tag = " 🚨EMBEDDED_TOKEN" if l["has_embedded_token"] else ""
        lines.append(f"- `{l['path']}` → {l['remote'] or '(no remote)'}{tag}")
    lines.append("")
    return "\n".join(lines)


if __name__ == "__main__":
    build()
