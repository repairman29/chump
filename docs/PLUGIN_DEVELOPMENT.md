# Chump Plugin Development Guide

> **Status:** V1 scaffold. Static (compile-time) plugin registration only.
> Dynamic loading (V2) is on the roadmap — see [Roadmap](#roadmap).

Chump plugins let third-party developers extend the agent with new tools,
context engines, adapters, and skills **without forking the host repo**.

This guide describes the plugin contract, manifest format, discovery rules,
and recommended layout for the V1 scaffold.

---

## Overview

A Chump plugin is a Rust crate (V1) or shared library (V2) that implements the
`ChumpPlugin` trait defined in `src/plugin.rs`. At host startup, Chump:

1. Scans the discovery sources for `plugin.yaml` manifests.
2. Loads any statically-registered plugins compiled into the binary.
3. Calls each plugin's `initialize(&PluginContext)` once.

Plugins register their contributions (tools, etc.) inside `initialize()` using
the host's existing registries (e.g. the `inventory`-based tool registry).

## Discovery

Chump scans these sources, in order. Later sources win on name collisions.

| Order | Source                                          | Purpose                      |
| ----- | ----------------------------------------------- | ---------------------------- |
| 1     | `~/.chump/plugins/<name>/`                      | User-level (per-machine)     |
| 2     | `<CHUMP_REPO>/.chump/plugins/<name>/`           | Project-level (checked in)   |
| 3     | Cargo dependency named `chump-plugin-*`         | Build-time (static linkage)  |

`CHUMP_HOME` overrides the user root (`$CHUMP_HOME/plugins/`).
`CHUMP_REPO` (or the active working-repo override) selects the project root.

## `plugin.yaml` Format

```yaml
# Required
name: hello-plugin            # unique, lowercase, hyphenated
version: 0.1.0                # free-form (semver recommended)

# Optional
description: Says hello from a plugin.
author: Jane Doe <jane@example.com>

# Cargo features the host binary must have enabled. Plugins listing
# unmet features are loaded as inert and a warning is emitted.
requires_features:
  - inprocess-embed

# Path (relative to the plugin dir) to the entry artifact.
# V1: informational only. V2: passed to libloading::Library::new.
entry_path: lib/libhello_plugin.dylib

# Declarative summary of what this plugin contributes. Advisory only —
# the plugin's initialize() is the source of truth.
provides:
  tools: [hello, wave]
  context_engines: [greeter]
  adapters: []
  skills: []

# Optional JSON Schema for the plugin's user-facing config block.
config_schema:
  type: object
  properties:
    greeting:
      type: string
      default: "hello"
```

## Implementing a Plugin (V1, static)

```rust
use anyhow::Result;
use chump::plugin::{ChumpPlugin, PluginContext, PluginManifest, PluginProvides};

pub struct HelloPlugin;

impl ChumpPlugin for HelloPlugin {
    fn name(&self) -> &str { "hello-plugin" }
    fn version(&self) -> &str { "0.1.0" }

    fn manifest(&self) -> PluginManifest {
        PluginManifest {
            name: self.name().into(),
            version: self.version().into(),
            description: Some("Says hello.".into()),
            author: None,
            requires_features: vec![],
            entry_path: None,
            config_schema: serde_json::Value::Null,
            provides: PluginProvides {
                tools: vec!["hello".into()],
                ..Default::default()
            },
        }
    }

    fn initialize(&self, _ctx: &PluginContext) -> Result<()> {
        // Register tools, context engines, adapters here.
        // For inventory-based tools, your `#[chump_tool]` annotations
        // already self-register at link time.
        Ok(())
    }
}
```

### Registering Tools

The host uses the `inventory` crate for tool registration via the
`chump-tool-macro` proc macro. Plugins compiled into the binary can use the
same macro and their tools will appear in the tool registry automatically — no
explicit registration call needed inside `initialize()`.

### Context Engines & Adapters

V1 expects context engines and adapters to register themselves through the
existing module-level constructors. A future revision will add explicit
registry handles to `PluginContext`.

## Recommended Plugin Layout

```
my-plugin/
├── plugin.yaml
├── Cargo.toml          # cdylib + rlib for V2 forward-compat
├── README.md
└── src/
    └── lib.rs
```

For project-local plugins, drop the directory under
`<repo>/.chump/plugins/my-plugin/` and check it into the repo.

## Security Considerations

- **Trust model:** plugins run **in-process** with the same privileges as
  Chump itself. Only install plugins from sources you trust.
- **Manifest validation:** Chump verifies `name` and `version` are non-empty
  before loading a manifest. Other fields are accepted as-is — don't rely on
  the host to sanitize them.
- **Feature gating:** declare `requires_features` for any host feature flag
  your plugin needs. Unmet requirements load the plugin as inert rather than
  panicking, but the user is warned.
- **No network at discovery:** discovery only touches the local filesystem.
  Plugins are free to make network calls inside `initialize()`, but should not
  block the startup path.
- **Path safety:** `PluginContext.plugin_dir` is the only directory a plugin
  should write to without explicit user consent. Treat the brain path and repo
  root as read-mostly.
- **V2 dynamic loading** will require code-signing or a trust-on-first-use
  prompt before `dlopen`-ing arbitrary `.dylib`/`.so` files.

## Roadmap

- **V1 (this scaffold)**
  - Manifest types (`PluginManifest`, `PluginProvides`)
  - `ChumpPlugin` trait
  - Filesystem discovery (`discover_plugins`)
  - Static (compile-time) registration only
- **V2 — dynamic loading**
  - `libloading`-based `cdylib` loading via `entry_path`
  - C-ABI plugin entry point + version handshake
  - Per-plugin sandboxing (capability-scoped `PluginContext`)
- **V3 — distribution**
  - `chump plugin install <name>` CLI command
  - Signed plugin index / registry
  - Hot reload during `chump dev`
