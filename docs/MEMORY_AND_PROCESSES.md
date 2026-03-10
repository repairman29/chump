# Why memory gets eaten so fast (and what to do)

On Apple Silicon, **CPU and GPU share the same RAM** (unified memory). When you “shut down” an app, macOS often keeps some of that memory in cache or in background processes, so free memory doesn’t jump back immediately. Plus several Chump-related processes can each use a lot.

## Is 30B too big for this machine?

**Check unified memory (Apple Silicon):**

```bash
system_profiler SPHardwareDataType | grep "Memory:"
```

- **8 GB:** 30B (~17 GB model + KV cache) will not fit. Use the **7B** model: `export VLLM_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit` then `./serve-vllm-mlx.sh`.
- **16 GB:** 30B can load but is tight; Cursor, browser, or large context often trigger Metal OOM. vllm-mlx does not support context-length limits; quit other apps or switch to 7B as above.
- **24 GB+:** 30B is viable; keep other heavy apps (and 8001/embed) minimal when using 30B. Note: vllm-mlx does not support `VLLM_MAX_MODEL_LEN`; if 30B still OOMs, quit Cursor/browsers and retry, or use 7B.

**Quick switch to 7B (one terminal):**

```bash
cd rust-agent
export VLLM_MODEL=mlx-community/Qwen2.5-7B-Instruct-4bit
./serve-vllm-mlx.sh
```

Chump will use ~4.5 GB; quality is lower than 30B but stable on 8–16 GB Macs.

## What uses memory in this stack

| Process                         | Typical use  | How to stop                                                                       |
| ------------------------------- | ------------ | --------------------------------------------------------------------------------- |
| **vLLM-MLX (30B on 8000)**      | ~17 GB       | Kill the process on port 8000, or stop the terminal running `./serve-vllm-mlx.sh` |
| **vLLM-MLX (7B on 8001)**       | ~4.5 GB      | Kill the process on port 8001, or Chump Menu → Stop vLLM (8001)                   |
| **Python embed server (18765)** | ~400 MB–1 GB | `pkill -f embed_server.py` or Chump Menu → Stop embed server                      |
| **Chump Discord bot**           | &lt;100 MB   | `pkill -f 'rust-agent.*--discord'` or Chump Menu → Stop Chump                     |
| **OpenClaw gateway**            | Varies       | Quit the OpenClaw app or stop the gateway process                                 |

So **30B + 7B + embed + everything else** can be 22+ GB. Shutting down “programs” in the UI may not kill the **model servers** (vLLM) or the **embed server** if they were started in a terminal or by a script.

## See what’s using memory

**Terminal (biggest users first):**

```bash
# RSS (resident memory) by process, top 15
ps aux --sort=-rss | head -16

# Or on macOS:
ps -eo pid,rss,comm | sort -k2 -rn | head -20
```

**By port (is something still on 8000/8001?):**

```bash
lsof -i :8000
lsof -i :8001
lsof -i :18765
```

**System memory summary (macOS):**

```bash
vm_stat
```

## Free memory in this stack

1. **Stop the model servers** (biggest gain):

   ```bash
   lsof -ti :8000 | xargs kill
   lsof -ti :8001 | xargs kill
   ```

   Or close the terminal(s) that are running `serve-vllm-mlx.sh` / `serve-vllm-mlx-8001.sh`.

2. **Stop the embed server** (if you run it):

   ```bash
   pkill -f embed_server.py
   ```

   Or use Chump Menu → Stop embed server.

3. **Stop the Discord bot** (small):

   ```bash
   pkill -f 'rust-agent.*--discord'
   ```

4. **macOS cache** – Memory may stay in “cached” for a while. Restarting the Mac frees it; otherwise avoid running 30B+7B at once so you don’t need to chase every byte.

## Why it feels like memory is “eaten” so fast

- **Unified memory:** GPU (Metal/MLX) and CPU share RAM. Loading the 30B model allocates a big chunk; when you quit, the OS may keep some of it as cache instead of returning it to “free” right away.
- **Multiple heavy processes:** If 8000 and 8001 and the embed server were all running, that’s 22+ GB. Closing one app (e.g. a browser) doesn’t stop those; you have to kill the right processes (see above).
- **Caching:** macOS uses free RAM for file and other caches. “Inactive” or “cached” memory is reclaimed when apps need it, but Activity Monitor may still show most RAM as “used.”

**Practical approach:** Run **only 8000 (30B)** when you need Chump; don’t start 8001 or the Python embed server unless you need them. Use in-process embeddings (`cargo build --features inprocess-embed`) to avoid the separate Python embed process. After a session, kill the vLLM process on 8000 so that ~17 GB is released.

## What the logs show when memory pressure hits

Reviewing `rust-agent/logs/` explains many "connection closed" or "Connection refused" failures during heartbeat or tests.

### 1. vLLM on 8000 dies mid-request (Metal OOM)

**Log:** `vllm-8000.log` (or whatever captures the 8000 server's stdout)

**Typical line:**

```text
libc++abi: terminating due to uncaught exception of type std::runtime_error: [METAL] Command buffer execution failed: Insufficient Memory (kIOGPUCommandBufferCallbackErrorOutOfMemory)
```

**Cause:** A single request had a very large context (e.g. 68k+ characters, many conversation turns). The 30B model's KV cache plus that context pushes Metal over the limit; the process exits, so the client sees "connection closed before message completed".

**Heartbeat:** Each round sends a long conversation (system + many user/assistant turns). That context size plus 30B inference is enough to trigger Metal OOM when the machine is already under memory pressure (e.g. Cursor + cargo + tests).

**Mitigations:**

- Run heartbeat (and heavy Chump use) when nothing else heavy is running (e.g. no parallel `cargo test` or big IDE).
- Lower vLLM context so the KV cache is smaller: e.g. in `serve-vllm-mlx.sh` or env: `export VLLM_MAX_MODEL_LEN=8192` (or 4096) then restart the server.
- Use the 7B model on 8001 for heartbeat instead of 30B if you have 8001 running; 7B uses less memory per request.

### 2. warm-the-ovens fails with "empty array" (no Metal device)

**Log:** `warm-ovens.log`

**Typical line:**

```text
*** Terminating app due to uncaught exception 'NSRangeException', reason: '*** -[__NSArray0 objectAtIndex:]: index 0 beyond bounds for empty array'
```

Stack shows `libmlx.dylib` → `mlx.core.metal.Device` / `MetalAllocator`.

**Cause:** MLX is enumerating Metal devices and gets an empty list. That can happen when the GPU is already fully held by another process (e.g. Cursor, a previous vLLM, or another ML app), or when the system is under such memory pressure that Metal can't hand out a device. The script then sees "Abort trap: 6" and "Timeout waiting for port 8000", and may fall back to 8001.

**Mitigations:**

- Don't rely on warm-the-ovens when 8000 is down if Cursor (or other heavy GPU apps) are running; start 8000 manually when the machine is idle.
- Free memory and GPU by killing other consumers (see "Free memory in this stack" above), then try starting 8000 again.

### 3. Heartbeat log: "connection closed" then "Connection refused"

**Log:** `heartbeat-learn.log`

**Pattern:** Round 1 (or N): "connection closed before message completed". Later rounds: "Connection refused (os error 61)".

**Interpretation:** The first error usually means vLLM crashed during that request (often Metal OOM as in (1)). After that, the server is gone, so subsequent requests get "Connection refused". Preflight may then try warm-the-ovens and hit (2) if the machine is still under pressure.
