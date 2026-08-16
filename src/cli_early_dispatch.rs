//! Early CLI dispatch table extracted from `main()` (INFRA-1965).
//!
//! `main()` in `src/main.rs` had grown to ~17,000 lines as a single giant
//! function containing a long sequence of `if args.get(1) == Some("cmd")`
//! blocks. That single-function shape meant any edit anywhere in the CLI
//! router forced rustc to re-typecheck/re-codegen the whole function as one
//! unit. This module holds one contiguous slice of that dispatch table
//! (commands `git-guard` through `fleet-status`) as its own function so it
//! can be edited/compiled independently of the rest of `main()`.
//!
//! Each `if` block here either diverges (`std::process::exit`) or returns
//! `Some(Result<()>)` to signal "this command matched, propagate this
//! result and return from `main()`". `None` means "no match here, fall
//! through to the rest of `main()`'s dispatch chain".

use chump_gap_store as gap_store;
use std::io::Write as _;

#[allow(clippy::too_many_lines)]
pub async fn dispatch(args: &[String]) -> Option<anyhow::Result<()>> {
    if args.get(1).map(String::as_str) == Some("git-guard") {
        std::process::exit(crate::git_safety::run_cli(args));
    }
    // RESILIENT-256: the load-bearing half. Writes a dirty checkout into the
    // object store (refs/wip/…) without touching its working tree or index,
    // so `reset --hard` stops being unrecoverable even when it is correct.
    if args.get(1).map(String::as_str) == Some("wip-snapshot") {
        std::process::exit(crate::git_safety::run_snapshot_cli(args));
    }

    // INFRA-1649 (re-do of INFRA-1598): `chump verify-claim-branch [--json]`
    // asserts the current git branch matches the branch implied by this
    // session's active claim lease. Dispatched here — ahead of store/config
    // init — so it's cheap enough to call from a pre-push hook on every
    // push (Guard 5 in scripts/git-hooks/pre-push already does the same
    // check inline in bash; this is the reusable Rust primitive for
    // non-hook callers).
    if args.get(1).map(String::as_str) == Some("verify-claim-branch") {
        std::process::exit(crate::verify_claim_branch::run_cli(args));
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
    crate::ensure_gh_token_env();

    // INFRA-2054 (META-114 freshness cluster, binary-staleness layer):
    // `chump --build-info [--json]` prints the build-time metadata baked
    // in by build.rs (full git SHA, build timestamp, rustc version,
    // workspace root). Separate from --version because consumers want the
    // structured form. Falls through unchanged if the flag is absent.
    if args.iter().any(|a| a == "--build-info") {
        let want_json = args.iter().any(|a| a == "--json");
        std::process::exit(crate::staleness::run_build_info_cli(want_json));
    }

    // INFRA-2054: `chump self-check-staleness [--threshold-age-s N]
    // [--threshold-commits N] [--json]` classifies the running binary
    // against two axes (file mtime age, commits-behind origin/main) and
    // exits 0/1/2 for FRESH/STALE/CRITICAL_STALE. Defaults match the
    // META-115 freshness preamble (3600s / 5 commits soft; 4x / 10x crit).
    if args.get(1).map(String::as_str) == Some("self-check-staleness") {
        let mut threshold_age_s: u64 = crate::staleness::DEFAULT_THRESHOLD_AGE_S;
        let mut threshold_commits: u64 = crate::staleness::DEFAULT_THRESHOLD_COMMITS;
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
                        crate::staleness::DEFAULT_THRESHOLD_AGE_S
                    );
                    println!(
                        "  --threshold-commits <N>   Soft commits-behind threshold (default {})",
                        crate::staleness::DEFAULT_THRESHOLD_COMMITS
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
        std::process::exit(crate::staleness::run_self_check_staleness_cli(
            threshold_age_s,
            threshold_commits,
            want_json,
        ));
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
            std::process::exit(crate::farmer_status::run_cli(&sub_args[1..]));
        }
        eprintln!("Usage: chump farmer status [--json] [--quiet]");
        std::process::exit(2);
    }

    // EFFECTIVE-009: no-args → help; `chump help` → help. Must come before
    // any mode that falls through to the interactive agent loop.
    let wants_help = args.len() == 1
        || args.get(1).map(String::as_str) == Some("help")
        || args.get(1).map(String::as_str) == Some("--help")
        || args.get(1).map(String::as_str) == Some("-h");
    if wants_help {
        crate::print_help();
        return Some(Ok(()));
    }

    if args.iter().any(|a| a == "--desktop") {
        crate::desktop_launcher::launch_and_wait(args);
    }
    crate::load_dotenv();
    crate::local_openai::auto_configure_context_window().await;

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
        let b = crate::briefing::build_briefing(gap_id);
        // INFRA-1548: --json flag emits schema_version:1 JSON for harness consumers.
        if args.iter().any(|a| a == "--json") {
            println!("{}", crate::briefing::render_json(&b));
        } else {
            print!("{}", crate::briefing::render_markdown(&b));
        }
        return Some(Ok(()));
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
        let repo_root = crate::repo_path::repo_root();
        match crate::ci_lesson::capture_ci_lesson(
            &repo_root,
            &domain,
            &check,
            &pr_ref,
            &failure_text,
        ) {
            Ok(res) => {
                println!(
                    "captured: class={} reflection_id={}",
                    res.class.as_str(),
                    res.reflection_id
                );
                return Some(Ok(()));
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
        let (system, max_tokens, prompt_flag, model_class) = crate::parse_llm_complete_args(args);
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
        let provider = crate::provider_cascade::build_provider();
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
                return Some(Ok(()));
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
            return Some(Ok(()));
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
        let repo_root = crate::repo_path::repo_root();
        std::env::set_var("CHUMP_PROVIDER_CHAIN", chain_names);
        let chain = crate::inference_provider::ProviderChain::from_env(&repo_root);
        let client = crate::inference_provider::testing::ScenarioClient::new(scenario);
        let result = chain.execute(&client, "smoke test prompt", &repo_root);
        if want_json {
            let json = match &result {
                Ok(c) => format!(
                    r#"{{"ok":true,"provider":"{}","model":"{}"}}"#,
                    c.provider, c.model
                ),
                Err(crate::inference_provider::ChainError::InvalidPrompt(msg)) => {
                    format!(r#"{{"ok":false,"error":"invalid_prompt","message":"{msg}"}}"#)
                }
                Err(crate::inference_provider::ChainError::AllProvidersFailed { attempts }) => {
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
        return Some(match result {
            Ok(_) => Ok(()),
            Err(_) => std::process::exit(1),
        });
    }

    // `chump agent-run` (INFRA-3475) — the external-repo execution keystone. Runs
    // the OS's OWN agent (chump-local: ProviderCascade + the full tool set incl.
    // git_push/gh) on an ad-hoc prompt inside a working dir. NO gap lookup — this
    // is the primitive that sidesteps execute_gap's gap-source/file-root conflation,
    // so `chump improve` can default to chump-local (spawn this in the clone) instead
    // of the claude CLI. See docs/design/EXTERNAL_REPO_EXECUTION.md.
    if args.get(1).map(String::as_str) == Some("agent-run") {
        let (prompt_file, cwd) = crate::parse_agent_run_args(args);
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
            // crate::execute_gap::build_free_tier_agent — that forces the cascade OFF and
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
                    return Some(Ok(()));
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
            return Some(Ok(()));
        }
        // Slice off args[0] (binary name) so from_argv sees
        // ["ambient", "emit", <kind>, ...flags].
        let parsed = match crate::ambient_emit::EmitArgs::from_argv(&args[1..]) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("chump ambient emit: {e:#}");
                eprintln!("Run `chump ambient emit --help` for usage.");
                std::process::exit(2);
            }
        };
        let path = match crate::ambient_emit::emit(&parsed) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("chump ambient emit: {e:#}");
                std::process::exit(1);
            }
        };
        // Stderr so stdout stays clean for chained commands (e.g. backtick capture).
        eprintln!("[ambient] wrote {} ({})", parsed.kind, path.display());
        return Some(Ok(()));
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
            return Some(Ok(()));
        }
        return Some(crate::ship_plan_cli(&args[3..]).await);
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
            return Some(Ok(()));
        }
        return Some(crate::ship_execute_cli(&args[3..]).await);
    }

    // `chump init` (UX-001) — first-run setup: detect model, write .env, start server, open browser.
    // Flags: --port N (override CHUMP_WEB_PORT), --no-browser (skip step 4 — for CI / FTUE).
    if args.get(1).map(String::as_str) == Some("init") {
        let init_args = match crate::chump_init::InitArgs::from_argv(&args[2..]) {
            Ok(a) => a,
            Err(e) => {
                eprintln!("chump init: {e:#}");
                eprintln!("usage: chump init [--port N] [--no-browser]");
                std::process::exit(2);
            }
        };
        let repo_root = crate::repo_path::repo_root();
        if let Err(e) = crate::chump_init::run_init(&repo_root, &init_args) {
            eprintln!("chump init: {e:#}");
            std::process::exit(1);
        }
        return Some(Ok(()));
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
            return Some(Ok(()));
        }
        crate::activation::print_funnel();
        return Some(Ok(()));
    }

    // `chump claim <GAP-ID> [--paths X,Y,...]` (INFRA-468) — atomic
    // replacement for the 6-step shell dance documented in CLAUDE.md's
    // mandatory pre-flight: fetch + verify-gap + health-probe + worktree
    // + lease-write + import-if-drifted, all in one call. Each step has
    // its own bypass env for testing / unusual setups.
    if args.get(1).map(String::as_str) == Some("claim") {
        let repo_root = crate::repo_path::repo_root();

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
        if !farmer_gate_bypass {
            let fs = crate::farmer_status::compute(&repo_root);
            if !fs.green {
                eprintln!("chump claim: farmer status RED — no new claims admitted.");
                for r in &fs.reasons {
                    eprintln!("  - {r}");
                }
                eprintln!("Run `chump farmer status` for detail. Bypass: --skip-farmer-gate");
                std::process::exit(1);
            }
        }

        let claim_args =
            match crate::atomic_claim::ClaimArgs::from_argv(&claim_argv, repo_root.clone()) {
                Ok(a) => a,
                Err(e) => {
                    eprintln!("chump claim: {e:#}");
                    eprintln!();
                    eprintln!("Usage: chump claim <GAP-ID> [--paths CSV] [--session ID]");
                    eprintln!("                          [--skip-doctor] [--skip-import]");
                    eprintln!();
                    eprintln!("Atomically: fetch origin/main, verify the gap, run chump-doctor,");
                    eprintln!("create a linked worktree, write the lease. Replaces the 6-step");
                    eprintln!("shell dance in CLAUDE.md mandatory pre-flight (INFRA-468).");
                    std::process::exit(2);
                }
            };
        match crate::atomic_claim::run_claim(claim_args) {
            Ok(report) => {
                crate::atomic_claim::print_report(&report);
                return Some(Ok(()));
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
        std::process::exit(crate::preflight::run(&sub_args));
    }

    // `chump verify` (CREDIBLE-155) — unified policy engine: typed rules
    // over parsed diff semantics, one implementation for git hooks and CI.
    // All logic lives in src/verify/ (INFRA-3287: keep this arm tiny).
    if args.get(1).map(String::as_str) == Some("verify") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::verify::run(&sub_args));
    }

    // `chump self-rescue-loop [--execute] [--grace-secs N]` (EFFECTIVE-088) — the
    // autonomous conductor: detect a wedged fleet → propose self-rescue on the
    // consensus bus → objection window → act. Dry-run unless --execute. Obeys the
    // autonomy dial + kill switch. Intended to run as a launchd daemon.
    if args.get(1).map(String::as_str) == Some("self-rescue-loop") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::fleet_self_rescue_conductor::run(&sub_args));
    }

    // `chump session-summary` (INFRA-1437) — list merged + armed + filed PRs
    // in the current session window. Replaces the manual ambient.jsonl + gh
    // pr list scrape that PM-curator + operator were doing at every session
    // end (~5 min of work).
    if args.get(1).map(String::as_str) == Some("session-summary") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::session_summary::run(&sub_args));
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
                std::process::exit(crate::pe_suite_status::run(&flags));
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
    // Extracted to crate::commands::dispatch_external (INFRA-3289, slice 1 of INFRA-3287).
    if let Some(code) = crate::commands::dispatch_external::try_dispatch(args) {
        std::process::exit(code);
    }

    // `chump ingest <repo-path>` (INFRA-1780, phase 1a of INFRA-1746) —
    // repo validation + read-only safety only. No filesystem mutation, no
    // network calls. Later phases add the actual scanning/writing.
    if args.get(1).map(String::as_str) == Some("ingest") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::ingest::run(&sub_args));
    }

    // `chump ingest-preflight <owner/repo|url|local-path>` (INFRA-1778) —
    // verifies gh auth + push access before any ingest phase runs. Read-only.
    if args.get(1).map(String::as_str) == Some("ingest-preflight") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::ingest_preflight::run(&sub_args));
    }

    // `chump scan <repo-path> [--max-gaps N]` (INFRA-1882, 2026 demo #2) —
    // local read-only heuristics against a sibling repo, files up to
    // --max-gaps concrete gaps straight into the TARGET repo's own
    // .chump/state.db. Pairs with `chump fleet-mode --takeover`.
    if args.get(1).map(String::as_str) == Some("scan") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::scan::run(&sub_args));
    }

    // `chump cartograph <target-repo-path> [--json]` (INFRA-1782, phase 2 of
    // INFRA-1746) — static, read-only scan of a target repo that writes
    // <target-repo-path>/docs/ARCHITECTURE.md. No LLM calls, no network
    // calls; the only write is ARCHITECTURE.md itself.
    if args.get(1).map(String::as_str) == Some("cartograph") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::cartographer::run(&sub_args));
    }

    // `chump evangelize <target-repo-path> [--json]` (INFRA-1783, phase 3 of
    // INFRA-1746) — static, read-only scan of a target repo that writes
    // <target-repo-path>/docs/HIDDEN_GEMS.md. No LLM calls, no network
    // calls; the only write is HIDDEN_GEMS.md itself.
    if args.get(1).map(String::as_str) == Some("evangelize") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::evangelist::run(&sub_args));
    }

    // `chump harvest <scan|check|brief|deep-scan|list-clusters>` (INFRA-1823)
    // — Fleet Cartographer CLI. Productizes the Harvester (previously a
    // Claude-Code-session-only shell script + agent) as a first-class chump
    // engine capability, usable from any harness.
    if args.get(1).map(String::as_str) == Some("harvest") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::harvester_cli::run(&sub_args));
    }

    // `chump systematize <target-repo-path> [--json]` (INFRA-1783, phase 4 of
    // INFRA-1746) — static, read-only scan of a target repo that writes
    // <target-repo-path>/docs/CAPABILITIES_REGISTRY.json. No LLM calls, no
    // network calls; the only write is CAPABILITIES_REGISTRY.json itself.
    if args.get(1).map(String::as_str) == Some("systematize") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::systematizer::run(&sub_args));
    }

    // `chump vote <corr_id> <+1|-1|0> --reason <text>` (META-159) —
    // emit a FEEDBACK kind=vote event via the broadcast.sh FEEDBACK pathway.
    // Gated behind CHUMP_FLEET_RECV_SIDE_V0=1; prints "feature flag off,
    // vote not emitted" and exits 0 when flag is unset.
    if args.get(1).map(String::as_str) == Some("vote") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::commands::vote::run(&sub_args));
    }

    // `chump consensus ask <question> --reason <text> [--id <id>] [--block]
    // [--timeout <secs>]` (INFRA-2156, META-125/C5) — publish a fleet
    // decision question onto the existing FEEDBACK kind=proposal channel
    // and return a consensus_id; --block polls ambient.jsonl for the
    // deliberator's consensus_result up to --timeout seconds.
    // Gated behind CHUMP_FLEET_RECV_SIDE_V0=1, same as `chump vote`.
    if args.get(1).map(String::as_str) == Some("consensus")
        && args.get(2).map(String::as_str) == Some("ask")
    {
        let sub_args: Vec<String> = args.iter().skip(3).cloned().collect();
        std::process::exit(crate::commands::consensus_ask::run(&sub_args));
    }

    // `chump voice --wedge-class <id> --minutes-lost <int> ...` (INFRA-2258) —
    // file a Voice-of-Agent (VOA) report: writes docs/gaps/VOA-NNNN.yaml +
    // docs/voice/VOA-NNNN-FULL.yaml and emits kind=voice_of_agent_filed.
    // Optional --ship to open a PR against repairman29/chump.
    if args.get(1).map(String::as_str) == Some("voice") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::commands::voice::run(&sub_args));
    }

    // `chump source-resolve "<capability keyword>"` (INFRA-3508, COTG-S.1) —
    // resolve a capability against repo -> arsenal -> world prior art BEFORE
    // building. See src/sourcing_resolver.rs for the tiered resolution logic.
    if args.get(1).map(String::as_str) == Some("source-resolve") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::commands::source_resolve::run(&sub_args));
    }

    // `chump intervention-watchdog [--window H] [--apply] [--json]` (COTG-2.1/INFRA-3489) —
    // detect human touches in the fleet, class each as an autonomy_defect, file self-heal gaps.
    if args.get(1).map(String::as_str) == Some("intervention-watchdog") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::intervention_watchdog::run(&sub_args));
    }

    // `chump bench run --track <path> [--apply] [--json]` (DOC-072/EFFECTIVE-327) —
    // run a ChumpBench track as a scoreable lap: grade the acceptance check + tally human touches.
    if args.get(1).map(String::as_str) == Some("bench") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::bench::run(&sub_args));
    }

    // `chump demo [--seed N] [--duration 60m] [--dry-run] ...` (INFRA-2391) —
    // wires the META-072 chump-demo crate (Track-3 autonomous-throughput
    // demo loop) in as a first-class subcommand instead of leaving it as an
    // undiscoverable standalone binary. Execs the sibling chump-demo binary
    // built by this workspace, forwarding args + exit code.
    if args.get(1).map(String::as_str) == Some("demo") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::commands::demo::run(&sub_args));
    }

    // `chump config [show] [--json]` (INFRA-2371) — runtime cascade /
    // privacy / MCP snapshot. Pure read; never invokes an LLM, so it's
    // safe to run when the cascade is wedged. Solves the daily-friction
    // case where bare `chump config` previously fell through to the LLM
    // gen path and 400'd from Gemini.
    if args.get(1).map(String::as_str) == Some("config") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::commands::config::run(&sub_args));
    }

    // `chump consensus-tally [--corr-id X | --all] [--since <dur>]` (META-159) —
    // aggregate FEEDBACK kind=vote events from ambient.jsonl per corr_id
    // and compute a verdict. Always runs regardless of feature flag (read-only).
    if args.get(1).map(String::as_str) == Some("consensus-tally") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::commands::consensus_tally::run(&sub_args));
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
        std::process::exit(crate::commands::consensus::run(&sub_args));
    }

    // `chump sibling-status [--json] [--watch]` (META-154) — per-active-lease
    // progress matrix. Beats "lease exists" by classifying each holder as
    // progressing / in-flight / heartbeat-only / stalled / silent / expired.
    if args.get(1).map(String::as_str) == Some("sibling-status") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::commands::sibling_status::run(&sub_args));
    }

    // `chump claim-lint --range <base>..<head> [--message-file <path>]
    //   [--test-log <path>] [--model <name>] [--gap-id <id>] [--json]
    //   [--no-emit]` (CREDIBLE-208) — pre-ship bullshit gate: ground an
    // agent's claims (commit/PR text) against the diff. Bounces (exit 1)
    // with the specific ungrounded claim named on any bust.
    if args.get(1).map(String::as_str) == Some("claim-lint") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::commands::claim_lint::run(&sub_args));
    }

    // `chump inventory <rebuild|show|debt-report|...>` (META-271) —
    // fleet inventory + tech-debt review-only audit. ALL detector findings
    // land at tier=0 (surface-only) — never auto-files a gap, never removes
    // code. Operator runs `chump inventory review` to classify findings, then
    // `chump inventory promote <class>` after ≥10 reviewed + ≥70% RP ratio.
    // Tier-2 auto-file machinery deferred to INFRA-2374.
    if args.get(1).map(String::as_str) == Some("inventory") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::commands::inventory::run(&sub_args));
    }

    // `chump contract-scan [--in-flight] [--against <pr-number>]` (INFRA-2405) —
    // detect cross-PR state-file/IPC schema mismatches. Triggered by INFRA-2404:
    // the main-preflight-watchdog (INFRA-2397) wrote {state, updated_at, last_tick_id}
    // while the claim main-health-gate (INFRA-2398) read {last_status, last_tick_at,
    // failing_gates} — keys never matched, the procedure layer shipped silently inert.
    // Exit 0 = clean, 1 = mismatches detected, 2 = scan failure.
    if args.get(1).map(String::as_str) == Some("contract-scan") {
        let sub_args: Vec<String> = args.iter().skip(2).cloned().collect();
        std::process::exit(crate::commands::contract_scan::run(&sub_args));
    }

    // `chump bootstrap <intent> [--dir <path>] [--skip-arch-decision] [--with-roadmap]`
    // (INFRA-2265) — net-new product bootstrap entrypoint: empty dir → git init →
    // scaffold (Cargo.toml | package.json | pyproject.toml) → README.md → first commit
    // → umbrella gap via `chump gap reserve`. Sister of INFRA-1746 (`chump ingest`).
    // This is the SUBSTRATE-layer entrypoint; consumer surfaces own the founder-facing
    // pitch lane. Third demo-able 2026 outcome (META-067).
    if args.get(1).map(String::as_str) == Some("bootstrap") {
        let sub_args: Vec<String> = args.iter().skip(1).cloned().collect();
        std::process::exit(crate::commands::bootstrap::run(&sub_args));
    }

    // `chump roadmap-from-vision <vision> --domain D [--outcome ID] [--max-gaps N] [--apply]`
    // (EFFECTIVE-425, COTG spine slice 1) — vision string -> validated Roadmap JSON;
    // with --apply, files each GapDraft via `chump gap reserve --outcome <id>` so
    // MISSION-045 / pillar / similarity gates apply. See crate::commands::roadmap_from_vision.
    if args.get(1).map(String::as_str) == Some("roadmap-from-vision") {
        let sub_args: Vec<String> = args.iter().skip(1).cloned().collect();
        std::process::exit(crate::commands::roadmap_from_vision::run(&sub_args).await);
    }

    // INFRA-2399 author-time helper commands (add-env-var / emit-event /
    // install-daemon / add-path-filter / add-raw-gh-allowlist).
    // Extracted to crate::commands::dispatch_authoring (INFRA-3298, slice 2 of INFRA-3287).
    if let Some(code) = crate::commands::dispatch_authoring::try_dispatch(args) {
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
        let repo_root = crate::repo_path::repo_root();
        match crate::inspect_cmd::run(&repo_root, &gap_id, !no_tmux) {
            Ok(()) => return Some(Ok(())),
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
        let repo_root = crate::repo_path::repo_root();
        match crate::resume_cmd::run(&repo_root, &gap_id) {
            Ok(verdict) => {
                println!("{}", verdict.summary());
                let exit_code = if verdict == crate::resume_cmd::ResumeVerdict::Ready {
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
        let repo_root = crate::repo_path::repo_root();
        match crate::scrap_cmd::run(&repo_root, &gap_id) {
            Ok(outcome) => {
                println!(
                    "scrap: worktree_removed={} lease_removed={} branch_deleted={}",
                    outcome.worktree_removed, outcome.lease_removed, outcome.branch_deleted
                );
                return Some(Ok(()));
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
        let repo_root = crate::repo_path::repo_root();
        let sub_args: Vec<String> = args.iter().skip(3).cloned().collect();
        let exit_code = match sub {
            Some("status") => match crate::disk_cmd::run_status(&sub_args, &repo_root) {
                Ok(code) => code,
                Err(e) => {
                    eprintln!("chump disk status: {e:#}");
                    1
                }
            },
            Some("plan") => match crate::disk_cmd::run_plan(&sub_args, &repo_root) {
                Ok(code) => code,
                Err(e) => {
                    eprintln!("chump disk plan: {e:#}");
                    1
                }
            },
            Some("budget") => match crate::disk_cmd::run_budget(&sub_args, &repo_root) {
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
                    return Some(Ok(()));
                }
                _ => {
                    eprintln!("pr-rescue: unknown arg: {}", args[i]);
                    std::process::exit(2);
                }
            }
            i += 1;
        }
        let opts = crate::pr_rescue::RescueOpts {
            once,
            pr,
            dry_run,
            explain,
        };
        match crate::pr_rescue::run(opts) {
            Ok(()) => return Some(Ok(())),
            Err(e) => {
                eprintln!("pr-rescue: {e}");
                std::process::exit(1);
            }
        }
    }

    // `chump completion [zsh|bash|fish]` (EFFECTIVE-010) — print shell completion script.
    if args.get(1).map(String::as_str) == Some("completion") {
        let shell = args.get(2).map(String::as_str).unwrap_or("zsh");
        match shell {
            "zsh" => {
                print!("{}", crate::completion::zsh());
                return Some(Ok(()));
            }
            "bash" => {
                print!("{}", crate::completion::bash());
                return Some(Ok(()));
            }
            "fish" => {
                print!("{}", crate::completion::fish());
                return Some(Ok(()));
            }
            other => {
                eprintln!("chump completion: unknown shell {other:?}");
                eprintln!("Usage: chump completion [zsh|bash|fish]");
                eprintln!();
                eprintln!("Install examples:");
                eprintln!("  zsh:  chump completion zsh > $(brew --prefix)/share/zsh/site-functions/_chump");
                eprintln!("  bash: chump completion bash >> ~/.bashrc");
                eprintln!("  fish: chump completion fish > ~/.config/fish/completions/chump.fish");
                std::process::exit(2);
            }
        }
    }

    // `chump lesson-grade <GAP-ID> --pr <N>` (COG-043) — for each
    // `lessons_shown` event tied to this gap+session in ambient.jsonl,
    // score the directive's keywords against the PR's diff + body and
    // emit `lesson_applied` / `lesson_not_applied` events. Best-effort:
    // missing PR or network errors degrade to no-op, never panic.
    //
    // Called from bot-merge.sh after auto-close. Operators can also
    // run it manually post-hoc on any closed PR.
    if args.get(1).map(String::as_str) == Some("lesson-grade") {
        let gap_id = args.get(2).cloned().unwrap_or_else(|| {
            eprintln!("Usage: chump lesson-grade <GAP-ID> --pr <N>");
            std::process::exit(2);
        });
        if gap_id.starts_with("--") {
            eprintln!("Usage: chump lesson-grade <GAP-ID> --pr <N>");
            std::process::exit(2);
        }
        let lg_flag = |name: &str| -> Option<String> {
            args.iter()
                .position(|a| a == name)
                .and_then(|i| args.get(i + 1).cloned())
        };
        let pr_number: u64 = match lg_flag("--pr") {
            Some(s) => s.parse().unwrap_or_else(|_| {
                eprintln!("chump lesson-grade: --pr expects an integer (got {s:?})");
                std::process::exit(2);
            }),
            None => {
                eprintln!("Usage: chump lesson-grade <GAP-ID> --pr <N>");
                std::process::exit(2);
            }
        };
        let session_filter = lg_flag("--session"); // optional — defaults to all sessions for the gap
        let repo_root = crate::repo_path::repo_root();
        let graded =
            crate::run_lesson_grade(&repo_root, &gap_id, pr_number, session_filter.as_deref());
        match graded {
            Ok(counts) => {
                println!(
                    "lesson-grade {}: applied={} not_applied={} skipped={}",
                    gap_id, counts.0, counts.1, counts.2
                );
                return Some(Ok(()));
            }
            Err(e) => {
                // Best-effort — print the warning but exit 0 so we don't
                // break bot-merge.sh's auto-close flow.
                eprintln!("chump lesson-grade: warning: {e:#}");
                return Some(Ok(()));
            }
        }
    }

    // `chump audit aha-sweep [--json] [--window-days N] [--emit]` (INFRA-1370).
    // Walks every kind in EVENT_REGISTRY.yaml, reads its effect_metric +
    // expected_min_per_day declarations (INFRA-1371), and compares against the
    // last-N-days emit count in .chump-locks/ambient.jsonl. Surfaces "registered
    // but silent" kinds (alert) and "below floor" kinds (warn) as
    // kind=audit_finding events. Exit non-zero on any alert.
    if args.get(1).map(String::as_str) == Some("audit") {
        let sub = args.get(2).map(String::as_str).unwrap_or("--help");
        if sub == "--help" || sub == "help" || sub.is_empty() {
            println!("Usage: chump audit <subcommand> [options]");
            println!();
            println!("Subcommands:");
            println!(
                "  aha-sweep         walk code/runtime/effect triangle for every registered kind"
            );
            println!(
                "  librarian-sweep   dead-code + redundant-script triage for an ingest target repo"
            );
            println!("  query             query the per-action audit log (INFRA-1842, CP-010)");
            println!("  retention         delete audit_log rows older than a cutoff (INFRA-1842)");
            println!();
            println!("Run 'chump audit <subcommand> --help' for options.");
            return Some(Ok(()));
        }
        // `chump audit query [filters] [--json]` (INFRA-1842, CP-010) — queryable
        // per-action audit log. See docs/arsenal/cross-pollination/CP-010-beast-mode-audit-logger.md.
        if sub == "query" {
            let rest: Vec<&str> = args.iter().skip(3).map(String::as_str).collect();
            if rest.iter().any(|a| *a == "--help" || *a == "help") {
                println!("Usage: chump audit query [filters] [--json]");
                println!();
                println!("Options:");
                println!("  --actor <id>          filter by actor (session id or login)");
                println!("  --action <name>        filter by action name (e.g. gap.shipped)");
                println!(
                    "  --resource <class>     filter by resource class (gap | pr | lease | config)"
                );
                println!(
                    "  --resource-id <id>     filter by specific resource id (e.g. INFRA-1842)"
                );
                println!("  --since <duration|iso> 24h | 7d | 1m | 0s | RFC-3339 timestamp");
                println!("  --until <duration|iso> same syntax as --since");
                println!("  --limit N              truncate result (default 100)");
                println!("  --json                 structured JSON output (default: pretty table)");
                return Some(Ok(()));
            }
            let want_json = rest.contains(&"--json");
            let mut filter = crate::audit_log::QueryFilter::default();
            let mut it = rest.iter().peekable();
            while let Some(a) = it.next() {
                match *a {
                    "--actor" => filter.actor = it.next().map(|s| s.to_string()),
                    "--action" => filter.action = it.next().map(|s| s.to_string()),
                    "--resource" => filter.resource = it.next().map(|s| s.to_string()),
                    "--resource-id" => filter.resource_id = it.next().map(|s| s.to_string()),
                    "--since" => {
                        if let Some(v) = it.next() {
                            match crate::audit_log::resolve_time_bound(v) {
                                Ok(ts) => filter.since = Some(ts),
                                Err(e) => {
                                    eprintln!("chump audit query: bad --since value: {e}");
                                    std::process::exit(2);
                                }
                            }
                        }
                    }
                    "--until" => {
                        if let Some(v) = it.next() {
                            match crate::audit_log::resolve_time_bound(v) {
                                Ok(ts) => filter.until = Some(ts),
                                Err(e) => {
                                    eprintln!("chump audit query: bad --until value: {e}");
                                    std::process::exit(2);
                                }
                            }
                        }
                    }
                    "--limit" => {
                        if let Some(v) = it.next() {
                            filter.limit = v.parse().ok();
                        }
                    }
                    _ => {}
                }
            }
            let repo_root = crate::repo_path::repo_root();
            let conn = match crate::audit_log::open(&repo_root) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("chump audit query: {e}");
                    std::process::exit(1);
                }
            };
            let entries = match crate::audit_log::query(&conn, &filter) {
                Ok(e) => e,
                Err(e) => {
                    eprintln!("chump audit query: {e}");
                    std::process::exit(1);
                }
            };
            if want_json {
                println!(
                    "{}",
                    serde_json::json!({ "count": entries.len(), "entries": entries })
                );
            } else {
                println!(
                    "{:<28} {:<22} {:<24} {:<10} resource_id",
                    "ts", "actor", "action", "result"
                );
                for e in &entries {
                    println!(
                        "{:<28} {:<22} {:<24} {:<10} {}",
                        e.ts,
                        e.actor,
                        e.action,
                        e.result.as_str(),
                        e.resource_id.clone().unwrap_or_default()
                    );
                }
                println!("{} entries", entries.len());
            }
            return Some(Ok(()));
        }
        // `chump audit retention --older-than <duration> [--dry-run] [--json]` (INFRA-1842).
        if sub == "retention" {
            let rest: Vec<&str> = args.iter().skip(3).map(String::as_str).collect();
            if rest.iter().any(|a| *a == "--help" || *a == "help") || rest.is_empty() {
                println!(
                    "Usage: chump audit retention --older-than <duration> [--dry-run] [--json]"
                );
                println!();
                println!("Deletes audit_log rows with ts older than the cutoff. No automatic");
                println!("rotation — operator/cron invoked, mirrors BEAST-MODE's clearLogs().");
                return Some(Ok(()));
            }
            let want_json = rest.contains(&"--json");
            let mut older_than: Option<String> = None;
            let mut it = rest.iter().peekable();
            while let Some(a) = it.next() {
                if *a == "--older-than" {
                    older_than = it.next().map(|s| s.to_string());
                }
            }
            let older_than = match older_than {
                Some(v) => v,
                None => {
                    eprintln!("chump audit retention: --older-than is required");
                    std::process::exit(2);
                }
            };
            let cutoff = match crate::audit_log::resolve_time_bound(&older_than) {
                Ok(ts) => ts,
                Err(e) => {
                    eprintln!("chump audit retention: bad --older-than value: {e}");
                    std::process::exit(2);
                }
            };
            let repo_root = crate::repo_path::repo_root();
            let conn = match crate::audit_log::open(&repo_root) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("chump audit retention: {e}");
                    std::process::exit(1);
                }
            };
            let report = match crate::audit_log::clear_older_than(&conn, &cutoff) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("chump audit retention: {e}");
                    std::process::exit(1);
                }
            };
            if want_json {
                println!(
                    "{}",
                    serde_json::json!({ "removed": report.removed, "remaining": report.remaining })
                );
            } else {
                println!(
                    "removed {} rows older than {}, {} remaining",
                    report.removed, cutoff, report.remaining
                );
            }
            return Some(Ok(()));
        }
        // `chump audit _test_seed ...` — hidden subcommand for synthetic audit
        // entries, gated on CHUMP_TEST_MODE=1, matching the pattern used by
        // scripts/ci/test-gap-audit-priorities.sh's fixture seeding.
        if sub == "_test_seed" {
            if std::env::var("CHUMP_TEST_MODE").as_deref() != Ok("1") {
                eprintln!("chump audit _test_seed: only available with CHUMP_TEST_MODE=1");
                std::process::exit(2);
            }
            let rest: Vec<&str> = args.iter().skip(3).map(String::as_str).collect();
            let mut actor = "test-actor".to_string();
            let mut action = "test.action".to_string();
            let mut resource: Option<String> = None;
            let mut resource_id: Option<String> = None;
            let mut it = rest.iter().peekable();
            while let Some(a) = it.next() {
                match *a {
                    "--actor" => actor = it.next().map(|s| s.to_string()).unwrap_or(actor),
                    "--action" => action = it.next().map(|s| s.to_string()).unwrap_or(action),
                    "--resource" => resource = it.next().map(|s| s.to_string()),
                    "--resource-id" => resource_id = it.next().map(|s| s.to_string()),
                    _ => {}
                }
            }
            let mut entry = crate::audit_log::AuditEntry::new(&actor, &action);
            if let (Some(r), Some(rid)) = (resource, resource_id) {
                entry = entry.with_resource(&r, &rid);
            }
            let repo_root = crate::repo_path::repo_root();
            let conn = match crate::audit_log::open(&repo_root) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("chump audit _test_seed: {e}");
                    std::process::exit(1);
                }
            };
            if let Err(e) = crate::audit_log::log_action(&conn, &entry) {
                eprintln!("chump audit _test_seed: {e}");
                std::process::exit(1);
            }
            println!("{}", entry.id);
            return Some(Ok(()));
        }
        if sub == "librarian-sweep" {
            let rest: Vec<&str> = args.iter().skip(3).map(String::as_str).collect();
            if rest.is_empty() || rest.iter().any(|a| *a == "--help" || *a == "help") {
                println!(
                    "Usage: chump audit librarian-sweep <target-repo> [--budget-usd N] [--json]"
                );
                println!();
                println!(
                    "INFRA-1781 (INFRA-1746 phase 1b). Read-only static sweep of <target-repo>:"
                );
                println!("flags dead-code candidates (source stem never referenced elsewhere) and");
                println!(
                    "redundant scripts (byte-identical content under scripts/ or *.sh). Writes"
                );
                println!(
                    "<target-repo>/.chump-ingest/triage.md. Zero LLM/API calls (cost_usd_cents=0)."
                );
                println!();
                println!("Options:");
                println!("  --budget-usd N   accepted for interface parity with later ingest phases (default 10.0)");
                println!("  --json           output JSON instead of the markdown report");
                std::process::exit(if rest.is_empty() { 2 } else { 0 });
            }
            let want_json = rest.contains(&"--json");
            let budget_usd: f64 = {
                let mut it = rest.iter().peekable();
                let mut n = 10.0f64;
                while let Some(a) = it.next() {
                    if *a == "--budget-usd" {
                        if let Some(v) = it.next() {
                            if let Ok(parsed) = v.parse::<f64>() {
                                n = parsed;
                            }
                        }
                    }
                }
                n
            };
            let target_repo = std::path::PathBuf::from(rest[0]);
            let chump_repo_root = crate::repo_path::repo_root();
            let cfg = crate::ingest_librarian::LibrarianConfig {
                target_repo: target_repo.clone(),
                budget_usd,
            };
            crate::ingest_librarian::emit_started(&chump_repo_root, &target_repo);
            let report = match crate::ingest_librarian::run_sweep(&cfg) {
                Ok(r) => r,
                Err(e) => {
                    crate::ingest_librarian::emit_failed(&chump_repo_root, &target_repo, &e);
                    eprintln!("chump audit librarian-sweep: {}", e);
                    std::process::exit(1);
                }
            };
            if let Err(e) = crate::ingest_librarian::write_triage_report(&report) {
                crate::ingest_librarian::emit_failed(&chump_repo_root, &target_repo, &e);
                eprintln!("chump audit librarian-sweep: {}", e);
                std::process::exit(1);
            }
            crate::ingest_librarian::emit_completed(&chump_repo_root, &report);
            if want_json {
                println!(
                    "{}",
                    serde_json::json!({
                        "target_repo": report.target_repo.display().to_string(),
                        "files_scanned": report.files_scanned,
                        "dead_code_candidate_count": report.dead_code_candidates.len(),
                        "redundant_script_group_count": report.redundant_scripts.len(),
                        "cost_usd_cents": report.cost_usd_cents,
                        "elapsed_ms": report.elapsed_ms,
                        "truncated": report.truncated,
                    })
                );
            } else {
                print!("{}", crate::ingest_librarian::render_markdown(&report));
                println!(
                    "triage report written to {}",
                    target_repo.join(".chump-ingest/triage.md").display()
                );
            }
            return Some(Ok(()));
        }
        if sub != "aha-sweep" {
            eprintln!("chump audit: unknown subcommand '{}'", sub);
            eprintln!("Run 'chump audit --help' for the list.");
            std::process::exit(2);
        }
        let rest: Vec<&str> = args.iter().skip(3).map(String::as_str).collect();
        if rest.iter().any(|a| *a == "--help" || *a == "help") {
            println!("Usage: chump audit aha-sweep [--json] [--window-days N] [--flag-silent-self] [--emit]");
            println!();
            println!("Walks every kind in EVENT_REGISTRY.yaml and verifies the recent ambient");
            println!("stream actually contains emits consistent with the declared effect_metric +");
            println!("expected_min_per_day floor.");
            println!();
            println!("Options:");
            println!("  --json               output JSON instead of text");
            println!("  --window-days N      look back window in days (default 7)");
            println!("  --flag-silent-self   also warn on effect_metric=self kinds with 0 emits");
            println!("  --emit               write kind=audit_finding to ambient.jsonl for non-ok findings");
            println!();
            println!("Exits non-zero when any finding has severity=alert.");
            return Some(Ok(()));
        }
        let want_json = rest.contains(&"--json");
        let flag_silent_self = rest.contains(&"--flag-silent-self");
        let do_emit = rest.contains(&"--emit");
        let window_days: u64 = {
            let mut it = rest.iter().peekable();
            let mut n = 7u64;
            while let Some(a) = it.next() {
                if *a == "--window-days" {
                    if let Some(v) = it.next() {
                        if let Ok(parsed) = v.parse::<u64>() {
                            n = parsed.clamp(1, 90);
                        }
                    }
                }
            }
            n
        };
        let repo_root = crate::repo_path::repo_root();
        let cfg = crate::audit::SweepConfig {
            repo_root: repo_root.clone(),
            window: std::time::Duration::from_secs(window_days * 24 * 3600),
            flag_silent_self,
        };
        let findings = match crate::audit::sweep_event_registry(&cfg) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("chump audit aha-sweep: {}", e);
                std::process::exit(1);
            }
        };
        if do_emit {
            if let Err(e) = crate::audit::emit_findings(&repo_root, &findings) {
                eprintln!("chump audit aha-sweep: emit warning: {}", e);
            }
        }
        if want_json {
            println!("{}", crate::audit::render_json(&findings));
        } else {
            print!("{}", crate::audit::render_text(&findings));
        }
        let any_alert = findings
            .iter()
            .any(|f| f.severity == crate::audit::AuditSeverity::Alert);
        if any_alert {
            std::process::exit(1);
        }
        return Some(Ok(()));
    }

    // `chump mission-grade [--json]` (INFRA-599) — auto-emit 4-pillar scorecard.
    // Counts pickable, in_flight, and shipped_24h gaps per pillar
    // (EFFECTIVE/CREDIBLE/RESILIENT/ZERO-WASTE, identified by title prefix),
    // emits kind=mission_grade to ambient.jsonl, and prints to stdout.
    if args.get(1).map(String::as_str) == Some("mission-grade") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump mission-grade [--json]");
            println!();
            println!("Current pillar grades: EFFECTIVE / CREDIBLE / RESILIENT / ZERO-WASTE.");
            println!("Emits kind=mission_grade to ambient.jsonl on each run.");
            println!();
            println!("Options:");
            println!("  --json   output in JSON format");
            println!();
            println!("Example:");
            println!("  chump mission-grade");
            println!("  chump mission-grade --json");
            return Some(Ok(()));
        }
        let want_json = args.iter().any(|a| a == "--json");
        let repo_root = crate::repo_path::repo_root();
        let report = crate::mission_grade::build_report(&repo_root);
        crate::mission_grade::emit(&repo_root, &report);
        if want_json {
            println!("{}", report.render_json());
        } else {
            print!("{}", report.render_text());
        }
        if report.any_low_grade() {
            std::process::exit(1);
        }
        return Some(Ok(()));
    }

    // `chump upgrade [--dry-run]` (INFRA-1504) — upgrade the chump binary.
    // Detects install method (brew / cargo / manual) and runs the right upgrade.
    if args.get(1).map(String::as_str) == Some("upgrade") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump upgrade [--dry-run]");
            println!();
            println!("Detects how chump was installed and runs the appropriate upgrade:");
            println!("  brew:   brew upgrade chump");
            println!("  cargo:  cargo install --force chump");
            println!("  manual: prints instructions to download a new release");
            println!();
            println!("Options:");
            println!("  --dry-run  show the upgrade command without running it");
            return Some(Ok(()));
        }
        let dry_run = args.iter().any(|a| a == "--dry-run");
        crate::fleet_health::run_upgrade(dry_run);
        return Some(Ok(()));
    }

    // `chump health [--json] [--watch]` (INFRA-644) — composite fleet health
    // score (0-100) rolling up fleet-status, waste-tally, cost-watch,
    // mission-grade, pr-stuck, version-skew, auth, and ghost-gaps.
    // Emits kind=fleet_health to ambient.jsonl on each run.
    if args.get(1).map(String::as_str) == Some("health") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump health [--json] [--watch] [--slo-check] [--temp]");
            println!();
            println!("Composite fleet health score (0-100) rolling up fleet-status, waste-tally,");
            println!("cost-watch, mission-grade, pr-stuck, version-skew, auth, and ghost-gaps.");
            println!("Emits kind=fleet_health to ambient.jsonl on each run.");
            println!();
            println!("Options:");
            println!("  --json       output in JSON format");
            println!("  --watch      refresh every 30 s (clear screen between runs)");
            println!("  --slo-check  exit non-zero if any SLO is breached");
            println!("  --temp       INFRA-1992: report floor-temperature only (COLD/WARM/HOT)");
            println!();
            println!("Example:");
            println!("  chump health");
            println!("  chump health --slo-check   # use in CI");
            println!("  chump health --temp        # one-word floor-temp signal");
            println!("  chump health --temp --json # full floor-temp report with component counts");
            return Some(Ok(()));
        }
        let want_json = args.iter().any(|a| a == "--json");
        let watch = args.iter().any(|a| a == "--watch");
        let slo_check = args.iter().any(|a| a == "--slo-check");
        let want_temp = args.iter().any(|a| a == "--temp");
        let repo_root = crate::repo_path::repo_root();

        // INFRA-1992 (THE FLOOR Phase 1): floor-temperature signal.
        // Reads ambient.jsonl over trailing 24h, counts hot event kinds
        // (hook_silent_passthrough + ci_failure_cluster + admin_merge_executed),
        // returns COLD/WARM/HOT. Emits kind=floor_temp on each invocation.
        if want_temp {
            let ambient = crate::floor_temp::ambient_path_for(&repo_root);
            let report =
                crate::floor_temp::compute(&ambient, crate::floor_temp::DEFAULT_WINDOW_SECS);
            crate::floor_temp::emit_floor_temp(&report);
            if want_json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&report).unwrap_or_else(|_| "{}".to_string())
                );
            } else {
                println!("{}", report.temp_str);
                eprintln!(
                    "  ({} hot events in trailing {}h)",
                    report.total_hot_events,
                    report.window_secs / 3600
                );
                eprintln!("  {}", report.recommendation);
            }
            // Exit code: HOT → 2, WARM → 1, COLD → 0 (so CI/workers can react).
            let code = match report.temp {
                crate::floor_temp::FloorTemp::Cold => 0,
                crate::floor_temp::FloorTemp::Warm => 1,
                crate::floor_temp::FloorTemp::Hot => 2,
            };
            std::process::exit(code);
        }

        if slo_check {
            let results = crate::fleet_health::check_slos(&repo_root);
            if want_json {
                println!("{}", crate::fleet_health::render_slo_json(&results));
            } else {
                print!("{}", crate::fleet_health::render_slo_text(&results));
            }
            if results.iter().any(|r| r.breached) {
                std::process::exit(1);
            }
            return Some(Ok(()));
        }

        loop {
            let report = crate::fleet_health::build_report(&repo_root);
            crate::fleet_health::emit(&repo_root, &report);
            // Emit kind=session_rescue for any new rescues found (INFRA-667).
            let rescues = crate::rescue_tally::scan_rescues(&repo_root, 24);
            crate::rescue_tally::emit_rescue_events(&repo_root, &rescues);
            if want_json {
                println!("{}", report.render_json());
            } else {
                print!("{}", report.render_text());
            }
            if !watch {
                break;
            }
            std::thread::sleep(std::time::Duration::from_secs(30));
            // Clear terminal for next iteration.
            print!("\x1b[2J\x1b[H");
            let _ = std::io::stdout().flush();
        }
        return Some(Ok(()));
    }

    // INFRA-1613: `chump skill <subcmd>` — operator-facing CLI for skill management.
    // Exposes list/view/health/record-outcome/tap-add without requiring an
    // agent loop session. Skills live in chump-brain/skills/<name>/SKILL.md;
    // reliability stats come from chump_skills SQLite table (skill_db.rs).
    if args.get(1).map(String::as_str) == Some("skill") {
        let subcmd = args.get(2).map(String::as_str).unwrap_or("list");
        let want_json = args.iter().any(|a| a == "--json");

        if subcmd == "--help" || subcmd == "help" || subcmd == "-h" {
            println!("Usage: chump skill <subcommand> [options]");
            println!();
            println!("Subcommands:");
            println!("  list [--json]              List all installed skills");
            println!("  view NAME                  Show full SKILL.md for NAME");
            println!("  health [--name NAME] [--min-uses N]");
            println!("                             Wilson CI ranking per skill");
            println!("  record-outcome NAME true|false");
            println!("                             Record a success/failure outcome");
            println!("  tap-add URL                Install skills from a GitHub repo");
            println!();
            println!("Skills live in: chump-brain/skills/<name>/SKILL.md");
            println!("Override: CHUMP_BRAIN_PATH env var");
            return Some(Ok(()));
        }

        match subcmd {
            "list" => {
                match crate::skills::list_skills() {
                    Ok(skills) if skills.is_empty() => {
                        if want_json {
                            println!("[]");
                        } else {
                            println!(
                                "No skills installed. Use skill_manage action=create to add one."
                            );
                        }
                    }
                    Ok(skills) => {
                        if want_json {
                            // Build JSON array from skill frontmatter + reliability stats.
                            let mut items: Vec<serde_json::Value> =
                                Vec::with_capacity(skills.len());
                            for s in &skills {
                                let (rel, n) =
                                    crate::skill_db::skill_reliability(&s.frontmatter.name)
                                        .unwrap_or((0.5, 0));
                                let rec =
                                    crate::skill_db::list_skill_records().ok().and_then(|recs| {
                                        recs.into_iter().find(|r| r.name == s.frontmatter.name)
                                    });
                                let last_used = rec.as_ref().and_then(|r| r.last_used_at.clone());
                                let version = s.frontmatter.version;
                                let platforms = &s.frontmatter.platforms;
                                let meta = serde_json::json!({
                                    "tags": s.frontmatter.metadata.tags,
                                    "category": s.frontmatter.metadata.category,
                                    "requires_toolsets": s.frontmatter.metadata.requires_toolsets,
                                });
                                items.push(serde_json::json!({
                                    "name": s.frontmatter.name,
                                    "description": s.frontmatter.description,
                                    "version": version,
                                    "platforms": platforms,
                                    "metadata": meta,
                                    "reliability_p": rel,
                                    "sample_n": n,
                                    "last_used_at": last_used,
                                }));
                            }
                            println!(
                                "{}",
                                serde_json::to_string_pretty(&items)
                                    .unwrap_or_else(|_| "[]".to_string())
                            );
                        } else {
                            println!("Installed skills ({}):", skills.len());
                            for s in &skills {
                                println!("  {}", s.summary_line());
                            }
                        }
                    }
                    Err(e) => {
                        eprintln!("chump skill list: {e:#}");
                        std::process::exit(1);
                    }
                }
                return Some(Ok(()));
            }
            "view" => {
                let name = match args.get(3) {
                    Some(n) => n.as_str(),
                    None => {
                        eprintln!("Usage: chump skill view NAME");
                        std::process::exit(2);
                    }
                };
                match crate::skills::load_skill(name) {
                    Ok(skill) => {
                        let (rel, n) = crate::skill_db::skill_reliability(name).unwrap_or((0.5, 0));
                        if n > 0 {
                            println!(
                                "# Skill: {} (v{})\n",
                                skill.frontmatter.name, skill.frontmatter.version
                            );
                            println!("**Description:** {}", skill.frontmatter.description);
                            println!("**Reliability:** {:.1}% over {} uses\n", rel * 100.0, n);
                            println!("---\n");
                        } else {
                            println!(
                                "# Skill: {} (v{})\n",
                                skill.frontmatter.name, skill.frontmatter.version
                            );
                            println!("**Description:** {}", skill.frontmatter.description);
                            println!("**Reliability:** no usage data yet\n");
                            println!("---\n");
                        }
                        print!("{}", skill.body);
                    }
                    Err(e) => {
                        eprintln!("chump skill view: {e:#}");
                        std::process::exit(1);
                    }
                }
                return Some(Ok(()));
            }
            "health" => {
                // Optional filters: --name NAME, --min-uses N
                let name_filter: Option<String> = {
                    let mut v = None;
                    let mut it = args.iter().skip(3);
                    while let Some(a) = it.next() {
                        if a == "--name" {
                            v = it.next().cloned();
                            break;
                        }
                    }
                    v
                };
                let min_uses: u64 = {
                    let mut v = 0u64;
                    let mut it = args.iter().skip(3);
                    while let Some(a) = it.next() {
                        if a == "--min-uses" {
                            if let Some(n) = it.next().and_then(|s| s.parse().ok()) {
                                v = n;
                            }
                            break;
                        }
                    }
                    v
                };
                match crate::skill_metrics::skill_health_ranking() {
                    Ok(ranking) => {
                        let filtered: Vec<_> = ranking
                            .into_iter()
                            .filter(|h| name_filter.as_deref().is_none_or(|n| h.name == n))
                            .filter(|h| h.use_count >= min_uses)
                            .collect();
                        if want_json {
                            println!(
                                "{}",
                                serde_json::to_string_pretty(&filtered)
                                    .unwrap_or_else(|_| "[]".to_string())
                            );
                        } else if filtered.is_empty() {
                            println!("No skills matching the filter.");
                        } else {
                            println!(
                                "{:<30} {:>6} {:>6} {:>12} {:>10} {:>8}",
                                "name", "uses", "rel%", "ci_lower-upper", "composite", "days_old"
                            );
                            println!("{}", "-".repeat(80));
                            for h in &filtered {
                                let days = h
                                    .days_since_last_use
                                    .map(|d| d.to_string())
                                    .unwrap_or_else(|| "never".to_string());
                                println!(
                                    "{:<30} {:>6} {:>5.1}% [{:>5.1}%–{:>5.1}%] {:>10.3} {:>8}",
                                    h.name,
                                    h.use_count,
                                    h.reliability * 100.0,
                                    h.confidence_lower * 100.0,
                                    h.confidence_upper * 100.0,
                                    h.composite_score,
                                    days,
                                );
                            }
                        }
                    }
                    Err(e) => {
                        eprintln!("chump skill health: {e:#}");
                        std::process::exit(1);
                    }
                }
                return Some(Ok(()));
            }
            "record-outcome" => {
                let name = match args.get(3) {
                    Some(n) => n.as_str(),
                    None => {
                        eprintln!("Usage: chump skill record-outcome NAME true|false");
                        std::process::exit(2);
                    }
                };
                let success_str = match args.get(4) {
                    Some(s) => s.as_str(),
                    None => {
                        eprintln!("Usage: chump skill record-outcome NAME true|false");
                        std::process::exit(2);
                    }
                };
                let success = match success_str {
                    "true" | "1" | "yes" => true,
                    "false" | "0" | "no" => false,
                    other => {
                        eprintln!("chump skill record-outcome: expected true|false, got {other:?}");
                        std::process::exit(2);
                    }
                };
                match crate::skill_db::record_skill_outcome(name, success) {
                    Ok(()) => {
                        let (rel, uses) =
                            crate::skill_db::skill_reliability(name).unwrap_or((0.5, 0));
                        println!(
                            "Recorded {} for '{}'. Reliability: {:.1}% over {} uses.",
                            if success { "success" } else { "failure" },
                            name,
                            rel * 100.0,
                            uses
                        );
                    }
                    Err(e) => {
                        eprintln!("chump skill record-outcome: {e:#}");
                        std::process::exit(1);
                    }
                }
                return Some(Ok(()));
            }
            "tap-add" => {
                let url = match args.get(3) {
                    Some(u) => u.as_str(),
                    None => {
                        eprintln!("Usage: chump skill tap-add URL");
                        eprintln!(
                            "  URL: https://github.com/owner/repo (must have a skills/ directory)"
                        );
                        std::process::exit(2);
                    }
                };
                // Call handle_tap_add directly (pub since INFRA-1613).
                match crate::skill_tool::handle_tap_add(url).await {
                    Ok(msg) => println!("{msg}"),
                    Err(e) => {
                        eprintln!("chump skill tap-add: {e:#}");
                        std::process::exit(1);
                    }
                }
                return Some(Ok(()));
            }
            other => {
                eprintln!("chump skill: unknown subcommand '{other}'");
                eprintln!("Valid: list, view, health, record-outcome, tap-add");
                eprintln!("Run 'chump skill --help' for usage.");
                std::process::exit(2);
            }
        }
    }

    // INFRA-1696 (META-066 phase 3): `chump content-bots <subcmd>` operator
    // surface for the Content Bots Suite (PMM, DocuBot, Evangelist, CopyBot).
    // Reads docs/agents/content-bots/bots.yaml + the toggle resolver from
    // INFRA-1700 (src/content_bots.rs).
    if args.get(1).map(String::as_str) == Some("content-bots") {
        let subcmd = args.get(2).map(String::as_str).unwrap_or("list");
        let json = args.iter().any(|a| a == "--json");
        let repo_root = crate::repo_path::repo_root();
        let bots_yaml = repo_root.join("docs/agents/content-bots/bots.yaml");

        if !bots_yaml.exists() {
            eprintln!(
                "chump content-bots: bots.yaml not found at {}",
                bots_yaml.display()
            );
            eprintln!("  Foundation gap INFRA-1690 must ship before this command works.");
            std::process::exit(2);
        }

        // Minimal bots.yaml reader — parse `bot_id:`, `tier:`, `model_tier:`,
        // `default_enabled:` per entry. Avoid pulling serde_yaml dep just for
        // this read; bots.yaml is operator-curated and small.
        let raw = std::fs::read_to_string(&bots_yaml).unwrap_or_default();
        #[derive(Debug, Default)]
        struct BotEntry {
            bot_id: String,
            tier: String,
            model_tier: String,
            default_enabled: bool,
        }
        let mut bots: Vec<BotEntry> = Vec::new();
        let mut cur = BotEntry::default();
        let mut in_bots = false;
        for line in raw.lines() {
            let trimmed = line.trim_start();
            if trimmed.starts_with("bots:") {
                in_bots = true;
                continue;
            }
            if !in_bots {
                continue;
            }
            if trimmed.starts_with("- bot_id:") {
                if !cur.bot_id.is_empty() {
                    bots.push(std::mem::take(&mut cur));
                }
                cur.bot_id = trimmed.trim_start_matches("- bot_id:").trim().to_string();
            } else if let Some(v) = trimmed.strip_prefix("tier:") {
                cur.tier = v.trim().to_string();
            } else if let Some(v) = trimmed.strip_prefix("model_tier:") {
                cur.model_tier = v.split_whitespace().next().unwrap_or("").to_string();
            } else if let Some(v) = trimmed.strip_prefix("default_enabled:") {
                cur.default_enabled = v.split_whitespace().next() == Some("true");
            }
        }
        if !cur.bot_id.is_empty() {
            bots.push(cur);
        }

        match subcmd {
            "list" => {
                let enabled = crate::content_bots::enabled_set(&repo_root);
                if json {
                    println!("[");
                    for (i, b) in bots.iter().enumerate() {
                        let en = enabled.contains(&b.bot_id) || b.default_enabled;
                        println!(
                            "  {{\"bot_id\": \"{}\", \"tier\": \"{}\", \"model_tier\": \"{}\", \"enabled\": {}}}{}",
                            b.bot_id,
                            b.tier,
                            b.model_tier,
                            en,
                            if i + 1 == bots.len() { "" } else { "," }
                        );
                    }
                    println!("]");
                } else {
                    println!("{:<14} {:<12} {:<6} ENABLED", "BOT_ID", "TIER", "MODEL");
                    for b in &bots {
                        let en = enabled.contains(&b.bot_id) || b.default_enabled;
                        let mark = if en { "✓" } else { "·" };
                        let src = if enabled.contains(&b.bot_id) {
                            " (config|env)"
                        } else if b.default_enabled {
                            " (default)"
                        } else {
                            ""
                        };
                        println!(
                            "{:<14} {:<12} {:<6} {}{}",
                            b.bot_id, b.tier, b.model_tier, mark, src
                        );
                    }
                    println!();
                    println!(
                        "Toggle: CHUMP_CONTENT_BOTS=<csv> (env) or [content_bots] enabled in .chump-config.toml"
                    );
                }
                return Some(Ok(()));
            }
            _ => {
                eprintln!("chump content-bots: unknown subcommand '{}'", subcmd);
                eprintln!("  Available: list [--json]");
                std::process::exit(2);
            }
        }
    }

    // MISSION-008 / MISSION-030: `chump outcome <sub>` — first-class Outcome object commands.
    // INFRA-3480: chump intake "<plain-language problem>" [--json] [--create]
    // CREATE-mode conversational intake — plain-language restatement, 1-3
    // clarifying questions, and a proposed definition-of-done. Never emits
    // software jargon (structurally enforced in VisionIntakeContract::validate).
    if args.get(1).map(String::as_str) == Some("intake") {
        let json_out = args.iter().any(|a| a == "--json");
        let create = args.iter().any(|a| a == "--create");
        let text = args
            .iter()
            .skip(2)
            .find(|a| !a.starts_with("--"))
            .cloned()
            .unwrap_or_else(|| {
                eprintln!("Usage: chump intake \"<plain-language problem>\" [--json] [--create]");
                std::process::exit(2);
            });
        if let Err(e) = crate::vision_intake::run(&text, json_out, create).await {
            eprintln!("chump intake: {e:#}");
            std::process::exit(1);
        }
        return Some(Ok(()));
    }

    // chump outcome new|create --id X --title T [--priority P] [--dod D]
    // chump outcome list [--status open|done] [--json]
    // chump outcome show <id> [--json]
    // chump outcome status <id> [--json]   (alias for show)
    // chump outcome link <GAP-ID> --outcome <OUTCOME-ID>
    // chump outcome unlink <GAP-ID>
    // chump outcome bootstrap              (seed canonical mission outcomes)
    // chump outcome backfill [--dry-run] [--apply]
    // ADVISORY ONLY — outcome rollup never gates or blocks a child gap from closing.
    if args.get(1).map(String::as_str) == Some("outcome") {
        let sub = args.get(2).map(String::as_str).unwrap_or("help");
        let repo_root = crate::repo_path::repo_root();
        let store = match gap_store::GapStore::open(&repo_root) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("chump outcome: {e:#}");
                std::process::exit(1);
            }
        };
        // Inline flag helper valid for this block (flag closure defined later in main).
        let oflag = |name: &str| -> Option<String> {
            args.windows(2)
                .find(|w| w[0] == name)
                .and_then(|w| w.get(1))
                .cloned()
        };
        let json_out = args.iter().any(|a| a == "--json");
        match sub {
            "new" | "create" => {
                let id = oflag("--id").unwrap_or_else(|| {
                    eprintln!("Usage: chump outcome new --id X --title T [--priority P] [--dod D]");
                    std::process::exit(2);
                });
                let title = oflag("--title").unwrap_or_else(|| {
                    eprintln!("chump outcome new: --title required");
                    std::process::exit(2);
                });
                let priority = oflag("--priority")
                    .or_else(|| oflag("--p"))
                    .unwrap_or_else(|| "P2".into());
                let dod = oflag("--dod")
                    .or_else(|| oflag("--definition-of-done"))
                    .unwrap_or_default();
                match store.create_outcome(&id, &title, &priority, &dod) {
                    Ok(()) => {
                        if json_out {
                            println!(
                                r#"{{"id":"{id}","title":"{title}","priority":"{priority}","created":true}}"#
                            );
                        } else {
                            println!(
                                "outcome {} created (advisory — never gates child close)",
                                id
                            );
                        }
                    }
                    Err(e) => {
                        eprintln!("chump outcome new: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "list" => {
                let status_filter = oflag("--status");
                let outcomes = store.list_outcomes().unwrap_or_default();
                let outcomes: Vec<_> = outcomes
                    .into_iter()
                    .filter(|o| {
                        status_filter
                            .as_deref()
                            .map(|s| o.status == s)
                            .unwrap_or(true)
                    })
                    .collect();
                if json_out {
                    // Build gap-count per outcome for richer output.
                    let all_gaps = store.list(None).unwrap_or_default();
                    let items: Vec<String> = outcomes
                        .iter()
                        .map(|o| {
                            let gap_count = all_gaps
                                .iter()
                                .filter(|g| g.outcome_id.as_deref() == Some(o.id.as_str()))
                                .count();
                            let open_count = all_gaps
                                .iter()
                                .filter(|g| {
                                    g.outcome_id.as_deref() == Some(o.id.as_str())
                                        && g.status == "open"
                                })
                                .count();
                            format!(
                                r#"{{"id":"{}","title":"{}","priority":"{}","status":"{}","gap_count":{},"open_count":{}}}"#,
                                o.id,
                                o.title.replace('"', "\\\""),
                                o.priority,
                                o.status,
                                gap_count,
                                open_count,
                            )
                        })
                        .collect();
                    println!("[{}]", items.join(","));
                } else {
                    if outcomes.is_empty() {
                        println!(
                            "(no outcomes registered — use `chump outcome bootstrap` or `chump outcome create`)"
                        );
                    }
                    let all_gaps = store.list(None).unwrap_or_default();
                    for o in &outcomes {
                        let gap_count = all_gaps
                            .iter()
                            .filter(|g| g.outcome_id.as_deref() == Some(o.id.as_str()))
                            .count();
                        println!(
                            "{} [{}] {} — {} ({} gaps)",
                            o.id, o.priority, o.status, o.title, gap_count
                        );
                    }
                }
            }
            // MISSION-030: `show` = detailed view of one outcome + its linked gaps.
            "show" | "status" => {
                let oid = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump outcome show <outcome-id> [--json]");
                    std::process::exit(2);
                });
                match store.outcome_status(&oid) {
                    Ok(Some(r)) => {
                        if json_out {
                            // Include linked gaps in JSON.
                            let linked = store.gaps_for_outcome(&oid).unwrap_or_default();
                            let gaps_json: Vec<String> = linked
                                .iter()
                                .map(|g| {
                                    format!(
                                        r#"{{"id":"{}","title":"{}","status":"{}","priority":"{}"}}"#,
                                        g.id,
                                        g.title.replace('"', "\\\""),
                                        g.status,
                                        g.priority,
                                    )
                                })
                                .collect();
                            println!(
                                r#"{{"outcome_id":"{}","title":"{}","priority":"{}","status":"{}","definition_of_done":"{}","total":{},"open":{},"done":{},"other":{},"advisory":true,"gaps":[{}]}}"#,
                                r.outcome.id,
                                r.outcome.title.replace('"', "\\\""),
                                r.outcome.priority,
                                r.outcome.status,
                                r.outcome.definition_of_done.replace('"', "\\\""),
                                r.total,
                                r.open,
                                r.done,
                                r.other,
                                gaps_json.join(","),
                            );
                        } else {
                            println!("=== Outcome: {} ===", r.outcome.id);
                            println!("Title    : {}", r.outcome.title);
                            println!("Priority : {}", r.outcome.priority);
                            println!("Status   : {}", r.outcome.status);
                            if !r.outcome.definition_of_done.is_empty() {
                                println!("DoD      : {}", r.outcome.definition_of_done);
                            }
                            println!();
                            println!("Child gaps (advisory rollup — never gates close):");
                            println!(
                                "  total: {}  open: {}  done: {}  other: {}",
                                r.total, r.open, r.done, r.other
                            );
                            if r.total > 0 {
                                let pct = (r.done as f64 / r.total as f64 * 100.0) as usize;
                                println!("  progress: {}%", pct);
                            }
                            let linked = store.gaps_for_outcome(&oid).unwrap_or_default();
                            if !linked.is_empty() {
                                println!();
                                println!("Linked gaps:");
                                for g in &linked {
                                    println!(
                                        "  {} [{}] {} — {}",
                                        g.id, g.priority, g.status, g.title
                                    );
                                }
                            }
                        }
                    }
                    Ok(None) => {
                        eprintln!("chump outcome show: outcome '{}' not found", oid);
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("chump outcome show: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            // MISSION-030: `link <GAP-ID> --outcome <OUTCOME-ID>` — set gaps.outcome_id.
            "link" => {
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump outcome link <GAP-ID> --outcome <OUTCOME-ID>");
                    std::process::exit(2);
                });
                let oid = oflag("--outcome").unwrap_or_else(|| {
                    eprintln!("chump outcome link: --outcome required");
                    std::process::exit(2);
                });
                // Verify outcome exists before linking.
                match store.get_outcome(&oid) {
                    Ok(None) => {
                        eprintln!(
                            "chump outcome link: outcome '{}' not found — create it first",
                            oid
                        );
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("chump outcome link: {e:#}");
                        std::process::exit(1);
                    }
                    Ok(Some(_)) => {}
                }
                let update = gap_store::GapFieldUpdate {
                    outcome_id: Some(oid.clone()),
                    ..Default::default()
                };
                match store.set_fields(&gap_id, update) {
                    Ok(()) => {
                        if json_out {
                            println!(
                                r#"{{"gap_id":"{gap_id}","outcome_id":"{oid}","linked":true}}"#
                            );
                        } else {
                            println!("{} linked to outcome {}", gap_id, oid);
                        }
                    }
                    Err(e) => {
                        eprintln!("chump outcome link: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            // MISSION-030: `unlink <GAP-ID>` — clear gaps.outcome_id.
            "unlink" => {
                let gap_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump outcome unlink <GAP-ID>");
                    std::process::exit(2);
                });
                let update = gap_store::GapFieldUpdate {
                    outcome_id: Some(String::new()), // empty = set NULL
                    ..Default::default()
                };
                match store.set_fields(&gap_id, update) {
                    Ok(()) => {
                        if json_out {
                            println!(r#"{{"gap_id":"{gap_id}","outcome_id":null,"linked":false}}"#);
                        } else {
                            println!("{} unlinked from outcome", gap_id);
                        }
                    }
                    Err(e) => {
                        eprintln!("chump outcome unlink: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            // MISSION-030: `bootstrap` — seed canonical mission outcomes (idempotent).
            // MISSION-043: also seeds 4 pillar outcomes (CREDIBLE/EFFECTIVE/RESILIENT/ZERO-WASTE).
            "bootstrap" => {
                // Canonical outcomes per docs/MISSION.md and gap dispatch context.
                // Each entry: (id, title, priority, dod)
                let canonical: &[(&str, &str, &str, &str)] = &[
                    (
                        "MISSION-010",
                        "self-coordinating fleet (BEAST proof)",
                        "P0",
                        "Fleet ships PRs to external repos without human in the loop; \
                         BEAST-MODE overnight proof completed.",
                    ),
                    (
                        "MISSION-012",
                        "self-deploy: auto-deploy daemon keeps installed binary on origin/main",
                        "P0",
                        "Binary on each fleet node always tracks origin/main; \
                         no manual pull required after a ship.",
                    ),
                    (
                        "MISSION-032",
                        "scale to 100s-to-10000s of external repos",
                        "P1",
                        "Phase B: repos table + external claims + per-repo mission scoreboard; \
                         Phase C: multi-tenant with repo_scope.",
                    ),
                    (
                        "META-067",
                        "three demo-able 2026 outcomes: net-new bootstrap / repo takeover / autonomous throughput",
                        "P1",
                        "Demo 1: zero-to-first-PR on a blank repo; \
                         Demo 2: Chump takes over an existing repo; \
                         Demo 3: sustained autonomous throughput.",
                    ),
                    // MISSION-043: four pillar outcomes — one per quality pillar.
                    (
                        "CREDIBLE-000",
                        "Credible: measurable, verifiable, trustworthy",
                        "P1",
                        "Every CREDIBLE-* gap traces to honest measurement (no proxy metrics, \
                         no silent failures). Reality-check gate (CREDIBLE-090) is the keystone.",
                    ),
                    (
                        "EFFECTIVE-000",
                        "Effective: user-facing capability, real-world impact",
                        "P1",
                        "Every EFFECTIVE-* gap moves a user-visible surface forward \
                         (CLI, PWA, docs that reach humans). META-067 demo outcomes are \
                         canonical evidence.",
                    ),
                    (
                        "RESILIENT-000",
                        "Resilient: self-healing, no fragile single points of failure",
                        "P1",
                        "Every RESILIENT-* gap removes a halt-class or recovers from one. \
                         Fleet recovers from any halt with no human terminal.",
                    ),
                    (
                        "ZERO-WASTE-000",
                        "Zero-waste: no idle agents, no duplicated work, no shelved capability",
                        "P1",
                        "Every ZERO-WASTE-* gap removes a waste class. \
                         Substrate doesn't accumulate without being used.",
                    ),
                ];
                let mut created = 0usize;
                let mut already = 0usize;
                for (id, title, priority, dod) in canonical {
                    // Check existence first (create_outcome is idempotent via INSERT OR IGNORE).
                    let exists = store.get_outcome(id).unwrap_or(None).is_some();
                    match store.create_outcome(id, title, priority, dod) {
                        Ok(()) => {
                            if exists {
                                already += 1;
                                if !json_out {
                                    println!("  {} already exists (skipped)", id);
                                }
                            } else {
                                created += 1;
                                if !json_out {
                                    println!("  {} created: {}", id, title);
                                }
                            }
                        }
                        Err(e) => {
                            eprintln!("chump outcome bootstrap: error creating {}: {}", id, e);
                        }
                    }
                }
                if json_out {
                    println!(
                        r#"{{"created":{},"already_existed":{},"total":{}}}"#,
                        created,
                        already,
                        canonical.len()
                    );
                } else {
                    println!();
                    println!(
                        "bootstrap complete: {} created, {} already existed ({} total)",
                        created,
                        already,
                        canonical.len()
                    );
                }
            }
            // MISSION-030: `backfill [--dry-run] [--apply]` — auto-link open gaps to outcomes.
            "backfill" => {
                let dry_run = !args.iter().any(|a| a == "--apply");
                if dry_run {
                    println!("[outcome backfill] DRY RUN — use --apply to commit changes");
                }

                let outcomes = store.list_outcomes().unwrap_or_default();
                if outcomes.is_empty() {
                    eprintln!(
                        "chump outcome backfill: no outcomes registered. Run `chump outcome bootstrap` first."
                    );
                    std::process::exit(1);
                }

                let all_gaps = match store.list(None) {
                    Ok(g) => g,
                    Err(e) => {
                        eprintln!("chump outcome backfill: {e:#}");
                        std::process::exit(1);
                    }
                };

                // Build outcome-id set for fast lookup.
                let outcome_ids: std::collections::HashSet<&str> =
                    outcomes.iter().map(|o| o.id.as_str()).collect();

                // Backfill heuristics (applied in order; first match wins):
                // 1. Exact-prefix: gap.id == outcome.id → link directly.
                //    (e.g. MISSION-030 → MISSION-010 as scaffolding)
                //    Actually: for gaps whose id STARTS with same prefix as any outcome.
                //    Concretely: MISSION-* gaps → MISSION-010 (the umbrella mission).
                // 2. Title contains outcome id → link to that outcome.
                // 3. Description contains "MISSION-XXX umbrella" / "Tier-1 of MISSION-XXX"
                //    → link to named outcome id if registered.
                // 4. Title/description contains "BEAST" or "BEAST-MODE" → MISSION-010.
                // 5. Title/description contains "META-067" → META-067.
                // Default: skip (don't guess).

                // Counters per outcome.
                let mut counts: std::collections::HashMap<&str, usize> =
                    outcomes.iter().map(|o| (o.id.as_str(), 0usize)).collect();
                let mut skipped = 0usize;
                let mut already_linked = 0usize;
                let mut changes: Vec<(String, String)> = Vec::new(); // (gap_id, outcome_id)

                for g in &all_gaps {
                    // Don't overwrite existing links.
                    if g.outcome_id.as_deref().map(|s| !s.is_empty()) == Some(true) {
                        already_linked += 1;
                        continue;
                    }

                    let id_uc = g.id.to_uppercase();
                    let title_uc = g.title.to_uppercase();
                    let desc_uc = g.description.to_uppercase();

                    let mut assigned: Option<&str> = None;

                    // Heuristic 1: gap id IS a registered outcome → self-link.
                    if outcome_ids.contains(g.id.as_str()) {
                        assigned = Some(g.id.as_str());
                    }

                    // Heuristic 2: gap title contains a registered outcome id.
                    if assigned.is_none() {
                        for oid in &outcome_ids {
                            if title_uc.contains(&oid.to_uppercase()) {
                                assigned = Some(oid);
                                break;
                            }
                        }
                    }

                    // Heuristic 3: description contains "umbrella" or "Tier-1 of" phrase
                    // referring to a registered outcome id.
                    if assigned.is_none() {
                        for oid in &outcome_ids {
                            let needle = oid.to_uppercase();
                            let paren_prefix = format!("({needle} ");
                            let paren_slice = format!("({needle} SLICE");
                            if desc_uc.contains(&format!("{needle} UMBRELLA"))
                                || desc_uc.contains(&format!("TIER-1 OF {needle}"))
                                || desc_uc.contains(paren_prefix.as_str())
                                || desc_uc.contains(paren_slice.as_str())
                                || desc_uc.contains(&format!("{needle} PHASE"))
                            {
                                assigned = Some(oid);
                                break;
                            }
                        }
                    }

                    // Heuristic 4: BEAST / BEAST-MODE → MISSION-010.
                    if assigned.is_none()
                        && outcome_ids.contains("MISSION-010")
                        && (title_uc.contains("BEAST") || desc_uc.contains("BEAST"))
                    {
                        assigned = Some("MISSION-010");
                    }

                    // Heuristic 5: META-067 in title or description → META-067.
                    if assigned.is_none()
                        && outcome_ids.contains("META-067")
                        && (title_uc.contains("META-067") || desc_uc.contains("META-067"))
                    {
                        assigned = Some("META-067");
                    }

                    // Heuristic 6: MISSION-* prefix gap ids → MISSION-010 umbrella
                    // (since MISSION-010 is the fleet self-coordination master mission).
                    if assigned.is_none()
                        && id_uc.starts_with("MISSION-")
                        && outcome_ids.contains("MISSION-010")
                    {
                        assigned = Some("MISSION-010");
                    }

                    // Heuristic 7 (MISSION-043): domain-prefix → pillar outcome.
                    // Only fires when the pillar outcome is registered (idempotent /
                    // graceful fallback when bootstrap wasn't run yet).
                    if assigned.is_none() {
                        if id_uc.starts_with("CREDIBLE-") && outcome_ids.contains("CREDIBLE-000") {
                            assigned = Some("CREDIBLE-000");
                        } else if id_uc.starts_with("EFFECTIVE-")
                            && outcome_ids.contains("EFFECTIVE-000")
                        {
                            assigned = Some("EFFECTIVE-000");
                        } else if id_uc.starts_with("RESILIENT-")
                            && outcome_ids.contains("RESILIENT-000")
                        {
                            assigned = Some("RESILIENT-000");
                        } else if (id_uc.starts_with("ZERO-WASTE-") || id_uc.starts_with("ZERO-"))
                            && outcome_ids.contains("ZERO-WASTE-000")
                        {
                            assigned = Some("ZERO-WASTE-000");
                        }
                    }

                    // Heuristic 8 (MISSION-043): INFRA-* and META-* → MISSION-010.
                    // INFRA gaps are fleet infrastructure gaps; they collectively implement
                    // the self-coordinating-fleet mission. META-* gaps are fleet PM/process
                    // gaps that support mission coordination. Both route to MISSION-010
                    // as the umbrella fleet-mission outcome.
                    // Only fires when MISSION-010 is registered.
                    if assigned.is_none()
                        && outcome_ids.contains("MISSION-010")
                        && (id_uc.starts_with("INFRA-") || id_uc.starts_with("META-"))
                    {
                        assigned = Some("MISSION-010");
                    }

                    match assigned {
                        Some(oid) => {
                            changes.push((g.id.clone(), oid.to_string()));
                            *counts.entry(oid).or_default() += 1;
                        }
                        None => {
                            skipped += 1;
                        }
                    }
                }

                // Report plan.
                println!("Backfill plan:");
                for o in &outcomes {
                    let c = counts.get(o.id.as_str()).copied().unwrap_or(0);
                    if c > 0 {
                        println!("  {} ← {} gap(s)", o.id, c);
                    }
                }
                println!("  already linked: {}", already_linked);
                println!("  unmatched (skipped): {}", skipped);
                println!("  total to link: {}", changes.len());

                if dry_run {
                    println!();
                    println!("[dry-run] no changes written. Re-run with --apply to commit.");
                    return Some(Ok(()));
                }

                // Apply.
                let mut applied = 0usize;
                let mut errors = 0usize;
                for (gid, oid) in &changes {
                    let update = gap_store::GapFieldUpdate {
                        outcome_id: Some(oid.clone()),
                        ..Default::default()
                    };
                    match store.set_fields(gid, update) {
                        Ok(()) => {
                            applied += 1;
                        }
                        Err(e) => {
                            eprintln!("  WARN: could not link {} → {}: {}", gid, oid, e);
                            errors += 1;
                        }
                    }
                }
                println!();
                if json_out {
                    println!(
                        r#"{{"applied":{},"errors":{},"already_linked":{},"skipped":{}}}"#,
                        applied, errors, already_linked, skipped
                    );
                } else {
                    println!("applied {} link(s), {} error(s)", applied, errors);
                    // Emit ambient event for observability.
                    let lock_dir = repo_root.join(".chump-locks");
                    let ambient = lock_dir.join("ambient.jsonl");
                    let ts = std::process::Command::new("date")
                        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
                        .output()
                        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                        .unwrap_or_default();
                    // scanner-anchor: outcome_backfill_completed (MISSION-030)
                    let event = format!(
                        r#"{{"ts":"{ts}","kind":"outcome_backfill_completed","applied":{applied},"errors":{errors},"skipped":{skipped}}}"#,
                    );
                    let _ = std::fs::OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(&ambient)
                        .and_then(|mut f| {
                            use std::io::Write;
                            writeln!(f, "{}", event)
                        });
                }
            }
            // RESILIENT-254: `park <outcome-id> --reason "..."` — declare that
            // an outcome with open, non-moving children is parked ON PURPOSE.
            // Excludes it from the L5-SLO-2 commitment-rot breach so a
            // deliberate decision doesn't train the operator to ignore SLOs.
            "park" => {
                let oid = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump outcome park <outcome-id> --reason \"...\"");
                    std::process::exit(2);
                });
                let reason = oflag("--reason").unwrap_or_else(|| {
                    eprintln!("chump outcome park: --reason required (why is this on hold?)");
                    std::process::exit(2);
                });
                match store.park_outcome(&oid, &reason) {
                    Ok(()) => {
                        if json_out {
                            println!(
                                r#"{{"outcome_id":"{oid}","status":"parked","park_reason":"{}"}}"#,
                                reason.replace('"', "\\\"")
                            );
                        } else {
                            println!("{} parked: {}", oid, reason);
                        }
                    }
                    Err(e) => {
                        eprintln!("chump outcome park: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "unpark" => {
                let oid = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump outcome unpark <outcome-id>");
                    std::process::exit(2);
                });
                match store.unpark_outcome(&oid) {
                    Ok(()) => {
                        if json_out {
                            println!(r#"{{"outcome_id":"{oid}","status":"open"}}"#);
                        } else {
                            println!("{} unparked (status: open)", oid);
                        }
                    }
                    Err(e) => {
                        eprintln!("chump outcome unpark: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            _ => {
                println!("Usage: chump outcome <sub> [args]");
                println!();
                println!("Subcommands:");
                println!("  create --id X --title T [--priority P] [--dod D]");
                println!("  list [--status open|done] [--json]");
                println!("  show <outcome-id> [--json]");
                println!("  link <gap-id> --outcome <outcome-id>");
                println!("  unlink <gap-id>");
                println!(
                    "  park <outcome-id> --reason \"...\"   (RESILIENT-254: exempt from L5-SLO-2)"
                );
                println!("  unpark <outcome-id>");
                println!("  bootstrap   (seed 8 outcomes: MISSION-010/012/032 + META-067 + 4 pillar outcomes)");
                println!("  backfill [--dry-run] [--apply]");
                println!();
                println!(
                    "ADVISORY: outcome rollup never gates or blocks a child gap from closing."
                );
            }
        }
        return Some(Ok(()));
    }

    // MISSION-033: `chump repos <sub>` — first-class repo index commands.
    // chump repos list [--status active|paused|archived] [--json]
    // chump repos show <owner/repo> [--json]
    // chump repos add <owner/repo> [--cascade-tier T] [--status S]
    // chump repos set <owner/repo> --cascade-tier T | --status S | --last-clone-at N | ...
    // chump repos rm <owner/repo>
    //
    // Derived index: repos table is populated by auto-upsert on `chump gap import`
    // for every external_repo:* tag in gaps.skills_required. Manual add also supported.
    if args.get(1).map(String::as_str) == Some("repos") {
        let sub = args.get(2).map(String::as_str).unwrap_or("help");
        let repo_root = crate::repo_path::repo_root();
        let store = match gap_store::GapStore::open(&repo_root) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("chump repos: {e:#}");
                std::process::exit(1);
            }
        };
        let rflag = |name: &str| -> Option<String> {
            args.windows(2)
                .find(|w| w[0] == name)
                .and_then(|w| w.get(1))
                .cloned()
        };
        let json_out = args.iter().any(|a| a == "--json");

        match sub {
            "list" => {
                let status_filter = rflag("--status");
                let repos = match store.list_repos(status_filter.as_deref()) {
                    Ok(r) => r,
                    Err(e) => {
                        eprintln!("chump repos list: {e:#}");
                        std::process::exit(1);
                    }
                };
                if json_out {
                    let items: Vec<String> = repos
                        .iter()
                        .map(|r| {
                            let gap_count = store.repo_gap_count(&r.id).unwrap_or(0);
                            format!(
                                r#"{{"id":"{}","owner":"{}","name":"{}","added_at":{},"last_scan_at":{},"last_clone_at":{},"last_ship_at":{},"cascade_tier":"{}","status":"{}","gap_count":{}}}"#,
                                r.id.replace('"', "\\\""),
                                r.owner.replace('"', "\\\""),
                                r.name.replace('"', "\\\""),
                                r.added_at,
                                r.last_scan_at.map(|v| v.to_string()).unwrap_or_else(|| "null".into()),
                                r.last_clone_at.map(|v| v.to_string()).unwrap_or_else(|| "null".into()),
                                r.last_ship_at.map(|v| v.to_string()).unwrap_or_else(|| "null".into()),
                                r.cascade_tier,
                                r.status,
                                gap_count,
                            )
                        })
                        .collect();
                    println!("[{}]", items.join(","));
                } else {
                    if repos.is_empty() {
                        println!("(no repos registered — run `chump gap import` or `chump repos add <owner/repo>`)");
                    }
                    for r in &repos {
                        let gap_count = store.repo_gap_count(&r.id).unwrap_or(0);
                        println!(
                            "{} [{}] {} | last_scan={} | last_clone={} | gaps={}",
                            r.id,
                            r.cascade_tier,
                            r.status,
                            r.last_scan_at
                                .map(|v| v.to_string())
                                .unwrap_or_else(|| "never".into()),
                            r.last_clone_at
                                .map(|v| v.to_string())
                                .unwrap_or_else(|| "never".into()),
                            gap_count,
                        );
                    }
                }
            }
            "show" => {
                let repo_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump repos show <owner/repo> [--json]");
                    std::process::exit(2);
                });
                match store.get_repo(&repo_id) {
                    Ok(Some(r)) => {
                        let gap_count = store.repo_gap_count(&r.id).unwrap_or(0);
                        if json_out {
                            println!(
                                r#"{{"id":"{}","owner":"{}","name":"{}","added_at":{},"last_scan_at":{},"last_clone_at":{},"last_ship_at":{},"cascade_tier":"{}","status":"{}","gap_count":{}}}"#,
                                r.id.replace('"', "\\\""),
                                r.owner.replace('"', "\\\""),
                                r.name.replace('"', "\\\""),
                                r.added_at,
                                r.last_scan_at
                                    .map(|v| v.to_string())
                                    .unwrap_or_else(|| "null".into()),
                                r.last_clone_at
                                    .map(|v| v.to_string())
                                    .unwrap_or_else(|| "null".into()),
                                r.last_ship_at
                                    .map(|v| v.to_string())
                                    .unwrap_or_else(|| "null".into()),
                                r.cascade_tier,
                                r.status,
                                gap_count,
                            );
                        } else {
                            println!("=== Repo: {} ===", r.id);
                            println!("Owner        : {}", r.owner);
                            println!("Name         : {}", r.name);
                            println!("Cascade tier : {}", r.cascade_tier);
                            println!("Status       : {}", r.status);
                            println!("Added at     : {}", r.added_at);
                            println!(
                                "Last scan    : {}",
                                r.last_scan_at
                                    .map(|v| v.to_string())
                                    .unwrap_or_else(|| "never".into())
                            );
                            println!(
                                "Last clone   : {}",
                                r.last_clone_at
                                    .map(|v| v.to_string())
                                    .unwrap_or_else(|| "never".into())
                            );
                            println!(
                                "Last ship    : {}",
                                r.last_ship_at
                                    .map(|v| v.to_string())
                                    .unwrap_or_else(|| "never".into())
                            );
                            println!("Linked gaps  : {}", gap_count);
                        }
                    }
                    Ok(None) => {
                        eprintln!("chump repos show: '{}' not found", repo_id);
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("chump repos show: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "add" => {
                let repo_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!(
                        "Usage: chump repos add <owner/repo> [--cascade-tier T] [--status S]"
                    );
                    std::process::exit(2);
                });
                let slash = repo_id.find('/').unwrap_or_else(|| {
                    eprintln!(
                        "chump repos add: id must be 'owner/repo', got '{}'",
                        repo_id
                    );
                    std::process::exit(2);
                });
                let owner = &repo_id[..slash];
                let name = &repo_id[slash + 1..];
                if owner.is_empty() || name.is_empty() {
                    eprintln!("chump repos add: owner and name must be non-empty");
                    std::process::exit(2);
                }
                let cascade_tier = rflag("--cascade-tier").unwrap_or_else(|| "dogfood".into());
                let status = rflag("--status").unwrap_or_else(|| "active".into());
                match store.add_repo(&repo_id, owner, name, &cascade_tier, &status) {
                    Ok(()) => {
                        if json_out {
                            println!(
                                r#"{{"id":"{repo_id}","cascade_tier":"{cascade_tier}","status":"{status}","added":true}}"#
                            );
                        } else {
                            println!(
                                "repo {} added (tier={}, status={})",
                                repo_id, cascade_tier, status
                            );
                        }
                    }
                    Err(e) => {
                        eprintln!("chump repos add: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "set" => {
                let repo_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump repos set <owner/repo> [--cascade-tier T] [--status S] [--last-scan-at N] [--last-clone-at N] [--last-ship-at N]");
                    std::process::exit(2);
                });
                let cascade_tier = rflag("--cascade-tier");
                let status = rflag("--status");
                let last_scan_at = rflag("--last-scan-at").and_then(|v| v.parse::<i64>().ok());
                let last_clone_at = rflag("--last-clone-at").and_then(|v| v.parse::<i64>().ok());
                let last_ship_at = rflag("--last-ship-at").and_then(|v| v.parse::<i64>().ok());
                match store.set_repo_fields(
                    &repo_id,
                    cascade_tier.as_deref(),
                    status.as_deref(),
                    last_scan_at,
                    last_clone_at,
                    last_ship_at,
                ) {
                    Ok(true) => {
                        if json_out {
                            println!(r#"{{"id":"{repo_id}","updated":true}}"#);
                        } else {
                            println!("repo {} updated", repo_id);
                        }
                    }
                    Ok(false) => {
                        eprintln!("chump repos set: '{}' not found — add it first", repo_id);
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("chump repos set: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            "rm" | "remove" => {
                let repo_id = args.get(3).cloned().unwrap_or_else(|| {
                    eprintln!("Usage: chump repos rm <owner/repo>");
                    std::process::exit(2);
                });
                match store.remove_repo(&repo_id) {
                    Ok(true) => {
                        if json_out {
                            println!(r#"{{"id":"{repo_id}","removed":true}}"#);
                        } else {
                            println!("repo {} removed", repo_id);
                        }
                    }
                    Ok(false) => {
                        eprintln!("chump repos rm: '{}' not found", repo_id);
                        std::process::exit(1);
                    }
                    Err(e) => {
                        eprintln!("chump repos rm: {e:#}");
                        std::process::exit(1);
                    }
                }
            }
            _ => {
                println!("Usage: chump repos <sub> [args]");
                println!();
                println!("Subcommands:");
                println!("  list [--status active|paused|archived] [--json]");
                println!("  show <owner/repo> [--json]");
                println!("  add <owner/repo> [--cascade-tier T] [--status S]");
                println!("  set <owner/repo> [--cascade-tier T] [--status S]");
                println!("         [--last-scan-at EPOCH] [--last-clone-at EPOCH] [--last-ship-at EPOCH]");
                println!("  rm <owner/repo>");
                println!();
                println!("Derived index: repos rows are auto-upserted from external_repo:* tags");
                println!("in gaps.skills_required on `chump gap import`. Lifecycle is decoupled");
                println!("from gaps — removing a gap does NOT remove its repo row.");
                println!();
                println!("Daemon-callable: `chump repos set <id> --last-clone-at EPOCH` works");
                println!("without a TTY (used by MISSION-035 clone GC and MISSION-038 scheduler).");
            }
        }
        return Some(Ok(()));
    }

    // `chump roadmap-status [--json] [--exit-on-drift] [--top-starved N]`
    // INFRA-606: reads docs/ROADMAP.md, shows 🟢/🟡/🔴 progress per weekly outcome.
    // INFRA-1145: adds starved_outcomes, untraced_p0, pillar_coverage, --exit-on-drift.
    if args.get(1).map(String::as_str) == Some("roadmap-status") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump roadmap-status [--json] [--exit-on-drift] [--top-starved N]");
            println!();
            println!("Reads docs/ROADMAP.md and shows 🟢/🟡/🔴 progress per weekly outcome.");
            println!("Lists implementing gaps with shipped/in-flight/open counts cross-referenced");
            println!("against state.db.");
            println!();
            println!("Options:");
            println!("  --json            output in JSON format");
            println!("  --exit-on-drift   exit 1 if starved outcomes or untraced P0/P1 gaps found");
            println!(
                "  --top-starved N   limit starved_outcomes output to N entries (default: all)"
            );
            println!();
            println!("Exit codes:");
            println!("  0 — no drift detected (or --exit-on-drift not set)");
            println!("  1 — drift detected when --exit-on-drift is set");
            println!();
            println!("Examples:");
            println!("  chump roadmap-status");
            println!("  chump roadmap-status --json | jq .starved_outcomes");
            println!("  chump roadmap-status --exit-on-drift  # CI gate");
            return Some(Ok(()));
        }
        let want_json = args.iter().any(|a| a == "--json");
        let exit_on_drift = args.iter().any(|a| a == "--exit-on-drift");

        // Parse --top-starved N
        let top_starved: usize = args
            .windows(2)
            .find(|w| w[0] == "--top-starved")
            .and_then(|w| w[1].parse::<usize>().ok())
            .unwrap_or(usize::MAX);

        let repo_root = crate::repo_path::repo_root();
        let report = crate::roadmap_status::build_report(&repo_root);

        // INFRA-1145: emit ambient event when drift detected and --exit-on-drift set
        if exit_on_drift && report.has_drift() {
            let lock_dir = repo_root.join(".chump-locks");
            let ambient = lock_dir.join("ambient.jsonl");
            if let Ok(ts_out) = std::process::Command::new("date")
                .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
                .output()
            {
                let ts_str = String::from_utf8_lossy(&ts_out.stdout).trim().to_string();
                let starved_json: Vec<String> = report
                    .starved_outcomes
                    .iter()
                    .map(|w| w.to_string())
                    .collect();
                let untraced_json: Vec<String> = report
                    .untraced_p0
                    .iter()
                    .map(|id| format!(r#""{id}""#))
                    .collect();
                let event = format!(
                    r#"{{"ts":"{ts}","kind":"roadmap_drift_detected","starved_outcomes":[{s}],"untraced_p0":[{u}]}}"#,
                    ts = ts_str,
                    s = starved_json.join(","),
                    u = untraced_json.join(","),
                );
                let _ = std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&ambient)
                    .and_then(|mut f| {
                        use std::io::Write;
                        writeln!(f, "{}", event)
                    });
            }
        }

        if want_json {
            println!("{}", report.render_json_with_opts(top_starved));
        } else {
            print!("{}", report.render_text_with_opts(top_starved));
        }

        if exit_on_drift && report.has_drift() {
            eprintln!(
                "[roadmap-status] DRIFT: {} starved outcome(s), {} untraced P0/P1 gap(s)",
                report.starved_outcomes.len(),
                report.untraced_p0.len()
            );
            std::process::exit(1);
        }
        return Some(Ok(()));
    }

    // `chump fleet-status` (INFRA-494) — single-command operator
    // dashboard combining active leases, last-24h shipped/abandoned,
    // last-24h waste tally summary, and recent fleet wedges.
    // `chump ambient-rotate` (INFRA-941) — rotate ambient.jsonl if over threshold.
    if args.get(1).map(String::as_str) == Some("ambient-rotate") {
        let repo_root = crate::repo_path::repo_root();
        let ambient = repo_root.join(".chump-locks/ambient.jsonl");
        let threshold_mb = std::env::var("CHUMP_AMBIENT_MAX_MB")
            .ok()
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(50);
        let size_mb = std::fs::metadata(&ambient)
            .map(|m| m.len() / (1024 * 1024))
            .unwrap_or(0);
        if crate::ambient_rotate::rotate_if_needed(&ambient) {
            println!(
                "rotated: ambient.jsonl ({} MB) → ambient.jsonl.1 (threshold {} MB)",
                size_mb, threshold_mb
            );
        } else {
            println!(
                "no-op: ambient.jsonl is {} MB (threshold {} MB)",
                size_mb, threshold_mb
            );
        }
        return Some(Ok(()));
    }

    if args.get(1).map(String::as_str) == Some("fleet-status") {
        if args.iter().any(|a| a == "--help" || a == "help") {
            println!("Usage: chump fleet-status");
            println!();
            println!("Single-command operator dashboard combining active leases, last-24h");
            println!("shipped/abandoned, last-24h waste tally summary, and recent fleet wedges.");
            println!();
            println!("Example:");
            println!("  chump fleet-status");
            return Some(Ok(()));
        }
        let repo_root = crate::repo_path::repo_root();
        let status = crate::fleet_status::snapshot(&repo_root);
        print!("{}", status.render_text());
        return Some(Ok(()));
    }

    None
}
