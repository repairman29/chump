#!/usr/bin/env bash
# scripts/ci/test-public-doc-privacy.sh — DOC-050 + PRODUCT-375
#
# Enforces two public-documentation hygiene contracts:
#
# 1. DOC-050 (RESEARCH_INTEGRITY.md:28-29) over docs/strategy/ and docs/product/:
#    Blocks empirical benchmark magnitudes, versioned eval model names, and
#    per-eval COG-NN / EVAL-NN IDs unless exempted with
#    '<!-- research-privacy-exempt: <reason> -->'.
#
# 2. PRODUCT-375 (Public v1.0 Surface Sanitization & Allowlist Gate):
#    - Verifies mkdocs.yml does NOT use 'awesome-pages' and enforces a root
#      allowlist ('*' first under exclude_docs).
#    - Scans every page in mkdocs.yml nav:, web/site/**/*.html, README.md,
#      CONTRIBUTING.md, and .env.example for private hostnames (helsinki,
#      closetjunky, beast-mode), Tailscale CGNAT IPs (100.64.0.0/10), personal
#      home paths (/Users/jeff*, /home/jeff*), personal bot/companion names
#      (mabel, farmer-brown, ask_jeff), and retired pre-v1.0 shell scripts
#      (run-discord.sh, bot-merge.sh, gap-claim.sh, env-max_m4.sh).
#    - Verifies every mkdocs.yml nav: page carries a fresh 'last_audited:'
#      frontmatter date (<= 90 days old).
#
# Exit: 0 = clean, 1 = at least one violation found

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ------------------------------------------------------------------------------
# Part 1: DOC-050 — RESEARCH_INTEGRITY.md scan over strategy & product docs
# ------------------------------------------------------------------------------
SCAN_PATHS=(
    "$REPO_ROOT/docs/strategy"
    "$REPO_ROOT/docs/product"
)

declare -a PATTERNS=(
    'specific_pp_delta|[+-]0\.[0-9]+ ?(pp|percentage point|absolute rate)|+0.14 pp'
    'sample_size|\b[nN] ?= ?[0-9]+\b|n=100'
    'wilson_ci_specific|±0\.[0-9]+|±0.22'
    'model_haiku|\bhaiku-[0-9]+(-[0-9]+)?\b|haiku-4-5'
    'model_opus|\bopus-[0-9]+(-[0-9]+)?\b|opus-4-5'
    'model_sonnet|\bsonnet-[0-9]+(-[0-9]+)?\b|sonnet-4-5'
    'model_claude_versioned|\bclaude-[0-9]+(\.[0-9]+)?(-[a-z]+)?\b|claude-3-opus'
    'model_qwen|\bqwen[0-9]+(\.[0-9]+)?(:[0-9]+b?)?\b|qwen2.5:14b'
    'model_llama|\bllama-?[0-9]+(\.[0-9]+)?\b|llama-3'
    'per_eval_cog|\bCOG-[0-9]+\b|COG-014'
    'per_eval_eval|\bEVAL-[0-9]+\b|EVAL-010'
)

violations=0
files_scanned=0

for scan_root in "${SCAN_PATHS[@]}"; do
    [[ -d "$scan_root" ]] || continue
    while IFS= read -r -d '' md; do
        files_scanned=$((files_scanned + 1))
        if grep -q -- '<!-- research-privacy-exempt:' "$md" 2>/dev/null; then
            continue
        fi
        for spec in "${PATTERNS[@]}"; do
            IFS='|' read -r name regex example <<< "$spec"
            if hits="$(grep -nE -- "$regex" "$md" 2>/dev/null)"; then
                rel="${md#"$REPO_ROOT/"}"
                while IFS= read -r line; do
                    echo "VIOLATION $name in $rel: $line"
                    violations=$((violations + 1))
                done <<< "$hits"
            fi
        done
    done < <(find "$scan_root" -type f -name '*.md' -print0)
done

if [[ $files_scanned -eq 0 ]]; then
    echo "FAIL DOC-050: no markdown files found in scan paths (regression in repo layout?)"
    exit 1
fi

if [[ $violations -gt 0 ]]; then
    echo ""
    echo "FAIL DOC-050: $violations RESEARCH_INTEGRITY.md violation(s) in $files_scanned scanned file(s)"
    echo "  Reference: docs/process/RESEARCH_INTEGRITY.md:28-29"
    echo "  Fix: move specifics to the private companion repo (chump-proprietary), or"
    echo "       add '<!-- research-privacy-exempt: <reason> -->' to the file if intentional"
    exit 1
fi

echo "OK DOC-050: $files_scanned research/strategy docs scanned, 0 RESEARCH_INTEGRITY violations"

# ------------------------------------------------------------------------------
# Part 2: PRODUCT-375 — Public v1.0 Surface Allowlist, Privacy & Freshness Gate
# ------------------------------------------------------------------------------
REPO_ROOT="$REPO_ROOT" python3 - <<'PYEOF'
import os
import re
import sys
from datetime import datetime, timezone

repo = os.environ["REPO_ROOT"]
mkdocs_path = os.path.join(repo, "mkdocs.yml")

if not os.path.isfile(mkdocs_path):
    print("FAIL PRODUCT-375: mkdocs.yml missing", file=sys.stderr)
    sys.exit(1)

mkdocs_raw = open(mkdocs_path, encoding="utf-8").read()

if re.search(r"^\s*-\s*awesome-pages\b", mkdocs_raw, re.M):
    print("FAIL PRODUCT-375: mkdocs.yml must not enable 'awesome-pages' (exposes internal docs/)", file=sys.stderr)
    sys.exit(1)

if not re.search(r"exclude_docs:\s*\|\s*\n\s*\*\s*\n", mkdocs_raw):
    print("FAIL PRODUCT-375: mkdocs.yml exclude_docs must begin with '*' default-deny allowlist", file=sys.stderr)
    sys.exit(1)

# Parse nav: markdown targets from mkdocs.yml
in_nav = False
nav_docs = []
for line in mkdocs_raw.splitlines():
    if re.match(r"^nav:\s*$", line):
        in_nav = True
        continue
    if in_nav and re.match(r"^[a-zA-Z0-9_-]+:", line):
        in_nav = False
        continue
    if in_nav:
        m = re.search(r":\s*([A-Za-z0-9_./-]+\.md)\s*$", line)
        if m:
            nav_docs.append(os.path.join(repo, "docs", m.group(1)))

if len(nav_docs) < 10:
    print(f"FAIL PRODUCT-375: expected >=10 curated pages in mkdocs.yml nav:, found {len(nav_docs)}", file=sys.stderr)
    sys.exit(1)

public_files = list(nav_docs)
for root_file in ("README.md", "CONTRIBUTING.md", ".env.example"):
    p = os.path.join(repo, root_file)
    if os.path.isfile(p):
        public_files.append(p)

web_site_dir = os.path.join(repo, "web", "site")
if os.path.isdir(web_site_dir):
    for d, _, fns in os.walk(web_site_dir):
        for fn in fns:
            if fn.endswith((".html", ".js")):
                public_files.append(os.path.join(d, fn))

LEAK_RULES = [
    ("private_hostname_helsinki", re.compile(r"\bhelsinki\b", re.I)),
    ("private_hostname_closetjunky", re.compile(r"\bclosetjunky\b", re.I)),
    ("private_repo_beast_mode", re.compile(r"\bbeast-mode\b", re.I)),
    ("tailscale_cgnat_ip", re.compile(r"\b100\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b")),
    ("personal_user_path", re.compile(r"(?:/Users/jeff[a-z0-9_-]*|/home/jeff[a-z0-9_-]*)", re.I)),
    ("personal_companion_mabel", re.compile(r"\bmabel\b", re.I)),
    ("personal_watchdog_farmer_brown", re.compile(r"farmer[- ]brown", re.I)),
    ("personal_tool_ask_jeff", re.compile(r"\bask_jeff\b", re.I)),
    ("retired_script_run_discord", re.compile(r"run-discord(?:-full)?\.sh")),
    ("retired_script_bot_merge", re.compile(r"\bbot-merge\.sh\b")),
    ("retired_script_gap_claim", re.compile(r"\bgap-claim\.sh\b")),
    ("retired_script_env_max_m4", re.compile(r"env-max_m4\.sh")),
]

leak_errors = []
now = datetime.now(timezone.utc)

for fpath in public_files:
    rel = os.path.relpath(fpath, repo)
    if not os.path.isfile(fpath):
        leak_errors.append(f"MISSING nav/public file: {rel}")
        continue
    text = open(fpath, encoding="utf-8", errors="replace").read()
    for lineno, line in enumerate(text.splitlines(), 1):
        for rule_name, rx in LEAK_RULES:
            if rx.search(line):
                leak_errors.append(f"LEAK [{rule_name}] {rel}:{lineno}: {line.strip()[:120]}")

# Enforce last_audited <= 90 days on all curated mkdocs.yml nav: pages
for fpath in nav_docs:
    rel = os.path.relpath(fpath, repo)
    head = open(fpath, encoding="utf-8", errors="replace").read(1024)
    m = re.search(r"^last_audited:\s*['\"]?(\d{4}-\d{2}-\d{2})['\"]?", head, re.M)
    if not m:
        leak_errors.append(f"STALE [missing last_audited frontmatter] {rel}")
        continue
    dt = datetime.strptime(m.group(1), "%Y-%m-%d").replace(tzinfo=timezone.utc)
    age_days = (now - dt).days
    if age_days > 90:
        leak_errors.append(f"STALE [last_audited {m.group(1)} is {age_days}d > 90d] {rel}")

if leak_errors:
    for err in leak_errors:
        print(err, file=sys.stderr)
    print(f"\nFAIL PRODUCT-375: {len(leak_errors)} public-surface privacy/freshness issue(s) across {len(public_files)} files", file=sys.stderr)
    sys.exit(1)

print(f"OK PRODUCT-375: {len(public_files)} public surface files ({len(nav_docs)} MkDocs nav pages) clean & fresh (<=90d)")
PYEOF
