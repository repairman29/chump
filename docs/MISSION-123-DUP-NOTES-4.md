# MISSION-123 (re-filed) — closed as duplicate, fourth occurrence

This gap ID was re-filed as open a fourth time after being closed as a
duplicate of PR #5225 (commit `3528c5ade`, "node capacity planner sheds on
hard-limit breach") three times already — see `docs/MISSION-123-NOTES.md`,
`docs/MISSION-123-DUP-NOTES-2.md`, `docs/MISSION-123-DUP-NOTES-3.md`.

Re-verified on this branch that all 4 acceptance criteria still hold on
`origin/main`:

1. **AC1** — `shed_target()` in `scripts/ops/node-capacity-plan.sh` returns
   `"shed"` once load strictly exceeds the hard limit.
2. **AC2** — on shed, the lowest-priority (highest-numbered) worker is
   stopped and `plan.json` records `shed.action`/`shed.target`.
3. **AC3** — log line `auto-size shed triggered: ...` is emitted verbatim.
4. **AC4** — normal loads and the last-worker guard are untouched/correct.

`bash scripts/ci/test-node-capacity-plan.sh` passes clean, including the
`MISSION-123: planner shed-on-breach integration` section. No new code
needed — closing as a duplicate again rather than re-implementing existing
coverage. Precedent: `docs/MISSION-123-NOTES.md`,
`docs/MISSION-123-DUP-NOTES-2.md`, `docs/MISSION-123-DUP-NOTES-3.md`.
