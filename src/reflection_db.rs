//! Persistence + retrieval for structured reflections (GEPA, COG-006).
//!
//! Two tables (schema lives in `db_pool::init_schema`):
//!
//! - `chump_reflections`: one row per completed task / episode, with the
//!   typed fields from `reflection::Reflection` minus the improvements list
//!   (which is normalized into the next table).
//! - `chump_improvement_targets`: one row per directive, FK to parent
//!   reflection. Indexed on (priority, created_at) so the prompt assembler
//!   can pull the freshest high-priority targets cheaply.
//!
//! The "feedback flywheel" closes here:
//!
//! 1. Autonomy loop completes a task → `save_reflection()` (autonomy_loop.rs)
//! 2. Next task starts → `load_recent_high_priority_targets()` (prompt_assembler)
//! 3. Targets render into the system prompt as a "Lessons" block.
//!
//! Without persistence, `reflection.rs`'s typed analysis was throwaway. With
//! it, the agent gets to read its own postmortems.

#[cfg(test)]
use crate::reflection::{ErrorPattern, OutcomeClass};
use crate::reflection::{ImprovementTarget, Priority, Reflection};
use anyhow::Result;
#[cfg(test)]
use rusqlite::Connection;

#[cfg(not(test))]
fn open_db() -> Result<r2d2::PooledConnection<r2d2_sqlite::SqliteConnectionManager>> {
    crate::db_pool::get()
}

#[cfg(test)]
thread_local! {
    static TEST_DB_ROOT: std::cell::RefCell<Option<std::path::PathBuf>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
fn set_test_db_root(path: Option<std::path::PathBuf>) {
    TEST_DB_ROOT.with(|cell| *cell.borrow_mut() = path);
}

#[cfg(test)]
fn open_db() -> Result<Connection> {
    let base = TEST_DB_ROOT
        .with(|cell| cell.borrow().clone())
        .unwrap_or_else(|| {
            std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."))
        });
    let path = base.join("sessions/chump_memory.db");
    if let Some(p) = path.parent() {
        let _ = std::fs::create_dir_all(p);
    }
    let conn = Connection::open(&path)?;
    // Mirror schema from db_pool::init_schema for isolated tests.
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS chump_reflections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            episode_id INTEGER,
            task_id INTEGER,
            intended_goal TEXT NOT NULL DEFAULT '',
            observed_outcome TEXT NOT NULL DEFAULT '',
            outcome_class TEXT NOT NULL DEFAULT 'failure',
            error_pattern TEXT,
            hypothesis TEXT NOT NULL DEFAULT '',
            surprisal_at_reflect REAL,
            confidence_at_reflect REAL,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
         );
         CREATE TABLE IF NOT EXISTS chump_improvement_targets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            reflection_id INTEGER NOT NULL,
            directive TEXT NOT NULL,
            priority TEXT NOT NULL DEFAULT 'medium',
            scope TEXT,
            actioned_as TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
         );
         CREATE TABLE IF NOT EXISTS chump_causal_lessons (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            episode_id INTEGER,
            task_type TEXT,
            action_taken TEXT NOT NULL,
            alternative TEXT,
            lesson TEXT NOT NULL,
            confidence REAL NOT NULL DEFAULT 0.5,
            times_applied INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
         );",
    )?;
    Ok(conn)
}

/// Whether the reflection store is reachable. Mirrors `episode_db::episode_available()`.
pub fn reflection_available() -> bool {
    open_db().is_ok()
}

/// COG-011 gate: whether the "Lessons from prior episodes" block should be
/// injected into assembled prompts. Default on. Set `CHUMP_REFLECTION_INJECTION=0`
/// (also accepts "false" or "off") to run a baseline-prompt A/B without
/// recompiling. The gap test rig flips this flag across 20 tasks to measure
/// whether lesson injection actually improves task success.
pub fn reflection_injection_enabled() -> bool {
    !matches!(
        std::env::var("CHUMP_REFLECTION_INJECTION").as_deref(),
        Ok("0") | Ok("false") | Ok("off")
    )
}

// ---------------------------------------------------------------------------
// COG-016: model-tier-aware lessons injection
//
// The n=100 sweep (PRs #80 + #82, results in docs/CONSCIOUSNESS_AB_RESULTS.md)
// established statistically (p<0.05 across 3 fixtures, 10.7× A/A noise floor)
// that injecting the lessons block triggers fake-tool-call emission by mean
// +0.14 percentage points on weak agent models (haiku-4-5). The Llama-3.3-70B
// probe (2026-04-19) showed the failure mode is Anthropic-pretrain-specific;
// Llama doesn't exhibit it. Production should gate injection on agent
// capability + add an explicit anti-hallucination guardrail to the lessons
// content itself.
// ---------------------------------------------------------------------------

/// Coarse capability tier for the agent model the lessons block would be
/// injected into. Used by [`lessons_enabled_for_model`] to gate injection.
///
/// Ordering is meaningful: `Frontier` > `Sonnet` > `Capable` > `Small` > `Unknown`.
///
/// COG-023: `Sonnet` was carved out from `Frontier` because EVAL-027c (n=100,
/// non-overlapping CIs) confirmed the COG-016 anti-hallucination directive
/// ACTIVELY HARMS sonnet-4-5 — it triggers ~33% fake-tool-call emission per
/// response under cell A (full directive + lessons). Carving the tier below
/// `Frontier` means the default `CHUMP_LESSONS_MIN_TIER=frontier` excludes
/// sonnet, while operators can opt back in by lowering the threshold.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum ModelTier {
    /// Unrecognized model id — safest default is to NOT inject (avoid
    /// surprising any environment running a model we haven't classified).
    Unknown,
    /// Sub-14B local models (qwen2.5:7b, llama3.2:3b, etc.).
    Small,
    /// 14B-32B local mid-tier models (qwen2.5:14b, gpt-oss:20b).
    Capable,
    /// Anthropic Sonnet-class models (claude-sonnet-4-5+). Carved out from
    /// `Frontier` per COG-023 / EVAL-027c: the COG-016 directive backfires
    /// on Sonnet (33% fake-tool emission), so default-frontier injection
    /// must skip them. Below `Frontier` so default `CHUMP_LESSONS_MIN_TIER=
    /// frontier` does NOT inject; opt-in via `=capable` or lower.
    Sonnet,
    /// Frontier-class: claude-haiku-4-5+, opus-4-5+, gpt-4*,
    /// gemini-1.5-pro+, llama-3.x-70B+.
    /// (Sonnet intentionally excluded — see [`ModelTier::Sonnet`].)
    Frontier,
}

/// Map a model id (from `OPENAI_MODEL`, the agent backend, etc.) to a coarse
/// capability tier. Returns [`ModelTier::Unknown`] for unrecognized strings.
///
/// Matching is **case-insensitive substring** so it survives provider
/// variations like `claude-haiku-4-5-20251001` and
/// `meta-llama/Llama-3.3-70B-Instruct-Turbo`.
pub fn model_tier(model_id: &str) -> ModelTier {
    let m = model_id.to_lowercase();

    // COG-023: Sonnet carve-out — must be checked BEFORE the frontier
    // matchers (some legacy patterns like "claude-3-5-sonnet" would otherwise
    // hit a frontier marker). EVAL-027c confirmed the COG-016 directive
    // backfires on Sonnet (33% fake-tool emission per response, n=100).
    // Match any model id containing "sonnet" (case-insensitive). Opus and
    // haiku do NOT match this branch.
    if m.contains("sonnet") {
        return ModelTier::Sonnet;
    }

    // Frontier: cloud APIs + flagship locals (Sonnet is carved out above).
    let frontier_markers: &[&str] = &[
        "claude-haiku-4",
        "claude-opus-4",
        "claude-3-5-haiku",
        "claude-3-7",
        "claude-3-haiku",
        "gpt-4",
        "gpt-5",
        "o1",
        "o3",
        "gemini-1.5-pro",
        "gemini-2",
        "llama-3.3-70b",
        "llama-3.1-70b",
        "llama-3.1-405b",
        "qwen2.5-72b",
        "qwen2.5:72b",
    ];
    if frontier_markers.iter().any(|s| m.contains(s)) {
        return ModelTier::Frontier;
    }

    // Capable: 14B-32B local mid-tier
    let capable_markers: &[&str] = &[
        "qwen2.5:14b",
        "qwen2.5-14b",
        "qwen3:14b",
        "qwen3-14b",
        "qwen3:32b",
        "qwen3-32b",
        "qwen2.5:32b",
        "qwen2.5-32b",
        "llama-3.1-8b",
        "gpt-oss:20b",
        "gpt-oss-20b",
        "gemini-1.5-flash",
    ];
    if capable_markers.iter().any(|s| m.contains(s)) {
        return ModelTier::Capable;
    }

    // Small: sub-14B
    let small_markers: &[&str] = &[
        "llama-3.2-1b",
        "llama-3.2-3b",
        "llama3.2:1b",
        "llama3.2:3b",
        "qwen2.5:7b",
        "qwen2.5-7b",
        "qwen3:8b",
        "qwen3-8b",
        "qwen3:7b",
        "qwen3-7b",
    ];
    if small_markers.iter().any(|s| m.contains(s)) {
        return ModelTier::Small;
    }

    ModelTier::Unknown
}

/// Read `CHUMP_LESSONS_MIN_TIER` env var to determine the minimum agent tier
/// at which the lessons block should be injected.
///
/// Accepted values (case-insensitive): `frontier`, `capable`, `small`, `none`.
/// `none` (or unset) disables tier gating entirely — no model receives lessons
/// via the tier path. To re-enable, set `CHUMP_LESSONS_MIN_TIER=frontier` or
/// (preferred) opt models in individually via [`lessons_opt_in_for_model`].
///
/// **Default: `None`** (COG-024) — lessons OFF unless explicitly opted-in
/// per-model via `CHUMP_LESSONS_OPT_IN_MODELS`. Per EVAL-027c full Anthropic-
/// family results, no model has UNIVERSAL benefit, so per-model opt-in is
/// the only safe default. Prior `CHUMP_LESSONS_MIN_TIER=frontier` users
/// should switch to per-model opt-in (see docs/COG-024-MIGRATION.md).
pub fn min_tier_for_lessons() -> Option<ModelTier> {
    let raw = std::env::var("CHUMP_LESSONS_MIN_TIER").ok();
    let normalized = raw.as_deref().map(|s| s.trim().to_lowercase());
    match normalized.as_deref() {
        Some("none") | Some("off") | Some("disabled") => None,
        Some("small") => Some(ModelTier::Small),
        Some("capable") => Some(ModelTier::Capable),
        Some("frontier") => Some(ModelTier::Frontier),
        Some(_) => None,
        None => None,
    }
}

/// COG-024: per-model opt-in lookup. Returns the validated lessons variant
/// (e.g. `"cog016"`, `"v1"`, `"sake"`) for `model_id` if it appears in the
/// `CHUMP_LESSONS_OPT_IN_MODELS` CSV, else `None`.
///
/// CSV format: `model_id:variant,model_id:variant,...`
///
/// Examples:
/// - `claude-haiku-4-5:cog016,claude-opus-4-5:cog016` — both opted in
/// - `claude-haiku-4-5:cog016` — haiku only
///
/// Matching is **case-insensitive substring** on the model_id portion (same
/// semantics as [`model_tier`]) so it survives provider variations like
/// `claude-haiku-4-5-20251001`. Malformed entries (no colon, empty halves)
/// are silently skipped.
pub fn lessons_opt_in_for_model(model_id: &str) -> Option<String> {
    let raw = std::env::var("CHUMP_LESSONS_OPT_IN_MODELS").ok()?;
    let needle = model_id.to_lowercase();
    if needle.is_empty() {
        return None;
    }
    for entry in raw.split(',') {
        let entry = entry.trim();
        if entry.is_empty() {
            continue;
        }
        let (id, variant) = match entry.split_once(':') {
            Some(pair) => pair,
            None => continue, // malformed — skip
        };
        let id = id.trim().to_lowercase();
        let variant = variant.trim();
        if id.is_empty() || variant.is_empty() {
            continue;
        }
        if needle.contains(&id) {
            return Some(variant.to_string());
        }
    }
    None
}

/// INFRA-016: family-level deny-list. Returns `true` when `model_id` contains
/// any family name from `CHUMP_LESSONS_DENY_FAMILIES` (comma-separated,
/// case-insensitive substring match — same semantics as the opt-in CSV).
///
/// When the env var is **unset**, the default deny-list is `["deepseek"]` —
/// protecting DeepSeek architectures where EVAL-071 preliminary shows a -23 pp
/// correctness regression from lesson injection. Set `CHUMP_LESSONS_DENY_FAMILIES`
/// to an explicit empty string (`""`) to disable even the default.
///
/// This check short-circuits both the opt-in-model path and the tier-gate path
/// in `lessons_enabled_for_model`. The deny-list wins over explicit opt-in so
/// operators get a safe-by-default escape hatch when per-family evidence is
/// negative (EVAL-074 will re-open DeepSeek once data is in).
pub fn lessons_family_denied(model_id: &str) -> bool {
    let raw =
        std::env::var("CHUMP_LESSONS_DENY_FAMILIES").unwrap_or_else(|_| "deepseek".to_string());
    let needle = model_id.to_lowercase();
    for family in raw.split(',') {
        let family = family.trim().to_lowercase();
        if !family.is_empty() && needle.contains(&family) {
            return true;
        }
    }
    false
}

/// Resolve the agent model id from environment. Tries `CHUMP_AGENT_MODEL`
/// first (explicit chump-side override), then `OPENAI_MODEL` (the standard
/// OpenAI-compat backend env var).
pub fn current_agent_model() -> String {
    std::env::var("CHUMP_AGENT_MODEL")
        .or_else(|_| std::env::var("OPENAI_MODEL"))
        .unwrap_or_default()
}

/// COG-016 / COG-024 unified gate: should the lessons block be injected for
/// the current agent model?
///
/// Returns true iff the [`reflection_injection_enabled`] kill-switch is on
/// AND **either** of:
///   (a) the model is explicitly opted-in via [`lessons_opt_in_for_model`]
///       (CHUMP_LESSONS_OPT_IN_MODELS CSV — preferred path post-COG-024), OR
///   (b) the legacy tier gate [`min_tier_for_lessons`] passes (only active
///       when `CHUMP_LESSONS_MIN_TIER` is explicitly set to a tier name).
///
/// `Unknown` model tiers are NEVER injected via the tier path (safer
/// default — don't surprise an unknown environment with extra prompt
/// content). The opt-in CSV bypasses this — if you name a model explicitly,
/// you want it on.
///
/// COG-024: with `CHUMP_LESSONS_MIN_TIER` unset, [`min_tier_for_lessons`]
/// returns `None`, so only the opt-in CSV can enable injection. Default is
/// OFF for every model — see docs/COG-024-MIGRATION.md.
pub fn lessons_enabled_for_model(model_id: &str) -> bool {
    if !reflection_injection_enabled() {
        return false;
    }
    // INFRA-016: family deny-list short-circuits opt-in and tier gate.
    if lessons_family_denied(model_id) {
        tracing::warn!(
            model = model_id,
            "lessons suppressed — family denied (CHUMP_LESSONS_DENY_FAMILIES)"
        );
        return false;
    }
    // (a) per-model opt-in (preferred path)
    if lessons_opt_in_for_model(model_id).is_some() {
        return true;
    }
    // (b) legacy tier gate — only fires if CHUMP_LESSONS_MIN_TIER is set
    let min = match min_tier_for_lessons() {
        None => return false, // COG-024: default OFF
        Some(t) => t,
    };
    let tier = model_tier(model_id);
    if tier == ModelTier::Unknown {
        return false;
    }
    tier >= min
}

// ---------------------------------------------------------------------------
// MEM-006: lessons-loaded-at-spawn
//
// PRODUCT-006 (PR #125) writes reflection lessons into chump_improvement_targets
// via harvest-synthesis-lessons.sh. MEM-006 closes the loop by reading top-N
// relevant lessons at agent spawn-time, not just on per-task assembly.
//
// This is the SECOND opt-in path (alongside CHUMP_LESSONS_OPT_IN_MODELS). Both
// require explicit env-var activation — neither fires by default. This
// preserves the COG-024 safe-by-default policy: zero injection unless the
// operator actively chose it.
// ---------------------------------------------------------------------------

/// Default cap for spawn-loaded lessons. Same as the per-task LESSONS_LIMIT
/// (5) in prompt_assembler.rs — keeps prompt overhead bounded.
const SPAWN_LESSONS_DEFAULT_N: usize = 5;
/// Hard ceiling. Operators can request fewer, but never more — past 20 the
/// prompt starts crowding out the actual task.
const SPAWN_LESSONS_MAX_N: usize = 20;

/// Read CHUMP_LESSONS_AT_SPAWN_N env var. Returns `None` when unset (the
/// default — spawn-loaded lessons OFF). When set, the value is clamped to
/// [0, SPAWN_LESSONS_MAX_N]. Malformed values fall back to the default (5).
///
/// COG-024 invariant: returning `None` here means the spawn-lessons path is
/// completely silent. Callers MUST treat None as "do nothing."
pub fn spawn_lessons_n() -> Option<usize> {
    let raw = std::env::var("CHUMP_LESSONS_AT_SPAWN_N").ok()?;
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let parsed: usize = trimmed.parse().unwrap_or(SPAWN_LESSONS_DEFAULT_N);
    Some(parsed.min(SPAWN_LESSONS_MAX_N))
}

/// Map a reflection's `outcome_class` string to a quality score (MEM-009).
///
/// Scoring:
///   "pass" | "success" → 1.0
///   "partial"          → 0.5
///   "failure" | "abandoned" | other → 0.0
///   NULL / missing     → 0.5 (conservative default)
///
/// Used by [`load_spawn_lessons`] to filter lessons by parent-reflection quality.
fn outcome_quality(outcome_class: Option<&str>) -> f64 {
    match outcome_class {
        None | Some("") => 0.5,
        Some("pass") | Some("success") => 1.0,
        Some("partial") => 0.5,
        _ => 0.0,
    }
}

/// Read `CHUMP_LESSON_QUALITY_THRESHOLD` env var (float 0.0–1.0).
/// Returns 0.0 when unset (no filter — all lessons pass).
/// Clamps the parsed value to [0.0, 1.0].
/// Malformed values fall back to 0.0 (safe default — same as unset).
pub fn lesson_quality_threshold() -> f64 {
    let raw = match std::env::var("CHUMP_LESSON_QUALITY_THRESHOLD") {
        Ok(s) => s,
        Err(_) => return 0.0,
    };
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return 0.0;
    }
    let parsed: f64 = trimmed.parse().unwrap_or(0.0);
    parsed.clamp(0.0, 1.0)
}

/// Load the top-N most-relevant improvement targets for a spawning agent.
///
/// Ranking heuristic (recency × frequency surrogate):
///   score = COUNT(*) by directive * exp(-age_days / 7.0)
///
/// Lessons that recur across multiple reflections in the past week outrank
/// one-off lessons from a month ago. This favors directives that the
/// reflection harvester has independently confirmed multiple times.
///
/// `domain` filter behaviour:
///   - empty / "any" / "global" → all high+medium lessons regardless of scope
///   - non-empty → exact scope match OR universal (NULL/empty) scope.
///     Mirrors the lax-scope behaviour of [`load_recent_high_priority_targets`].
///
/// `quality_threshold` — minimum quality score [0.0, 1.0] for the parent
/// reflection. Quality is derived from the parent reflection's `outcome_class`:
///   "pass"/"success" = 1.0, "partial" = 0.5, "failure"/"abandoned" = 0.0,
///   NULL/missing = 0.5. Pass 0.0 to load all lessons regardless of quality
/// (the default / backward-compatible behaviour). The env var
/// `CHUMP_LESSON_QUALITY_THRESHOLD` is read by the prompt assembler and passed
/// here; individual callers can also supply an explicit value for testing.
///
/// Always excludes ab_seed reflections (consistent with the per-task path).
/// `max_n` is clamped to [0, SPAWN_LESSONS_MAX_N].
///
/// Returns empty Vec when the DB is unreachable or the query produces no rows
/// — never errors out at the callsite. Spawn-time injection is best-effort:
/// a missing DB must not block agent startup.
pub fn load_spawn_lessons(domain: &str, max_n: usize) -> Vec<ImprovementTarget> {
    // EVAL-056: memory ablation gate — bypass flag short-circuits before any DB work.
    if crate::env_flags::chump_bypass_spawn_lessons() {
        return Vec::new();
    }
    load_spawn_lessons_with_threshold(domain, max_n, lesson_quality_threshold())
}

/// Inner implementation of [`load_spawn_lessons`] with an explicit quality
/// threshold. Kept separate so tests can supply any threshold without touching
/// the env var (which would require serial test coordination).
pub fn load_spawn_lessons_with_threshold(
    domain: &str,
    max_n: usize,
    quality_threshold: f64,
) -> Vec<ImprovementTarget> {
    let max_n = max_n.min(SPAWN_LESSONS_MAX_N);
    if max_n == 0 {
        return Vec::new();
    }
    let conn = match open_db() {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };

    let domain_norm = domain.trim().to_lowercase();
    let use_domain_filter =
        !domain_norm.is_empty() && domain_norm != "any" && domain_norm != "global";

    // Clamp threshold into [0.0, 1.0] in case caller passes an out-of-range value.
    let quality_threshold = quality_threshold.clamp(0.0, 1.0);

    // Build the quality filter clause. We join chump_improvement_targets with
    // chump_reflections to access outcome_class. The CASE expression maps
    // outcome_class to a numeric quality score:
    //   'pass'/'success' → 1.0, 'partial' → 0.5, NULL/'' → 0.5, else → 0.0
    // When threshold = 0.0, the condition is always true (no-op filter).
    //
    // Recency-frequency ranking: per-directive count * exp(-age_days/7)
    // SQLite has no exp(); approximate with 1.0 / (1.0 + age_days / 7.0).
    // Equivalent ordering for our purposes (monotonic decreasing in age).
    // MIN(priority) over text picks 'high' over 'medium' lexicographically
    // (h < m), which happens to give us the semantically correct "promote a
    // directive to its highest-ever priority." MAX(scope) collapses to any
    // representative scope when the same directive appears with multiple.
    // Column order MUST match `row_from_target` (directive, priority, scope,
    // actioned_as). We embed NULL for actioned_as (spawn lessons don't carry
    // a per-instance action trace — they're aggregated across reflections).
    // Ranking columns (freq, latest_at, score) trail and are only used by
    // ORDER BY, never read back.
    let quality_clause = if quality_threshold <= 0.0 {
        // No-op: include everything — avoid the join cost when not needed.
        String::new()
    } else {
        format!(
            "  AND reflection_id IN (
              SELECT id FROM chump_reflections
              WHERE CASE
                WHEN outcome_class IS NULL OR outcome_class = '' THEN 0.5
                WHEN outcome_class = 'pass' OR outcome_class = 'success' THEN 1.0
                WHEN outcome_class = 'partial' THEN 0.5
                ELSE 0.0
              END >= {quality_threshold}
            )"
        )
    };

    let sql_common = format!(
        "
        SELECT directive,
               MIN(priority) AS priority,
               MAX(scope) AS scope,
               NULL AS actioned_as,
               COUNT(*) AS freq,
               MAX(created_at) AS latest_at,
               (CAST(COUNT(*) AS REAL) /
                (1.0 + (julianday('now') - julianday(MAX(created_at))) / 7.0)) AS score
        FROM chump_improvement_targets
        WHERE priority IN ('high', 'medium')
          AND reflection_id NOT IN (
              SELECT id FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%'
          )
        {quality_clause}"
    );

    let rows: Result<Vec<ImprovementTarget>, rusqlite::Error> = if use_domain_filter {
        let q = format!(
            "{sql_common}
              AND (scope IS NULL OR scope = '' OR LOWER(scope) = ?1)
            GROUP BY directive
            ORDER BY score DESC, latest_at DESC
            LIMIT ?2"
        );
        let mut stmt = match conn.prepare(&q) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        let iter = match stmt.query_map(
            rusqlite::params![domain_norm, max_n as i64],
            row_from_target,
        ) {
            Ok(it) => it,
            Err(_) => return Vec::new(),
        };
        iter.collect()
    } else {
        let q = format!(
            "{sql_common}
            GROUP BY directive
            ORDER BY score DESC, latest_at DESC
            LIMIT ?1"
        );
        let mut stmt = match conn.prepare(&q) {
            Ok(s) => s,
            Err(_) => return Vec::new(),
        };
        let iter = match stmt.query_map(rusqlite::params![max_n as i64], row_from_target) {
            Ok(it) => it,
            Err(_) => return Vec::new(),
        };
        iter.collect()
    };

    rows.unwrap_or_default()
}

/// COG-011d variant (b): when ON, only inject lessons whose `scope` exactly
/// matches the current `tool_hint`. Excludes the universal (NULL-scope)
/// lessons that get returned by default. Tests the hypothesis that
/// "irrelevant lessons act as noise" — if true, strict-scope mode should
/// recover some of the -0.30 gotcha penalty seen in COG-011b.
///
/// Default OFF (current behavior — universal lessons surface for every prompt).
pub fn reflection_strict_scope_enabled() -> bool {
    matches!(
        std::env::var("CHUMP_REFLECTION_STRICT_SCOPE").as_deref(),
        Ok("1") | Ok("true") | Ok("on")
    )
}

/// Persist a Reflection plus its improvement targets in a single transaction.
/// Returns the new reflection_id. On any error, the whole insert rolls back.
pub fn save_reflection(reflection: &Reflection, task_id: Option<i64>) -> Result<i64> {
    let mut conn = open_db()?;
    let tx = conn.transaction()?;
    tx.execute(
        "INSERT INTO chump_reflections (
            episode_id, task_id, intended_goal, observed_outcome,
            outcome_class, error_pattern, hypothesis,
            surprisal_at_reflect, confidence_at_reflect
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        rusqlite::params![
            reflection.episode_id,
            task_id,
            reflection.intended_goal,
            reflection.observed_outcome,
            reflection.outcome_class.as_str(),
            reflection.error_pattern.map(|p| p.as_str()),
            reflection.hypothesis,
            reflection.surprisal_at_reflect,
            reflection.confidence_at_reflect,
        ],
    )?;
    let reflection_id = tx.last_insert_rowid();
    for target in &reflection.improvements {
        tx.execute(
            "INSERT INTO chump_improvement_targets (
                reflection_id, directive, priority, scope, actioned_as
             ) VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![
                reflection_id,
                target.directive,
                target.priority.as_str(),
                target.scope,
                target.actioned_as,
            ],
        )?;
    }
    tx.commit()?;
    Ok(reflection_id)
}

/// Load the most-recent high+medium priority improvement targets, capped at `limit`.
///
/// `scope_filter`:
///   - `Some(scope)` + `CHUMP_REFLECTION_STRICT_SCOPE=1` → exact scope matches only
///     (no NULL-scope universal lessons). The COG-011d variant (b) test path.
///   - `Some(scope)` + default → exact match OR NULL/empty scope (universal lessons
///     ride along). Original COG-007 behavior.
///   - `None` + `CHUMP_REFLECTION_STRICT_SCOPE=1` → return empty (no signal to
///     filter on, strict mode refuses to inject noise).
///   - `None` + default → all high+medium-priority targets regardless of scope.
///
/// Order: priority DESC (high → medium), then created_at DESC (freshest wins).
/// Low-priority targets are never returned — they exist for analytics only.
pub fn load_recent_high_priority_targets(
    limit: usize,
    scope_filter: Option<&str>,
) -> Result<Vec<ImprovementTarget>> {
    let conn = open_db()?;
    let limit = limit.min(20);
    let strict = reflection_strict_scope_enabled();

    let rows: Vec<ImprovementTarget> = match (scope_filter, strict) {
        (Some(scope), true) => {
            // Strict: exact scope match only. No NULL/empty scope catch-all.
            // Exclude ab_seed rows — those are only for consciousness-gated injection.
            let q = "SELECT directive, priority, scope, actioned_as
                     FROM chump_improvement_targets
                     WHERE priority IN ('high', 'medium')
                       AND scope = ?1
                       AND reflection_id NOT IN (
                           SELECT id FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%'
                       )
                     ORDER BY CASE priority WHEN 'high' THEN 0 ELSE 1 END,
                              created_at DESC
                     LIMIT ?2";
            let mut stmt = conn.prepare(q)?;
            let iter = stmt.query_map(rusqlite::params![scope, limit as i64], row_from_target)?;
            let mut out = Vec::new();
            for r in iter {
                out.push(r?);
            }
            out
        }
        (Some(scope), false) => {
            // Default: exact scope match OR NULL/empty (universal).
            // Exclude ab_seed rows — those are only for consciousness-gated injection.
            let q = "SELECT directive, priority, scope, actioned_as
                     FROM chump_improvement_targets
                     WHERE priority IN ('high', 'medium')
                       AND (scope IS NULL OR scope = '' OR scope = ?1)
                       AND reflection_id NOT IN (
                           SELECT id FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%'
                       )
                     ORDER BY CASE priority WHEN 'high' THEN 0 ELSE 1 END,
                              created_at DESC
                     LIMIT ?2";
            let mut stmt = conn.prepare(q)?;
            let iter = stmt.query_map(rusqlite::params![scope, limit as i64], row_from_target)?;
            let mut out = Vec::new();
            for r in iter {
                out.push(r?);
            }
            out
        }
        (None, true) => {
            // Strict + no signal → return empty. Caller's lesson block stays empty,
            // matching the COG-011b "lessons hurt when injected indiscriminately" finding.
            Vec::new()
        }
        (None, false) => {
            // No filter: all high/medium targets.
            // Exclude ab_seed rows — those are only for consciousness-gated injection.
            let q = "SELECT directive, priority, scope, actioned_as
                     FROM chump_improvement_targets
                     WHERE priority IN ('high', 'medium')
                       AND reflection_id NOT IN (
                           SELECT id FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%'
                       )
                     ORDER BY CASE priority WHEN 'high' THEN 0 ELSE 1 END,
                              created_at DESC
                     LIMIT ?1";
            let mut stmt = conn.prepare(q)?;
            let iter = stmt.query_map(rusqlite::params![limit as i64], row_from_target)?;
            let mut out = Vec::new();
            for r in iter {
                out.push(r?);
            }
            out
        }
    };
    Ok(rows)
}

fn row_from_target(r: &rusqlite::Row) -> Result<ImprovementTarget, rusqlite::Error> {
    let priority_str: String = r.get(1)?;
    let priority = match priority_str.as_str() {
        "high" => Priority::High,
        "low" => Priority::Low,
        _ => Priority::Medium,
    };
    Ok(ImprovementTarget {
        directive: r.get(0)?,
        priority,
        scope: r.get::<_, Option<String>>(2)?.filter(|s| !s.is_empty()),
        actioned_as: r.get::<_, Option<String>>(3)?.filter(|s| !s.is_empty()),
    })
}

// ---------------------------------------------------------------------------
// EVAL-030: Task-class-aware lessons gating
// ---------------------------------------------------------------------------
//
// EVAL-029 mechanism analysis (docs/eval/EVAL-029-neuromod-task-drilldown.md)
// showed the v1 lessons block hurts the neuromod fixture by 10–16 pp on
// `is_correct` across 4 models. The harm concentrates in two task classes:
//
//   1. **Conditional-chain prompts** ("do X, if it fails do Y, then if Y fails
//      do Z") — the perception directive "ask one clarifying question rather
//      than guessing" causes early-stopping on multi-step chains. Suppress
//      that specific directive when the user prompt contains 2+ conditional
//      markers or an explicit step-numbered chain.
//
//   2. **Monosyllabic chat tokens** (`lol`, `sup`, `k thx`) — the lessons
//      block dwarfs the prompt and the agent over-formalizes the response.
//      Skip the entire block when the prompt is shorter than 30 chars.
//
// Both detectors are pure heuristics over the raw user prompt — no LLM call,
// no DB read. Default ON; `CHUMP_LESSONS_TASK_AWARE=0` disables the gating
// so harness sweeps can re-measure the v1 baseline.

/// Returns true when the prompt looks like a multi-step conditional chain
/// (2+ conditional markers OR explicit step-numbered sequence). On these
/// tasks the perception "ask one clarifying question" directive harms
/// outcomes by triggering early-stopping mid-chain.
pub fn is_conditional_chain(prompt: &str) -> bool {
    let lc = prompt.to_lowercase();
    let cond_markers = [
        "if it fails",
        "if that fails",
        "then if",
        "else if",
        "if not",
    ];
    let cond_count = cond_markers.iter().filter(|m| lc.contains(*m)).count();
    let step_pattern = lc.contains("step 1") && lc.contains("step 2");
    cond_count >= 2 || step_pattern
}

/// Returns true when the prompt is a trivial chat token (under 30 chars
/// trimmed). On these the lessons block dwarfs the actual input and the
/// agent over-formalizes — best to skip lessons entirely.
pub fn is_trivial_token(prompt: &str) -> bool {
    prompt.trim().len() < 30
}

/// Whether EVAL-030 task-class-aware lessons gating is active. Default ON;
/// set `CHUMP_LESSONS_TASK_AWARE=0` to restore the v1-uniform behavior for
/// A/B harness sweeps.
pub fn task_aware_lessons_enabled() -> bool {
    !matches!(
        std::env::var("CHUMP_LESSONS_TASK_AWARE")
            .unwrap_or_default()
            .as_str(),
        "0" | "false" | "off" | "no"
    )
}

/// Heuristic: does this directive read like the perception "ask one
/// clarifying question" line that EVAL-029 identified as harmful on
/// conditional-chain tasks? We match on the substring rather than equality
/// so paraphrases survive (e.g. "ask a clarifying question first").
fn is_perception_clarify_directive(directive: &str) -> bool {
    let lc = directive.to_lowercase();
    lc.contains("clarifying question") || lc.contains("clarify") && lc.contains("ambig")
}

/// Render a list of improvement targets as a system-prompt block. Returns
/// empty string when input is empty so callers can `if !block.is_empty()` cheaply.
///
/// Format chosen for low-distraction injection: short header, bullet list,
/// priority and scope inlined when present. Designed to be appended to the
/// existing system prompt, not to replace any task-planner block.
pub fn format_lessons_block(targets: &[ImprovementTarget]) -> String {
    format_lessons_block_with_prompt(targets, None)
}

/// EVAL-030: variant of [`format_lessons_block`] that accepts the raw user
/// prompt for task-class-aware suppression. When `user_prompt` is `Some` and
/// `task_aware_lessons_enabled()` is true:
///
/// * trivial-token prompts → return empty string (skip the block entirely)
/// * conditional-chain prompts → filter out the perception "ask one
///   clarifying question" directive (the rest of the block still renders)
///
/// `user_prompt = None` and `CHUMP_LESSONS_TASK_AWARE=0` both fall through
/// to the legacy uniform behavior.
pub fn format_lessons_block_with_prompt(
    targets: &[ImprovementTarget],
    user_prompt: Option<&str>,
) -> String {
    // EVAL-030 gating — runs only when caller passes a prompt and the env
    // var hasn't disabled the feature.
    let filtered: Vec<ImprovementTarget>;
    let effective_targets: &[ImprovementTarget] = match user_prompt {
        Some(p) if task_aware_lessons_enabled() => {
            if is_trivial_token(p) {
                // Skip the entire block on monosyllabic chat — EVAL-029 row 4–13.
                return String::new();
            }
            if is_conditional_chain(p) {
                // Drop the harmful perception directive only; keep the rest.
                filtered = targets
                    .iter()
                    .filter(|t| !is_perception_clarify_directive(&t.directive))
                    .cloned()
                    .collect();
                &filtered[..]
            } else {
                targets
            }
        }
        _ => targets,
    };
    if effective_targets.is_empty() {
        return String::new();
    }
    let targets = effective_targets;
    // COG-016: explicit anti-hallucination guardrail prepended to the lessons
    // header. The n=100 sweep showed the original block (without this line)
    // reliably increased fake-tool-call emission by +0.14 on weak agents
    // (haiku-4-5, n=600 trials, p<0.05 across 3 fixtures). The directive
    // tells the model NOT to emit fake tool-call markup when it has no
    // actual tool access — addressing the failure mode observed in the
    // forensic in docs/CONSCIOUSNESS_AB_RESULTS.md.
    let mut out = String::from(
        "## Lessons from prior episodes\n\
         The following directives came from structured reflections on previous tasks. \
         Apply them when relevant; do not narrate that you are applying them.\n\
         \n\
         IMPORTANT: if you do not have actual tool access in this context, do NOT \
         emit `<function_calls>`, `<tool_call>`, `<tool_use>`, or similar markup. \
         Instead, describe in plain prose what you would do if tools were available, \
         and acknowledge that you cannot execute commands directly.\n",
    );
    for t in targets {
        let scope = match &t.scope {
            Some(s) if !s.is_empty() => format!(" [{}]", s),
            _ => String::new(),
        };
        out.push_str(&format!(
            "- ({}){} {}\n",
            t.priority.as_str(),
            scope,
            t.directive
        ));
    }
    out
}

// ---------------------------------------------------------------------------
// COG-014: AB harness lesson seeding
// ---------------------------------------------------------------------------

/// A single authored directive for AB harness seeding.
#[derive(Debug, serde::Deserialize)]
pub struct SeedDirective {
    pub directive: String,
    /// "high" | "medium" | "low"
    pub priority: String,
    pub scope: Option<String>,
}

/// JSON structure for a domain lesson seed file.
#[derive(Debug, serde::Deserialize)]
pub struct LessonSeedFile {
    pub domain: String,
    pub directives: Vec<SeedDirective>,
}

/// Tag written to `error_pattern` for AB-seeded reflections so they can be
/// deleted cleanly without touching real reflections.
const AB_SEED_TAG_PREFIX: &str = "ab_seed:";

/// Remove all AB-seeded reflections and their associated improvement targets,
/// and also remove causal lessons seeded for AB testing.
/// Returns the number of rows deleted from `chump_reflections`.
///
/// Explicitly deletes from `chump_improvement_targets` first because SQLite
/// FK enforcement (`PRAGMA foreign_keys`) is off by default, so `ON DELETE
/// CASCADE` does not fire automatically.
pub fn clear_ab_seed_lessons() -> Result<usize> {
    let mut conn = open_db()?;
    let tx = conn.transaction()?;
    // Delete orphaned targets first — FK cascade may not be active.
    tx.execute(
        "DELETE FROM chump_improvement_targets \
         WHERE reflection_id IN ( \
             SELECT id FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%' \
         )",
        [],
    )?;
    let deleted = tx.execute(
        "DELETE FROM chump_reflections WHERE error_pattern LIKE 'ab_seed:%'",
        [],
    )?;
    // Also clear causal lessons seeded for AB testing (task_type = 'ab_seed').
    tx.execute(
        "DELETE FROM chump_causal_lessons WHERE task_type = 'ab_seed'",
        [],
    )?;
    tx.commit()?;
    Ok(deleted)
}

/// Seed domain-specific lessons into `chump_reflections` + `chump_improvement_targets`
/// AND into `chump_causal_lessons` for use by the A/B harness.
///
/// The improvement-targets path is gated only by reflection injection (not consciousness).
/// The causal-lessons path (`task_type = 'ab_seed'`) is the consciousness-gated path
/// used by `find_relevant_lessons` as a fallback when keyword matching returns nothing.
/// Creates a single parent reflection tagged with `error_pattern = 'ab_seed:<domain>'`
/// so it can be cleared later.
///
/// Returns the number of directives inserted.
pub fn seed_ab_lessons(domain: &str, directives: &[SeedDirective]) -> Result<usize> {
    if directives.is_empty() {
        return Ok(0);
    }
    let mut conn = open_db()?;
    let tx = conn.transaction()?;
    tx.execute(
        "INSERT INTO chump_reflections (
            intended_goal, observed_outcome, outcome_class, error_pattern, hypothesis
         ) VALUES (?1, 'seeded', 'ab_seed', ?2, ?3)",
        rusqlite::params![
            format!("AB harness seed — {domain}"),
            format!("{AB_SEED_TAG_PREFIX}{domain}"),
            format!("Task-specific lessons for {domain} domain A/B testing"),
        ],
    )?;
    let reflection_id = tx.last_insert_rowid();

    let mut count = 0usize;
    for d in directives {
        tx.execute(
            "INSERT INTO chump_improvement_targets (reflection_id, directive, priority, scope)
             VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![reflection_id, d.directive, d.priority, d.scope],
        )?;
        // Also seed into chump_causal_lessons so the consciousness-gated
        // lessons_for_context_with_ids() path can find them via the ab_seed fallback.
        tx.execute(
            "INSERT INTO chump_causal_lessons (task_type, action_taken, lesson, confidence)
             VALUES ('ab_seed', ?1, ?2, 0.95)",
            rusqlite::params![d.scope.as_deref().unwrap_or(""), d.directive],
        )?;
        count += 1;
    }
    tx.commit()?;
    Ok(count)
}

/// Load a [`LessonSeedFile`] from a JSON path and seed it into the DB.
/// Convenience wrapper used by the `--seed-ab-lessons` CLI.
pub fn seed_ab_lessons_from_file(path: &std::path::Path) -> Result<usize> {
    let content = std::fs::read_to_string(path)?;
    let seed: LessonSeedFile = serde_json::from_str(&content)?;
    seed_ab_lessons(&seed.domain, &seed.directives)
}

#[cfg(test)]
mod tests {
    //! Tests use a temp DB root so they never touch the user's real chump_memory.db.
    //! `serial(reflection_db)` because all tests share the same TEST_DB_ROOT
    //! thread-local — running them in parallel would interleave inserts.

    use super::*;
    use serial_test::serial;

    /// Per-test fresh DB root. Uses uuid like episode_db tests so concurrent
    /// runs (or repeated runs after failure) never collide.
    fn fresh_test_root() {
        let dir = std::env::temp_dir().join(format!(
            "chump_reflection_db_test_{}",
            uuid::Uuid::new_v4().simple()
        ));
        let _ = std::fs::create_dir_all(&dir);
        set_test_db_root(Some(dir));
    }

    fn sample_reflection(directive: &str, priority: Priority, scope: Option<&str>) -> Reflection {
        Reflection {
            id: None,
            episode_id: None,
            intended_goal: "test goal".into(),
            observed_outcome: "test outcome".into(),
            outcome_class: OutcomeClass::Failure,
            error_pattern: Some(ErrorPattern::ToolMisuse),
            improvements: vec![ImprovementTarget {
                directive: directive.into(),
                priority,
                scope: scope.map(String::from),
                actioned_as: None,
            }],
            hypothesis: "test hypothesis".into(),
            surprisal_at_reflect: Some(0.5),
            confidence_at_reflect: Some(0.7),
            created_at: "2026-04-17T00:00:00Z".into(),
        }
    }

    #[test]
    #[serial(reflection_db)]
    fn save_then_load_returns_high_priority_first() {
        fresh_test_root();
        let mut low = sample_reflection("low priority lesson", Priority::Low, None);
        // Tag a low-priority target — it must NOT appear in load.
        low.improvements[0].priority = Priority::Low;
        save_reflection(&low, Some(1)).expect("test invariant");

        let med = sample_reflection("medium lesson", Priority::Medium, None);
        save_reflection(&med, Some(2)).expect("test invariant");

        let high = sample_reflection("HIGH urgency lesson", Priority::High, None);
        save_reflection(&high, Some(3)).expect("test invariant");

        let targets = load_recent_high_priority_targets(10, None).expect("test invariant");
        assert_eq!(targets.len(), 2, "low-priority must be filtered out");
        assert_eq!(targets[0].directive, "HIGH urgency lesson");
        assert_eq!(targets[0].priority, Priority::High);
        assert_eq!(targets[1].directive, "medium lesson");
    }

    #[test]
    #[serial(reflection_db)]
    fn scope_filter_includes_null_scope_targets() {
        fresh_test_root();
        // Universal lesson (no scope) — must always surface.
        save_reflection(
            &sample_reflection("universal lesson", Priority::High, None),
            None,
        )
        .expect("test invariant");
        // Tool-scoped lesson — surfaces only when scope matches.
        save_reflection(
            &sample_reflection("patch-specific lesson", Priority::High, Some("patch_file")),
            None,
        )
        .expect("test invariant");
        // Different-tool lesson — must NOT surface for patch_file scope.
        save_reflection(
            &sample_reflection("git-specific lesson", Priority::High, Some("git_commit")),
            None,
        )
        .expect("test invariant");

        let targets =
            load_recent_high_priority_targets(10, Some("patch_file")).expect("test invariant");
        let directives: Vec<_> = targets.iter().map(|t| t.directive.as_str()).collect();
        assert!(directives.contains(&"universal lesson"));
        assert!(directives.contains(&"patch-specific lesson"));
        assert!(
            !directives.contains(&"git-specific lesson"),
            "scope filter must exclude other tools' lessons"
        );
    }

    #[test]
    #[serial(reflection_db)]
    fn save_persists_all_typed_fields_roundtrip() {
        fresh_test_root();
        let r = sample_reflection(
            "verify file exists before patch",
            Priority::High,
            Some("patch_file"),
        );
        let id = save_reflection(&r, Some(42)).expect("test invariant");
        assert!(id > 0);

        let targets = load_recent_high_priority_targets(10, None).expect("test invariant");
        assert_eq!(targets.len(), 1);
        let t = &targets[0];
        assert_eq!(t.directive, "verify file exists before patch");
        assert_eq!(t.priority, Priority::High);
        assert_eq!(t.scope.as_deref(), Some("patch_file"));
    }

    #[test]
    #[serial(reflection_db)]
    fn load_with_no_data_returns_empty() {
        fresh_test_root();
        let targets = load_recent_high_priority_targets(10, None).expect("test invariant");
        assert!(targets.is_empty());
    }

    #[test]
    #[serial(reflection_db)]
    fn limit_respected() {
        fresh_test_root();
        for i in 0..5 {
            save_reflection(
                &sample_reflection(&format!("lesson {}", i), Priority::High, None),
                None,
            )
            .expect("test invariant");
        }
        let targets = load_recent_high_priority_targets(3, None).expect("test invariant");
        assert_eq!(targets.len(), 3);
    }

    #[test]
    #[serial(reflection_db)]
    fn reflection_injection_default_on() {
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        assert!(reflection_injection_enabled());
    }

    #[test]
    #[serial(reflection_db)]
    fn reflection_injection_off_via_env() {
        std::env::set_var("CHUMP_REFLECTION_INJECTION", "0");
        assert!(!reflection_injection_enabled());
        std::env::set_var("CHUMP_REFLECTION_INJECTION", "false");
        assert!(!reflection_injection_enabled());
        std::env::set_var("CHUMP_REFLECTION_INJECTION", "off");
        assert!(!reflection_injection_enabled());
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
    }

    // ── COG-011d variant (b): strict-scope mode ──────────────────────────

    #[test]
    #[serial(reflection_db)]
    fn strict_scope_default_off() {
        std::env::remove_var("CHUMP_REFLECTION_STRICT_SCOPE");
        assert!(!reflection_strict_scope_enabled());
    }

    #[test]
    #[serial(reflection_db)]
    fn strict_scope_on_via_env() {
        for v in ["1", "true", "on"] {
            std::env::set_var("CHUMP_REFLECTION_STRICT_SCOPE", v);
            assert!(reflection_strict_scope_enabled(), "expected on for {v}");
        }
        std::env::remove_var("CHUMP_REFLECTION_STRICT_SCOPE");
    }

    #[test]
    #[serial(reflection_db)]
    fn strict_scope_excludes_universal_lessons() {
        // Default (non-strict) returns BOTH a NULL-scope lesson and a
        // patch_file-scoped one when filter is "patch_file". Strict mode
        // returns ONLY the exact match.
        fresh_test_root();
        save_reflection(
            &sample_reflection("universal directive", Priority::High, None),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection(
                "patch-specific directive",
                Priority::High,
                Some("patch_file"),
            ),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection("git-specific directive", Priority::High, Some("git_commit")),
            None,
        )
        .expect("test invariant");

        std::env::remove_var("CHUMP_REFLECTION_STRICT_SCOPE");
        let lax =
            load_recent_high_priority_targets(10, Some("patch_file")).expect("test invariant");
        let lax_directives: Vec<_> = lax.iter().map(|t| t.directive.as_str()).collect();
        assert!(lax_directives.contains(&"universal directive"));
        assert!(lax_directives.contains(&"patch-specific directive"));
        assert!(!lax_directives.contains(&"git-specific directive"));

        std::env::set_var("CHUMP_REFLECTION_STRICT_SCOPE", "1");
        let strict =
            load_recent_high_priority_targets(10, Some("patch_file")).expect("test invariant");
        let strict_directives: Vec<_> = strict.iter().map(|t| t.directive.as_str()).collect();
        assert_eq!(
            strict_directives,
            vec!["patch-specific directive"],
            "strict mode must exclude universal AND off-scope lessons"
        );
        std::env::remove_var("CHUMP_REFLECTION_STRICT_SCOPE");
    }

    #[test]
    #[serial(reflection_db)]
    fn strict_scope_with_no_filter_returns_empty() {
        // Strict mode + no scope hint → nothing to filter on, so refuse to
        // inject. The "noise reduction" hypothesis behind COG-011d (b).
        fresh_test_root();
        save_reflection(&sample_reflection("any lesson", Priority::High, None), None)
            .expect("test invariant");
        save_reflection(
            &sample_reflection("scoped lesson", Priority::High, Some("patch_file")),
            None,
        )
        .expect("test invariant");

        std::env::set_var("CHUMP_REFLECTION_STRICT_SCOPE", "1");
        let targets = load_recent_high_priority_targets(10, None).expect("test invariant");
        assert!(
            targets.is_empty(),
            "strict mode + None filter should return []"
        );
        std::env::remove_var("CHUMP_REFLECTION_STRICT_SCOPE");
    }

    #[test]
    #[serial(reflection_db)]
    fn format_lessons_block_empty_returns_empty_string() {
        // Pure function — no DB needed. Cheap regression guard so the
        // assembler can `if !block.is_empty()` without surprise newlines.
        let s = format_lessons_block(&[]);
        assert!(s.is_empty());
    }

    // ── COG-014: AB seed helpers ────────────��─────────────────────────────

    #[test]
    #[serial(reflection_db)]
    fn seed_ab_lessons_inserts_and_clears() {
        fresh_test_root();
        let directives = vec![
            SeedDirective {
                directive: "entity lesson one".into(),
                priority: "high".into(),
                scope: Some("perception".into()),
            },
            SeedDirective {
                directive: "entity lesson two".into(),
                priority: "medium".into(),
                scope: Some("perception".into()),
            },
        ];
        let count = seed_ab_lessons("perception", &directives).expect("test invariant");
        assert_eq!(count, 2);

        // Seeded rows land in chump_improvement_targets, but are intentionally
        // excluded from the prompt-assembly path — load_recent_high_priority_targets
        // filters out reflection_ids tagged `ab_seed:*`.  Verify presence via a
        // direct count rather than going through the prompt-assembly query.
        {
            let conn = open_db().expect("test invariant");
            let it_count: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM chump_improvement_targets WHERE scope = 'perception'",
                    [],
                    |row| row.get(0),
                )
                .expect("test invariant");
            assert_eq!(
                it_count, 2,
                "two directives stored in chump_improvement_targets"
            );

            // The consciousness-gated path (chump_causal_lessons) also gets them.
            let cl_count: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM chump_causal_lessons WHERE task_type = 'ab_seed'",
                    [],
                    |row| row.get(0),
                )
                .expect("test invariant");
            assert_eq!(cl_count, 2, "two lessons stored in chump_causal_lessons");
        }
        // Confirm ab_seed rows do NOT bleed through to prompt assembly.
        let visible =
            load_recent_high_priority_targets(10, Some("perception")).expect("test invariant");
        assert!(
            visible.is_empty(),
            "ab_seed rows must be excluded from prompt-assembly path"
        );

        // Clearing removes them without touching other data.
        let deleted = clear_ab_seed_lessons().expect("test invariant");
        assert_eq!(deleted, 1, "one parent reflection row deleted");

        let after = load_recent_high_priority_targets(10, None).expect("test invariant");
        assert!(after.is_empty(), "all seeded targets gone after clear");
    }

    #[test]
    #[serial(reflection_db)]
    fn seed_ab_lessons_empty_slice_is_noop() {
        fresh_test_root();
        let count = seed_ab_lessons("perception", &[]).expect("test invariant");
        assert_eq!(count, 0);
    }

    #[test]
    #[serial(reflection_db)]
    fn clear_ab_seed_lessons_zero_when_nothing_seeded() {
        fresh_test_root();
        let deleted = clear_ab_seed_lessons().expect("test invariant");
        assert_eq!(deleted, 0);
    }

    #[test]
    #[serial(reflection_db)]
    fn clear_does_not_remove_real_reflections() {
        fresh_test_root();
        // Save a real reflection.
        save_reflection(
            &sample_reflection("real lesson", Priority::High, None),
            None,
        )
        .expect("test invariant");
        // Seed an AB lesson.
        seed_ab_lessons(
            "neuromod",
            &[SeedDirective {
                directive: "calibrate confidence".into(),
                priority: "high".into(),
                scope: Some("neuromod".into()),
            }],
        )
        .expect("test invariant");

        // Clearing removes only the seeded one.
        let deleted = clear_ab_seed_lessons().expect("test invariant");
        assert_eq!(deleted, 1);

        let remaining = load_recent_high_priority_targets(10, None).expect("test invariant");
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].directive, "real lesson");
    }

    #[test]
    #[serial(reflection_db)]
    fn format_lessons_block_renders_priority_and_scope() {
        let targets = vec![
            ImprovementTarget {
                directive: "verify before patch".into(),
                priority: Priority::High,
                scope: Some("patch_file".into()),
                actioned_as: None,
            },
            ImprovementTarget {
                directive: "ask clarifying questions when ambiguous".into(),
                priority: Priority::Medium,
                scope: None,
                actioned_as: None,
            },
        ];
        let s = format_lessons_block(&targets);
        assert!(s.contains("## Lessons from prior episodes"));
        assert!(s.contains("(high) [patch_file] verify before patch"));
        assert!(s.contains("(medium) ask clarifying questions"));
    }

    // ── COG-016: model-tier-aware lessons injection ──────────────────────

    #[test]
    fn model_tier_classifies_frontier_correctly() {
        // COG-023: sonnet entries removed — they now classify as ModelTier::Sonnet
        // (see model_tier_classifies_sonnet_correctly below).
        for m in &[
            "claude-haiku-4-5",
            "claude-haiku-4-5-20251001",
            "claude-opus-4-5",
            "claude-3-5-haiku-20241022",
            "gpt-4o",
            "gpt-4o-mini",
            "gpt-5",
            "o1-preview",
            "o3-mini",
            "gemini-1.5-pro",
            "gemini-2.0-flash",
            "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            "meta-llama/Meta-Llama-3.1-70B-Instruct-Turbo",
            "meta-llama/Meta-Llama-3.1-405B-Instruct",
        ] {
            assert_eq!(
                model_tier(m),
                ModelTier::Frontier,
                "expected Frontier for {}",
                m
            );
        }
    }

    #[test]
    fn model_tier_classifies_sonnet_correctly() {
        // COG-023: any model id containing "sonnet" (case-insensitive) classifies
        // as Sonnet — carved out from Frontier because the COG-016 directive
        // backfires on it (EVAL-027c, 33% fake-tool emission, n=100).
        for m in &[
            "claude-sonnet-4-5",
            "claude-sonnet-4-5-20250101",
            "claude-sonnet-4",
            "claude-3-5-sonnet-20241022",
            "claude-3-5-Sonnet-20241022", // case-insensitive
            "anthropic/claude-sonnet-4-5",
        ] {
            assert_eq!(
                model_tier(m),
                ModelTier::Sonnet,
                "expected Sonnet for {}",
                m
            );
        }

        // Negative controls: opus and haiku must NOT classify as Sonnet.
        assert_eq!(model_tier("claude-opus-4-5"), ModelTier::Frontier);
        assert_eq!(model_tier("claude-haiku-4-5"), ModelTier::Frontier);
    }

    #[test]
    fn model_tier_classifies_capable_correctly() {
        for m in &[
            "qwen2.5:14b",
            "ollama:qwen2.5-14b",
            "qwen3:14b",
            "qwen3:32b",
            "qwen2.5:32b",
            "gpt-oss:20b",
            "gemini-1.5-flash",
            "meta-llama/Meta-Llama-3.1-8B-Instruct-Turbo",
        ] {
            assert_eq!(
                model_tier(m),
                ModelTier::Capable,
                "expected Capable for {}",
                m
            );
        }
    }

    #[test]
    fn model_tier_classifies_small_correctly() {
        for m in &[
            "llama3.2:1b",
            "llama3.2:3b",
            "qwen2.5:7b",
            "qwen3:8b",
            "qwen3:7b",
        ] {
            assert_eq!(model_tier(m), ModelTier::Small, "expected Small for {}", m);
        }
    }

    #[test]
    fn model_tier_unknown_for_unrecognized() {
        for m in &["", "foo-bar-baz", "mistral-7b", "phi-3-mini"] {
            assert_eq!(
                model_tier(m),
                ModelTier::Unknown,
                "expected Unknown for {}",
                m
            );
        }
    }

    #[test]
    fn model_tier_ord_is_correct() {
        // Used by lessons_enabled_for_model: tier >= min_tier check.
        // COG-023: full chain is Unknown < Small < Capable < Sonnet < Frontier.
        assert!(ModelTier::Frontier > ModelTier::Sonnet);
        assert!(ModelTier::Sonnet > ModelTier::Capable);
        assert!(ModelTier::Capable > ModelTier::Small);
        assert!(ModelTier::Small > ModelTier::Unknown);
        // The full chain
        assert!(ModelTier::Frontier > ModelTier::Unknown);
        // Sonnet specifically must sit BELOW Frontier so default
        // CHUMP_LESSONS_MIN_TIER=frontier excludes it (the COG-023 fix).
        assert!(ModelTier::Sonnet < ModelTier::Frontier);
    }

    #[test]
    #[serial(reflection_db)]
    fn min_tier_default_is_none_post_cog024() {
        // COG-024: default flipped from Some(Frontier) to None. Lessons OFF
        // by default; opt-in per model via CHUMP_LESSONS_OPT_IN_MODELS.
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
        assert_eq!(min_tier_for_lessons(), None);
    }

    #[test]
    #[serial(reflection_db)]
    fn min_tier_none_disables_gating() {
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "none");
        assert_eq!(min_tier_for_lessons(), None);
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "off");
        assert_eq!(min_tier_for_lessons(), None);
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "disabled");
        assert_eq!(min_tier_for_lessons(), None);
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }

    #[test]
    #[serial(reflection_db)]
    fn min_tier_explicit_values_parse() {
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "small");
        assert_eq!(min_tier_for_lessons(), Some(ModelTier::Small));
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "capable");
        assert_eq!(min_tier_for_lessons(), Some(ModelTier::Capable));
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "FRONTIER"); // case insensitive
        assert_eq!(min_tier_for_lessons(), Some(ModelTier::Frontier));
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }

    #[test]
    #[serial(reflection_db)]
    fn lessons_enabled_for_model_default_off_post_cog024() {
        // COG-024: with neither CHUMP_LESSONS_MIN_TIER nor
        // CHUMP_LESSONS_OPT_IN_MODELS set, EVERY model is off — including
        // former Frontier defaults. Lessons require explicit opt-in now.
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");

        assert!(!lessons_enabled_for_model("claude-haiku-4-5"));
        assert!(!lessons_enabled_for_model("claude-opus-4-5"));
        assert!(!lessons_enabled_for_model("gpt-4o"));
        assert!(!lessons_enabled_for_model("qwen2.5:14b"));
        assert!(!lessons_enabled_for_model("qwen2.5:7b"));
        assert!(!lessons_enabled_for_model("foo-unknown"));
        assert!(!lessons_enabled_for_model(""));
    }

    #[test]
    #[serial(reflection_db)]
    fn lessons_enabled_for_model_capable_min() {
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "capable");

        assert!(lessons_enabled_for_model("claude-haiku-4-5")); // Frontier >= Capable
        assert!(lessons_enabled_for_model("qwen2.5:14b")); // Capable >= Capable
        assert!(!lessons_enabled_for_model("qwen2.5:7b")); // Small < Capable
        assert!(!lessons_enabled_for_model("foo-unknown")); // Unknown still off

        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }

    #[test]
    #[serial(reflection_db)]
    fn lessons_enabled_for_model_none_means_off_post_cog024() {
        // COG-024 semantic flip: `none` no longer means "preserve legacy
        // behavior of always-on" — it now collapses to default OFF (same as
        // unset). The opt-in CSV is the only way to enable injection.
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "none");

        assert!(!lessons_enabled_for_model("claude-haiku-4-5"));
        assert!(!lessons_enabled_for_model("qwen2.5:7b"));
        assert!(!lessons_enabled_for_model("foo-unknown"));

        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }

    #[test]
    #[serial(reflection_db)]
    fn lessons_enabled_for_model_kill_switch_still_works() {
        std::env::set_var("CHUMP_REFLECTION_INJECTION", "0");
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "frontier");
        std::env::set_var("CHUMP_LESSONS_OPT_IN_MODELS", "claude-haiku-4-5:cog016");

        // Kill-switch wins over EVERYTHING — both tier and opt-in CSV.
        assert!(!lessons_enabled_for_model("claude-haiku-4-5"));

        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
    }

    // ── COG-023: Sonnet carve-out from cog016 directive injection ────────

    #[test]
    #[serial(reflection_db)]
    fn cog023_sonnet_excluded_at_default_and_at_frontier_tier() {
        // EVAL-027c CONFIRMED: the COG-016 directive triggers ~33% fake-tool
        // emission per response on sonnet-4-5 (n=100, non-overlapping CIs).
        // Sonnet must be off (a) by default per COG-024 and (b) when tier
        // gate is at frontier (Sonnet < Frontier).
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");

        // (a) COG-024 default: nothing set → off everywhere including sonnet.
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
        assert!(!lessons_enabled_for_model("claude-sonnet-4-5"));

        // (b) Legacy MIN_TIER=frontier path: sonnet still excluded by COG-023.
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "frontier");
        assert!(
            !lessons_enabled_for_model("claude-sonnet-4-5"),
            "sonnet-4-5 must NOT receive injection at frontier tier — \
             COG-016 directive backfires per EVAL-027c"
        );
        assert!(!lessons_enabled_for_model("claude-sonnet-4-5-20250101"));
        assert!(!lessons_enabled_for_model("claude-3-5-sonnet-20241022"));
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }

    #[test]
    #[serial(reflection_db)]
    fn cog023_sonnet_opt_in_at_capable_tier() {
        // Operators who explicitly want sonnet to receive lessons can
        // opt in by lowering CHUMP_LESSONS_MIN_TIER. Sonnet > Capable in
        // the ordering, so capable-tier minimum re-enables sonnet.
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "capable");

        assert!(
            lessons_enabled_for_model("claude-sonnet-4-5"),
            "sonnet-4-5 must receive injection when MIN_TIER=capable (opt-in)"
        );

        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }

    #[test]
    #[serial(reflection_db)]
    fn cog023_haiku_off_by_default_post_cog024_but_on_via_opt_in() {
        // COG-024 supersedes COG-023 for the default behavior: haiku-4-5
        // no longer receives injection by default. It must be opted-in
        // explicitly via CHUMP_LESSONS_OPT_IN_MODELS.
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");

        assert!(
            !lessons_enabled_for_model("claude-haiku-4-5"),
            "post-COG-024 default OFF — haiku-4-5 must NOT inject without opt-in"
        );

        // Opt-in re-enables it.
        std::env::set_var("CHUMP_LESSONS_OPT_IN_MODELS", "claude-haiku-4-5:cog016");
        assert!(lessons_enabled_for_model("claude-haiku-4-5"));
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
    }

    #[test]
    #[serial(reflection_db)]
    fn cog023_opus_off_by_default_post_cog024_but_on_via_opt_in() {
        // COG-024: opus-4-5 also defaults OFF now (was: ON via Frontier).
        // Per CONSCIOUSNESS_AB_RESULTS post-EVAL-027c, opus is in the
        // recommended opt-in list (cog016, partial fix).
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");

        assert!(!lessons_enabled_for_model("claude-opus-4-5"));

        std::env::set_var("CHUMP_LESSONS_OPT_IN_MODELS", "claude-opus-4-5:cog016");
        assert!(lessons_enabled_for_model("claude-opus-4-5"));
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
    }

    // ── COG-024: per-model opt-in via CHUMP_LESSONS_OPT_IN_MODELS ─────────

    #[test]
    #[serial(reflection_db)]
    fn cog024_opt_in_lookup_returns_variant() {
        std::env::set_var(
            "CHUMP_LESSONS_OPT_IN_MODELS",
            "claude-haiku-4-5:cog016,claude-opus-4-5:cog016",
        );
        assert_eq!(
            lessons_opt_in_for_model("claude-haiku-4-5"),
            Some("cog016".to_string())
        );
        assert_eq!(
            lessons_opt_in_for_model("claude-haiku-4-5-20251001"),
            Some("cog016".to_string()),
            "substring match must accept dated suffixes"
        );
        assert_eq!(
            lessons_opt_in_for_model("claude-opus-4-5"),
            Some("cog016".to_string())
        );
        assert_eq!(lessons_opt_in_for_model("claude-sonnet-4-5"), None);
        assert_eq!(lessons_opt_in_for_model("qwen2.5:7b"), None);
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
    }

    #[test]
    #[serial(reflection_db)]
    fn cog024_opt_in_unset_returns_none() {
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
        assert_eq!(lessons_opt_in_for_model("claude-haiku-4-5"), None);
    }

    #[test]
    #[serial(reflection_db)]
    fn cog024_opt_in_malformed_csv_handled_gracefully() {
        // Malformed entries (no colon, empty halves, stray commas) must be
        // skipped without panicking. The good entry should still match.
        std::env::set_var(
            "CHUMP_LESSONS_OPT_IN_MODELS",
            ",  , no-colon-here, :empty-id, empty-variant: ,claude-haiku-4-5:cog016,",
        );
        assert_eq!(
            lessons_opt_in_for_model("claude-haiku-4-5"),
            Some("cog016".to_string())
        );
        assert_eq!(lessons_opt_in_for_model("no-colon-here"), None);
        assert_eq!(lessons_opt_in_for_model(""), None);
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
    }

    #[test]
    #[serial(reflection_db)]
    fn cog024_opt_in_alone_enables_lessons() {
        // Tier gate unset (default None post-COG-024) but opt-in CSV names
        // haiku → injection ON for haiku, OFF for everything else.
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
        std::env::set_var("CHUMP_LESSONS_OPT_IN_MODELS", "claude-haiku-4-5:cog016");

        assert!(lessons_enabled_for_model("claude-haiku-4-5"));
        assert!(!lessons_enabled_for_model("claude-opus-4-5"));
        assert!(!lessons_enabled_for_model("claude-sonnet-4-5"));
        assert!(!lessons_enabled_for_model("qwen2.5:7b"));

        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
    }

    #[test]
    #[serial(reflection_db)]
    fn cog024_tier_gate_alone_still_works() {
        // Operators who already use CHUMP_LESSONS_MIN_TIER=frontier keep
        // working — the tier path is preserved as a secondary gate.
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "frontier");

        assert!(lessons_enabled_for_model("claude-haiku-4-5"));
        assert!(lessons_enabled_for_model("claude-opus-4-5"));
        assert!(!lessons_enabled_for_model("claude-sonnet-4-5")); // Sonnet < Frontier (COG-023)
        assert!(!lessons_enabled_for_model("qwen2.5:14b"));

        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }

    #[test]
    #[serial(reflection_db)]
    fn cog024_opt_in_and_tier_both_active_or_combine() {
        // Opt-in OR tier — either route enables. Test sonnet (excluded by
        // tier even at frontier) gets re-enabled if explicitly opted-in.
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "frontier");
        std::env::set_var("CHUMP_LESSONS_OPT_IN_MODELS", "claude-sonnet-4-5:custom");

        // Tier path: haiku ON (Frontier ≥ Frontier).
        assert!(lessons_enabled_for_model("claude-haiku-4-5"));
        // Opt-in path overrides Sonnet's tier exclusion.
        assert!(lessons_enabled_for_model("claude-sonnet-4-5"));
        // Neither path: still off.
        assert!(!lessons_enabled_for_model("qwen2.5:7b"));

        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
    }

    // ── MEM-006: lessons-loaded-at-spawn ─────────────────────────────────

    #[test]
    #[serial(reflection_db)]
    fn spawn_lessons_n_unset_returns_none() {
        std::env::remove_var("CHUMP_LESSONS_AT_SPAWN_N");
        assert_eq!(spawn_lessons_n(), None);
    }

    #[test]
    #[serial(reflection_db)]
    fn spawn_lessons_n_parses_and_clamps() {
        std::env::set_var("CHUMP_LESSONS_AT_SPAWN_N", "3");
        assert_eq!(spawn_lessons_n(), Some(3));
        std::env::set_var("CHUMP_LESSONS_AT_SPAWN_N", "999");
        assert_eq!(spawn_lessons_n(), Some(20), "must clamp to MAX_N=20");
        std::env::set_var("CHUMP_LESSONS_AT_SPAWN_N", "0");
        assert_eq!(spawn_lessons_n(), Some(0));
        std::env::set_var("CHUMP_LESSONS_AT_SPAWN_N", "garbage");
        assert_eq!(
            spawn_lessons_n(),
            Some(5),
            "malformed value falls back to default 5"
        );
        std::env::remove_var("CHUMP_LESSONS_AT_SPAWN_N");
    }

    #[test]
    #[serial(reflection_db)]
    fn spawn_lessons_empty_db_returns_empty() {
        fresh_test_root();
        let lessons = load_spawn_lessons("", 5);
        assert!(lessons.is_empty());
    }

    #[test]
    #[serial(reflection_db)]
    fn spawn_lessons_respects_max_n() {
        fresh_test_root();
        for i in 0..10 {
            save_reflection(
                &sample_reflection(&format!("lesson {}", i), Priority::High, None),
                None,
            )
            .expect("test invariant");
        }
        let lessons = load_spawn_lessons("", 3);
        assert_eq!(lessons.len(), 3);
    }

    #[test]
    #[serial(reflection_db)]
    fn spawn_lessons_zero_n_returns_empty() {
        fresh_test_root();
        save_reflection(&sample_reflection("any lesson", Priority::High, None), None)
            .expect("test invariant");
        let lessons = load_spawn_lessons("", 0);
        assert!(lessons.is_empty(), "max_n=0 must short-circuit to empty");
    }

    #[test]
    #[serial(reflection_db)]
    fn spawn_lessons_excludes_low_priority_and_ab_seed() {
        fresh_test_root();
        // High priority — must surface.
        save_reflection(
            &sample_reflection("real high lesson", Priority::High, None),
            None,
        )
        .expect("test invariant");
        // Low priority — must NOT surface (consistent with per-task path).
        let mut low = sample_reflection("low priority lesson", Priority::Low, None);
        low.improvements[0].priority = Priority::Low;
        save_reflection(&low, None).expect("test invariant");
        // ab_seed — must NOT surface.
        seed_ab_lessons(
            "perception",
            &[SeedDirective {
                directive: "seeded lesson".into(),
                priority: "high".into(),
                scope: Some("perception".into()),
            }],
        )
        .expect("test invariant");

        let lessons = load_spawn_lessons("", 10);
        let directives: Vec<_> = lessons.iter().map(|t| t.directive.as_str()).collect();
        assert!(directives.contains(&"real high lesson"));
        assert!(!directives.contains(&"low priority lesson"));
        assert!(!directives.contains(&"seeded lesson"));
    }

    #[test]
    #[serial(reflection_db)]
    fn spawn_lessons_ranks_frequent_recent_higher() {
        fresh_test_root();
        // "recurring lesson" appears 3 times — should outrank a one-off
        // even though all share the same created_at. Frequency dominates.
        for _ in 0..3 {
            save_reflection(
                &sample_reflection("recurring lesson", Priority::High, None),
                None,
            )
            .expect("test invariant");
        }
        save_reflection(
            &sample_reflection("one-off lesson", Priority::High, None),
            None,
        )
        .expect("test invariant");

        let lessons = load_spawn_lessons("", 10);
        // The recurring one must be first; both unique directives should
        // appear (GROUP BY collapses dupes).
        assert_eq!(lessons.len(), 2, "duplicates collapsed via GROUP BY");
        assert_eq!(lessons[0].directive, "recurring lesson");
        assert_eq!(lessons[1].directive, "one-off lesson");
    }

    #[test]
    #[serial(reflection_db)]
    fn spawn_lessons_domain_filter_includes_universal() {
        fresh_test_root();
        save_reflection(
            &sample_reflection("universal lesson", Priority::High, None),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection("patch-scoped lesson", Priority::High, Some("patch_file")),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection("git-scoped lesson", Priority::High, Some("git_commit")),
            None,
        )
        .expect("test invariant");

        let lessons = load_spawn_lessons("patch_file", 10);
        let directives: Vec<_> = lessons.iter().map(|t| t.directive.as_str()).collect();
        assert!(directives.contains(&"universal lesson"));
        assert!(directives.contains(&"patch-scoped lesson"));
        assert!(
            !directives.contains(&"git-scoped lesson"),
            "off-domain lesson must be excluded"
        );
    }

    #[test]
    #[serial(reflection_db)]
    fn spawn_lessons_global_domain_returns_all() {
        fresh_test_root();
        save_reflection(
            &sample_reflection("a", Priority::High, Some("perception")),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection("b", Priority::High, Some("git_commit")),
            None,
        )
        .expect("test invariant");

        let lessons = load_spawn_lessons("global", 10);
        assert_eq!(
            lessons.len(),
            2,
            "global/empty domain returns lessons regardless of scope"
        );
    }

    #[test]
    fn format_lessons_block_includes_anti_hallucination_directive() {
        let targets = vec![ImprovementTarget {
            directive: "do the thing".to_string(),
            priority: Priority::High,
            scope: None,
            actioned_as: None,
        }];
        let s = format_lessons_block(&targets);
        // The COG-016 anti-hallucination guardrail must appear in every
        // emitted block — it's the literal text that addresses the
        // documented hallucination failure mode.
        assert!(
            s.contains("do NOT") && s.contains("function_calls"),
            "block must contain anti-hallucination directive, got: {}",
            s
        );
    }

    // ── EVAL-030: task-class-aware lessons gating ────────────────────────

    fn make_targets() -> Vec<ImprovementTarget> {
        vec![
            ImprovementTarget {
                directive:
                    "If the user prompt is ambiguous, ask one clarifying question rather than guessing."
                        .into(),
                priority: Priority::High,
                scope: Some("perception".into()),
                actioned_as: None,
            },
            ImprovementTarget {
                directive: "verify file exists before patch_file".into(),
                priority: Priority::High,
                scope: Some("patch_file".into()),
                actioned_as: None,
            },
        ]
    }

    #[test]
    fn eval030_is_conditional_chain_matches_two_markers() {
        let p = "do X, if it fails do Y, then if Y fails do Z";
        assert!(is_conditional_chain(p));
    }

    #[test]
    fn eval030_is_conditional_chain_matches_step_pattern() {
        let p = "Step 1: read foo. Step 2: write bar.";
        assert!(is_conditional_chain(p));
    }

    #[test]
    fn eval030_is_conditional_chain_does_not_match_clean_prompt() {
        let p = "Summarize the design doc and propose three improvements.";
        assert!(!is_conditional_chain(p));
    }

    #[test]
    fn eval030_is_conditional_chain_single_marker_does_not_match() {
        let p = "Run the tests and tell me if it fails.";
        assert!(!is_conditional_chain(p));
    }

    #[test]
    fn eval030_is_trivial_token_matches_short_chat() {
        for p in &["lol", "thanks", "k thx", "sup", "noice"] {
            assert!(is_trivial_token(p), "expected trivial: {}", p);
        }
    }

    #[test]
    fn eval030_is_trivial_token_does_not_match_real_prompt() {
        let p = "Please analyze the database schema and report any normalization issues.";
        assert!(!is_trivial_token(p));
    }

    #[test]
    #[serial(reflection_db)]
    fn eval030_format_returns_empty_for_trivial_token() {
        std::env::remove_var("CHUMP_LESSONS_TASK_AWARE");
        let targets = make_targets();
        let s = format_lessons_block_with_prompt(&targets, Some("lol"));
        assert!(
            s.is_empty(),
            "trivial token should suppress whole block, got: {:?}",
            s
        );
    }

    #[test]
    #[serial(reflection_db)]
    fn eval030_format_suppresses_perception_directive_on_conditional_chain() {
        std::env::remove_var("CHUMP_LESSONS_TASK_AWARE");
        let targets = make_targets();
        let prompt = "Please do A, if it fails do B, then if B fails do C.";
        let s = format_lessons_block_with_prompt(&targets, Some(prompt));
        assert!(
            !s.is_empty(),
            "conditional chain still has the patch_file lesson, block must render"
        );
        assert!(
            !s.to_lowercase().contains("clarifying question"),
            "perception clarifying directive must be filtered, got: {}",
            s
        );
        assert!(
            s.contains("verify file exists before patch_file"),
            "non-perception directives must survive, got: {}",
            s
        );
    }

    #[test]
    #[serial(reflection_db)]
    fn eval030_default_env_preserves_existing_behavior_when_prompt_unset() {
        // No prompt → identical to legacy format_lessons_block path.
        std::env::remove_var("CHUMP_LESSONS_TASK_AWARE");
        let targets = make_targets();
        let legacy = format_lessons_block(&targets);
        let new_no_prompt = format_lessons_block_with_prompt(&targets, None);
        assert_eq!(legacy, new_no_prompt);
        assert!(legacy.to_lowercase().contains("clarifying question"));
    }

    #[test]
    #[serial(reflection_db)]
    fn eval030_opt_out_disables_gating() {
        std::env::set_var("CHUMP_LESSONS_TASK_AWARE", "0");
        let targets = make_targets();
        // Trivial prompt — would normally suppress; opt-out keeps the block.
        let s = format_lessons_block_with_prompt(&targets, Some("lol"));
        assert!(
            s.to_lowercase().contains("clarifying question"),
            "opt-out must restore v1 uniform behavior, got: {}",
            s
        );
        std::env::remove_var("CHUMP_LESSONS_TASK_AWARE");
    }

    #[test]
    #[serial(reflection_db)]
    fn eval030_task_aware_default_on() {
        std::env::remove_var("CHUMP_LESSONS_TASK_AWARE");
        assert!(task_aware_lessons_enabled());
    }

    // ── MEM-009: quality-threshold filtering ─────────────────────────────

    /// Build a reflection with a specific outcome_class for quality-threshold tests.
    fn sample_reflection_with_outcome(directive: &str, outcome: OutcomeClass) -> Reflection {
        Reflection {
            id: None,
            episode_id: None,
            intended_goal: "test goal".into(),
            observed_outcome: "test outcome".into(),
            outcome_class: outcome,
            error_pattern: None,
            improvements: vec![ImprovementTarget {
                directive: directive.into(),
                priority: Priority::High,
                scope: None,
                actioned_as: None,
            }],
            hypothesis: "test hypothesis".into(),
            surprisal_at_reflect: None,
            confidence_at_reflect: None,
            created_at: "2026-04-19T00:00:00Z".into(),
        }
    }

    #[test]
    fn mem009_outcome_quality_mapping() {
        // Verify the pure-function mapping matches the acceptance criteria.
        assert_eq!(outcome_quality(Some("pass")), 1.0);
        assert_eq!(outcome_quality(Some("success")), 1.0);
        assert_eq!(outcome_quality(Some("partial")), 0.5);
        assert_eq!(outcome_quality(Some("failure")), 0.0);
        assert_eq!(outcome_quality(Some("abandoned")), 0.0);
        assert_eq!(
            outcome_quality(Some("")),
            0.5,
            "empty string defaults to 0.5"
        );
        assert_eq!(outcome_quality(None), 0.5, "NULL defaults to 0.5");
        assert_eq!(outcome_quality(Some("unknown_value")), 0.0, "unknown → 0.0");
    }

    #[test]
    #[serial(reflection_db)]
    fn mem009_lesson_quality_threshold_default_zero() {
        std::env::remove_var("CHUMP_LESSON_QUALITY_THRESHOLD");
        assert_eq!(lesson_quality_threshold(), 0.0);
    }

    #[test]
    #[serial(reflection_db)]
    fn mem009_lesson_quality_threshold_parses_and_clamps() {
        std::env::set_var("CHUMP_LESSON_QUALITY_THRESHOLD", "0.5");
        assert_eq!(lesson_quality_threshold(), 0.5);
        std::env::set_var("CHUMP_LESSON_QUALITY_THRESHOLD", "1.0");
        assert_eq!(lesson_quality_threshold(), 1.0);
        std::env::set_var("CHUMP_LESSON_QUALITY_THRESHOLD", "0.0");
        assert_eq!(lesson_quality_threshold(), 0.0);
        // Out-of-range values clamp.
        std::env::set_var("CHUMP_LESSON_QUALITY_THRESHOLD", "2.5");
        assert_eq!(lesson_quality_threshold(), 1.0, "above 1.0 clamps to 1.0");
        std::env::set_var("CHUMP_LESSON_QUALITY_THRESHOLD", "-0.5");
        assert_eq!(lesson_quality_threshold(), 0.0, "below 0.0 clamps to 0.0");
        // Malformed value falls back to 0.0.
        std::env::set_var("CHUMP_LESSON_QUALITY_THRESHOLD", "garbage");
        assert_eq!(
            lesson_quality_threshold(),
            0.0,
            "malformed falls back to 0.0"
        );
        std::env::remove_var("CHUMP_LESSON_QUALITY_THRESHOLD");
    }

    #[test]
    #[serial(reflection_db)]
    fn mem009_threshold_zero_loads_all() {
        // threshold=0.0 must load lessons from all outcome classes.
        fresh_test_root();
        save_reflection(
            &sample_reflection_with_outcome("success lesson", OutcomeClass::Pass),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection_with_outcome("partial lesson", OutcomeClass::PartialSuccess),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection_with_outcome("failure lesson", OutcomeClass::Failure),
            None,
        )
        .expect("test invariant");

        let lessons = load_spawn_lessons_with_threshold("", 10, 0.0);
        let directives: Vec<_> = lessons.iter().map(|t| t.directive.as_str()).collect();
        assert!(
            directives.contains(&"success lesson"),
            "threshold=0.0 must include success"
        );
        assert!(
            directives.contains(&"partial lesson"),
            "threshold=0.0 must include partial"
        );
        assert!(
            directives.contains(&"failure lesson"),
            "threshold=0.0 must include failure"
        );
        assert_eq!(
            directives.len(),
            3,
            "all three lessons visible at threshold=0.0"
        );
    }

    #[test]
    #[serial(reflection_db)]
    fn mem009_threshold_one_loads_only_successes() {
        // threshold=1.0 must return only lessons from reflections with outcome "pass".
        fresh_test_root();
        save_reflection(
            &sample_reflection_with_outcome("success lesson", OutcomeClass::Pass),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection_with_outcome("partial lesson", OutcomeClass::PartialSuccess),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection_with_outcome("failure lesson", OutcomeClass::Failure),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection_with_outcome("abandoned lesson", OutcomeClass::Abandoned),
            None,
        )
        .expect("test invariant");

        let lessons = load_spawn_lessons_with_threshold("", 10, 1.0);
        let directives: Vec<_> = lessons.iter().map(|t| t.directive.as_str()).collect();
        assert_eq!(
            directives,
            vec!["success lesson"],
            "threshold=1.0 must include only pass/success outcome"
        );
    }

    #[test]
    #[serial(reflection_db)]
    fn mem009_threshold_half_loads_successes_and_partials() {
        // threshold=0.5 must return lessons from pass and partial outcomes,
        // excluding failure and abandoned.
        fresh_test_root();
        save_reflection(
            &sample_reflection_with_outcome("success lesson", OutcomeClass::Pass),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection_with_outcome("partial lesson", OutcomeClass::PartialSuccess),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection_with_outcome("failure lesson", OutcomeClass::Failure),
            None,
        )
        .expect("test invariant");

        let lessons = load_spawn_lessons_with_threshold("", 10, 0.5);
        let directives: Vec<_> = lessons.iter().map(|t| t.directive.as_str()).collect();
        assert!(
            directives.contains(&"success lesson"),
            "threshold=0.5 must include success"
        );
        assert!(
            directives.contains(&"partial lesson"),
            "threshold=0.5 must include partial"
        );
        assert!(
            !directives.contains(&"failure lesson"),
            "threshold=0.5 must exclude failure"
        );
        assert_eq!(directives.len(), 2);
    }

    #[test]
    #[serial(reflection_db)]
    fn mem009_env_var_threshold_applied_by_load_spawn_lessons() {
        // load_spawn_lessons (the public API) reads CHUMP_LESSON_QUALITY_THRESHOLD.
        fresh_test_root();
        save_reflection(
            &sample_reflection_with_outcome("success lesson", OutcomeClass::Pass),
            None,
        )
        .expect("test invariant");
        save_reflection(
            &sample_reflection_with_outcome("failure lesson", OutcomeClass::Failure),
            None,
        )
        .expect("test invariant");

        // With threshold=1.0 set, only success should surface.
        std::env::set_var("CHUMP_LESSON_QUALITY_THRESHOLD", "1.0");
        let lessons = load_spawn_lessons("", 10);
        let directives: Vec<_> = lessons.iter().map(|t| t.directive.as_str()).collect();
        assert_eq!(directives, vec!["success lesson"]);

        // Remove threshold → both surface.
        std::env::remove_var("CHUMP_LESSON_QUALITY_THRESHOLD");
        let all_lessons = load_spawn_lessons("", 10);
        assert_eq!(all_lessons.len(), 2, "no threshold → all lessons returned");
    }

    // ── INFRA-016: family deny-list ──────────────────────────────────────────

    #[test]
    #[serial(reflection_db)]
    fn lessons_family_denied_default_deepseek() {
        std::env::remove_var("CHUMP_LESSONS_DENY_FAMILIES");
        // Default deny-list is "deepseek".
        assert!(lessons_family_denied("deepseek-v3.1"));
        assert!(lessons_family_denied("DeepSeek-R1")); // case-insensitive
        assert!(!lessons_family_denied("claude-haiku-4-5"));
        assert!(!lessons_family_denied("qwen2.5:14b"));
    }

    #[test]
    #[serial(reflection_db)]
    fn lessons_family_denied_custom_list() {
        std::env::set_var("CHUMP_LESSONS_DENY_FAMILIES", "qwen,mistral");
        assert!(lessons_family_denied("qwen2.5:14b"));
        assert!(lessons_family_denied("mistral-7b"));
        assert!(!lessons_family_denied("deepseek-v3.1")); // not in custom list
        assert!(!lessons_family_denied("claude-haiku-4-5"));
        std::env::remove_var("CHUMP_LESSONS_DENY_FAMILIES");
    }

    #[test]
    #[serial(reflection_db)]
    fn lessons_family_denied_empty_disables_default() {
        std::env::set_var("CHUMP_LESSONS_DENY_FAMILIES", "");
        assert!(!lessons_family_denied("deepseek-v3.1")); // default suppressed
        assert!(!lessons_family_denied("claude-haiku-4-5"));
        std::env::remove_var("CHUMP_LESSONS_DENY_FAMILIES");
    }

    #[test]
    #[serial(reflection_db)]
    fn deny_list_wins_over_opt_in_model() {
        // INFRA-016 core invariant: deny-list beats explicit opt-in.
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_DENY_FAMILIES"); // default: deepseek
        std::env::set_var("CHUMP_LESSONS_OPT_IN_MODELS", "deepseek-v3.1:cog016");
        assert!(
            !lessons_enabled_for_model("deepseek-v3.1"),
            "deny-list must win even when model is explicitly opted in"
        );
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
    }

    #[test]
    #[serial(reflection_db)]
    fn deny_list_wins_over_tier_gate() {
        // Deny-list also beats the legacy tier gate.
        std::env::remove_var("CHUMP_REFLECTION_INJECTION");
        std::env::remove_var("CHUMP_LESSONS_DENY_FAMILIES"); // default: deepseek
        std::env::remove_var("CHUMP_LESSONS_OPT_IN_MODELS");
        std::env::set_var("CHUMP_LESSONS_MIN_TIER", "capable");
        // deepseek-v3.1 would pass the capable-tier check but deny-list wins.
        assert!(
            !lessons_enabled_for_model("deepseek-v3.1"),
            "deny-list must win over tier gate"
        );
        std::env::remove_var("CHUMP_LESSONS_MIN_TIER");
    }
}
