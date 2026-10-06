#!/usr/bin/env bash
# INFRA-3614: yaml-only-pr-guard.sh refuses diffs that are only gap YAML mirrors.
set -uo pipefail
G="$(cd "$(dirname "$0")/../coord" && pwd)/yaml-only-pr-guard.sh"
fail=0
chk() { # name expected_rc input
    printf '%b' "$3" | bash "$G" - ; rc=$?
    if [[ $rc -eq $2 ]]; then echo "ok   $1"; else echo "FAIL $1 (rc=$rc want $2)"; fail=1; fi
}
chk yaml-only        1 'docs/gaps/INFRA-1.yaml\ndocs/gaps/ZERO-WASTE-020.yaml\n'
chk yaml-plus-code   0 'docs/gaps/INFRA-1.yaml\nsrc/main.rs\n'
chk code-only        0 'scripts/x.sh\n'
chk empty            0 ''
chk gaps-yaml-legacy 0 'docs/gaps.yaml\n'
printf 'docs/gaps/INFRA-1.yaml\n' | CHUMP_ALLOW_YAML_ONLY_PR=1 bash "$G" - && echo "ok   bypass" || { echo "FAIL bypass"; fail=1; }
exit $fail
