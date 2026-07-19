#!/usr/bin/env bash
# build-hidden-gems.sh — INFRA-1727
#
# Auto-populates docs/HIDDEN_GEMS.md from repo sources, merging the operator's
# hand-curated overlay (docs/HIDDEN_GEMS_CURATED.yaml) on top.
#
# Sources mined:
#   - scripts/README.md          (CLI / dev / dispatch script catalog)
#   - chump-mcp.json             (MCP server descriptions)
#   - scripts/ci/event-registry-reserved.txt  (ambient event kinds)
#
# Output: <repo-root>/docs/HIDDEN_GEMS.md (idempotent — same inputs => same output)
# Emits: kind=hidden_gems_refreshed with delta_count to .chump-locks/ambient.jsonl
#
# Usage:
#   bash scripts/dev/build-hidden-gems.sh                     — regenerate doc + emit event
#   bash scripts/dev/build-hidden-gems.sh --check              — exit non-zero if regenerate would change doc
#   bash scripts/dev/build-hidden-gems.sh [--repo-root PATH] [--out PATH] [--check]
#
# --repo-root lets this run against an arbitrary target repo (the Column A
# `chump ingest` Phase 3 Evangelist artifact) — used by
# scripts/ops/generate-hidden-gems.sh. Defaults to the current git toplevel.

set -euo pipefail

REPO_ROOT_DEFAULT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
REPO_ROOT="$REPO_ROOT_DEFAULT"
OUT_OVERRIDE=""
MODE="build"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root) REPO_ROOT="$2"; shift 2 ;;
        --out)       OUT_OVERRIDE="$2"; shift 2 ;;
        --check)     MODE="--check"; shift ;;
        -h|--help)
            sed -n '2,20p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "unknown arg: $1" >&2
            exit 2
            ;;
    esac
done

REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
export CHUMP_HIDDEN_GEMS_REPO_ROOT="$REPO_ROOT"
export CHUMP_HIDDEN_GEMS_OUT="${OUT_OVERRIDE:-$REPO_ROOT/docs/HIDDEN_GEMS.md}"
export CHUMP_HIDDEN_GEMS_MODE="$MODE"
export CHUMP_HIDDEN_GEMS_AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT_DEFAULT/.chump-locks/ambient.jsonl}"

cd "$REPO_ROOT"

# Single-quoted heredoc → NO shell expansion inside. All variables come via env.
python3 <<'PYEOF'
import datetime, json, os, re, sys
from pathlib import Path

REPO = Path(os.environ["CHUMP_HIDDEN_GEMS_REPO_ROOT"])
MODE = os.environ["CHUMP_HIDDEN_GEMS_MODE"]
AMBIENT = Path(os.environ["CHUMP_HIDDEN_GEMS_AMBIENT"])
OUT = Path(os.environ["CHUMP_HIDDEN_GEMS_OUT"])
CURATED = REPO / "docs" / "HIDDEN_GEMS_CURATED.yaml"

# ── Load curated overlay ────────────────────────────────────────────────────
curated = {"cli": [], "mcp": [], "env": [], "hidden": []}
if CURATED.exists():
    try:
        import yaml
        loaded = yaml.safe_load(CURATED.read_text()) or {}
        for section in curated:
            curated[section] = loaded.get(section, []) or []
    except ImportError:
        # Minimal fallback parser for the known shape.
        section = None
        cur_entry = None
        with open(CURATED) as f:
            for line in f:
                m = re.match(r"^([a-z]+):\s*(\[\])?\s*$", line)
                if m:
                    if cur_entry and section in curated:
                        curated[section].append(cur_entry)
                        cur_entry = None
                    section = m.group(1)
                    if section not in curated:
                        curated[section] = []
                    continue
                if line.startswith("  - name:"):
                    if cur_entry and section in curated:
                        curated[section].append(cur_entry)
                    cur_entry = {"name": line.split(":", 1)[1].strip()}
                elif line.startswith("    ") and ":" in line and cur_entry is not None:
                    k, v = line.strip().split(":", 1)
                    cur_entry[k.strip()] = v.strip()
            if cur_entry and section in curated:
                curated[section].append(cur_entry)

# ── Auto-detect baseline ─────────────────────────────────────────────────────
baseline = {"cli": [], "mcp": [], "env": [], "hidden": []}

mcp_path = REPO / "chump-mcp.json"
if mcp_path.exists():
    try:
        mcp = json.loads(mcp_path.read_text())
        for name, conf in (mcp.get("mcpServers") or {}).items():
            desc = conf.get("description") or conf.get("command", "")
            baseline["mcp"].append({
                "name": name,
                "where_to_find": "chump-mcp.json",
                "when_to_use": (desc or "MCP server: " + name)[:120],
                "example_command": "claude --mcp-config chump-mcp.json  # registers " + name,
            })
    except Exception as e:
        print("[build-hidden-gems] warn: could not parse chump-mcp.json: " + str(e), file=sys.stderr)

reg_path = REPO / "scripts" / "ci" / "event-registry-reserved.txt"
if reg_path.exists():
    for line in reg_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("#", 1)
        kind = parts[0].strip()
        reason = parts[1].strip() if len(parts) > 1 else ""
        if not kind:
            continue
        baseline["hidden"].append({
            "name": "ambient kind=" + kind,
            "where_to_find": "scripts/ci/event-registry-reserved.txt",
            "when_to_use": (reason[:140] if reason else "Ambient event kind emitted by the fleet for observability"),
            "example_command": "grep '\"kind\":\"" + kind + "\"' .chump-locks/ambient.jsonl",
        })

readme_path = REPO / "scripts" / "README.md"
if readme_path.exists():
    text = readme_path.read_text()
    seen = set()
    for m in re.finditer(r"(scripts/(?:dev|dispatch|coord|ops)/[a-z0-9_\-]+\.sh)", text):
        path = m.group(1)
        if path in seen:
            continue
        seen.add(path)
        full = REPO / path
        if not full.exists():
            continue
        name = path.rsplit("/", 1)[-1]
        baseline["cli"].append({
            "name": path,
            "where_to_find": path,
            "when_to_use": "See scripts/README.md for details on " + name,
            "example_command": "bash " + path + " --help 2>&1 | head -20",
        })

# ── Merge curated on top of baseline (curated wins on (section, name)) ──────
merged = {section: [] for section in baseline}
for section in merged:
    cur_names = set(e.get("name") for e in curated[section])
    merged[section].extend(curated[section])
    for e in baseline[section]:
        if e.get("name") not in cur_names:
            merged[section].append(e)

# ── Render markdown ──────────────────────────────────────────────────────────
SECTION_TITLES = {
    "cli": "CLI commands",
    "mcp": "Agent tools (MCP)",
    "env": "Config knobs (env vars)",
    "hidden": "Hidden features (workflow tricks)",
}

lines = []
lines.append("# Chump — Hidden Gems")
lines.append("")
lines.append("> Auto-generated curated showcase of valuable primitives that new users miss.")
lines.append("> Content source for Evangelist bot (META-066). Pair with docs/PITCH.md for the")
lines.append("> why-Chump narrative; this is the how-Chump payload.")
lines.append("")
lines.append("> Build: `bash scripts/dev/build-hidden-gems.sh`. Operator overlay lives in")
lines.append("> `docs/HIDDEN_GEMS_CURATED.yaml`; curated entries land first in each section.")
lines.append("")
for section in ("cli", "mcp", "env", "hidden"):
    entries = merged.get(section, [])
    lines.append("## " + SECTION_TITLES[section])
    lines.append("")
    if not entries:
        lines.append("_No entries yet — add to `docs/HIDDEN_GEMS_CURATED.yaml`._")
        lines.append("")
        continue
    for e in entries:
        name = e.get("name", "?")
        where = e.get("where_to_find", "?")
        when = e.get("when_to_use", "?")
        example = e.get("example_command", "?")
        lines.append("### `" + name + "`")
        lines.append("")
        lines.append("- **Where:** `" + where + "`")
        lines.append("- **When to use:** " + when)
        lines.append("- **Example:**")
        lines.append("")
        lines.append("  ```bash")
        lines.append("  " + example)
        lines.append("  ```")
        lines.append("")
lines.append("---")
lines.append("")
lines.append("_Last refreshed: " + datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d") + "_")
lines.append("")
new_md = "\n".join(lines) + "\n"

old_md = OUT.read_text() if OUT.exists() else ""
delta = 0 if new_md == old_md else 1

if MODE == "--check":
    if delta:
        print("[build-hidden-gems] would regenerate " + str(OUT) + " (content drift)", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(new_md)
total = sum(len(merged[s]) for s in merged)
print("[build-hidden-gems] wrote " + str(OUT) + " (" + str(total) + " entries; delta=" + str(delta) + ")")

# Emit hidden_gems_refreshed (python-direct write — registered in event-registry-reserved.txt)
try:
    AMBIENT.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "kind": "hidden_gems_refreshed",
        "repo": REPO.name,
        "delta_count": delta,
        "total_entries": total,
        "script": "build-hidden-gems.sh",
    }
    with open(AMBIENT, "a") as f:
        f.write(json.dumps(payload) + "\n")
except Exception as e:
    print("[build-hidden-gems] warn: could not emit ambient event: " + str(e), file=sys.stderr)
PYEOF
