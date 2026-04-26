#!/usr/bin/env bash
# Shared prompt for sprint_synthesis heartbeat rounds. Sourced by heartbeat-self-improve.sh
# and any script that wants to run a sprint synthesis round. Do not execute directly.

sprint_synthesis_prompt() {
  cat <<'EOF'
Self-improve round: **sprint synthesis** — generate and commit a narrative session synthesis.

**Goal:** Produce a synthesis document capturing what was built, what was learned, and where to pick up. This is the narrative layer above individual commit messages — a future agent reading this cold should be able to orient in < 5 min.

**Steps:**

1. **Run the synthesis script:**
   ```
   run_cli "./scripts/eval/generate-sprint-synthesis.sh"
   ```
   The script collects git log + SQLite data and calls the model to generate the synthesis. On success it prints the output file path. On failure it prints an error to stderr.

2. **If the script exits non-zero:**
   - If the error mentions `docs/syntheses/ not found`: PRODUCT-004 has not landed yet. episode log "sprint_synthesis: skipped — docs/syntheses/ missing (PRODUCT-004 not merged)" and stop.
   - If the error mentions `Chump binary not found`: episode log "sprint_synthesis: skipped — binary not built" and stop.
   - Otherwise: episode log the error and notify Jeff.

3. **Review the output:**
   read_file the path returned by the script. Verify all nine sections are present and no section is a bare placeholder ("TBD", "[link]", etc.). If a section is missing key data you can infer from context (ego read_all + task list + episode recent limit 10), use patch_file to fill it in. Do not invent data — if a section genuinely has no data, a one-line "No X in this span" is correct.

4. **Commit and push:**
   ```
   run_cli "scripts/coord/chump-commit.sh <synthesis-file-path> -m 'docs(synthesis): auto-generate $(date +%Y-%m-%d) session synthesis'"
   ```
   Then git_push on branch `chump/synthesis-$(date +%Y-%m-%d)`. Optionally gh_create_pr with a brief description of what the synthesis covers.

5. **Wrap up:**
   episode log (synthesis span, file path, which sections had real data vs. sparse). ego update (current_focus = what the synthesis captured as the active thread). notify Jeff only if something unexpected came up (surprising metric, emerging bloat, or a blocker that needs a human decision).

**Rules:**
- This round is documentation only — no code changes, no Cargo.toml edits.
- DRY_RUN → `run_cli "CHUMP_DRY_RUN=1 ./scripts/eval/generate-sprint-synthesis.sh"` and print the context block only; do not write or commit.
- If docs/syntheses/ is missing, skip gracefully — do not create it (that is PRODUCT-004's scope).
EOF
}
