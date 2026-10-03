#!/usr/bin/env bash
# scripts/ci/test-sccache-codegen-gating.sh — INFRA-3764 (INFRA-3660 slice)
#
# Regression coverage for the cranelift/mold availability-gating in
# scripts/setup/install-sccache.sh:
#
#   AC1 — no repo-tracked .cargo/config.toml carries cranelift/mold settings
#         that would affect CI (the file is per-machine and .gitignore'd;
#         it must never be committed).
#   AC2/AC3 — build_mold_block() / build_cranelift_block() only emit their
#         `[target.*]` / `[profile.dev]` sections when the corresponding
#         binary/component is actually present, so a host missing either
#         can't get a broken build.
#
# Sources the install script for its function defs only (the BASH_SOURCE
# guard inside it skips the install/write/verify side effects), then drives
# build_mold_block()/build_cranelift_block() against a faked PATH/rustup —
# same pattern as scripts/ci/test-sccache-dir-selection.sh (INFRA-7113).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL_SCRIPT="$REPO_ROOT/scripts/setup/install-sccache.sh"

pass() { printf '\033[0;32mPASS\033[0m  %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m  %s\n' "$*"; exit 1; }
info() { printf '\033[0;36m→\033[0m    %s\n' "$*"; }

[[ -f "$INSTALL_SCRIPT" ]] || fail "install script not found: $INSTALL_SCRIPT"

# ── AC1: no tracked .cargo/config.toml with cranelift/mold settings ───────
TRACKED_CARGO_CONFIG="$(cd "$REPO_ROOT" && git ls-files '.cargo/config.toml' '.cargo/config')"
if [[ -n "$TRACKED_CARGO_CONFIG" ]]; then
    if (cd "$REPO_ROOT" && git show "HEAD:.cargo/config.toml" 2>/dev/null | grep -qiE 'cranelift|fuse-ld=mold'); then
        fail "AC1: repo-tracked .cargo/config.toml contains cranelift/mold settings — these must stay per-machine"
    fi
fi
pass "AC1: no repo-tracked .cargo/config.toml carries cranelift/mold settings"

TMPDIR_BASE=$(mktemp -d /tmp/test-sccache-codegen-XXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT
FAKE_BIN_DIR="$TMPDIR_BASE/bin"
mkdir -p "$FAKE_BIN_DIR"

# shellcheck source=/dev/null
source "$INSTALL_SCRIPT"

# ── AC2/AC3: mold block only when `mold` is on PATH ────────────────────────
# Put the fake bin dir first on PATH so a fake `mold`/`rustup` wins over any
# real one on the test-runner's machine, while coreutils (cat, grep, …)
# used inside build_mold_block/build_cranelift_block stay resolvable.
ISOLATED_PATH="$FAKE_BIN_DIR:$PATH"

result="$(PATH="$ISOLATED_PATH" build_mold_block)"
[[ -z "$result" ]] || fail "AC2: build_mold_block emitted a section with mold absent from PATH"
pass "AC2: build_mold_block omits the [target.*] section when mold is not on PATH"

cat > "$FAKE_BIN_DIR/mold" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/mold"
result="$(PATH="$ISOLATED_PATH" build_mold_block)"
[[ "$result" == *"[target.x86_64-unknown-linux-gnu]"* ]] || fail "AC2: build_mold_block did not emit the linux-target section with mold present"
[[ "$result" == *"fuse-ld=mold"* ]] || fail "AC2: build_mold_block section missing the mold rustflag"
pass "AC2: build_mold_block emits the [target.*] mold section when mold is on PATH"

# ── AC2/AC3: cranelift block only when the rustup component is installed ──
cat > "$FAKE_BIN_DIR/rustup" <<'EOF'
#!/usr/bin/env bash
# No components installed.
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/rustup"
result="$(PATH="$ISOLATED_PATH" build_cranelift_block)"
[[ -z "$result" ]] || fail "AC3: build_cranelift_block emitted a section with the component not installed"
pass "AC3: build_cranelift_block omits the [profile.dev] section when rustc-codegen-cranelift is not installed"

cat > "$FAKE_BIN_DIR/rustup" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "component" && "$2" == "list" ]]; then
    echo "rustc-codegen-cranelift-preview (installed)"
    exit 0
fi
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/rustup"
result="$(PATH="$ISOLATED_PATH" build_cranelift_block)"
[[ "$result" == *'codegen-backend = "cranelift"'* ]] || fail "AC3: build_cranelift_block did not emit the codegen-backend section with the component present"
pass "AC3: build_cranelift_block emits the [profile.dev] cranelift section when the component is installed"

info "all sccache codegen-gating tests passed"
