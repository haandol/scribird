#!/bin/bash
# Run locked Python suites; unit tests mock model and AWS calls.
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

uv run --project mcp --frozen python -m unittest discover -s mcp/tests -v
uv run --project mcp --frozen python -m unittest discover \
    -s plugin/scribird-diarize/skills/multi-speaker-diarize/tests -v

# Keep this lightweight environment separate from the full local inference runtime.
UV_PROJECT_ENVIRONMENT="$project_root/build/qwen-test-venv" HF_HUB_OFFLINE=1 \
    uv run --project runtime/qwen --frozen --only-group test \
    python -m unittest discover -s runtime/qwen/tests -v
