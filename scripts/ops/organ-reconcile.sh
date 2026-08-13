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

AMBIENT_LOG="${NODE_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
LIB_AMBIENT="$REPO_ROOT/scripts/coord/lib/ambient-write.sh"
[[ -f "$LIB_AMBIENT" ]] && source "$LIB_AMBIENT"

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

# ── read manifest into two arrays ────────────────────────────────────────────
PAGING_OFF=()
ENABLED=()
if [[ ! -f "$MANIFEST" ]]; then
  echo "ERROR: manifest not found: $MANIFEST" >&2
  exit 1
fi
while read -r state unit _rest; do
  [[ -z "${state:-}" ]] && continue
  [[ "$state" == \#* ]] && continue
  case "$state" in
    paging_off) PAGING_OFF+=("$unit") ;;
    enabled)    ENABLED+=("$unit") ;;
    *) echo "WARN: unknown state '$state' for '$unit' in manifest; ignoring" >&2 ;;
  esac
done < "$MANIFEST"

MODE="${1:---apply}"

# ── --check mode: verify live state matches the manifest, change nothing ─────
if [[ "$MODE" == "--check" ]]; then
  fail=0
  for unit in "${PAGING_OFF[@]}"; do
    # effective ExecStart must be neutered to /bin/true
    if ! systemctl show "$unit" -p ExecStart 2>/dev/null | grep -q '/bin/true'; then
      echo "DRIFT: $unit auto-paging is NOT neutered"; fail=1
    fi
  done
  for unit in "${ENABLED[@]}"; do
    if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
      echo "DRIFT: $unit is not active"; fail=1
    fi
  done
  [[ "$fail" == 0 ]] && echo "ok: live systemd state matches organ-manifest.txt"
  exit "$fail"
fi

# ── --apply mode ─────────────────────────────────────────────────────────────
if [[ "$(id -u)" != "0" ]]; then
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
  systemctl daemon-reload
fi

# Stop any pager still running so an in-flight page cycle halts. (Oneshot pagers
# are usually already inactive; this is the belt for the suspenders.)
for unit in "${PAGING_OFF[@]}"; do
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    systemctl stop "$unit" 2>/dev/null || true
    CHANGED+=("stopped:$unit")
  fi
done

# 2) Enabled organs → enable --now if not already active.
for unit in "${ENABLED[@]}"; do
  if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
    if systemctl enable --now "$unit" 2>/dev/null; then
      CHANGED+=("started:$unit")
    else
      echo "WARN: could not enable --now $unit" >&2
      # scanner-anchor: "kind":"organ_reconcile_unit_failed" (RESILIENT-305; an
      # organ the manifest marks `enabled` could not be enable --now'd)
      emit organ_reconcile_unit_failed "\"unit\":\"$unit\""
    fi
  fi
done

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
