#!/usr/bin/env bash
# Regression test for scripts/coord/subprocess-auth-smoke.sh (INFRA-2354).
# Stubs `claude` on PATH so the test runs offline + fast; exercises OK, DEAD
# (non-zero exit / no PONG), and PATH-absent branches, plus the ambient emit.
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF/../.." && pwd)"
SCRIPT="$ROOT/scripts/coord/subprocess-auth-smoke.sh"
[[ -x "$SCRIPT" ]] || { echo "[test] FAIL: subprocess-auth-smoke.sh not executable"; exit 1; }
[[ "$(bash -n "$SCRIPT" 2>&1)" == "" ]] || { echo "[test] FAIL: syntax error"; exit 1; }

fail=0

make_stub_dir() {
  local mode="$1" stub_dir
  stub_dir="$(mktemp -d)"
  case "$mode" in
    ok)
      cat > "$stub_dir/claude" <<'STUB'
#!/usr/bin/env bash
echo "PONG"
exit 0
STUB
      ;;
    dead-exit)
      cat > "$stub_dir/claude" <<'STUB'
#!/usr/bin/env bash
echo "error: 401 unauthorized" >&2
exit 1
STUB
      ;;
    dead-no-pong)
      cat > "$stub_dir/claude" <<'STUB'
#!/usr/bin/env bash
echo "some other output"
exit 0
STUB
      ;;
  esac
  chmod +x "$stub_dir/claude" 2>/dev/null || true
  printf '%s' "$stub_dir"
}

check() {
  local desc="$1" mode="$2" eexit="$3" esub="$4"
  local ambient rc out stub_dir
  ambient="$(mktemp -t smoke-ambient.XXXXXX)"
  if [[ "$mode" == "absent" ]]; then
    # Strip only the claude binary's directory from PATH so bash/timeout/etc
    # stay resolvable but `command -v claude` genuinely misses.
    local claude_dirs stripped_path bash_bin
    bash_bin="$(command -v bash)"
    claude_dirs="$(for d in $(printf '%s' "$PATH" | tr ':' '\n'); do [[ -x "$d/claude" ]] && echo "$d"; done)"
    stripped_path="$(printf '%s' "$PATH" | tr ':' '\n' | grep -vFxf <(printf '%s\n' "$claude_dirs") | paste -sd: -)"
    out="$(CHUMP_SUBPROC_SMOKE_AMBIENT="$ambient" PATH="$stripped_path" "$bash_bin" "$SCRIPT" 2>&1)"
    rc=$?
  else
    stub_dir="$(make_stub_dir "$mode")"
    out="$(CHUMP_SUBPROC_SMOKE_AMBIENT="$ambient" PATH="$stub_dir:$PATH" \
        CHUMP_SUBPROC_SMOKE_TIMEOUT_S=5 bash "$SCRIPT" 2>&1)"
    rc=$?
    rm -rf "$stub_dir"
  fi
  if [[ "$rc" == "$eexit" ]] && printf '%s' "$out" | grep -qF "$esub"; then
    echo "[test] PASS: $desc (exit $rc)"
  else
    echo "[test] FAIL: $desc — want exit=$eexit substr='$esub', got exit=$rc: $out"; fail=1
  fi
  rm -f "$ambient"
}

check "claude -p returns PONG -> OK"           ok           0 "SUBPROCESS-AUTH ✓ OK"
check "claude -p non-zero exit -> DEAD"        dead-exit    1 "SUBPROCESS-AUTH ✗ DEAD"
check "claude -p no PONG -> DEAD"              dead-no-pong 1 "SUBPROCESS-AUTH ✗ DEAD"
check "claude not on PATH -> DEAD"             absent       1 "claude CLI not found"

# ── ambient emit shape ───────────────────────────────────────────────────────
ambient="$(mktemp -t smoke-ambient.XXXXXX)"
stub_dir="$(make_stub_dir ok)"
CHUMP_SUBPROC_SMOKE_AMBIENT="$ambient" PATH="$stub_dir:$PATH" CHUMP_SUBPROC_SMOKE_TIMEOUT_S=5 \
    bash "$SCRIPT" --quiet >/dev/null 2>&1
if grep -q '"kind":"subprocess_auth_ok"' "$ambient" && grep -q '"claude_p_exit_code":0' "$ambient"; then
  echo "[test] PASS: subprocess_auth_ok ambient event emitted with claude_p_exit_code"
else
  echo "[test] FAIL: expected subprocess_auth_ok ambient event; got: $(cat "$ambient")"; fail=1
fi
rm -rf "$stub_dir" "$ambient"

ambient="$(mktemp -t smoke-ambient.XXXXXX)"
stub_dir="$(make_stub_dir dead-exit)"
CHUMP_SUBPROC_SMOKE_AMBIENT="$ambient" PATH="$stub_dir:$PATH" CHUMP_SUBPROC_SMOKE_TIMEOUT_S=5 \
    bash "$SCRIPT" --quiet >/dev/null 2>&1
if grep -q '"kind":"subprocess_auth_dead"' "$ambient" && grep -q '"claude_p_exit_code":1' "$ambient"; then
  echo "[test] PASS: subprocess_auth_dead ambient event emitted with claude_p_exit_code"
else
  echo "[test] FAIL: expected subprocess_auth_dead ambient event; got: $(cat "$ambient")"; fail=1
fi
rm -rf "$stub_dir" "$ambient"

if [[ "$fail" -eq 0 ]]; then
  echo "[test] ALL PASS"
  exit 0
else
  echo "[test] SOME FAILED"
  exit 1
fi
