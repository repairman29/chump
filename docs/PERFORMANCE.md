# Performance and Profiling

This document describes how to profile and optimize the Chump Rust binary, and summarizes allocation-reduction work in critical paths.

## Profiling tools

### 1. rust-analyzer (IDE)

- Use **rust-analyzer** in Cursor/VS Code for inline diagnostics and “run” lenses.
- No extra setup; ensure the Rust extension is enabled for type info and hot-path awareness.

### 2. Cargo Profiler (Linux + Valgrind)

For instruction and cache profiling on Linux:

```bash
cargo install cargo-profiler
# Valgrind required: e.g. apt install valgrind / brew install valgrind (Linux only)

# Instruction-level profiling (release build)
cargo profiler callgrind --release

# Cache analysis
cargo profiler cachegrind --release

# Top 15 functions by instruction count
cargo profiler callgrind --release -n 15

# Pass args to the binary (e.g. --discord)
cargo profiler callgrind --release -- --discord
```

### 3. Flamegraph (cross-platform)

For CPU flame graphs:

```bash
cargo install flamegraph

# Requires debug symbols; use release profile with debug = true (see Cargo.toml)
cargo flamegraph --release
# Or with release-with-debug for richer symbols
cargo flamegraph --profile release-with-debug
```

### 4. Heap / memory profiling (dhat-rs)

To find allocation bottlenecks, use the optional **dhat-heap** feature:

```bash
# Run with heap profiling enabled (writes dhat.out.* when the process exits)
cargo run --release --features dhat-heap -- --chump
# Or: -- --discord
```

- On exit, the process prints heap stats and writes `dhat.out.*` files.
- Use [dhat-viewer](https://github.com/nnethercote/dhat-rs#viewing) or the [DHAT viewer](https://valgrind.org/docs/manual/dh-manual.html) to inspect where allocations occur.

## Cargo profiles

- **`release`**: `opt-level=3`, `debug=true` (for profiling), `lto="thin"`, `codegen-units=1`.
- **`release-with-debug`**: Same as `release` with full debug info and no strip, for best profiler backtraces.

## Optimizations applied

### Context assembly (`src/context_assembly.rs`)

- **`assemble_context()`**: Pre-allocates a single `String` with capacity 4096 and uses `std::fmt::Write` / `write!` / `writeln!` to build the context block in place, avoiding many intermediate `format!` and `push_str(&format!(...))` allocations in this hot path.

### Logging (`src/chump_log.rs`)

- **`redact()`**: Single-pass redaction. Collects secret env values once, then scans the input once and builds one output `String` (or returns the input as-is when no secrets are present), instead of multiple `replace()` calls that each reallocate.
- **`log_adb()`**: Calls `get_request_id()` once and reuses the value for both structured and plain log branches, avoiding duplicate clones.

### Memory profiling

- **dhat-heap feature**: Optional global allocator and heap profiler (see above). Use `cargo run --release --features dhat-heap` to identify allocation hotspots.

## Finding bottlenecks

1. **CPU**: Use `cargo flamegraph` or `cargo profiler callgrind` on a representative workload (e.g. one `--chump` turn or Discord message).
2. **Allocations**: Run with `--features dhat-heap`, capture a short run, then inspect `dhat.out.*` to see which call sites allocate the most.
3. **Critical sections**: Main allocation-heavy paths are context assembly (every turn) and logging (every message/reply/tool call). These have been optimized as above; profile again after changes to confirm no regressions.
