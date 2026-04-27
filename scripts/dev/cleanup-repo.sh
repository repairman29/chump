#!/usr/bin/env bash
# Reclaim disk: Cargo + SwiftPM build dirs; optionally tarball sessions/ + logs/ before pruning.
# Does not delete source, docs, or .env files.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

DRY_RUN=0
CLEAN_TARGET=1
CLEAN_CHUMPMENU=1
ARCHIVE_RUNTIME=0
PRUNE_AFTER=0

ARCHIVE_DIR="${CHUMP_ARCHIVE_DIR:-$ROOT/archive}"

usage() {
  cat <<'EOF'
Usage: cleanup-repo.sh [options]

  --dry-run              Print actions only
  --no-cargo-target      Skip cargo clean
  --no-chumpmenu-build   Skip rm -rf ChumpMenu/.build
  --archive-runtime      Create a .tar.gz of sessions/ and logs/ under CHUMP_ARCHIVE_DIR
  --prune-runtime-after-archive  After a successful archive, remove contents of sessions/ and logs/
  -h, --help             This help

Environment:
  CHUMP_ARCHIVE_DIR      Directory for tarballs (default: ./archive)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-cargo-target) CLEAN_TARGET=0 ;;
    --no-chumpmenu-build) CLEAN_CHUMPMENU=0 ;;
    --archive-runtime) ARCHIVE_RUNTIME=1 ;;
    --prune-runtime-after-archive) PRUNE_AFTER=1; ARCHIVE_RUNTIME=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

if [[ "$CLEAN_TARGET" -eq 1 ]]; then
  if [[ -d "$ROOT/target" ]]; then
    echo "== Cargo: cleaning target/ (rebuild with cargo build) =="
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[dry-run] cargo clean"
    else
      cargo clean
    fi
  else
    echo "== Cargo: no target/ directory =="
  fi
fi

if [[ "$CLEAN_CHUMPMENU" -eq 1 ]]; then
  if [[ -d "$ROOT/ChumpMenu/.build" ]]; then
    echo "== ChumpMenu: removing .build/ =="
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[dry-run] rm -rf ChumpMenu/.build"
    else
      rm -rf "$ROOT/ChumpMenu/.build"
    fi
  else
    echo "== ChumpMenu: no .build/ =="
  fi
fi

if [[ "$ARCHIVE_RUNTIME" -eq 1 ]]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  OUT="$ARCHIVE_DIR/chump-runtime-$TS.tar.gz"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would mkdir -p $ARCHIVE_DIR"
    echo "[dry-run] would create $OUT from sessions/ and logs/ with ARCHIVE_MANIFEST.txt inside"
    if [[ "$PRUNE_AFTER" -eq 1 ]]; then
      echo "[dry-run] would prune contents of sessions/ and logs/"
    fi
  else
    mkdir -p "$ARCHIVE_DIR"
    STAGING="$ROOT/.cleanup-staging-$TS"
    mkdir -p "$STAGING"
    MANIFEST="$STAGING/ARCHIVE_MANIFEST.txt"
    {
      echo "chump runtime archive"
      echo "created_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "host: $(hostname 2>/dev/null || echo unknown)"
      echo "repo: $ROOT"
      echo ""
    } >"$MANIFEST"

    for d in sessions logs; do
      if [[ -d "$ROOT/$d" ]]; then
        du -sh "$ROOT/$d" 2>/dev/null | sed "s|$ROOT/||" >>"$MANIFEST" || true
        cp -R "$ROOT/$d" "$STAGING/"
      else
        echo "(missing $d)" >>"$MANIFEST"
      fi
    done

    echo "== Archiving runtime data to $OUT =="
    tar -C "$STAGING" -czf "$OUT" .
    rm -rf "$STAGING"
    ls -lh "$OUT"

    if [[ "$PRUNE_AFTER" -eq 1 ]]; then
      echo "== Pruning sessions/* and logs/* (dirs kept) =="
      find "$ROOT/sessions" -mindepth 1 -delete 2>/dev/null || true
      find "$ROOT/logs" -mindepth 1 -delete 2>/dev/null || true
    fi
  fi
fi

echo "Done."
