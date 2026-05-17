#!/usr/bin/env bash
# test-workflow-linux-guard.sh — INFRA-1539 (RESILIENT)
#
# Proactive guard sweep: every workflow step that runs `sudo`, `apt-get`, or
# `pip install` (without bundled fallback) MUST be wrapped in
# `if: runner.os == 'Linux'`. This protects against the cascade that hit on
# 2026-05-16 where migrating a job to self-hosted macOS without the guard
# tripped 8+ unguarded apt-get steps and required emergency PRs.
#
# Exception: steps inside a job that declares `container:` are exempt
# (the container guarantees Linux).
#
# Wired into the `pr-hygiene` job in .github/workflows/ci.yml so any new
# unguarded step is caught at PR time, not at "first self-hosted run".
#
# Exit codes:
#   0  all matching steps are guarded
#   1  one or more unguarded steps found (list printed to stderr)
#   2  scanning error (file unreadable, etc.)
#
# Implementation notes:
#   - Pure POSIX-ish awk; no yq, no PyYAML dependency.
#   - Tracks step boundaries by indent: a step starts at the FIRST `- name:`
#     after a `steps:` line and ends at the next `- ` at the same indent OR
#     the next `jobs:`/job-header-level token.
#   - A step is "guarded" when it has `if: runner.os == 'Linux'` (or a
#     compound matrix.os/runner.os expression containing that substring) on
#     one of its own attribute lines (NOT inherited from another step).
#   - A step is "exempt" when its enclosing job has a `container:` key.
#
# Cross-platform: tested on macOS BSD awk and GNU awk.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

WORKFLOWS_DIR=".github/workflows"
if [[ ! -d "$WORKFLOWS_DIR" ]]; then
  echo "FAIL: $WORKFLOWS_DIR not found" >&2
  exit 2
fi

# Single awk script does all the work, prints `OFFENDER\t<file>:<line>\t<rule>\t<step_name>`
# lines for every unguarded match. We then count and report.
OFFENDERS_FILE="$(mktemp)"
trap 'rm -f "$OFFENDERS_FILE"' EXIT

shopt -s nullglob
for wf in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml; do
  awk -v WF="$wf" '
    function reset_step() {
      step_name = ""
      step_line = 0
      step_if = ""
      step_run = ""
      step_indent = -1
    }
    function check_and_emit() {
      if (step_indent < 0) return
      # match sudo / apt-get / pip install in the run block
      hits = ""
      if (match(step_run, /(^|[^A-Za-z0-9_])sudo[ \t]/))   hits = hits "sudo "
      if (match(step_run, /apt-get/))                       hits = hits "apt-get "
      if (match(step_run, /pip[ \t]+install/))              hits = hits "pip-install "
      if (hits == "") { reset_step(); return }

      # exempt if job has container:
      if (job_has_container) { reset_step(); return }

      # guard check on the steps own if:
      if (step_if ~ /runner\.os[ \t]*==[ \t]*[\x27"]Linux[\x27"]/) {
        reset_step(); return
      }

      sub(/[ \t]+$/, "", hits)
      printf("OFFENDER\t%s:%d\t%s\t%s\n", WF, step_line, hits, step_name) > "/dev/stderr"
      offender_count++
      reset_step()
    }

    BEGIN {
      in_jobs = 0
      job_indent = -1
      job_has_container = 0
      in_steps = 0
      steps_indent = -1
      reset_step()
      in_run_block = 0
      run_block_indent = -1
      offender_count = 0
    }

    {
      # Compute indent (leading spaces)
      line = $0
      raw = line
      # strip trailing CR if any
      sub(/\r$/, "", line)
      # trim trailing whitespace for parsing
      stripped = line
      sub(/[ \t]+$/, "", stripped)
      # strip leading whitespace to give a normalized "stripped" view
      sub(/^[ \t]+/, "", stripped)

      if (stripped ~ /^#/ || stripped == "") {
        # comment or blank — if were inside a run block, preserve it
        if (in_run_block) {
          step_run = step_run "\n" stripped
        }
        next
      }

      # indent
      n = match(line, /[^ ]/)
      indent = (n > 0) ? n - 1 : 0

      # Detect top-level `jobs:`
      if (indent == 0 && stripped ~ /^jobs:[ \t]*$/) {
        check_and_emit()
        in_jobs = 1
        job_indent = -1
        job_has_container = 0
        in_steps = 0
        in_run_block = 0
        next
      }

      if (!in_jobs) next

      # End of run-block detection: if we were in a run block, end it once
      # the indent drops to <= step_indent (i.e. were back at step-attr level
      # or higher).
      if (in_run_block && indent <= step_indent) {
        in_run_block = 0
      }

      # Job header: indent == 2 (jobs are 2-space indented under jobs:),
      # line ends with ":" and isnt a `- name:` step.
      # Be permissive: any key at indent 2 that ends with ":" starts a new job
      # context. (Common convention; matches all our workflows.)
      if (indent == 2 && stripped ~ /^[A-Za-z_][A-Za-z0-9_-]*:[ \t]*$/) {
        check_and_emit()
        job_indent = 2
        job_has_container = 0
        in_steps = 0
        steps_indent = -1
        in_run_block = 0
        reset_step()
        next
      }

      # job-level attributes (indent 4 typically). Track container:
      if (job_indent == 2 && indent == 4) {
        if (stripped ~ /^container:/) {
          # `container: null` or `container: ${{ ... && image || null }}` —
          # We treat ANY container: declaration that is not literally
          # `container: null` (no expression) as enabling exemption. To stay
          # conservative for expression-based containers (where the runtime
          # container may be null), require an unambiguous string value.
          # Anything other than `null` -> exempt.
          val = stripped
          sub(/^container:[ \t]*/, "", val)
          if (val == "" || val == "null" || val == "~") {
            job_has_container = 0
          } else {
            # Conservative: expressions can resolve to null. Only mark exempt
            # if the value is a non-expression string (image name).
            if (val ~ /^\$\{\{/) {
              job_has_container = 0  # expression — treat as "not guaranteed"
            } else {
              job_has_container = 1
            }
          }
        } else if (stripped ~ /^steps:[ \t]*$/) {
          in_steps = 1
          steps_indent = 4
        }
        next
      }

      # Within steps:
      if (in_steps) {
        # A step starts when we see `- name:` or `- uses:` or `- run:` at
        # the step list indent (steps_indent + 2 typically; the `-` is at
        # steps_indent + 2 columns? actually `      - name:` is at indent 6
        # when `    steps:` is at 4).
        # We detect step start by `- ` at any indent > steps_indent.
        if (stripped ~ /^- /) {
          # New step boundary.
          check_and_emit()
          step_indent = indent
          step_line = NR
          step_name = ""
          step_if = ""
          step_run = ""
          in_run_block = 0

          # The first line of a step may declare name/uses/run inline.
          line_after_dash = stripped
          sub(/^- /, "", line_after_dash)
          if (line_after_dash ~ /^name:/) {
            val = line_after_dash
            sub(/^name:[ \t]*/, "", val)
            step_name = val
          } else if (line_after_dash ~ /^run:/) {
            val = line_after_dash
            sub(/^run:[ \t]*/, "", val)
            if (val == "|" || val == ">" || val == "|-" || val == ">-" || val == "|+" || val == ">+") {
              in_run_block = 1
              run_block_indent = step_indent + 2
              step_run = ""
            } else {
              step_run = val
              in_run_block = 1
              run_block_indent = step_indent + 2
            }
          } else if (line_after_dash ~ /^if:/) {
            val = line_after_dash
            sub(/^if:[ \t]*/, "", val)
            step_if = val
          }
          next
        }

        # Step attribute (indent > step_indent and indent == step_indent + 2)
        if (step_indent >= 0 && indent == step_indent + 2) {
          # End any prior run block
          in_run_block = 0
          if (stripped ~ /^name:/) {
            val = stripped; sub(/^name:[ \t]*/, "", val); step_name = val
          } else if (stripped ~ /^if:/) {
            val = stripped; sub(/^if:[ \t]*/, "", val); step_if = val
          } else if (stripped ~ /^run:/) {
            val = stripped; sub(/^run:[ \t]*/, "", val)
            if (val == "|" || val == ">" || val == "|-" || val == ">-" || val == "|+" || val == ">+") {
              in_run_block = 1
              run_block_indent = step_indent + 4
              step_run = ""
            } else {
              step_run = val
              in_run_block = 1
              run_block_indent = step_indent + 4
            }
          }
          next
        }

        # Inside a run: |  block — accumulate while indent > step_indent
        if (in_run_block && indent > step_indent) {
          step_run = step_run "\n" stripped
          next
        }
      }
    }

    END {
      check_and_emit()
      # Print summary count to stdout for the outer script.
      printf("%d\n", offender_count)
    }
  ' "$wf" >> "$OFFENDERS_FILE"
done

# Sum offender counts (each awk run printed one integer to stdout via the
# combined output). The awk above writes offender lines to /dev/stderr and
# the per-file count to stdout, captured into OFFENDERS_FILE.
total=0
while IFS= read -r n; do
  [[ -z "$n" ]] && continue
  total=$((total + n))
done < "$OFFENDERS_FILE"

if [[ "$total" -gt 0 ]]; then
  echo "" >&2
  echo "FAIL: $total workflow step(s) run sudo/apt-get/pip-install without" >&2
  echo "      'if: runner.os == \"Linux\"' guard." >&2
  echo "" >&2
  echo "Each offender printed above as: OFFENDER<TAB>file:line<TAB>rule<TAB>step-name" >&2
  echo "" >&2
  echo "Fix: add  'if: runner.os == \"Linux\"'  immediately after the step's" >&2
  echo "      '- name:' line. Steps inside a container: job are exempt." >&2
  exit 1
fi

echo "OK: workflow Linux-only step guard sweep (INFRA-1539) — all guarded."
exit 0
