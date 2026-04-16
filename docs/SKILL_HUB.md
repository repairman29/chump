# Skill Hub

The Skill Hub lets Chump install procedural **skills** (`SKILL.md` files) from
remote registries instead of requiring manual copy-paste into
`chump-brain/skills/<name>/SKILL.md`.

## Overview

A skill registry is just a JSON document listing skills with metadata and
either an inline body or a URL to fetch the `SKILL.md`. Chump speaks two
formats:

1. **Chump native** — `{ "version": "...", "skills": [SkillHubEntry, ...] }`
2. **Hermes-compatible** — a bare JSON array (`[SkillHubEntry, ...]`),
   conventionally served at `/.well-known/skills/index.json`. This is the
   convention used by the `skills.sh` ecosystem; Chump indexes are
   interoperable.

`SkillHubEntry` fields:

| Field             | Required | Notes                                             |
| ----------------- | -------- | ------------------------------------------------- |
| `name`            | yes      | Must match the `name:` in the SKILL.md frontmatter |
| `description`     | yes      | One-line summary                                  |
| `version`         | no       | String; defaults to `"1"`                         |
| `author`          | no       |                                                   |
| `source_url`      | no       | URL to fetch the SKILL.md body                    |
| `inline_content`  | no       | Embedded SKILL.md body (alias: `content`, `skill_md`) |
| `tags`            | no       | List of tag strings                               |
| `category`        | no       |                                                   |
| `checksum_sha256` | no       | Reserved for future verification                  |

Either `source_url` or `inline_content` must be present.

## Configuration

Set the `CHUMP_SKILL_REGISTRIES` environment variable to a comma-separated
list of registry URLs:

```bash
export CHUMP_SKILL_REGISTRIES="https://example.com/skills/index.json,https://other.example/.well-known/skills/index.json"
```

Defaults: **none** (opt-in).

Future well-known registry to try (planned, not yet hosted):

- `https://raw.githubusercontent.com/chump-community/skills/main/index.json`

## Usage

The `skill_hub` tool exposes five actions:

| Action            | Purpose                                          |
| ----------------- | ------------------------------------------------ |
| `list_registries` | Show configured registry URLs                    |
| `index_info`      | Probe each registry and report reachability      |
| `search`          | Search across registries by name/description/tag |
| `install`         | Install a named skill from the first match       |
| `install_url`     | Install from a direct SKILL.md URL               |

Example agent invocations:

```json
{ "action": "search", "query": "clippy" }
{ "action": "install", "name": "fix-clippy-warnings" }
{ "action": "install_url", "url": "https://example.com/skills/fix-clippy/SKILL.md" }
```

## Interop with Hermes / skills.sh

The Hermes ecosystem publishes registries at
`/.well-known/skills/index.json`. Chump:

- Accepts both the object form and the bare-array form.
- Treats Hermes registries as first-class. Add their URL to
  `CHUMP_SKILL_REGISTRIES` and the Skill Hub Just Works.
- Writes installed skills using the same SKILL.md schema used by Hermes,
  so a skill authored for Chump can be served back to a Hermes-compatible
  client without modification.

The intent is **parasitize and contribute back**: pull from upstream
ecosystems when useful, and publish Chump-authored skills in the same
shape so they're consumable elsewhere.

## Security considerations

Skills execute via Chump's tool layer (an agent may follow a skill's
`## Procedure` and run shell, file, or network commands). Treat skill
installation like installing third-party code:

- **Audit before install.** Use `install_url` only with sources you trust,
  or copy the SKILL.md locally and review.
- The hub's `security_scan` runs on every install. It **hard-fails** on:
  - Skills whose name is reserved (collides with a built-in tool).
  - Bodies larger than `MAX_SKILL_LEN` (~32 KB).
  - Malformed YAML frontmatter.
- It **soft-warns** (does not block) on:
  - Shell command patterns (`rm -rf`, `curl | sh`, `sudo`, ...).
  - References to sensitive paths (`/etc/`, `/var/`, `~/.ssh`, ...).
  - HTTP(S) URLs (potential fetch-and-execute patterns).
  - Long base64-looking blobs.
- Warnings are surfaced in the `install` tool result so the operator can
  see what tripped the heuristic.

## Air-gap mode

If `CHUMP_AIR_GAP_MODE=1`, all hub actions that would touch the network
refuse cleanly. `list_registries` still works (purely local).

## Hosting your own registry

Serve any of the following as a static JSON file at a public URL:

```jsonc
// Chump native form
{
  "version": "1.0",
  "skills": [
    {
      "name": "fix-clippy-warnings",
      "description": "Systematic approach to resolving Rust clippy warnings",
      "version": "1",
      "tags": ["rust", "lint"],
      "category": "code-quality",
      "source_url": "https://example.com/skills/fix-clippy/SKILL.md"
    }
  ]
}
```

```jsonc
// Hermes-compatible bare array
[
  {
    "name": "fix-clippy-warnings",
    "description": "Systematic approach to resolving Rust clippy warnings",
    "source_url": "https://example.com/skills/fix-clippy/SKILL.md"
  }
]
```

Inline form (no separate fetch needed):

```jsonc
{
  "skills": [
    {
      "name": "hello",
      "description": "Trivial greeter",
      "content": "---\nname: hello\ndescription: Trivial greeter\n---\n## Procedure\n1. Say hello\n"
    }
  ]
}
```

A 30-second timeout applies to each registry/skill fetch.

## Network errors

Offline users see a friendly message naming the failing registry; other
configured registries are still tried before giving up.
