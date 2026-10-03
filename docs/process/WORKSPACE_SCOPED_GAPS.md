# Workspace-scoped gaps — route to operator/ATC, don't fleet-dispatch (RESILIENT-292)

Moved out of `AGENTS.md` by ZERO-WASTE-125 (rulebook line-budget cut).

A fleet-worker claims a linked worktree scoped to a single repo. It has no
filesystem path to sibling workspace-level directories one level above the
claiming repo. A gap whose acceptance criteria require reading or writing
real content at that level cannot be honestly shipped from an isolated
fleet-worker clone: the only options from inside the sandbox are fabricate
(a CREDIBLE violation) or decline. CREDIBLE-234 hit this wall 13 times
across fresh sandboxes before this rule landed — pure waste.

**Decision (2026-08-10): route, don't provision.** Rather than mirror
sibling repos into every fleet-worker sandbox, workspace-scoped gaps are
tagged and routed to a session that already has real `~/Projects` access.

- **Filing convention.** Any gap whose evidence/description references
  paths outside the claiming repo's own tree MUST carry the
  `skills_required` tag `workspace_scope`:
  `chump gap set <ID> --skills-required workspace_scope`.
- **Enforcement.** `WorkerCapability::matches` gates any gap tagged
  `workspace_scope` behind `CHUMP_WORKSPACE_SCOPE_PICK_OK=1` — mirrors the
  `external_repo:` pattern (INFRA-2113). An operator/ATC session exports
  this env var before picking.
- **Not a manufacture-more-gaps lever.** This tag routes existing
  workspace-scoped work; it is not a reason to file new workspace-level
  gaps for their own sake.
