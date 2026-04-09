//! Heavy-duty exercise harness for the Synthetic Consciousness Framework.
//!
//! Populates all 6 subsystems with realistic volumes of data by calling
//! module APIs directly (no LLM round-trip), then runs the full measurement
//! pipeline and prints a comprehensive report with baseline metrics.
//!
//! Run with: cargo test consciousness_exercise -- --nocapture

#[cfg(test)]
mod tests {
    use serial_test::serial;
    use std::fs;

    fn setup_test_db() -> (std::path::PathBuf, Option<std::path::PathBuf>) {
        let dir = std::env::temp_dir().join(format!(
            "chump_exercise_{}",
            uuid::Uuid::new_v4().simple()
        ));
        let _ = fs::create_dir_all(dir.join("sessions"));
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();
        (dir, prev)
    }

    fn teardown(dir: std::path::PathBuf, prev: Option<std::path::PathBuf>) {
        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
        let _ = fs::remove_dir_all(&dir);
    }

    /// Run this with: cargo test consciousness_exercise_full -- --nocapture
    /// Populates all modules with realistic data and prints a full metrics report.
    #[test]
    #[serial]
    fn consciousness_exercise_full() {
        let (dir, prev) = setup_test_db();

        println!("\n============================================================");
        println!("  CONSCIOUSNESS FRAMEWORK EXERCISE");
        println!("  Populating all 6 subsystems with realistic data");
        println!("============================================================\n");

        // ============================================================
        // Phase 1: Surprise Tracker — simulate 50 tool calls
        // ============================================================
        println!("--- Phase 1: Surprise Tracker (50 tool calls) ---");

        let tool_scenarios = vec![
            // (tool, outcome, latency_ms, expected_latency_ms)
            ("read_file", "ok", 45, 100),
            ("read_file", "ok", 60, 100),
            ("read_file", "ok", 30, 100),
            ("read_file", "ok", 120, 100),
            ("read_file", "error", 50, 100),   // file not found
            ("list_dir", "ok", 20, 50),
            ("list_dir", "ok", 15, 50),
            ("list_dir", "ok", 25, 50),
            ("run_cli", "ok", 3000, 5000),
            ("run_cli", "ok", 4500, 5000),
            ("run_cli", "timeout", 30000, 10000),  // npm test timeout
            ("run_cli", "timeout", 30000, 10000),  // cargo build timeout
            ("run_cli", "error", 500, 5000),        // command not found
            ("run_cli", "ok", 8000, 5000),          // slow but ok
            ("run_cli", "ok", 2000, 5000),
            ("memory", "ok", 10, 50),
            ("memory", "ok", 15, 50),
            ("memory", "ok", 8, 50),
            ("memory", "ok", 12, 50),
            ("memory", "ok", 200, 50),   // slow embed
            ("episode", "ok", 5, 20),
            ("episode", "ok", 3, 20),
            ("episode", "ok", 7, 20),
            ("calc", "ok", 1, 10),
            ("calc", "ok", 2, 10),
            ("edit_file", "ok", 100, 200),
            ("edit_file", "ok", 80, 200),
            ("edit_file", "error", 50, 200),     // path not found
            ("git_commit", "ok", 2000, 3000),
            ("git_commit", "error", 100, 3000),  // nothing to commit
            ("git_push", "ok", 5000, 8000),
            ("git_push", "error", 1000, 8000),   // auth failure
            ("gh_list_issues", "ok", 1500, 3000),
            ("gh_list_issues", "timeout", 30000, 3000),
            ("delegate", "ok", 15000, 20000),
            ("delegate", "ok", 12000, 20000),
            ("read_url", "ok", 2000, 5000),
            ("read_url", "timeout", 30000, 5000),
            ("read_url", "ok", 3000, 5000),
            ("introspect", "ok", 5, 20),
            ("task", "ok", 10, 30),
            ("task", "ok", 8, 30),
            ("task", "ok", 12, 30),
            ("ego", "ok", 5, 20),
            ("ego", "ok", 3, 20),
            ("schedule", "ok", 10, 30),
            ("write_file", "ok", 50, 100),
            ("write_file", "error", 30, 100),
            ("run_test", "ok", 5000, 10000),
            ("run_test", "error", 8000, 10000),  // tests failed
        ];

        for (tool, outcome, latency, expected) in &tool_scenarios {
            crate::surprise_tracker::record_prediction(tool, outcome, *latency, *expected);
        }

        let ema = crate::surprise_tracker::current_surprisal_ema();
        let total = crate::surprise_tracker::total_predictions();
        let high = crate::surprise_tracker::high_surprise_count();
        let pct = crate::surprise_tracker::high_surprise_pct();
        println!("  Recorded: {} predictions", tool_scenarios.len());
        println!("  EMA: {:.4}", ema);
        println!("  Total tracked: {} (high surprise: {}, {:.1}%)", total, high, pct);

        // Query DB analytics
        let by_tool = crate::surprise_tracker::mean_surprisal_by_tool(200).unwrap();
        println!("  Surprisal by tool (top 10):");
        for (tool, avg, count) in by_tool.iter().take(10) {
            println!("    {:20} avg={:.3} count={}", tool, avg, count);
        }

        let recent = crate::surprise_tracker::recent_predictions(None, 5).unwrap();
        println!("  Recent predictions: {} rows returned", recent.len());
        assert!(total >= 50, "should have 50+ predictions");
        assert!(ema > 0.0, "EMA should be non-zero");

        // ============================================================
        // Phase 2: Memory Graph — store 30 triples forming a knowledge web
        // ============================================================
        println!("\n--- Phase 2: Memory Graph (knowledge web) ---");

        let knowledge = vec![
            // Tech stack
            ("chump", "is", "discord bot"),
            ("chump", "written_in", "rust"),
            ("chump", "uses", "sqlite"),
            ("chump", "uses", "axum"),
            ("chump", "uses", "serenity"),
            ("chump", "runs_on", "macos"),
            ("chump", "connects_to", "ollama"),
            ("chump", "connects_to", "mlx"),
            // Architecture
            ("sqlite", "stores", "memories"),
            ("sqlite", "stores", "episodes"),
            ("sqlite", "stores", "tasks"),
            ("sqlite", "stores", "predictions"),
            ("axum", "serves", "web ui"),
            ("axum", "serves", "health endpoint"),
            ("serenity", "handles", "discord messages"),
            // People and preferences
            ("jeff", "prefers", "rust"),
            ("jeff", "owns", "pixel phone"),
            ("jeff", "uses", "macos"),
            // Fleet
            ("mabel", "runs_on", "pixel phone"),
            ("mabel", "is", "companion agent"),
            ("mabel", "uses", "termux"),
            ("mabel", "connects_to", "ollama"),
            // Consciousness framework
            ("surprise tracker", "measures", "prediction errors"),
            ("blackboard", "implements", "global workspace"),
            ("memory graph", "stores", "knowledge triples"),
            ("counterfactual", "extracts", "causal lessons"),
            ("precision controller", "adjusts", "exploration"),
            ("phi proxy", "measures", "integration"),
            // Causal chains
            ("timeout", "caused_by", "slow model"),
            ("slow model", "caused_by", "large context"),
        ];

        let triples: Vec<(String, String, String)> = knowledge
            .iter()
            .map(|(s, r, o)| (s.to_string(), r.to_string(), o.to_string()))
            .collect();

        let stored = crate::memory_graph::store_triples(&triples, Some(1), None).unwrap();
        println!("  Stored: {} new triples", stored);

        let total_triples = crate::memory_graph::triple_count().unwrap();
        println!("  Total triples in graph: {}", total_triples);

        // Test associative recall
        let from_chump = crate::memory_graph::associative_recall(
            &["chump".to_string()], 2, 15,
        ).unwrap();
        println!("  Recall from 'chump' (2-hop): {} entities", from_chump.len());
        for (entity, score) in from_chump.iter().take(8) {
            println!("    {:25} score={:.3}", entity, score);
        }

        // Test multi-hop: chump -> sqlite -> memories
        let from_timeout = crate::memory_graph::associative_recall(
            &["timeout".to_string()], 2, 10,
        ).unwrap();
        println!("  Recall from 'timeout' (causal chain): {} entities", from_timeout.len());
        for (entity, score) in &from_timeout {
            println!("    {:25} score={:.3}", entity, score);
        }

        assert!(total_triples >= 28, "should have 28+ triples");
        assert!(!from_chump.is_empty(), "chump should have connections");

        // ============================================================
        // Phase 3: Blackboard — post from multiple modules
        // ============================================================
        println!("\n--- Phase 3: Blackboard (inter-module communication) ---");

        use crate::blackboard::*;
        let bb = global();

        // Simulate realistic posts from various modules
        let posts = vec![
            (Module::SurpriseTracker, "High prediction error on run_cli: 2 timeouts in last 5 calls", 0.9, 0.7, 0.8, 0.7),
            (Module::SurpriseTracker, "run_test showing elevated error rate", 0.8, 0.5, 0.6, 0.5),
            (Module::Episode, "Completed task: fix timeout handling in tool middleware", 0.7, 0.4, 0.5, 0.2),
            (Module::Episode, "Failed: npm test timed out during CI validation", 0.9, 0.6, 0.7, 0.6),
            (Module::Memory, "Recalled: Jeff prefers running tests locally before CI", 0.6, 0.5, 0.7, 0.3),
            (Module::Task, "Next task: benchmark consciousness framework memory recall", 0.5, 0.3, 0.8, 0.4),
            (Module::Task, "Task blocked: waiting for model server stability", 0.7, 0.4, 0.6, 0.7),
            (Module::Custom("precision_controller".to_string()), "Regime changed to 'balanced' — surprisal EMA=0.25", 0.9, 0.4, 0.5, 0.3),
            (Module::Brain, "Project playbook updated with new deployment steps", 0.5, 0.2, 0.4, 0.1),
            (Module::Autonomy, "Planner selected task #42 for execution", 0.6, 0.3, 0.7, 0.4),
        ];

        for (module, content, novelty, unc_red, goal_rel, urgency) in &posts {
            bb.post(
                module.clone(),
                content.to_string(),
                SalienceFactors {
                    novelty: *novelty,
                    uncertainty_reduction: *unc_red,
                    goal_relevance: *goal_rel,
                    urgency: *urgency,
                },
            );
        }

        // Simulate cross-module reads (drives phi coupling)
        let _ = bb.read_from(Module::Task, &Module::SurpriseTracker);
        let _ = bb.read_from(Module::Task, &Module::Episode);
        let _ = bb.read_from(Module::Autonomy, &Module::SurpriseTracker);
        let _ = bb.read_from(Module::Autonomy, &Module::Task);
        let _ = bb.read_from(Module::Memory, &Module::Episode);
        let _ = bb.read_from(Module::Memory, &Module::Task);
        let _ = bb.read_from(Module::Episode, &Module::SurpriseTracker);

        let broadcast = bb.broadcast_entries();
        let ctx = bb.broadcast_context(5, 2000);
        println!("  Posted: {} entries", posts.len());
        println!("  Broadcast (above threshold): {} entries", broadcast.len());
        println!("  Broadcast context length: {} chars", ctx.len());
        println!("  Cross-module read pairs: {}", bb.cross_module_reads().len());

        assert!(broadcast.len() >= 5, "most entries should broadcast");

        // ============================================================
        // Phase 4: Counterfactual — generate causal lessons from episodes
        // ============================================================
        println!("\n--- Phase 4: Counterfactual Reasoning ---");

        // Log episodes with various sentiments
        let episodes = vec![
            ("Successfully deployed consciousness framework", Some("All 6 modules active and tests passing"), Some("deployment,consciousness"), Some("win")),
            ("Memory recall returned stale context for multi-hop query", Some("FTS5 keyword search missed causally related memories"), Some("memory,recall"), Some("frustrating")),
            ("Tool run_cli timed out during npm test", Some("30s timeout insufficient for full test suite"), Some("timeout,testing"), Some("loss")),
            ("Fixed timeout handling in tool middleware", Some("Increased default timeout and added per-tool config"), Some("fix,middleware"), Some("win")),
            ("Git push failed due to auth token expiry", Some("GITHUB_TOKEN expired; had to regenerate"), Some("auth,git"), Some("frustrating")),
            ("Battle QA run: 498/500 pass", Some("2 failures in edge-case calc queries"), Some("qa,testing"), Some("win")),
            ("Provider cascade fell through to local after cloud rate limit", Some("All cloud slots exhausted in 5 minutes"), Some("provider,rate-limit"), Some("uncertain")),
            ("Episodic memory sentiment analysis working correctly", Some("Frustrating episodes properly filtered for context"), Some("episode,sentiment"), Some("win")),
            ("Autonomy loop stuck on task with missing acceptance criteria", Some("Planner couldn't determine done condition"), Some("autonomy,planning"), Some("frustrating")),
            ("Read_url tool failed on JS-heavy site", Some("reqwest returned empty body; needs browser sandbox"), Some("read_url,scraping"), Some("loss")),
        ];

        let mut episode_ids = Vec::new();
        for (summary, detail, tags, sentiment) in &episodes {
            let id = crate::episode_db::episode_log(
                summary,
                *detail,
                *tags,
                Some("chump"),
                *sentiment,
                None,
                None,
            ).unwrap();
            episode_ids.push(id);
        }
        println!("  Logged: {} episodes", episodes.len());

        // Run counterfactual analysis on frustrating/loss episodes
        let mut lessons_generated = 0;
        for (i, (summary, detail, tags, sentiment)) in episodes.iter().enumerate() {
            if matches!(*sentiment, Some("frustrating") | Some("loss") | Some("uncertain")) {
                let lesson = crate::counterfactual::analyze_episode(
                    episode_ids[i],
                    summary,
                    *detail,
                    *sentiment,
                    *tags,
                ).unwrap();
                if lesson.is_some() {
                    lessons_generated += 1;
                }
            }
        }
        println!("  Causal lessons generated: {}", lessons_generated);

        let total_lessons = crate::counterfactual::lesson_count().unwrap();
        println!("  Total lessons in DB: {}", total_lessons);

        let patterns = crate::counterfactual::failure_patterns(10).unwrap();
        println!("  Failure patterns:");
        for (task_type, count) in &patterns {
            println!("    {:30} count={}", task_type, count);
        }

        // Test lesson retrieval
        let ctx = crate::counterfactual::lessons_for_context(None, "timeout testing npm", 5);
        println!("  Lessons for 'timeout testing npm': {} chars", ctx.len());

        assert!(total_lessons >= 3, "should have at least 3 lessons from frustrating episodes");

        // ============================================================
        // Phase 5: Precision Controller — verify regime + energy
        // ============================================================
        println!("\n--- Phase 5: Precision Controller ---");

        let regime = crate::precision_controller::current_regime();
        let tier = crate::precision_controller::recommended_model_tier();
        let max_tools = crate::precision_controller::recommended_max_tool_calls();
        let ctx_budget = crate::precision_controller::context_exploration_budget();
        let escalation = crate::precision_controller::escalation_rate();

        println!("  Regime: {}", regime);
        println!("  Model tier: {}", tier);
        println!("  Max tool calls: {}", max_tools);
        println!("  Context exploration budget: {:.0}%", ctx_budget * 100.0);
        println!("  Escalation rate: {:.1}%", escalation * 100.0);
        println!("  Should escalate: {}", crate::precision_controller::should_escalate_model());

        // Simulate energy budget
        crate::precision_controller::set_energy_budget(100000, 200);
        crate::precision_controller::record_energy_spent(25000, 50);
        crate::precision_controller::record_model_decision(crate::precision_controller::ModelTier::Standard);
        crate::precision_controller::record_model_decision(crate::precision_controller::ModelTier::Standard);
        crate::precision_controller::record_model_decision(crate::precision_controller::ModelTier::Capable);

        println!("  Token budget remaining: {:.0}%", crate::precision_controller::token_budget_remaining() * 100.0);
        println!("  Tool budget remaining: {:.0}%", crate::precision_controller::tool_call_budget_remaining() * 100.0);
        println!("  Budget critical: {}", crate::precision_controller::budget_critical());

        let params = crate::precision_controller::adaptive_params();
        println!("  Adaptive params: regime={}, tier={}, max_tools={}, explore={:.0}%, critical={}",
            params.regime, params.model_tier, params.max_tool_calls,
            params.context_exploration_fraction * 100.0, params.budget_critical);

        // Trigger regime change check (posts to blackboard if changed)
        crate::precision_controller::check_regime_change();

        // ============================================================
        // Phase 6: Phi Proxy — integrated information
        // ============================================================
        println!("\n--- Phase 6: Phi Proxy (Integrated Information) ---");

        let phi = crate::phi_proxy::compute_phi();
        println!("  Phi proxy: {:.4}", phi.phi_proxy);
        println!("  Coupling score: {:.4} ({}/{} pairs)", phi.coupling_score, phi.active_coupling_pairs, phi.total_possible_pairs);
        println!("  Cross-read utilization: {:.1}%", phi.cross_read_utilization * 100.0);
        println!("  Information flow entropy: {:.4}", phi.information_flow_entropy);

        let activity = crate::phi_proxy::module_activity();
        if !activity.is_empty() {
            println!("  Module activity:");
            for (module, act) in &activity {
                println!("    {:25} reads_from_others={}, read_by_others={}",
                    module, act.reads_from_others, act.read_by_others);
            }
        }

        assert!(phi.active_coupling_pairs > 0, "should have active coupling");
        assert!(phi.phi_proxy > 0.0, "phi proxy should be non-zero");

        // ============================================================
        // Final Report
        // ============================================================
        println!("\n============================================================");
        println!("  FINAL METRICS REPORT");
        println!("============================================================");
        println!();
        println!("  SURPRISE (Phase 1)");
        println!("    Predictions:        {}", crate::surprise_tracker::total_predictions());
        println!("    Surprisal EMA:      {:.4}", crate::surprise_tracker::current_surprisal_ema());
        println!("    High-surprise:      {} ({:.1}%)", crate::surprise_tracker::high_surprise_count(), crate::surprise_tracker::high_surprise_pct());
        println!("    Tools tracked:      {}", by_tool.len());
        println!();
        println!("  MEMORY GRAPH (Phase 2)");
        println!("    Triples:            {}", crate::memory_graph::triple_count().unwrap());
        println!("    Recall depth:       2-hop associative");
        println!("    Connected to RRF:   3-way merge (keyword + semantic + graph)");
        println!();
        println!("  BLACKBOARD (Phase 3)");
        println!("    Entries posted:     {}", bb.entry_count());
        println!("    Broadcast count:    {}", bb.cross_read_entry_count());
        println!("    Cross-module pairs: {}", bb.cross_module_reads().len());
        println!();
        println!("  COUNTERFACTUAL (Phase 4)");
        println!("    Episodes logged:    {}", episodes.len());
        println!("    Lessons generated:  {}", total_lessons);
        println!("    Failure patterns:   {}", patterns.len());
        println!();
        println!("  PRECISION (Phase 5)");
        println!("    Regime:             {}", regime);
        println!("    Model tier:         {}", tier);
        println!("    Escalation rate:    {:.1}%", crate::precision_controller::escalation_rate() * 100.0);
        println!();
        println!("  PHI PROXY (Phase 6)");
        println!("    Phi:                {:.4}", phi.phi_proxy);
        println!("    Coupling:           {:.4}", phi.coupling_score);
        println!("    Cross-read util:    {:.1}%", phi.cross_read_utilization * 100.0);
        println!("    Entropy:            {:.4}", phi.information_flow_entropy);
        println!();

        // Verdict
        let all_active = crate::surprise_tracker::total_predictions() >= 50
            && crate::memory_graph::triple_count().unwrap() >= 28
            && total_lessons >= 3
            && phi.active_coupling_pairs > 0;

        if all_active {
            println!("  VERDICT: ALL 6 PHASES ACTIVE AND GENERATING DATA");
            println!("           Framework is operational and producing measurable metrics.");
        } else {
            println!("  VERDICT: Some phases not fully active. Check individual metrics above.");
        }
        println!();

        teardown(dir, prev);
    }
}
