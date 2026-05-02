pub mod context;
pub mod iteration_controller;
pub mod orchestrator;
pub mod perception_layer;
pub mod prompt_assembler;
pub mod state;
pub mod tool_runner;
pub mod types;

pub use context::{phase_timing_enabled, AgentLoopContext, PhaseTimings};
pub use iteration_controller::IterationController;
pub use orchestrator::ChumpAgent;
pub use perception_layer::PerceptionLayer;
pub use prompt_assembler::PromptAssembler;
pub use tool_runner::ToolRunner;
pub use types::*;

// Re-exports for callers that previously imported these from `agent_loop`
// before the module split. Keeps `crate::agent_loop::AgentEvent` working
// without forcing every file in this module to switch to `stream_events`.
pub use crate::stream_events::{AgentEvent, EventSender};
