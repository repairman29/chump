//! PRODUCT-004: FTUE completion tool.
//!
//! Chump calls this once at the end of the onboarding conversation to commit
//! all five answers to the user profile. After this call, profile_complete()
//! returns true and the onboarding block disappears from context.

use anyhow::{anyhow, Result};
use async_trait::async_trait;
use axonerai::tool::Tool;
use serde_json::{json, Value};

pub struct CompleteOnboardingTool;

#[async_trait]
impl Tool for CompleteOnboardingTool {
    fn name(&self) -> String {
        "complete_onboarding".to_string()
    }

    fn description(&self) -> String {
        "Save the user's onboarding answers and mark setup complete. Call ONLY after collecting all five answers conversationally. This is a one-time call — it permanently completes onboarding.".to_string()
    }

    fn input_schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "User's name (as they gave it)"
                },
                "role": {
                    "type": "string",
                    "description": "What kind of work they do (free text, e.g. 'founder, software developer')"
                },
                "domains": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Areas of expertise extracted from their role answer (e.g. ['Rust', 'AI', 'product'])"
                },
                "current_projects": {
                    "type": "array",
                    "items": { "type": "string" },
                    "description": "Active projects they named"
                },
                "this_week_goal": {
                    "type": "string",
                    "description": "What they most want to accomplish this week"
                },
                "working_style": {
                    "type": "string",
                    "enum": ["frequent", "async", "autonomous"],
                    "description": "How often they want Chump to check in: frequent, async, or autonomous"
                },
                "timezone": {
                    "type": "string",
                    "description": "Their timezone if mentioned (e.g. 'America/Denver'). Default 'UTC'."
                }
            },
            "required": ["name", "role", "domains", "current_projects", "this_week_goal", "working_style"]
        })
    }

    async fn execute(&self, input: Value) -> Result<String> {
        if let Err(e) = crate::limits::check_tool_input_len(&input) {
            return Err(anyhow!("{}", e));
        }

        let name = input
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim();
        let role = input
            .get("role")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim();
        let domains: Vec<String> = input
            .get("domains")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str())
                    .map(|s| s.to_string())
                    .collect()
            })
            .unwrap_or_default();
        let projects: Vec<String> = input
            .get("current_projects")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str())
                    .map(|s| s.to_string())
                    .collect()
            })
            .unwrap_or_default();
        let goal = input
            .get("this_week_goal")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim();
        let working_style = input
            .get("working_style")
            .and_then(|v| v.as_str())
            .unwrap_or("async")
            .trim();
        let timezone = input
            .get("timezone")
            .and_then(|v| v.as_str())
            .unwrap_or("UTC")
            .trim();

        if name.is_empty() || role.is_empty() {
            return Err(anyhow!("name and role are required"));
        }

        // Layer 1: identity
        crate::user_profile::save_identity(name, role, &domains, timezone)?;

        // Layer 2: context — one row per project + the week goal
        for project in &projects {
            let key = format!(
                "project:{}",
                project
                    .to_lowercase()
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join("-")
            );
            crate::user_profile::update_context(&key, project, "project")?;
        }
        if !goal.is_empty() {
            crate::user_profile::update_context("goal:this-week", goal, "goal")?;
        }

        // Behavioral regime
        let checkin: crate::user_profile::CheckinFrequency =
            working_style.parse().unwrap_or_default();
        crate::user_profile::save_behavior(
            checkin,
            crate::user_profile::RiskTolerance::Medium,
            "concise",
            &[],
        )?;

        // Seed PrecisionController from the new regime
        if let Some(ctx) = crate::user_profile::user_context() {
            crate::precision_controller::seed_from_behavior_regime(&ctx.regime);
        }

        // Mark complete — FTUE block disappears from next context assembly
        crate::user_profile::mark_onboarding_complete()?;

        let first_name = name.split_whitespace().next().unwrap_or(name);
        Ok(format!(
            "Onboarding complete. Welcome, {first_name}. I've saved your profile and I'm ready to get to work."
        ))
    }
}

pub fn onboarding_complete() -> bool {
    crate::user_profile::profile_complete()
}
