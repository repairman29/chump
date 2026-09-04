#!/usr/bin/env bash
# CREDIBLE-787: exercises scripts/ci/check-grep-target-sweep.py against both
# the real repo (must report zero missing targets, per AC4) and a synthetic
# fixture repo with a deliberately dangling grep target (must be detected).
set -uo pipefail

REAL_REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECKER="$REAL_REPO_ROOT/scripts/ci/check-grep-target-sweep.py"

pass=0
fail=0
declare -a errors=()

ok()   { pass=$((pass+1)); echo "  [ok] $1"; }
bad()  { fail=$((fail+1)); errors+=("$1"); echo "  [FAIL] $1"; }

echo "== test 1: real repo main — zero missing targets, exit 0 =="
out="$(REPO_ROOT="$REAL_REPO_ROOT" python3 "$CHECKER" --json)"
rc=$?
if [[ $rc -eq 0 ]]; then
  ok "exit code 0 on clean repo"
else
  bad "expected exit 0 on clean repo, got $rc"
fi
count="$(echo "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["missing_count"])' 2>/dev/null || echo "parse-error")"
if [[ "$count" == "0" ]]; then
  ok "missing_count is 0 on clean repo"
else
  bad "expected missing_count=0 on clean repo, got '$count'"
fi

echo "== test 2: synthetic fixture with a dangling grep target =="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts/ci"
cat > "$TMP/scripts/ci/test-fixture.sh" <<'EOF'
#!/usr/bin/env bash
if grep -q "some_marker" scripts/does/not/exist.rs; then
  echo "found"
fi
EOF

out2="$(REPO_ROOT="$TMP" python3 "$CHECKER" --json)"
rc2=$?
if [[ $rc2 -eq 1 ]]; then
  ok "exit code 1 when a dangling target exists"
else
  bad "expected exit 1 on fixture with dangling target, got $rc2"
fi
count2="$(echo "$out2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["missing_count"])' 2>/dev/null || echo "parse-error")"
if [[ "$count2" == "1" ]]; then
  ok "missing_count is 1 on fixture"
else
  bad "expected missing_count=1 on fixture, got '$count2'"
fi
if echo "$out2" | grep -q "scripts/does/not/exist.rs"; then
  ok "report names the missing target"
else
  bad "report did not name the missing target: $out2"
fi
if echo "$out2" | grep -q "test-fixture.sh"; then
  ok "report names the source file"
else
  bad "report did not name the source file: $out2"
fi

echo "== test 3: synthetic fixture with a satisfied grep target =="
TMP2="$(mktemp -d)"
mkdir -p "$TMP2/scripts/ci" "$TMP2/scripts/coord"
touch "$TMP2/scripts/coord/real-file.sh"
cat > "$TMP2/scripts/ci/test-fixture-ok.sh" <<'EOF'
#!/usr/bin/env bash
if grep -q "marker" scripts/coord/real-file.sh; then
  echo "found"
fi
EOF
out3="$(REPO_ROOT="$TMP2" python3 "$CHECKER" --json)"
rc3=$?
rm -rf "$TMP2"
if [[ $rc3 -eq 0 ]]; then
  ok "exit code 0 when target exists"
else
  bad "expected exit 0 when target exists, got $rc3"
fi

echo
echo "pass=$pass fail=$fail"
if [[ $fail -gt 0 ]]; then
  printf 'FAILED: %s\n' "${errors[@]}"
  exit 1
fi
exit 0
