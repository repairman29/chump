# WASM tools (Phase 2)

Chump can run sandboxed tools as WebAssembly (WASI) modules via the **wasmtime** CLI. No filesystem or network is granted by default.

## wasm_calc

A safe calculator that runs in WASM. The model can call it with an `expression` (e.g. `"2 + 3"` or `"10 / 2"`). Input is passed on stdin, result on stdout.

**Requirements:**

- **wasmtime** on PATH (e.g. `brew install wasmtime`).
- The module `wasm/calculator.wasm` must exist.

**Building the calculator WASM:**

```bash
cd rust-agent/wasm/calc-wasm
rustup target add wasm32-wasi
cargo build --release --target wasm32-wasi --bin calc-wasm
cp target/wasm32-wasi/release/calc_wasm.wasm ../calculator.wasm
```

(Artifact name is `calc_wasm.wasm`.)

From the `rust-agent` directory you can run:

```bash
mkdir -p wasm
cd wasm/calc-wasm && cargo build --release --target wasm32-wasi --bin calc-wasm && cp target/wasm32-wasi/release/calc_wasm.wasm ../calculator.wasm && cd ../..
```

If `wasmtime` is installed and `wasm/calculator.wasm` is present, Chump will register the `wasm_calc` tool. Otherwise the tool is not advertised and the existing `calculator` tool (host) is used.

## Runner behavior

The runner (`src/wasm_runner.rs`) runs:

```bash
wasmtime run --disable-cache <path-to-wasm>
```

Stdin is fed the tool input (e.g. the expression plus newline); stdout and stderr are captured and returned. No preopened directories, env, or network are passed.

## Adding more WASM tools

1. Build a WASI module that reads from stdin and writes to stdout (or use a fixed JSON/text protocol).
2. Place the `.wasm` file under `wasm/` (e.g. `wasm/readonly_reader.wasm`).
3. Add a new tool in `src/` that calls `wasm_runner::run_wasm_wasi(&path, stdin_bytes).await` and parses the result.
4. Register the tool when the module path exists (and optionally when wasmtime is available).

This complements `run_cli`: use WASM tools for narrow, safe operations; use `run_cli` when the user explicitly requests host commands.
