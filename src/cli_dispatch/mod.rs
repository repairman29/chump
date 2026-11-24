//! Top-level CLI switchboard and subcommand dispatch for Universal Chump (`v1.0`).

pub(crate) mod eval_modes;
pub(crate) mod fleet_modes;
pub(crate) mod gap_admin_modes;
pub(crate) mod gap_audit_modes;
pub(crate) mod gap_modes;
pub(crate) mod helpers;
pub(crate) mod ops_modes;
pub(crate) mod pr_roadmap_modes;
pub(crate) mod runtime_modes;
pub(crate) mod ship_modes;
pub(crate) mod store_modes;

pub(crate) use eval_modes::*;
pub(crate) use helpers::*;
pub(crate) use ship_modes::*;
pub(crate) use store_modes::*;

use crate::*;
use anyhow::Result;
#[allow(unused_imports)]
use axonerai::agent::Agent;
#[allow(unused_imports)]
use axonerai::file_session_manager::FileSessionManager;
#[allow(unused_imports)]
use axonerai::tool::ToolRegistry;
use std::env;
#[allow(unused_imports)]
use std::io::{self, IsTerminal, Write};

pub async fn run() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    // EFFECTIVE-011: expand short aliases (g, c, s, f, d, h, cs) before routing.
    let args = expand_aliases(args);

    // SIGPIPE handling for CLI tools (Broken Pipe panics).
    #[cfg(unix)]
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }

    // EFFECTIVE-411: inject per-model pricing into the extracted waste-tally
    // crate. Registered once here so every code path (waste subcommands,
    // fleet_status) prices tokens via session_ledger's rate table. Kept out of
    // the crate itself to avoid pulling the pricing subsystem out of the bin.
    waste_tally::set_cost_fn(session_ledger::cost_usd_from_tokens);

    // EFFECTIVE-418: same injection for the extracted kpi-report crate — its
    // cost-savings + tokens-per-ship sections price tokens via the same rate
    // table, kept out of the crate to avoid promoting the pricing subsystem.
    kpi_report::set_cost_fn(session_ledger::cost_usd_from_tokens);

    // CREDIBLE-019: --verbose / --debug global flags (processed first so they
    // take effect even alongside --version or --help).
    // --verbose: escalate RUST_LOG to debug (human stderr).
    // --debug: same as --verbose + emit a startup header with version, args, timestamp.
    let flag_verbose = args.iter().any(|a| a == "--verbose" || a == "-v");
    let flag_debug = args.iter().any(|a| a == "--debug");
    if (flag_verbose || flag_debug) && std::env::var("RUST_LOG").is_err() {
        // Safety: single-threaded; no async tasks spawned yet.
        unsafe { std::env::set_var("RUST_LOG", "debug") };
    }
    if flag_debug {
        let ts = chrono::Utc::now().format("%H:%M:%S%.3f");
        eprintln!(
            "[debug] chump {} ({}) started at {}",
            version::chump_version(),
            version::chump_build_sha(),
            ts,
        );
        eprintln!("[debug] args: {:?}", &args[1..]);
    }

    // INFRA-148: surface the baked build SHA + date so operators can verify
    // their binary's staleness against `git log src/gap_store.rs src/main.rs`
    // *before* running `chump gap ship --update-yaml` / `chump gap dump`.
    // Pre-this-fix, `chump --version` fell through to the model-prompt path
    // (printed "Response from Agent: ...") because there was no top-level
    // flag handler — defeating the point of baking the SHA at build time.
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!(
            "chump {} ({} built {})",
            version::chump_version(),
            version::chump_build_sha(),
            version::chump_build_date(),
        );
        return Ok(());
    }

    // RESILIENT-256: `chump git-guard` runs on the Claude Code PreToolUse
    // path, i.e. before EVERY Bash/Edit/Write an agent makes. It dispatches
    // here — ahead of every other subcommand and before any store, config or
    // network init — because a guard that adds latency to every tool call is
    // a guard the operator turns off. Same in-binary shape as INFRA-825's
    // stale-binary destructive-op guard, and deliberately NOT gated on
    // binary freshness: refusing to protect uncommitted work because the
    // binary is a few commits old would trade a real loss for a cosmetic one.
    if args.get(1).map(String::as_str) == Some("git-guard") {
        std::process::exit(git_safety::run_cli(&args));
    }

    // INFRA-5754 (INFRA-1748 pilot slice): self-registered subcommands take
    // priority over the legacy if/else dispatch chain below. Registered via
    // `inventory::submit! { CommandEntry::new(...) }`; first user is
    // `calibrate` (CREDIBLE-1493, src/commands/calibrate.rs).
    if let Some(name) = args.get(1) {
        if let Some(result) = commands::registry::dispatch(name, &args) {
            return result;
        }
    }
    // RESILIENT-256: the load-bearing half. Writes a dirty checkout into the
    // object store (refs/wip/…) without touching its working tree or index,
    // so `reset --hard` stops being unrecoverable even when it is correct.
    if args.get(1).map(String::as_str) == Some("wip-snapshot") {
        std::process::exit(git_safety::run_snapshot_cli(&args));
    }

    // INFRA-1649 (re-do of INFRA-1598): `chump verify-claim-branch [--json]`
    // asserts the current git branch matches the branch implied by this
    // session's active claim lease. Dispatched here — ahead of store/config
    // init — so it's cheap enough to call from a pre-push hook on every
    // push (Guard 5 in scripts/git-hooks/pre-push already does the same
    // check inline in bash; this is the reusable Rust primitive for
    // non-hook callers).
    if args.get(1).map(String::as_str) == Some("verify-claim-branch") {
        std::process::exit(verify_claim_branch::run_cli(&args));
    }

    // INFRA-8222 (Phase R R4): `chump store reconcile --from <db> --into <db>
    // [--dry-run] [--audit <path>] [--force-offline] [--skip-new-open] [--json]`
    // merges a stale gap store into the live one (newest-wins, terminal-status
    // guard). Dispatched before any GapStore::open so the live store is never
    // migrated or touched by this process before the active-writer check.
    if args.get(1).map(String::as_str) == Some("store") {
        std::process::exit(run_store_cli(&args));
    }

    // INFRA-2028: every `gh` subprocess chump spawns inherits this process's
    // env, but a subprocess spawned by chump doesn't get the macOS keychain
    // entitlement an interactive shell's `gh` has — so `gh` silently falls
    // back to an anonymous (401) request instead of the keychain-backed
    // token. If GH_TOKEN/GITHUB_TOKEN aren't already set, resolve the token
    // once via `gh auth token` (same call the operator's shell already makes
    // successfully) and export it so every later `Command::new("gh")` in
    // this process inherits it for free. No-op if gh isn't installed or the
    // caller already supplied an explicit token.
    ensure_gh_token_env();

    // INFRA-2054 (META-114 freshness cluster, binary-staleness layer):
    // `chump --build-info [--json]` prints the build-time metadata baked
    // in by build.rs (full git SHA, build timestamp, rustc version,
    // workspace root). Separate from --version because consumers want the
    // structured form. Falls through unchanged if the flag is absent.
    if args.iter().any(|a| a == "--build-info") {
        let want_json = args.iter().any(|a| a == "--json");
        std::process::exit(staleness::run_build_info_cli(want_json));
    }

    // INFRA-2054: `chump self-check-staleness [--threshold-age-s N]
    // [--threshold-commits N] [--json]` classifies the running binary
    // against two axes (file mtime age, commits-behind origin/main) and
    // exits 0/1/2 for FRESH/STALE/CRITICAL_STALE. Defaults match the
    // META-115 freshness preamble (3600s / 5 commits soft; 4x / 10x crit).
    if args.get(1).map(String::as_str) == Some("self-check-staleness") {
        let mut threshold_age_s: u64 = staleness::DEFAULT_THRESHOLD_AGE_S;
        let mut threshold_commits: u64 = staleness::DEFAULT_THRESHOLD_COMMITS;
        let mut want_json = false;
        let mut i = 2;
        while i < args.len() {
            match args[i].as_str() {
                "--threshold-age-s" => {
                    if let Some(v) = args.get(i + 1).and_then(|s| s.parse::<u64>().ok()) {
                        threshold_age_s = v;
                        i += 2;
                        continue;
                    } else {
                        eprintln!("error: --threshold-age-s requires a non-negative integer");
                        std::process::exit(2);
                    }
                }
                "--threshold-commits" => {
                    if let Some(v) = args.get(i + 1).and_then(|s| s.parse::<u64>().ok()) {
                        threshold_commits = v;
                        i += 2;
                        continue;
                    } else {
                        eprintln!("error: --threshold-commits requires a non-negative integer");
                        std::process::exit(2);
                    }
                }
                "--json" => {
                    want_json = true;
                    i += 1;
                }
                "--help" | "-h" => {
                    println!("chump self-check-staleness — INFRA-2054 (META-114 cluster)");
                    println!();
                    println!("USAGE");
                    println!("  chump self-check-staleness [options]");
                    println!();
                    println!("OPTIONS");
                    println!(
                        "  --threshold-age-s <N>     Soft age threshold in seconds (default {})",
                        staleness::DEFAULT_THRESHOLD_AGE_S
                    );
                    println!(
                        "  --threshold-commits <N>   Soft commits-behind threshold (default {})",
                        staleness::DEFAULT_THRESHOLD_COMMITS
                    );
                    println!("  --json                    Emit StalenessReport as JSON");
                    println!();
                    println!("EXIT CODES");
                    println!("  0   FRESH          — both axes inside threshold");
                    println!("  1   STALE          — at least one axis past soft threshold");
                    println!("  2   CRITICAL_STALE — at least one axis past critical threshold");
                    std::process::exit(0);
                }
                _ => {
                    i += 1;
                }
            }
        }
        std::process::exit(staleness::run_self_check_staleness_cli(
            threshold_age_s,
            threshold_commits,
            want_json,
        ));
    }

    // INFRA-8194 (Phase R R5): `chump node host` / `chump node render-unit` —
    // the typed host provisioning enum (crates/chump-provision). Thin arm only.
    // `chump node pause|resume` (RESILIENT-1614, src/node_mode.rs) falls through to its own arm.
    if args.get(1).map(String::as_str) == Some("node")
        && !matches!(
            args.get(2).map(String::as_str),
            // RESILIENT-1652/1653: `is-paused` is the node-mode read verb, handled
            // by the pause/resume block below — NOT chump_provision. Exclude it
            // here or it would hit the provision CLI and exit 2 as unknown.
            Some("pause") | Some("resume") | Some("is-paused")
        )
    {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(chump_provision::cli::run_cli(&sub_args));
    }

    // RESILIENT-069: `chump farmer status [--json] [--quiet]` — the
    // readiness gate for scripts/coord/farmer.sh (RESILIENT-068). Pure
    // local-state read (<100ms, pause-immune): exits 0 (GREEN) when
    // sentinel absent + zero exit-78 supervisors + oauth fresh + farmer
    // heartbeat <120s, else 1 (RED). Wired into `chump claim` and the
    // gap-reserve admission guard below.
    if args.get(1).map(String::as_str) == Some("farmer") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        if sub_args.first().map(String::as_str) == Some("status") {
            std::process::exit(farmer_status::run_cli(&sub_args[1..]));
        }
        eprintln!("Usage: chump farmer status [--json] [--quiet]");
        std::process::exit(2);
    }

    // CREDIBLE-227: `chump provider probe` — probes every enabled cloud
    // provider slot's live rate-limit headers + /v1/models existence,
    // compares against the hand-entered CHUMP_PROVIDER_{N}_RPM/RPD in .env,
    // and hollers (ambient kind=provider_slot_drift) any disagreement
    // instead of silently trusting or rewriting the configured value.
    if args.get(1).map(String::as_str) == Some("provider")
        && args.get(2).map(String::as_str) == Some("probe")
    {
        load_dotenv();
        let summary = provider_probe::run_probe_and_report().await;
        println!("{}", summary);
        return Ok(());
    }

    // EFFECTIVE-009: no-args → help; `chump help` → help. Must come before
    // any mode that falls through to the interactive agent loop.
    let wants_help = args.len() == 1
        || args.get(1).map(String::as_str) == Some("help")
        || args.get(1).map(String::as_str) == Some("--help")
        || args.get(1).map(String::as_str) == Some("-h");
    if wants_help {
        print_help();
        return Ok(());
    }

    if args.iter().any(|a| a == "--desktop") {
        desktop_launcher::launch_and_wait(&args);
    }
    load_dotenv();
    local_openai::auto_configure_context_window().await;

    // `chump --briefing <GAP-ID>` (MEM-007) — agent context-query that returns
    // "what should I know before working on gap X?". Reads docs/gaps.yaml,
    // chump_improvement_targets, ambient.jsonl, and strategic docs. Bypasses
    // the agent loop entirely; intended to be run by an agent right after
    // gap-preflight.sh and before gap-claim.sh. Exits 0 always — a missing
    // gap renders an explicit "not found" block rather than failing.
    if let Some(pos) = args.iter().position(|a| a == "--briefing") {
        let gap_id = args.get(pos + 1).map(String::as_str).unwrap_or("");
        if gap_id.is_empty() || gap_id.starts_with("--") {
            eprintln!("Usage: chump --briefing <GAP-ID> [--json]");
            std::process::exit(2);
        }
        let b = briefing::build_briefing(gap_id);
        // INFRA-1548: --json flag emits schema_version:1 JSON for harness consumers.
        if args.iter().any(|a| a == "--json") {
            println!("{}", briefing::render_json(&b));
        } else {
            print!("{}", briefing::render_markdown(&b));
        }
        return Ok(());
    }

    // `chump ci-lesson capture` (INFRA-1765) — turns one CI failure into a
    // structured lesson persisted to memory_db (chump_reflections /
    // chump_improvement_targets), scoped by --domain so it's auto-surfaced
    // in the next `chump --briefing <GAP-ID>` for that domain. Reads failure
    // text from --failure-text or stdin. Intended to be invoked by
    // scripts/coord/ci-lesson-propagation.sh, one call per failing check.
    if args.get(1).map(String::as_str) == Some("ci-lesson")
        && args.get(2).map(String::as_str) == Some("capture")
    {
        let get_flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1))
                .cloned()
        };
        let domain = get_flag("--domain").unwrap_or_default();
        let check = get_flag("--check").unwrap_or_default();
        let pr_ref = get_flag("--pr-ref").unwrap_or_default();
        let failure_text = match get_flag("--failure-text") {
            Some(t) => t,
            None => {
                use std::io::Read;
                let mut buf = String::new();
                let _ = std::io::stdin().read_to_string(&mut buf);
                buf
            }
        };
        if check.is_empty() || failure_text.trim().is_empty() {
            eprintln!(
                "Usage: chump ci-lesson capture --check <name> --pr-ref <ref> --domain <domain> \
                 [--failure-text <text> | stdin]"
            );
            std::process::exit(2);
        }
        let repo_root = repo_path::repo_root();
        match ci_lesson::capture_ci_lesson(&repo_root, &domain, &check, &pr_ref, &failure_text) {
            Ok(res) => {
                println!(
                    "captured: class={} reflection_id={}",
                    res.class.as_str(),
                    res.reflection_id
                );
                return Ok(());
            }
            Err(e) => {
                eprintln!("ci-lesson capture failed: {e}");
                std::process::exit(1);
            }
        }
    }

    // `chump llm-complete` (INFRA-3461) — the SANCTIONED shell gateway to the
    // shared LLM service (ProviderCascade). Reads a prompt from `--prompt` or
    // stdin, routes through `build_provider()` (the shared cascade: full auth
    // ladder incl. OAuth, 429 backoff, slot fallback), and prints the completion
    // to stdout. This lets shell scripts (e.g. the code reviewer, INFRA-3457)
    // reach the shared service instead of hand-rolling `curl` + `x-api-key`,
    // which is the class of bug the shared-service contract exists to kill.
    if args.get(1).map(String::as_str) == Some("llm-complete") {
        if args.iter().skip(2).any(|a| a == "--help" || a == "-h") {
            println!(
                "Usage: chump llm-complete [--prompt <text> | <text>] [--system <text>] [--max-tokens <n>] [--model <class>]\n\
                 Reads prompt from --prompt, positional arguments, or stdin."
            );
            return Ok(());
        }
        let (system, max_tokens, prompt_flag, model_class) = parse_llm_complete_args(&args);
        let prompt = match prompt_flag {
            Some(p) => p,
            None => {
                use std::io::Read;
                let mut buf = String::new();
                let _ = std::io::stdin().read_to_string(&mut buf);
                buf
            }
        };
        if prompt.trim().is_empty() {
            eprintln!(
                "chump llm-complete: empty prompt (pass --prompt <text> or pipe it via stdin)"
            );
            std::process::exit(2);
        }
        // INFRA-3462: --model biases the cascade toward a class (opus/sonnet/haiku)
        // via CHUMP_PREFERRED_MODEL_CLASS, which build_provider() reads. If that
        // class has no valid slot the cascade falls back to its other slots — so
        // the caller (e.g. the code reviewer) gets a strong model when available
        // and a graceful downgrade otherwise, never a hard failure.
        if let Some(class) = model_class {
            std::env::set_var("CHUMP_PREFERRED_MODEL_CLASS", class);
        }
        let provider = provider_cascade::build_provider();
        let msgs = vec![axonerai::provider::Message {
            role: "user".into(),
            content: prompt,
        }];
        match provider
            .complete(msgs, None, Some(max_tokens), system)
            .await
        {
            Ok(resp) => {
                print!("{}", resp.text.unwrap_or_default());
                return Ok(());
            }
            Err(e) => {
                eprintln!("chump llm-complete: provider error: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump provider-chain simulate --chain a,b --scenario NAME [--json]`
    // (INFRA-1844, CP-012). Smoke-test entry point for
    // scripts/ci/test-provider-chain.sh — drives the real ProviderChain
    // executor against a scripted client so fallback/retry/ambient-emission
    // behavior is exercised without depending on live providers.
    if args.get(1).map(String::as_str) == Some("provider-chain") {
        let sub = args.get(2).map(String::as_str).unwrap_or("--help");
        if sub != "simulate" {
            println!(
                "Usage: chump provider-chain simulate --chain <a,b,...> --scenario <name> [--json]"
            );
            println!();
            println!("Scenarios: happy | auth_fail | rate_limit_exhausted | transient_5xx |");
            println!("           timeout | content_refusal | invalid_prompt | chain_exhausted");
            return Ok(());
        }
        let rest: Vec<&str> = args.iter().skip(3).map(String::as_str).collect();
        let mut chain_arg: Option<&str> = None;
        let mut scenario_arg: Option<&str> = None;
        let want_json = rest.contains(&"--json");
        let mut it = rest.iter().peekable();
        while let Some(a) = it.next() {
            match *a {
                "--chain" => chain_arg = it.next().copied(),
                "--scenario" => scenario_arg = it.next().copied(),
                _ => {}
            }
        }
        let chain_names = chain_arg.unwrap_or("anthropic,openai");
        let scenario = scenario_arg.unwrap_or("happy");
        let repo_root = repo_path::repo_root();
        std::env::set_var("CHUMP_PROVIDER_CHAIN", chain_names);
        let chain = inference_provider::ProviderChain::from_env(&repo_root);
        let client = inference_provider::testing::ScenarioClient::new(scenario);
        let result = chain.execute(&client, "smoke test prompt", &repo_root);
        if want_json {
            let json = match &result {
                Ok(c) => format!(
                    r#"{{"ok":true,"provider":"{}","model":"{}"}}"#,
                    c.provider, c.model
                ),
                Err(inference_provider::ChainError::InvalidPrompt(msg)) => {
                    format!(r#"{{"ok":false,"error":"invalid_prompt","message":"{msg}"}}"#)
                }
                Err(inference_provider::ChainError::AllProvidersFailed { attempts }) => {
                    format!(
                        r#"{{"ok":false,"error":"all_providers_failed","attempts":{attempts}}}"#
                    )
                }
            };
            println!("{json}");
        } else {
            match &result {
                Ok(c) => println!("OK provider={} model={}", c.provider, c.model),
                Err(e) => println!("ERR {e:?}"),
            }
        }
        return match result {
            Ok(_) => Ok(()),
            Err(_) => std::process::exit(1),
        };
    }

    // `chump agent-run` (INFRA-3475) — the external-repo execution keystone. Runs
    // the OS's OWN agent (chump-local: ProviderCascade + the full tool set incl.
    // git_push/gh) on an ad-hoc prompt inside a working dir. NO gap lookup — this
    // is the primitive that sidesteps execute_gap's gap-source/file-root conflation,
    // so `chump improve` can default to chump-local (spawn this in the clone) instead
    // of the claude CLI. See docs/design/EXTERNAL_REPO_EXECUTION.md.
    if args.get(1).map(String::as_str) == Some("agent-run") {
        let (prompt_file, cwd) = parse_agent_run_args(&args);
        // EFFECTIVE-342: --slim builds the agent with the proven free-tier
        // dispatch profile (slim writer toolset incl patch_file, no read-only
        // bloat) instead of the full inventory. Without it, weak/free models
        // (the default provider cascade) loop on list_dir/read_file and return
        // code as *text* without ever calling patch_file — so nothing lands on
        // disk. This is the same profile the fleet's execute-gap path ships with.
        let slim = args.iter().any(|a| a == "--slim");
        let prompt = match prompt_file {
            Some(f) => std::fs::read_to_string(&f).unwrap_or_else(|e| {
                eprintln!("chump agent-run: cannot read --prompt-file {f}: {e}");
                std::process::exit(2);
            }),
            None => {
                use std::io::Read;
                let mut buf = String::new();
                let _ = std::io::stdin().read_to_string(&mut buf);
                buf
            }
        };
        if prompt.trim().is_empty() {
            eprintln!("chump agent-run: empty prompt (pass --prompt-file <f> or pipe via stdin)");
            std::process::exit(2);
        }
        // CREDIBLE-189: capture chump's OWN root BEFORE CHUMP_REPO is repointed at
        // --cwd below, so the per-run cost emit at exit lands in chump's ambient
        // stream (where cost_watch/bench read it), not the external clone's.
        let cost_emit_root = crate::repo_path::repo_root();
        // Root the agent's file tools at --cwd (the external clone/worktree) so its
        // edits land THERE, not in the chump repo. This is the external analog of a
        // linked worktree: gap/context come from chump, files live in the target.
        if let Some(dir) = cwd {
            std::env::set_var("CHUMP_REPO", &dir);
            if let Err(e) = std::env::set_current_dir(&dir) {
                eprintln!("chump agent-run: cannot cd to --cwd {dir}: {e}");
                std::process::exit(2);
            }
        }
        // Unattended primitive: there's no human to approve tool calls, so clear
        // the approval ask-list. The .env may set CHUMP_TOOLS_ASK=write_file,...
        // which otherwise DENIES write_file/patch_file/git_commit when no event
        // channel exists to approve them (the runtime proof of INFRA-3475 caught
        // write_file being denied). Mirrors build_free_tier_agent's discipline.
        std::env::remove_var("CHUMP_TOOLS_ASK");
        let agent: anyhow::Result<crate::agent_loop::ChumpAgent> = if slim {
            // EFFECTIVE-342: the working provider cascade + the slim free-tier
            // writer toolset (patch_file + search, no read-only bloat) + no
            // system prompt. This is the combination that makes weak/free models
            // actually WRITE files. NOTE: we deliberately do NOT reuse
            // execute_gap::build_free_tier_agent — that forces the cascade OFF and
            // a single rotation-configured provider, which 404s to a local model
            // when no free-tier rotation is set. Keep the cascade ON here.
            let provider = crate::provider_cascade::global_provider();
            let mut registry = axonerai::tool::ToolRegistry::new();
            crate::tool_inventory::register_free_dispatch_tools(&mut registry);
            let max_iter = std::env::var("CHUMP_AGENT_MAX_ITER")
                .ok()
                .and_then(|s| s.parse::<usize>().ok())
                .unwrap_or(30);
            Ok(crate::agent_loop::ChumpAgent::new(
                provider, registry, None, None, None, max_iter,
            ))
        } else {
            crate::agent_factory::build_chump_agent_cli().map(|(agent, _ready)| agent)
        };
        match agent {
            Ok(agent) => match agent.run(&prompt).await {
                Ok(o) => {
                    print!("{}", o.reply);
                    // CREDIBLE-189: emit this agent-run's model-token cost to CHUMP's
                    // ambient session_end. The rows were bare, so the bench couldn't
                    // attribute per-lap cost (bench.rs:124) — cost_watch/waste-tally/
                    // kpi already read input_tokens/output_tokens off session_end.
                    // agent-run is the gap-less primitive: key by env session/gap if
                    // present, else a sentinel. (Model field is a follow-up slice —
                    // needs a reliable cascade-model source + a signature change;
                    // the bare-row token hole is the core of this gap.)
                    let (in_tok, out_tok) = chump_cost_tracker::token_totals();
                    if in_tok > 0 || out_tok > 0 {
                        let sid = std::env::var("CHUMP_SESSION_ID")
                            .unwrap_or_else(|_| "agent-run".to_string());
                        let gid = std::env::var("CHUMP_GAP_ID").unwrap_or_default();
                        crate::session_ledger::emit_session_end(
                            &cost_emit_root,
                            &sid,
                            &gid,
                            crate::session_ledger::Outcome::Shipped,
                            Some(crate::session_ledger::TokenCounts {
                                input_tokens: in_tok,
                                output_tokens: out_tok,
                                cache_read_tokens: 0,
                            }),
                        );
                    }
                    return Ok(());
                }
                Err(e) => {
                    eprintln!("chump agent-run: agent error: {e:#}");
                    std::process::exit(1);
                }
            },
            Err(e) => {
                eprintln!("chump agent-run: build failed: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump ambient emit <kind> [...]` (INFRA-1048) — harness-agnostic
    // event-write CLI. Replaces the Claude-Code-specific PreToolUse hook
    // shell+python+flock chain for non-Claude harnesses. See
    // docs/process/AGENT_API.md §3 for the contract; specced via INFRA-1050.
    if args.get(1).map(String::as_str) == Some("ambient")
        && args.get(2).map(String::as_str) == Some("emit")
    {
        if args.iter().any(|a| a == "--help" || a == "-h") {
            println!(
                "Usage: chump ambient emit <kind> [--gap GAP-ID] [--source NAME] \\\n         [--harness NAME] [--field key=value]..."
            );
            println!();
            println!(
                "Write one event line to .chump-locks/ambient.jsonl. Auto-fills ts (RFC3339 UTC),"
            );
            println!("session (CHUMP_SESSION_ID > CLAUDE_SESSION_ID > worktree cache > derived),");
            println!(
                "worktree (basename of repo root), and harness (--harness > CHUMP_AGENT_HARNESS > 'unknown')."
            );
            println!();
            println!("Examples:");
            println!("  chump ambient emit file_edit --gap INFRA-1048 --field path=src/main.rs");
            println!("  chump ambient emit commit --field sha=abc1234 --field msg='fix: x'");
            return Ok(());
        }
        // Slice off args[0] (binary name) so from_argv sees
        // ["ambient", "emit", <kind>, ...flags].
        let parsed = match ambient_emit::EmitArgs::from_argv(&args[1..]) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("chump ambient emit: {e:#}");
                eprintln!("Run `chump ambient emit --help` for usage.");
                std::process::exit(2);
            }
        };
        let path = match ambient_emit::emit(&parsed) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("chump ambient emit: {e:#}");
                std::process::exit(1);
            }
        };
        // Stderr so stdout stays clean for chained commands (e.g. backtick capture).
        eprintln!("[ambient] wrote {} ({})", parsed.kind, path.display());
        return Ok(());
    }

    // `chump curator status [--role ROLE] [--json]` /
    // `chump curator refresh <role> [--pr-url U] [--commit-sha S] [--gap-ids CSV]`
    // (INFRA-2185 — META-125 ring-the-bell operator surface). Mutates
    // canonical state (.chump-locks/curator-memory/<role>.json), so it's a
    // Rust CLI per the Rust-first criteria; scripts/coord/main-merge-listener.sh
    // and scripts/coord/post-merge-bell.sh are the shell glue that calls in.
    if args.get(1).map(String::as_str) == Some("curator") {
        let repo_root = repo_path::repo_root();
        match args.get(2).map(String::as_str) {
            Some("status") => {
                if args.iter().any(|a| a == "--help" || a == "-h") {
                    println!("Usage: chump curator status [--role ROLE] [--json]");
                    println!();
                    println!("Show each curator role's last post-merge refresh timestamp,");
                    println!("whether it is >24h stale on its lane, and open staleness findings.");
                    return Ok(());
                }
                let role_filter = args
                    .iter()
                    .position(|a| a == "--role")
                    .and_then(|i| args.get(i + 1))
                    .map(String::as_str);
                let rows = curator_bell::status_rows(&repo_root, role_filter);
                if args.iter().any(|a| a == "--json") {
                    let json: Vec<serde_json::Value> = rows
                        .iter()
                        .map(|r| {
                            serde_json::json!({
                                "role": r.role,
                                "last_refresh": r.last_refresh,
                                "stale": r.stale,
                                "open_findings": r.open_findings,
                            })
                        })
                        .collect();
                    println!("{}", serde_json::to_string_pretty(&json).unwrap());
                } else {
                    print!("{}", curator_bell::render_status_text(&rows));
                }
                return Ok(());
            }
            Some("refresh") => {
                if args.iter().any(|a| a == "--help" || a == "-h") {
                    println!("Usage: chump curator refresh <role> [--pr-url URL] [--commit-sha SHA] [--gap-ids CSV]");
                    println!();
                    println!(
                        "Manual or fan-out-triggered ring-the-bell for one curator: records the"
                    );
                    println!(
                        "merge in its memory file and re-evaluates staleness against current main."
                    );
                    return Ok(());
                }
                let role = match args.get(3) {
                    Some(r) if !r.starts_with("--") => r.clone(),
                    _ => {
                        eprintln!("chump curator refresh: missing <role>");
                        eprintln!("Usage: chump curator refresh <role> [--pr-url URL] [--commit-sha SHA] [--gap-ids CSV]");
                        std::process::exit(2);
                    }
                };
                let pr_url = args
                    .iter()
                    .position(|a| a == "--pr-url")
                    .and_then(|i| args.get(i + 1))
                    .cloned()
                    .unwrap_or_default();
                let commit_sha = args
                    .iter()
                    .position(|a| a == "--commit-sha")
                    .and_then(|i| args.get(i + 1))
                    .cloned()
                    .unwrap_or_default();
                let gap_ids: Vec<String> = args
                    .iter()
                    .position(|a| a == "--gap-ids")
                    .and_then(|i| args.get(i + 1))
                    .map(|s| {
                        s.split(',')
                            .map(str::trim)
                            .filter(|s| !s.is_empty())
                            .map(str::to_string)
                            .collect()
                    })
                    .unwrap_or_default();
                let mem = curator_bell::refresh(
                    &repo_root,
                    &curator_bell::RefreshArgs {
                        role: role.clone(),
                        pr_url,
                        commit_sha,
                        gap_ids,
                    },
                );
                println!(
                    "chump curator refresh: {} refreshed at {} ({} seen_merges, {} findings)",
                    mem.role,
                    mem.last_refresh.as_deref().unwrap_or("?"),
                    mem.seen_merges.len(),
                    mem.staleness_findings.len(),
                );
                return Ok(());
            }
            _ => {
                eprintln!("chump curator: unknown subcommand");
                eprintln!("Try: chump curator <status|refresh> [args…]");
                std::process::exit(2);
            }
        }
    }

    // `chump ship plan` (INFRA-1229 slice 1) — pure planner that decides
    // REBASE / ARM / WAIT / CONFLICT-RECOVER / etc. given a snapshot of
    // PR + branch state. Today's bot-merge.sh consumes the output as a
    // structured JSON plan and dispatches; slice 2 (separate PR) will
    // move the executor side into Rust as well.
    if args.get(1).map(String::as_str) == Some("ship")
        && args.get(2).map(String::as_str) == Some("plan")
    {
        if args.iter().any(|a| a == "--help" || a == "-h") {
            println!("Usage: chump ship plan [--gap GAP-ID] [--pr N] [--branch B] [--json|--human] [--dry-run]");
            println!();
            println!("Decide the next ship action for a branch + PR given their current state.");
            println!("Output is a structured ShipPlan JSON (default) suitable for bot-merge.sh");
            println!("or any other consumer to dispatch on. The planner does no mutations.");
            println!();
            println!("Inputs are gathered by calling `gh api` for the PR + check-runs and");
            println!("`git rev-list --count` for behind/ahead. --dry-run uses synthetic state.");
            return Ok(());
        }
        return ship_plan_cli(&args[3..]).await;
    }

    // `chump ship execute` (INFRA-1229 slice 2) — walks the ExecutorStep
    // list derived from a ShipPlan via std::process::Command. Reads the
    // plan JSON from --plan <file> or --stdin. Mutates state — pair with
    // --dry-run to inspect without executing.
    if args.get(1).map(String::as_str) == Some("ship")
        && args.get(2).map(String::as_str) == Some("execute")
    {
        if args.iter().any(|a| a == "--help" || a == "-h") {
            println!("Usage: chump ship execute (--plan PATH | --stdin) [--dry-run] [--json]");
            println!();
            println!("Read a ShipPlan JSON (from `chump ship plan`) and execute the");
            println!("derived ExecutorStep list. Emits an ExecuteResult JSON with the");
            println!("rc + stderr_tail for each step. --dry-run prints steps; runs none.");
            println!();
            println!("Pipe pattern:");
            println!("  chump ship plan --gap INFRA-989 --pr 1913 | chump ship execute --stdin");
            return Ok(());
        }
        return ship_execute_cli(&args[3..]).await;
    }

    // `chump ship` executor (Milestone 3): `chump ship [run] --gap <ID> [--mode manual|bot-merge] [--gate-arm-check] ...`
    if args.get(1).map(String::as_str) == Some("ship") {
        let mut ship_argv: Vec<String> = vec!["chump-ship".to_string()];
        let tail = match args.get(2).map(String::as_str) {
            Some("run") => &args[3..],
            Some("bot-merge") => {
                ship_argv.push("--mode".to_string());
                ship_argv.push("bot-merge".to_string());
                &args[3..]
            }
            _ => &args[2..],
        };
        ship_argv.extend_from_slice(tail);
        let code = chump_ship::cli::run_from_itr(ship_argv).await;
        std::process::exit(code as i32);
    }

    // `chump hook <install|pre-commit|pre-push|status>` (Milestone 3) — cross-platform Rust git hook firewall.
    if args.get(1).map(String::as_str) == Some("hook") {
        let sub = args.get(2).map(String::as_str).unwrap_or("--help");
        match sub {
            "install" => {
                let explicit = args
                    .windows(2)
                    .find(|w| w[0] == "--repo")
                    .map(|w| std::path::PathBuf::from(&w[1]));
                let root = crate::service_cmd::resolve_active_git_repo(explicit.as_deref());
                match chump_git_hooks::install_hooks(&root) {
                    Ok(report) => {
                        println!(
                            "Installed portable git hooks in {}:\n  - {}\n  - {}",
                            report.hooks_dir.display(),
                            report.pre_commit_path.display(),
                            report.pre_push_path.display()
                        );
                        return Ok(());
                    }
                    Err(e) => {
                        eprintln!("chump hook install failed: {e}");
                        std::process::exit(1);
                    }
                }
            }
            "status" => {
                let explicit = args
                    .windows(2)
                    .find(|w| w[0] == "--repo")
                    .map(|w| std::path::PathBuf::from(&w[1]));
                let root = crate::service_cmd::resolve_active_git_repo(explicit.as_deref());
                let st = chump_git_hooks::hooks_status(&root);
                println!("hooks_dir: {}", st.hooks_dir.display());
                println!(
                    "pre-commit: {}",
                    if st.pre_commit_installed {
                        "installed"
                    } else {
                        "not installed"
                    }
                );
                println!(
                    "pre-push:   {}",
                    if st.pre_push_installed {
                        "installed"
                    } else {
                        "not installed"
                    }
                );
                return Ok(());
            }
            "pre-commit" => {
                let code = chump_git_hooks::run_pre_commit_cli();
                std::process::exit(code as i32);
            }
            "pre-push" => {
                let remote = args.get(3).cloned();
                let stdin_buf = match chump_git_hooks::read_stdin_to_string() {
                    Ok(s) => s,
                    Err(e) => {
                        eprintln!("[chump hook pre-push] failed reading stdin: {e}");
                        std::process::exit(1);
                    }
                };
                let code = chump_git_hooks::run_pre_push_cli(remote, &stdin_buf);
                std::process::exit(code as i32);
            }
            _ => {
                println!("Usage: chump hook <install|pre-commit|pre-push|status>");
                println!();
                println!("Subcommands:");
                println!("  install     Write portable #!/bin/sh pre-commit & pre-push shims to git hooks dir");
                println!("  pre-commit  Run the cross-platform Rust pre-commit guard chain");
                println!("  pre-push    Run the cross-platform Rust pre-push guard chain");
                println!("  status      Show whether Rust hook shims are installed");
                if sub == "--help" || sub == "-h" || sub == "help" {
                    return Ok(());
                }
                std::process::exit(2);
            }
        }
    }

    // `chump up` & `chump service <install|uninstall|status>` & `chump --worker-tick` (Milestone 4)
    if args.get(1).map(String::as_str) == Some("up") {
        std::process::exit(service_cmd::run_up_cli(&args[2..]));
    }
    if args.get(1).map(String::as_str) == Some("service") {
        std::process::exit(service_cmd::run_service_cli(&args[2..]));
    }
    if args.get(1).map(String::as_str) == Some("--worker-tick") {
        std::process::exit(service_cmd::run_worker_tick());
    }

    // `chump init` (UX-001) — first-run setup: detect model, write .env, start server, open browser.
    // Flags: --port N (override CHUMP_WEB_PORT), --no-browser (skip step 4 — for CI / FTUE).
    if args.get(1).map(String::as_str) == Some("init") {
        let init_args = match chump_init::InitArgs::from_argv(&args[2..]) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("chump init: {e:#}");
                eprintln!("usage: chump init [--port N] [--no-browser]");
                std::process::exit(2);
            }
        };
        let repo_root = repo_path::repo_root();
        if let Err(e) = chump_init::run_init(&repo_root, &init_args) {
            eprintln!("chump init: {e:#}");
            std::process::exit(1);
        }
        return Ok(());
    }

    // `chump funnel` (PRODUCT-015) — read .chump-locks/ambient.jsonl and print
    // the three-row activation funnel: install → first_task → return_d2.
    if args.get(1).map(String::as_str) == Some("funnel") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump funnel");
            println!();
            println!(
                "Print install → first_task → return_d2 activation funnel from ambient events."
            );
            println!();
            println!("Example:");
            println!("  chump funnel");
            return Ok(());
        }
        activation::print_funnel();
        return Ok(());
    }

    // `chump claim <GAP-ID> [--paths X,Y,...]` (INFRA-468) — atomic
    // replacement for the 6-step shell dance documented in CLAUDE.md's
    // mandatory pre-flight: fetch + verify-gap + health-probe + worktree
    // + lease-write + import-if-drifted, all in one call. Each step has
    // its own bypass env for testing / unusual setups.
    if args.get(1).map(String::as_str) == Some("claim") {
        let repo_root = repo_path::repo_root();

        // RESILIENT-069: farmer readiness gate. RED = farmer has positive
        // evidence of trouble (stale heartbeat, exit-78 supervisor, a
        // paused-fleet sentinel, or a known-broken auth cache) — admit no
        // NEW claims until it's lights-on again. Bypass: --skip-farmer-gate
        // (stripped before handing args to ClaimArgs::from_argv, which
        // rejects unrecognized flags).
        let farmer_gate_bypass = args.iter().any(|a| a == "--skip-farmer-gate");
        let claim_argv: Vec<String> = args[1..]
            .iter()
            .filter(|a| a.as_str() != "--skip-farmer-gate")
            .cloned()
            .collect();
        // CREDIBLE-291: validate the request (GAP-ID format) BEFORE the farmer
        // readiness gate. A malformed/invalid GAP-ID must return a format error
        // regardless of farmer GREEN/RED — otherwise a transient farmer-RED flap
        // makes `claim <bad-id>` print "farmer status RED" instead of the format
        // error, failing test-cli-integration.sh (fast-checks) and cascading
        // fast-checks -> test -> verified red on EVERY code PR (fleet-wide
        // false-red jam, 2026-08-20). Mirrors CREDIBLE-166's autonomy-gate fix:
        // validate request shape before any health/admission gate.
        let claim_args = match atomic_claim::ClaimArgs::from_argv(&claim_argv, repo_root.clone()) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("chump claim: {e:#}");
                // INFRA-5486 (INFRA-1863 slice): AC2 requires exit code 1
                // specifically for the missing-mandatory-`--role` case;
                // other argument errors keep the existing exit code 2.
                if format!("{e:#}").contains("missing required flag --role") {
                    std::process::exit(1);
                }
                eprintln!();
                eprintln!("Usage: chump claim <GAP-ID> --role ROLE [--paths CSV] [--session ID]");
                eprintln!("                          [--skip-doctor|--no-doctor] [--skip-import|--no-import]");
                eprintln!("                          [--scope SCOPE]");
                eprintln!();
                eprintln!("Atomically: fetch origin/main, verify the gap, run chump-doctor,");
                eprintln!("create a linked worktree, write the lease. Replaces the 6-step");
                eprintln!("shell dance in CLAUDE.md mandatory pre-flight (INFRA-468).");
                std::process::exit(2);
            }
        };

        // RESILIENT-069 + RESILIENT-1636: farmer readiness gate. Admit no NEW
        // claims until the farmer is lights-on — BUT do not re-gate the ship
        // step of work a dispatch/chain lane already claimed. bot-merge
        // re-invokes `chump claim` to re-enter the worktree whose lease the
        // dispatch already holds; on a paused node that re-claim used to die at
        // the gate (every dispatch shipped only via salvage). The admission
        // decision (re-entry vs NEW claim) lives in Rust (R6 invariant), keyed
        // on a live lease for (gap, CHUMP_SESSION_ID). Runs AFTER format
        // validation (CREDIBLE-291) so a farmer blip never masks a bad-request.
        if !farmer_gate_bypass && !claim_args.lease_only {
            let env_session = std::env::var("CHUMP_SESSION_ID").ok();
            match farmer_status::claim_admission(
                &repo_root,
                &claim_args.gap_id,
                env_session.as_deref(),
            ) {
                farmer_status::ClaimAdmission::Green => {}
                farmer_status::ClaimAdmission::ReentryAdmit { note } => {
                    // Print to STDOUT so bot-merge / `chump dispatch` can surface
                    // the admission reason (AC: bot-merge prints to stdout).
                    println!("chump claim: {note}");
                }
                farmer_status::ClaimAdmission::Refuse { status } => {
                    // Print the refusal reason to BOTH stdout (so bot-merge /
                    // `chump dispatch` carry it in their reason field) and stderr.
                    let header = if status.paused {
                        "chump claim: farmer PAUSED — no new claims admitted."
                    } else {
                        "chump claim: farmer status RED — no new claims admitted."
                    };
                    println!("{header}");
                    eprintln!("{header}");
                    for r in &status.reasons {
                        println!("  - {r}");
                        eprintln!("  - {r}");
                    }
                    println!("Run `chump farmer status` for detail.");
                    eprintln!("Run `chump farmer status` for detail. Bypass: --skip-farmer-gate");
                    std::process::exit(1);
                }
            }
        }
        match atomic_claim::run_claim(claim_args) {
            Ok(report) => {
                atomic_claim::print_report(&report);
                return Ok(());
            }
            Err(e) => {
                eprintln!("chump claim: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump preflight` (INFRA-1670) — local CI mirror.
    // Runs cargo fmt --check, clippy -D warnings, check; optionally
    // selected scripts/ci/test-*.sh with --with-tests. Catches the
    // failure classes that bit us most often on GH Actions (cargo fmt
    // drift, clippy dead_code, INFRA-682 path-filter, INFRA-1287
    // registry-orphan, etc.) in <60s warm instead of ~15 min round-trip.
    if args.get(1).map(String::as_str) == Some("preflight") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(preflight::run(&sub_args));
    }

    // `chump cron install|uninstall|status` (INFRA-2057) — declarative cron
    // expr to launchd plist (macOS) / systemd user timer (Linux) generator.
    // Fleet-durable scheduling: never depends on any agent session being alive.
    if args.get(1).map(String::as_str) == Some("cron") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(chump_cron::run(&sub_args));
    }

    // `chump verify` (CREDIBLE-155) — unified policy engine: typed rules
    // over parsed diff semantics, one implementation for git hooks and CI.
    // All logic lives in src/verify/ (INFRA-3287: keep this arm tiny).
    if args.get(1).map(String::as_str) == Some("verify") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(verify::run(&sub_args));
    }

    // `chump self-rescue-loop [--execute] [--grace-secs N]` (EFFECTIVE-088) — the
    // autonomous conductor: detect a wedged fleet → propose self-rescue on the
    // consensus bus → objection window → act. Dry-run unless --execute. Obeys the
    // autonomy dial + kill switch. Intended to run as a launchd daemon.
    if args.get(1).map(String::as_str) == Some("self-rescue-loop") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(fleet_self_rescue_conductor::run(&sub_args));
    }

    // `chump session-summary` (INFRA-1437) — list merged + armed + filed PRs
    // in the current session window. Replaces the manual ambient.jsonl + gh
    // pr list scrape that PM-curator + operator were doing at every session
    // end (~5 min of work).
    if args.get(1).map(String::as_str) == Some("session-summary") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(session_summary::run(&sub_args));
    }

    // `chump pe-suite status` (INFRA-2229, META-127/C7) — P&E suite operator
    // dashboard: active curators, FEEDBACK engagement, consensus convergence.
    // Reads .chump-locks/ + ambient.jsonl; no network calls required.
    if args.get(1).map(String::as_str) == Some("pe-suite") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        // sub_args[0] should be "status"; any other subcommand errors gracefully.
        let subcmd = sub_args.first().map(String::as_str).unwrap_or("status");
        match subcmd {
            "status" => {
                let flags: Vec<String> = sub_args.iter().skip(1).cloned().collect();
                std::process::exit(pe_suite_status::run(&flags));
            }
            "-h" | "--help" | "help" => {
                println!("Usage: chump pe-suite <subcommand>");
                println!();
                println!("Subcommands:");
                println!("  status [--json]  Show P&E suite operator dashboard (INFRA-2229)");
                std::process::exit(0);
            }
            other => {
                eprintln!("chump pe-suite: unknown subcommand '{}'", other);
                eprintln!("Try: chump pe-suite status [--json]");
                std::process::exit(1);
            }
        }
    }

    // External-repo command group (onboard / improve / external verify-merge).
    // Extracted to commands::dispatch_external (INFRA-3289, slice 1 of INFRA-3287).
    if let Some(code) = commands::dispatch_external::try_dispatch(&args) {
        std::process::exit(code);
    }

    // `chump ingest <repo-path>` (INFRA-1780, phase 1a of INFRA-1746) —
    // repo validation + read-only safety only. No filesystem mutation, no
    // network calls. Later phases add the actual scanning/writing.
    if args.get(1).map(String::as_str) == Some("ingest") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(ingest::run(&sub_args));
    }

    // `chump ingest-preflight <owner/repo|url|local-path>` (INFRA-1778) —
    // verifies gh auth + push access before any ingest phase runs. Read-only.
    if args.get(1).map(String::as_str) == Some("ingest-preflight") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(ingest_preflight::run(&sub_args));
    }

    // `chump scan <repo-path> [--max-gaps N]` (INFRA-1882, 2026 demo #2) —
    // local read-only heuristics against a sibling repo, files up to
    // --max-gaps concrete gaps straight into the TARGET repo's own
    // .chump/state.db. Pairs with `chump fleet-mode --takeover`.
    if args.get(1).map(String::as_str) == Some("scan") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(scan::run(&sub_args));
    }

    // `chump cartograph <target-repo-path> [--json]` (INFRA-1782, phase 2 of
    // INFRA-1746) — static, read-only scan of a target repo that writes
    // <target-repo-path>/docs/ARCHITECTURE.md. No LLM calls, no network
    // calls; the only write is ARCHITECTURE.md itself.
    if args.get(1).map(String::as_str) == Some("cartograph") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(cartographer::run(&sub_args));
    }

    // `chump evangelize <target-repo-path> [--json]` (INFRA-1783, phase 3 of
    // INFRA-1746) — static, read-only scan of a target repo that writes
    // <target-repo-path>/docs/HIDDEN_GEMS.md. No LLM calls, no network
    // calls; the only write is HIDDEN_GEMS.md itself.
    if args.get(1).map(String::as_str) == Some("evangelize") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(evangelist::run(&sub_args));
    }

    // `chump harvest <scan|check|brief|deep-scan|list-clusters>` (INFRA-1823)
    // — Fleet Cartographer CLI. Productizes the Harvester (previously a
    // Claude-Code-session-only shell script + agent) as a first-class chump
    // engine capability, usable from any harness.
    if args.get(1).map(String::as_str) == Some("harvest") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(harvester_cli::run(&sub_args));
    }

    // `chump admit <claude|cargo> [--wait-s N]` (INFRA-8219) — node-wide
    // admission ceiling. Exits 0 when a slot is free, 75 when deferred.
    if args.get(1).map(String::as_str) == Some("admit") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(admit::run(&sub_args));
    }

    // `chump rules <audit|check-budget> [--window 30d] [--json]` (ZERO-WASTE-125)
    // — self-pruning rulebook auditor and one-in-one-out doc budget ratchet.
    if args.get(1).map(String::as_str) == Some("rules") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(rules_audit::run(&sub_args));
    }

    // `chump systematize <target-repo-path> [--json]` (INFRA-1783, phase 4 of
    // INFRA-1746) — static, read-only scan of a target repo that writes
    // <target-repo-path>/docs/CAPABILITIES_REGISTRY.json. No LLM calls, no
    // network calls; the only write is CAPABILITIES_REGISTRY.json itself.
    if args.get(1).map(String::as_str) == Some("systematize") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(systematizer::run(&sub_args));
    }

    // `chump vote <corr_id> <+1|-1|0> --reason <text>` (META-159) —
    // emit a FEEDBACK kind=vote event via the broadcast.sh FEEDBACK pathway.
    // Enabled by default (CREDIBLE-179); CHUMP_FLEET_RECV_SIDE_V0=0 opts out,
    // printing "feature flag off, vote not emitted" and exiting 0.
    if args.get(1).map(String::as_str) == Some("vote") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(commands::vote::run(&sub_args));
    }

    // `chump consensus ask <question> --reason <text> [--id <id>] [--block]
    // [--timeout <secs>]` (INFRA-2156, META-125/C5) — publish a fleet
    // decision question onto the existing FEEDBACK kind=proposal channel
    // and return a consensus_id; --block polls ambient.jsonl for the
    // deliberator's consensus_result up to --timeout seconds.
    // Enabled by default (CREDIBLE-179), same flag as `chump vote`.
    if args.get(1).map(String::as_str) == Some("consensus")
        && args.get(2).map(String::as_str) == Some("ask")
    {
        let sub_args: Vec<String> = args.iter().skip(3).cloned().collect();
        std::process::exit(commands::consensus_ask::run(&sub_args));
    }

    // `chump unwedge <GAP-ID> [--stall-threshold-s N] [--dry-run]` (EFFECTIVE-1136,
    // EFFECTIVE-178 slice) — on-demand kill + recover of a wedged bot-merge
    // run: detects a stalled `bot-merge.sh --gap <ID>` process past the
    // stall threshold, kills it (+ children), aborts any in-progress
    // rebase/merge and clears stale git locks, then invokes
    // `chump claim <ID> --force-recover` to reconcile the lease/worktree.
    // Emits kind=gap_unwedged.
    if args.get(1).map(String::as_str) == Some("unwedge") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(commands::unwedge::run(&sub_args));
    }

    // `chump voice --wedge-class <id> --minutes-lost <int> ...` (INFRA-2258) —
    // file a Voice-of-Agent (VOA) report: writes docs/gaps/VOA-NNNN.yaml +
    // docs/voice/VOA-NNNN-FULL.yaml and emits kind=voice_of_agent_filed.
    // Optional --ship to open a PR against repairman29/chump.
    if args.get(1).map(String::as_str) == Some("voice") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(commands::voice::run(&sub_args));
    }

    // `chump source-resolve "<capability keyword>"` (INFRA-3508, COTG-S.1) —
    // resolve a capability against repo -> arsenal -> world prior art BEFORE
    // building. See src/sourcing_resolver.rs for the tiered resolution logic.
    if args.get(1).map(String::as_str) == Some("source-resolve") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(commands::source_resolve::run(&sub_args));
    }

    // `chump intervention-watchdog [--window H] [--apply] [--json]` (COTG-2.1/INFRA-3489) —
    // detect human touches in the fleet, class each as an autonomy_defect, file self-heal gaps.
    if args.get(1).map(String::as_str) == Some("intervention-watchdog") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(intervention_watchdog::run(&sub_args));
    }

    // `chump bench run --track <path> [--apply] [--json]` (DOC-072/EFFECTIVE-327) —
    // run a ChumpBench track as a scoreable lap: grade the acceptance check + tally human touches.
    if args.get(1).map(String::as_str) == Some("bench") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(bench::run(&sub_args));
    }

    // `chump demo [--seed N] [--duration 60m] [--dry-run] ...` (INFRA-2391) —
    // wires the META-072 chump-demo crate (Track-3 autonomous-throughput
    // demo loop) in as a first-class subcommand instead of leaving it as an
    // undiscoverable standalone binary. Execs the sibling chump-demo binary
    // built by this workspace, forwarding args + exit code.
    if args.get(1).map(String::as_str) == Some("demo") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(commands::demo::run(&sub_args));
    }

    // `chump config [show] [--json]` (INFRA-2371) — runtime cascade /
    // privacy / MCP snapshot. Pure read; never invokes an LLM, so it's
    // safe to run when the cascade is wedged. Solves the daily-friction
    // case where bare `chump config` previously fell through to the LLM
    // gen path and 400'd from Gemini.
    if args.get(1).map(String::as_str) == Some("config") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(commands::config::run(&sub_args));
    }

    // `chump consensus-tally [--corr-id X | --all] [--since <dur>]` (META-159) —
    // aggregate FEEDBACK kind=vote events from ambient.jsonl per corr_id
    // and compute a verdict. Always runs regardless of feature flag (read-only).
    if args.get(1).map(String::as_str) == Some("consensus-tally") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(commands::consensus_tally::run(&sub_args));
    }

    // `chump consensus resolve <corr_id> [--since <dur>]` /
    // `chump consensus status [<corr_id> | --all] [--since <dur>]`
    // (INFRA-2158, META-125/C7) — resolve productizes the deliberator's
    // tally + kind=consensus_result emission as a directly-callable CLI;
    // status makes the resulting decision state queryable (durable
    // consensus_result if reached, else a live tally). Always runs
    // regardless of feature flag (read-only aggregation; resolve's only
    // write is the ambient.jsonl append on a reached decision).
    if args.get(1).map(String::as_str) == Some("consensus") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(commands::consensus::run(&sub_args));
    }

    // `chump sibling-status [--json] [--watch]` (META-154) — per-active-lease
    // progress matrix. Beats "lease exists" by classifying each holder as
    // progressing / in-flight / heartbeat-only / stalled / silent / expired.
    if args.get(1).map(String::as_str) == Some("sibling-status") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(commands::sibling_status::run(&sub_args));
    }

    // `chump claim-lint --range <base>..<head> [--message-file <path>]
    //   [--test-log <path>] [--model <name>] [--gap-id <id>] [--json]
    //   [--no-emit]` (CREDIBLE-208) — pre-ship bullshit gate: ground an
    // agent's claims (commit/PR text) against the diff. Bounces (exit 1)
    // with the specific ungrounded claim named on any bust.
    if args.get(1).map(String::as_str) == Some("claim-lint") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(commands::claim_lint::run(&sub_args));
    }

    // `chump inventory <rebuild|show|debt-report|...>` (META-271) —
    // fleet inventory + tech-debt review-only audit. ALL detector findings
    // land at tier=0 (surface-only) — never auto-files a gap, never removes
    // code. Operator runs `chump inventory review` to classify findings, then
    // `chump inventory promote <class>` after ≥10 reviewed + ≥70% RP ratio.
    // Tier-2 auto-file machinery deferred to INFRA-2374.
    if args.get(1).map(String::as_str) == Some("inventory") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(commands::inventory::run(&sub_args));
    }

    // `chump contract-scan [--in-flight] [--against <pr-number>]` (INFRA-2405) —
    // detect cross-PR state-file/IPC schema mismatches. Triggered by INFRA-2404:
    // the main-preflight-watchdog (INFRA-2397) wrote {state, updated_at, last_tick_id}
    // while the claim main-health-gate (INFRA-2398) read {last_status, last_tick_at,
    // failing_gates} — keys never matched, the procedure layer shipped silently inert.
    // Exit 0 = clean, 1 = mismatches detected, 2 = scan failure.
    if args.get(1).map(String::as_str) == Some("contract-scan") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(commands::contract_scan::run(&sub_args));
    }

    // `chump bootstrap <intent> [--dir <path>] [--skip-arch-decision] [--with-roadmap]`
    // (INFRA-2265) — net-new product bootstrap entrypoint: empty dir → git init →
    // scaffold (Cargo.toml | package.json | pyproject.toml) → README.md → first commit
    // → umbrella gap via `chump gap reserve`. Sister of INFRA-1746 (`chump ingest`).
    // This is the SUBSTRATE-layer entrypoint; consumer surfaces own the founder-facing
    // pitch lane. Third demo-able 2026 outcome (META-067).
    if args.get(1).map(String::as_str) == Some("bootstrap") {
        let sub_args: Vec<String> = args.iter().skip(1).cloned().collect();
        std::process::exit(commands::bootstrap::run(&sub_args));
    }

    // `chump swe <prompt> [--budget-secs N] [--budget-tokens N]
    //   [--budget-dollars N] [--paths CSV] [--dry-run-diff]` (INFRA-2089) —
    // one-shot bounded SWE-agent wrapper: reserve+claim a synthetic gap from
    // the prompt, dispatch a headless sub-agent under budget, arm auto-merge,
    // emit kind=swe_invocation_complete. Productizes the existing per-gap
    // claim -> worktree -> subagent-dispatch -> auto-merge pipeline
    // (crate::dispatch::run) as a direct prompt-in surface (Bet 1,
    // MARKET_POSITIONING_2026-05-27 #2679).
    if args.get(1).map(String::as_str) == Some("swe") {
        let sub_args: Vec<String> = args.iter().skip(1).cloned().collect();
        std::process::exit(commands::swe::run(&sub_args));
    }

    // `chump roadmap-from-vision --vision <STR> --domain D [--outcome ID] [--max-gaps N] [--apply]`
    // (EFFECTIVE-425, COTG spine slice 1) — vision string -> validated Roadmap JSON;
    // with --apply, files each GapDraft via `chump gap reserve --outcome <id>` so
    // MISSION-045 / pillar / similarity gates apply. See commands::roadmap_from_vision.
    if args.get(1).map(String::as_str) == Some("roadmap-from-vision") {
        let sub_args: Vec<String> = args.iter().skip(1).cloned().collect();
        std::process::exit(commands::roadmap_from_vision::run(&sub_args).await);
    }

    // INFRA-2399 author-time helper commands (add-env-var / emit-event /
    // install-daemon / add-path-filter / add-raw-gh-allowlist).
    // Extracted to commands::dispatch_authoring (INFRA-3298, slice 2 of INFRA-3287).
    if let Some(code) = commands::dispatch_authoring::try_dispatch(&args) {
        std::process::exit(code);
    }

    // `chump inspect <gap-id>` (INFRA-1456) — eject-and-inspect surface.
    // Opens a 3-pane tmux session (or text snapshot if --no-tmux) for the
    // active lease of the given gap: worktree shell, live ambient tail, and
    // recent ambient events. Marcus's Saturday-morning-uninstall scenario.
    if args.get(1).map(String::as_str) == Some("inspect") {
        let gap_id = match args.get(2) {
            Some(id) => id.clone(),
            None => {
                eprintln!("Usage: chump inspect <gap-id> [--no-tmux]");
                std::process::exit(2);
            }
        };
        let no_tmux = args.iter().any(|a| a == "--no-tmux");
        let repo_root = repo_path::repo_root();
        match inspect_cmd::run(&repo_root, &gap_id, !no_tmux) {
            Ok(()) => return Ok(()),
            Err(e) => {
                eprintln!("chump inspect: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump resume <gap-id>` (INFRA-1456) — validate worktree recoverability.
    // Checks lease present, worktree on disk, no dangling rebase/merge state,
    // no uncommitted churn. Prints verdict and emits kind=gap_resumed.
    if args.get(1).map(String::as_str) == Some("resume") {
        let gap_id = match args.get(2) {
            Some(id) => id.clone(),
            None => {
                eprintln!("Usage: chump resume <gap-id>");
                std::process::exit(2);
            }
        };
        let repo_root = repo_path::repo_root();
        match resume_cmd::run(&repo_root, &gap_id) {
            Ok(verdict) => {
                println!("{}", verdict.summary());
                let exit_code = if verdict == resume_cmd::ResumeVerdict::Ready {
                    0
                } else {
                    1
                };
                std::process::exit(exit_code);
            }
            Err(e) => {
                eprintln!("chump resume: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump scrap <gap-id>` (INFRA-1456) — clean teardown of a wedged gap.
    // Removes the worktree, deletes the lease JSON, deletes the local branch,
    // prunes dangling refs. Emits kind=gap_scrapped to ambient.jsonl.
    if args.get(1).map(String::as_str) == Some("scrap") {
        let gap_id = match args.get(2) {
            Some(id) => id.clone(),
            None => {
                eprintln!("Usage: chump scrap <gap-id>");
                std::process::exit(2);
            }
        };
        let repo_root = repo_path::repo_root();
        match scrap_cmd::run(&repo_root, &gap_id) {
            Ok(outcome) => {
                println!(
                    "scrap: worktree_removed={} lease_removed={} branch_deleted={}",
                    outcome.worktree_removed, outcome.lease_removed, outcome.branch_deleted
                );
                return Ok(());
            }
            Err(e) => {
                eprintln!("chump scrap: {e:#}");
                std::process::exit(1);
            }
        }
    }

    // `chump disk status|plan|budget` (INFRA-2196, META-128/C5) — operator + subprocess
    // surface for disk-aware fleet decisions. Reads ~/.chump/disk-inventory.json
    // (written by chump-disk-inventory-daemon INFRA-2193) and DISK_COST_MODEL.yaml
    // (INFRA-2195). Exit codes: 0=OK, 1=REFUSE, 2=WAIT (for `chump disk plan`).
    if args.get(1).map(String::as_str) == Some("disk") {
        let sub = args.get(2).map(String::as_str);
        let repo_root = repo_path::repo_root();
        let sub_args: Vec<String> = args.iter().skip(3).cloned().collect();
        let exit_code = match sub {
            Some("status") => match disk_cmd::run_status(&sub_args, &repo_root) {
                Ok(code) => code,
                Err(e) => {
                    eprintln!("chump disk status: {e:#}");
                    1
                }
            },
            Some("plan") => match disk_cmd::run_plan(&sub_args, &repo_root) {
                Ok(code) => code,
                Err(e) => {
                    eprintln!("chump disk plan: {e:#}");
                    1
                }
            },
            Some("budget") => match disk_cmd::run_budget(&sub_args, &repo_root) {
                Ok(code) => code,
                Err(e) => {
                    eprintln!("chump disk budget: {e:#}");
                    1
                }
            },
            _ => {
                println!("Usage: chump disk <subcommand> [options]");
                println!();
                println!("Subcommands:");
                println!("  status [--json]                     disk snapshot: total/free/used/headroom + top consumers");
                println!("  plan <action-class> [--count N]     OK|WAIT|REFUSE projection from DISK_COST_MODEL.yaml");
                println!("  budget [--for <action-class>]       max-safe-N for action class(es)");
                println!();
                println!("Env:");
                println!("  CHUMP_DISK_FLOOR_GB=5               free-space floor (default 5 GB)");
                println!(
                    "  CHUMP_DISK_INVENTORY_PATH=...       override ~/.chump/disk-inventory.json"
                );
                println!("  CHUMP_DISK_COST_MODEL_PATH=...      override docs/process/DISK_COST_MODEL.yaml");
                println!();
                println!("Exit codes (disk plan): 0=OK, 1=REFUSE, 2=WAIT");
                2
            }
        };
        std::process::exit(exit_code);
    }

    // `chump pr-rescue` (INFRA-1714) — closed-loop PR rescue. v0 handles two
    // mechanical failure patterns (orphan-allowlist, env-var-coverage) that
    // accounted for ~6 manual rescues in the 2026-05-22 ship session. See
    // src/pr_rescue.rs for the classifier + fixer logic.
    if args.get(1).map(String::as_str) == Some("pr-rescue") {
        let mut once = false;
        let mut dry_run = false;
        let mut pr: Option<u32> = None;
        let mut explain: Option<u32> = None;
        let mut i = 2;
        while i < args.len() {
            match args[i].as_str() {
                "--once" => once = true,
                "--dry-run" => dry_run = true,
                "--pr" => {
                    i += 1;
                    if i < args.len() {
                        pr = args[i].parse().ok();
                    }
                }
                "--explain" => {
                    i += 1;
                    if i < args.len() {
                        explain = args[i].parse().ok();
                    }
                }
                "--help" | "-h" => {
                    println!("chump pr-rescue [--once] [--pr N] [--dry-run] [--explain N]");
                    println!();
                    println!("Closed-loop PR rescue (INFRA-1714 v0). Auto-fixes two patterns:");
                    println!(
                        "  - orphan-allowlist: server-side rebase via gh pr update-branch --rebase"
                    );
                    println!(
                        "  - env-var-coverage: append missing vars to env-vars-internal.txt + push"
                    );
                    println!();
                    println!("Safety: CHUMP_PR_RESCUE_MAX_AGE_HOURS (default 24h), per-PR 5min cooldown,");
                    println!(
                        "        --force-with-lease only, never touches main, never touches DRAFT."
                    );
                    return Ok(());
                }
                _ => {
                    eprintln!("pr-rescue: unknown arg: {}", args[i]);
                    std::process::exit(2);
                }
            }
            i += 1;
        }
        let opts = pr_rescue::RescueOpts {
            once,
            pr,
            dry_run,
            explain,
        };
        match pr_rescue::run(opts) {
            Ok(()) => return Ok(()),
            Err(e) => {
                eprintln!("pr-rescue: {e}");
                std::process::exit(1);
            }
        }
    }

    // `chump completion [zsh|bash|fish]` (EFFECTIVE-010) — print shell completion script.

    Box::pin(ops_modes::dispatch_ops(args)).await
}
