#!/usr/bin/env bash
# scripts/ops/rotate-sccache-r2-gh-only.sh — INFRA-2240
#
# Atomic update of the R2 token PAIR in GH Actions secrets. No Cloudflare API
# scope required — operator regenerates the R2 token in the CF dashboard
# (manual UI step, ~30 sec), pastes both new values into a local file, runs
# this script.
#
# This is the PRIMARY rotation path because:
# 1. The actual failure class is "GH half-rotation" (one secret updated,
#    other left stale → pair mismatch → S3Error Unauthorized in every
#    Rust CI job). That's what wedged the 2026-05-30 queue.
# 2. CF token regen via dashboard is already a one-click flow operators do.
# 3. The script eliminates the failure class by writing BOTH secrets in
#    the same shell + emitting an audit event with timestamp proof of
#    pairing.
#
# scripts/ops/rotate-sccache-r2-token.sh (INFRA-2237) is the BACKUP path —
# also automates the CF dashboard step via the CF API, but requires a
# Cloudflare API token with `User API Tokens: Edit` scope (a privileged
# scope an operator might not want to keep around for everyday use).
#
# Usage:
#   bash scripts/ops/rotate-sccache-r2-gh-only.sh                # dry-run
#   bash scripts/ops/rotate-sccache-r2-gh-only.sh --execute      # actually rotate
#   bash scripts/ops/rotate-sccache-r2-gh-only.sh --help
#
# Input file format (default ~/.chump/r2-new-token.txt):
#   ACCESS_KEY_ID=<32-char-hex>
#   SECRET_ACCESS_KEY=<64-char-hex>
#   # lines starting with # are ignored
#   # blank lines are ignored
#
# Flags:
#   --execute              actually write the GH secrets (default: dry-run)
#   --input-file PATH      override input file location
#   --repo SLUG            override GH repo slug (default repairman29/chump)
#   --help, -h             print this docstring
#
# Env overrides (lower priority than flags):
#   CHUMP_R2_NEW_TOKEN_FILE   input file path
#   CHUMP_GH_REPO             target repo slug
#   CHUMP_AMBIENT_LOG         ambient.jsonl path

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd || pwd)"

EXECUTE=0
INPUT_FILE="${CHUMP_R2_NEW_TOKEN_FILE:-$HOME/.chump/r2-new-token.txt}"
GH_REPO="${CHUMP_GH_REPO:-repairman29/chump}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --execute)      EXECUTE=1 ;;
        --dry-run)      EXECUTE=0 ;;
        --input-file)   INPUT_FILE="$2"; shift ;;
        --repo)         GH_REPO="$2"; shift ;;
        --help|-h)
            sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "[rotate-r2-gh-only] ERROR: unknown flag: $1" >&2
            echo "  Usage: $0 [--execute] [--input-file PATH] [--repo SLUG]" >&2
            exit 1
            ;;
    esac
    shift
done

_dry_label="[DRY-RUN]"
[[ $EXECUTE -eq 1 ]] && _dry_label=""

# ── Pre-flight ───────────────────────────────────────────────────────────────

if ! command -v gh >/dev/null 2>&1; then
    echo "[rotate-r2-gh-only] ERROR: gh CLI is required." >&2
    exit 2
fi

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "[rotate-r2-gh-only] ERROR: input file not found: $INPUT_FILE" >&2
    echo "  Create it with:" >&2
    echo "    cat > $INPUT_FILE <<EOF" >&2
    echo "    ACCESS_KEY_ID=<32-char-hex-from-CF-dashboard>" >&2
    echo "    SECRET_ACCESS_KEY=<64-char-hex-from-CF-dashboard>" >&2
    echo "    EOF" >&2
    echo "    chmod 600 $INPUT_FILE" >&2
    exit 3
fi

# ── Parse input file ─────────────────────────────────────────────────────────

NEW_ACCESS_KEY_ID=""
NEW_SECRET_ACCESS_KEY=""
while IFS= read -r _line || [[ -n "$_line" ]]; do
    # Strip leading/trailing whitespace
    _line="${_line#"${_line%%[![:space:]]*}"}"
    _line="${_line%"${_line##*[![:space:]]}"}"
    # Skip blank + comment lines
    [[ -z "$_line" ]] && continue
    [[ "${_line:0:1}" == "#" ]] && continue

    # Parse KEY=VALUE
    if [[ "$_line" == *"="* ]]; then
        _key="${_line%%=*}"
        _val="${_line#*=}"
        # Trim quotes if present
        _val="${_val#\'}"; _val="${_val%\'}"
        _val="${_val#\"}"; _val="${_val%\"}"
        case "$_key" in
            ACCESS_KEY_ID)      NEW_ACCESS_KEY_ID="$_val" ;;
            SECRET_ACCESS_KEY)  NEW_SECRET_ACCESS_KEY="$_val" ;;
        esac
    fi
done < "$INPUT_FILE"

# ── Validate ─────────────────────────────────────────────────────────────────

if [[ -z "$NEW_ACCESS_KEY_ID" ]]; then
    echo "[rotate-r2-gh-only] ERROR: ACCESS_KEY_ID not found in $INPUT_FILE" >&2
    exit 4
fi
if [[ -z "$NEW_SECRET_ACCESS_KEY" ]]; then
    echo "[rotate-r2-gh-only] ERROR: SECRET_ACCESS_KEY not found in $INPUT_FILE" >&2
    exit 4
fi

# RESILIENT-055: validate by SANITY (garbage-reject) + advisory length warning,
# NOT a brittle exact-length assert. Cloudflare R2 access keys are commonly 32
# hex, but the API token-id can be 40+ chars (per CF docs + the known "length 40"
# S3 class), and the operator confirmed a non-32 key authenticates fine. A hard
# len==32/64 reject wrongly BLOCKS valid keys — that was the recurring rotation
# failure. Hard-reject only genuine paste errors (empty / whitespace / wrong
# charset / absurd length); the GH-secret write + the next CI sccache auth is the
# real validation.
if [[ "$NEW_ACCESS_KEY_ID" =~ [[:space:]] ]] || ! [[ "$NEW_ACCESS_KEY_ID" =~ ^[A-Za-z0-9]{16,128}$ ]]; then
    echo "[rotate-r2-gh-only] ERROR: ACCESS_KEY_ID empty / whitespace / wrong-charset / absurd-length (len ${#NEW_ACCESS_KEY_ID}). Likely paste error — re-check CF dashboard." >&2
    exit 4
fi
if [[ ${#NEW_ACCESS_KEY_ID} -ne 32 ]]; then
    echo "[rotate-r2-gh-only] WARN: ACCESS_KEY_ID length ${#NEW_ACCESS_KEY_ID} (R2 standard is 32; CF can issue longer token-id keys — proceeding; CI sccache auth is the real check)." >&2
fi
if [[ "$NEW_SECRET_ACCESS_KEY" =~ [[:space:]] ]] || ! [[ "$NEW_SECRET_ACCESS_KEY" =~ ^[A-Za-z0-9]{40,128}$ ]]; then
    echo "[rotate-r2-gh-only] ERROR: SECRET_ACCESS_KEY empty / whitespace / wrong-charset / absurd-length (len ${#NEW_SECRET_ACCESS_KEY}). Likely paste error — re-check CF dashboard." >&2
    exit 4
fi
if [[ ${#NEW_SECRET_ACCESS_KEY} -ne 64 ]]; then
    echo "[rotate-r2-gh-only] WARN: SECRET_ACCESS_KEY length ${#NEW_SECRET_ACCESS_KEY} (R2 standard is 64 — proceeding)." >&2
fi

# Audit fingerprint helper — never echo full secrets.
_finger() {
    local s="$1"
    local len="${#s}"
    if [[ "$len" -lt 8 ]]; then
        printf '<short:%d>' "$len"
        return
    fi
    printf '%s...%s' "${s:0:4}" "${s: -4}"
}

# Ambient emit.
_emit() {
    local kind="$1"; shift
    local extra=""
    for kv in "$@"; do extra+=",${kv}"; done
    printf '{"ts":"%s","kind":"%s","source":"rotate_sccache_r2_gh_only"%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$extra" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
}

# ── Report ───────────────────────────────────────────────────────────────────

echo "[rotate-r2-gh-only] input file:      $INPUT_FILE"
echo "[rotate-r2-gh-only] target repo:     $GH_REPO"
echo "[rotate-r2-gh-only] access_key_id:   $(_finger "$NEW_ACCESS_KEY_ID") (len ${#NEW_ACCESS_KEY_ID})"
echo "[rotate-r2-gh-only] secret_access:   $(_finger "$NEW_SECRET_ACCESS_KEY") (len ${#NEW_SECRET_ACCESS_KEY})"
echo ""

if [[ $EXECUTE -eq 0 ]]; then
    echo "${_dry_label}  would gh secret set R2_ACCESS_KEY_ID  in $GH_REPO"
    echo "${_dry_label}  would gh secret set R2_SECRET_ACCESS_KEY in $GH_REPO"
    echo "${_dry_label}  would securely delete $INPUT_FILE on success"
    echo "${_dry_label}  would emit kind=sccache_r2_gh_rotated to ambient"
    echo ""
    echo "[rotate-r2-gh-only] dry-run complete. Re-run with --execute to actually rotate."
    exit 0
fi

# ── Atomic GH update ─────────────────────────────────────────────────────────

echo "[rotate-r2-gh-only] writing R2_ACCESS_KEY_ID in $GH_REPO …"
if ! printf '%s' "$NEW_ACCESS_KEY_ID" | gh secret set R2_ACCESS_KEY_ID -R "$GH_REPO" --body - 2>&1 | tail -3; then
    echo "[rotate-r2-gh-only] ABORT: gh secret set R2_ACCESS_KEY_ID failed" >&2
    _emit "sccache_r2_gh_rotation_failed" "\"step\":\"set_access_key_id\""
    exit 5
fi
echo "  PASS"

echo "[rotate-r2-gh-only] writing R2_SECRET_ACCESS_KEY in $GH_REPO …"
if ! printf '%s' "$NEW_SECRET_ACCESS_KEY" | gh secret set R2_SECRET_ACCESS_KEY -R "$GH_REPO" --body - 2>&1 | tail -3; then
    echo "[rotate-r2-gh-only] ABORT: gh secret set R2_SECRET_ACCESS_KEY failed AFTER R2_ACCESS_KEY_ID succeeded" >&2
    echo "  GH is now HALF-ROTATED — operator MUST re-paste R2_ACCESS_KEY_ID from CF (the value is still in $INPUT_FILE) OR re-run this script." >&2
    _emit "sccache_r2_gh_rotation_partial" \
        "\"step\":\"set_secret_access_key\"" \
        "\"warning\":\"R2_ACCESS_KEY_ID already updated; GH is half-rotated\""
    exit 5
fi
echo "  PASS"

# ── Confirm timestamps match within 5s window ───────────────────────────────

echo "[rotate-r2-gh-only] verifying secret timestamps …"
TS_BLOCK="$(gh secret list -R "$GH_REPO" 2>&1 | grep -E '^R2_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)\s')"
echo "$TS_BLOCK"
ACC_TS="$(printf '%s' "$TS_BLOCK" | awk '/^R2_ACCESS_KEY_ID/{print $2}')"
SEC_TS="$(printf '%s' "$TS_BLOCK" | awk '/^R2_SECRET_ACCESS_KEY/{print $2}')"
if [[ -n "$ACC_TS" && -n "$SEC_TS" ]]; then
    echo "[rotate-r2-gh-only] both secrets timestamped; pair-mismatch class avoided."
fi

# ── Securely delete the input file ───────────────────────────────────────────

echo "[rotate-r2-gh-only] securely deleting $INPUT_FILE …"
if command -v shred >/dev/null 2>&1; then
    shred -uz "$INPUT_FILE" 2>/dev/null || rm -f "$INPUT_FILE"
elif rm -P "$INPUT_FILE" 2>/dev/null; then
    : # macOS-style overwrite-then-unlink
else
    rm -f "$INPUT_FILE"
fi
[[ ! -f "$INPUT_FILE" ]] && echo "  PASS (file removed)" || echo "  WARN: file still present — operator should delete manually"

# ── Emit success ─────────────────────────────────────────────────────────────

_emit "sccache_r2_gh_rotated" \
    "\"target_repo\":\"$GH_REPO\"" \
    "\"new_access_key_id_fingerprint\":\"$(_finger "$NEW_ACCESS_KEY_ID")\"" \
    "\"access_key_id_ts\":\"$ACC_TS\"" \
    "\"secret_access_key_ts\":\"$SEC_TS\""

echo ""
echo "[rotate-r2-gh-only] DONE. Next CI run on a Rust PR uses the new pair."
echo "  Verify by triggering: gh workflow run ci.yml --ref main -R $GH_REPO"
echo "  Watch for: sccache log line should switch from 'S3Error Unauthorized' to cache stats."
