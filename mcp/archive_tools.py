"""Read Scribird archives without modifying meeting files."""

from __future__ import annotations

from collections import Counter
from datetime import date, datetime
import json
import math
import plistlib
import re
from pathlib import Path
from typing import Annotated, Any, Literal

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations
from pydantic import Field

from app_client import AppUnavailable, control_request


def absolute_directory(path: str) -> Path:
    directory = Path(path).expanduser()
    if not directory.is_absolute():
        raise ValueError("Use an absolute local directory path.")
    return directory


async def archive_root(output_root: str | None) -> Path:
    if output_root is not None:
        return absolute_directory(output_root)
    try:
        settings = await control_request("get_settings")
        root = settings.get("effectiveTranscriptRoot")
        if root:
            return absolute_directory(root)
    except AppUnavailable:
        preferences = Path.home() / "Library/Preferences/com.scribird.app.plist"
        try:
            with preferences.open("rb") as file:
                root = plistlib.load(file).get("transcriptRootPath")
            if isinstance(root, str) and root:
                return absolute_directory(root)
        except (FileNotFoundError, plistlib.InvalidFileException):
            pass
    return Path.home() / "Documents/Scribird"


def session_info(directory: Path) -> dict[str, Any]:
    imported = directory.name.startswith("import-") or (directory / "result.json").is_file()
    started = None
    match = re.fullmatch(r"(\d{4}-\d{2}-\d{2}_\d{6})(?:-[\da-fA-F-]{36})?", directory.name)
    if not imported and match:
        try:
            started = datetime.strptime(match[1], "%Y-%m-%d_%H%M%S")
        except ValueError:
            pass
    return {
        "sessionDirectory": str(directory),
        "kind": "import" if imported else "live",
        "recordingDate": started.date().isoformat() if started else None,
        "localStartedAt": started.isoformat() if started else None,
        "hasJSONL": (directory / "transcript.jsonl").is_file(),
        "hasMarkdown": (directory / "transcript.md").is_file(),
        "hasImportResult": (directory / "result.json").is_file(),
        "audioPaths": [str(directory / name) for name in ("meeting.m4a", "me.m4a", "remote.m4a") if (directory / name).is_file()],
    }


def pagination(offset: int, size: int, total: int) -> dict[str, Any]:
    next_offset = offset + size
    has_more = next_offset < total
    return {"total": total, "offset": offset, "hasMore": has_more,
            "nextOffset": next_offset if has_more else None}


def segment_times(segment: dict[str, Any]) -> tuple[int | float, int | float] | None:
    start, end = segment.get("start"), segment.get("end")
    if any(isinstance(value, bool) or not isinstance(value, (int, float)) for value in (start, end)):
        return None
    try:
        if math.isfinite(start) and math.isfinite(end) and 0 <= start <= end:
            return start, end
    except OverflowError:
        pass
    return None


def timecode(seconds: int | float | None) -> str | None:
    if seconds is None:
        return None
    hours, remainder = divmod(int(seconds), 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def register_archive_tools(mcp: FastMCP) -> None:
    read = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)

    @mcp.tool(annotations=read)
    async def list_sessions(
        output_root: str | None = None,
        kind: Literal["all", "live", "import"] = "all",
        offset: Annotated[int, Field(ge=0)] = 0,
        limit: Annotated[int, Field(ge=1, le=200)] = 50,
        recording_date: str | None = None,
    ) -> dict[str, Any]:
        """List saved/live session folders, newest modified first, with output paths.
        Defaults to the running app's effective save folder, or the saved preference
        when offline, then ~/Documents/Scribird. Supply output_root to inspect another
        root (including CLI/MCP file imports, which default to ~/Documents/Scribird).
        A Markdown file indicates a finalized snapshot, not that recording is idle.
        recording_date filters live recordings by YYYY-MM-DD in the recording
        machine's local folder name, never modification time; imports do not match.
        recordingDate/localStartedAt are null for imports or unrecognized names.
        localStartedAt has no timezone. Follow nextOffset until it is null.
        No session contents are returned here. Does not move, rename or delete files.
        """
        if recording_date is not None:
            if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", recording_date):
                raise ValueError("recording_date must be a valid YYYY-MM-DD date.")
            try:
                date.fromisoformat(recording_date)
            except ValueError as error:
                raise ValueError("recording_date must be a valid YYYY-MM-DD date.") from error
        root = await archive_root(output_root)
        if not root.exists():
            return {"outputRoot": str(root), **pagination(offset, 0, 0), "sessions": []}
        if not root.is_dir():
            raise ValueError("output_root is not a directory.")
        folders = []
        for directory in root.iterdir():
            if directory.is_symlink() or not directory.is_dir():
                continue
            if not any((directory / name).is_file() for name in ("transcript.jsonl", "transcript.md", "result.json")):
                continue
            info = session_info(directory)
            if ((kind == "all" or info["kind"] == kind)
                    and (recording_date is None or info["recordingDate"] == recording_date)):
                folders.append((directory.stat().st_mtime_ns, info))
        folders.sort(key=lambda item: (item[0], item[1]["sessionDirectory"]), reverse=True)
        page = [info for _, info in folders[offset:offset + limit]]
        return {"outputRoot": str(root), **pagination(offset, len(page), len(folders)), "sessions": page}

    @mcp.tool(annotations=read)
    async def read_session(
        session_directory: str,
        offset: Annotated[int, Field(ge=0)] = 0,
        limit: Annotated[int, Field(ge=1, le=1000)] = 200,
    ) -> dict[str, Any]:
        """Read a page of persisted transcript.jsonl from a session/import directory.
        Returns text, timed segments and saved paths. Speakers are me/remote for live
        capture and unknown for imports. A trailing incomplete JSONL line is omitted
        and reported explicitly; malformed complete lines are errors. Files are read
        only, including when the app is closed. Pending on-screen speech is available
        separately through get_live_transcript. Markdown paths may not exist until stop.
        Follow nextOffset for paging. citationLabels match this page's segments in
        order and contain the source line and whole-second timecodes. transcriptSummary
        covers all complete records, not just this page. Its span includes gaps and
        overlap, not summed speech or audio duration; missing/invalid times are counted.
        """
        directory = absolute_directory(session_directory)
        if not directory.is_dir():
            raise ValueError("session_directory must be an existing directory.")
        path = directory / "transcript.jsonl"
        if not path.is_file() or path.is_symlink():
            raise ValueError("This session has no regular transcript.jsonl file.")
        segments = []
        citations = []
        total = 0
        incomplete = False
        labels: Counter[str] = Counter()
        granularities: set[str] = set()
        first_start = last_end = None
        invalid_times = 0
        with path.open("rb") as file:
            while line := file.readline(2 * 1024 * 1024 + 1):
                if len(line) > 2 * 1024 * 1024:
                    raise ValueError("A transcript line exceeds the 2 MiB read limit.")
                if not line.endswith(b"\n"):
                    incomplete = True
                    break
                try:
                    segment = json.loads(line)
                    if not isinstance(segment, dict) or not isinstance(segment.get("text"), str):
                        raise ValueError("Missing text")
                    if segment.get("speaker") not in ("me", "remote", "unknown"):
                        raise ValueError("Invalid speaker")
                except (ValueError, UnicodeDecodeError) as error:
                    raise ValueError(f"Malformed transcript.jsonl at line {total + 1}.") from error
                labels[segment["speaker"]] += 1
                granularity = segment.get("timestampGranularity")
                if isinstance(granularity, str) and granularity:
                    granularities.add(granularity)
                times = segment_times(segment)
                if times is None:
                    invalid_times += 1
                else:
                    start, end = times
                    first_start = start if first_start is None else min(first_start, start)
                    last_end = end if last_end is None else max(last_end, end)
                if offset <= total < offset + limit:
                    segments.append(segment)
                    stamp = f"{timecode(times[0])}–{timecode(times[1])}" if times else "time unavailable"
                    citations.append(f"L{total + 1} [{stamp}]")
                total += 1
        info = session_info(directory)
        span = last_end - first_start if first_start is not None else None
        return {**info, "jsonlPath": str(path), "markdownPath": str(directory / "transcript.md"),
                **pagination(offset, len(segments), total),
                "incompleteTrailingLine": incomplete,
                "citationLabels": citations,
                "transcriptSummary": {
                    "labelCounts": dict(labels), "firstStartSeconds": first_start,
                    "lastEndSeconds": last_end, "spanSeconds": span,
                    "firstStartTimecode": timecode(first_start), "lastEndTimecode": timecode(last_end),
                    "spanTimecode": timecode(span), "missingOrInvalidTimingCount": invalid_times,
                    "timestampGranularities": sorted(granularities),
                },
                "text": "\n".join(segment["text"] for segment in segments), "segments": segments}
