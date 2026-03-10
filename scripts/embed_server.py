#!/usr/bin/env python3
"""Local embedding server for Chump semantic memory. Uses sentence-transformers (e.g. all-MiniLM-L6-v2).
Run: python scripts/embed_server.py [--port 18765]
Env: CHUMP_EMBED_PORT (default 18765), CHUMP_EMBED_MODEL (default sentence-transformers/all-MiniLM-L6-v2),
     CHUMP_EMBED_MAX_BATCH (default 64) max texts per request to avoid OOM/crashes.
If this process keeps crashing, use in-process embeddings instead: cargo build --features inprocess-embed
and leave CHUMP_EMBED_URL unset (no Python server needed)."""

import argparse
import os
import sys

MAX_BATCH = int(os.environ.get("CHUMP_EMBED_MAX_BATCH", "64"))

def main():
    parser = argparse.ArgumentParser(description="Chump local embedding server")
    parser.add_argument("--port", type=int, default=int(os.environ.get("CHUMP_EMBED_PORT", "18765")))
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()

    try:
        from sentence_transformers import SentenceTransformer
    except ImportError:
        print("Install: pip install sentence-transformers", file=sys.stderr)
        sys.exit(1)

    try:
        from fastapi import FastAPI
        from fastapi.responses import JSONResponse
        from pydantic import BaseModel
        import uvicorn
    except ImportError:
        print("Install: pip install fastapi uvicorn pydantic", file=sys.stderr)
        sys.exit(1)

    model_name = os.environ.get("CHUMP_EMBED_MODEL", "sentence-transformers/all-MiniLM-L6-v2")
    print(f"Loading model {model_name}...", flush=True)
    model = SentenceTransformer(model_name)
    print("Model loaded.", flush=True)

    app = FastAPI(title="Chump Embed")

    class EmbedRequest(BaseModel):
        text: str | None = None
        texts: list[str] | None = None

    @app.get("/health")
    def health():
        return {"status": "ok"}

    @app.post("/embed")
    def embed(req: EmbedRequest):
        if req.text is not None:
            texts = [req.text]
        elif req.texts is not None and len(req.texts) > 0:
            texts = req.texts[:MAX_BATCH]
        else:
            return JSONResponse(
                status_code=400,
                content={"error": "Provide 'text' or 'texts'"},
            )
        vecs = model.encode(texts, convert_to_numpy=True)
        if len(texts) == 1:
            return {"vector": vecs[0].tolist()}
        return {"vectors": [v.tolist() for v in vecs]}

    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
