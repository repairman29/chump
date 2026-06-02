#!/usr/bin/env bash
# scripts/ci/test-cross-pr-contract.sh — INFRA-2406
#
# CI gate: refuse merge when open PRs introduce cross-PR contract mismatches
# (writer keys vs reader keys on shared IPC surfaces).
#
# Background (INFRA-2404): PR #2943 (INFRA-2397) wrote JSON keys
# {state, updated_at, last_tick_id} while PR #2944 (INFRA-2398) read keys
# {last_status, last_tick_at, failing_gates}. Keys never matched; the procedure
# layer shipped silently inert. chump contract-scan --in-flight (INFRA-2405)
# is the gate that would have caught this BEFORE EITHER MERGED.
#
# WHAT THIS DOES:
#   1. Runs `chump contract-scan --in-flight` against all open PRs.
#   2. On detected mismatch: emits kind=cross_pr_contract_mismatch to
#      .chump-locks/ambient.jsonl, exits 1 with actionable remediation.
#   3. On clean: exits 0.
#   4. Checks cross-pr-allowlist.txt for pre-approved conflicts before failing.
#
# OPERATOR ZERO-BYPASS THESIS (INFRA-2406):
#   There is NO CHUMP_CROSS_PR_CONTRACT_BYPASS env var.
#   Legitimate conflicts must be resolved by:
#     (a) Fixing one of the two PRs to align keys, OR
#     (b) Adding an entry to scripts/ci/cross-pr-allowlist.txt (source-controlled,
#         requires git change → PR review).
#
# TIER-D (Tier-D — cannot mirror in chump preflight):
#   This gate calls `gh pr list` to enumerate open PRs — requires GH_TOKEN context.
#   Added to scripts/ci/preflight-ci-parity-exceptions.txt (INFRA-2406).
#
# self-test mode: TEST_SELF_TEST=1 bash scripts/ci/test-cross-pr-contract.sh
#   Runs 3 synthetic cases (mismatch, aligned, single-PR) without real gh calls.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ALLOWLIST="$REPO_ROOT/scripts/ci/cross-pr-allowlist.txt"
AMBIENT_LOG="$REPO_ROOT/.chump-locks/ambient.jsonl"
SURFACES_MANIFEST="$REPO_ROOT/scripts/ci/contract-surfaces.txt"

# ── Self-test mode ──────────────────────────────────────────────────────────────
if [[ "${TEST_SELF_TEST:-0}" == "1" ]]; then
  bash "$0" --self-test
  exit $?
fi

if [[ "${1:-}" == "--self-test" ]]; then
  PASS=0
  FAIL=0

  run_case() {
    local label="$1"
    local mock_json="$2"
    local expect_exit="$3"
    local tmpdir
    tmpdir="$(mktemp -d)"

    # Build a mock chump binary that emits the provided JSON
    local mock_chump="$tmpdir/chump"
    local mock_ambient="$tmpdir/ambient.jsonl"
    local mock_allowlist="$tmpdir/cross-pr-allowlist.txt"
    printf '# empty allowlist\n' > "$mock_allowlist"

    # Create mock chump that outputs fixed contract-scan JSON
    cat > "$mock_chump" <<'MOCKEOF'
#!/usr/bin/env bash
# Mock chump contract-scan — emits the JSON passed via MOCK_CONTRACT_JSON env var
if [[ "${1:-}" == "contract-scan" ]]; then
  printf '%s\n' "${MOCK_CONTRACT_JSON}"
  # Exit based on whether mismatches array is non-empty
  if printf '%s\n' "${MOCK_CONTRACT_JSON}" | grep -q '"mismatches":\s*\[\s*{'; then
    exit 1
  fi
  exit 0
fi
exit 0
MOCKEOF
    chmod +x "$mock_chump"

    local out
    local actual_exit=0
    out=$(CHUMP_BIN_OVERRIDE="$mock_chump" \
          MOCK_CONTRACT_JSON="$mock_json" \
          AMBIENT_LOG_OVERRIDE="$mock_ambient" \
          ALLOWLIST_OVERRIDE="$mock_allowlist" \
          bash "$0" 2>&1) \
      || actual_exit=$?

    if [[ "$actual_exit" -eq "$expect_exit" ]]; then
      echo "  PASS: $label (exit=$actual_exit)"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: $label — expected exit $expect_exit, got $actual_exit"
      echo "        output: $out"
      FAIL=$((FAIL + 1))
    fi
    rm -rf "$tmpdir"
  }

  echo "[cross-pr-contract self-test] running 3 synthetic cases..."

  # Case 1: 2 PRs with mismatched contracts → exit 1, event emitted
  MISMATCH_JSON='{"writers":[{"path":"scripts/coord/main-preflight-watchdog.sh","kind":"json-file","keys":["state","updated_at","last_tick_id"]}],"readers":[{"path":"scripts/coord/chump-health-gate.sh","writer":"scripts/coord/main-preflight-watchdog.sh","expected_keys":["last_status","last_tick_at","failing_gates"],"missing_keys":["last_status","last_tick_at","failing_gates"],"extra_keys":["state","updated_at","last_tick_id"]}],"mismatches":[{"writer":"scripts/coord/main-preflight-watchdog.sh","reader":"scripts/coord/chump-health-gate.sh","missing_keys":["last_status","last_tick_at","failing_gates"],"extra_keys":["state","updated_at","last_tick_id"]}]}'
  run_case "2 PRs with mismatched contracts → exit 1" \
    "$MISMATCH_JSON" \
    1

  # Case 2: 2 PRs aligned (no mismatches) → exit 0
  ALIGNED_JSON='{"writers":[{"path":"scripts/coord/main-preflight-watchdog.sh","kind":"json-file","keys":["state","updated_at","last_tick_id"]}],"readers":[{"path":"scripts/coord/chump-health-gate.sh","writer":"scripts/coord/main-preflight-watchdog.sh","expected_keys":["state","updated_at","last_tick_id"],"missing_keys":[],"extra_keys":[]}],"mismatches":[]}'
  run_case "2 PRs aligned (no mismatches) → exit 0" \
    "$ALIGNED_JSON" \
    0

  # Case 3: 1 PR open (no cross-PR comparison possible) → exit 0
  SINGLE_PR_JSON='{"writers":[],"readers":[],"mismatches":[]}'
  run_case "1 PR open (no cross-PR comparison possible) → exit 0" \
    "$SINGLE_PR_JSON" \
    0

  echo ""
  if [[ $FAIL -gt 0 ]]; then
    echo "[cross-pr-contract self-test] FAIL: $FAIL/$((PASS+FAIL)) cases failed"
    exit 1
  else
    echo "[cross-pr-contract self-test] PASS: all $PASS cases passed"
    exit 0
  fi
fi

# ── Locate chump binary ─────────────────────────────────────────────────────────
# Support CHUMP_BIN_OVERRIDE for self-test injection.
CHUMP_BIN="${CHUMP_BIN_OVERRIDE:-}"
if [[ -z "$CHUMP_BIN" ]]; then
  if [[ -n "${CHUMP_BIN:-}" ]]; then
    : # already set by caller
  elif [[ -f "$REPO_ROOT/target/debug/chump" ]]; then
    CHUMP_BIN="$REPO_ROOT/target/debug/chump"
  elif command -v chump &>/dev/null; then
    CHUMP_BIN="chump"
  elif [[ -n "${CARGO_TARGET_DIR:-}" ]] && [[ -f "$CARGO_TARGET_DIR/debug/chump" ]]; then
    CHUMP_BIN="$CARGO_TARGET_DIR/debug/chump"
  else
    echo "[cross-pr-contract] ERROR: chump binary not found." >&2
    echo "  Build it with: cargo build --bin chump" >&2
    exit 2
  fi
fi

# ── Override paths for self-test injection ──────────────────────────────────────
AMBIENT_LOG="${AMBIENT_LOG_OVERRIDE:-$AMBIENT_LOG}"
ALLOWLIST="${ALLOWLIST_OVERRIDE:-$ALLOWLIST}"

# ── Check mock contract-scan mode ───────────────────────────────────────────────
# When CHUMP_BIN_OVERRIDE is set (self-test), use the mock directly.
if [[ -n "${CHUMP_BIN_OVERRIDE:-}" ]]; then
  SCAN_OUTPUT=""
  SCAN_EXIT=0
  SCAN_OUTPUT="$(MOCK_CONTRACT_JSON="${MOCK_CONTRACT_JSON:-}" \
    "$CHUMP_BIN" contract-scan --in-flight 2>/dev/null)" \
    || SCAN_EXIT=$?
else
  # ── Run chump contract-scan --in-flight ─────────────────────────────────────
  echo "[cross-pr-contract] running: chump contract-scan --in-flight"
  SCAN_OUTPUT=""
  SCAN_EXIT=0
  SCAN_OUTPUT="$("$CHUMP_BIN" contract-scan --in-flight 2>&1 >/dev/null; \
                 "$CHUMP_BIN" contract-scan --in-flight 2>/dev/null)" \
    || true

  # Re-run capturing stdout cleanly (stderr went to terminal above for progress)
  SCAN_EXIT=0
  SCAN_OUTPUT="$("$CHUMP_BIN" contract-scan --in-flight 2>/dev/null)" \
    || SCAN_EXIT=$?
fi

if [[ $SCAN_EXIT -eq 2 ]]; then
  echo "[cross-pr-contract] ERROR: contract-scan returned exit 2 (scan failure)" >&2
  echo "  Check that GH_TOKEN is set and gh CLI is available." >&2
  exit 2
fi

# ── Extract mismatches from JSON output ─────────────────────────────────────────
# contract-scan emits JSON with {writers, readers, mismatches} structure.
# Parse mismatch entries using simple grep+sed (no jq dependency).
extract_mismatches() {
  local json="$1"
  # Check if mismatches array has any entries
  if printf '%s\n' "$json" | grep -qE '"mismatches"\s*:\s*\[\s*\{'; then
    return 0  # has mismatches
  fi
  return 1  # no mismatches
}

extract_field() {
  local json="$1"
  local field="$2"
  # Extract "field":"value" from JSON (simple single-line extraction)
  printf '%s\n' "$json" | grep -oE "\"${field}\":\"[^\"]*\"" | head -1 | sed 's/.*":\"//' | sed 's/"//'
}

extract_array_field() {
  local json="$1"
  local field="$2"
  # Extract "field":["val1","val2",...] — returns comma-separated values
  printf '%s\n' "$json" | grep -oE "\"${field}\":\[[^\]]*\]" | head -1 \
    | sed 's/.*:\[//' | sed 's/\]//' | tr -d '"' | tr ',' ' '
}

# ── Load allowlist ──────────────────────────────────────────────────────────────
load_allowlist() {
  if [[ ! -f "$ALLOWLIST" ]]; then
    return  # no allowlist = no pre-approved exceptions
  fi
  grep -v '^\s*#' "$ALLOWLIST" | grep -v '^\s*$'
}

ALLOWLIST_ENTRIES=()
while IFS= read -r line; do
  [[ -n "$line" ]] && ALLOWLIST_ENTRIES+=("$line")
done < <(load_allowlist)

is_allowlisted() {
  local writer="$1"
  local reader="$2"
  local entry
  for entry in "${ALLOWLIST_ENTRIES[@]:-}"; do
    # Format: "writer_path reader_path"
    local w r
    w="$(printf '%s\n' "$entry" | awk '{print $1}')"
    r="$(printf '%s\n' "$entry" | awk '{print $2}')"
    if [[ "$w" == "$writer" ]] && [[ "$r" == "$reader" ]]; then
      return 0
    fi
  done
  return 1
}

# ── Parse mismatch array from contract-scan JSON ────────────────────────────────
# We need to extract individual mismatch objects from the array.
# The JSON looks like: {"mismatches":[{"writer":"...","reader":"...","missing_keys":[...],...},...]}
# Strategy: split on },{ boundaries within the mismatches array.

MISMATCHES_RAW=""
if printf '%s\n' "$SCAN_OUTPUT" | grep -qE '"mismatches"\s*:\s*\['; then
  # Extract the mismatches array content
  MISMATCHES_RAW="$(printf '%s\n' "$SCAN_OUTPUT" \
    | grep -oE '"mismatches":\[[^]]*(\[[^]]*\])*[^]]*\]' \
    | sed 's/^"mismatches":\[//' \
    | sed 's/\]$//')"
fi

MISMATCH_COUNT=0
VIOLATION_PAIRS=()

if [[ -n "$MISMATCHES_RAW" ]] && printf '%s\n' "$MISMATCHES_RAW" | grep -q '"writer"'; then
  # Count mismatch objects by counting "writer": occurrences
  MISMATCH_COUNT="$(printf '%s\n' "$MISMATCHES_RAW" | grep -c '"writer"' || true)"

  # Extract individual mismatch pairs (writer + reader) for allowlist check
  # Simple approach: extract all writer/reader pairs sequentially
  WRITERS_LIST=()
  READERS_LIST=()
  MISSING_LIST=()

  while IFS= read -r w; do
    [[ -n "$w" ]] && WRITERS_LIST+=("$w")
  done < <(printf '%s\n' "$SCAN_OUTPUT" \
    | grep -oE '"writer":"[^"]*"' | sed 's/"writer":"//;s/"$//')

  while IFS= read -r r; do
    [[ -n "$r" ]] && READERS_LIST+=("$r")
  done < <(printf '%s\n' "$SCAN_OUTPUT" \
    | grep -oE '"reader":"[^"]*"' | sed 's/"reader":"//;s/"$//')

  while IFS= read -r m; do
    [[ -n "$m" ]] && MISSING_LIST+=("$m")
  done < <(printf '%s\n' "$SCAN_OUTPUT" \
    | grep -oE '"missing_keys":\[[^]]*\]' | sed 's/"missing_keys":\[//;s/\]$//' | tr -d '"')
fi

# ── Check allowlist and collect violations ──────────────────────────────────────
VIOLATIONS=()
ALLOWLISTED_COUNT=0

for i in "${!WRITERS_LIST[@]}"; do
  local_writer="${WRITERS_LIST[$i]:-}"
  local_reader="${READERS_LIST[$i]:-}"
  [[ -z "$local_writer" ]] && continue

  if is_allowlisted "$local_writer" "$local_reader"; then
    ALLOWLISTED_COUNT=$((ALLOWLISTED_COUNT + 1))
    echo "[cross-pr-contract] INFO: mismatch pre-approved in cross-pr-allowlist.txt: $local_writer → $local_reader"
  else
    VIOLATIONS+=("$local_writer|$local_reader|${MISSING_LIST[$i]:-}")
  fi
done

# ── Emit ambient event on violation ────────────────────────────────────────────
emit_mismatch_event() {
  local writer="$1"
  local reader="$2"
  local missing_keys="$3"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"

  mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true

  # Emit kind=cross_pr_contract_mismatch (INFRA-2406)
  # Fields match EVENT_REGISTRY.yaml fields_required
  printf '{"ts":"%s","kind":"cross_pr_contract_mismatch","writer_pr":"%s","reader_pr":"%s","missing_keys":"%s","gap":"INFRA-2406"}\n' \
    "$ts" \
    "$writer" \
    "$reader" \
    "$missing_keys" \
    >> "$AMBIENT_LOG" 2>/dev/null || true
}

# ── Report ──────────────────────────────────────────────────────────────────────
if [[ ${#VIOLATIONS[@]} -eq 0 ]]; then
  if [[ $MISMATCH_COUNT -eq 0 ]]; then
    echo "[cross-pr-contract] PASS: no cross-PR contract mismatches detected"
  else
    echo "[cross-pr-contract] PASS: $MISMATCH_COUNT mismatch(es) detected but all pre-approved in cross-pr-allowlist.txt"
  fi
  exit 0
fi

# Violations found — emit events and print remediation
{
  echo ""
  echo "[cross-pr-contract] FAIL: ${#VIOLATIONS[@]} cross-PR contract mismatch(es) detected"
  echo ""
  echo "  Root cause: INFRA-2404 — watchdog wrote {state,updated_at,last_tick_id},"
  echo "  claim-gate read {last_status,last_tick_at,failing_gates}. This gate"
  echo "  catches exactly that class of cross-PR schema drift BEFORE merge."
  echo ""
  echo "  Mismatched pairs:"
} >&2

for violation in "${VIOLATIONS[@]}"; do
  IFS='|' read -r vwriter vreader vmissing <<< "$violation"
  {
    echo "    writer: $vwriter"
    echo "    reader: $vreader"
    echo "    missing keys (reader expects, writer never wrote): $vmissing"
    echo ""
  } >&2

  emit_mismatch_event "$vwriter" "$vreader" "$vmissing"
done

{
  echo "  Remediation:"
  echo "    1. PREFERRED: Fix one of the two PRs so the writer and reader agree on"
  echo "       key names. This is the only path that actually fixes the contract."
  echo ""
  echo "    2. PRE-APPROVE (use sparingly): Add an entry to"
  echo "       scripts/ci/cross-pr-allowlist.txt in the format:"
  echo "         writer_path  reader_path  # reason: <why this is safe>"
  echo "       This requires a git change and PR review — there is NO env-var bypass."
  echo ""
  echo "    3. Contact the other PR's author and coordinate key alignment."
  echo ""
  echo "  See: INFRA-2406 — pre-merge cross-PR contract gate"
  echo "       INFRA-2405 — chump contract-scan subcommand"
  echo "       INFRA-2404 — root cause (watchdog/claim-gate key mismatch)"
} >&2

exit 1
