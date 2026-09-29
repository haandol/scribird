# Qwen3 runtime

This worker runs **Alkd/Qwen3-ASR-1.7B-MLX-8bit** locally on Apple Silicon.
The model revision is pinned to `b85224831c8109b261947e4c6daf5e89823f9c76`;
the Python/MLX dependencies are pinned by `uv.lock`. It is an optional engine for
file transcription and live meeting recording. Live recording uses one persistent
worker per source so microphone and system audio never share recognition context.

The app bundles the worker, project/lock files, and feature-extractor configuration.
On first use it uses `uv` to prepare Python 3.12 under
`~/Library/Application Support/Scribird/QwenRuntime/0.1.0`. Subsequent calls run that
Python directly. `SCRIBIRD_UV_EXECUTABLE` overrides uv discovery, and
`SCRIBIRD_QWEN_PYTHON` can point to an already prepared interpreter.

Managed first-use preparation holds an exclusive local file lock. Concurrent
requests reuse the completed environment, and interrupted or incomplete setup
does not create the readiness marker. A ready environment works even if `uv` is
subsequently unavailable.

Hugging Face downloads the pinned model into its normal local cache, then the
worker creates a local view under `~/Library/Application Support/Scribird/Qwen3/`
without modifying the weights. Complete cached files are used without a Hub lookup.
`HF_HUB_OFFLINE=1` enforces offline inference and errors if files are absent. No
audio, transcript or usage telemetry is sent to Hugging Face.

The [conversion's model card](https://huggingface.co/Alkd/Qwen3-ASR-1.7B-MLX-8bit)
describes an Apache-2.0 MLX 8-bit model, approximately 2.3 GB. Its snapshot lacks a
feature-extractor configuration. `preprocessor_config.json` preserves the values
from the [official Qwen3-ASR-1.7B configuration](https://huggingface.co/Qwen/Qwen3-ASR-1.7B/blob/main/preprocessor_config.json)
read on 2026-09-28. Inference uses
[mlx-audio's Qwen3 implementation](https://github.com/Blaizzy/mlx-audio/tree/main/mlx_audio/stt/models/qwen3_asr).

Input is decoded to a temporary mono WAV by the app. The worker reads at most
20 seconds at a time, resamples to 16 kHz, then emits finalized chunk text as JSONL
on stdout. Diagnostics go to stderr. Times describe input chunks, not exact speech
boundaries; `timestampGranularity=chunk` records that distinction. Confidence is
unavailable. Completely silent chunks are skipped. Hitting the decoding token
limit returns an error rather than silently accepting a truncated chunk.

Temporary normalized audio is deleted on ordinary success, failure or cancellation.
Force-killing the app/OS can leave temporary files. Per-chunk transcripts already
saved in the output directory remain recoverable. MCP uses a dedicated process
group so cancellation reaches Scribird and its Qwen3 child without terminating a
user's live app.

The bundled `--live` worker loads its model before reporting readiness. The app sends
16 kHz mono Float32 chunks through stdin and receives JSONL results through stdout;
neither pipe is a network connection. English and Korean are explicit language prompts;
the combined live setting uses the model's automatic language detection. A source's model
is reused until recording stops. Empty results still complete their chunk, and malformed
responses, decoding limits and process failures are errors. Session boundaries wait for
preceding results to be persisted before later results enter the new transcript store.
