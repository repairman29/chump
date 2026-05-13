#!/usr/bin/env bash
# test-markdown-intra-doc-links.sh — DOC-039
#
# Validates that intra-doc markdown links point at files that exist.
# Catches the failure class repaired in PR #1645 (52 broken links across
# docs/README.md after a directory reshuffle).
#
# **Default behaviour: PR-scoped.** Only checks markdown files modified in
# the current PR (vs. origin/main). This is what runs as a blocking CI
# gate. Prevents regression without forcing a one-shot cleanup of the
# 492 pre-existing broken links across docs/syntheses/ etc.
#
# **Full-repo mode:** `--all` flag scans every doc. Used for the
# audit-run (scripts/audit/run-all.sh) which is informational. Surfaces
# the backfill scope without blocking merges.
#
# Scope (always):
#   - docs/**/*.md
#   - README.md, AGENTS.md, CLAUDE.md, CONTRIBUTING.md
#   - book/src/**/*.md
#
# Checks:
#   - Relative markdown links [text](path) and [text](path#anchor)
#   - Resolves relative to the markdown file's directory
#   - Strips ?query and #anchor fragments before existence check
#
# Skips:
#   - External URLs (http://, https://, mailto:, ftp://)
#   - Pure anchor links (#section-name)
#   - Code-fenced blocks (links inside ``` ... ``` are documentation)
#   - Image links (![alt](src))
#
# Exit: 0 if all in-scope links resolve, 1 if any are broken.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

MODE="changed"
BASE_BRANCH="${GITHUB_BASE_REF:-main}"
for arg in "$@"; do
    case "$arg" in
        --all) MODE="all" ;;
        --changed) MODE="changed" ;;
        --base) ;;  # consumed below
    esac
done
# --base <branch>
i=0
for arg in "$@"; do
    if [[ "$arg" == "--base" ]]; then
        i=$((i + 1))
        eval "BASE_BRANCH=\${$((i + 1)):-$BASE_BRANCH}"
    fi
    i=$((i + 1))
done

CHANGED_FILES_LIST=""
if [[ "$MODE" == "changed" ]]; then
    if git rev-parse --verify "origin/${BASE_BRANCH}" >/dev/null 2>&1; then
        CHANGED_FILES_LIST="$(git diff --name-only --diff-filter=AM "origin/${BASE_BRANCH}...HEAD" 2>/dev/null || true)"
    elif git rev-parse --verify "${BASE_BRANCH}" >/dev/null 2>&1; then
        CHANGED_FILES_LIST="$(git diff --name-only --diff-filter=AM "${BASE_BRANCH}...HEAD" 2>/dev/null || true)"
    fi
fi

export MODE CHANGED_FILES_LIST
python3 - <<'PYEOF'
import os
import re
import sys

REPO = os.getcwd()
MODE = os.environ.get("MODE", "changed")
CHANGED_RAW = os.environ.get("CHANGED_FILES_LIST", "")

# Files to scan (always considered "in scope" for existence; what we
# actually LINT vs. just resolve is decided per-mode below).
SCAN_GLOBS = [
    "README.md",
    "AGENTS.md",
    "CLAUDE.md",
    "CONTRIBUTING.md",
]

def find_md_files():
    files = list(SCAN_GLOBS)
    for root in ("docs", "book/src"):
        if not os.path.isdir(root):
            continue
        for d, _, fns in os.walk(root):
            for fn in fns:
                if fn.endswith(".md"):
                    files.append(os.path.join(d, fn))
    return [f for f in files if os.path.exists(f)]

all_md = find_md_files()

if MODE == "changed":
    changed = set(p for p in CHANGED_RAW.splitlines() if p.endswith(".md"))
    in_scope = [f for f in all_md if f in changed]
    if not in_scope:
        print("=== DOC-039: no .md files changed in this PR — skipping link check ===")
        sys.exit(0)
else:
    in_scope = all_md

LINK_RE = re.compile(r"(?<!\!)\[([^\]]+)\]\(([^)]+)\)")
CODE_FENCE_RE = re.compile(r"^```")
EXTERNAL_PREFIXES = ("http://", "https://", "mailto:", "ftp://", "tel:")

def strip_code_blocks(text):
    out = []
    in_fence = False
    for line in text.split("\n"):
        if CODE_FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if not in_fence:
            out.append(line)
    return "\n".join(out)

broken = []
total_links = 0

for md_file in in_scope:
    try:
        body = open(md_file, encoding="utf-8", errors="replace").read()
    except OSError as e:
        broken.append((md_file, "<self>", f"cannot read: {e}"))
        continue
    body = strip_code_blocks(body)
    base = os.path.dirname(md_file)
    for m in LINK_RE.finditer(body):
        href = m.group(2).strip()
        total_links += 1
        if href.startswith(EXTERNAL_PREFIXES) or href.startswith("#"):
            continue
        if href.startswith("<") and href.endswith(">"):
            href = href[1:-1]
        href_path = href.split("?", 1)[0].split("#", 1)[0]
        if not href_path:
            continue
        target = os.path.normpath(os.path.join(base, href_path))
        if not os.path.exists(target):
            broken.append((md_file, href, target))

if broken:
    scope_str = "changed-only" if MODE == "changed" else "full-repo"
    print(f"=== DOC-039: {len(broken)} broken intra-doc link(s) [{scope_str}] ===\n")
    by_file = {}
    for md, href, target in broken:
        by_file.setdefault(md, []).append((href, target))
    for md in sorted(by_file):
        print(f"\n{md}:")
        for href, target in by_file[md]:
            print(f"  → {href}")
            print(f"     resolves to: {target} (not found)")
    print(f"\nScanned {total_links} links across {len(in_scope)} files; {len(broken)} broken.")
    sys.exit(1)

scope_str = "changed-only" if MODE == "changed" else "full-repo"
print(f"=== DOC-039: all {total_links} intra-doc links resolve [{scope_str}, {len(in_scope)} files] ===")
sys.exit(0)
PYEOF
