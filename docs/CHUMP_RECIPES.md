---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
---

# Chump Recipes

> Gap: COMP-008 — first shipped in the same PR.

A **Chump Recipe** is a YAML artifact that packages a reusable workflow with
its declared dependencies and parameters. Recipes live in the `recipes/`
directory of the repo and can be run with:

```
chump --recipe <path-to-recipe.yaml> [--<param> <value> ...]
```

Recipes draw inspiration from [Block's Goose recipes](https://block.github.io/goose/docs/guides/recipes/)
but are tailored to Chump's multi-agent, eval-centric workflow where the key
resources are eval scripts, API keys, and model-string parameters rather than
desktop extensions.

---

## Schema reference

A recipe is a YAML file with the following top-level fields:

```yaml
id: <kebab-case-string>           # required; unique identifier
title: "Human-readable name"      # required
description: |                    # optional; shown in help output
  Multi-line description.

required_env:                     # optional; list of env var names
  - MY_API_KEY                    #   that must be set before the recipe runs

required_tools:                   # optional; list of scripts or binaries
  - scripts/some-script.py        #   that must exist (file path relative to
  - jq                            #   repo root) or be on PATH

parameters:                       # optional; named parameter definitions
  param_name:
    description: "What it controls"
    required: false               # default false; when true caller must supply
    default: "some-value"         # omitted when required: true

steps:                            # ordered list of execution steps
  - name: step-label              # used in progress output
    tool: scripts/some-script.py  # executable (repo-relative path or binary)
    args:                         # argument list; {{param_name}} is substituted
      - "--flag"
      - "{{param_name}}"
```

### Field details

| Field | Required | Description |
|---|---|---|
| `id` | yes | Kebab-case unique ID. Used in log output. |
| `title` | yes | Short human-readable name. |
| `description` | no | Long-form description of the workflow. |
| `required_env` | no | Env vars that must be set. Recipe aborts with a helpful error if any are missing. |
| `required_tools` | no | Tools that must exist. Checked as repo-relative paths first, then on `$PATH`. |
| `parameters` | no | Named inputs with optional defaults. Required parameters must be supplied on the command line. |
| `steps` | no | Ordered steps. Each step runs the `tool` with the resolved `args`. |

### Parameter substitution

In step `args`, any occurrence of `{{param_name}}` is replaced with the
resolved parameter value. Parameter values are resolved in this priority order:

1. Caller-supplied value (`chump --recipe <path> --<param_name> <value>`)
2. `default` from the parameter definition
3. If `required: true` and no value is supplied — abort with an error

Unknown placeholders (no matching parameter) are left as-is in the args rather
than causing a silent error.

---

## Lifecycle

```
load recipe YAML
    │
    ▼
validate required_env      ← abort with helpful error if any missing
    │
    ▼
validate required_tools    ← abort if file not found and not on PATH
    │
    ▼
resolve parameters          ← merge caller overrides with defaults
    │
    ▼
execute steps in order      ← abort on first non-zero exit code
```

Discovery is intentionally simple: recipes are plain YAML files. There is no
central index. Agents and humans can reference them by path or list them with
`ls recipes/`.

---

## Running a recipe

```bash
# Minimum: supply all required parameters
chump --recipe recipes/eval-cloud-sweep.yaml --model claude-haiku-4-5

# Override optional parameters
chump --recipe recipes/eval-cloud-sweep.yaml \
  --model claude-haiku-4-5 \
  --n 20 \
  --fixtures reflection,perception

# Dry-run hint: set NO_OP=1 if the underlying script supports it
NO_OP=1 chump --recipe recipes/eval-cloud-sweep.yaml --model claude-haiku-4-5
```

Parameter names use `--` prefix and underscores are converted to hyphens for
the command-line flag (e.g. `lessons_version` → `--lessons-version`).

---

## Bundled recipes

### `recipes/eval-cloud-sweep.yaml`

Packages the multi-fixture A/B eval sweep against a single model using
`scripts/ab-harness/run-cloud-v2.py`.

**Required env:** `TOGETHER_API_KEY`, `ANTHROPIC_API_KEY`

**Required tools:** `scripts/ab-harness/run-cloud-v2.py`

| Parameter | Required | Default | Description |
|---|---|---|---|
| `model` | yes | — | Provider model string (e.g. `claude-haiku-4-5`) |
| `fixtures` | no | `reflection,perception,neuromod` | Comma-separated fixture names |
| `n` | no | `50` | Trials per cell |
| `lessons_version` | no | `v1` | Lessons block version (`v1`, `v2`, or `off`) |
| `judges` | no | `claude-haiku-4-5,meta-llama/Llama-3.3-70B-Instruct-Turbo` | Comma-separated judge models |

---

## Writing a new recipe

1. Create `recipes/<your-recipe-id>.yaml` following the schema above.
2. Test it locally: `chump --recipe recipes/<your-recipe-id>.yaml [--params ...]`
3. Add a brief entry to the Bundled recipes section of this doc in the same PR.

Guidelines:
- Keep recipes narrow and single-purpose. One recipe = one logical workflow.
- Prefer listing all required env and tools so failures are caught before the first step runs.
- Use descriptive `name` fields on steps so progress output is self-explanatory.
- Recipes are committed to the repo and reviewed like code; do not embed secrets.
