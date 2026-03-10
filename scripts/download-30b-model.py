#!/usr/bin/env python3
"""Download the full Qwen3-30B-A3B-4bit-DWQ model (missing shards) to HF cache.
   Set HF_TOKEN for faster downloads (higher rate limits): HF_TOKEN=hf_xxx python download-30b-model.py"""
import os
from huggingface_hub import snapshot_download

token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN")
print("Downloading mlx-community/Qwen3-30B-A3B-4bit-DWQ (first run may take a while)...")
snapshot_download("mlx-community/Qwen3-30B-A3B-4bit-DWQ", local_files_only=False, token=token)
print("Done.")
