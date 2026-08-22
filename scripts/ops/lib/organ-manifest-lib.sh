# scripts/ops/lib/organ-manifest-lib.sh — INFRA-3641
#
# Shared manifest-parser + requires= applicability-gate logic, extracted out
# of scripts/ops/organ-reconcile.sh so a SECOND consumer (chump-node-install.sh's
# host-agnostic ORGANS phase) can reuse the exact same grammar + gate instead of
# re-implementing it. Two callers, one implementation:
#   - scripts/ops/organ-reconcile.sh   — the systemd-only ATC roster on the
#     PRIMARY node (scripts/ops/organ-manifest.txt).
#   - scripts/setup/chump-node-install.sh — the host-agnostic (Termux/systemd/
#     macOS) brain+muscle organ roster (scripts/setup/node-organ-manifest.txt).
#
# Not meant to be executed directly — source it.

# organ_manifest_parse_tsv <manifest-file>
#   Emits one TSV line per non-blank, non-comment manifest line:
#     <state>\t<unit>\t<role>\t<requires>\t<extra>
#   role/requires are parsed from "role=..." / "requires=..." tokens after the
#   unit name; any other token (e.g. node-install's "exec=...") is preserved
#   verbatim, space-joined, in <extra> for the caller to interpret. role
#   defaults to "brain" when the line's state is "enabled" and no role= token
#   is present (matches organ-reconcile.sh's pre-existing default).
organ_manifest_parse_tsv() {
  local manifest="$1"
  if [[ ! -f "$manifest" ]]; then
    echo "ERROR: manifest not found: $manifest" >&2
    return 1
  fi
  local state unit rest
  while read -r state unit rest; do
    [[ -z "${state:-}" ]] && continue
    [[ "$state" == \#* ]] && continue
    local role="" requires="" extra="" tok
    for tok in $rest; do
      case "$tok" in
        role=*)     role="${tok#role=}" ;;
        requires=*) requires="${tok#requires=}" ;;
        *)          extra="${extra:+$extra }$tok" ;;
      esac
    done
    [[ "$state" == "enabled" ]] && role="${role:-brain}"
    printf '%s\t%s\t%s\t%s\t%s\n' "$state" "$unit" "$role" "$requires" "$extra"
  done < "$manifest"
}

# organ_manifest_default_dep_check <unit>
#   Fallback requires=dep:<unit> checker: is <unit> an active systemd unit?
#   Callers on a non-systemd host (Termux/nohup) must pass their own dep-check
#   function name as organ_is_applicable's 4th arg instead of relying on this.
organ_manifest_default_dep_check() {
  "${CHUMP_ORGAN_MANIFEST_SYSTEMCTL_BIN:-systemctl}" is-active --quiet "$1" 2>/dev/null
}

# organ_is_applicable <unit> <requires-csv> <reason-var> [dep-check-fn]
#   Is <unit> applicable to THIS host given its requires= spec (comma-separated
#   bin:/env:/dep: tokens)? Empty/absent requires means "always applicable"
#   (back-compat with manifest lines that omit requires=). On failure, writes
#   the first unmet reason into the variable named by reason-var (printf -v,
#   so the caller's own local `reason` var is set — see call sites).
organ_is_applicable() {
  local unit="$1" requires="$2" reason_var="$3"
  local dep_check="${4:-organ_manifest_default_dep_check}"
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
        if ! "$dep_check" "$dep"; then
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
