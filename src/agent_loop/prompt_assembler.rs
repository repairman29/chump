use crate::perception::PerceivedInput;
use crate::task_db;

pub struct PromptAssembler {
    pub base_system_prompt: Option<String>,
}

impl PromptAssembler {
    pub fn assemble(&self, perception: &PerceivedInput) -> Option<String> {
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
}
