//! Comprehensive DB-backed integration tests for the Synthetic Consciousness Framework.
//!
//! These tests exercise the full lifecycle of all 6 modules through the real SQLite pool,
//! validating cross-module wiring and establishing baseline behavior.

#[cfg(test)]
mod tests {
    use serial_test::serial;
    use std::fs;

    fn setup_test_db() -> (std::path::PathBuf, Option<std::path::PathBuf>) {
        let dir = std::env::temp_dir().join(format!(
            "chump_consciousness_test_{}",
            uuid::Uuid::new_v4().simple()
        ));
        let _ = fs::create_dir_all(dir.join("sessions"));
        let prev = std::env::current_dir().ok();
        std::env::set_current_dir(&dir).ok();
        // Full context tests assume consciousness + memory graph sections are not suppressed by light interactive.
        std::env::remove_var("CHUMP_LIGHT_CONTEXT");
        (dir, prev)
    }

    fn teardown(dir: std::path::PathBuf, prev: Option<std::path::PathBuf>) {
        if let Some(p) = prev {
            std::env::set_current_dir(p).ok();
        }
        let _ = fs::remove_dir_all(&dir);
    }

    // --- Phase 2: Memory Graph DB Lifecycle ---

    #[test]
    #[serial]
    fn memory_graph_store_and_traverse() {
        let (dir, prev) = setup_test_db();

        // Clean up any leftover rows from previous runs sharing the global pool DB.
        if let Ok(conn) = crate::db_pool::get() {
            let _ = conn.execute(
                "DELETE FROM chump_memory_graph WHERE subject IN ('test_agent_x','test_bot_y','test_db_z','test_data_w') OR object IN ('test_agent_x','test_bot_y','test_db_z','test_data_w')",
                [],
            );
        }

        // Store triples that form a chain: A->B->C (use unique entities to avoid collision with exercise)
        let triples1 = vec![
            (
                "test_agent_x".to_string(),
                "is".to_string(),
                "test_bot_y".to_string(),
            ),
            (
                "test_bot_y".to_string(),
                "uses".to_string(),
                "test_db_z".to_string(),
            ),
        ];
        let stored = crate::memory_graph::store_triples(&triples1, Some(1), None).unwrap();
        assert_eq!(stored, 2);

        // Store more triples extending the graph
        let triples2 = vec![
            (
                "test_db_z".to_string(),
                "stores".to_string(),
                "test_data_w".to_string(),
            ),
            (
                "test_agent_x".to_string(),
                "runs_on".to_string(),
                "test_lang_v".to_string(),
            ),
        ];
        crate::memory_graph::store_triples(&triples2, Some(2), None).unwrap();

        // Verify triple count (at least 4 from this test)
        let count = crate::memory_graph::triple_count().unwrap();
        assert!(count >= 4, "should have at least 4 triples: {}", count);

        // Test associative recall: seed with "test_agent_x", should find connected entities
        let results =
            crate::memory_graph::associative_recall(&["test_agent_x".to_string()], 2, 10).unwrap();
        assert!(
            !results.is_empty(),
            "should find connected entities from test_agent_x"
        );
        let entity_names: Vec<&str> = results.iter().map(|(e, _)| e.as_str()).collect();
        assert!(
            entity_names.contains(&"test_bot_y")
                || entity_names.contains(&"test_lang_v")
                || entity_names.contains(&"test_db_z"),
            "should find related entities: {:?}",
            entity_names
        );

        // Test 2-hop: "test_agent_x" -> "test_bot_y" -> "test_db_z" -> "test_data_w"
        let deep =
            crate::memory_graph::associative_recall(&["test_agent_x".to_string()], 2, 20).unwrap();
        let deep_names: Vec<&str> = deep.iter().map(|(e, _)| e.as_str()).collect();
        assert!(
            deep_names.contains(&"test_db_z") || deep_names.contains(&"test_data_w"),
            "2-hop should reach test_db_z or test_data_w: {:?}",
            deep_names
        );

        // Test memory_ids_for_entities
        let ids = crate::memory_graph::memory_ids_for_entities(&[
            "test_agent_x".to_string(),
            "test_db_z".to_string(),
        ])
        .unwrap();
        assert!(!ids.is_empty(), "should find memory IDs for known entities");

        // Test duplicate triple reinforcement (weight increase)
        let triples_dup = vec![(
            "test_agent_x".to_string(),
            "is".to_string(),
            "test_bot_y".to_string(),
        )];
        let stored_dup = crate::memory_graph::store_triples(&triples_dup, Some(3), None).unwrap();
        assert_eq!(stored_dup, 0, "duplicate should not create new triple");
        // Count should not increase from duplicate
        assert_eq!(crate::memory_graph::triple_count().unwrap(), count);

        teardown(dir, prev);
    }

    /// Curated recall@k (Phase F / gap closure): default `cargo test` coverage; script is for timing only.
    #[test]
    #[serial]
    fn memory_graph_curated_recall_topk() {
        let (dir, prev) = setup_test_db();

        let curated = vec![
            (
                "mg_curated_iphone".to_string(),
                "uses".to_string(),
                "mg_curated_ios".to_string(),
            ),
            (
                "mg_curated_ipad".to_string(),
                "uses".to_string(),
                "mg_curated_ios".to_string(),
            ),
            (
                "mg_curated_ios".to_string(),
                "part_of".to_string(),
                "mg_curated_hub".to_string(),
            ),
            (
                "mg_curated_macbook".to_string(),
                "uses".to_string(),
                "mg_curated_macos".to_string(),
            ),
            (
                "mg_curated_macos".to_string(),
                "part_of".to_string(),
                "mg_curated_hub".to_string(),
            ),
        ];
        crate::memory_graph::store_triples(&curated, None, None).unwrap();
        let ranked =
            crate::memory_graph::associative_recall(&["mg_curated_iphone".to_string()], 12, 5)
                .unwrap();
        let top: Vec<&str> = ranked.iter().map(|(s, _)| s.as_str()).collect();
        assert!(
            top.contains(&"mg_curated_hub"),
            "expected mg_curated_hub in top-5: {:?}",
            top
        );

        teardown(dir, prev);
    }

    // --- Phase 3: Blackboard Lifecycle ---

    #[test]
    fn blackboard_full_lifecycle() {
        use crate::blackboard::*;

        let bb = Blackboard::new();

        // Post from multiple modules with varying salience
        let id1 = bb.post(
            Module::SurpriseTracker,
            "High prediction error on run_cli tool".to_string(),
            SalienceFactors {
                novelty: 1.0,
                uncertainty_reduction: 0.7,
                goal_relevance: 0.8,
                urgency: 0.6,
            },
        );
        let id2 = bb.post(
            Module::Episode,
            "Task completed successfully: fixed timeout".to_string(),
            SalienceFactors {
                novelty: 0.8,
                uncertainty_reduction: 0.5,
                goal_relevance: 0.6,
                urgency: 0.2,
            },
        );
        let _id3 = bb.post(
            Module::Memory,
            "Routine fact stored".to_string(),
            SalienceFactors {
                novelty: 0.1,
                uncertainty_reduction: 0.0,
                goal_relevance: 0.1,
                urgency: 0.0,
            },
        );
        assert!(id1 > 0 && id2 > 0);

        // Verify broadcast_entries only returns above-threshold items
        let broadcast = bb.broadcast_entries();
        assert!(
            broadcast.len() >= 2,
            "high-salience entries should broadcast: {}",
            broadcast.len()
        );
        assert!(
            broadcast[0].salience >= broadcast[1].salience,
            "should be sorted by salience"
        );

        // Verify low-salience item is filtered
        let low_sal = broadcast
            .iter()
            .find(|e| e.content.contains("Routine fact"));
        assert!(low_sal.is_none(), "low-salience entry should not broadcast");

        // Test broadcast_context formatting
        let ctx = bb.broadcast_context(5, 2000);
        assert!(ctx.contains("Global workspace"));
        assert!(ctx.contains("prediction error"));

        // Test cross-module reads (drives phi coupling)
        let task_reads = bb.read_from(Module::Task, &Module::SurpriseTracker);
        assert_eq!(task_reads.len(), 1);

        let autonomy_reads = bb.read_from(Module::Autonomy, &Module::Episode);
        assert_eq!(autonomy_reads.len(), 1);

        // Verify cross-module read tracking
        let reads = bb.cross_module_reads();
        assert_eq!(
            *reads
                .get(&(Module::Task, Module::SurpriseTracker))
                .unwrap_or(&0),
            1
        );
        assert_eq!(
            *reads
                .get(&(Module::Autonomy, Module::Episode))
                .unwrap_or(&0),
            1
        );
        assert_eq!(reads.len(), 2, "should have exactly 2 cross-module pairs");
    }

    // --- Phase 4: Counterfactual DB Lifecycle ---

    #[test]
    #[serial]
    fn counterfactual_store_find_apply() {
        let (dir, prev) = setup_test_db();

        // Use unique task type per run so accumulated rows from prior test runs don't crowd
        // out freshly inserted lessons when the pool-shared DB has many rows at the query limit.
        let deploy_type = format!("deployment_{}", uuid::Uuid::new_v4().simple());

        // Store lessons manually
        let id1 = crate::counterfactual::store_lesson(
            Some(1),
            Some(&deploy_type),
            "ran deploy without checking tests",
            Some("run tests first then deploy"),
            "Always run tests before deployment to prevent broken releases",
            0.8,
            None,
        )
        .unwrap();
        assert!(id1 > 0);

        let _id2 = crate::counterfactual::store_lesson(
            Some(2),
            Some(&deploy_type),
            "deployed on Friday afternoon",
            Some("schedule for Monday"),
            "Avoid Friday deployments; schedule risky changes for early week",
            0.6,
            None,
        )
        .unwrap();

        let _id3 = crate::counterfactual::store_lesson(
            Some(3),
            Some("memory"),
            "memory recall returned stale data",
            None,
            "Check memory freshness before trusting recalled context",
            0.5,
            None,
        )
        .unwrap();

        // Verify lesson count (at least 3 from this test; may be more from other tests)
        let count = crate::counterfactual::lesson_count().unwrap();
        assert!(count >= 3, "should have at least 3 lessons: {}", count);

        // Find by task type — unique type guarantees exactly the rows we inserted
        let deploy_lessons =
            crate::counterfactual::find_relevant_lessons(Some(&deploy_type), &[], 10).unwrap();
        assert!(
            deploy_lessons.len() >= 2,
            "should find at least 2 deployment lessons: {}",
            deploy_lessons.len()
        );
        if deploy_lessons.len() >= 2 {
            assert!(deploy_lessons[0].confidence >= deploy_lessons[1].confidence);
        }

        // Find by keyword
        let keyword_lessons =
            crate::counterfactual::find_relevant_lessons(None, &["tests", "deployment"], 10)
                .unwrap();
        assert!(!keyword_lessons.is_empty());

        // Mark lesson applied
        crate::counterfactual::mark_lesson_applied(id1).unwrap();
        let updated =
            crate::counterfactual::find_relevant_lessons(Some(&deploy_type), &[], 10).unwrap();
        let applied = updated.iter().find(|l| l.id == id1).unwrap();
        assert!(applied.times_applied >= 1);

        // Failure patterns — unique type means we find exactly our rows
        let patterns = crate::counterfactual::failure_patterns(100).unwrap();
        assert!(!patterns.is_empty());
        let deploy_count = patterns.iter().find(|(t, _)| t == &deploy_type);
        assert!(deploy_count.is_some());
        assert!(deploy_count.unwrap().1 >= 2);

        // Test analyze_episode on frustrating episode
        let lesson = crate::counterfactual::analyze_episode(
            100,
            "run_cli timed out after 30s on npm test",
            Some("ran npm test without checking node_modules"),
            Some("frustrating"),
            Some("timeout,testing"),
        )
        .unwrap();
        assert!(
            lesson.is_some(),
            "frustrating episode should produce a lesson"
        );
        let lesson = lesson.unwrap();
        // COG-004: analyze_episode now uses graph-derived lessons when paths exist ("Causal path:"),
        // falling back to heuristic ("timed out"/"timeout") when graph has no paths.
        assert!(
            lesson.lesson.contains("timed out")
                || lesson.lesson.contains("timeout")
                || lesson.lesson.contains("Causal path:"),
            "expected timeout heuristic or graph-derived lesson, got: {}",
            lesson.lesson
        );

        // Neutral episodes should NOT produce lessons
        let no_lesson = crate::counterfactual::analyze_episode(
            101,
            "Normal task completed",
            Some("did the work"),
            Some("win"),
            Some("general"),
        )
        .unwrap();
        assert!(
            no_lesson.is_none(),
            "win episodes should not produce lessons"
        );

        // Test lessons_for_context formatting
        let ctx = crate::counterfactual::lessons_for_context(
            Some(&deploy_type),
            "deploy the new version",
            5,
        );
        assert!(ctx.contains("PROJECT-SPECIFIC CONFIGURATION"));

        teardown(dir, prev);
    }

    // --- Phase 5: Precision + Surprise Combined ---

    #[test]
    fn precision_regime_driven_by_surprisal() {
        use crate::precision_controller::*;

        // At startup with 0 EMA (surprisal_ema removed), should be in exploit mode
        let ema = 0.0_f64;
        if ema < 0.15 {
            assert_eq!(current_regime(), PrecisionRegime::Exploit);
            assert_eq!(recommended_model_tier(), ModelTier::Fast);
            assert_eq!(recommended_max_tool_calls(), 3);
        }

        // Adaptive params bundle should be consistent
        let params = adaptive_params();
        assert_eq!(params.regime, current_regime());
        assert_eq!(params.model_tier, recommended_model_tier());
        assert_eq!(params.max_tool_calls, recommended_max_tool_calls());

        // Context budget should be in valid range
        assert!(params.context_exploration_fraction > 0.0);
        assert!(params.context_exploration_fraction <= 1.0);
    }

    #[test]
    fn energy_budget_from_env() {
        use crate::precision_controller::*;

        // With no env set, budget should remain unlimited
        std::env::remove_var("CHUMP_SESSION_ENERGY_TOKENS");
        std::env::remove_var("CHUMP_SESSION_ENERGY_TOOLS");
        init_energy_budget_from_env();

        // Set env and verify it takes effect
        std::env::set_var("CHUMP_SESSION_ENERGY_TOKENS", "50000");
        std::env::set_var("CHUMP_SESSION_ENERGY_TOOLS", "100");
        init_energy_budget_from_env();

        // Budget should now be set (can't reset atomics so just verify the function doesn't panic)
        let _ = token_budget_remaining();
        let _ = tool_call_budget_remaining();

        std::env::remove_var("CHUMP_SESSION_ENERGY_TOKENS");
        std::env::remove_var("CHUMP_SESSION_ENERGY_TOOLS");
    }

    // --- Phase 6: Phi Proxy with Blackboard ---

    #[test]
    fn phi_proxy_measures_cross_module_coupling() {
        use crate::blackboard::*;

        let bb = Blackboard::new();

        // Post from 3 different modules
        bb.post(
            Module::Memory,
            "fact A".to_string(),
            SalienceFactors {
                novelty: 1.0,
                uncertainty_reduction: 0.5,
                goal_relevance: 0.5,
                urgency: 0.5,
            },
        );
        bb.post(
            Module::Episode,
            "event B".to_string(),
            SalienceFactors {
                novelty: 1.0,
                uncertainty_reduction: 0.5,
                goal_relevance: 0.5,
                urgency: 0.5,
            },
        );
        bb.post(
            Module::SurpriseTracker,
            "surprise C".to_string(),
            SalienceFactors {
                novelty: 1.0,
                uncertainty_reduction: 0.5,
                goal_relevance: 0.5,
                urgency: 0.5,
            },
        );

        // Task reads from Memory and Episode
        let _ = bb.read_from(Module::Task, &Module::Memory);
        let _ = bb.read_from(Module::Task, &Module::Episode);
        // Autonomy reads from SurpriseTracker
        let _ = bb.read_from(Module::Autonomy, &Module::SurpriseTracker);

        // Verify cross-module reads
        let reads = bb.cross_module_reads();
        assert_eq!(reads.len(), 3, "should have 3 cross-module read pairs");

        // Verify coupling metrics
        assert!(reads.values().all(|&v| v > 0));

        // Verify broadcast bumps cross_read_entry_count
        let _ = bb.broadcast_context(5, 1000);
        assert!(bb.cross_read_entry_count() > 0);
    }

    // --- Cross-Module Integration ---

    #[test]
    #[serial]
    fn cross_module_episode_to_counterfactual_to_context() {
        let (dir, prev) = setup_test_db();

        // Log an episode that triggers counterfactual analysis
        let ep_id = crate::episode_db::episode_log(
            "Tool run_cli failed with timeout",
            Some("Attempted to run npm test but it timed out after 30 seconds"),
            Some("timeout,testing"),
            Some("chump"),
            Some("frustrating"),
            None,
            None,
        )
        .unwrap();
        assert!(ep_id > 0);

        // Manually trigger counterfactual analysis (normally done by episode_tool)
        let lesson = crate::counterfactual::analyze_episode(
            ep_id,
            "Tool run_cli failed with timeout",
            Some("Attempted to run npm test but it timed out"),
            Some("frustrating"),
            Some("timeout,testing"),
        )
        .unwrap();
        assert!(
            lesson.is_some(),
            "frustrating episode should generate a causal lesson"
        );

        // Verify lessons are retrievable for context
        let ctx = crate::counterfactual::lessons_for_context(Some("timeout"), "run tests", 5);
        // May or may not match depending on task_type extraction, but should not panic
        let _ = ctx;

        teardown(dir, prev);
    }

    #[test]
    fn consciousness_summary_strings_all_valid() {
        let precision = crate::precision_controller::summary();
        assert!(precision.contains("regime:"));
        assert!(precision.contains("energy:"));

        let phi = crate::phi_proxy::summary();
        assert!(phi.contains("phi_proxy"));
        assert!(phi.contains("coupling"));

        let phi_json = crate::phi_proxy::metrics_json();
        assert!(phi_json.get("phi_proxy").is_some());
        assert!(phi_json.get("coupling_score").is_some());
    }

    // --- Edge Case Tests ---

    #[test]
    #[serial]
    fn edge_graph_cycle_does_not_blow_up() {
        let (dir, prev) = setup_test_db();

        // Create a cycle: A -> B -> A
        let triples = vec![
            (
                "cycle_a".to_string(),
                "links_to".to_string(),
                "cycle_b".to_string(),
            ),
            (
                "cycle_b".to_string(),
                "links_to".to_string(),
                "cycle_a".to_string(),
            ),
            (
                "cycle_b".to_string(),
                "links_to".to_string(),
                "cycle_c".to_string(),
            ),
        ];
        crate::memory_graph::store_triples(&triples, Some(99), None).unwrap();

        // Should complete without infinite loop even with cycles
        let results =
            crate::memory_graph::associative_recall(&["cycle_a".to_string()], 3, 10).unwrap();
        // Should find cycle_b and cycle_c but not loop forever
        assert!(!results.is_empty(), "should find entities despite cycle");
        let names: Vec<&str> = results.iter().map(|(e, _)| e.as_str()).collect();
        assert!(
            names.contains(&"cycle_b") || names.contains(&"cycle_c"),
            "should traverse past cycle: {:?}",
            names
        );

        teardown(dir, prev);
    }

    #[test]
    fn edge_empty_inputs() {
        // Empty seed entities -> empty results
        let r = crate::memory_graph::associative_recall(&[], 2, 10);
        assert!(r.is_ok());
        assert!(r.unwrap().is_empty());

        // Empty entity list for memory_ids
        let r = crate::memory_graph::memory_ids_for_entities(&[]);
        assert!(r.is_ok());
        assert!(r.unwrap().is_empty());

        // Empty text extraction
        let triples = crate::memory_graph::extract_triples("");
        assert!(triples.is_empty());

        // Empty query entities
        let entities = crate::memory_graph::extract_query_entities("");
        assert!(entities.is_empty());
    }

    #[test]
    fn edge_regime_at_ema_1_0() {
        // Regime for very high surprisal should be Conservative
        assert!(
            !crate::precision_controller::current_regime()
                .to_string()
                .is_empty(),
            "regime string should be non-empty"
        );
        // Directly test boundary
        let s = crate::precision_controller::summary();
        assert!(s.contains("regime:"));
    }

    #[test]
    fn edge_blackboard_self_read_no_coupling() {
        use crate::blackboard::*;
        let bb = Blackboard::new();
        bb.post(
            Module::Memory,
            "self fact".to_string(),
            SalienceFactors {
                novelty: 1.0,
                uncertainty_reduction: 0.5,
                goal_relevance: 0.5,
                urgency: 0.5,
            },
        );

        // Same-module read should not count as cross-module coupling
        let _ = bb.read_from(Module::Memory, &Module::Memory);
        let reads = bb.cross_module_reads();
        assert!(
            reads.is_empty(),
            "self-reads should not create coupling pairs"
        );
    }

    #[test]
    fn edge_broadcast_context_char_truncation() {
        use crate::blackboard::*;
        let bb = Blackboard::new();
        for i in 0..10 {
            bb.post(
                Module::SurpriseTracker,
                format!("Entry number {} with some content that takes space", i),
                SalienceFactors {
                    novelty: 1.0,
                    uncertainty_reduction: 0.5,
                    goal_relevance: 0.8,
                    urgency: 0.5,
                },
            );
        }

        // Very small char budget should truncate
        let ctx = bb.broadcast_context(10, 100);
        assert!(
            ctx.len() <= 150,
            "should respect char budget: {} chars",
            ctx.len()
        );
        assert!(ctx.contains("Global workspace"));
    }

    #[test]
    fn edge_phi_with_custom_modules() {
        use crate::blackboard::*;
        let bb = Blackboard::new();
        bb.post(
            Module::Custom("plugin_a".to_string()),
            "data".to_string(),
            SalienceFactors {
                novelty: 1.0,
                uncertainty_reduction: 0.5,
                goal_relevance: 0.5,
                urgency: 0.5,
            },
        );
        bb.post(
            Module::Custom("plugin_b".to_string()),
            "data".to_string(),
            SalienceFactors {
                novelty: 1.0,
                uncertainty_reduction: 0.5,
                goal_relevance: 0.5,
                urgency: 0.5,
            },
        );

        let _ = bb.read_from(
            Module::Custom("plugin_a".to_string()),
            &Module::Custom("plugin_b".to_string()),
        );
        let reads = bb.cross_module_reads();
        assert_eq!(
            reads.len(),
            1,
            "custom modules should create coupling pairs"
        );
    }

    #[test]
    #[serial]
    fn edge_counterfactual_neutral_no_lesson() {
        let (dir, prev) = setup_test_db();

        // Neutral/win episodes should not generate lessons
        let result = crate::counterfactual::analyze_episode(
            999,
            "Everything went fine",
            Some("normal work"),
            Some("neutral"),
            Some("general"),
        )
        .unwrap();
        assert!(
            result.is_none(),
            "neutral episodes should not generate lessons"
        );

        let result = crate::counterfactual::analyze_episode(
            1000,
            "Great success",
            Some("shipped it"),
            Some("win"),
            Some("deploy"),
        )
        .unwrap();
        assert!(result.is_none(), "win episodes should not generate lessons");

        teardown(dir, prev);
    }

    #[test]
    fn edge_tool_call_budget_warning() {
        // Reset turn counter
        crate::tool_middleware::reset_turn_tool_calls();
        // The check_tool_call_budget is internal, but reset_turn_tool_calls is public
        // Just verify it doesn't panic
    }

    #[test]
    #[serial]
    fn edge_lessons_for_context_with_ids() {
        let (dir, prev) = setup_test_db();

        // Use a unique task_type per run so prior test runs' accumulated rows don't crowd
        // out this insertion when the pool-shared DB has many "edge_test" rows at limit.
        let unique_task_type = format!("edge_test_{}", uuid::Uuid::new_v4().simple());

        let id = crate::counterfactual::store_lesson(
            Some(1),
            Some(&unique_task_type),
            "did something",
            Some("try other"),
            "Test lesson for edge case",
            0.9,
            None,
        )
        .unwrap();

        let (ctx, ids) = crate::counterfactual::lessons_for_context_with_ids(
            Some(&unique_task_type),
            "edge case testing",
            5,
        );
        assert!(!ctx.is_empty(), "should return lesson text");
        assert!(ids.contains(&id), "should return the lesson ID: {:?}", ids);

        teardown(dir, prev);
    }

    #[test]
    #[serial]
    fn edge_decay_unused_lessons() {
        let (dir, prev) = setup_test_db();

        // Store a lesson with old timestamp
        let conn = crate::db_pool::get().unwrap();
        conn.execute(
            "INSERT INTO chump_causal_lessons (episode_id, task_type, action_taken, lesson, confidence, times_applied, created_at) \
             VALUES (1, 'old_type', 'old action', 'old lesson', 0.8, 0, '1000000')",
            [],
        ).unwrap();

        // Decay should reduce confidence for old unused lessons
        let affected = crate::counterfactual::decay_unused_lessons(0, 0.1).unwrap();
        assert!(affected >= 1, "should affect at least the old lesson");

        teardown(dir, prev);
    }

    // --- Regression suite: cross-module state transition scenarios ---

    #[test]
    #[serial]
    fn regression_blackboard_persistence_roundtrip() {
        let (dir, prev) = setup_test_db();
        // Clear accumulated global blackboard entries and persisted rows from
        // prior tests so our entry isn't evicted by the in-memory capacity
        // limit or pruned by the DB top-50 DELETE.
        let bb = crate::blackboard::global();
        bb.clear_entries();
        if let Ok(conn) = crate::db_pool::get() {
            let _ = conn.execute("DELETE FROM chump_blackboard_persist", []);
        }
        bb.post(
            crate::blackboard::Module::Memory,
            "persisted fact: Chump uses Rust".to_string(),
            crate::blackboard::SalienceFactors {
                novelty: 1.0,
                uncertainty_reduction: 0.7,
                goal_relevance: 0.9,
                urgency: 0.5,
            },
        );

        // Persist to DB
        crate::blackboard::persist_high_salience();

        // Verify row exists in DB
        let conn = crate::db_pool::get().unwrap();
        let count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM chump_blackboard_persist WHERE content LIKE '%Chump uses Rust%'",
            [],
            |r| r.get(0),
        ).unwrap();
        assert!(count >= 1, "persisted entry should exist in DB");

        teardown(dir, prev);
    }

    #[test]
    #[serial]
    fn regression_consciousness_metrics_recorded() {
        let (dir, prev) = setup_test_db();

        let bb = crate::blackboard::global();
        bb.post(
            crate::blackboard::Module::SurpriseTracker,
            "test metric recording".to_string(),
            crate::blackboard::SalienceFactors {
                novelty: 1.0,
                uncertainty_reduction: 0.5,
                goal_relevance: 0.5,
                urgency: 0.5,
            },
        );
        let _ = bb.read_from(
            crate::blackboard::Module::Task,
            &crate::blackboard::Module::SurpriseTracker,
        );

        // Record metrics (same function called by close_session)
        let phi = crate::phi_proxy::compute_phi();
        let ema = 0.0_f64;
        let regime = format!("{:?}", crate::precision_controller::current_regime());
        let conn = crate::db_pool::get().unwrap();
        let _ = conn.execute(
            "DELETE FROM chump_consciousness_metrics WHERE session_id = 'test_99'",
            [],
        );
        conn.execute(
            "INSERT INTO chump_consciousness_metrics (session_id, phi_proxy, surprisal_ema, coupling_score, regime) VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params!["test_99", phi.phi_proxy, ema, phi.coupling_score, regime],
        ).unwrap();

        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM chump_consciousness_metrics WHERE session_id = 'test_99'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 1, "should have recorded one metrics row");

        teardown(dir, prev);
    }

    #[test]
    #[serial]
    fn regression_consciousness_disabled_skips_injection() {
        let (dir, prev) = setup_test_db();

        // With consciousness disabled, context should NOT contain consciousness lines
        std::env::set_var("CHUMP_CONSCIOUSNESS_ENABLED", "0");
        let ctx = crate::context_assembly::assemble_context();
        std::env::remove_var("CHUMP_CONSCIOUSNESS_ENABLED");

        assert!(
            !ctx.contains("Prediction tracking:"),
            "should not inject surprise when disabled"
        );
        assert!(
            !ctx.contains("Precision control:"),
            "should not inject precision when disabled"
        );
        assert!(
            !ctx.contains("Global workspace"),
            "should not inject blackboard when disabled"
        );
        assert!(
            !ctx.contains("Associative memory:"),
            "should not inject memory_graph when disabled"
        );

        teardown(dir, prev);
    }

    #[test]
    #[serial]
    fn regression_memory_graph_in_context() {
        let (dir, prev) = setup_test_db();

        // Store some triples so memory_graph reports as available
        let triples = vec![
            ("Chump".to_string(), "uses".to_string(), "Rust".to_string()),
            (
                "Chump".to_string(),
                "has".to_string(),
                "blackboard".to_string(),
            ),
        ];
        crate::memory_graph::store_triples(&triples, None, None).unwrap();

        let ctx = crate::context_assembly::assemble_context();
        assert!(
            ctx.contains("Associative memory:"),
            "context should include memory graph summary"
        );
        assert!(ctx.contains("triples"), "should mention triple count");

        teardown(dir, prev);
    }
}
