#!/usr/bin/env bash
# check-broken-doc-links.sh — find relative markdown links in docs/, book/src/, and
# repo-root *.md whose targets do not exist on disk.
#
# Skips: external URLs (http:, https:, mailto:), in-page anchors (#…), and image
# alt-text variants (![…](…)) get the same treatment as text links.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cd "$REPO_ROOT"
log "scanning for broken relative markdown links..."

MD_LIST="$(mktemp)"
TMP="$(mktemp)"
trap 'rm -f "$MD_LIST" "$TMP"' EXIT
{ find . -maxdepth 1 -name '*.md' -type f; find docs book/src -name '*.md' -type f 2>/dev/null; } >"$MD_LIST" 2>/dev/null

python3 - "$MD_LIST" >"$TMP" <<'PY'
import os, re, sys

LINK_RE = re.compile(r'!?\[[^\]]*\]\(([^)\s]+?)(?:\s+"[^"]*")?\)')

def is_external(t):
    return t.startswith(('http:', 'https:', 'mailto:', 'tel:', '#'))

with open(sys.argv[1]) as f:
    md_files = [l.strip() for l in f if l.strip()]
for src in md_files:
    if not os.path.isfile(src):
        continue
    src_dir = os.path.dirname(src) or '.'
    with open(src, encoding='utf-8', errors='replace') as f:
        for i, line in enumerate(f, 1):
            for m in LINK_RE.finditer(line):
                target = m.group(1)
                if is_external(target):
                    continue
                target_clean = target.split('#', 1)[0]
                if not target_clean:
                    continue
                resolved = os.path.normpath(os.path.join(src_dir, target_clean))
                if not os.path.exists(resolved):
                    src_norm = src.lstrip('./')
                    print(f"{src_norm}|{i}|{target_clean}")
PY

count="$(wc -l <"$TMP" | awk '{print $1}')"
if [ "$count" -eq 0 ]; then
    log "broken-doc-links done (0 broken)."
    exit 0
fi

samples_json="$(head -10 "$TMP" | python3 -c '
import json, sys
out=[]
for line in sys.stdin:
    parts = line.strip().split("|", 2)
    if len(parts) == 3:
        out.append(f"{parts[0]}:{parts[1]} -> {parts[2]}")
print(json.dumps(out))
')"

key="BROKEN_DOC_LINKS_ROLLUP"
title="Broken markdown links: ${count} found"
desc="${count} relative markdown links across docs/, book/src/, and repo-root \*.md point to files that do not exist on disk. Readers hit 404s. Acceptance criteria: regenerate the list with \`scripts/audit/auditor-checks/check-broken-doc-links.sh\` and either fix each target, convert to plain text, or remove. Close this gap when count is < 10."
emit_finding "broken-doc-links" "$key" "$title" "$desc" "DOC" "P2" "m" "$samples_json"

log "broken-doc-links done (${count} broken, rolled up)."
