# Security

## Reporting a vulnerability

Please **do not** open a public GitHub issue for undisclosed security problems.

1. **Preferred:** Use [GitHub private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability) for this repository (if enabled by maintainers).
2. **Otherwise:** Contact the repository maintainers through a private channel you already use for this project.

Include: affected version/commit, reproduction steps, and impact (confidentiality / integrity / availability) if you can.

## Scope notes

Chump is **self-hosted**: inference keys, Discord tokens, and `.env` live on your machine. Keep `.env` out of git (see `.gitignore` and `.env.example`). Review [docs/OPERATIONS.md](docs/OPERATIONS.md) for tool approvals and `run_cli` policy.
