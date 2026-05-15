#!/usr/bin/env bash
set -eu

# EVAL-103: Preregistration enforcement gates
# Given a preregistration MD path, parses the §12 locked-fields YAML manifest
# and asserts every env var and CLI flag matches.
#
# Usage:
#   source scripts/eval/lib/prereg-enforce.sh
#   enforce_prereg_manifest <path-to-prereg.md> [--model MODEL] [--n-per-cell N] [--fixture FIXTURE] [--judges JUDGE1,JUDGE2,...]

PREREG_ENFORCE_ERRORS=0
MISMATCHED_FIELDS=()
manifest_judge_models=()

# Parse YAML manifest from preregistration markdown
# Expects manifest to be in a code block starting with "```yaml" after "## 12. Locked-fields"
parse_locked_fields_manifest() {
    local prereg_path="$1"
    if [[ ! -f "$prereg_path" ]]; then
        echo "ERROR: preregistration file not found: $prereg_path" >&2
        return 1
    fi

    # Extract the yaml block from section 12
    # Look for the pattern: ## 12. ... followed by ```yaml ... ```
    awk '/## 12\. Locked-fields/,/^```$/ {
        if (/^```yaml$/) { in_yaml=1; next }
        if (in_yaml && /^```$/) { in_yaml=0; next }
        if (in_yaml) { print }
    }' "$prereg_path"
}

# Extract a single field from YAML (simple parser for our specific format)
# Usage: extract_yaml_field <yaml_string> <field_path>
# Examples: extract_yaml_field "$yaml" "gap_id"
#           extract_yaml_field "$yaml" "primary_agent"
extract_yaml_field() {
    local yaml="$1"
    local field="$2"

    # Simple extraction for top-level fields (no nesting)
    echo "$yaml" | grep "^  $field:" | sed "s/^  $field: //" | tr -d "'" | tr -d '"'
}

# Extract judge models list (special handling for arrays)
extract_judge_models() {
    local yaml="$1"

    # Extract the judge_models array (array items start with "- ")
    echo "$yaml" | awk '/judge_models:/,/^[^ ]/ {
        if (/^ *- /) {
            gsub(/^ *- /, "");
            gsub(/['"'"'"]/, "");
            if (NF > 0) print
        }
    }'
}

# Emit ambient event for prereg check
emit_prereg_check_event() {
    local prereg_id="$1"
    local result="$2"  # pass|fail|deviation
    local mismatched_fields="$3"  # JSON array or empty

    local event="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"kind\":\"eval_prereg_check\",\"prereg_id\":\"$prereg_id\",\"result\":\"$result\""
    if [[ -n "$mismatched_fields" ]]; then
        event="$event,\"mismatched_fields\":$mismatched_fields"
    fi
    event="$event}"

    # Append to ambient.jsonl if it exists
    if [[ -f ".chump-locks/ambient.jsonl" ]]; then
        echo "$event" >> ".chump-locks/ambient.jsonl"
    fi
}

# Main enforcement function
enforce_prereg_manifest() {
    local prereg_path="$1"
    shift || true

    # Parse arguments (support both --flag value and --flag=value)
    local provided_model=""
    local provided_n_per_cell=""
    local provided_fixture=""
    provided_judges=()
    manifest_judge_models=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --model)
                provided_model="$2"
                shift 2
                ;;
            --model=*)
                provided_model="${1#--model=}"
                shift
                ;;
            --n-per-cell)
                provided_n_per_cell="$2"
                shift 2
                ;;
            --n-per-cell=*)
                provided_n_per_cell="${1#--n-per-cell=}"
                shift
                ;;
            --fixture)
                provided_fixture="$2"
                shift 2
                ;;
            --fixture=*)
                provided_fixture="${1#--fixture=}"
                shift
                ;;
            --judges)
                IFS=',' read -ra provided_judges <<<"$2"
                shift 2
                ;;
            --judges=*)
                IFS=',' read -ra provided_judges <<<"${1#--judges=}"
                shift
                ;;
            *)
                echo "ERROR: unknown argument: $1" >&2
                return 1
                ;;
        esac
    done

    # Parse the manifest
    local yaml_manifest
    yaml_manifest=$(parse_locked_fields_manifest "$prereg_path")
    if [[ -z "$yaml_manifest" ]]; then
        echo "ERROR: could not parse locked-fields manifest from $prereg_path" >&2
        emit_prereg_check_event "" "fail" "[\"parse_error\"]"
        return 1
    fi

    # Extract locked fields from manifest
    local manifest_gap_id
    local manifest_primary_agent
    local manifest_n_per_cell
    local manifest_fixture

    manifest_gap_id=$(extract_yaml_field "$yaml_manifest" "gap_id")
    manifest_primary_agent=$(extract_yaml_field "$yaml_manifest" "primary_agent")
    manifest_n_per_cell=$(extract_yaml_field "$yaml_manifest" "n_per_cell")
    manifest_fixture=$(extract_yaml_field "$yaml_manifest" "fixture")

    # Extract judge models
    while IFS= read -r judge; do
        [[ -n "$judge" ]] && manifest_judge_models+=("$judge")
    done < <(extract_judge_models "$yaml_manifest")

    # Reset error tracking
    PREREG_ENFORCE_ERRORS=0
    MISMATCHED_FIELDS=()

    # Check model field
    if [[ -n "$provided_model" && "$provided_model" != "$manifest_primary_agent" ]]; then
        echo "ERROR: primary_agent mismatch: provided=$provided_model, manifest=$manifest_primary_agent" >&2
        MISMATCHED_FIELDS+=("primary_agent")
        ((PREREG_ENFORCE_ERRORS++))
    elif [[ -z "$provided_model" && -n "$CHUMP_AGENT_MODEL" && "$CHUMP_AGENT_MODEL" != "$manifest_primary_agent" ]]; then
        echo "ERROR: CHUMP_AGENT_MODEL mismatch: env=$CHUMP_AGENT_MODEL, manifest=$manifest_primary_agent" >&2
        MISMATCHED_FIELDS+=("primary_agent")
        ((PREREG_ENFORCE_ERRORS++))
    fi

    # Check n_per_cell (provided n must be >= manifest n)
    if [[ -n "$provided_n_per_cell" ]]; then
        if (( provided_n_per_cell < manifest_n_per_cell )); then
            echo "ERROR: n_per_cell too small: provided=$provided_n_per_cell, manifest minimum=$manifest_n_per_cell" >&2
            MISMATCHED_FIELDS+=("n_per_cell")
            ((PREREG_ENFORCE_ERRORS++))
        fi
    fi

    # Check fixture path
    if [[ -n "$provided_fixture" && "$provided_fixture" != "$manifest_fixture" ]]; then
        echo "ERROR: fixture mismatch: provided=$provided_fixture, manifest=$manifest_fixture" >&2
        MISMATCHED_FIELDS+=("fixture")
        ((PREREG_ENFORCE_ERRORS++))
    fi

    # Check judge models (set equality)
    if [[ ${#provided_judges[@]:-0} -gt 0 ]]; then
        # Convert both to sorted arrays for comparison
        local manifest_judges_sorted
        manifest_judges_sorted=$(printf '%s\n' "${manifest_judge_models[@]:-}" | grep -v '^$' | sort)
        local provided_judges_sorted
        provided_judges_sorted=$(printf '%s\n' "${provided_judges[@]}" | sort)

        if [[ "$manifest_judges_sorted" != "$provided_judges_sorted" ]]; then
            local provided_str
            provided_str=$(printf '%s,' "${provided_judges[@]}")
            local manifest_str
            manifest_str=$(printf '%s,' "${manifest_judge_models[@]:-}")
            echo "ERROR: judge_models mismatch: provided=($provided_str), manifest=($manifest_str)" >&2
            MISMATCHED_FIELDS+=("judge_models")
            ((PREREG_ENFORCE_ERRORS++))
        fi
    fi

    # Check CHUMP_AB_SCORER (must not be 'exit-code')
    if [[ "${CHUMP_AB_SCORER:-}" == "exit-code" ]]; then
        echo "ERROR: CHUMP_AB_SCORER must not be 'exit-code' (per RESEARCH_INTEGRITY §6)" >&2
        MISMATCHED_FIELDS+=("scorer_prohibition")
        ((PREREG_ENFORCE_ERRORS++))
    fi

    # Generate mismatched_fields JSON for ambient event
    local mismatched_json=""
    if [[ ${#MISMATCHED_FIELDS[@]} -gt 0 ]]; then
        mismatched_json='['
        for field in "${MISMATCHED_FIELDS[@]}"; do
            [[ -n "$mismatched_json" && "$mismatched_json" != '[' ]] && mismatched_json="$mismatched_json,"
            mismatched_json="$mismatched_json\"$field\""
        done
        mismatched_json="$mismatched_json]"
    fi

    # Emit event and return
    if [[ $PREREG_ENFORCE_ERRORS -eq 0 ]]; then
        emit_prereg_check_event "$manifest_gap_id" "pass" ""
        return 0
    else
        emit_prereg_check_event "$manifest_gap_id" "fail" "$mismatched_json"
        return 1
    fi
}

# Record a mid-run deviation to the preregistration doc
record_prereg_deviation() {
    local prereg_path="$1"
    local deviation_reason="$2"

    if [[ ! -f "$prereg_path" ]]; then
        echo "ERROR: preregistration file not found: $prereg_path" >&2
        return 1
    fi

    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local runner_sha
    if command -v git &>/dev/null && [[ -d ".git" ]]; then
        runner_sha=$(git rev-parse HEAD)
    else
        runner_sha="unknown"
    fi

    # Find the "## 13. Deviations" section and append the entry
    # This is a simple implementation that appends before the EOF
    local temp_file
    temp_file=$(mktemp)

    # Copy everything up to but not including the final line (assuming doc ends with newline or content)
    head -n -1 "$prereg_path" > "$temp_file"

    # Append the deviation entry
    echo "" >> "$temp_file"
    echo "**$timestamp** (runner SHA: \`${runner_sha:0:8}\`)" >> "$temp_file"
    echo ": $deviation_reason" >> "$temp_file"

    # Restore final newline if original had one
    if [[ $(tail -c 1 "$prereg_path" | wc -l) -eq 1 ]]; then
        echo "" >> "$temp_file"
    fi

    mv "$temp_file" "$prereg_path"
}

# Export functions for use in scripts that source this library
export -f enforce_prereg_manifest
export -f record_prereg_deviation
export -f parse_locked_fields_manifest
export -f extract_yaml_field
export -f extract_judge_models
export -f emit_prereg_check_event
