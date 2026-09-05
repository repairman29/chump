#!/usr/bin/env bash
# scripts/ops/organ-reconcile.sh — RESILIENT-305 (reproducible-deploy, slice 1)
#
# Converge the PRIMARY node's live systemd state to the repo-declared organ
# manifest (scripts/ops/organ-manifest.txt): enable/start the organs that must
# run, and neuter+stop the auto-pagers that must stay OFF. Idempotent — safe to
# re-run any time; a second run with no drift is a no-op.
#
# WHY: tonight's pager DM-spam + failed-organ resurrection were one root cause —
# deployed systemd state DRIFTED from the repo, and the fixes were host-level
# edits (/etc/systemd/system/*.d/zz-autopage-off.conf) that are invisible to the
# repo and get reverted by the deploy mirror's `git reset --hard origin/main`.
# This reconcile keeps the desired state IN the repo (the manifest) and re-applies
# it, so drift self-heals and nothing is a snowflake.
#
# The pager-OFF mechanism is a systemd drop-in that overrides ExecStart to
# /bin/true. A drop-in beats mask/disable for durability here because:
#   * install-helsinki-atc.sh does `cp -f` of the BASE unit file every deploy —
#     that would clobber a mask symlink, but it never touches the unit's `.d/`
#     drop-in directory, so the override survives.
#   * `git reset --hard` reverts working-tree edits, but the drop-in content is
#     re-applied by THIS script from the repo on every reconcile.
# Neutering to /bin/true (rather than disabling the timer) also means a oneshot
# pager exits SUCCESS, so chump-organ-watchdog never sees it "failed" and never
# restarts it — closing the 5-minute resurrection loop.
#
# Usage:
#   sudo bash scripts/ops/organ-reconcile.sh --apply    # converge (default)
#   sudo bash scripts/ops/organ-reconcile.sh --check    # exit 0 iff state==manifest
#
# Runs as root (writes /etc/systemd/system). Under a non-root/--auto-style
# context it warns and exits 0 rather than hard-failing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="${CHUMP_ORGAN_MANIFEST:-$REPO_ROOT/scripts/ops/organ-manifest.txt}"
SYSTEMD_DIR="/etc/systemd/system"
DROPIN_NAME="zz-organ-reconcile-pager-off.conf"
LEGACY_DROPIN="zz-autopage-off.conf"   # tonight's host-only snowflake — remove it

# RESILIENT-347: stubbable systemctl (test hook, mirrors organ-watchdog.sh's
# CHUMP_ORGAN_WATCHDOG_SYSTEMCTL_BIN pattern) + per-node-applicable reconcile
# tunables.
SYSTEMCTL_BIN="${CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN:-systemctl}"
BACKOFF_DIR="${CHUMP_ORGAN_RECONCILE_BACKOFF_DIR:-$REPO_ROOT/.chump-locks/organ-backoff}"
BACKOFF_COOLDOWN_S="${CHUMP_ORGAN_RECONCILE_BACKOFF_COOLDOWN_S:-3600}"
VERIFY_DELAY_S="${CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S:-2}"

AMBIENT_LOG="${NODE_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
LIB_AMBIENT="$REPO_ROOT/scripts/coord/lib/ambient-write.sh"
[[ -f "$LIB_AMBIENT" ]] && source "$LIB_AMBIENT"

# TREK-18 (INFRA-3644): the manifest parser is shared with install-helsinki-atc.sh
LIB_ORGAN_MANIFEST="$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh"
if [[ ! -f "$LIB_ORGAN_MANIFEST" ]]; then
  echo "ERROR: missing $LIB_ORGAN_MANIFEST" >&2
  exit 1
fi
source "$LIB_ORGAN_MANIFEST"

emit() {  # kind, extra-json (no leading/trailing comma)
  local kind="$1" extra="${2:-}"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local line
  if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
  else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
  if command -v _ambient_write >/dev/null 2>&1; then
    [[ -d "$(dirname "$AMBIENT_LOG")" ]] && _ambient_write "$AMBIENT_LOG" "$line" || true
  else
    [[ -d "$(dirname "$AMBIENT_LOG")" ]] && printf '%s\n' "$line" >> "$AMBIENT_LOG" 2>/dev/null || true
  fi
  return 0  # emit is best-effort telemetry; it must never sink the reconcile (set -e)
}

# RESILIENT-347: is `unit` applicable to THIS node given its declared
# `requires=` spec (comma-separated bin:/env:/dep: tokens, see manifest
# header)? Empty/absent requires means "always applicable" (back-compat with
# pre-347 manifest lines). Writes the first unmet reason into $2 (a nameref
# target via printf -v) for the caller to log/emit.
organ_is_applicable() {
  local unit="$1" requires="$2" reason_var="$3"
  [[ -z "$requires" ]] && return 0
  local tok IFS=','
  for tok in $requires; do
    case "$tok" in
      bin:*)
        local bin="${tok#bin:}"
        if ! command -v "$bin" >/dev/null 2>&1; then
          printf -v "$reason_var" 'missing_bin:%s' "$bin"; return 1
        fi
        ;;
      env:*)
        local var="${tok#env:}"
        if [[ -z "${!var:-}" ]]; then
          printf -v "$reason_var" 'missing_env:%s' "$var"; return 1
        fi
        ;;
      dep:*)
        local dep="${tok#dep:}"
        if ! "$SYSTEMCTL_BIN" is-active --quiet "$dep" 2>/dev/null; then
          printf -v "$reason_var" 'missing_dep:%s' "$dep"; return 1
        fi
        ;;
      *)
        printf -v "$reason_var" 'unknown_requires_spec:%s' "$tok"; return 1
        ;;
    esac
  done
  return 0
}

# RESILIENT-347: is `unit` still cooling down from a prior verify failure?
# Returns 0 (true, skip it) while now - since < BACKOFF_COOLDOWN_S.
organ_in_backoff() {
  local unit="$1" f="$BACKOFF_DIR/${unit}.json"
  [[ -f "$f" ]] || return 1
  local since; since="$(grep -o '"since":[0-9]*' "$f" 2>/dev/null | head -1 | cut -d: -f2)"
  [[ "$since" =~ ^[0-9]+$ ]] || return 1
  local now; now="$(date +%s)"
  (( now - since < BACKOFF_COOLDOWN_S ))
}

record_backoff() {  # unit, reason
  local unit="$1" reason="$2"
  mkdir -p "$BACKOFF_DIR" 2>/dev/null || return 0
  printf '{"unit":"%s","since":%d,"reason":"%s"}\n' "$unit" "$(date +%s)" "$reason" \
    > "$BACKOFF_DIR/${unit}.json" 2>/dev/null || true
}

clear_backoff() {  # unit
  rm -f "$BACKOFF_DIR/${1}.json" 2>/dev/null || true
}

# RESILIENT-1016 (a): drift-REMOVAL discovery. Lists every chump-managed unit
# FILE present on the host (installed, whether active or not) so the caller
# can diff it against the role-filtered manifest's expected set. Only
# meaningful for a role-scoped reconcile (ROLE_FILTER set) — the unfiltered
# reconcile already manages the WHOLE manifest, so there is no "out of role"
# unit to reap there.
discover_live_chump_units() {
  "$SYSTEMCTL_BIN" list-unit-files --type=service --no-legend 'chump-*.service' 2>/dev/null | awk '{print $1}'
}

# A unit is a drift-removal candidate if systemd still considers it active OR
# enabled — a unit that's merely present-on-disk-but-inactive-and-disabled
# isn't drift, it's just a dormant unit file left by history.
organ_is_live() {
  local unit="$1"
  "$SYSTEMCTL_BIN" is-active --quiet "$unit" 2>/dev/null && return 0
  "$SYSTEMCTL_BIN" is-enabled --quiet "$unit" 2>/dev/null && return 0
  return 1
}

# Repo-declared drop-in body that neuters an auto-pager's ExecStart.
dropin_body() {
  local unit="$1"
  cat <<EOF
# Managed by scripts/ops/organ-reconcile.sh (RESILIENT-305) — DO NOT EDIT BY HAND.
# Desired state is declared in scripts/ops/organ-manifest.txt (state=paging_off).
# Neuters $unit's ExecStart so its auto-paging stays OFF. Survives
# install-helsinki-atc.sh's cp of the base unit (the .d/ dir is untouched) and
# the deploy mirror's \`git reset --hard origin/main\` (re-applied from the repo).
[Service]
ExecStart=
ExecStart=/bin/true
EOF
}

# ── read manifest into arrays (+ per-unit role/requires, RESILIENT-347) ─────
# TREK-18: parsed by the shared organ_manifest_parse() helper (organ-manifest-lib.sh)
PAGING_OFF=()
ENABLED=()
declare -A ORGAN_ROLE
declare -A ORGAN_REQUIRES
organ_manifest_parse "$MANIFEST" PAGING_OFF ENABLED ORGAN_ROLE ORGAN_REQUIRES || exit 1

# RESILIENT-746: optional per-role scoping. chump-node-install.sh's ORGANS
# phase (--role brain|muscle|all) sets this so a freshly-installed node only
# reconciles the organs that belong to its declared role instead of every
# `enabled` line in the manifest (the "install ORGANS but never wire the role
# split into the reconcile" hole from the helsinki teardown). Comma-separated
# list of role= values (as declared in organ-manifest.txt); empty/unset means
# "all roles" — the pre-existing, back-compat behavior for the primary node's
# own timer-driven reconcile, which is not role-scoped.
ROLE_FILTER="${CHUMP_ORGAN_RECONCILE_ROLE:-}"
if [[ -n "$ROLE_FILTER" ]]; then
  FILTERED_ENABLED=()
  IFS=',' read -ra _role_filter_toks <<< "$ROLE_FILTER"
  for unit in "${ENABLED[@]}"; do
    role="${ORGAN_ROLE[$unit]:-brain}"
    for tok in "${_role_filter_toks[@]}"; do
      if [[ "$tok" == "$role" ]]; then
        FILTERED_ENABLED+=("$unit")
        break
      fi
    done
  done
  ENABLED=("${FILTERED_ENABLED[@]}")
fi

MODE="${1:---apply}"

# ── --check mode: verify live state matches the manifest, change nothing ─────
if [[ "$MODE" == "--check" ]]; then
  fail=0
  for unit in "${PAGING_OFF[@]}"; do
    # effective ExecStart must be neutered to /bin/true
    if ! "$SYSTEMCTL_BIN" show "$unit" -p ExecStart 2>/dev/null | grep -q '/bin/true'; then
      echo "DRIFT: $unit auto-paging is NOT neutered"; fail=1
    fi
  done
  for unit in "${ENABLED[@]}"; do
    requires="${ORGAN_REQUIRES[$unit]:-}"
    reason=""
    if ! organ_is_applicable "$unit" "$requires" reason; then
      echo "SKIP: $unit not applicable to this node ($reason)"
      continue
    fi
    if organ_in_backoff "$unit"; then
      echo "SKIP: $unit is backed off (cooling down after a prior failure)"
      continue
    fi
    if ! "$SYSTEMCTL_BIN" is-active --quiet "$unit" 2>/dev/null; then
      echo "DRIFT: $unit is not active"; fail=1
    fi
  done
  # RESILIENT-1016 (a): role-scoped drift check — flag any chump unit that is
  # still active/enabled but NOT in the role-filtered manifest (present but
  # out-of-role, or dropped from the manifest entirely). Unfiltered (whole
  # manifest) reconciles have nothing "out of role" to flag.
  if [[ -n "$ROLE_FILTER" ]]; then
    declare -A _EXPECTED_UNIT
    for unit in "${ENABLED[@]}"; do _EXPECTED_UNIT["$unit"]=1; done
    for unit in "${PAGING_OFF[@]}"; do _EXPECTED_UNIT["$unit"]=1; done
    while IFS= read -r unit; do
      [[ -z "$unit" ]] && continue
      [[ -n "${_EXPECTED_UNIT[$unit]:-}" ]] && continue
      if organ_is_live "$unit"; then
        echo "DRIFT: $unit is active/enabled but out-of-role (not in role-filtered manifest)"; fail=1
      fi
    done < <(discover_live_chump_units)
  fi
  [[ "$fail" == 0 ]] && echo "ok: live systemd state matches organ-manifest.txt"
  exit "$fail"
fi

# ── --apply mode ─────────────────────────────────────────────────────────────
# CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT is a test-only hook (mirrors the stub
# pattern organ-watchdog.sh uses for its own tests) so scripts/ci/test-organ-reconcile.sh
# can exercise the applicability/backoff logic against a stubbed systemctl
# without needing real root / a real systemd bus.
if [[ "$(id -u)" != "0" && "${CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT:-0}" != "1" ]]; then
  echo "WARN: organ-reconcile needs root to write $SYSTEMD_DIR; skipping (non-root context)" >&2
  # scanner-anchor: "kind":"organ_reconcile_skipped" (RESILIENT-305; fires when
  # the reconcile is invoked without root and cannot write /etc/systemd/system)
  emit organ_reconcile_skipped "\"reason\":\"not_root\""
  exit 0
fi

CHANGED=()
NEED_RELOAD=0

# 1) Auto-pagers → neuter (repo-declared drop-in) + stop; drop the legacy snowflake.
for unit in "${PAGING_OFF[@]}"; do
  dropin_dir="$SYSTEMD_DIR/${unit}.d"
  dropin="$dropin_dir/$DROPIN_NAME"
  want="$(dropin_body "$unit")"
  if [[ ! -f "$dropin" ]] || [[ "$(cat "$dropin" 2>/dev/null)" != "$want" ]]; then
    mkdir -p "$dropin_dir"
    printf '%s\n' "$want" > "$dropin"
    CHANGED+=("dropin:$unit")
    NEED_RELOAD=1
  fi
  # Remove tonight's host-only snowflake drop-in — end state is fully repo-declared.
  legacy="$dropin_dir/$LEGACY_DROPIN"
  if [[ -f "$legacy" ]]; then
    rm -f "$legacy"
    CHANGED+=("legacy-rm:$unit")
    NEED_RELOAD=1
  fi
done

if [[ "$NEED_RELOAD" == 1 ]]; then
  "$SYSTEMCTL_BIN" daemon-reload
fi

# Stop any pager still running so an in-flight page cycle halts. (Oneshot pagers
# are usually already inactive; this is the belt for the suspenders.)
for unit in "${PAGING_OFF[@]}"; do
  if "$SYSTEMCTL_BIN" is-active --quiet "$unit" 2>/dev/null; then
    "$SYSTEMCTL_BIN" stop "$unit" 2>/dev/null || true
    CHANGED+=("stopped:$unit")
  fi
done

# 2) Enabled organs → per-node-applicable reconcile (RESILIENT-347).
#    a. Not applicable to this node (unmet `requires=`)? Skip — silently, no
#       churn, one advisory event. This is the blast-all -> curated-per-node
#       fix: the pre-347 reconcile tried `enable --now` on every `enabled`
#       line regardless of whether the node could ever run it.
#    b. Still cooling down from a prior verify failure? Skip — this is what
#       stops a structurally-broken organ (wrong binary/role/deps) from being
#       re-installed and re-failing every single cycle.
#    c. Otherwise enable --now, then VERIFY it is actually active a moment
#       later (not just that the systemctl call exited 0 — a oneshot unit can
#       "enable" fine and still fail inside ExecStart). A verify failure
#       disables the unit and starts a backoff cooldown instead of leaving it
#       to churn identically forever.
for unit in "${ENABLED[@]}"; do
  role="${ORGAN_ROLE[$unit]:-brain}"
  requires="${ORGAN_REQUIRES[$unit]:-}"
  reason=""

  if ! organ_is_applicable "$unit" "$requires" reason; then
    echo "SKIP (not applicable to this node): $unit ($reason)"
    # scanner-anchor: "kind":"organ_reconcile_not_applicable" (RESILIENT-347;
    # fires when an `enabled` organ's requires= are unmet on this node — the
    # curated-per-node skip that replaces blast-all install)
    emit organ_reconcile_not_applicable "\"unit\":\"$unit\",\"role\":\"$role\",\"reason\":\"$reason\""
    continue
  fi

  if organ_in_backoff "$unit"; then
    echo "SKIP (backed off, cooling down after a prior failure): $unit"
    # scanner-anchor: "kind":"organ_reconcile_backoff_skip" (RESILIENT-347;
    # fires when a previously-failed organ is still inside its backoff
    # cooldown — proof the reconcile is NOT re-churning it every cycle)
    emit organ_reconcile_backoff_skip "\"unit\":\"$unit\",\"role\":\"$role\""
    continue
  fi

  if "$SYSTEMCTL_BIN" is-active --quiet "$unit" 2>/dev/null; then
    clear_backoff "$unit"
    continue
  fi

  if ! "$SYSTEMCTL_BIN" enable --now "$unit" 2>/dev/null; then
    echo "WARN: could not enable --now $unit" >&2
    # scanner-anchor: "kind":"organ_reconcile_unit_failed" (RESILIENT-305; an
    # organ the manifest marks `enabled` could not be enable --now'd)
    emit organ_reconcile_unit_failed "\"unit\":\"$unit\""
    record_backoff "$unit" "enable_failed"
    CHANGED+=("backoff:$unit")
    # scanner-anchor: "kind":"organ_reconcile_backoff" (RESILIENT-347; fires
    # when an applicable organ fails to enable/verify and the reconcile backs
    # it off instead of retrying it every cycle)
    emit organ_reconcile_backoff "\"unit\":\"$unit\",\"role\":\"$role\",\"reason\":\"enable_failed\""
    continue
  fi

  sleep "$VERIFY_DELAY_S"
  if "$SYSTEMCTL_BIN" is-active --quiet "$unit" 2>/dev/null; then
    CHANGED+=("started:$unit")
    clear_backoff "$unit"
  else
    echo "WARN: $unit enabled but did not verify active — disabling + backing off" >&2
    "$SYSTEMCTL_BIN" disable --now "$unit" 2>/dev/null || true
    record_backoff "$unit" "verify_failed"
    CHANGED+=("backoff:$unit")
    emit organ_reconcile_backoff "\"unit\":\"$unit\",\"role\":\"$role\",\"reason\":\"verify_failed\""
  fi
done

# 3) Drift-REMOVAL pass (RESILIENT-1016 part a). Role-scoped reconcile only:
#    the loop above only ENABLES in-role manifest units, it never
#    disables/reaps units that are present-but-out-of-role (left behind by a
#    prior role install/switch) or no longer in the manifest at all — so
#    stray units persist and fail forever (VERIFIED on mugman: 28 leftover
#    out-of-role brain units stayed failed until hand-reaped, then 28->1).
#    This makes a role install (or role switch) self-cleaning: any chump
#    unit still active/enabled that is NOT in the role-filtered expected set
#    gets disabled --now + reset-failed. Unfiltered (whole-manifest)
#    reconciles skip this — there's nothing "out of role" to reap there.
if [[ -n "$ROLE_FILTER" ]]; then
  declare -A EXPECTED_UNIT
  for unit in "${ENABLED[@]}"; do EXPECTED_UNIT["$unit"]=1; done
  for unit in "${PAGING_OFF[@]}"; do EXPECTED_UNIT["$unit"]=1; done
  while IFS= read -r unit; do
    [[ -z "$unit" ]] && continue
    [[ -n "${EXPECTED_UNIT[$unit]:-}" ]] && continue
    organ_is_live "$unit" || continue
    echo "DRIFT-REMOVE: $unit is active/enabled but out-of-role (not in role-filtered manifest) — disabling + reaping"
    "$SYSTEMCTL_BIN" disable --now "$unit" 2>/dev/null || true
    "$SYSTEMCTL_BIN" reset-failed "$unit" 2>/dev/null || true
    CHANGED+=("removed:$unit")
    # scanner-anchor: "kind":"organ_reconcile_drift_removed" (RESILIENT-1016;
    # fires when a role-scoped reconcile disables+reaps a stray chump unit
    # that is present-but-out-of-role or no longer in the manifest at all —
    # the self-cleaning pass that replaces the 28-unit hand-reap on mugman)
    emit organ_reconcile_drift_removed "\"unit\":\"$unit\""
  done < <(discover_live_chump_units)
fi

# ── report ───────────────────────────────────────────────────────────────────
if [[ "${#CHANGED[@]}" -gt 0 ]]; then
  changed_json="$(printf '"%s",' "${CHANGED[@]}")"
  changed_json="[${changed_json%,}]"
  # scanner-anchor: "kind":"organ_reconcile_applied" (RESILIENT-305; fires only
  # when the reconcile actually changed live systemd state — the drift-healing
  # signal the board can verify)
  emit organ_reconcile_applied "\"changed\":$changed_json"
  echo "organ-reconcile: applied — ${CHANGED[*]}"
else
  # scanner-anchor: "kind":"organ_reconcile_noop" (RESILIENT-305; live state
  # already matched the manifest — the idempotent common path)
  emit organ_reconcile_noop
  echo "organ-reconcile: no-op — live state already matches organ-manifest.txt"
fi
