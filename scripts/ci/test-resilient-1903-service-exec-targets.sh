#!/usr/bin/env bash
# RESILIENT-1903: every __REPO_ROOT__ ExecStart script in scripts/dispatch/*.service must exist.
set -euo pipefail
cd "$(dirname "$0")/../.."
fail=0
for f in scripts/dispatch/*.service; do
  while read -r t; do
    [[ -e "$t" ]] || { echo "FAIL: $f ExecStart target missing: $t"; fail=1; }
  done < <(grep -E '^ExecStart=' "$f" | grep -oE '__REPO_ROOT__/scripts/[^ "]+' | sed "s#__REPO_ROOT__/##; s#'\$##")
done
[[ $fail -eq 0 ]] && echo "PASS: all service ExecStart targets exist"
exit $fail
