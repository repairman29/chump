//! COMP-008 — `chump --recipe <path>` recipe runner.
//!
//! A Chump Recipe is a YAML-declared shareable workflow: it packages required
//! env variables, required tools (scripts or binaries), named parameters with
//! defaults, and an ordered list of steps. Steps are shell commands assembled
//! from a `tool` path + `args` list where `{{param}}` tokens are substituted
//! from the caller-supplied or default parameter values.
//!
//! ## Schema (see docs/process/CHUMP_RECIPES.md for full reference)
//!
//! ```yaml
//! id: my-recipe
//! title: "Human-readable name"
//! description: "What this recipe does"
//! required_env:
//!   - MY_API_KEY
//! required_tools:
//!   - scripts/some-script.py
//! parameters:
//!   param_name:
//!     description: "What this param controls"
//!     required: false        # default false
//!     default: "some-value"  # omitted when required: true
//! steps:
//!   - name: step-name
//!     tool: scripts/some-script.py
//!     args: ["--flag", "{{param_name}}"]
//! ```
//!
//! ## Usage
//!
//! ```text
//! chump --recipe recipes/eval-cloud-sweep.yaml --model claude-haiku-4-5 --n 20
//! ```
//!
//! Parameters without defaults must be supplied on the command line as
//! `--<param_name> <value>`.

use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;

// ---------------------------------------------------------------------------
// Schema types
// ---------------------------------------------------------------------------

/// Top-level recipe file.
#[derive(Debug, Clone, Deserialize)]
pub struct Recipe {
    /// Unique kebab-case identifier, e.g. `eval-cloud-sweep`.
    pub id: String,
    /// Human-readable name shown in listings.
    pub title: String,
    /// Long-form description of the workflow.
    #[serde(default)]
    pub description: String,
    /// Environment variables that must be present before execution starts.
    #[serde(default)]
    pub required_env: Vec<String>,
    /// Tools (script paths or binary names) that must exist before execution.
    #[serde(default)]
    pub required_tools: Vec<String>,
    /// Parameter definitions keyed by name.
    #[serde(default)]
    pub parameters: HashMap<String, ParameterDef>,
    /// Ordered list of steps to execute.
    #[serde(default)]
    pub steps: Vec<Step>,
}

/// Definition of a single named parameter.
#[derive(Debug, Clone, Deserialize)]
pub struct ParameterDef {
    /// Human-readable description shown in `--recipe --help`.
    #[serde(default)]
    pub description: String,
    /// When true, the caller must supply this parameter explicitly (no default).
    #[serde(default)]
    pub required: bool,
    /// Default value used when the parameter is not supplied by the caller.
    pub default: Option<String>,
}

/// One executable step in a recipe.
#[derive(Debug, Clone, Deserialize)]
pub struct Step {
    /// Short name used in progress output.
    pub name: String,
    /// Executable: a script path (relative to repo root) or a binary on PATH.
    pub tool: String,
    /// Argument list; each element may contain `{{param_name}}` placeholders.
    #[serde(default)]
    pub args: Vec<String>,
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Load a recipe from a YAML file at `path`.
pub fn load_recipe(path: &Path) -> Result<Recipe> {
    let src = std::fs::read_to_string(path)
        .with_context(|| format!("cannot read recipe file: {}", path.display()))?;
    let recipe: Recipe = serde_yaml::from_str(&src)
        .with_context(|| format!("invalid recipe YAML: {}", path.display()))?;
    Ok(recipe)
}

/// Validate required env vars; return `Err` with a helpful message if any are missing.
pub fn validate_env(recipe: &Recipe) -> Result<()> {
    let missing: Vec<&str> = recipe
        .required_env
        .iter()
        .filter(|k| std::env::var(k).is_err())
        .map(String::as_str)
        .collect();
    if missing.is_empty() {
        return Ok(());
    }
    bail!(
        "Recipe '{}' requires the following env vars to be set:\n  {}",
        recipe.id,
        missing.join("\n  ")
    );
}

/// Validate required tools; checks file existence (for path-like values) then
/// falls back to PATH lookup (for bare binary names).
pub fn validate_tools(recipe: &Recipe, repo_root: &Path) -> Result<()> {
    let mut missing = Vec::new();
    for tool in &recipe.required_tools {
        let as_path = repo_root.join(tool);
        if as_path.exists() {
            continue;
        }
        // Try PATH lookup — construct a plain filename search
        let binary_name = Path::new(tool)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or(tool);
        let found_on_path = std::env::var("PATH").ok().is_some_and(|path_var| {
            path_var.split(':').any(|dir| {
                let candidate = Path::new(dir).join(binary_name);
                candidate.exists()
            })
        });
        if !found_on_path {
            missing.push(tool.clone());
        }
    }
    if missing.is_empty() {
        return Ok(());
    }
    bail!(
        "Recipe '{}' requires the following tools but they were not found:\n  {}",
        recipe.id,
        missing.join("\n  ")
    );
}

/// Substitute `{{param}}` placeholders in a string using `values`.
pub fn substitute(template: &str, values: &HashMap<String, String>) -> String {
    let mut out = template.to_owned();
    for (k, v) in values {
        out = out.replace(&format!("{{{{{}}}}}", k), v);
    }
    out
}

/// Resolve final parameter values: required params must be in `overrides`;
/// optional params fall back to `default`.
pub fn resolve_params(
    recipe: &Recipe,
    overrides: &HashMap<String, String>,
) -> Result<HashMap<String, String>> {
    let mut resolved = HashMap::new();
    for (name, def) in &recipe.parameters {
        if let Some(v) = overrides.get(name) {
            resolved.insert(name.clone(), v.clone());
        } else if let Some(default) = &def.default {
            resolved.insert(name.clone(), default.clone());
        } else if def.required {
            bail!(
                "Required parameter '{}' was not supplied. Pass it as: --{} <value>",
                name,
                name.replace('_', "-")
            );
        }
        // optional with no default and not supplied — simply absent (steps
        // that reference it will keep the raw {{placeholder}})
    }
    Ok(resolved)
}

/// Execute all steps in order. Returns `Err` on the first non-zero exit.
pub fn run_steps(
    recipe: &Recipe,
    params: &HashMap<String, String>,
    repo_root: &Path,
) -> Result<()> {
    for (i, step) in recipe.steps.iter().enumerate() {
        let step_num = i + 1;
        let total = recipe.steps.len();
        println!(
            "[recipe:{id}] step {n}/{t}: {name}",
            id = recipe.id,
            n = step_num,
            t = total,
            name = step.name
        );

        // Resolve tool path — prefer repo-relative, fall back to plain name
        let tool_path: PathBuf = {
            let candidate = repo_root.join(&step.tool);
            if candidate.exists() {
                candidate
            } else {
                PathBuf::from(&step.tool)
            }
        };

        // Substitute parameters in each arg
        let resolved_args: Vec<String> = step.args.iter().map(|a| substitute(a, params)).collect();

        let status = Command::new(&tool_path)
            .args(&resolved_args)
            .current_dir(repo_root)
            .status()
            .with_context(|| {
                format!(
                    "failed to spawn step '{}' (tool: {})",
                    step.name,
                    tool_path.display()
                )
            })?;

        if !status.success() {
            bail!(
                "Recipe '{}' step '{}' exited with code {}",
                recipe.id,
                step.name,
                status.code().unwrap_or(-1)
            );
        }
    }
    Ok(())
}

/// Top-level entry point: load, validate, resolve params, and run a recipe.
pub fn run_recipe(
    recipe_path: &Path,
    param_overrides: &HashMap<String, String>,
    repo_root: &Path,
) -> Result<()> {
    let recipe = load_recipe(recipe_path)?;
    validate_env(&recipe)?;
    validate_tools(&recipe, repo_root)?;
    let params = resolve_params(&recipe, param_overrides)?;
    run_steps(&recipe, &params, repo_root)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    fn minimal_yaml(extra: &str) -> String {
        format!(
            r#"id: test-recipe
title: Test
description: A minimal recipe for unit tests
{}
"#,
            extra
        )
    }

    #[test]
    fn load_minimal_recipe() {
        let yaml = minimal_yaml("");
        let mut f = NamedTempFile::new().unwrap();
        f.write_all(yaml.as_bytes()).unwrap();
        let recipe = load_recipe(f.path()).expect("should parse");
        assert_eq!(recipe.id, "test-recipe");
        assert!(recipe.required_env.is_empty());
        assert!(recipe.steps.is_empty());
    }

    #[test]
    fn validate_env_passes_when_all_present() {
        let yaml = minimal_yaml("required_env: [PATH]");
        let mut f = NamedTempFile::new().unwrap();
        f.write_all(yaml.as_bytes()).unwrap();
        let recipe = load_recipe(f.path()).unwrap();
        assert!(validate_env(&recipe).is_ok());
    }

    #[test]
    fn validate_env_fails_for_missing_var() {
        let yaml = minimal_yaml("required_env: [__CHUMP_NONEXISTENT_VAR_XYZ__]");
        let mut f = NamedTempFile::new().unwrap();
        f.write_all(yaml.as_bytes()).unwrap();
        let recipe = load_recipe(f.path()).unwrap();
        let err = validate_env(&recipe).unwrap_err();
        assert!(err.to_string().contains("__CHUMP_NONEXISTENT_VAR_XYZ__"));
    }

    #[test]
    fn substitute_replaces_placeholders() {
        let mut vals = HashMap::new();
        vals.insert("model".to_string(), "claude-haiku-4-5".to_string());
        vals.insert("n".to_string(), "50".to_string());
        let result = substitute("--model {{model}} --n {{n}}", &vals);
        assert_eq!(result, "--model claude-haiku-4-5 --n 50");
    }

    #[test]
    fn substitute_leaves_unknown_placeholders_intact() {
        let vals = HashMap::new();
        let result = substitute("--model {{model}}", &vals);
        assert_eq!(result, "--model {{model}}");
    }

    #[test]
    fn resolve_params_uses_defaults() {
        let yaml = minimal_yaml(
            r#"parameters:
  model:
    description: "Model to use"
    required: true
  n:
    description: "Trials"
    default: "50"
"#,
        );
        let mut f = NamedTempFile::new().unwrap();
        f.write_all(yaml.as_bytes()).unwrap();
        let recipe = load_recipe(f.path()).unwrap();
        let mut overrides = HashMap::new();
        overrides.insert("model".to_string(), "claude-haiku-4-5".to_string());
        let params = resolve_params(&recipe, &overrides).unwrap();
        assert_eq!(params["model"], "claude-haiku-4-5");
        assert_eq!(params["n"], "50");
    }

    #[test]
    fn resolve_params_errors_on_missing_required() {
        let yaml = minimal_yaml(
            r#"parameters:
  model:
    description: "Model"
    required: true
"#,
        );
        let mut f = NamedTempFile::new().unwrap();
        f.write_all(yaml.as_bytes()).unwrap();
        let recipe = load_recipe(f.path()).unwrap();
        let overrides = HashMap::new();
        let err = resolve_params(&recipe, &overrides).unwrap_err();
        assert!(err.to_string().contains("model"));
    }

    #[test]
    fn validate_tools_accepts_path_binary() {
        // "sh" is guaranteed to be on PATH
        let yaml = minimal_yaml("required_tools: [sh]");
        let mut f = NamedTempFile::new().unwrap();
        f.write_all(yaml.as_bytes()).unwrap();
        let recipe = load_recipe(f.path()).unwrap();
        let tmp_dir = tempfile::tempdir().unwrap();
        assert!(validate_tools(&recipe, tmp_dir.path()).is_ok());
    }

    #[test]
    fn validate_tools_fails_for_missing_tool() {
        let yaml = minimal_yaml("required_tools: [scripts/__nonexistent_tool_xyz__.py]");
        let mut f = NamedTempFile::new().unwrap();
        f.write_all(yaml.as_bytes()).unwrap();
        let recipe = load_recipe(f.path()).unwrap();
        let tmp_dir = tempfile::tempdir().unwrap();
        let err = validate_tools(&recipe, tmp_dir.path()).unwrap_err();
        assert!(err.to_string().contains("__nonexistent_tool_xyz__"));
    }
}
