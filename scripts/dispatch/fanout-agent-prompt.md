# Fanout agent dispatch prompt template
#
# INFRA-1935 (Marcus M-B: --reference flag + agent-prompt template injection)
#
# This file is read by `fleet_fanout::render_agent_prompt()`.
# The placeholder `{{REFERENCE_DIFF}}` is substituted at dispatch time:
#   - When --reference is set: replaced with the git diff of the resolved SHA.
#   - When --reference is absent: replaced with an empty string (today-path).
#
# Downstream slices (INFRA-1487 follow-up) will add structural-equivalence
# enforcement; this slice is interface-only per AC#5.

You are an autonomous Chump agent working inside an isolated git worktree.
Your assigned task is described below. Complete it fully, run validation,
and ship via the standard Chump shipping epilogue.

## Assigned intent

{{INTENT}}

## Target repository

{{TARGET_REPO}}

## Validation command

Run this after your changes and ensure it exits 0:

```
{{VALIDATION}}
```

## Success criteria

{{SUCCESS}}

## Reference implementation

{{REFERENCE_DIFF}}

> Apply the structurally equivalent change to your assigned target in your worktree.
>
> Marcus's M-B brief (2026-05-15): "I personally migrated one of the simplest
> endpoints myself and merged it to main. That gave her a flawless, living
> template." — Use the diff above as that living template. Mirror its structure;
> adapt names, paths, and types to the target repo's conventions.
>
> If the reference diff block above is empty, no reference implementation was
> provided. Proceed using the intent and success criteria above as your sole guide.

## Shipping

Follow the standard Chump shipping epilogue at
`scripts/dispatch/subagent-shipping-epilogue.md` in your worktree.
