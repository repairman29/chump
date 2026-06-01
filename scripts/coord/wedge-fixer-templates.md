# wedge-fixer template library (INFRA-2069)

Operator reference for the wedge-fixer auto-dispatch system.
Template library: `scripts/coord/wedge-fixer-templates.yaml`
Dispatcher: `scripts/coord/wedge-fixer-dispatch.sh`

## Status

- AC #1 (template library), AC #5 (this doc), AC #6 (EVENT_REGISTRY entries): shipped in this PR.
- AC #2/#3/#4 (auto-dispatch, rate-limit, safety guards): deferred to follow-up PR once INFRA-2068 lands.

The dispatcher currently produces a **rendered prompt for operator review**. The operator pastes the
prompt into a Sonnet Agent tool invocation. Full auto-dispatch fires once INFRA-2068 ships the
`kind=wedge_class_detected` consumer hook.

---

## Quick start — manually dispatch a template

```bash
# 1. Identify the failure class (fmt-drift | orphan-event | printf-grep)
# 2. Run the dispatcher in --dry-run mode to preview the prompt
bash scripts/coord/wedge-fixer-dispatch.sh \
  --gap INFRA-XXXX \
  --template fmt-drift \
  --dry-run

# 3. For orphan-event, supply the event kind:
bash scripts/coord/wedge-fixer-dispatch.sh \
  --gap INFRA-XXXX \
  --template orphan-event \
  --event-kind my_new_kind \
  --dry-run

# 4. For printf-grep, supply the file with violations:
bash scripts/coord/wedge-fixer-dispatch.sh \
  --gap INFRA-XXXX \
  --template printf-grep \
  --violation-file scripts/coord/some-script.sh \
  --dry-run

# 5. When satisfied with the preview, emit the ambient event:
bash scripts/coord/wedge-fixer-dispatch.sh \
  --gap INFRA-XXXX \
  --template fmt-drift \
  --execute

# 6. Copy the rendered prompt and paste into a Sonnet Agent tool invocation.
```

---

## Shipped templates

| template_name  | signature_pattern (regex)                                              | max_loc | what it fixes                              |
|----------------|------------------------------------------------------------------------|---------|--------------------------------------------|
| `fmt-drift`    | `cargo fmt.*--check\|running \`cargo fmt\`\|Diff in .*\.rs`           | 500     | cargo fmt drift — pure formatting fix      |
| `orphan-event` | `event registry violation\|kind=\S+ not registered\|emit-without-register` | 30  | unregistered event kind in EVENT_REGISTRY  |
| `printf-grep`  | `printf.*\|.*grep\|RESILIENT-031`                                      | 80      | RESILIENT-031 printf\|grep → case pattern  |

---

## Authoring a new template

### 1. Design the signature pattern

The `signature_pattern` is a regex matched against:
- CI failure log text
- PR title / body
- `kind=wedge_class_detected` ambient event fields (once INFRA-2068 ships)

Keep patterns specific enough to avoid false matches. Test against real CI failure output:

```bash
echo "cargo fmt -- --check failed" | grep -E "cargo fmt.*--check|running \`cargo fmt\`"
```

### 2. Write the prompt template

Prompt templates use `{{UPPER_CASE}}` placeholder syntax. Reserved placeholders:

| Placeholder        | Resolved from                                         |
|--------------------|-------------------------------------------------------|
| `{{GAP_ID}}`       | `--gap` flag                                          |
| `{{WORKTREE_PATH}}`| `--worktree` flag or auto-detected from claim lease   |
| `{{EVENT_KIND}}`   | `--event-kind` flag (orphan-event template)           |
| `{{VIOLATION_FILE}}`| `--violation-file` flag (printf-grep template)       |

Add new placeholders by extending the dispatcher's render block in
`scripts/coord/wedge-fixer-dispatch.sh` (the `# ── render placeholders ──` section).

**Prompt discipline:**
- State the mission in 1-2 sentences.
- Give numbered steps — the agent executes them in order.
- Include an explicit "Out of scope" block — prevents scope creep.
- End with a "Done when" criterion so the agent knows when to stop.

### 3. Set max_loc conservatively

`max_loc` is the maximum lines-of-code the fix should touch. Choose the smallest
number that covers the expected fix. The safety guard in `bot-merge.sh` will reject
a diff that exceeds this. If you're unsure, start low — the operator can override
on a one-off basis.

| Fix class      | Typical max_loc |
|----------------|-----------------|
| fmt-drift      | 200–500         |
| single-file    | 30–80           |
| doc-only       | 20–40           |

### 4. Add a smoke_test

The `smoke_test` field is a shell command run by the dispatcher to verify the template
is well-formed. At minimum use `echo 'X template renders OK'`. For templates with
more complex validation:

```yaml
smoke_test: "bash -n scripts/coord/some-related-script.sh && echo OK"
```

### 5. Add a YAML entry

```yaml
  - template_name: my-new-template
    signature_pattern: "regex matching the CI failure"
    prompt_template: |
      You are a Sonnet subagent...
      Gap: {{GAP_ID}}
      Worktree: {{WORKTREE_PATH}}
      ...
    max_loc: 50
    smoke_test: "echo 'my-new-template renders OK'"
```

### 6. Verify

```bash
# YAML parses cleanly
python3 -c "import yaml; yaml.safe_load(open('scripts/coord/wedge-fixer-templates.yaml'))" && echo "OK"

# Smoke test passes
bash scripts/ci/test-wedge-fixer-dispatch.sh
```

---

## EVENT_REGISTRY integration

The dispatcher emits `kind=wedge_fixer_template_rendered` to `ambient.jsonl` when
run with `--execute`. This event is registered in `docs/observability/EVENT_REGISTRY.yaml`.

Once INFRA-2068 ships, the auto-dispatch consumer will read `kind=wedge_class_detected`
events (which carry `template_name` and `gap_id`) and invoke the dispatcher automatically.
The manual `--execute` path will remain available for operator override.

---

## CI gate

`scripts/ci/test-wedge-fixer-dispatch.sh` runs on every PR and asserts:
1. YAML loads cleanly
2. All 3 templates render without `{{PLACEHOLDER}}` residuals
3. Dispatcher `--dry-run` exits 0 for all templates
4. Unknown template name exits non-zero
5. Missing required placeholder exits non-zero
