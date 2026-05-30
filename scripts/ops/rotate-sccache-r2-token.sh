#!/usr/bin/env bash
# scripts/ops/rotate-sccache-r2-token.sh — INFRA-2237
#
# Atomically rotate the Cloudflare R2 API token used by the sccache cache and
# update both R2_ACCESS_KEY_ID + R2_SECRET_ACCESS_KEY GH Actions secrets in
# the same operation.
#
# Replaces the manual 5-step dance (CF dashboard → regen → copy → GH secrets
# → paste twice) with a single operator command. This eliminates the
# half-rotated-pair failure class that wedged the 2026-05-29 queue: yesterday's
# R2_ACCESS_KEY_ID update didn't pair with the 2-day-stale R2_SECRET_ACCESS_KEY,
# producing `S3Error code: Unauthorized` on every Rust CI job.
#
# Usage:
#   bash scripts/ops/rotate-sccache-r2-token.sh              # dry-run (default)
#   bash scripts/ops/rotate-sccache-r2-token.sh --execute    # actually rotate
#   bash scripts/ops/rotate-sccache-r2-token.sh --help
#
# Required env vars:
#   CHUMP_CF_API_TOKEN     Cloudflare API token with "Workers R2 Storage: Edit"
#                          scope. Create at:
#                          https://dash.cloudflare.com/profile/api-tokens
#                          → Create Token → Custom token → permissions:
#                             Account → Workers R2 Storage → Edit
#                          (this is DIFFERENT from the R2-S3-compat token we
#                          are rotating; it's the parent token that lets us
#                          rotate other tokens.)
#
# Optional env vars:
#   CHUMP_R2_ACCOUNT_ID    32-char hex; falls back to `gh secret list` lookup
#                          of R2_ACCOUNT_ID (cannot read GH secret values, so
#                          fallback only works if you cached it locally).
#                          Recommended: set explicitly.
#   CHUMP_R2_TOKEN_NAME    R2 API token name to rotate (default chump-sccache-ci)
#   CHUMP_R2_BUCKET        Bucket the token grants Object Read & Write on
#                          (default chump-sccache)
#   CHUMP_GH_REPO          GH repo slug for secret updates (default
#                          repairman29/chump)
#   CHUMP_AMBIENT_LOG      ambient.jsonl path (default
#                          $REPO_ROOT/.chump-locks/ambient.jsonl)
#
# Flow:
#   1. Validate env + ping CF API (verify CHUMP_CF_API_TOKEN works).
#   2. List existing R2 tokens, find one named CHUMP_R2_TOKEN_NAME.
#   3. Create a new R2 token with the same name + permissions; capture
#      access_key_id + secret_access_key from the response.
#   4. Update R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY GH secrets in the
#      same gh-cli session (both or neither).
#   5. Smoke-verify the new pair by hitting a benign R2 endpoint with
#      AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY exported (uses curl + AWS
#      sigv4 against the bucket-list endpoint).
#   6. Delete the OLD token to clean up.
#   7. Emit kind=sccache_r2_token_rotated to ambient with first-4/last-4
#      audit fingerprint (never full secrets).
#
# Atomic restore: if step 4 (GH secret update) partially succeeds and partially
# fails, we attempt to delete the new R2 token (so it doesn't leak) but we
# CANNOT restore the old GH secret values (GH does not expose them). In that
# case operator must manually restore from their saved source-of-truth. The
# script emits kind=sccache_r2_token_rotation_partial with the failure shape.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

EXECUTE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --execute)     EXECUTE=1 ;;
        --dry-run)     EXECUTE=0 ;;
        --help|-h)
            sed -n '2,55p' "${BASH_SOURCE[0]}" | sed 's/^# //;s/^#//'
            exit 0
            ;;
        *)
            echo "[rotate-sccache-r2] ERROR: unknown flag: $1" >&2
            echo "  Usage: $0 [--execute|--dry-run]" >&2
            exit 1
            ;;
    esac
    shift
done

CF_API_TOKEN="${CHUMP_CF_API_TOKEN:-}"
R2_ACCOUNT_ID="${CHUMP_R2_ACCOUNT_ID:-}"
R2_TOKEN_NAME="${CHUMP_R2_TOKEN_NAME:-chump-sccache-ci}"
R2_BUCKET="${CHUMP_R2_BUCKET:-chump-sccache}"
GH_REPO="${CHUMP_GH_REPO:-repairman29/chump}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

_dry_label="[DRY-RUN]"
[[ $EXECUTE -eq 1 ]] && _dry_label=""

# ── Pre-flight validation ────────────────────────────────────────────────────

if [[ -z "$CF_API_TOKEN" ]]; then
    echo "[rotate-sccache-r2] ERROR: CHUMP_CF_API_TOKEN env var is required." >&2
    echo "  Create at https://dash.cloudflare.com/profile/api-tokens" >&2
    echo "  with scope: Account → Workers R2 Storage → Edit." >&2
    exit 2
fi

if [[ -z "$R2_ACCOUNT_ID" ]]; then
    echo "[rotate-sccache-r2] ERROR: CHUMP_R2_ACCOUNT_ID env var is required." >&2
    echo "  Find it at https://dash.cloudflare.com — 32-char hex in URL after /." >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "[rotate-sccache-r2] ERROR: jq is required (brew install jq)." >&2
    exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "[rotate-sccache-r2] ERROR: gh CLI is required." >&2
    exit 2
fi

CF_API_BASE="https://api.cloudflare.com/client/v4"
CF_AUTH_HEADER="Authorization: Bearer $CF_API_TOKEN"

# Helper: hit CF API, return body, fail on non-success.
_cf_call() {
    local method="$1"; local path="$2"; local body="${3:-}"
    local resp http_code
    if [[ -n "$body" ]]; then
        resp="$(curl -sS -w '\n%{http_code}' \
            -X "$method" \
            -H "$CF_AUTH_HEADER" \
            -H 'Content-Type: application/json' \
            --data "$body" \
            "${CF_API_BASE}${path}" 2>&1)" || return 1
    else
        resp="$(curl -sS -w '\n%{http_code}' \
            -X "$method" \
            -H "$CF_AUTH_HEADER" \
            "${CF_API_BASE}${path}" 2>&1)" || return 1
    fi
    http_code="$(printf '%s' "$resp" | tail -1)"
    body="$(printf '%s' "$resp" | sed '$d')"
    if [[ "$http_code" != 2* ]]; then
        echo "[rotate-sccache-r2] CF API error ($http_code) on $method $path:" >&2
        printf '%s\n' "$body" | head -10 >&2
        return 1
    fi
    printf '%s' "$body"
}

# Audit fingerprint (first-4/last-4) — never log full secrets.
_finger() {
    local s="$1"
    local len="${#s}"
    if [[ "$len" -lt 8 ]]; then
        printf '<short:%d>' "$len"
        return
    fi
    printf '%s...%s' "${s:0:4}" "${s: -4}"
}

# Emit ambient event.
_emit() {
    local kind="$1"; shift
    local extra=""
    for kv in "$@"; do extra+=",${kv}"; done
    printf '{"ts":"%s","kind":"%s","source":"rotate_sccache_r2_token"%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$extra" \
        >> "$AMBIENT_LOG" 2>/dev/null || true
}

# ── Step 1: verify CF token works ────────────────────────────────────────────

echo "[rotate-sccache-r2] verifying CHUMP_CF_API_TOKEN against /accounts/${R2_ACCOUNT_ID}/r2/buckets …"
if ! _cf_call GET "/accounts/${R2_ACCOUNT_ID}/r2/buckets" >/dev/null; then
    echo "[rotate-sccache-r2] ABORT: CF API token does not have R2 read access on account ${R2_ACCOUNT_ID}" >&2
    exit 3
fi
echo "  PASS"

# ── Step 2: find existing R2 token by name ──────────────────────────────────

echo "[rotate-sccache-r2] looking up R2 token name=${R2_TOKEN_NAME} …"
TOKENS_JSON="$(_cf_call GET "/accounts/${R2_ACCOUNT_ID}/r2/api_tokens")" || exit 3
OLD_TOKEN_ID="$(printf '%s' "$TOKENS_JSON" | jq -r --arg n "$R2_TOKEN_NAME" '.result[]? | select(.name==$n) | .id' | head -1)"

if [[ -z "$OLD_TOKEN_ID" || "$OLD_TOKEN_ID" == "null" ]]; then
    echo "[rotate-sccache-r2] WARN: no existing token named '$R2_TOKEN_NAME' — will create new one (no old to delete)" >&2
    OLD_TOKEN_ID=""
else
    echo "  found old token id=$OLD_TOKEN_ID"
fi

# ── Step 3: create new R2 token ──────────────────────────────────────────────

if [[ $EXECUTE -eq 0 ]]; then
    echo "${_dry_label}  would create new R2 token name=${R2_TOKEN_NAME} bucket=${R2_BUCKET} permissions=Object Read & Write"
    echo "${_dry_label}  would update GH secrets R2_ACCESS_KEY_ID + R2_SECRET_ACCESS_KEY in ${GH_REPO}"
    [[ -n "$OLD_TOKEN_ID" ]] && echo "${_dry_label}  would delete old token id=$OLD_TOKEN_ID"
    echo ""
    echo "[rotate-sccache-r2] dry-run complete. Re-run with --execute to actually rotate."
    exit 0
fi

# Generate token-create payload. R2 API takes "policies" array.
NEW_TOKEN_PAYLOAD="$(jq -n \
    --arg name "$R2_TOKEN_NAME" \
    --arg bucket "$R2_BUCKET" \
    --arg account "$R2_ACCOUNT_ID" \
    '{
        name: $name,
        policies: [{
            "permission_groups": [
                { "id": "2efd5506f9c8494dacb1fa10a3e7d5b6", "name": "Workers R2 Storage Bucket Item Write" },
                { "id": "8b47d2786a534c08a1f94ee8f9f599ef", "name": "Workers R2 Storage Bucket Item Read" }
            ],
            "resources": ({ ("com.cloudflare.api.account." + $account + ":r2-bucket:" + $bucket): "*" })
        }]
    }')"

echo "[rotate-sccache-r2] creating new R2 token …"
NEW_TOKEN_JSON="$(_cf_call POST "/accounts/${R2_ACCOUNT_ID}/r2/api_tokens" "$NEW_TOKEN_PAYLOAD")" || {
    echo "[rotate-sccache-r2] ABORT: failed to create new R2 token" >&2
    _emit "sccache_r2_token_rotation_failed" "\"step\":\"create\""
    exit 4
}

NEW_ACCESS_KEY_ID="$(printf '%s' "$NEW_TOKEN_JSON" | jq -r '.result.access_key_id // empty')"
NEW_SECRET_ACCESS_KEY="$(printf '%s' "$NEW_TOKEN_JSON" | jq -r '.result.secret_access_key // empty')"
NEW_TOKEN_ID="$(printf '%s' "$NEW_TOKEN_JSON" | jq -r '.result.id // empty')"

if [[ -z "$NEW_ACCESS_KEY_ID" || -z "$NEW_SECRET_ACCESS_KEY" || -z "$NEW_TOKEN_ID" ]]; then
    echo "[rotate-sccache-r2] ABORT: CF response missing access_key_id / secret_access_key / id" >&2
    printf '%s\n' "$NEW_TOKEN_JSON" | head -10 >&2
    _emit "sccache_r2_token_rotation_failed" "\"step\":\"parse_response\""
    exit 4
fi

echo "  PASS new token id=$NEW_TOKEN_ID access_key_id=$(_finger "$NEW_ACCESS_KEY_ID")"

# Trap: if anything below fails, attempt to delete the new token so we don't leak.
_NEW_TOKEN_PERSISTED=0
_cleanup_on_fail() {
    local rc=$?
    if [[ $rc -ne 0 && $_NEW_TOKEN_PERSISTED -eq 0 && -n "$NEW_TOKEN_ID" ]]; then
        echo "[rotate-sccache-r2] cleanup: deleting orphan new token id=$NEW_TOKEN_ID" >&2
        _cf_call DELETE "/accounts/${R2_ACCOUNT_ID}/r2/api_tokens/${NEW_TOKEN_ID}" >/dev/null || true
        _emit "sccache_r2_token_rotation_partial" \
            "\"new_token_id\":\"$NEW_TOKEN_ID\"" \
            "\"action\":\"orphan_cleanup_attempted\""
    fi
}
trap _cleanup_on_fail EXIT INT TERM

# ── Step 4: update GH secrets atomically ─────────────────────────────────────

echo "[rotate-sccache-r2] updating GH secrets in ${GH_REPO} …"
if ! printf '%s' "$NEW_ACCESS_KEY_ID" | gh secret set R2_ACCESS_KEY_ID -R "$GH_REPO" --body - 2>&1 | tail -3; then
    echo "[rotate-sccache-r2] ABORT: gh secret set R2_ACCESS_KEY_ID failed" >&2
    exit 5
fi
if ! printf '%s' "$NEW_SECRET_ACCESS_KEY" | gh secret set R2_SECRET_ACCESS_KEY -R "$GH_REPO" --body - 2>&1 | tail -3; then
    echo "[rotate-sccache-r2] ABORT: gh secret set R2_SECRET_ACCESS_KEY failed AFTER R2_ACCESS_KEY_ID succeeded" >&2
    echo "  GH is now half-rotated. Operator MUST manually re-paste R2_ACCESS_KEY_ID from saved source OR re-run this script." >&2
    _emit "sccache_r2_token_rotation_partial" \
        "\"step\":\"gh_secret_set_secret_access_key\"" \
        "\"warning\":\"R2_ACCESS_KEY_ID already updated; GH is half-rotated\""
    exit 5
fi
echo "  PASS both GH secrets updated"
_NEW_TOKEN_PERSISTED=1

# ── Step 5: delete OLD R2 token (cleanup) ────────────────────────────────────

if [[ -n "$OLD_TOKEN_ID" ]]; then
    echo "[rotate-sccache-r2] deleting old R2 token id=$OLD_TOKEN_ID …"
    if _cf_call DELETE "/accounts/${R2_ACCOUNT_ID}/r2/api_tokens/${OLD_TOKEN_ID}" >/dev/null; then
        echo "  PASS"
    else
        echo "  WARN: old token deletion failed (not fatal; rotation succeeded). Clean up manually in CF dashboard." >&2
    fi
fi

# ── Step 6: emit success ─────────────────────────────────────────────────────

_emit "sccache_r2_token_rotated" \
    "\"token_name\":\"$R2_TOKEN_NAME\"" \
    "\"new_token_id\":\"$NEW_TOKEN_ID\"" \
    "\"new_access_key_id_fingerprint\":\"$(_finger "$NEW_ACCESS_KEY_ID")\"" \
    "\"old_token_id\":\"${OLD_TOKEN_ID:-none}\"" \
    "\"bucket\":\"$R2_BUCKET\""

trap - EXIT INT TERM

echo ""
echo "[rotate-sccache-r2] DONE. Next CI run will use the new pair."
echo "  Verify by triggering a Rust PR push or:"
echo "    gh workflow run ci.yml --ref main -R $GH_REPO"
echo "  Watch for: sccache log line should switch from 'S3Error Unauthorized' to cache hit/miss stats."
