#!/usr/bin/env bash
# scripts/ops/free-tier-refresh.sh — CREDIBLE-185
#
# Keep a fleet node's FREE-TIER provider cascade current + validated in
# ~/.chump/providers.env, and set CHUMP_FREE_TIER_PROVIDERS to the ONE
# live-verified $0 cascade — the tracked-manifest counterpart to
# node-refresh-chump.sh (which keeps the *binary* current, not the config).
#
# WHY THIS EXISTS (CREDIBLE-185): the free-tier cascade used to live ONLY in
# each node's gitignored, hand-entered ~/.chump/providers.env. It drifted: by
# 2026-08-22 closetjunky's CHUMP_FREE_TIER_PROVIDERS pointed at a 100%-DEAD
# stack (Groq llama-3.3-70b 404, Cerebras 402, NVIDIA unusable, GitHub-Models
# retired, Together/Gemini metered) while the Pixel had only two Groq slots
# sharing one quota. A fresh checkout's src DEFAULTS were dead too (fixed in
# PR #4174 / EFFECTIVE-444). This script makes the cascade a TRACKED,
# liveness-verifiable manifest that survives a fresh checkout and self-heals
# each node's providers.env back to the validated order on a cadence — instead
# of a value hand-typed into a gitignored file that silently rots.
#
# THE VALIDATED $0 CASCADE (live-verified 2026-08-22 + 2026-08-23, cross-provider
# so a Groq 429/exhaustion fails over to a DIFFERENT provider, not a second Groq
# model on the same daily quota). Kept byte-identical to the src DEFAULTS in
# src/execute_gap.rs::parse_free_tier_providers() — the CI test
# scripts/ci/test-free-tier-refresh.sh asserts they never drift apart:
#   1. Groq        openai/gpt-oss-120b                     (best free quality)
#   2. OpenRouter  nvidia/nemotron-3-super-120b-a12b:free  (different provider)
#   3. Groq        openai/gpt-oss-20b                       (fast fallback)
#
# FREE-ONLY LAW: the active cascade must contain NO metered provider. This
# script REFUSES to write any entry whose base_url matches a known metered
# route (opencode.ai / /zen / etc.) and strips such entries if it finds them in
# an existing CHUMP_FREE_TIER_PROVIDERS line before rewriting.
#
# NO SECRET VALUES: this script never reads, prints, or moves a key VALUE. It
# only checks — by env-NAME — that the keys the cascade references
# (GROQ_API_KEY, OPENROUTER_API_KEY) are PRESENT in providers.env. If a
# required key is absent it emits a loud, actionable one-step (which key, which
# file) and exits non-zero WITHOUT touching the cascade — an operator places the
# key, then the next run wires it in.
#
# PAUSE SAFETY (RESILIENT-073): touches ONLY the CHUMP_FREE_TIER_PROVIDERS line
# in providers.env. Never reads/writes ~/.chump/AUTONOMY_LEVEL, never starts
# fleet work. A paused node self-currents its cascade and stays off.
#
# HOST-AGNOSTIC: pure POSIX-ish bash, no cargo, no systemd assumptions. Runs
# identically under a systemd --user timer on closetjunky and a runit service on
# the Pixel (Termux). Resolves providers.env via CHUMP_STATE_DIR (Termux sets it
# to ~/.chump) then falls back to ~/.chump.
#
# Idempotent: if the active line already equals the validated cascade, no write.
#
# Emits (appended to $NODE_AMBIENT if its dir exists, else logfile only):
#   free_tier_refreshed        — cascade line rewritten to the validated order
#   free_tier_refresh_skipped  — already current (no-op)
#   free_tier_metered_stripped — a metered entry was removed from the active line
#   free_tier_key_missing      — a required key env is absent (actionable, exit 2)
#   free_tier_refresh_failed   — I/O or precondition error
#
# Bypass: CHUMP_SKIP_FREE_TIER_REFRESH=1 short-circuits to exit 0.
#
# Env overrides:
#   CHUMP_STATE_DIR    dir holding providers.env   (default: ~/.chump)
#   NODE_AMBIENT       ambient stream to append to (default: <state>/ambient.jsonl
#                      or <repo>/.chump-locks/ambient.jsonl if that dir exists)

set -uo pipefail

# --- the ONE validated $0 cascade (keep byte-identical to src DEFAULTS) -------
readonly VALIDATED_CASCADE="openai/gpt-oss-120b@https://api.groq.com/openai/v1:GROQ_API_KEY,nvidia/nemotron-3-super-120b-a12b:free@https://openrouter.ai/api/v1:OPENROUTER_API_KEY,openai/gpt-oss-20b@https://api.groq.com/openai/v1:GROQ_API_KEY"

# key envs the cascade references (checked by NAME only — never by value)
readonly REQUIRED_KEY_ENVS=("GROQ_API_KEY" "OPENROUTER_API_KEY")

# base-url fragments that mark a METERED route — never allowed in the active
# free-tier rotation (kept only as an explicitly-flagged last resort elsewhere).
readonly METERED_MARKERS=("opencode.ai" "/zen")

STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
ENVF="$STATE_DIR/providers.env"

# ambient stream: prefer an existing repo .chump-locks/, else state dir
if [[ -z "${NODE_AMBIENT:-}" ]]; then
    if [[ -d "$STATE_DIR" ]]; then NODE_AMBIENT="$STATE_DIR/ambient.jsonl"; fi
    for r in "$HOME/chump-host" "$HOME/chump-repo" "$HOME/Projects/Chump" "$HOME/chump"; do
        if [[ -d "$r/.chump-locks" ]]; then NODE_AMBIENT="$r/.chump-locks/ambient.jsonl"; break; fi
    done
fi

LOG_DIR="${CHUMP_FREE_TIER_REFRESH_LOGDIR:-$STATE_DIR/free-tier-refresh-logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/refresh-$(date -u +%Y%m%dT%H%M%SZ).log"

emit() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    [[ -n "${NODE_AMBIENT:-}" && -d "$(dirname "$NODE_AMBIENT")" ]] && printf '%s\n' "$line" >> "$NODE_AMBIENT" 2>/dev/null || true
    printf '[%s] %s %s\n' "$ts" "$kind" "$extra" >> "$LOG" 2>/dev/null || true
}
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

# --- self-check: the compiled-in cascade must itself be metered-free ----------
for _m in "${METERED_MARKERS[@]}"; do
    if [[ "$VALIDATED_CASCADE" == *"$_m"* ]]; then
        log "FATAL: VALIDATED_CASCADE contains metered marker '$_m' — refusing"
        emit free_tier_refresh_failed "\"reason\":\"validated_cascade_metered\",\"marker\":\"$_m\""
        exit 1
    fi
done

if [[ "${CHUMP_SKIP_FREE_TIER_REFRESH:-0}" == "1" ]]; then
    log "BYPASS: CHUMP_SKIP_FREE_TIER_REFRESH=1"; exit 0
fi

if [[ ! -f "$ENVF" ]]; then
    log "FATAL: providers.env not found at $ENVF (set CHUMP_STATE_DIR)"
    emit free_tier_refresh_failed "\"reason\":\"no_providers_env\",\"path\":\"$ENVF\""
    exit 1
fi

# --- required keys must be PRESENT (by name) ---------------------------------
# Match an assignment line for the env name, optionally `export `-prefixed, with
# a non-empty value. We never capture or print the value.
_key_present() {
    local name="$1"
    grep -qE "^(export[[:space:]]+)?${name}=[^[:space:]\"']|^(export[[:space:]]+)?${name}=\"[^\"]|^(export[[:space:]]+)?${name}='[^']" "$ENVF"
}
missing=()
for k in "${REQUIRED_KEY_ENVS[@]}"; do
    _key_present "$k" || missing+=("$k")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    for k in "${missing[@]}"; do
        log "KEY MISSING: $k is not set in $ENVF"
        log "  → one-step: add a line  ${k}=<value>  to $ENVF on this node (chmod 600), then re-run this script."
        emit free_tier_key_missing "\"key\":\"$k\",\"path\":\"$ENVF\""
    done
    log "REFUSING to rewrite cascade while required keys are missing (cascade untouched)."
    exit 2
fi

# --- read the current active cascade line ------------------------------------
current_line="$(grep -E "^(export[[:space:]]+)?CHUMP_FREE_TIER_PROVIDERS=" "$ENVF" | tail -1 || true)"
current_val=""
if [[ -n "$current_line" ]]; then
    current_val="${current_line#*=}"
    current_val="${current_val%\"}"; current_val="${current_val#\"}"
    current_val="${current_val%\'}"; current_val="${current_val#\'}"
fi

# --- detect metered entries in the existing active line (for the receipt) ----
stripped_any=0
if [[ -n "$current_val" ]]; then
    for _m in "${METERED_MARKERS[@]}"; do
        if [[ "$current_val" == *"$_m"* ]]; then
            stripped_any=1
            log "METERED route present in current cascade (marker '$_m') — will be removed by rewrite"
            emit free_tier_metered_stripped "\"marker\":\"$_m\""
        fi
    done
fi

# --- idempotency: already the validated cascade? -----------------------------
if [[ "$current_val" == "$VALIDATED_CASCADE" ]]; then
    log "SKIP: CHUMP_FREE_TIER_PROVIDERS already the validated $0 cascade"
    emit free_tier_refresh_skipped "\"reason\":\"already_current\""
    exit 0
fi

# --- rewrite providers.env: drop every existing CHUMP_FREE_TIER_PROVIDERS line,
#     append the single validated line. Atomic (tempfile + rename). Preserves
#     file mode.
TMP="$ENVF.free-tier.$$"
if ! grep -vE "^(export[[:space:]]+)?CHUMP_FREE_TIER_PROVIDERS=" "$ENVF" > "$TMP" 2>>"$LOG"; then
    log "FATAL: failed to stage rewrite of $ENVF"
    emit free_tier_refresh_failed "\"reason\":\"stage_failed\""
    rm -f "$TMP" 2>/dev/null || true
    exit 1
fi
printf 'CHUMP_FREE_TIER_PROVIDERS=%s\n' "$VALIDATED_CASCADE" >> "$TMP"

# preserve permissions (providers.env holds secrets — keep it 600)
if command -v stat >/dev/null 2>&1; then
    mode="$(stat -c '%a' "$ENVF" 2>/dev/null || stat -f '%Lp' "$ENVF" 2>/dev/null || echo 600)"
    chmod "${mode:-600}" "$TMP" 2>/dev/null || chmod 600 "$TMP" 2>/dev/null || true
else
    chmod 600 "$TMP" 2>/dev/null || true
fi

if ! mv -f "$TMP" "$ENVF" 2>>"$LOG"; then
    log "FATAL: failed to install rewritten $ENVF"
    emit free_tier_refresh_failed "\"reason\":\"install_failed\""
    rm -f "$TMP" 2>/dev/null || true
    exit 1
fi

log "OK: CHUMP_FREE_TIER_PROVIDERS set to validated $0 cascade in $ENVF"
log "    cascade = $VALIDATED_CASCADE"
emit free_tier_refreshed "\"prev_present\":$([[ -n "$current_val" ]] && echo true || echo false),\"stripped_metered\":$([[ "$stripped_any" == "1" ]] && echo true || echo false)"

# Prune old logs (keep last 24)
ls -t "$LOG_DIR"/refresh-*.log 2>/dev/null | tail -n +25 | xargs -r rm -f 2>/dev/null || true
exit 0
