//! EFFECTIVE-010: shell completion scripts for the chump CLI.
//!
//! Invoked via `chump completion [zsh|bash|fish]`.
//! Install:
//!   zsh:  chump completion zsh > $(brew --prefix)/share/zsh/site-functions/_chump
//!   bash: chump completion bash >> ~/.bashrc
//!   fish: chump completion fish > ~/.config/fish/completions/chump.fish

const TOP_LEVEL: &[&str] = &[
    "ambient", "ambient-rotate", "cascade", "ci-summary", "claim",
    "classify-failure", "completion", "cost", "cost-check", "cost-report",
    "cost-watch", "dashboard", "dispatch", "emit", "fix-clippy",
    "fleet", "fleet-status", "fleet-velocity", "funnel", "gap",
    "gen", "health", "health-digest", "help", "init", "kpi",
    "lesson-grade", "mission-grade", "orchestrate", "plan", "pr",
    "pr-coupling-cost", "priority", "rebase-stuck", "record-pr",
    "reflect-delta", "report", "roadmap-status", "route", "scoreboard",
    "session-export", "session-resume", "session-track", "ship-quality",
    "simulate", "stats", "triage", "waste-tally",
    // top-level flags
    "--release", "--leases", "--heartbeat", "--briefing", "--help", "--version",
];

const GAP_SUBS: &[&str] = &[
    "list", "show", "ship", "reserve", "import", "import-spec",
    "claim", "preflight", "decompose", "audit-priorities", "audit-ac",
    "set", "edit", "update",
];

const GAP_FLAGS: &[&str] = &[
    "--status", "--priority", "--effort", "--domain", "--json",
    "--update-yaml", "--closed-pr", "--force", "--dry-run",
];

const COMMON_FLAGS: &[&str] = &["--json", "--help", "--verbose"];

pub fn zsh() -> String {
    let top = TOP_LEVEL.join(" ");
    let gap = GAP_SUBS.join(" ");
    let gap_flags = GAP_FLAGS.join(" ");
    let common = COMMON_FLAGS.join(" ");

    format!(
        r#"#compdef chump
# EFFECTIVE-010: zsh completion for chump
# Install: chump completion zsh | sudo tee $(brew --prefix)/share/zsh/site-functions/_chump

_chump() {{
  local -a cmds gap_cmds
  cmds=({top})
  gap_cmds=({gap})

  local state
  _arguments -C \
    '1: :->cmd' \
    '*:: :->args' && return 0

  case $state in
    cmd)
      _describe 'chump command' cmds
      ;;
    args)
      case $words[1] in
        gap)
          if (( CURRENT == 2 )); then
            _describe 'gap subcommand' gap_cmds
          else
            case $words[2] in
              show|ship|claim|preflight|decompose|audit-priorities|audit-ac)
                _arguments '*:gap-id:_chump_gap_ids'
                ;;
              list)
                _arguments \
                  '--status[filter by status]:status:(open done)' \
                  '--domain[filter by domain]:domain:(INFRA PRODUCT EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE)' \
                  '--priority[filter by priority]:priority:(P0 P1 P2 P3)' \
                  '{common}'
                ;;
              reserve)
                _arguments \
                  '--domain[gap domain (required)]:domain:(INFRA PRODUCT EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE)' \
                  '--title[gap title (required)]:title:' \
                  '--priority[priority]:priority:(P0 P1 P2 P3)' \
                  '--effort[effort estimate]:effort:(xs s m l xl)' \
                  '--force[skip duplicate check]'
                ;;
              *)
                _arguments '*: :{gap_flags}'
                ;;
            esac
          fi
          ;;
        claim)
          _arguments \
            '1:gap-id:_chump_gap_ids' \
            '--paths[comma-separated file paths]:paths:_files' \
            '--session[session id override]:session:' \
            '--skip-doctor[skip doctor probe]' \
            '--skip-import[skip state.db import]' \
            '--resume[reset to remote tip if branch exists]'
          ;;
        completion)
          _arguments '1:shell:(zsh bash fish)'
          ;;
        health)
          _arguments \
            '--json[output as JSON]' \
            '--watch[refresh every 30s]' \
            '--slo-check[exit non-zero on SLO breach]'
          ;;
        waste-tally)
          _arguments \
            '--window[time window (e.g. 2h, 24h)]:window:' \
            '--by-close-reason[group by close reason]' \
            '--json[output as JSON]'
          ;;
        fleet-status|fleet)
          _arguments \
            '--json[output as JSON]' \
            '--watch[refresh every 30s]'
          ;;
        mission-grade)
          _arguments '--json[output as JSON]'
          ;;
        *)
          _arguments '*: :{common}'
          ;;
      esac
      ;;
  esac
}}

_chump_gap_ids() {{
  local -a ids
  if command -v chump &>/dev/null; then
    ids=("${{(@f)$(chump gap list --json 2>/dev/null | python3 -c "import sys,json; [print(r['id']) for r in json.load(sys.stdin)]" 2>/dev/null)}}")
    _describe 'gap id' ids
  fi
}}

_chump "$@"
"#,
        top = top,
        gap = gap,
        gap_flags = gap_flags,
        common = common
    )
}

pub fn bash() -> String {
    let top = TOP_LEVEL.join(" ");
    let gap = GAP_SUBS.join(" ");

    format!(
        r#"# EFFECTIVE-010: bash completion for chump
# Install: chump completion bash >> ~/.bashrc   (or source it in your profile)

_chump_complete() {{
  local cur prev words cword
  _init_completion 2>/dev/null || {{
    COMPREPLY=()
    cur="${{COMP_WORDS[COMP_CWORD]}}"
    prev="${{COMP_WORDS[COMP_CWORD-1]}}"
    words=("${{COMP_WORDS[@]}}")
    cword=$COMP_CWORD
  }}

  local top_cmds="{top}"
  local gap_subs="{gap}"

  if [[ $cword -eq 1 ]]; then
    COMPREPLY=($(compgen -W "$top_cmds" -- "$cur"))
    return
  fi

  local cmd="${{words[1]}}"
  case "$cmd" in
    gap)
      if [[ $cword -eq 2 ]]; then
        COMPREPLY=($(compgen -W "$gap_subs" -- "$cur"))
        return
      fi
      local sub="${{words[2]}}"
      case "$sub" in
        show|ship|claim|preflight|decompose)
          # Attempt live completion of gap IDs
          if command -v chump &>/dev/null; then
            local ids
            ids=$(chump gap list --json 2>/dev/null \
              | python3 -c "import sys,json; [print(r['id']) for r in json.load(sys.stdin)]" 2>/dev/null)
            COMPREPLY=($(compgen -W "$ids" -- "$cur"))
          fi
          ;;
        list)
          COMPREPLY=($(compgen -W "--status --domain --priority --effort --json" -- "$cur"))
          ;;
        reserve)
          COMPREPLY=($(compgen -W "--domain --title --priority --effort --force" -- "$cur"))
          ;;
      esac
      ;;
    claim)
      case "$prev" in
        --paths)  COMPREPLY=($(compgen -f -- "$cur")); return ;;
        --session) return ;;
      esac
      COMPREPLY=($(compgen -W "--paths --session --skip-doctor --skip-import --resume" -- "$cur"))
      ;;
    completion)
      COMPREPLY=($(compgen -W "zsh bash fish" -- "$cur"))
      ;;
    health)
      COMPREPLY=($(compgen -W "--json --watch --slo-check" -- "$cur"))
      ;;
    waste-tally)
      COMPREPLY=($(compgen -W "--window --by-close-reason --json" -- "$cur"))
      ;;
    *)
      COMPREPLY=($(compgen -W "--json --help" -- "$cur"))
      ;;
  esac
}}

complete -F _chump_complete chump
"#,
        top = top,
        gap = gap
    )
}

pub fn fish() -> String {
    let mut lines = vec![
        "# EFFECTIVE-010: fish completion for chump".to_string(),
        "# Install: chump completion fish > ~/.config/fish/completions/chump.fish".to_string(),
        String::new(),
        "# Disable file completions for chump by default".to_string(),
        "complete -c chump -f".to_string(),
        String::new(),
    ];

    // Top-level commands
    let top_with_desc: &[(&str, &str)] = &[
        ("claim",         "Atomically claim a gap (worktree + lease + state.db)"),
        ("completion",    "Print shell completion script"),
        ("gap",           "Gap registry commands (list, show, ship, reserve…)"),
        ("health",        "Fleet health score (0-100)"),
        ("fleet-status",  "Active workers and lease state"),
        ("fleet-velocity","Gap throughput over time"),
        ("waste-tally",   "Waste rate by close reason"),
        ("mission-grade", "4-pillar mission grade"),
        ("dispatch",      "Queue and run gap workflows"),
        ("cost",          "Cost summary"),
        ("cost-watch",    "Live cost monitor"),
        ("kpi",           "KPI report"),
        ("roadmap-status","Roadmap drift analysis"),
        ("init",          "Initialize a new chump repo"),
        ("ambient",       "Ambient event stream query"),
        ("lesson-grade",  "Grade lesson application for a gap"),
        ("session-track", "Track agent session metadata"),
        ("session-export","Export session events"),
        ("simulate",      "Simulate gap workflow"),
        ("triage",        "Interactive gap triage"),
        ("plan",          "Planning and decomposition"),
        ("dashboard",     "Interactive fleet dashboard"),
        ("gen",           "Generation utilities"),
        ("help",          "Show help"),
    ];

    for (cmd, desc) in top_with_desc {
        lines.push(format!(
            "complete -c chump -n '__fish_use_subcommand chump' -a {cmd} -d '{desc}'"
        ));
    }

    lines.push(String::new());
    lines.push("# gap subcommands".to_string());
    let gap_subs: &[(&str, &str)] = &[
        ("list",              "List gaps"),
        ("show",              "Show gap details"),
        ("ship",              "Mark gap done + update YAML"),
        ("reserve",           "Reserve a new gap"),
        ("import",            "Import gap YAMLs into state.db"),
        ("claim",             "Claim a gap in state.db"),
        ("preflight",         "Check gap is claimable"),
        ("decompose",         "LLM-decompose gap into sub-gaps"),
        ("audit-priorities",  "PM health audit (P0 count, vague ACs)"),
        ("audit-ac",          "Audit acceptance criteria completeness"),
        ("set",               "Set a gap field"),
        ("edit",              "Edit gap description"),
    ];

    for (sub, desc) in gap_subs {
        lines.push(format!(
            "complete -c chump -n '__fish_seen_subcommand_from gap' -a {sub} -d '{desc}'"
        ));
    }

    lines.push(String::new());
    lines.push("# gap list flags".to_string());
    for flag in &["--status", "--domain", "--priority", "--effort", "--json"] {
        lines.push(format!(
            "complete -c chump -n '__fish_seen_subcommand_from gap' -l {} -d 'gap list filter'",
            flag.trim_start_matches('-')
        ));
    }

    lines.push(String::new());
    lines.push("# claim flags".to_string());
    let claim_flags: &[(&str, &str)] = &[
        ("paths",        "CSV of repo-relative paths"),
        ("session",      "Session ID override"),
        ("skip-doctor",  "Skip doctor probe"),
        ("skip-import",  "Skip state.db import check"),
        ("resume",       "Reset to remote tip if branch exists"),
    ];
    for (flag, desc) in claim_flags {
        lines.push(format!(
            "complete -c chump -n '__fish_seen_subcommand_from claim' -l {flag} -d '{desc}'"
        ));
    }

    lines.push(String::new());
    lines.push("# completion shells".to_string());
    for shell in &["zsh", "bash", "fish"] {
        lines.push(format!(
            "complete -c chump -n '__fish_seen_subcommand_from completion' -a {shell} -d '{shell} completion'"
        ));
    }

    lines.push(String::new());
    lines.push("# health / waste-tally flags".to_string());
    lines.push("complete -c chump -n '__fish_seen_subcommand_from health' -l json -d 'JSON output'".to_string());
    lines.push("complete -c chump -n '__fish_seen_subcommand_from health' -l watch -d 'Refresh every 30s'".to_string());
    lines.push("complete -c chump -n '__fish_seen_subcommand_from health' -l slo-check -d 'Exit non-zero on SLO breach'".to_string());
    lines.push("complete -c chump -n '__fish_seen_subcommand_from waste-tally' -l json -d 'JSON output'".to_string());
    lines.push("complete -c chump -n '__fish_seen_subcommand_from waste-tally' -l by-close-reason -d 'Group by close reason'".to_string());

    lines.join("\n") + "\n"
}
