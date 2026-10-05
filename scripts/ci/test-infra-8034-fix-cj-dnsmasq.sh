#!/usr/bin/env bash
# test-infra-8034-fix-cj-dnsmasq.sh — INFRA-8034
#
# Proves scripts/ops/fix-cj-dnsmasq.sh:
#   1. no-ops cleanly when dnsmasq.service isn't installed on the node;
#   2. no-ops cleanly when dnsmasq.service is installed but not failed;
#   3. disables+masks+reset-failed when dnsmasq.service IS failed (via sudo);
#   4. --dry-run never calls sudo/systemctl mutating verbs;
#   5. prints manual instructions (and exits non-zero) when sudo can't
#      self-elevate and there's no interactive terminal.
#
# Runs entirely against stubbed systemctl/sudo on PATH — no live systemd or
# root needed, safe on any CI runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/ops/fix-cj-dnsmasq.sh"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f "$TARGET" ]] || fail "missing $TARGET"

TMP="$(mktemp -d -t test-fix-cj-dnsmasq-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"

write_stub_systemctl() {
    # $1 = is-failed output, $2 = is-enabled output, $3 = CALL_LOG path
    local is_failed="$1" is_enabled="$2" call_log="$3"
    cat > "$STUB_BIN/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$call_log"
case "\$*" in
    "list-unit-files dnsmasq.service") echo "dnsmasq.service enabled"; exit 0 ;;
    "is-failed dnsmasq.service") echo "$is_failed"; exit 0 ;;
    "is-enabled dnsmasq.service") echo "$is_enabled"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$STUB_BIN/systemctl"
}

write_stub_sudo() {
    # $1 = CALL_LOG path, $2 = "ok" (sudo -n true succeeds) or "noninteractive"
    local call_log="$1" mode="$2"
    cat > "$STUB_BIN/sudo" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-n" && "\$2" == "true" ]]; then
    [[ "$mode" == "ok" ]] && exit 0 || exit 1
fi
echo "sudo \$*" >> "$call_log"
exit 0
EOF
    chmod +x "$STUB_BIN/sudo"
}

# ── 1. dnsmasq.service not installed → clean no-op ──────────────────────────
CALL_LOG="$TMP/calls1.log"; : > "$CALL_LOG"
cat > "$STUB_BIN/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$CALL_LOG"
exit 1
EOF
chmod +x "$STUB_BIN/systemctl"
OUT="$(PATH="$STUB_BIN:$PATH" bash "$TARGET")" || fail "exited non-zero when unit not installed: $OUT"
printf '%s' "$OUT" | grep -q "not installed" || fail "did not report 'not installed' when unit absent"
pass "no-ops cleanly when dnsmasq.service is not installed on the node"

# ── 2. installed, not failed → clean no-op ──────────────────────────────────
CALL_LOG="$TMP/calls2.log"; : > "$CALL_LOG"
write_stub_systemctl "active" "enabled" "$CALL_LOG"
OUT="$(PATH="$STUB_BIN:$PATH" bash "$TARGET")" || fail "exited non-zero when unit not failed: $OUT"
printf '%s' "$OUT" | grep -q "not in failed state" || fail "did not report not-failed when is-failed=active"
grep -q "disable" "$CALL_LOG" && fail "called disable on a non-failed unit"
pass "no-ops cleanly when dnsmasq.service is installed but not failed"

# ── 3. failed + sudo -n works → disables+masks+reset-failed ─────────────────
CALL_LOG="$TMP/calls3.log"; : > "$CALL_LOG"
write_stub_systemctl "failed" "enabled" "$CALL_LOG"
write_stub_sudo "$CALL_LOG" "ok"
OUT="$(PATH="$STUB_BIN:$PATH" bash "$TARGET")" || fail "exited non-zero on the fix path: $OUT"
grep -q "sudo.*systemctl disable --now dnsmasq.service" "$CALL_LOG" || fail "did not disable --now dnsmasq.service via sudo"
grep -q "sudo.*systemctl mask dnsmasq.service" "$CALL_LOG" || fail "did not mask dnsmasq.service via sudo"
grep -q "sudo.*systemctl reset-failed dnsmasq.service" "$CALL_LOG" || fail "did not reset-failed dnsmasq.service via sudo"
pass "failed unit gets disable --now + mask + reset-failed via passwordless sudo"

# ── 4. --dry-run never mutates ───────────────────────────────────────────────
CALL_LOG="$TMP/calls4.log"; : > "$CALL_LOG"
write_stub_systemctl "failed" "enabled" "$CALL_LOG"
write_stub_sudo "$CALL_LOG" "ok"
OUT="$(PATH="$STUB_BIN:$PATH" bash "$TARGET" --dry-run)" || fail "exited non-zero on --dry-run: $OUT"
printf '%s' "$OUT" | grep -q '\[dry-run\]' || fail "--dry-run did not print [dry-run] markers"
grep -q "^sudo" "$CALL_LOG" && fail "--dry-run invoked sudo: $(cat "$CALL_LOG")"
pass "--dry-run never calls sudo (pure preview)"

# ── 5. failed + no passwordless sudo + non-interactive → manual instructions ─
CALL_LOG="$TMP/calls5.log"; : > "$CALL_LOG"
write_stub_systemctl "failed" "enabled" "$CALL_LOG"
write_stub_sudo "$CALL_LOG" "noninteractive"
set +e
OUT="$(PATH="$STUB_BIN:$PATH" bash "$TARGET" < /dev/null 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 ]] || fail "expected non-zero exit when sudo can't self-elevate non-interactively"
printf '%s' "$OUT" | grep -q "sudo systemctl disable --now dnsmasq.service" || fail "did not print manual fix instructions"
[[ -s "$CALL_LOG" ]] && grep -q "disable" "$CALL_LOG" && fail "mutated state despite no sudo access: $(cat "$CALL_LOG")"
pass "prints manual operator instructions + exits non-zero when sudo can't self-elevate non-interactively"

echo "ALL PASS"
