use repo_sentinel::{
    harden_repo, render_harden_json, render_harden_summary, render_portfolio_json,
    render_portfolio_markdown, render_portfolio_summary, render_scan_json, render_scan_markdown,
    render_scan_summary, scan_portfolio, scan_repo, Severity,
};
use std::env;
use std::path::Path;
use std::process;

fn print_help() {
    println!("Usage: repo-sentinel [COMMAND] [OPTIONS]");
    println!();
    println!("Commands:");
    println!("  scan       Scan a single repository");
    println!("  portfolio  Scan a portfolio of repositories");
    println!("  harden     Harden a repository");
    println!("  help       Print this help message");
    println!("  version    Print version information");
    println!();
    println!("Options:");
    println!("  --help, -h  Print help information");
    println!("  --version, -V  Print version information");
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() {
        print_help();
        return;
    }

    match args[0].as_str() {
        "--help" | "-h" | "help" => {
            print_help();
        }
        "--version" | "-V" => {
            println!("repo-sentinel 0.1.0");
        }
        "scan" => {
            let mut path = String::from(".");
            let mut staged = false;
            let mut json = false;
            let mut markdown = false;
            let mut fail_on = Severity::High;

            let mut i = 1;
            while i < args.len() {
                match args[i].as_str() {
                    "--path" => {
                        if i + 1 < args.len() {
                            path = args[i + 1].clone();
                            i += 1;
                        } else {
                            eprintln!("Missing value for --path");
                            process::exit(2);
                        }
                    }
                    "--staged" => {
                        staged = true;
                    }
                    other if !other.starts_with("-") => {
                        path = other.to_string();
                    }
                    "--json" => {
                        json = true;
                    }
                    "--markdown" => {
                        markdown = true;
                    }
                    "--fail-on" => {
                        if i + 1 < args.len() {
                            fail_on = match args[i + 1].as_str() {
                                "low" => Severity::Low,
                                "medium" => Severity::Medium,
                                "high" => Severity::High,
                                "critical" => Severity::Critical,
                                _ => {
                                    eprintln!("Invalid severity level: {}", args[i + 1]);
                                    process::exit(2);
                                }
                            };
                            i += 1;
                        } else {
                            eprintln!("Missing value for --fail-on");
                            process::exit(2);
                        }
                    }
                    _ => {
                        eprintln!("Unknown option: {}", args[i]);
                        print_help();
                        process::exit(2);
                    }
                }
                i += 1;
            }

            let report = match scan_repo(Path::new(&path), staged, fail_on) {
                Ok(report) => report,
                Err(e) => {
                    eprintln!("Error scanning repository: {}", e);
                    process::exit(1);
                }
            };

            if json {
                println!("{}", render_scan_json(&report));
            } else if markdown {
                println!("{}", render_scan_markdown(&report));
            } else {
                println!("{}", render_scan_summary(&report));
            }

            if !report.passed_gate {
                process::exit(1);
            }
        }
        "portfolio" => {
            if args.len() < 2 {
                eprintln!("Missing directory path");
                print_help();
                process::exit(2);
            }

            let dir = args[1].clone();
            let mut max_repos: usize = 50;
            let mut json = false;
            let mut markdown = false;
            let mut fail_on = Severity::High;

            let mut i = 2;
            while i < args.len() {
                match args[i].as_str() {
                    "--max-repos" => {
                        if i + 1 < args.len() {
                            max_repos = match args[i + 1].parse() {
                                Ok(n) => n,
                                Err(_) => {
                                    eprintln!("Invalid number: {}", args[i + 1]);
                                    process::exit(2);
                                }
                            };
                            i += 1;
                        } else {
                            eprintln!("Missing value for --max-repos");
                            process::exit(2);
                        }
                    }
                    "--json" => {
                        json = true;
                    }
                    "--markdown" => {
                        markdown = true;
                    }
                    "--fail-on" => {
                        if i + 1 < args.len() {
                            fail_on = match args[i + 1].as_str() {
                                "low" => Severity::Low,
                                "medium" => Severity::Medium,
                                "high" => Severity::High,
                                "critical" => Severity::Critical,
                                _ => {
                                    eprintln!("Invalid severity level: {}", args[i + 1]);
                                    process::exit(2);
                                }
                            };
                            i += 1;
                        } else {
                            eprintln!("Missing value for --fail-on");
                            process::exit(2);
                        }
                    }
                    _ => {
                        eprintln!("Unknown option: {}", args[i]);
                        print_help();
                        process::exit(2);
                    }
                }
                i += 1;
            }

            let report = match scan_portfolio(Path::new(&dir), max_repos, fail_on) {
                Ok(report) => report,
                Err(e) => {
                    eprintln!("Error scanning portfolio: {}", e);
                    process::exit(1);
                }
            };

            if json {
                println!("{}", render_portfolio_json(&report));
            } else if markdown {
                println!("{}", render_portfolio_markdown(&report));
            } else {
                println!("{}", render_portfolio_summary(&report));
            }

            if report.at_risk_repos > 0 {
                process::exit(1);
            }
        }
        "harden" => {
            let mut path = String::from(".");
            let mut dry_run = false;
            let mut apply = false;
            let mut install_hook = false;
            let mut json = false;

            let mut i = 1;
            while i < args.len() {
                match args[i].as_str() {
                    "--path" => {
                        if i + 1 < args.len() {
                            path = args[i + 1].clone();
                            i += 1;
                        } else {
                            eprintln!("Missing value for --path");
                            process::exit(2);
                        }
                    }
                    "--dry-run" => {
                        dry_run = true;
                    }
                    "--apply" => {
                        apply = true;
                    }
                    "--install-hook" => {
                        install_hook = true;
                    }
                    other if !other.starts_with("-") => {
                        path = other.to_string();
                    }
                    "--json" => {
                        json = true;
                    }
                    _ => {
                        eprintln!("Unknown option: {}", args[i]);
                        print_help();
                        process::exit(2);
                    }
                }
                i += 1;
            }

            if dry_run && apply {
                eprintln!("Cannot specify both --dry-run and --apply");
                process::exit(2);
            }

            let res = match harden_repo(Path::new(&path), apply, install_hook) {
                Ok(res) => res,
                Err(e) => {
                    eprintln!("Error hardening repository: {}", e);
                    process::exit(1);
                }
            };

            if json {
                println!("{}", render_harden_json(&res));
            } else {
                println!("{}", render_harden_summary(&res));
            }
        }
        other => {
            eprintln!("Unknown command: {}", other);
            print_help();
            process::exit(2);
        }
    }
}
