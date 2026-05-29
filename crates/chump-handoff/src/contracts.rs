//! The three concrete contracts called out by INFRA-1720 AC #3.
//!
//! These are *real* contract shapes — i.e. when (not if) we rewrite the
//! current markdown-prompt subagent spawn sites in `src/agent_factory.rs`
//! and the auto-decompose path, these are the types they'll use.
//!
//! Each contract:
//!
//! * Has `Input`/`Output` structs with `#[derive]` for serde.
//! * Implements [`crate::Validate`] on `Output` (semantic checks beyond schema).
//! * Implements [`crate::HandoffContract`] with a `prompt()` template that
//!   tells the subagent the exact JSON shape it must emit.
//! * Picks a `model_tier` appropriate to the work.

use crate::{HandoffContract, ModelTier, Validate, ValidationError};
use serde::{Deserialize, Serialize};

// ── (a) GapReviewContract ─────────────────────────────────────────────────

/// Input to a "review this gap" subagent: the gap ID + optional context.
#[derive(Debug, Clone, Serialize)]
pub struct GapReviewInput {
    /// Gap identifier (e.g. `INFRA-1720`).
    pub gap_id: String,
    /// Free-form context the parent already has (gap description, related PRs).
    pub context: String,
}

/// Output from gap-review: a verdict + reasoning + any blocking concerns.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct GapReviewOutput {
    /// Verdict tag — one of `approve` | `revise` | `block`.
    pub verdict: String,
    /// Free-form reasoning supporting the verdict.
    pub reasoning: String,
    /// Specific concerns the parent must address before proceeding (may be empty).
    pub blocking_concerns: Vec<String>,
}

impl Validate for GapReviewOutput {
    fn validate(&self) -> Result<(), ValidationError> {
        // Verdict is the only field the parent routes on — narrow it to the
        // three allowed tags. Reasoning + concerns are free-form by design.
        match self.verdict.as_str() {
            "approve" | "revise" | "block" => {}
            other => {
                return Err(ValidationError::new(format!(
                    "verdict must be approve|revise|block, got {other:?}"
                )))
            }
        }
        if self.reasoning.trim().is_empty() {
            return Err(ValidationError::new("reasoning cannot be empty"));
        }
        Ok(())
    }
}

/// Subagent reviews a gap's spec and returns a verdict.
///
/// Use case: opus-curator (META-046) wants a second-opinion review before
/// promoting a gap to P0; spawn a Sonnet under this contract so the verdict +
/// reasoning come back typed instead of as text the curator has to re-parse.
pub struct GapReviewContract;

impl HandoffContract for GapReviewContract {
    type Input = GapReviewInput;
    type Output = GapReviewOutput;

    fn name() -> &'static str {
        "GapReviewContract"
    }

    fn prompt(input: &Self::Input) -> String {
        format!(
            r#"You are reviewing gap {gap_id} for the Chump fleet.

Context the parent has already gathered:
{context}

Decide one of:
  - "approve"  — the gap is ready to pick up as-is
  - "revise"   — the gap needs AC / scope / priority tweaks first (list them)
  - "block"    — the gap should not be picked up at all (explain why)

Emit a single fenced JSON block of this exact shape (no other JSON, no extra commentary outside the block):

```json
{{
  "verdict": "approve" | "revise" | "block",
  "reasoning": "<2-4 sentence justification>",
  "blocking_concerns": ["<concern 1>", "<concern 2>", ...]
}}
```

Use an empty `blocking_concerns` array for `approve`. Be specific in `reasoning` — what about this gap drove the verdict?
"#,
            gap_id = input.gap_id,
            context = input.context
        )
    }

    fn model_tier() -> ModelTier {
        // Review = judgement work; Sonnet is the right default. Opus reserved
        // for cases Sonnet routinely waffles on (e.g. cross-pillar trade-off).
        ModelTier::Sonnet
    }
}

// ── (b) CodeFixContract ───────────────────────────────────────────────────

/// Input: where the symptom is and what it looks like.
#[derive(Debug, Clone, Serialize)]
pub struct CodeFixInput {
    /// Repository-relative path to the file the parent suspects.
    pub file_path: String,
    /// Description of the symptom (test failure text, panic, lint output).
    pub symptom: String,
}

/// Output: the unified diff the parent should apply + the test it added/changed.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct CodeFixOutput {
    /// Unified diff in `diff --git a/X b/X` form, ready to feed `git apply`.
    pub unified_diff: String,
    /// Files the diff actually touches (parent uses this to gate lease overlap).
    pub files_touched: Vec<String>,
    /// Repository-relative path to the test file the subagent added/changed.
    pub tests_added: Vec<String>,
}

impl Validate for CodeFixOutput {
    fn validate(&self) -> Result<(), ValidationError> {
        let head = self.unified_diff.trim_start();
        if !head.starts_with("diff --git") && !head.starts_with("---") {
            return Err(ValidationError::new(
                "unified_diff must start with `diff --git` or `---` header",
            ));
        }
        if self.files_touched.is_empty() {
            return Err(ValidationError::new("files_touched cannot be empty"));
        }
        // Tests-added may be empty (some fixes don't need a new test — e.g. a
        // typo in a string literal). Parent applies its own policy on top.
        Ok(())
    }
}

/// Subagent diagnoses a symptom + emits a unified diff.
///
/// Use case: pr-rescue v2 (INFRA-1714 follow-up) when classifier hits an
/// `Unknown` pattern — spawn a Sonnet under this contract for a one-shot
/// fix attempt. Output is a diff the parent can apply via `git apply` after
/// running the listed files through the lease-overlap check.
pub struct CodeFixContract;

impl HandoffContract for CodeFixContract {
    type Input = CodeFixInput;
    type Output = CodeFixOutput;

    fn name() -> &'static str {
        "CodeFixContract"
    }

    fn prompt(input: &Self::Input) -> String {
        format!(
            r#"You are fixing a code symptom in the Chump repo.

File suspected: {file_path}
Symptom:
{symptom}

Investigate the file (read it, look at related modules), then emit a single fenced JSON block with this exact shape (no other JSON, no extra commentary outside the block):

```json
{{
  "unified_diff": "diff --git a/path b/path\n--- a/path\n+++ b/path\n@@ ... @@\n...",
  "files_touched": ["path/relative/to/repo/root", ...],
  "tests_added": ["path/to/test/file", ...]
}}
```

Rules:
- `unified_diff` MUST start with `diff --git` (or `---` for a pure file-add) and be appliable via `git apply`.
- `files_touched` MUST list every file the diff modifies — the parent uses this to check for lease collisions before applying.
- `tests_added` MAY be empty if the fix is too small to need a new test, but prefer adding one.
"#,
            file_path = input.file_path,
            symptom = input.symptom
        )
    }

    fn model_tier() -> ModelTier {
        ModelTier::Sonnet
    }
}

// ── (c) DecomposeContract ─────────────────────────────────────────────────

/// Input: gap ID + the AST-derived map of relevant files (from INFRA-1719).
///
/// `ast_map` is a JSON blob the parent assembles; the subagent is *not*
/// expected to re-traverse the codebase, only to reason over the supplied map.
#[derive(Debug, Clone, Serialize)]
pub struct DecomposeInput {
    /// Gap identifier (e.g. `INFRA-1720`).
    pub gap_id: String,
    /// JSON serialised AST map (output of INFRA-1719's crawler).
    pub ast_map_json: String,
}

/// A single sub-gap proposed by the decomposer.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct SubGap {
    /// One-paragraph description suitable for a gap description field.
    pub description: String,
    /// Repo-relative paths the sub-gap is expected to touch (lease scope).
    pub files_to_modify: Vec<String>,
    /// Branch name in `chump/<id>-claim` style (decomposer can suggest).
    pub branch_name: String,
    /// Command the parent should run to verify the sub-gap's AC.
    pub test_command: String,
    /// Other sub-gap branch names this one depends on (topological order).
    pub depends_on: Vec<String>,
}

/// Output: the proposed sub-gap list, plus optional context for the parent.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct DecomposeOutput {
    /// Proposed sub-gaps in topological order.
    pub sub_gaps: Vec<SubGap>,
    /// Decomposer's reasoning (why this split).
    pub reasoning: String,
}

impl Validate for DecomposeOutput {
    fn validate(&self) -> Result<(), ValidationError> {
        if self.sub_gaps.is_empty() {
            return Err(ValidationError::new("sub_gaps cannot be empty"));
        }
        for (i, sg) in self.sub_gaps.iter().enumerate() {
            if sg.description.trim().is_empty() {
                return Err(ValidationError::new(format!(
                    "sub_gaps[{i}].description cannot be empty"
                )));
            }
            if sg.files_to_modify.is_empty() {
                return Err(ValidationError::new(format!(
                    "sub_gaps[{i}].files_to_modify cannot be empty"
                )));
            }
            if !sg.branch_name.starts_with("chump/") {
                return Err(ValidationError::new(format!(
                    "sub_gaps[{i}].branch_name must start with `chump/`"
                )));
            }
            if sg.test_command.trim().is_empty() {
                return Err(ValidationError::new(format!(
                    "sub_gaps[{i}].test_command cannot be empty"
                )));
            }
        }
        Ok(())
    }
}

/// Subagent decomposes a gap into sub-gaps using an AST map as context.
///
/// Use case: `chump gap decompose <ID>` (current markdown-prompt path) is the
/// archetype for this contract — typed output means the CLI can write the
/// sub-gaps directly to state.db instead of regex-parsing free-form text.
pub struct DecomposeContract;

impl HandoffContract for DecomposeContract {
    type Input = DecomposeInput;
    type Output = DecomposeOutput;

    fn name() -> &'static str {
        "DecomposeContract"
    }

    fn prompt(input: &Self::Input) -> String {
        format!(
            r#"You are decomposing gap {gap_id} into sub-gaps.

AST map (JSON; do not re-traverse the codebase, work from this):
```json
{ast}
```

Propose sub-gaps in topological order (depends_on must reference earlier branch_names). Emit a single fenced JSON block with this exact shape (no other JSON, no extra commentary outside the block):

```json
{{
  "sub_gaps": [
    {{
      "description": "...",
      "files_to_modify": ["src/foo.rs", ...],
      "branch_name": "chump/<short-id>-claim",
      "test_command": "cargo test --bin chump my_test_name",
      "depends_on": []
    }},
    ...
  ],
  "reasoning": "Why this particular split"
}}
```

Rules:
- `sub_gaps` MUST be non-empty.
- Every `files_to_modify` entry must be reachable from the AST map (don't invent paths).
- `branch_name` MUST start with `chump/`.
- `test_command` MUST be the exact command the parent will run to verify AC.
- `depends_on` must reference earlier `branch_name` values (no forward refs, no cycles).
"#,
            gap_id = input.gap_id,
            ast = input.ast_map_json
        )
    }

    fn model_tier() -> ModelTier {
        // Decomposition is the original "Opus decides, Sonnet executes" job.
        // Pin to Opus by default; callers can override if budget tight.
        ModelTier::Opus
    }
}

// ── (d) ExternalRepoContract ──────────────────────────────────────────────

/// Input: what repo to touch, where it is locally, and what change to make.
#[derive(Debug, Clone, Serialize)]
pub struct ExternalRepoInput {
    /// External repo in `owner/repo` form (e.g. `ehippy/derelict`).
    pub external_repo: String,
    /// Absolute path to a local clone of the external repo.
    pub repo_local_path: String,
    /// Description of the change to ship (gap description style).
    pub proposed_gap_description: String,
    /// Base branch to open the PR against (e.g. `main`).
    pub base_branch: String,
    /// Fork owner for fork-PR mode (e.g. `repairman29`). `None` means
    /// direct-push to a branch on the upstream (only valid if the subagent
    /// has push rights).
    pub fork_owner: Option<String>,
}

/// Output: evidence the change was shipped — PR URL + supporting metadata.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ExternalRepoOutput {
    /// Full GitHub PR URL, e.g. `https://github.com/ehippy/derelict/pull/42`.
    pub pr_url: String,
    /// Head branch name the PR was opened from.
    pub head_ref: String,
    /// Base branch the PR targets.
    pub base_ref: String,
    /// Repo-relative paths the change touches (used for lease-overlap audit).
    pub files_touched: Vec<String>,
    /// Full commit SHA of the head commit.
    pub commit_sha: String,
    /// Free-form notes on what was done (for operator review).
    pub notes: String,
}

/// Returns `true` if `url` matches `https://github.com/<owner>/<repo>/pull/<N>`
/// where `<N>` is one or more digits. No external crate needed.
fn is_valid_github_pr_url(url: &str) -> bool {
    // Must start with the canonical prefix.
    let Some(rest) = url.strip_prefix("https://github.com/") else {
        return false;
    };
    // Expect <owner>/<repo>/pull/<N>
    let parts: Vec<&str> = rest.splitn(4, '/').collect();
    if parts.len() != 4 {
        return false;
    }
    let (owner, repo, pull_literal, pr_number) = (parts[0], parts[1], parts[2], parts[3]);
    !owner.is_empty()
        && !repo.is_empty()
        && pull_literal == "pull"
        && !pr_number.is_empty()
        && pr_number.chars().all(|c| c.is_ascii_digit())
}

impl Validate for ExternalRepoOutput {
    fn validate(&self) -> Result<(), ValidationError> {
        if self.pr_url.trim().is_empty() {
            return Err(ValidationError::new("pr_url cannot be empty"));
        }
        // Require a well-formed GitHub PR URL: https://github.com/<owner>/<repo>/pull/<N>
        if !is_valid_github_pr_url(self.pr_url.trim()) {
            return Err(ValidationError::new(
                "pr_url must match https://github.com/<owner>/<repo>/pull/<N>",
            ));
        }
        if self.files_touched.is_empty() {
            return Err(ValidationError::new("files_touched cannot be empty"));
        }
        if self.commit_sha.trim().is_empty() {
            return Err(ValidationError::new("commit_sha cannot be empty"));
        }
        Ok(())
    }
}

/// Subagent ships a change into an external repo and opens a PR.
///
/// Use case: META-123 flow — Scout proposes, external-collab reviews, Target
/// picks, then this contract dispatches a Sonnet worker that clones (or uses an
/// existing clone at `repo_local_path`), branches, makes the change described
/// in `proposed_gap_description`, commits, pushes, and opens the PR. The typed
/// output gives the parent a PR URL it can track without regex-parsing free text.
pub struct ExternalRepoContract;

impl HandoffContract for ExternalRepoContract {
    type Input = ExternalRepoInput;
    type Output = ExternalRepoOutput;

    fn name() -> &'static str {
        "ExternalRepoContract"
    }

    fn prompt(input: &Self::Input) -> String {
        let fork_line = match &input.fork_owner {
            Some(owner) => format!(
                "Fork owner: {owner} (open the PR from a fork, not directly on the upstream)"
            ),
            None => "Fork owner: none (push directly to a branch on the upstream)".to_string(),
        };
        format!(
            r#"You are shipping a change into an external repository on behalf of the Chump fleet.

External repo   : {external_repo}
Local clone path: {repo_local_path}
Base branch     : {base_branch}
{fork_line}

Proposed change:
{proposed_gap_description}

Steps:
1. `cd {repo_local_path}`; confirm the clone is on a clean checkout of `{base_branch}`.
2. Create a short descriptive branch name and check it out.
3. Make the minimal change that satisfies the proposed description.
4. `git add` + `git commit` (conventional-commit style message).
5. Push the branch and open a PR against `{base_branch}` on `{external_repo}`.
6. Emit a single fenced JSON block with the exact shape below — no other JSON, no extra commentary outside the block.

```json
{{
  "pr_url": "https://github.com/{external_repo}/pull/<N>",
  "head_ref": "<branch-you-pushed>",
  "base_ref": "{base_branch}",
  "files_touched": ["<repo-relative path>", ...],
  "commit_sha": "<full 40-char SHA>",
  "notes": "<what you did and why>"
}}
```

Rules:
- `pr_url` MUST be the real URL returned by `gh pr create` — do not fabricate it.
- `files_touched` MUST list every file the diff modifies.
- `commit_sha` MUST be the full 40-character SHA of the head commit (`git rev-parse HEAD`).
- Keep `notes` factual: what changed and why, no filler.
"#,
            external_repo = input.external_repo,
            repo_local_path = input.repo_local_path,
            base_branch = input.base_branch,
            proposed_gap_description = input.proposed_gap_description,
            fork_line = fork_line,
        )
    }

    fn model_tier() -> ModelTier {
        // Execution work — Sonnet is the standard tier for workers that ship code.
        ModelTier::Sonnet
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // GapReviewOutput validation ───────────────────────────────────────────

    #[test]
    fn gap_review_accepts_valid_verdict() {
        let v = GapReviewOutput {
            verdict: "approve".into(),
            reasoning: "scope is tight, AC concrete".into(),
            blocking_concerns: vec![],
        };
        assert!(v.validate().is_ok());
    }

    #[test]
    fn gap_review_rejects_unknown_verdict() {
        let v = GapReviewOutput {
            verdict: "maybe".into(),
            reasoning: "x".into(),
            blocking_concerns: vec![],
        };
        let err = v.validate().unwrap_err();
        assert!(err.message().contains("approve|revise|block"));
    }

    #[test]
    fn gap_review_rejects_empty_reasoning() {
        let v = GapReviewOutput {
            verdict: "approve".into(),
            reasoning: "   ".into(),
            blocking_concerns: vec![],
        };
        assert!(v.validate().is_err());
    }

    // CodeFixOutput validation ──────────────────────────────────────────────

    #[test]
    fn code_fix_accepts_proper_diff() {
        let v = CodeFixOutput {
            unified_diff: "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n".into(),
            files_touched: vec!["x".into()],
            tests_added: vec!["x_test.rs".into()],
        };
        assert!(v.validate().is_ok());
    }

    #[test]
    fn code_fix_rejects_non_diff() {
        let v = CodeFixOutput {
            unified_diff: "here is what i would do".into(),
            files_touched: vec!["x".into()],
            tests_added: vec![],
        };
        assert!(v.validate().is_err());
    }

    #[test]
    fn code_fix_rejects_empty_files_touched() {
        let v = CodeFixOutput {
            unified_diff: "diff --git a/x b/x\n".into(),
            files_touched: vec![],
            tests_added: vec![],
        };
        assert!(v.validate().is_err());
    }

    // DecomposeOutput validation ────────────────────────────────────────────

    fn good_sub_gap() -> SubGap {
        SubGap {
            description: "Add foo module".into(),
            files_to_modify: vec!["src/foo.rs".into()],
            branch_name: "chump/foo-claim".into(),
            test_command: "cargo test foo".into(),
            depends_on: vec![],
        }
    }

    #[test]
    fn decompose_accepts_well_formed_sub_gap() {
        let v = DecomposeOutput {
            sub_gaps: vec![good_sub_gap()],
            reasoning: "single-file scope".into(),
        };
        assert!(v.validate().is_ok());
    }

    #[test]
    fn decompose_rejects_bad_branch_name() {
        let mut sg = good_sub_gap();
        sg.branch_name = "feat/foo".into();
        let v = DecomposeOutput {
            sub_gaps: vec![sg],
            reasoning: "x".into(),
        };
        let err = v.validate().unwrap_err();
        assert!(err.message().contains("chump/"));
    }

    #[test]
    fn decompose_rejects_empty_files_to_modify() {
        let mut sg = good_sub_gap();
        sg.files_to_modify = vec![];
        let v = DecomposeOutput {
            sub_gaps: vec![sg],
            reasoning: "x".into(),
        };
        assert!(v.validate().is_err());
    }

    #[test]
    fn decompose_rejects_empty_sub_gaps() {
        let v = DecomposeOutput {
            sub_gaps: vec![],
            reasoning: "x".into(),
        };
        assert!(v.validate().is_err());
    }

    // Smoke test: prompts render without panicking and include the inputs.
    #[test]
    fn prompts_include_inputs() {
        let p = GapReviewContract::prompt(&GapReviewInput {
            gap_id: "INFRA-1720".into(),
            context: "xyz".into(),
        });
        assert!(p.contains("INFRA-1720"));
        assert!(p.contains("xyz"));

        let p = CodeFixContract::prompt(&CodeFixInput {
            file_path: "src/foo.rs".into(),
            symptom: "panicked at X".into(),
        });
        assert!(p.contains("src/foo.rs"));
        assert!(p.contains("panicked at X"));

        let p = DecomposeContract::prompt(&DecomposeInput {
            gap_id: "INFRA-1720".into(),
            ast_map_json: "{}".into(),
        });
        assert!(p.contains("INFRA-1720"));
    }

    // Default tier selections (regression: if someone flips Decompose to
    // Sonnet by accident, the cost picture changes).
    #[test]
    fn tiers_are_intentional() {
        assert_eq!(GapReviewContract::model_tier(), ModelTier::Sonnet);
        assert_eq!(CodeFixContract::model_tier(), ModelTier::Sonnet);
        assert_eq!(DecomposeContract::model_tier(), ModelTier::Opus);
        assert_eq!(ExternalRepoContract::model_tier(), ModelTier::Sonnet);
    }

    // ExternalRepoOutput validation ───────────────────────────────────────────

    fn good_external_output() -> ExternalRepoOutput {
        ExternalRepoOutput {
            pr_url: "https://github.com/ehippy/derelict/pull/42".into(),
            head_ref: "chump/fix-foo".into(),
            base_ref: "main".into(),
            files_touched: vec!["src/main.rs".into()],
            commit_sha: "abc123def456abc123def456abc123def456abc1".into(),
            notes: "Fixed the thing".into(),
        }
    }

    #[test]
    fn external_repo_accepts_valid_output() {
        assert!(good_external_output().validate().is_ok());
    }

    #[test]
    fn external_repo_rejects_bad_pr_url() {
        let mut out = good_external_output();
        out.pr_url = "https://github.com/ehippy/derelict/issues/42".into();
        let err = out.validate().unwrap_err();
        assert!(err.message().contains("pr_url must match"));

        let mut out2 = good_external_output();
        out2.pr_url = "not-a-url".into();
        assert!(out2.validate().is_err());

        let mut out3 = good_external_output();
        out3.pr_url = "https://github.com/ehippy/derelict/pull/abc".into();
        assert!(out3.validate().is_err());
    }

    #[test]
    fn external_repo_rejects_empty_files_touched() {
        let mut out = good_external_output();
        out.files_touched = vec![];
        let err = out.validate().unwrap_err();
        assert!(err.message().contains("files_touched cannot be empty"));
    }

    #[test]
    fn external_repo_rejects_empty_commit_sha() {
        let mut out = good_external_output();
        out.commit_sha = "".into();
        let err = out.validate().unwrap_err();
        assert!(err.message().contains("commit_sha cannot be empty"));
    }

    #[test]
    fn external_repo_prompt_includes_inputs() {
        let input = ExternalRepoInput {
            external_repo: "ehippy/derelict".into(),
            repo_local_path: "/tmp/derelict".into(),
            proposed_gap_description: "Add retry logic to fetch".into(),
            base_branch: "main".into(),
            fork_owner: Some("repairman29".into()),
        };
        let p = ExternalRepoContract::prompt(&input);
        assert!(p.contains("ehippy/derelict"));
        assert!(p.contains("/tmp/derelict"));
        assert!(p.contains("Add retry logic to fetch"));
        assert!(p.contains("main"));
        assert!(p.contains("repairman29"));
    }
}
