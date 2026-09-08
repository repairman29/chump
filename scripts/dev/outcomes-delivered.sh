#!/usr/bin/env bash
# CREDIBLE-297: report landed outcomes from a JSON-lines ambient log/fixture.
#
# The inline bot-merge step in trek/swe runs a full local `cargo clippy` over
# the whole workspace and can exit 13 (clippy-fail) on pre-existing lint noise
# unrelated to the change being shipped, while the PR's own scoped CI clippy
# passes and GitHub auto-merge lands it anyway. Treat a `bot-merge` event with
# exit_code 13 as a landed outcome (not a failure), and ignore any
# `wait_expiry` field — it does not change whether the PR actually merged.
set -euo pipefail

# Reads a JSON-lines file and prints the count of events that represent a
# landed (successful) bot-merge outcome.
count_json_events() {
    local file="$1"
    local success=0
    local line type exit_code

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        type="$(jq -r '.type // empty' <<<"$line" 2>/dev/null || true)"
        exit_code="$(jq -r '.exit_code // empty' <<<"$line" 2>/dev/null || true)"
        if [[ "$type" == "bot-merge" ]] && { [[ "$exit_code" == "0" ]] || [[ "$exit_code" == "13" ]]; }; then
            success=$((success + 1))
        fi
    done < "$file"

    echo "$success"
}

main() {
    local file="${1:-}"
    if [[ -z "$file" || ! -f "$file" ]]; then
        echo "usage: $0 <json-lines-file>" >&2
        exit 1
    fi

    local success
    success="$(count_json_events "$file")"

    if [[ "$success" -ge 1 ]]; then
        echo "SUCCESS: $success landed outcome(s)"
        exit 0
    fi

    echo "FAILED: 0 landed outcomes"
    exit 1
}

# Allow sourcing for unit tests without running main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
