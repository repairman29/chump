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
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
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
overlay_status = "absent"
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
        overlay_status = "applied"
    except Exception as e:
        # CREDIBLE-240: this used to be a bare `pass`. A missing PyYAML on the
        # runner silently dropped every hand-curated when_to_use string and
        # produced a *different, quieter* registry that looked perfectly fine —
        # the exact silent-degradation failure this gap is about. Say it.
        overlay_status = f"FAILED:{type(e).__name__}"
        print(
            f"[build-capabilities-registry] WARNING: overlay {overlay_path} could not be "
            f"applied ({e}); every curated when_to_use is MISSING from this registry. "
            f"Install PyYAML (pip install pyyaml) and re-run.",
            file=sys.stderr,
        )

def apply_overlay(primitive: dict) -> dict:
    """Merge curated overlay into a primitive entry, overlay wins on conflict."""
    pid = primitive.get("primitive_id")
    if pid and pid in overlay:
        for k, v in overlay[pid].items():
            if k == "primitive_id":
                continue
            primitive[k] = v
    return primitive


# ── 1. CLI commands (parse the repo's own help text) ──────────────────────────
#
# CREDIBLE-240: source-first, binary-second. The old order (PATH binary first)
# made the output depend on which build happened to be installed on the machine
# running the generator — CI and a laptop produced different registries, so an
# auto-commit job would flip-flop forever. Parsing `fn print_help()` out of
# src/main.rs is deterministic and needs no build; it was verified
# set-identical to `chump --help` (40 commands, zero difference) when written.
cli_commands = []
cli_source = "none"

def _help_text_from_source() -> str:
    """Reconstruct --help output from the println! literals inside
    `fn print_help()` in src/main.rs. Returns "" when that function is absent
    (i.e. the target repo is not chump — the generic `chump ingest` path)."""
    main_rs = repo_root / "src" / "main.rs"
    if not main_rs.is_file():
        return ""
    try:
        text = main_rs.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    start = text.find("fn print_help() {")
    if start < 0:
        return ""
    end = text.find("\n}\n", start)
    if end < 0:
        return ""
    body = text[start:end]
    parts: list[str] = []
    for m in re.finditer(r'print(?:ln)?!\(\s*"((?:[^"\\]|\\.)*)"', body, re.S):
        try:
            parts.append(m.group(1).encode().decode("unicode_escape"))
        except UnicodeDecodeError:
            parts.append(m.group(1))
    return "\n".join(parts)

def parse_chump_help() -> tuple[list[dict], str]:
    """Deterministic source parse first; `chump --help` on PATH only as the
    fallback for repos whose help text is not a literal in src/main.rs."""
    help_text = _help_text_from_source()
    if help_text:
        parsed = _parse_help_block(help_text)
        if parsed:
            return parsed, "src/main.rs:print_help"
    try:
        proc = subprocess.run(
            ["chump", "--help"],
            capture_output=True, text=True, timeout=5,
            env={**os.environ, "CHUMP_NO_BANNER": "1"},
        )
        if proc.returncode == 0:
            parsed = _parse_help_block(proc.stdout)
            if parsed:
                return parsed, "chump --help (PATH binary — not reproducible)"
    except (FileNotFoundError, subprocess.SubprocessError):
        pass
    return [], "none"

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

cli_commands, cli_source = parse_chump_help()

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

# ── 3. Crate APIs (every crate in the workspace) ──────────────────────────────
#
# CREDIBLE-240: the old discovery was `crates/*/src/lib.rs` — one level deep,
# library crates only. That silently dropped 14 of chump's 47 workspace
# packages: the 7 nested crates under crates/mcp-servers/ (every MCP server
# implementation), the binary-only crates, chump-tool-macro,
# desktop/src-tauri, and the root `chump` package itself. A catalog that omits
# every MCP server crate is exactly the confidently-wrong answer this gap is
# about.
#
# New discovery order:
#   1. root Cargo.toml [workspace].members (authoritative; globs expanded)
#   2. otherwise recurse crates/ for any directory holding a Cargo.toml
def _workspace_member_dirs() -> list[Path]:
    """Resolve [workspace].members from the root Cargo.toml, plus the root
    package itself when the root Cargo.toml also declares a [package]."""
    root_toml = repo_root / "Cargo.toml"
    if not root_toml.is_file():
        return []
    try:
        toml_text = root_toml.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    m = re.search(r"^\[workspace\]\s*$(.*?)(?=^\[)", toml_text, re.M | re.S)
    if not m:
        return []
    mm = re.search(r"members\s*=\s*\[(.*?)\]", m.group(1), re.S)
    if not mm:
        return []
    found: list[Path] = []
    for raw in re.findall(r'"([^"]+)"', mm.group(1)):
        # Members may be globs ("crates/*"); expand them relative to the root.
        if any(ch in raw for ch in "*?["):
            found.extend(sorted(p for p in repo_root.glob(raw) if (p / "Cargo.toml").is_file()))
        else:
            p = repo_root / raw
            if (p / "Cargo.toml").is_file():
                found.append(p)
    if re.search(r"^\[package\]\s*$", toml_text, re.M):
        found.append(repo_root)
    # Deterministic order, no duplicates.
    return sorted(set(found), key=lambda p: str(p.relative_to(repo_root)))

def _scan_crates_dir() -> list[Path]:
    crates_dir = repo_root / "crates"
    if not crates_dir.is_dir():
        return []
    found = []
    for cargo in crates_dir.rglob("Cargo.toml"):
        if "target" in cargo.parts:
            continue
        found.append(cargo.parent)
    return sorted(set(found), key=lambda p: str(p.relative_to(repo_root)))

crate_apis = []
crate_dirs = _workspace_member_dirs() or _scan_crates_dir()
for crate_path in crate_dirs:
        lib_rs = crate_path / "src" / "lib.rs"
        main_rs = crate_path / "src" / "main.rs"
        # A crate with neither entry point (e.g. a pure [[bin]]-table crate)
        # still counts — record it with whatever entry file we can name.
        if lib_rs.is_file():
            entry, crate_kind = lib_rs, ("lib+bin" if main_rs.is_file() else "lib")
        elif main_rs.is_file():
            entry, crate_kind = main_rs, "bin"
        else:
            entry, crate_kind = crate_path / "Cargo.toml", "other"
        items: list[dict] = []
        try:
            text = entry.read_text(encoding="utf-8", errors="replace") if crate_kind.startswith("lib") else ""
        except OSError:
            text = ""
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
        rel_crate = str(crate_path.relative_to(repo_root)) or "."
        crate_apis.append({
            "crate_name": crate_name,
            "crate_path": rel_crate,
            "crate_kind": crate_kind,
            "entry_file": str(entry.relative_to(repo_root)),
            "public_items": items,
        })
crate_apis.sort(key=lambda c: (c["crate_path"], c["crate_name"]))

# ── 4. MCP tools (chump-mcp.json + #[chump_tool] macro sites) ─────────────────
# CREDIBLE-240: a declared-but-disabled server used to be dropped entirely, so
# the catalog said "chump has no github MCP server" when in fact it has one
# that is wired and switched off. Silence is the wrong answer — list it with
# `enabled: false` so a reader learns both that it exists and that it is off.
mcp_tools = []
if mcp_json.exists():
    try:
        doc = json.loads(mcp_json.read_text(encoding="utf-8"))
        for name, spec in (doc.get("mcpServers") or {}).items():
            enabled = bool(spec.get("enabled", True))
            desc = spec.get("command", "")
            if not enabled:
                desc = f"{desc} (DISABLED in chump-mcp.json — declared but not started)"
            mcp_tools.append({
                "name": name,
                "description": desc,
                "schema": "",
                "source": "chump-mcp.json",
                "enabled": enabled,
                "file_path": "chump-mcp.json",
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
                "enabled": True,
                # CREDIBLE-240: point the receipt at the real definition site,
                # not at chump-mcp.json (which never mentions this tool).
                "file_path": str(rs_file.relative_to(repo_root)),
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
                "enabled": True,
                "file_path": str(rs_file.relative_to(repo_root)),
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
        # CREDIBLE-240: use the crate's real entry file. Hardcoding
        # "<path>/src/lib.rs" produced dangling receipts for binary crates.
        "file_paths": [cr["entry_file"]],
        "purpose_one_line": (
            f"{cr['crate_kind']} crate, {len(cr['public_items'])} public items"
        ),
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
        "file_paths": [tool.get("file_path") or "chump-mcp.json"],
        "purpose_one_line": tool.get("description", ""),
        "when_to_use": "",
        "example_invocation": tool.get("description", ""),
        "version": "git-sha",
    }))

# Skill primitives (already shaped above)
primitives.extend(apply_overlay(s) for s in skills)

# ── 7. Self-reporting freshness + cross-registry pointers (CREDIBLE-240) ─────
#
# This file is INDEXED by almanac, so an agent can be handed a chunk of it with
# a file:line receipt and quote it as current fact. A JSON document cannot know
# what today's date is — so instead of only stamping when it was made, it also
# states the date after which it must not be believed. `stale_after` is an
# absolute timestamp: any reader, including an LLM that cannot run code, can
# compare it to today without doing date arithmetic.
max_age_days = int(os.environ.get("CHUMP_CAPABILITIES_MAX_AGE_DAYS", "30"))
generated_dt = datetime.now(timezone.utc).replace(microsecond=0)
stale_after = (generated_dt + timedelta(days=max_age_days)).isoformat().replace("+00:00", "Z")

read_me_first = (
    f"GENERATED FILE — do not hand-edit. Regenerate with "
    f"`bash scripts/dev/build-capabilities-registry.sh`. This snapshot is only "
    f"trustworthy until {stale_after}. If today is on or after that date, this "
    f"catalog is STALE: re-run the generator before quoting anything in it as "
    f"the current state of the repo. Verify freshness with "
    f"`bash scripts/ci/check-capabilities-freshness.sh`."
)

# CREDIBLE-240 AC#5: this registry answers "what tools does the fleet have".
# privateer/charter.json answers "which provider backs a given capability
# need". Neither used to mention the other, so "which provider does this tool
# front" had no answer. The join is stated here, in the tools direction.
related_registries = [
    {
        "name": "privateer charter",
        "path": "../privateer/charter.json",
        "repo": "repairman29/privateer",
        "holds": "capability NEEDS and the provider backing each one "
                 "(completion, search, embedding, rerank, tts, stt, ocr, "
                 "vision, code-sandbox), plus its cascade status",
        "this_registry_holds": "the TOOLS and primitives chump exposes",
        "answers_together": "which provider does this tool front",
        "join": "charter.needs[].incumbent is a '<repo>:<path>' string, e.g. "
                "'chump:crates/mcp-servers/chump-mcp-tavily'. Split on the "
                "first ':'; when the repo part is 'chump', match the path part "
                "against crate_apis[].crate_path (crate-directory incumbents), "
                "then crate_apis[].entry_file, then primitives[].file_paths. "
                "Run scripts/ops/capability-provider-join.sh to do this.",
        "join_caveats": "Verified 2026-08-09, not assumed: of the 9 needs in "
                        "charter.json only 'search' resolves to a primitive "
                        "here (crate chump-mcp-tavily). 'completion' names "
                        "chump:src/provider_cascade.rs, which is plain source "
                        "this registry does not catalogue as a primitive — the "
                        "path is real, the join target is not. The other 7 "
                        "incumbents live in other repos (almanac, olive) or "
                        "are unexplored. Do not read a missing match as "
                        "'chump has no such capability'.",
        "direction": "chump -> privateer (this pointer). The reverse edge is "
                     "the `incumbent` field inside charter.json.",
    }
]

registry = {
    "_read_me_first": read_me_first,
    "schema_version": 1,
    "repo": repo_id,
    "generated_at": now,
    "stale_after": stale_after,
    "staleness_policy": {
        "max_age_days": max_age_days,
        "regenerate_cmd": "bash scripts/dev/build-capabilities-registry.sh",
        "check_cmd": "bash scripts/ci/check-capabilities-freshness.sh",
        "enforced_by": [
            ".github/workflows/capabilities-registry.yml",
            "scripts/ci/check-capabilities-freshness.sh",
            "scripts/ci/test-capabilities-registry.sh",
        ],
    },
    "generator_version": os.environ.get("GIT_SHA", "dev"),
    "cli_source": cli_source,
    "overlay_status": overlay_status,
    "related_registries": related_registries,
    "cli_commands": cli_commands,
    "event_kinds": event_kinds,
    "crate_apis": crate_apis,
    "mcp_tools": mcp_tools,
    "primitives": primitives,
}

# Content fingerprint over the substantive sections ONLY — deliberately
# excludes generated_at / stale_after / _read_me_first so the trigger job can
# tell "the repo actually changed" from "time passed". Without this, every
# scheduled run would look like a diff and commit noise forever.
content_keys = ["schema_version", "repo", "cli_commands", "event_kinds",
                "crate_apis", "mcp_tools", "primitives", "related_registries"]
content_blob = json.dumps({k: registry[k] for k in content_keys},
                          sort_keys=True, separators=(",", ":"))
registry["content_sha256"] = hashlib.sha256(content_blob.encode("utf-8")).hexdigest()

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
