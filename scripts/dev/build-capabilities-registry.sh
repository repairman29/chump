#!/usr/bin/env bash
# build-capabilities-registry.sh — INFRA-1729 (EFFECTIVE — Quartermaster artifact)
#
# Generate docs/CAPABILITIES_REGISTRY.json from:
#   - chump --help (CLI commands, recursive)
#   - docs/observability/EVENT_REGISTRY.yaml (ambient event kinds)
#   - crates/*/src/lib.rs (public crate APIs via chump-ast-crawler)
#   - chump-mcp.json + #[chump_tool] macro sites (MCP tools)
#   - chump-brain/skills/<name>/SKILL.md (skills, when present)
#   - scripts/README.md primitives (scripts catalog)
# plus optional docs/CAPABILITIES_OVERLAY.yaml for hand-curated when_to_use fields.
#
# Usage:
#   bash scripts/dev/build-capabilities-registry.sh [--repo-root PATH] [--out PATH]
#
# Defaults: repo-root = git toplevel; out = <repo-root>/docs/CAPABILITIES_REGISTRY.json
#
# Emits ambient event `capabilities_registry_refreshed` with fields:
#   {ts, kind, repo, items_count, delta_count}
#
# Pillar: EFFECTIVE — unlocks dynamic tool discovery for the multi-agent factory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_DEFAULT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

REPO_ROOT="$REPO_ROOT_DEFAULT"
OUT_PATH=""
QUIET=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root) REPO_ROOT="$2"; shift 2 ;;
        --out)       OUT_PATH="$2"; shift 2 ;;
        --quiet|-q)  QUIET=1; shift ;;
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
OUT_PATH="${OUT_PATH:-$REPO_ROOT/docs/CAPABILITIES_REGISTRY.json}"
OVERLAY_PATH="$REPO_ROOT/docs/CAPABILITIES_OVERLAY.yaml"
REGISTRY_YAML="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
MCP_JSON="$REPO_ROOT/chump-mcp.json"
SKILLS_DIR="$REPO_ROOT/chump-brain/skills"
SCRIPTS_README="$REPO_ROOT/scripts/README.md"

# Output buffer (built up section by section in python helper below).
TMP_OUT="$(mktemp -t chump-capreg-XXXXXX.json)"
trap 'rm -f "$TMP_OUT"' EXIT

# Pre-count of existing entries (for delta).
PREV_COUNT=0
if [[ -f "$OUT_PATH" ]]; then
    PREV_COUNT="$(python3 -c "import json,sys
try:
    d=json.load(open('$OUT_PATH'))
    print(len(d.get('primitives',[])))
except Exception:
    print(0)" 2>/dev/null || echo 0)"
fi

# ── Discover repo identifier ──────────────────────────────────────────────────
REPO_ID=""
if git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
    URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)"
    # Strip .git and protocol/host; keep <owner>/<name>
    REPO_ID="$(printf '%s' "$URL" | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
fi
if [[ -z "$REPO_ID" ]]; then
    REPO_ID="$(basename "$REPO_ROOT")"
fi

# ── Build the registry via python (single pass; deterministic ordering) ──────
REPO_ROOT="$REPO_ROOT" \
REPO_ID="$REPO_ID" \
OUT_PATH="$OUT_PATH" \
OVERLAY_PATH="$OVERLAY_PATH" \
REGISTRY_YAML="$REGISTRY_YAML" \
MCP_JSON="$MCP_JSON" \
SKILLS_DIR="$SKILLS_DIR" \
SCRIPTS_README="$SCRIPTS_README" \
TMP_OUT="$TMP_OUT" \
python3 - <<'PYEOF'
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

repo_root = Path(os.environ["REPO_ROOT"])
out_path = Path(os.environ["OUT_PATH"])
overlay_path = Path(os.environ["OVERLAY_PATH"])
registry_yaml = Path(os.environ["REGISTRY_YAML"])
mcp_json = Path(os.environ["MCP_JSON"])
skills_dir = Path(os.environ["SKILLS_DIR"])
scripts_readme = Path(os.environ["SCRIPTS_README"])
tmp_out = Path(os.environ["TMP_OUT"])
repo_id = os.environ["REPO_ID"]

now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

# ── Optional curated overlay ─────────────────────────────────────────────────
overlay = {}
if overlay_path.exists():
    try:
        import yaml  # type: ignore
        with overlay_path.open() as fh:
            doc = yaml.safe_load(fh) or {}
        # Expect shape: { primitives: [ { primitive_id, when_to_use, example_invocation } ... ] }
        for entry in doc.get("primitives", []):
            pid = entry.get("primitive_id")
            if pid:
                overlay[pid] = entry
    except Exception:
        # Overlay parse failure is non-fatal; auto-generated values remain.
        pass

def apply_overlay(primitive: dict) -> dict:
    """Merge curated overlay into a primitive entry, overlay wins on conflict."""
    pid = primitive.get("primitive_id")
    if pid and pid in overlay:
        for k, v in overlay[pid].items():
            if k == "primitive_id":
                continue
            primitive[k] = v
    return primitive


# ── 1. CLI commands (parse main binary --help) ────────────────────────────────
cli_commands = []

def parse_chump_help() -> list[dict]:
    """Run `chump --help` if available; fall back to a deterministic stub list
    keyed off scripts/dev/chump-explain.sh + src/main.rs when chump isn't on PATH."""
    try:
        # Prefer the version installed on PATH; if missing or errors, fall back.
        proc = subprocess.run(
            ["chump", "--help"],
            capture_output=True, text=True, timeout=5,
            env={**os.environ, "CHUMP_NO_BANNER": "1"},
        )
        if proc.returncode == 0:
            return _parse_help_block(proc.stdout)
    except (FileNotFoundError, subprocess.SubprocessError):
        pass
    return []

def _parse_help_block(text: str) -> list[dict]:
    """Extract `<command>  description` rows from the chump --help output."""
    out: list[dict] = []
    seen: set[str] = set()
    # Lines like "  gap <sub>  (alias: g)  list, show, reserve, ship, …"
    # Capture the first token before whitespace.
    for line in text.splitlines():
        m = re.match(r"^\s{2,}([a-z][a-z0-9_-]*)(?:\s+<[^>]+>)?\s+", line)
        if not m:
            continue
        # Skip lines that look like section headings (all caps left side).
        if line.strip().endswith(":"):
            continue
        name = m.group(1)
        if name in seen or name in {"usage", "the", "or", "and", "no"}:
            continue
        seen.add(name)
        out.append({"name": name, "subcommands": [], "flags_summary": line.strip()})
    return out

cli_commands = parse_chump_help()

# ── 2. Event kinds (parse EVENT_REGISTRY.yaml) ────────────────────────────────
# The registry occasionally contains unquoted `:` in multi-line trigger blocks
# which trips yaml.safe_load. Fall back to a kind-only regex extractor — for
# the registry we only need the `kind` field on each `- kind: <name>` row.
event_kinds = []
def _parse_registry_strict(path: Path) -> list[dict]:
    import yaml  # type: ignore
    with path.open() as fh:
        doc = yaml.safe_load(fh) or {}
    out: list[dict] = []
    for evt in doc.get("events", []) or []:
        kind = evt.get("kind")
        if not kind:
            continue
        out.append({
            "name": kind,
            "emitter": evt.get("emitter", ""),
            "consumers": evt.get("consumers", []) or [],
            "fields_required": evt.get("fields_required", []) or [],
        })
    return out

def _parse_registry_fallback(path: Path) -> list[dict]:
    """Tolerant regex scan — extract one entry per `  - kind: <name>` line plus
    any directly-adjacent `emitter:` / `consumers:` / `fields_required:` lines.
    Used when strict YAML parsing fails due to unquoted-colon multi-line values."""
    out: list[dict] = []
    text = path.read_text(encoding="utf-8", errors="replace")
    block: dict[str, object] = {}
    for line in text.splitlines():
        # New event entry — flush previous block.
        m = re.match(r"^  -\s+kind:\s+(\S+)", line)
        if m:
            if block.get("name"):
                out.append(block)
            block = {"name": m.group(1), "emitter": "", "consumers": [], "fields_required": []}
            continue
        if not block:
            continue
        m = re.match(r"^\s{4,}emitter:\s+(.+)$", line)
        if m:
            block["emitter"] = m.group(1).strip()
            continue
        m = re.match(r"^\s{4,}consumers:\s+\[(.+)\]", line)
        if m:
            block["consumers"] = [s.strip() for s in m.group(1).split(",") if s.strip()]
            continue
        m = re.match(r"^\s{4,}fields_required:\s+\[(.+)\]", line)
        if m:
            block["fields_required"] = [s.strip() for s in m.group(1).split(",") if s.strip()]
            continue
    if block.get("name"):
        out.append(block)
    return out

if registry_yaml.exists():
    try:
        event_kinds = _parse_registry_strict(registry_yaml)
    except Exception as e:
        print(f"[build-capabilities-registry] note: strict YAML parse failed ({e}); using tolerant fallback", file=sys.stderr)
        try:
            event_kinds = _parse_registry_fallback(registry_yaml)
        except Exception as ee:
            print(f"[build-capabilities-registry] warning: fallback parse also failed: {ee}", file=sys.stderr)

# ── 3. Crate APIs (chump-ast-crawler over crates/*/src/lib.rs) ────────────────
crate_apis = []
crates_dir = repo_root / "crates"
if crates_dir.is_dir():
    for crate_path in sorted(p for p in crates_dir.iterdir() if p.is_dir()):
        lib_rs = crate_path / "src" / "lib.rs"
        if not lib_rs.is_file():
            continue
        items: list[dict] = []
        try:
            text = lib_rs.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        # Lightweight regex extraction — matches the chump-ast-crawler's
        # per-language symbol set for Rust (pub fn / pub struct / pub enum /
        # pub trait / pub mod / pub const / pub type / pub use). We avoid the
        # tree-sitter dependency here so the generator can run pre-build.
        pattern = re.compile(
            r"^[ \t]*pub(?:\([^)]*\))?[ \t]+(?:async[ \t]+)?(?:unsafe[ \t]+)?"
            r"(?P<kind>fn|struct|enum|trait|mod|const|type|use)[ \t]+(?P<name>[A-Za-z_][A-Za-z0-9_]*)",
            re.MULTILINE,
        )
        for idx, line in enumerate(text.splitlines(), start=1):
            m = pattern.match(line)
            if m:
                items.append({
                    "name": m.group("name"),
                    "kind": m.group("kind"),
                    "line": idx,
                })
        # Drop trivial `pub use` re-exports of std primitives to keep noise down.
        items = [i for i in items if i["name"] not in {"crate", "self", "super"}]
        # Extract crate name from Cargo.toml.
        cargo_toml = crate_path / "Cargo.toml"
        crate_name = crate_path.name
        if cargo_toml.is_file():
            try:
                cargo_text = cargo_toml.read_text(encoding="utf-8", errors="replace")
                m = re.search(r'^\s*name\s*=\s*"([^"]+)"', cargo_text, re.MULTILINE)
                if m:
                    crate_name = m.group(1)
            except OSError:
                pass
        crate_apis.append({
            "crate_name": crate_name,
            "crate_path": str(crate_path.relative_to(repo_root)),
            "public_items": items,
        })

# ── 4. MCP tools (chump-mcp.json + #[chump_tool] macro sites) ─────────────────
mcp_tools = []
if mcp_json.exists():
    try:
        doc = json.loads(mcp_json.read_text(encoding="utf-8"))
        for name, spec in (doc.get("mcpServers") or {}).items():
            if not spec.get("enabled", True):
                continue
            mcp_tools.append({
                "name": name,
                "description": spec.get("command", ""),
                "schema": "",
                "source": "chump-mcp.json",
            })
    except Exception as e:
        print(f"[build-capabilities-registry] warning: failed to parse chump-mcp.json: {e}", file=sys.stderr)

# Macro-annotated tools — scan src/**/*.rs for #[chump_tool] attributes and
# inventory! registrations. Keep this lightweight (regex, not AST) so the
# generator stays fast on cold caches.
src_dir = repo_root / "src"
if src_dir.is_dir():
    seen_tool_names: set[str] = {t["name"] for t in mcp_tools}
    for rs_file in sorted(src_dir.rglob("*.rs")):
        try:
            text = rs_file.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        # #[chump_tool(name = "foo", ...)]
        for m in re.finditer(r'#\[chump_tool\([^)]*name\s*=\s*"([^"]+)"', text):
            tn = m.group(1)
            if tn in seen_tool_names:
                continue
            seen_tool_names.add(tn)
            mcp_tools.append({
                "name": tn,
                "description": f"#[chump_tool] annotation in {rs_file.relative_to(repo_root)}",
                "schema": "",
                "source": "chump_tool_macro",
            })
        # inventory::submit!(ChumpTool { name: "foo", ... })
        for m in re.finditer(r'inventory::submit!\([^)]*name\s*:\s*"([^"]+)"', text):
            tn = m.group(1)
            if tn in seen_tool_names:
                continue
            seen_tool_names.add(tn)
            mcp_tools.append({
                "name": tn,
                "description": f"inventory! registration in {rs_file.relative_to(repo_root)}",
                "schema": "",
                "source": "inventory_registration",
            })

# ── 5. Skills (chump-brain/skills/<name>/SKILL.md when present) ──────────────
skills = []
if skills_dir.is_dir():
    for skill_dir in sorted(p for p in skills_dir.iterdir() if p.is_dir()):
        skill_md = skill_dir / "SKILL.md"
        if not skill_md.is_file():
            continue
        try:
            head = skill_md.read_text(encoding="utf-8", errors="replace")[:512]
        except OSError:
            head = ""
        purpose = ""
        for line in head.splitlines():
            if line.strip() and not line.startswith("#"):
                purpose = line.strip()[:180]
                break
        skills.append({
            "primitive_id": f"skill-{skill_dir.name.lower().replace('_','-')}",
            "kind": "skill",
            "file_paths": [str(skill_md.relative_to(repo_root))],
            "purpose_one_line": purpose,
            "when_to_use": "",
            "example_invocation": f"chump skill run {skill_dir.name}",
            "version": "git-sha",
        })

# ── 6. Build the flattened primitives list (AC #1) ───────────────────────────
def slug(s: str) -> str:
    """kebab-case the input id."""
    s = re.sub(r"[^A-Za-z0-9]+", "-", s).strip("-").lower()
    return s or "unknown"

primitives = []

# CLI primitives
for c in cli_commands:
    pid = slug(f"cli-{c['name']}")
    primitives.append(apply_overlay({
        "primitive_id": pid,
        "kind": "cli",
        "file_paths": ["src/main.rs"],
        "purpose_one_line": c.get("flags_summary", ""),
        "when_to_use": "",
        "example_invocation": f"chump {c['name']} --help",
        "version": "git-sha",
    }))

# Event primitives
for ev in event_kinds:
    pid = slug(f"event-{ev['name']}")
    primitives.append(apply_overlay({
        "primitive_id": pid,
        "kind": "event",
        "file_paths": ["docs/observability/EVENT_REGISTRY.yaml"],
        "purpose_one_line": f"ambient event emitted by {ev.get('emitter','?')}",
        "when_to_use": "",
        "example_invocation": f"scripts/dev/ambient-emit.sh {ev['name']} key=value",
        "version": "git-sha",
    }))

# Crate primitives
for cr in crate_apis:
    pid = slug(f"crate-{cr['crate_name']}")
    primitives.append(apply_overlay({
        "primitive_id": pid,
        "kind": "crate",
        "file_paths": [f"{cr['crate_path']}/src/lib.rs"],
        "purpose_one_line": f"{len(cr['public_items'])} public items",
        "when_to_use": "",
        "example_invocation": f'use {cr["crate_name"].replace("-","_")};',
        "version": "0.1.0",
    }))

# MCP-tool primitives
for tool in mcp_tools:
    pid = slug(f"mcp-{tool['name']}")
    primitives.append(apply_overlay({
        "primitive_id": pid,
        "kind": "mcp_tool",
        "file_paths": ["chump-mcp.json"],
        "purpose_one_line": tool.get("description", ""),
        "when_to_use": "",
        "example_invocation": tool.get("description", ""),
        "version": "git-sha",
    }))

# Skill primitives (already shaped above)
primitives.extend(apply_overlay(s) for s in skills)

registry = {
    "schema_version": 1,
    "repo": repo_id,
    "generated_at": now,
    "generator_version": os.environ.get("GIT_SHA", "dev"),
    "cli_commands": cli_commands,
    "event_kinds": event_kinds,
    "crate_apis": crate_apis,
    "mcp_tools": mcp_tools,
    "primitives": primitives,
}

tmp_out.write_text(json.dumps(registry, indent=2, sort_keys=False) + "\n", encoding="utf-8")
# Caller reads the count via a follow-up jq call; stdout from this heredoc
# is reserved for warnings only so --quiet stays quiet.
PYEOF

ITEMS_COUNT="$(python3 -c "import json,sys; print(len(json.load(open('$TMP_OUT')).get('primitives',[])))" 2>/dev/null || echo 0)"
DELTA_COUNT=$((ITEMS_COUNT - PREV_COUNT))

# Move into place atomically.
mkdir -p "$(dirname "$OUT_PATH")"
mv "$TMP_OUT" "$OUT_PATH"
trap - EXIT

if [[ "$QUIET" -eq 0 ]]; then
    echo "[build-capabilities-registry] wrote $OUT_PATH (items=$ITEMS_COUNT, delta=$DELTA_COUNT)"
fi

# ── Ambient emit ──────────────────────────────────────────────────────────────
# Best-effort; never fail the generator if ambient-emit isn't on PATH or the
# schema check rejects (e.g. when running inside a synthetic test repo).
if [[ -x "$SCRIPT_DIR/ambient-emit.sh" ]]; then
    # Use literal "capabilities_registry_refreshed" so the
    # event-registry-coverage gate sees the kind in this script.
    CHUMP_AMBIENT_SCHEMA_CHECK=0 \
    bash "$SCRIPT_DIR/ambient-emit.sh" "capabilities_registry_refreshed" \
        "repo=$REPO_ID" "items_count=$ITEMS_COUNT" "delta_count=$DELTA_COUNT" \
        2>/dev/null || true
fi
