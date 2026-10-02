# Filing follow-up gaps — the feeder system

Moved out of `AGENTS.md` by ZERO-WASTE-125 (rulebook line-budget cut).

The gap registry only stays useful if it is actively fed. When you spot a
real bug, design hole, tooling drift, reproducible guard misfire,
coordination race, or non-obvious finding while doing other work — file it
immediately. Don't ask the operator first.

**Why non-negotiable:** the cost of NOT filing is silent regression —
every shipped session leaves behind unfiled findings that die with the
session and resurface later as fresh incidents. The cost of over-filing is
near zero (gap-doctor and the closer-pr-batcher clean up). Asymmetric cost
= bias toward filing.

**Triggers:** a bug diagnosed end-to-end; a tool/workflow that doesn't
behave as documented; a misfiring pre-commit/pre-push/CI guard; a
coordination race recovered from manually; a toolchain mismatch; a
pattern that already happened ≥2 times recently.

**Skip only when:** you lack confidence the finding is real; it's
speculation about a hypothetical nobody's hit; it's already filed (search
`chump gap list --status open` first).

## Filing flow

```bash
chump gap reserve --domain INFRA --title "<one-line title>" --priority P1 --effort s
chump gap set INFRA-NNN --description "<what's broken, reproducer, fix paths>" \
  --acceptance-criteria "<criterion 1>|<criterion 2>"
git add docs/gaps/INFRA-NNN.yaml
CHUMP_RAW_YAML_LOCK=0 scripts/coord/chump-commit.sh docs/gaps/INFRA-NNN.yaml \
  -m "chore(gaps): file INFRA-NNN — <title>"
CHUMP_GAP_CHECK=0 git push -u origin chore/file-infra-NNN
gh pr create --base main --title "..." --body "..." && \
  gh pr merge $(gh pr list --head chore/file-infra-NNN --json number -q '.[0].number') --auto --squash
```

**Priority:** P0 blocks current work for the fleet; P1 is observed-and-painful;
P2 is niggling (not actively biting).

**Bundling:** findings sharing a session origin or causal chain can bundle
into one PR with multiple `chore(gaps): file …` entries — still one
state.db row + YAML per gap.

The `chump_skills` table and the lessons-injection pipeline both depend on
this feeder system: filings → reflections → distilled directives → next
session's prompt context.
