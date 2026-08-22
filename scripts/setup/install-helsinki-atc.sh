#!/usr/bin/env bash
# scripts/setup/install-helsinki-atc.sh — RESILIENT-300, auto-deploy path INFRA-3593
#
# Establishes the full "ATC roster" on the primary node (helsinki) from a
# fresh clone: the self-maintenance daemons that keep the shipping pipeline
# moving without an agent having to remember them:
#
#   chump-pr-lander      (RESILIENT-288) — arms green-but-unarmed PRs so they merge
#   chump-armed-rebaser  (INFRA-3473)    — rebases armed PRs that drift BEHIND/DIRTY
#   chump-rot-reaper     (RESILIENT-324) — closes CONFLICTING+old PRs (which the
#                                           rebaser CANNOT rebase) + re-queues
#                                           their gaps, so the back-pressure
#                                           breaker can never deadlock in the
#                                           4–5 hysteresis dead-zone
#   chump-node-refresh   (RESILIENT-200) — keeps the installed chump binary current
#   chump-board-cycle    (INFRA-3590)    — Sonnet board-cycle agent: SLA score +
#                                           stall classify + Discord report, zero
#                                           desktop session required
#   chump-sla-scorecard  (RESILIENT-302) — flags PRs open >30m unmerged with no
#                                           owner as a board BREACH
#   chump-organ-watchdog (INFRA-3595)    — self-heals any failed chump-*
#                                           organ (reset-failed + restart), no
#                                           human step required
#   chump-board-ceo-briefing (INFRA-3601) — board strategy layer: one thing,
#                                           bottleneck, operator-only
#                                           decisions, on-mission drift check,
#                                           on boot + hourly. Distinct from
#                                           chump-board-cycle (the ops SLA
#                                           scorecard, which watches the
#                                           factory) — this watches the
#                                           mission.
#   chump-organ-reconcile (RESILIENT-305) — converges live systemd organ state
#                                           to the repo-declared manifest
#                                           (scripts/ops/organ-manifest.txt):
#                                           enables the organs that must run and
#                                           neuters the auto-pagers that must
#                                           stay OFF. Runs on a timer so drift
#                                           between the repo and the node self-
#                                           heals — including a pager this very
#                                           installer just re-enabled.
#   chump-almanac-liveness (INFRA-3643)  — systemd complement to the macOS-only
#                                           almanac-summarize-watchdog
#                                           (RESILIENT-354): binary presence +
#                                           index freshness for the almanac
#                                           fusion-search organ on Linux nodes.
#
# Before RESILIENT-300, these were live-hacked directly into /etc/systemd/system
# and ~/.config/systemd/user — a node rebuild silently lost ATC. This script is
# the single, idempotent entrypoint that re-establishes the whole roster from
# tracked repo files.
#
# pr-lander, armed-rebaser, sla-scorecard, board-cycle, organ-watchdog,
# board-ceo-briefing are SYSTEM units
# (root-owned, /etc/systemd/system) — this script must run as root (or via
# sudo). node-refresh is a USER unit (systemd --user) — installed by
# delegating to install-node-refresh-systemd.sh.
#
# Idempotent: safe to re-run any time (e.g. after a node rebuild, or to pick up
# unit-file changes) — copies + daemon-reload + enable --now every time.
#
# INFRA-3593: this is also the AUTO-DEPLOY entrypoint. node-refresh-chump.sh
# (RESILIENT-200) calls this script with --auto after every fast-forward to
# origin/main, so a merge that touches a chump-*.service/.timer file installs
# on helsinki with no human step — mirroring how node-refresh already
# auto-deploys binary changes. --auto diffs each tracked unit file against
# what's live in /etc/systemd/system BEFORE copying, and emits
# kind=organ_units_deployed (listing only the units that actually changed)
# so the board can verify the auto-deploy ran (AC 7). If nothing changed, it
# emits kind=organ_units_deploy_skipped instead — quiet on the common path,
# but still observable that the check happened (INFRA-3593 AC 1/7).
# --auto degrades to a warning (not a hard failure) when not root, since it
# may be invoked from a non-privileged refresh context — see
# kind=organ_units_deploy_failed reason=not_root.
#
# Usage:
#   sudo bash scripts/setup/install-helsinki-atc.sh
#   sudo bash scripts/setup/install-helsinki-atc.sh --check   # exit 0 iff all timers active
#   bash scripts/setup/install-helsinki-atc.sh --auto         # merge-triggered auto-deploy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
AMBIENT_LOG="${NODE_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
LIB_AMBIENT="$REPO_ROOT/scripts/coord/lib/ambient-write.sh"
[[ -f "$LIB_AMBIENT" ]] && source "$LIB_AMBIENT"

# TREK-18 (INFRA-3644): the manifest parser is shared with organ-reconcile.sh
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
    [[ -d "$(dirname "$AMBIENT_LOG")" ]] && _ambient_write "$AMBIENT_LOG" "$line"
  else
    [[ -d "$(dirname "$AMBIENT_LOG")" ]] && printf '%s\n' "$line" >> "$AMBIENT_LOG" 2>/dev/null || true
  fi
}

# TREK-18 (INFRA-3644): the roster used to be a hand-maintained literal array
# here — a second source of truth alongside scripts/ops/organ-manifest.txt.
# That drift class bit twice: RESILIENT-366 caught organs in THIS array with
# no manifest line (unrevivable), and the inverse also happened silently —
# chump-conflict-resolution-consumer.timer and chump-gap-closure-reconcile.timer
# were both `enabled` in the manifest but never installed here, because
# adding a manifest line was never sufficient on its own.
#
# Now the roster is DERIVED from organ-manifest.txt (via the shared
# organ_manifest_parse() helper, TREK-18) intersected with the tracked unit
# files under scripts/dispatch/ — the only two facts that matter: "does the
# manifest want this organ" and "do we have a unit file for it". A manifest
# `enabled` OR `paging_off` line is enough to get an organ installed +
# enabled here; `paging_off` organs still need their .timer enabled (only
# their .service ExecStart gets neutered, by organ-reconcile below) so both
# states contribute basenames to the roster.
#
# chump-organ-reconcile itself is the one deliberate exception (see the
# manifest header): its own liveness is this installer's job, not something
# the reconcile can bootstrap for itself, so it is always included.
MANIFEST_FOR_ROSTER="$REPO_ROOT/scripts/ops/organ-manifest.txt"
declare -a _M_PAGING_OFF=()
declare -a _M_ENABLED=()
declare -A _M_ROLE=()
declare -A _M_REQUIRES=()
organ_manifest_parse "$MANIFEST_FOR_ROSTER" _M_PAGING_OFF _M_ENABLED _M_ROLE _M_REQUIRES || exit 1

declare -A _ORGAN_BASENAMES=()
for _u in "${_M_ENABLED[@]}" "${_M_PAGING_OFF[@]}"; do
  _base="${_u%.service}"; _base="${_base%.timer}"
  _ORGAN_BASENAMES["$_base"]=1
done
_ORGAN_BASENAMES["chump-organ-reconcile"]=1   # self-exempt from the manifest, see above

SYSTEM_UNITS=()
while IFS= read -r _base; do
  [[ -f "$REPO_ROOT/scripts/dispatch/${_base}.service" ]] && SYSTEM_UNITS+=("${_base}.service")
  [[ -f "$REPO_ROOT/scripts/dispatch/${_base}.timer" ]] && SYSTEM_UNITS+=("${_base}.timer")
done < <(printf '%s\n' "${!_ORGAN_BASENAMES[@]}" | sort)

SYSTEM_TIMERS=()
for _u in "${SYSTEM_UNITS[@]}"; do
  [[ "$_u" == *.timer ]] && SYSTEM_TIMERS+=("$_u")
done

if [[ "${#SYSTEM_UNITS[@]}" -eq 0 ]]; then
  echo "ERROR: manifest-derived roster is empty — organ-manifest.txt unreadable or no scripts/dispatch/ unit files matched" >&2
  exit 1
fi

# ── --print-roster (debug/CI helper) ─────────────────────────────────────────
# Prints the derived roster, one unit per line, and exits — no root, no
# systemctl, no side effects. Lets CI assert "every manifest-declared organ
# with a tracked unit file lands in the roster" without touching a real
# systemd bus (used by scripts/ci/test-resilient-366-organ-roll-call.sh).
if [[ "${1:-}" == "--print-roster" ]]; then
  printf '%s\n' "${SYSTEM_UNITS[@]}"
  exit 0
fi

# ── --check mode ─────────────────────────────────────────────────────────────
# TREK-18 (AC3): delegate to organ-reconcile.sh --check — the SAME
# manifest-derived source of truth this installer's roster is built from —
# instead of re-checking only the hardcoded roster subset. This makes --check
# exit 0 iff every manifest-derived `enabled` organ (applicable to this node,
# not in backoff) is active, and every `paging_off` organ is neutered.
if [[ "${1:-}" == "--check" ]]; then
  fail=0
  ORGAN_RECONCILE_FOR_CHECK="$REPO_ROOT/scripts/ops/organ-reconcile.sh"
  if [[ -x "$ORGAN_RECONCILE_FOR_CHECK" ]]; then
    bash "$ORGAN_RECONCILE_FOR_CHECK" --check || fail=1
  else
    echo "WARN: $ORGAN_RECONCILE_FOR_CHECK missing; falling back to roster-only check" >&2
    for t in "${SYSTEM_TIMERS[@]}"; do
      if ! systemctl is-active --quiet "$t" 2>/dev/null; then
        echo "MISSING: $t not active"; fail=1
      fi
    done
  fi
  if ! systemctl --user is-active --quiet chump-node-refresh.timer 2>/dev/null; then
    echo "MISSING: chump-node-refresh.timer (user) not active"; fail=1
  fi
  [[ "$fail" == 0 ]] && echo "ok: full ATC roster active"
  exit "$fail"
fi

AUTO=0
[[ "${1:-}" == "--auto" ]] && AUTO=1

# RESILIENT-347: stubbable systemd dest-dir + systemctl + root-check (test
# hooks, mirror organ-reconcile.sh's CHUMP_ORGAN_RECONCILE_* pattern) so the
# full --auto roster-install path — including a per-unit enable failure —
# can be exercised in CI without touching a real /etc/systemd/system.
SYSTEMD_DEST_DIR="${CHUMP_INSTALL_ATC_SYSTEMD_DIR:-/etc/systemd/system}"
SYSTEMCTL_BIN="${CHUMP_INSTALL_ATC_SYSTEMCTL_BIN:-systemctl}"

if [[ "$(id -u)" != "0" && "${CHUMP_INSTALL_ATC_ALLOW_NONROOT:-0}" != "1" ]]; then
  if [[ "$AUTO" == "1" ]]; then
    echo "WARN: --auto invoked without root; skipping system-unit deploy (this worker context cannot install system units)" >&2
    # scanner-anchor: "kind":"organ_units_deploy_failed"  (INFRA-3593; fires
    # when the auto-deploy caller lacks root and cannot write /etc/systemd/system)
    emit organ_units_deploy_failed "\"reason\":\"not_root\""
    exit 0
  fi
  echo "ERROR: system units require root (sudo bash $0)" >&2
  exit 1
fi

echo "== installing system units (pr-lander, armed-rebaser, sla-scorecard, board-cycle, organ-watchdog, board-ceo-briefing, organ-reconcile, pr-approval) =="
# RESILIENT-353: HOST-AGNOSTIC reconcile. The tracked units are helsinki-shaped
# (User=root, /root/.chump, /root/.cargo). Verbatim-copying them onto an owned
# node (CJ=jeff, Termux, ...) installs broken units that source a nonexistent
# /root/.chump and run as the wrong user (no git/ssh/cargo). Rewrite per-host on
# copy so the SAME manifest wires correctly everywhere — this is what lets
# organ-watchdog end the shipped-but-dark disease on any node, not just helsinki.
RUN_USER="${CHUMP_RUN_USER:-$(stat -c %U "$REPO_ROOT" 2>/dev/null || echo root)}"
RUN_HOME="$(getent passwd "$RUN_USER" 2>/dev/null | cut -d: -f6)"; [[ -z "$RUN_HOME" ]] && RUN_HOME="/home/$RUN_USER"
echo "  host-rewrite target: User=$RUN_USER HOME=$RUN_HOME"
mkdir -p "$SYSTEMD_DEST_DIR"
CHANGED_UNITS=()
for unit in "${SYSTEM_UNITS[@]}"; do
  src="$REPO_ROOT/scripts/dispatch/$unit"
  dest="$SYSTEMD_DEST_DIR/$unit"
  if [[ ! -f "$src" ]]; then
    echo "ERROR: $src not found" >&2
    exit 1
  fi
  tmp="$(mktemp)"
  # RESILIENT-353 / INFRA-3647 host-rewrite. Tracked units are helsinki-shaped
  # (User=root, HOME=/root, /root/... paths). Rewrite per host so the SAME
  # manifest wires correctly on an owned node:
  #   s#/root/#...#g  -> path PREFIXES (/root/Projects, /root/.chump, ...)
  #   s#=/root$#...#  -> a BARE /root as the WHOLE value of an assignment, the
  #                      class the prefix rule silently missed. Chiefly
  #                      `Environment=HOME=/root` (no trailing slash): it
  #                      survived the prefix sed, so on an owned node HOME
  #                      stayed /root even as User= flipped to jeff, and every
  #                      tool read /root/.config/gh, /root/.almanac, cwd=/ and
  #                      failed CLOSED while reporting fake-perfect ("instruments
  #                      lie" keystone). Also covers a bare WorkingDirectory=/root.
  sed -e "s#/root/#${RUN_HOME%/}/#g" \
      -e "s#=/root\$#=${RUN_HOME%/}#" \
      -e "s#^User=root#User=${RUN_USER}#" "$src" > "$tmp"
  # Host-agnostic runtime context for EVERY generated organ, applied uniformly
  # (one pattern, not per-service): run as the repo-owning user (git/ssh/cargo),
  # with that user's real HOME, ~/.cargo/bin on PATH, and cwd at the repo root,
  # so cwd-based tools (chump gap, gh repo view) don't run from / and
  # $HOME-based tools (gh, almanac) read the run-user's config, on any host.
  if grep -q "^\[Service\]" "$tmp"; then
    _repo_on_host="${RUN_HOME%/}/Projects/chump"
    grep -q "^User=" "$tmp"             || sed -i "/^\[Service\]/a User=${RUN_USER}" "$tmp"
    grep -q "^Environment=HOME=" "$tmp" || sed -i "/^\[Service\]/a Environment=HOME=${RUN_HOME%/}" "$tmp"
    grep -q "^WorkingDirectory=" "$tmp" || sed -i "/^\[Service\]/a WorkingDirectory=${_repo_on_host}" "$tmp"
    grep -q "^Environment=PATH=" "$tmp" || sed -i "/^\[Service\]/a Environment=PATH=${RUN_HOME%/}/.cargo/bin:/usr/local/bin:/usr/bin:/bin" "$tmp"
  fi
  if [[ ! -f "$dest" ]] || ! cmp -s "$tmp" "$dest"; then
    CHANGED_UNITS+=("$unit")
  fi
  cp -f "$tmp" "$dest"; rm -f "$tmp"
  echo "  installed $unit (host-rewritten -> $RUN_USER)"
done

# RESILIENT-318 / INFRA-2130: the Batched Merge Train needs its own binary, which
# node-refresh-chump.sh does NOT build (it only refreshes `chump`). Ensure it
# exists so a fresh node boots with a WORKING merge train, not a timer that
# fails on a missing binary. Best-effort + non-fatal: a build failure must never
# block the rest of the ATC roster (the timer safely no-ops until the binary
# lands). Idempotent: only builds when the binary is absent.
INTEGRATOR_BIN_DEST="${CARGO_BIN_DIR:-/root/.cargo/bin}/chump-integrator"
if [[ ! -x "$INTEGRATOR_BIN_DEST" ]]; then
  _staged=""
  for cand in "$REPO_ROOT/target/release/chump-integrator" "$REPO_ROOT/target/debug/chump-integrator"; do
    [[ -x "$cand" ]] && { _staged="$cand"; break; }
  done
  if [[ -z "$_staged" ]] && command -v cargo >/dev/null 2>&1; then
    echo "== building chump-integrator binary (Batched Merge Train) =="
    if (cd "$REPO_ROOT" && cargo build --release -p chump-integrator --bin chump-integrator) 2>&1; then
      _staged="$REPO_ROOT/target/release/chump-integrator"
    else
      echo "WARN: chump-integrator build failed (non-fatal; timer no-ops until binary lands)" >&2
    fi
  fi
  if [[ -n "$_staged" && -x "$_staged" ]]; then
    install -m 0755 "$_staged" "$INTEGRATOR_BIN_DEST" \
      && echo "  installed chump-integrator -> $INTEGRATOR_BIN_DEST"
  fi
fi

if ! "$SYSTEMCTL_BIN" daemon-reload 2>&1; then
  echo "ERROR: systemctl daemon-reload failed (no systemd bus reachable?)" >&2
  emit organ_units_deploy_failed "\"reason\":\"systemctl_daemon_reload_failed\""
  [[ "$AUTO" == "1" ]] && exit 0
  exit 1
fi
# RESILIENT-347: a single timer failing to `enable --now` (e.g.
# chump-integrator.timer/chump-backlog-sync-writer.timer/chump-farmer.timer
# on a node missing that organ's binary/deps) must NOT abort the whole
# --auto roster install. Before this fix, `exit 0` here under --auto meant
# the run stopped dead on the FIRST failing unit and never reached the
# ORGAN_RECONCILE call below — so the curated per-node-applicable reconcile
# (which backs the failing unit off cleanly instead of re-churning it) never
# even got a chance to run. Non---auto (manual sudo invocation) still hard-
# fails, since an operator running this by hand wants to see the error stop
# the script rather than have it silently continue.
for t in "${SYSTEM_TIMERS[@]}"; do
  if ! "$SYSTEMCTL_BIN" enable --now "$t" 2>&1; then
    echo "ERROR: systemctl enable --now $t failed" >&2
    emit organ_units_deploy_failed "\"reason\":\"systemctl_enable_failed\",\"unit\":\"$t\""
    if [[ "$AUTO" == "1" ]]; then
      continue
    fi
    exit 1
  fi
  echo "  enabled + started $t"
done

# RESILIENT-305: converge organ state to the repo manifest immediately, rather
# than waiting for chump-organ-reconcile.timer's first tick. Critically, THIS
# installer's own enable-loop just (re-)started the pager timers
# (sla-scorecard, board-ceo-briefing); the reconcile re-neuters them from the
# repo-declared manifest so a deploy can never resurrect the auto-pagers. Best
# -effort: a failure here must not block the roster install above.
ORGAN_RECONCILE="$REPO_ROOT/scripts/ops/organ-reconcile.sh"
if [[ -x "$ORGAN_RECONCILE" ]]; then
  echo "== reconciling organ manifest (enabled organs up, auto-pagers OFF) =="
  bash "$ORGAN_RECONCILE" --apply || echo "WARN: organ-reconcile failed (non-fatal; roster units still installed)" >&2
fi

echo "== installing user unit (node-refresh) =="
# node-refresh runs as the operator user (not root's systemd --user unless
# helsinki genuinely operates as root), so hand off to its own installer,
# which generates the unit files directly rather than tracking static copies.
NODE_REFRESH_INSTALLER="$REPO_ROOT/scripts/setup/install-node-refresh-systemd.sh"
if [[ ! -f "$NODE_REFRESH_INSTALLER" ]]; then
  echo "ERROR: $NODE_REFRESH_INSTALLER not found" >&2
  exit 1
fi
# INFRA-3598: never bake an EPHEMERAL session worktree
# (.claude/worktrees/<gap>-<ts>/) into the persisted node-refresh unit's
# CHUMP_NODE_REPO. This script's own REPO_ROOT is "wherever this file
# currently lives on disk" — fine for the SYSTEM_UNITS copy step above
# (idempotent, re-copies from wherever it's invoked), but fatal for
# node-refresh: that env var gets written into ~/.config/systemd/user's
# Environment= line and persists there until the next install. A worktree
# invocation (e.g. an agent session manually re-running this script to test
# a change) would clobber the shared timer to build from a scratch dir that
# gets deleted at session end, silently breaking "helsinki clone auto-stays-
# current" until someone notices and reinstalls from a stable mirror. Proof:
# exactly this happened on 2026-08-11 (unit found pointing at an
# infra-3593-fleet-1-* worktree that no longer matched a live checkout).
#
# If REPO_ROOT looks ephemeral, DON'T pass CHUMP_NODE_REPO at all — the
# installer's own fallback chain (CHUMP_NODE_REPO env -> $HOME/chump-host ->
# $HOME/Projects/Chump -> its own $0-relative path) already tries
# $HOME/chump-host next, which is the stable mirror on helsinki.
if [[ "$REPO_ROOT" == *"/.claude/worktrees/"* ]]; then
  echo "  NOTE: this script is running from an ephemeral worktree ($REPO_ROOT)."
  echo "        Not propagating it as CHUMP_NODE_REPO — letting the installer"
  echo "        fall back to a stable mirror (\$HOME/chump-host or similar)."
  bash "$NODE_REFRESH_INSTALLER" \
    || echo "WARN: node-refresh user-unit install failed (non-fatal; system units above still installed)" >&2
else
  CHUMP_NODE_REPO="$REPO_ROOT" bash "$NODE_REFRESH_INSTALLER" \
    || echo "WARN: node-refresh user-unit install failed (non-fatal; system units above still installed)" >&2
fi

echo ""
echo "== ATC roster status =="
systemctl list-timers "${SYSTEM_TIMERS[@]}" --no-pager 2>/dev/null || true
systemctl --user list-timers chump-node-refresh.timer --no-pager 2>/dev/null || true

if [[ "${#CHANGED_UNITS[@]}" -gt 0 ]]; then
  units_json="$(printf '"%s",' "${CHANGED_UNITS[@]}")"
  units_json="[${units_json%,}]"
  # scanner-anchor: "kind":"organ_units_deployed"  (INFRA-3593; fires only
  # when a chump-*.service/.timer diff was actually installed — the
  # merge-triggered auto-deploy signal the board polls to verify AC 1/7)
  emit organ_units_deployed "\"units\":$units_json,\"auto\":$([[ "$AUTO" == 1 ]] && echo true || echo false)"
  echo ""
  echo "deployed (changed): ${CHANGED_UNITS[*]}"
else
  # scanner-anchor: "kind":"organ_units_deploy_skipped"  (INFRA-3593; no unit
  # diff found — roster already current, no-op on the common auto-deploy path)
  emit organ_units_deploy_skipped "\"auto\":$([[ "$AUTO" == 1 ]] && echo true || echo false)"
fi

echo ""
echo "Verify: bash $0 --check"
