use crate::perception::PerceivedInput;
use crate::reflection_db;
use crate::task_db;

/// How many recent improvement targets to surface in the "Lessons" block.
/// Cap is intentionally small — reflections are advisory context, not the main
/// instruction. More than ~5 risks crowding out the actual task prompt.
const LESSONS_LIMIT: usize = 5;

pub struct PromptAssembler {
    pub base_system_prompt: Option<String>,
}

impl PromptAssembler {
    /// Backwards-compatible wrapper: assemble with no explicit tool hint.
    /// Falls through to perception entities for lesson scope filtering.
    pub fn assemble(&self, perception: &PerceivedInput) -> Option<String> {
        self.assemble_with_hint(perception, None)
    }

    /// Assemble with an optional `tool_hint` that overrides perception entities
    /// when filtering reflection lessons (COG-009). When the caller knows
    /// which tool just failed (or which tool is about to be called), pass its
    /// name here so the lessons block surfaces directives scoped to that tool.
    /// Falls back to perception entities when `None`.
    ///
    /// Wiring: orchestrator currently passes `None` — wiring the actual
    /// "last failed tool" signal from BatchOutcome is tracked as COG-009b.
    pub fn assemble_with_hint(
        &self,
        perception: &PerceivedInput,
        tool_hint: Option<&str>,
    ) -> Option<String> {
        let mut effective_system = self.base_system_prompt.clone();

        // Inject task planner block if available
        if task_db::task_available() {
            if let Ok(Some(block)) = task_db::planner_active_prompt_block() {
                effective_system = match effective_system {
                    Some(s) if !s.trim().is_empty() => Some(format!("{}\n\n{}", s, block)),
                    _ => Some(block),
                };
            }
        }

        // COG-007 / COG-009 / COG-011: inject reflection learnings. Gated on
        // (a) the DB being reachable AND (b) the COG-016 unified gate
        // [`lessons_enabled_for_model`] — which combines the legacy
        // CHUMP_REFLECTION_INJECTION kill-switch with the COG-016
        // model-tier check (default: only inject on Frontier-class agents
        // per the n=100 sweep evidence; controllable via
        // CHUMP_LESSONS_MIN_TIER=frontier|capable|small|none).
        // Scope filter priority: explicit tool_hint > first detected
        // perception entity > None.
        let agent_model = reflection_db::current_agent_model();
        if reflection_db::reflection_available()
            && reflection_db::lessons_enabled_for_model(&agent_model)
        {
            let scope_hint: Option<&str> =
                tool_hint.or_else(|| perception.detected_entities.first().map(|s| s.as_str()));
            if let Ok(targets) =
                reflection_db::load_recent_high_priority_targets(LESSONS_LIMIT, scope_hint)
            {
                let block = reflection_db::format_lessons_block(&targets);
                if !block.is_empty() {
                    effective_system = match effective_system {
                        Some(s) if !s.trim().is_empty() => Some(format!("{}\n\n{}", s, block)),
                        _ => Some(block),
                    };
                }
            }
        }

        // COG-015: inject entity-keyed persisted blackboard facts.
        // Gated on CHUMP_ENTITY_PREFETCH (default on); no-ops when entities
        // list is empty or the DB has no matching rows.
        if crate::blackboard::entity_prefetch_enabled() && !perception.detected_entities.is_empty()
        {
            if let Some(block) = crate::blackboard::query_persist_for_entities(
                &perception.detected_entities,
                crate::blackboard::ENTITY_PREFETCH_MAX_ENTRIES,
                crate::blackboard::ENTITY_PREFETCH_MAX_CHARS,
            ) {
                effective_system = match effective_system {
                    Some(s) if !s.trim().is_empty() => {
                        Some(format!("{}\n\n{}", s, block.trim_end()))
                    }
                    _ => Some(block.trim_end().to_string()),
                };
            }
        }

        // Inject perception summary into system prompt when non-trivial
        let perception_ctx = crate::perception::context_summary(perception);
        if !perception_ctx.is_empty() {
            effective_system = match effective_system {
                Some(s) => Some(format!("{}\n\n[Perception] {}", s, perception_ctx)),
                None => Some(format!("[Perception] {}", perception_ctx)),
            };
        }

        effective_system
    }

    pub fn assemble_no_tools_guard(&self, effective_system: Option<String>) -> Option<String> {
        let guard = "\n\nCRITICAL: No tools available right now. Rules:\n\
            1. NEVER say \"Creating...\", \"Saved as...\", \"Checking...\", or claim you did something.\n\
            2. NEVER pretend to create files, run commands, list tasks, or take actions.\n\
            3. Just chat naturally. Answer questions from your knowledge.\n\
            4. If they want you to DO something (create, check, list, run), say: \
               \"Sure, let me do that for you\" — the system will give me tools on the next turn.\n\
            VIOLATION = saying you did something you didn't. That is lying. Don't lie.";

        match effective_system {
            Some(s) => Some(format!("{}{}", s, guard)),
            None => Some(guard.to_string()),
        }
    }
}

#[cfg(test)]
mod tests {
    //! Tests for the no-tools-guard assembly. The full `assemble()` method
    //! pulls in task_db + perception state which are global and harder to
    //! isolate; the guard wrapper is pure and easy to pin.

    use super::PromptAssembler;

    #[test]
    fn no_tools_guard_appends_to_existing_prompt() {
        let pa = PromptAssembler {
            base_system_prompt: Some("base prompt".to_string()),
        };
        let out = pa
            .assemble_no_tools_guard(Some("existing system".to_string()))
            .expect("guarded prompt");
        assert!(out.starts_with("existing system"));
        assert!(out.contains("CRITICAL: No tools available"));
        assert!(out.contains("VIOLATION = saying you did something"));
    }

    #[test]
    fn no_tools_guard_creates_prompt_when_none() {
        let pa = PromptAssembler {
            base_system_prompt: None,
        };
        let out = pa.assemble_no_tools_guard(None).expect("guarded prompt");
        assert!(out.starts_with("\n\nCRITICAL"));
        assert!(out.contains("CRITICAL: No tools available"));
    }

    #[test]
    fn no_tools_guard_preserves_content_verbatim() {
        let pa = PromptAssembler {
            base_system_prompt: None,
        };
        let original = "preserve me exactly".to_string();
        let out = pa.assemble_no_tools_guard(Some(original.clone())).unwrap();
        // The guard MUST come after the original, never modify it.
        assert!(out.starts_with("preserve me exactly"));
    }

    #[test]
    fn no_tools_guard_includes_anti_hallucination_examples() {
        let pa = PromptAssembler {
            base_system_prompt: None,
        };
        let out = pa.assemble_no_tools_guard(None).unwrap();
        // The guard exists specifically to stop the model from claiming it
        // did things. These exemplar phrases must be present so the model
        // has concrete things to avoid.
        assert!(out.contains("Creating..."));
        assert!(out.contains("Saved as..."));
        assert!(out.contains("Checking..."));
    }

    // ── COG-009: explicit tool_hint precedence ─────────────────────────
    //
    // These check the priority ordering at the API boundary without standing
    // up the reflection DB. They deliberately don't assert on the lessons
    // *content* — that's covered in `reflection_db::tests`. What we want
    // here is: assemble_with_hint(_, Some("X")) must call the underlying
    // load with scope_filter == Some("X") regardless of perception entities.
    // We can't observe that call directly without DI, but we CAN observe that
    // the call doesn't panic and returns Some/None matching base_system_prompt
    // when the reflection DB is unavailable in the test process.

    use crate::perception::{PerceivedInput, TaskType};

    fn dummy_perception(entities: Vec<&str>) -> PerceivedInput {
        PerceivedInput {
            raw_text: "test".to_string(),
            likely_needs_tools: false,
            detected_entities: entities.iter().map(|s| s.to_string()).collect(),
            detected_constraints: vec![],
            ambiguity_level: 0.0,
            risk_indicators: vec![],
            question_count: 0,
            task_type: TaskType::Question,
        }
    }

    #[test]
    fn assemble_with_hint_preserves_base_when_no_db() {
        // No reflection DB available in unit-test process → no lessons block.
        // Output should equal base_system_prompt (modulo perception summary,
        // which is empty for our trivial PerceivedInput).
        let pa = PromptAssembler {
            base_system_prompt: Some("BASE".to_string()),
        };
        let out = pa
            .assemble_with_hint(&dummy_perception(vec!["patch_file"]), Some("git_commit"))
            .expect("base preserved");
        // Either pure BASE (no DB) or BASE + lessons block. Never replaces BASE.
        assert!(out.starts_with("BASE"));
    }

    // Note: removed `assemble_falls_back_to_assemble_with_hint_none` because
    // it was racy in the full test suite — both `assemble()` and
    // `assemble_with_hint(p, None)` query the shared reflection_db, and any
    // other test inserting between the two calls makes the assert_eq fail.
    // The contract "assemble() == assemble_with_hint(p, None)" is verified
    // by inspection: assemble's body is literally `self.assemble_with_hint(p, None)`.
}
