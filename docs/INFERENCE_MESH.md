# Inference mesh

Optional third node: use an **iPhone inference server** (e.g. inferrlm on Tailscale) alongside Mac (vLLM-MLX :8000) and Pixel (llama-server :8000) to improve resilience and offload work.

## Nodes

| Node | Address | Role |
|------|---------|------|
| **Mac** | localhost:8000 (vLLM-MLX) | Chump primary; optional Mabel heavy (Pixel → Mac Tailscale IP:8000). |
| **Pixel** | 127.0.0.1:8000 (llama-server) | Mabel local; patrol/intel/verify/peer_sync. |
| **iPhone** | Tailscale IP:8889 (e.g. 10.1.10.175:8889) | Optional: fallback, delegate worker, or Mabel heavy. Replace IP if Tailscale changes. |

The iPhone must serve an **OpenAI-compatible API** (e.g. `/v1/chat/completions`, `/v1/models`). Tailscale makes it reachable from Mac and Pixel.

## Using the iPhone node

No code changes are required; set env vars only.

### Mac (Chump) `.env`

| Env | Value | Effect |
|-----|--------|--------|
| **CHUMP_FALLBACK_API_BASE** | `http://10.1.10.175:8889/v1` | When Mac 8000 fails or times out, one attempt goes to iPhone. |
| **CHUMP_WORKER_API_BASE** | `http://10.1.10.175:8889/v1` | Delegate (summarize/extract) and diff_review run on the iPhone. Requires `CHUMP_DELEGATE=1`. |
| **OPENAI_API_BASE** | `http://10.1.10.175:8889/v1` | All Chump inference on iPhone; Mac runs no model. Use only if iPhone is primary. |

If the iPhone server uses a different model id, set **OPENAI_MODEL** or **CHUMP_WORKER_MODEL** to that id where the iPhone is used.

### Pixel (Mabel) `~/chump/.env`

| Env | Value | Effect |
|-----|--------|--------|
| **MABEL_HEAVY_MODEL_BASE** | `http://10.1.10.175:8889/v1` | Research/report rounds use the iPhone instead of Mac 14B. Frees Mac GPU. |

## Suggested setup

- **Start:** Mac fallback and/or delegate worker (env on Mac only).
- **Then:** If the iPhone model is good, set **MABEL_HEAVY_MODEL_BASE** on the Pixel to the iPhone URL so research/report use the mesh node.

## Check mesh

From the Chump repo on the Mac, run:

```bash
./scripts/check-inference-mesh.sh
```

This curls each node’s `/v1/models` (and optionally Pixel via SSH) and prints which are up. Useful after a network swap.

## See also

- [NETWORK_SWAP.md](NETWORK_SWAP.md) — Mac/Pixel IPs after a network change.
- [ANDROID_COMPANION.md](ANDROID_COMPANION.md#hybrid-inference) — Hybrid inference (Mabel heavy) from Pixel.
- [OPERATIONS.md](OPERATIONS.md) — OPENAI_API_BASE, CHUMP_FALLBACK_API_BASE, CHUMP_WORKER_API_BASE.
