#!/usr/bin/env bash
# scripts/ops/lib/organ-manifest-lib.sh — TREK-18 (INFRA-3644)
#
# The ONE parser for scripts/ops/organ-manifest.txt, shared by
# organ-reconcile.sh (which converges live systemd state to the manifest)
# and install-fleet-node.sh (which now derives its installed roster FROM
# the manifest instead of a second, hand-maintained array). Before this gap,
# the installer's SYSTEM_TIMERS array and the manifest were two independent
# sources of truth — adding an organ to the manifest was NOT sufficient to
# get it installed (chump-conflict-resolution-consumer.timer and
# chump-gap-closure-reconcile.timer were both `enabled` in the manifest but
# absent from the installer's roster until this fix), and RESILIENT-366 had
# to add a standalone CI test just to catch the inverse drift. One parser
# feeding both call sites makes that whole drift class structurally
# impossible instead of separately detected.
#
# Format is documented in scripts/ops/organ-manifest.txt's header comment.

# organ_manifest_parse <manifest-file> <paging_off-array-name> <enabled-array-name> <role-assoc-array-name> <requires-assoc-array-name>
#
# Populates the four caller-provided array names (via nameref) from the
# manifest file. Caller must declare them first (any prior contents are
# cleared). Returns 1 (and prints an error) if the manifest file is missing.
organ_manifest_parse() {
  local manifest="$1"
  local -n _omp_paging_off="$2"
  local -n _omp_enabled="$3"
  local -n _omp_role="$4"
  local -n _omp_requires="$5"

  _omp_paging_off=()
  _omp_enabled=()
  _omp_role=()
  _omp_requires=()

  if [[ ! -f "$manifest" ]]; then
    echo "ERROR: manifest not found: $manifest" >&2
    return 1
  fi

  local state unit rest role requires tok
  while read -r state unit rest; do
    [[ -z "${state:-}" ]] && continue
    [[ "$state" == \#* ]] && continue
    role="" requires=""
    for tok in $rest; do
      case "$tok" in
        role=*)     role="${tok#role=}" ;;
        requires=*) requires="${tok#requires=}" ;;
      esac
    done
    case "$state" in
      paging_off) _omp_paging_off+=("$unit") ;;
      enabled)
        _omp_enabled+=("$unit")
        _omp_role["$unit"]="${role:-brain}"
        _omp_requires["$unit"]="$requires"
        ;;
      *) echo "WARN: unknown state '$state' for '$unit' in manifest; ignoring" >&2 ;;
    esac
  done < "$manifest"
  return 0
}
