#!/usr/bin/env bash
# check-orphan-rust-modules.sh — find .rs files under src/ that are not referenced
# by any `mod` or `pub mod` declaration. These are dead modules — either delete or
# wire up.
#
# Excluded: main.rs, lib.rs, mod.rs (these are entry points), build.rs (build
# script), and integration tests under src/tests/ (cargo treats them specially).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

cd "$REPO_ROOT"
log "scanning for orphan rust modules..."

while IFS= read -r rs_file; do
    base="$(basename "$rs_file" .rs)"
    case "$base" in
        main|lib|mod|build) continue ;;
    esac
    # Skip integration tests (cargo discovers these via src/tests/ or tests/)
    case "$rs_file" in
        ./tests/*|*/tests/*) continue ;;
    esac
    # Search for `mod <base>` or `pub mod <base>` anywhere in src/, excluding self.
    if ! grep -REn --include='*.rs' --exclude-dir=target \
        "^[[:space:]]*(pub[[:space:]]+)?mod[[:space:]]+${base}([[:space:]]*[;{]|$)" src/ 2>/dev/null \
        | grep -v "^${rs_file}:" >/dev/null; then
        key="ORPHAN_RUST_MOD::${rs_file}"
        title="Orphan Rust module: $rs_file"
        desc="The Rust source file \`$rs_file\` is not referenced by any \`mod $base\` or \`pub mod $base\` declaration in \`src/\`. The compiler does not build it; it is dead weight or a forgotten wire-up. Acceptance criteria: either delete \`$rs_file\` or add the missing \`mod\` declaration to its parent."
        emit_finding "orphan-rust-modules" "$key" "$title" "$desc" "INFRA" "P2" "xs" "[\"$rs_file\"]"
    fi
done < <(find src -name '*.rs' -type f 2>/dev/null | sed 's|^|./|')

log "orphan-rust-modules done."
