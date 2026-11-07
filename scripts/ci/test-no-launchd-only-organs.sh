#!/usr/bin/env bash
# INFRA-8188: proves check-no-launchd-only-organs.sh rejects launchd-only additions.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)/check-no-launchd-only-organs.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cd "$T"; git init -q -b main .; git config user.email t@t; git config user.name t
mkdir -p launchd scripts/dispatch scripts/ci
echo x > launchd/com.chump.old.plist; : > scripts/ci/launchd-only-exempt.txt
git add -A; git commit -qm base; git update-ref refs/remotes/origin/main HEAD
run() { LAUNCHD_GUARD_ROOT="$T" bash "$SRC" >/dev/null 2>&1; }

git checkout -qb feat
run || { echo "FAIL: no-change should pass"; exit 1; }

echo x > launchd/com.chump.newthing.plist; git add -A; git commit -qm add
if run; then echo "FAIL: launchd-only plist should be rejected"; exit 1; fi

echo x > scripts/dispatch/chump-newthing.service; git add -A; git commit -qm svc
run || { echo "FAIL: plist with systemd unit should pass"; exit 1; }

echo x > launchd/com.chump.other.plist; git add -A; git commit -qm other
if run; then echo "FAIL: second launchd-only plist should be rejected"; exit 1; fi
echo "com.chump.other.plist  # reason: test" >> scripts/ci/launchd-only-exempt.txt
git add -A; git commit -qm ex
run || { echo "FAIL: exempt plist should pass"; exit 1; }
echo "PASS: test-no-launchd-only-organs"
