#!/usr/bin/env bash
# merge-driver-state-sql-regen.sh — INFRA-310 / INFRA-367
#
# Custom git merge driver for `.chump/state.sql`. Wired in via
# `.gitattributes`:
#
#   .chump/state.sql merge=chump-state-sql-regen
#
# And registered in `.git/config` by scripts/setup/install-merge-drivers.sh:
#
#   [merge "chump-state-sql-regen"]
#       name = Regenerate .chump/state.sql from .chump/state.db on conflict
#       driver = scripts/git/merge-driver-state-sql-regen.sh %O %A %B %P
#
# Why: `.chump/state.sql` is a *regenerated artifact* of `.chump/state.db`
# (the canonical SQLite gap registry). Every parallel `chump gap reserve`
# bumps the dump, so any multi-day rebase hits chronic textual conflicts —
# observed 1400-line / 2400-line diffs on PRs #972 and #990 (2026-05-03).
#
# The conflicts are *trivially resolvable* — the canonical fix is to
# regenerate from the local state.db. This driver does exactly that, then
# returns success so the rebase / merge proceeds without operator
# intervention.
#
# git invokes us with: %O = ancestor blob, %A = current blob, %B = other blob,
# %P = pathname. We only need %A (the file we'll write back) and %P (the
# target pathname relative to repo root).
#
# Contract:
#   - Exit 0 if we successfully wrote a clean state.sql to %A
#   - Exit 1 if regeneration failed — git falls back to manual conflict
#     markers, which is the pre-INFRA-310 behavior (no regression risk)

set -euo pipefail

ANCESTOR="${1:?ancestor blob path}"
CURRENT="${2:?current blob path}"
OTHER="${3:?other blob path}"
PATHNAME="${4:?pathname}"

# We're called from the repo root by git's merge machinery. Resolve chump
# binary preferring the explicit override, then PATH lookup.
CHUMP_BIN="${CHUMP_BIN:-chump}"
if ! command -v "$CHUMP_BIN" >/dev/null 2>&1; then
    echo "[merge-state-sql] chump binary not found (\$CHUMP_BIN=$CHUMP_BIN); falling back to manual conflict" >&2
    exit 1
fi

# Sanity check: only act on the file we expect to be wired for.
if [[ "$PATHNAME" != ".chump/state.sql" ]]; then
    echo "[merge-state-sql] WARNING: invoked on unexpected path $PATHNAME — falling back to manual conflict" >&2
    exit 1
fi

# Sanity check: state.db must exist locally — without it `chump gap dump`
# can't produce a meaningful state.sql. (Fresh worktree case where state.db
# wasn't seeded — fall through to manual.)
if [[ ! -f .chump/state.db ]]; then
    echo "[merge-state-sql] .chump/state.db not present locally — falling back to manual conflict" >&2
    exit 1
fi

# Regenerate state.sql from the local DB. We deliberately use --out pointing
# at the temp blob path %A that git gave us (not at .chump/state.sql) so
# git's merge driver contract is honored.
TMP_OUT="$(mktemp -t chump-state-sql-regen.XXXXXX)"
trap 'rm -f "$TMP_OUT"' EXIT

if ! CHUMP_BINARY_STALENESS_CHECK=0 "$CHUMP_BIN" gap dump --out "$TMP_OUT" >/dev/null 2>&1; then
    echo "[merge-state-sql] chump gap dump failed — falling back to manual conflict" >&2
    exit 1
fi

# Replace %A with the regenerated dump.
if ! cp "$TMP_OUT" "$CURRENT"; then
    echo "[merge-state-sql] failed to write regenerated dump to $CURRENT — falling back" >&2
    exit 1
fi

echo "[merge-state-sql] regenerated $PATHNAME from local .chump/state.db (INFRA-310)"
exit 0
