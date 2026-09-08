#!/usr/bin/env bash
# scripts/ops/lib/organ-unit-install-lib.sh — RESILIENT-1055
#
# The ONE host-agnostic systemd-unit rewriter, shared by install-helsinki-atc.sh
# (the primary-node ATC roster placer) and chump-node-install.sh (the --role
# fresh-node bring-up placer). Before this lib, the host-rewrite sed logic lived
# ONLY inside install-helsinki-atc.sh, so a fresh `chump-node-install --role`
# never placed the role's tracked unit files at all — it only ran
# organ-reconcile's `systemctl enable --now`, which fails on a unit whose file
# was never copied into /etc/systemd/system (-> perpetual `backoff:` for every
# manifest organ that had no file on the box). Extracting the rewriter here lets
# the fresh-node installer PLACE the role roster from the same tracked source,
# host-rewritten identically, so `enable --now` finds a real unit.
#
# WHY host-rewrite at all (RESILIENT-353 / INFRA-3647 / RESILIENT-1051): the
# tracked units in scripts/dispatch/ are NOT all one shape — several are
# helsinki-shaped (User=root, HOME=/root, /root/.cargo) and several are
# CJ-native (User=jeff, /home/jeff/...). Verbatim-copying either shape onto a
# THIRD box (e.g. an ubuntu Oracle node, User=ubuntu, /home/ubuntu) installs a
# unit whose WorkingDirectory/HOME/User don't exist there -> CHDIR/127 every
# cycle, or (the "instruments lie" keystone) a bare `Environment=HOME=/root`
# that survives a naive prefix-rewrite and makes every tool read /root/.config.
# organ_unit_host_rewrite detects each unit's OWN baked-in source user and
# rewrites THAT home, then injects a uniform host-agnostic runtime context, so
# the SAME manifest wires correctly on any host.

# organ_unit_host_rewrite <src-file> <dest-file> <run-user> <run-home> [keep_root]
#   Writes the host-rewritten unit from <src-file> to <dest-file>.
#   run-user / run-home: the box's repo-owning user + that user's real HOME.
#   keep_root (optional, "1"): force User=root even after the rewrite — for the
#     one narrow class of organs whose JOB is the privileged system-unit deploy
#     (chump-organ-deploy.*), which a de-privileged rewrite would break
#     (RESILIENT-374). Everything else runs as the repo-owning user.
#   Returns non-zero if <src-file> is missing.
organ_unit_host_rewrite() {
  local src="$1" dest="$2" run_user="$3" run_home="$4" keep_root="${5:-0}"
  [[ -f "$src" ]] || { echo "organ_unit_host_rewrite: missing src $src" >&2; return 1; }

  local repo_on_host="${run_home%/}/Projects/chump"

  # Detect the unit's OWN baked-in source user (its `User=` line; default root
  # when absent, matching the historical helsinki shape) and rewrite THAT home.
  local src_user src_home
  src_user="$(grep -m1 -E '^User=' "$src" | cut -d= -f2 || true)"
  [[ -z "$src_user" ]] && src_user="root"
  if [[ "$src_user" == "root" ]]; then
    src_home="/root"
  else
    src_home="$(getent passwd "$src_user" 2>/dev/null | cut -d: -f6 || true)"
    [[ -z "$src_home" ]] && src_home="/home/$src_user"
  fi

  # s#$SRC_HOME/#...#g  -> path PREFIXES ($SRC_HOME/Projects, $SRC_HOME/.chump, …)
  # s#=$SRC_HOME$#...#  -> a BARE $SRC_HOME as the WHOLE value of an assignment
  #                       (chiefly `Environment=HOME=/root`, no trailing slash).
  # s#^User=$SRC_USER$# -> the User= line itself.
  sed -e "s#${src_home%/}/#${run_home%/}/#g" \
      -e "s#=${src_home%/}\$#=${run_home%/}#" \
      -e "s#^User=${src_user}\$#User=${run_user}#" "$src" > "$dest"

  # Uniform host-agnostic runtime context for EVERY generated organ (one
  # pattern, not per-service): run as the repo-owning user (git/ssh/cargo), that
  # user's real HOME, ~/.cargo/bin on PATH, cwd at the repo root — so cwd-based
  # tools (chump gap, gh repo view) don't run from / and $HOME-based tools (gh,
  # almanac) read the run-user's config, on any host.
  if grep -q "^\[Service\]" "$dest"; then
    grep -q "^User=" "$dest"             || sed -i "/^\[Service\]/a User=${run_user}" "$dest"
    grep -q "^Environment=HOME=" "$dest" || sed -i "/^\[Service\]/a Environment=HOME=${run_home%/}" "$dest"
    grep -q "^WorkingDirectory=" "$dest" || sed -i "/^\[Service\]/a WorkingDirectory=${repo_on_host}" "$dest"
    grep -q "^Environment=PATH=" "$dest" || sed -i "/^\[Service\]/a Environment=PATH=${run_home%/}/.cargo/bin:/usr/local/bin:/usr/bin:/bin" "$dest"
  fi

  # RESILIENT-374: re-assert User=root for keep-root organs (the deploy organ).
  # Narrow, explicit, and the ONLY place a unit is forced back to root.
  if [[ "$keep_root" == "1" ]]; then
    if grep -q "^User=" "$dest"; then
      sed -i "s#^User=.*#User=root#" "$dest"
    else
      sed -i "/^\[Service\]/a User=root" "$dest"
    fi
  fi
  return 0
}

# organ_unit_run_user <repo-root> — the box's repo-owning user (git/ssh/cargo
# identity) that units should run as. Mirrors install-helsinki-atc.sh's
# CHUMP_RUN_USER derivation so both placers agree on the host identity.
organ_unit_run_user() {
  local repo_root="$1"
  echo "${CHUMP_RUN_USER:-$(stat -c %U "$repo_root" 2>/dev/null || echo root)}"
}

# organ_unit_run_home <run-user> — that user's real HOME (passwd), falling back
# to /home/<user>.
organ_unit_run_home() {
  local run_user="$1" h
  h="$(getent passwd "$run_user" 2>/dev/null | cut -d: -f6 || true)"
  [[ -z "$h" ]] && h="/home/$run_user"
  echo "$h"
}
