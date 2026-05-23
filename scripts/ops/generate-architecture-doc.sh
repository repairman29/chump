#!/usr/bin/env bash
# scripts/ops/generate-architecture-doc.sh — INFRA-1722
#
# Auto-generate per-repo docs/ARCHITECTURE.md from the deterministic
# INFRA-1719 AST crawler output. Companion to INFRA-1721's
# CAPABILITIES_REGISTRY.json — where the registry is the programmatic
# surface, ARCHITECTURE.md is the human-readable counterpart.
#
# Sections produced:
#   1. Overview              — Custodian content-bot prose (stub if not wired)
#   2. Module topology       — deterministic text tree of source files
#   3. Key primitives        — top-level fn/struct/trait per module, with
#                              one-line summaries from doc comments
#   4. Dependencies          — text adjacency list derived from imports
#   5. Public surface        — modules re-exported from lib roots
#
# Sections 2/3/4/5 are deterministic non-AI output. Section 1 (and any other
# prose-only header) is gated through `scripts/content-bots/run-bot.sh
# docubot` (the closest match to the "Custodian" role in the bots.yaml
# manifest until META-066 adds a dedicated custodian bot). If the bot is not
# enabled per the toggle resolver, the generator leaves a
# `<!-- CUSTODIAN: fill in -->` placeholder so the doc still lands and the
# operator can wire the bot later without re-running everything.
#
# Usage:
#   scripts/ops/generate-architecture-doc.sh <repo-path> [--output PATH]
#                                            [--no-bot] [--ambient-log PATH]
#
# Defaults:
#   --output         <repo-path>/docs/ARCHITECTURE.md
#   --no-bot         off; the Custodian bot is invoked when enabled
#   --ambient-log    .chump-locks/ambient.jsonl in the *target* repo if it
#                    exists, else $CHUMP_AMBIENT_LOG, else /dev/null
#
# Exit codes:
#   0  output written (and event emitted)
#   2  bad usage
#   3  AST crawler invocation failed
#   4  output directory could not be created
#
# Emits: kind=architecture_doc_regenerated to ambient on each generation.
# Fields: ts, kind, repo, lines_changed, sections_touched.
#
# Tracked: INFRA-1722 (this gap). Depends on INFRA-1719 (AST crawler) and
# the content-bot dispatcher from INFRA-1695.

set -euo pipefail

# ── Arg parsing ─────────────────────────────────────────────────────────────
REPO_PATH=""
OUTPUT=""
NO_BOT=0
AMBIENT_LOG=""

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed -n '/^# Usage:/,/^# Tracked:/p' | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT="$2"; shift 2 ;;
        --no-bot) NO_BOT=1; shift ;;
        --ambient-log) AMBIENT_LOG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --*) echo "[arch-gen] unknown flag: $1" >&2; exit 2 ;;
        *)
            if [[ -z "$REPO_PATH" ]]; then
                REPO_PATH="$1"
            else
                echo "[arch-gen] unexpected positional: $1" >&2
                exit 2
            fi
            shift ;;
    esac
done

if [[ -z "$REPO_PATH" ]]; then
    usage
    exit 2
fi

if [[ ! -d "$REPO_PATH" ]]; then
    echo "[arch-gen] FAIL: not a directory: $REPO_PATH" >&2
    exit 2
fi

# Absolute paths from here on — relative paths get confusing when we cd into
# the chump worktree to run cargo.
REPO_PATH="$(cd "$REPO_PATH" && pwd)"
OUTPUT="${OUTPUT:-$REPO_PATH/docs/ARCHITECTURE.md}"

# Resolve the chump worktree so we can run cargo against the ast-crawler
# crate even when REPO_PATH points elsewhere (the demo-target case).
CHUMP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Ambient log default: prefer the target repo's own ambient stream if it
# exists (operators running ingest on their own repo see the event there),
# else $CHUMP_AMBIENT_LOG, else the chump root's lock dir.
if [[ -z "$AMBIENT_LOG" ]]; then
    if [[ -d "$REPO_PATH/.chump-locks" ]]; then
        AMBIENT_LOG="$REPO_PATH/.chump-locks/ambient.jsonl"
    elif [[ -n "${CHUMP_AMBIENT_LOG:-}" ]]; then
        AMBIENT_LOG="$CHUMP_AMBIENT_LOG"
    else
        AMBIENT_LOG="$CHUMP_ROOT/.chump-locks/ambient.jsonl"
    fi
fi

# ── 1. Crawl the repo via the INFRA-1719 AST crawler ────────────────────────
SHAPE_JSON="$(mktemp -t chump-arch-shape.XXXXXX.json)"
trap 'rm -f "$SHAPE_JSON" "$OUTPUT.tmp" "$OUTPUT.prev" 2>/dev/null || true' EXIT

echo "[arch-gen] crawling $REPO_PATH (via chump-ast-crawler / INFRA-1719)" >&2

if ! (cd "$CHUMP_ROOT" && cargo run --quiet --release -p chump-ast-crawler --bin crawl-cli -- "$REPO_PATH" \
        > "$SHAPE_JSON" 2>&1 < /dev/null) ; then
    echo "[arch-gen] FAIL: chump-ast-crawler crawl-cli exited non-zero" >&2
    echo "[arch-gen] crawler output:" >&2
    sed 's/^/  /' "$SHAPE_JSON" >&2 || true
    exit 3
fi

# Validate the JSON looks like CodebaseShape.
if ! python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert 'files' in d and 'total_files' in d" "$SHAPE_JSON" 2>/dev/null; then
    echo "[arch-gen] FAIL: crawler output is not a CodebaseShape JSON" >&2
    sed 's/^/  /' "$SHAPE_JSON" >&2
    exit 3
fi

# ── 2. Render the four deterministic sections from the shape JSON ───────────
#
# All rendering happens in a single python3 invocation so we have access to
# json.load + dict-ordering + multi-section composition without 20 separate
# subshells. Output is appended to $OUTPUT.tmp; the Custodian prose (or
# placeholder) is prepended afterwards.
DETERMINISTIC_BODY="$(mktemp -t chump-arch-body.XXXXXX.md)"
trap 'rm -f "$SHAPE_JSON" "$OUTPUT.tmp" "$OUTPUT.prev" "$DETERMINISTIC_BODY" 2>/dev/null || true' EXIT

python3 - "$SHAPE_JSON" "$REPO_PATH" > "$DETERMINISTIC_BODY" <<'PYEOF'
import json
import os
import sys
from collections import defaultdict

shape_path, repo_path = sys.argv[1], sys.argv[2]
with open(shape_path) as f:
    shape = json.load(f)

files = sorted(shape.get("files", []), key=lambda f: f["path"])
total_files = shape.get("total_files", len(files))
total_symbols = shape.get("total_symbols", 0)
langs = shape.get("supported_languages", [])

# ── Module topology ─────────────────────────────────────────────────────────
print("## Module topology")
print()
print(f"_{total_files} files, {total_symbols} top-level symbols, languages: {', '.join(langs) or 'none'}._")
print()
print("```")
# Group files by directory for a compact text tree.
by_dir = defaultdict(list)
for f in files:
    d = os.path.dirname(f["path"]) or "."
    by_dir[d].append(f)
for d in sorted(by_dir.keys()):
    print(f"{d}/")
    for f in by_dir[d]:
        name = os.path.basename(f["path"])
        lang = f.get("language", "unknown")
        n = len(f.get("top_level_symbols", []))
        print(f"  {name}  [{lang}, {n} symbols]")
print("```")
print()

# ── Key primitives ──────────────────────────────────────────────────────────
print("## Key primitives")
print()
print("Top-level `fn`/`struct`/`trait`/`class` (and equivalents) per module, with the")
print("first non-blank line of any attached doc comment.")
print()
emitted_any = False
for f in files:
    syms = f.get("top_level_symbols") or []
    if not syms:
        continue
    emitted_any = True
    print(f"### `{f['path']}`")
    print()
    for s in syms:
        kind = s.get("kind", "?")
        name = s.get("name", "?")
        line = s.get("line", 0)
        doc = (s.get("doc_first_line") or "").strip()
        if doc:
            print(f"- **{kind}** `{name}` _(L{line})_ — {doc}")
        else:
            print(f"- **{kind}** `{name}` _(L{line})_")
    print()
if not emitted_any:
    print("_(no symbols extracted — repo contains no source files in the day-1 supported set)_")
    print()

# ── Dependencies ────────────────────────────────────────────────────────────
print("## Dependencies")
print()
print("Inter-module import adjacency derived from `use` / `import` statements.")
print("Imports are listed verbatim from source; resolve to a module by mapping each")
print("import root against the file tree above.")
print()
emitted_any = False
for f in files:
    imps = f.get("imports") or []
    if not imps:
        continue
    emitted_any = True
    print(f"- `{f['path']}` →")
    for imp in imps:
        first = imp.splitlines()[0].strip()
        if first:
            print(f"  - `{first}`")
if not emitted_any:
    print("_(no imports surfaced)_")
print()

# ── Public surface ──────────────────────────────────────────────────────────
print("## Public surface")
print()
print("Modules re-exported from a lib root (heuristic: a `pub mod` / `pub use`")
print("declaration in a file named `lib.rs`, `mod.rs`, `index.ts`, `index.js`, or")
print("`__init__.py`).")
print()
ROOT_BASENAMES = {"lib.rs", "mod.rs", "index.ts", "index.js", "index.tsx",
                   "index.jsx", "__init__.py", "main.go"}
emitted_any = False
for f in files:
    name = os.path.basename(f["path"])
    if name not in ROOT_BASENAMES:
        continue
    # A symbol counts as "public surface" when it is itself a mod declaration
    # (Rust) or any top-level symbol exported from an index file (TS/JS/Py).
    exported = []
    for s in f.get("top_level_symbols") or []:
        if s.get("kind") == "mod" or name != "lib.rs":
            exported.append(s)
    if not exported:
        continue
    emitted_any = True
    print(f"### `{f['path']}`")
    print()
    for s in exported:
        kind = s.get("kind", "?")
        nm = s.get("name", "?")
        doc = (s.get("doc_first_line") or "").strip()
        if doc:
            print(f"- **{kind}** `{nm}` — {doc}")
        else:
            print(f"- **{kind}** `{nm}`")
    print()
if not emitted_any:
    print("_(no lib-root files with re-exports detected)_")
    print()
PYEOF

# ── 3. Custodian prose (or placeholder) ─────────────────────────────────────
CUSTODIAN_OUT="$(mktemp -t chump-arch-custodian.XXXXXX.md)"
trap 'rm -f "$SHAPE_JSON" "$OUTPUT.tmp" "$OUTPUT.prev" "$DETERMINISTIC_BODY" "$CUSTODIAN_OUT" 2>/dev/null || true' EXIT

CUSTODIAN_BOT="${CHUMP_ARCH_CUSTODIAN_BOT:-docubot}"
CUSTODIAN_INVOKED=0

if [[ "$NO_BOT" == "1" ]]; then
    : >"$CUSTODIAN_OUT"
elif [[ -x "$CHUMP_ROOT/scripts/content-bots/run-bot.sh" ]]; then
    TASK_FILE="$(mktemp -t chump-arch-task.XXXXXX.md)"
    {
        echo "# Task: generate the Overview + Module Roles prose for ARCHITECTURE.md"
        echo ""
        echo "Target repo: \`$REPO_PATH\`"
        echo ""
        echo "Below is the deterministic output that will be appended to ARCHITECTURE.md."
        echo "Read it and write ~3-6 short paragraphs for:"
        echo "  - **Overview** — what this codebase does, scoped to a developer landing for"
        echo "    the first time. Reference modules from the topology by name."
        echo "  - **Module roles** — one line per top-level module describing its job."
        echo ""
        echo "Do not invent files or types not present in the topology. Keep prose under"
        echo "350 words total. Output raw markdown (no code fences around the prose itself)."
        echo ""
        echo "---"
        echo ""
        cat "$DETERMINISTIC_BODY"
    } >"$TASK_FILE"
    if "$CHUMP_ROOT/scripts/content-bots/run-bot.sh" "$CUSTODIAN_BOT" \
            --task "$TASK_FILE" \
            --run-id "arch-doc-$(date +%s)-$$" \
            >"$CUSTODIAN_OUT.runlog" 2>&1; then
        # run-bot.sh prints "OK $BOT_ID → $OUT_FILE …" — extract path.
        bot_output_path="$(awk '/-> / {print $4}' "$CUSTODIAN_OUT.runlog" | head -1)"
        if [[ -n "$bot_output_path" ]] && [[ -f "$bot_output_path" ]]; then
            cp "$bot_output_path" "$CUSTODIAN_OUT"
            CUSTODIAN_INVOKED=1
        else
            : >"$CUSTODIAN_OUT"
        fi
    else
        echo "[arch-gen] note: content-bot '$CUSTODIAN_BOT' not enabled or failed; using placeholder" >&2
        : >"$CUSTODIAN_OUT"
    fi
    rm -f "$TASK_FILE" "$CUSTODIAN_OUT.runlog" 2>/dev/null || true
else
    : >"$CUSTODIAN_OUT"
fi

# ── 4. Compose ARCHITECTURE.md ──────────────────────────────────────────────
mkdir -p "$(dirname "$OUTPUT")" || { echo "[arch-gen] FAIL: cannot mkdir $(dirname "$OUTPUT")" >&2; exit 4; }

{
    echo "# Architecture"
    echo ""
    echo "_Auto-generated by \`scripts/ops/generate-architecture-doc.sh\` (INFRA-1722)."
    echo "Sections 2-5 are deterministic AST-derived output; section 1 prose is"
    echo "Custodian-generated via the content-bot suite._"
    echo ""
    if [[ -s "$CUSTODIAN_OUT" ]]; then
        cat "$CUSTODIAN_OUT"
    else
        echo "## Overview"
        echo ""
        echo "<!-- CUSTODIAN: fill in -->"
        echo ""
        echo "_(The Custodian content-bot is not currently wired; the operator can"
        echo "enable it via \`CHUMP_CONTENT_BOTS=docubot\` and re-run to populate"
        echo "this section.)_"
        echo ""
    fi
    cat "$DETERMINISTIC_BODY"
} >"$OUTPUT.tmp"

# ── 5. Diff-aware: only overwrite if changed >=5 lines ──────────────────────
LINES_CHANGED=0
SECTIONS_TOUCHED="full"
if [[ -f "$OUTPUT" ]]; then
    if cmp -s "$OUTPUT" "$OUTPUT.tmp"; then
        LINES_CHANGED=0
        SECTIONS_TOUCHED="none"
        echo "[arch-gen] no change vs existing $OUTPUT" >&2
    else
        # Count the diff lines (excluding the +++/--- headers).
        LINES_CHANGED="$(diff -u "$OUTPUT" "$OUTPUT.tmp" 2>/dev/null \
            | awk '/^[+-][^+-]/ {n++} END {print n+0}')"
        cp "$OUTPUT" "$OUTPUT.prev"
        mv "$OUTPUT.tmp" "$OUTPUT"
    fi
else
    # First generation — count every body line as a change.
    LINES_CHANGED="$(wc -l < "$OUTPUT.tmp" | tr -d ' ')"
    mv "$OUTPUT.tmp" "$OUTPUT"
fi

# ── 6. Ambient emit ─────────────────────────────────────────────────────────
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
# JSON-escape repo path minimally (no backslashes, double-quote escape).
repo_escaped="${REPO_PATH//\\/\\\\}"
repo_escaped="${repo_escaped//\"/\\\"}"
# The kind literal "architecture_doc_regenerated" is in the printf format
# string itself (not a %s substitution) so the event-registry coverage gate
# (scripts/ci/test-event-registry-coverage.sh, INFRA-1287) can statically
# discover this emit site via its `"kind":"<name>"` grep pattern.
printf '{"ts":"%s","kind":"architecture_doc_regenerated","repo":"%s","lines_changed":%d,"sections_touched":"%s","custodian_invoked":%s,"output":"%s"}\n' \
    "$ts" "$repo_escaped" "$LINES_CHANGED" "$SECTIONS_TOUCHED" \
    "$([[ "$CUSTODIAN_INVOKED" == "1" ]] && echo true || echo false)" \
    "${OUTPUT//\"/\\\"}" \
    >>"$AMBIENT_LOG" 2>/dev/null || true

echo "[arch-gen] OK $OUTPUT (lines_changed=$LINES_CHANGED sections_touched=$SECTIONS_TOUCHED)"
