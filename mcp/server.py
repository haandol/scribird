"""Scribird's local stdio MCP adapter. Transcript tools return text to the client."""

from __future__ import annotations

import asyncio
import json
import os
import signal
import tempfile
from pathlib import Path
from typing import Annotated, Literal

from mcp.server.fastmcp import Context, FastMCP
from mcp.types import ToolAnnotations
from pydantic import BaseModel, Field


class TranscriptSegment(BaseModel):
    id: str
    speaker: Literal["unknown"]
    start: float
    end: float
    text: str
    confidence: float | None = None
    locale: str


class TranscriptionResult(BaseModel):
    sourcePath: str
    durationSeconds: float
    language: Literal["english", "korean"]
    text: str
    segments: list[TranscriptSegment]
    outputDirectory: str
    jsonlPath: str
    markdownPath: str
    engine: Literal["speech-analyzer", "qwen3"]
    model: Annotated[str, Field(min_length=1)]
    timestampGranularity: Literal["utterance", "chunk"]


mcp = FastMCP("Scribird", instructions=(
    "Control the running Scribird app and read saved sessions on this Mac. "
    "Use get_app_status/get_settings before changes. Live language auto means Korean + English. "
    "Transcribe local audio or video files on macOS 26 using SpeechAnalyzer or Qwen3 MLX. "
    "No audio uploads. File speakers are unknown; this tool does not diarize."
))


def executable_path() -> Path:
    """Select an explicit or installed worker without changing the user's running app."""
    configured = os.environ.get("SCRIBIRD_EXECUTABLE")
    if configured:
        candidates = [Path(configured).expanduser()]
    else:
        candidates = [
            Path(__file__).resolve().parents[1] / "build/Scribird.app/Contents/MacOS/Scribird",
            Path("/Applications/Scribird.app/Contents/MacOS/Scribird"),
        ]
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise ValueError("Build Scribird with ./build.sh release or set SCRIBIRD_EXECUTABLE to its executable.")


async def stop_process(process: asyncio.subprocess.Process) -> None:
    """Stop only this call's process group and allow its temporary-audio cleanup to finish."""
    if process.returncode is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        # Give Scribird time to reap its worker (3s forced-stop fallback) and
        # remove temporary audio before escalating the whole group to SIGKILL.
        await asyncio.wait_for(process.communicate(), timeout=10)
    except TimeoutError:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        await process.communicate()


def commit_result(result: TranscriptionResult) -> None:
    """Commit completion after this MCP call receives and validates the worker result."""
    directory = Path(result.outputDirectory)
    for path in [result.jsonlPath, result.markdownPath]:
        artifact = Path(path)
        if artifact.parent.resolve() != directory.resolve() or not artifact.is_file():
            raise ValueError("Scribird returned a result without its saved transcript files.")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=directory, prefix=".result-", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(result.model_dump_json().encode())
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(directory / "result.json")
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


@mcp.tool(annotations=ToolAnnotations(
    readOnlyHint=False, destructiveHint=False, idempotentHint=False, openWorldHint=True
))
async def transcribe_audio(
    file_path: str,
    language: Literal["english", "korean"] = "english",
    output_root: str | None = None,
    engine: Literal["speech-analyzer", "qwen3"] = "speech-analyzer",
    timeout_seconds: Annotated[int, Field(ge=1, le=3600)] = 600,
    ctx: Context | None = None,
) -> TranscriptionResult:
    """Transcribe local audio (MP3/M4A/WAV/AIFF/CAF) or video (MP4/MOV) without playing it.

    For video, extracts only the first audio track and preserves the original video
    timeline, including leading silence and gaps. Videos without audio are errors.
    Audio is prepared as temporary WAV; no separate MP3 export is created.

    file_path must be an absolute path on this Mac (or start with ~).
    For speech-analyzer, install the language model in Scribird settings first.
    qwen3 uses Alkd/Qwen3-ASR-1.7B-MLX-8bit on Apple Silicon; first use downloads
    its Python/MLX runtime and model (about 2.3 GB), then runs locally from cache.
    Qwen3 timestamps cover audio chunks up to 20 seconds, not utterance boundaries.
    Each call creates a new import directory containing transcript.jsonl,
    transcript.md and result.json. output_root defaults to ~/Documents/Scribird.
    Returns the full text, timed segments with speaker='unknown', and saved paths.
    Silent audio succeeds with empty text/segments. Invalid files, missing models,
    write failures and timeouts are tool errors. Cancellation/timeout stops the
    child process; any already-written partial JSONL remains in the output root.
    Use a matching MCP client timeout for long files. No audio uploads or capture
    permissions; initial Qwen3 setup downloads public model/runtime files.
    """
    source = Path(file_path).expanduser()
    if not source.is_absolute() or not source.is_file():
        raise ValueError("file_path must be an existing absolute local file path.")
    if language not in ("english", "korean"):
        raise ValueError("language must be english or korean.")
    if engine not in ("speech-analyzer", "qwen3"):
        raise ValueError("engine must be speech-analyzer or qwen3.")
    if not 1 <= timeout_seconds <= 3600:
        raise ValueError("timeout_seconds must be between 1 and 3600.")
    command = [str(executable_path()), "--transcribe", str(source), "--language", language,
               "--engine", engine]
    if output_root is not None:
        root = Path(output_root).expanduser()
        if not root.is_absolute():
            raise ValueError("output_root must be an absolute local directory path.")
        command.extend(["--output-root", str(root)])
    if ctx:
        await ctx.report_progress(progress=0, total=1, message="Transcribing audio locally")
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout_seconds
    environment = dict(os.environ)
    # A worker cannot decide whether its response reached this coordinator before
    # the MCP deadline. Defer the completion marker until collection succeeds.
    environment["_SCRIBIRD_MCP_DEFER_COMPLETION"] = "1"
    process = await asyncio.create_subprocess_exec(
        *command, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        start_new_session=True,
        env=environment,
    )
    try:
        stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=max(0, deadline - loop.time()))
    except TimeoutError as error:
        await asyncio.shield(stop_process(process))
        raise ValueError(f"Transcription exceeded {timeout_seconds} seconds. Any partial JSONL is retained in the output root.") from error
    except BaseException:
        await asyncio.shield(stop_process(process))
        raise
    if process.returncode != 0:
        message = stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(message or f"Scribird exited with code {process.returncode}.")
    try:
        result = TranscriptionResult.model_validate(json.loads(stdout))
    except (ValueError, TypeError) as error:
        raise ValueError("Scribird returned an invalid result; rebuild it with file transcription support.") from error
    if ctx:
        await ctx.report_progress(progress=1, total=1, message="Finalizing saved transcript")
    if loop.time() >= deadline:
        raise ValueError(f"Transcription exceeded {timeout_seconds} seconds. Any partial JSONL is retained in the output root.")
    # No await between committing and returning: a cancellation observed before
    # this point leaves no marker; completion is committed as one local action.
    commit_result(result)
    if loop.time() >= deadline:
        (Path(result.outputDirectory) / "result.json").unlink(missing_ok=True)
        raise ValueError(f"Transcription exceeded {timeout_seconds} seconds while saving its result.")
    return result


from live_tools import register_live_tools
from archive_tools import register_archive_tools

register_live_tools(mcp, executable_path)
register_archive_tools(mcp)


if __name__ == "__main__":
    mcp.run(transport="stdio")
