#!/usr/bin/env bash
# registry-snapshot.sh — RESILIENT-1902
#
# Daily off-node snapshot of the canonical state.db so a dead hub never costs
# registry rows. Rust-First-Bypass: sqlite3 .backup + scp + git glue, no types.
#
#   registry-snapshot.sh snapshot            take + ship a snapshot
#   registry-snapshot.sh restore <src>       <src> = file | refs/stash/registry/<date>
#   registry-snapshot.sh age                 print newest snapshot age in hours (exit 1 if none)
#
# Env: CHUMP_REPO_ROOT, CHUMP_STATE_DB, CHUMP_SNAPSHOT_DIR (~/.chump/snapshots),
#      CHUMP_SNAPSHOT_SLIM (scp target, e.g. slim:.chump/snapshots/; unset = skip),
#      CHUMP_SNAPSHOT_REMOTE (git remote, default origin; "none" = skip),
#      CHUMP_SNAPSHOT_KEEP (default 14), CHUMP_REGISTRY_RESTORE_FORCE=1 (overwrite a populated registry).
set -euo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
STATE_DB="${CHUMP_STATE_DB:-$REPO_ROOT/.chump/state.db}"
SNAP_DIR="${CHUMP_SNAPSHOT_DIR:-$HOME/.chump/snapshots}"
REMOTE="${CHUMP_SNAPSHOT_REMOTE:-origin}"
KEEP="${CHUMP_SNAPSHOT_KEEP:-14}"
REF_PREFIX="refs/stash/registry"

cmd_snapshot() {
    local date; date="$(date -u +%Y-%m-%d)"
    mkdir -p "$SNAP_DIR"
    local out="$SNAP_DIR/state-$date.db"
    rm -f "$out"
    sqlite3 "$STATE_DB" ".backup '$out'"
    [[ "$(sqlite3 "$out" 'PRAGMA integrity_check;')" == "ok" ]] || { echo "snapshot failed integrity_check" >&2; rm -f "$out"; exit 1; }
    gzip -kf "$out"
    echo "snapshot: $out ($(sqlite3 "$out" 'SELECT count(*) FROM gaps;' 2>/dev/null || echo '?') gaps)"

    if [[ -n "${CHUMP_SNAPSHOT_SLIM:-}" ]]; then
        scp -q "$out" "$out.gz" "$CHUMP_SNAPSHOT_SLIM" && echo "scp: $CHUMP_SNAPSHOT_SLIM" \
            || echo "WARN: scp to $CHUMP_SNAPSHOT_SLIM failed" >&2
    fi

    if [[ "$REMOTE" != "none" ]]; then
        # Commit the gzip as a blob-only commit and push to a refs/stash ref: no branch, no CI.
        local blob tree commit
        blob="$(git -C "$REPO_ROOT" hash-object -w "$out.gz")"
        tree="$(printf '100644 blob %s\tstate-%s.db.gz\n' "$blob" "$date" | git -C "$REPO_ROOT" mktree)"
        commit="$(GIT_AUTHOR_NAME=registry-snapshot GIT_AUTHOR_EMAIL=snapshot@chump.local \
            GIT_COMMITTER_NAME=registry-snapshot GIT_COMMITTER_EMAIL=snapshot@chump.local \
            git -C "$REPO_ROOT" commit-tree "$tree" -m "registry snapshot $date")"
        git -C "$REPO_ROOT" update-ref "$REF_PREFIX/$date" "$commit"
        git -C "$REPO_ROOT" push -q "$REMOTE" "+$REF_PREFIX/$date:$REF_PREFIX/$date" \
            && echo "pushed: $REMOTE $REF_PREFIX/$date" \
            || echo "WARN: push to $REMOTE failed" >&2
        # Prune: keep newest $KEEP refs (local + remote).
        local old
        old="$(git -C "$REPO_ROOT" for-each-ref --format='%(refname)' "$REF_PREFIX/" | sort -r | tail -n +"$((KEEP + 1))")"
        for r in $old; do
            git -C "$REPO_ROOT" update-ref -d "$r" || true
            git -C "$REPO_ROOT" push -q "$REMOTE" --delete "$r" 2>/dev/null || true
        done
    fi
    # Prune local files too.
    ls -1 "$SNAP_DIR"/state-*.db 2>/dev/null | sort -r | tail -n +"$((KEEP + 1))" | while read -r f; do rm -f "$f" "$f.gz"; done
}

cmd_restore() {
    local src="${1:?usage: restore <path|refs/stash/registry/<date>>}"
    local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    local db="$tmp/restore.db"
    if [[ "$src" == refs/* ]]; then
        git -C "$REPO_ROOT" fetch -q "$REMOTE" "+$src:$src" </dev/null 2>/dev/null || true
        local name
        name="$(git -C "$REPO_ROOT" ls-tree --name-only "$src" | head -1)"
        [[ -n "$name" ]] || { echo "ref $src not found" >&2; exit 1; }
        git -C "$REPO_ROOT" show "$src:$name" >"$tmp/snap.gz"
        gunzip -c "$tmp/snap.gz" >"$db"
    elif [[ "$src" == *.gz ]]; then
        gunzip -c "$src" >"$db"
    else
        cp "$src" "$db"
    fi
    [[ "$(sqlite3 "$db" 'PRAGMA integrity_check;')" == "ok" ]] || { echo "restore source failed integrity_check" >&2; exit 1; }
    mkdir -p "$(dirname "$STATE_DB")"
    # Safety: never overwrite a populated registry unless explicitly forced.
    if [[ -s "$STATE_DB" && "${CHUMP_REGISTRY_RESTORE_FORCE:-0}" != "1" ]] \
        && [[ "$(sqlite3 "$STATE_DB" 'SELECT count(*) FROM gaps;' 2>/dev/null || echo 0)" != "0" ]]; then
        echo "refusing: $STATE_DB already holds gaps; set CHUMP_REGISTRY_RESTORE_FORCE=1 to overwrite" >&2
        exit 1
    fi
    if [[ -f "$STATE_DB" ]]; then
        cp "$STATE_DB" "$STATE_DB.pre-restore.$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    rm -f "$STATE_DB-wal" "$STATE_DB-shm"
    cp "$db" "$STATE_DB"
    echo "restored $STATE_DB from $src ($(sqlite3 "$STATE_DB" 'SELECT count(*) FROM gaps;' 2>/dev/null || echo '?') gaps)"
}

cmd_age() {
    local newest
    newest="$(ls -1t "$SNAP_DIR"/state-*.db 2>/dev/null | head -1 || true)"
    [[ -n "$newest" ]] || { echo "none"; exit 1; }
    local now mt; now="$(date +%s)"; mt="$(stat -c %Y "$newest" 2>/dev/null || stat -f %m "$newest")"
    echo $(( (now - mt) / 3600 ))
}

case "${1:-}" in
    snapshot) cmd_snapshot ;;
    restore) shift; cmd_restore "$@" ;;
    age) cmd_age ;;
    *) echo "usage: $0 snapshot|restore <src>|age" >&2; exit 2 ;;
esac
