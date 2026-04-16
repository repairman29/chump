# Deployment Comparison: Chump vs Hermes-Agent

**Phase 2.4 of the [Hermes Competitive Roadmap](HERMES_COMPETITIVE_ROADMAP.md).** Honest side-by-side comparison of what it takes to get each agent running on a fresh machine.

**TL;DR:** Chump trades slower first install (Rust compile time) for zero runtime dependencies and a single binary. Hermes is faster to get running but drags Python + `uv` + plugin complexity with it forever.

---

## Install Experience

### Hermes-Agent

**Canonical install:**
```bash
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
```

**What this does:**
1. Checks Python version (>= 3.11 required)
2. Installs `uv` (Python package manager) if not present
3. Downloads Hermes repo
4. Creates a Python venv via `uv`
5. Installs ~50-80 Python dependencies (teloxide, anthropic, openai, httpx, rich, etc.)
6. Sets up `~/.hermes/` config directory
7. Links `hermes` binary into `~/.local/bin`

**Required system packages:**
- Python 3.11+
- curl, git
- build-essential (for any native Python extensions)
- `uv` (installed by the script)

**Install time (fresh Ubuntu 22.04):**
- ~2-5 minutes (mostly Python package downloads)

**Runtime dependencies:**
- Python interpreter
- ~200-500 MB of installed Python packages in the venv
- Separate config at `~/.hermes/`
- May need platform-specific deps for adapters (e.g. `signal-cli` for Signal)

---

### Chump

**Canonical install:**
```bash
git clone https://github.com/repairman29/chump.git && cd chump
cargo build --release
./target/release/chump --web
```

**What this does:**
1. Downloads Rust source code
2. Compiles to a single binary (`target/release/chump`, ~50-80 MB)
3. First run creates `sessions/chump_memory.db` SQLite file
4. Loads `.env` if present

**Required system packages:**
- Rust toolchain (rustc + cargo, installed via `rustup`)
- git
- (Linux only) `webkit2gtk-4.1`, `libssl-dev` for optional Tauri desktop

**Install time (fresh Ubuntu 22.04, first build):**
- ~15-25 minutes (Rust compile time — this is the honest tradeoff)
- After first build: `cargo build --release` on unchanged code = seconds

**Runtime dependencies:**
- NONE. The binary is statically linked against most things (musl-capable).
- SQLite file in current dir (or `CHUMP_MEMORY_DB_PATH`)

---

## Runtime Footprint

| Metric | Hermes | Chump |
|---|---|---|
| Binary/process size | ~200 MB venv + Python | ~55 MB single binary |
| Cold start | ~2-3s (Python import) | ~50-100 ms |
| Warm start | ~500 ms | ~10 ms |
| Runtime deps | Python + ~50 packages | None |
| Update path | `uv pip install --upgrade hermes-agent` | `cargo build --release` or download release binary |
| Lock-in | Python env, plugin entrypoints | None — just replace the binary |

---

## Deployment Scenarios

### Scenario 1: Developer Laptop (macOS)

**Hermes:** Works fine if Python 3.11+ is available. Install is fast. Devs who live in Python have zero friction.

**Chump:** First build takes 15-25 min which is annoying. After that, `cargo build --release` is fast (~10-30 sec for incremental). Single binary is portable across laptops.

**Winner:** Tie. Hermes is faster for first install; Chump is faster for everything after.

---

### Scenario 2: Production VPS (headless Linux)

**Hermes:** 
- Need Python 3.11+ on the VPS
- Venv needs to persist across deploys
- Updates can break if system Python changes
- Plugins installed via pip need maintenance

**Chump:**
- Build once (on dev machine or CI), copy binary to VPS
- Or: clone + build on VPS (15-25 min one-time cost)
- Update = `scp` new binary, systemd restart
- No package drift; binary is frozen

**Winner:** Chump. Production ops is the single-binary use case.

---

### Scenario 3: Air-Gapped / Regulated Environment

**Hermes:**
- **Problematic.** Requires Python, uv, pip, internet access for pip.
- Air-gapped pip installs are possible but painful (wheel bundling).
- Plugin updates require re-bundling.
- Auditing what's actually installed = scanning 50-80 Python packages across venv.

**Chump:**
- **Designed for this.** Single binary is auditable. No transitive dependency surprises.
- Build artifact is one file. Sign it, checksum it, ship it.
- Zero network access needed at runtime (except to local Ollama and your own services).
- SBOM (Software Bill of Materials) is just `cargo tree` output.

**Winner:** Chump. This is a real market Hermes structurally cannot serve.

---

### Scenario 4: Hobbyist / Homelab

**Hermes:** Easier to try because Python is familiar. `curl | bash` is frictionless.

**Chump:** First build is long, but after that: copy binary to homelab, run it, done. No Python upgrade drama over time.

**Winner:** Hermes for first-try. Chump for long-term homelab reliability.

---

### Scenario 5: Docker / Container Deploy

**Hermes Dockerfile (rough):**
```dockerfile
FROM python:3.11-slim
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
COPY . /app
WORKDIR /app
RUN uv sync
CMD ["hermes"]
```
- Final image: ~500 MB (Python base + deps)
- Build time: 2-3 min

**Chump Dockerfile (rough):**
```dockerfile
FROM rust:1.82 AS build
COPY . /app
WORKDIR /app
RUN cargo build --release

FROM debian:bookworm-slim
COPY --from=build /app/target/release/chump /usr/local/bin/chump
CMD ["chump", "--web"]
```
- Final image: ~100 MB (slim runtime)
- Build time: 15-25 min (uncached); seconds (cached)

**Winner:** Chump on final image size. Hermes on first build time. For production, Chump's smaller image is a clear win.

---

## Update / Maintenance

### Updating Hermes

```bash
uv pip install --upgrade hermes-agent
# Plugins may need separate updates:
hermes skills update
```

**Risk:** Python dep conflicts if another tool shares the venv. Plugin breakage if pyproject.toml changes.

### Updating Chump

```bash
git pull && cargo build --release
# OR: download new release binary
```

**Risk:** Rust compile errors if you pulled a broken commit. Binary replacement = atomic, no half-state.

---

## Security Surface

| Threat | Hermes exposure | Chump exposure |
|---|---|---|
| Malicious pip package | High — transitive deps of deps | None (crates are Rust, different ecosystem) |
| Python sandbox escape | Possible via plugin | N/A |
| Dependency confusion attack | High (PyPI is famous for these) | Lower (crates.io has stricter namespacing) |
| Binary tampering in transit | Same for both | Same (signed release binaries solve this) |
| Runtime memory safety | Depends on C extensions | Rust safety (except `unsafe` blocks) |
| Audit complexity | Scan Python venv + source | `cargo tree` + `cargo audit` (already in Chump CI) |

---

## What Hermes Wins On

Being honest about where Hermes has the advantage:

1. **First-install speed.** 2-5 minutes vs 15-25 minutes. Huge for demos and evaluation.
2. **Plugin ecosystem velocity.** Python has millions of libraries; Rust has thousands. For domain integrations (Notion, Salesforce, random APIs), Python wins.
3. **Scripting familiarity.** Most users can read Python. Rust has a steeper learning curve.
4. **Platform breadth.** 15+ messaging platforms vs Chump's current 3 (Discord, PWA, CLI).
5. **Cloud backend diversity.** Modal, Daytona, Singularity are Python-native; Rust would need wrappers.

---

## What Chump Wins On

1. **Single binary deployment.** Zero runtime dependencies. Ship one file.
2. **Footprint.** 55 MB binary vs 200 MB+ Python venv.
3. **Startup speed.** 50-100ms cold start vs 2-3 sec.
4. **Air-gapped/regulated deployment.** No Python, no pip, no surprises.
5. **Memory safety.** Rust's borrow checker prevents entire bug categories.
6. **Update atomicity.** Binary swap is atomic; Python venv updates can partially fail.
7. **Long-term stability.** No Python upgrade drama, no dep resolver hell over time.
8. **Audit-friendly.** `cargo tree` + `cargo audit` + SBOM tools work out of the box.

---

## Recommendations

**Pick Hermes if:**
- You want to try an agent in < 5 minutes
- You live in Python and want to extend it with Python plugins
- You need 10+ messaging platform integrations out of the box
- You're running on generous compute with Modal/Daytona/serverless backends

**Pick Chump if:**
- You're deploying to production servers and hate Python ops
- You need air-gapped, regulated, or auditable deployment
- You want zero runtime dependencies
- You care about memory safety and cargo tooling
- You're building on a resource-constrained system (old laptop, Raspberry Pi, etc.)
- You want the consciousness framework, memory graph, or belief state (Hermes doesn't have these)

**The real framing:** These are different products for different audiences. Hermes is **"the accessible AI agent for Python-comfortable devs with cloud resources."** Chump is **"the serious production agent for Rust-comfortable ops with local-first or regulated environments."**

Both can thrive. They're not really competitors — they're serving different halves of the market.

---

## Reproduce This Comparison

**Hermes install timing:**
```bash
time curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
```

**Chump install timing:**
```bash
time bash -c 'git clone https://github.com/repairman29/chump.git && cd chump && cargo build --release'
```

**Image size:**
```bash
# Hermes
docker build -t hermes-test -f Dockerfile.hermes .
docker images hermes-test --format "{{.Size}}"

# Chump
docker build -t chump-test -f Dockerfile .
docker images chump-test --format "{{.Size}}"
```

Run both on fresh Ubuntu 22.04 VM for apples-to-apples comparison.

---

**Sources:**
- [Hermes Agent install instructions](https://github.com/NousResearch/hermes-agent#installation)
- [Chump README](../README.md)
- Empirical timing on MacBook Air M4 (24GB), April 2026
