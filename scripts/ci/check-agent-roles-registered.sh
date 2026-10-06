#!/usr/bin/env bash
# check-agent-roles-registered.sh — RESILIENT-1528
#
# Static PR-time companion to the runtime role validation in `chump claim`
# (INFRA-5773): every role passed to `chump claim ... --role X` in scripts/
# must be registered in docs/process/AGENT_ROLES.yaml. INFRA-5773 shipped the
# runtime check without registering `fleet-test`, which turned main red until
# #5146; this gate makes that omission impossible to merge.
#
# A "usage" is a line in scripts/**/*.{sh,py} that mentions `claim` (or the
# `_claim_extra` flag-builder) and passes a literal `--role <name>`. Roles taken
# from variables ($ROLE) or placeholders (<role>) are not checkable and ignored.
# Intentional negative-test roles are allowlisted (NEGATIVE_ROLES below, or
# CHECK_AGENT_ROLES_NEGATIVE="a b" in the environment).
#
# Usage: bash scripts/ci/check-agent-roles-registered.sh [--list]
#   --list   print every positive-path role usage (file:line role) and exit 0
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
REGISTRY="${CHECK_AGENT_ROLES_REGISTRY:-docs/process/AGENT_ROLES.yaml}"
SCAN_DIR="${CHECK_AGENT_ROLES_SCAN_DIR:-scripts}"
NEGATIVE_ROLES="bogus ${CHECK_AGENT_ROLES_NEGATIVE:-}"

[[ -f "$REGISTRY" ]] || { echo "FAIL: registry $REGISTRY not found"; exit 1; }
registered="$(sed -nE 's/^[[:space:]]*-[[:space:]]+name:[[:space:]]*"?([A-Za-z0-9._-]+)"?[[:space:]]*$/\1/p' "$REGISTRY")"
[[ -n "$registered" ]] || { echo "FAIL: no roles parsed from $REGISTRY"; exit 1; }

# Scan with python so backslash line-continuations are joined (a `chump claim
# ... \` command often carries --role on a continuation line) and comment lines
# are skipped.
list="$(SCAN_DIR="$SCAN_DIR" SELF="$(basename "${BASH_SOURCE[0]}")" python3 - <<'PY'
import os, re
ROLE = re.compile(r"--role[ =]+[\"']?([a-z][a-z0-9_-]*)")
CLAIM = re.compile(r"(^|[^A-Za-z0-9_-])claim([^A-Za-z0-9_-]|$)|_claim_extra")
for root, _, files in os.walk(os.environ["SCAN_DIR"]):
    for fn in sorted(files):
        if not fn.endswith((".sh", ".py")) or fn in (os.environ["SELF"], "test-" + os.environ["SELF"]):
            continue
        path = os.path.join(root, fn)
        try:
            lines = open(path, errors="replace").read().split("\n")
        except OSError:
            continue
        i = 0
        while i < len(lines):
            start, buf = i, lines[i]
            while buf.rstrip().endswith("\\") and i + 1 < len(lines):
                i += 1
                buf = buf.rstrip()[:-1] + " " + lines[i]
            i += 1
            if buf.lstrip().startswith("#"):
                continue
            if CLAIM.search(buf):
                for m in ROLE.finditer(buf):
                    print(f"{path}:{start + 1} {m.group(1)}")
PY
)"
[[ -n "$list" ]] && list+=$'\n'

if [[ "${1:-}" == "--list" ]]; then printf '%s' "$list"; exit 0; fi

bad=0
while read -r loc role; do
    [[ -z "$role" ]] && continue
    for n in $NEGATIVE_ROLES; do [[ "$role" == "$n" ]] && continue 2; done
    if ! grep -qxF "$role" <<<"$registered"; then
        echo "UNREGISTERED role '$role' used at $loc — add it to $REGISTRY in the same PR (or allowlist it as a negative-test role)"
        bad=$((bad + 1))
    fi
done <<<"$list"

total="$(printf '%s' "$list" | grep -c . || true)"
if [[ "$bad" -gt 0 ]]; then
    echo "FAIL: $bad unregistered role usage(s) (of $total checked)"; exit 1
fi
echo "OK: all $total role usage(s) in $SCAN_DIR/ are registered in $REGISTRY"
