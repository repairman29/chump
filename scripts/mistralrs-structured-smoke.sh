#!/usr/bin/env bash
# Optional operator checklist: JSON-schema constrained assistant text (in-process mistral).
# No model download here — only documents steps and runs compile-only tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== mistral.rs structured output (tool-free completions) ==="
echo ""
echo "1. Build: cargo build --release --features mistralrs-infer  (or mistralrs-metal on Apple Silicon)"
echo "2. Create a JSON Schema file (root = schema object), e.g. brain/tmp/pilot-object.schema.json"
echo "3. Set: export CHUMP_MISTRALRS_OUTPUT_JSON_SCHEMA=\"\$PWD/brain/tmp/pilot-object.schema.json\""
echo "4. Set CHUMP_INFERENCE_BACKEND=mistralrs + CHUMP_MISTRALRS_MODEL per docs/INFERENCE_PROFILES.md §2b"
echo "5. Run a tool-FREE turn (e.g. CLI one-shot or a chat path with no tools) asking for JSON matching the schema."
echo "6. Expect model-dependent: assistant content parses as JSON valid under the schema."
echo ""
echo "Note: turns that register tools skip this constraint (see docs/ADR-002-mistralrs-structured-output-spike.md)."
echo ""
echo "=== Compile + unit tests (mistralrs_provider) ==="
exec ./scripts/check-mistralrs-infer-build.sh
