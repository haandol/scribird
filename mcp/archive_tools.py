"""Read Scribird archives without modifying meeting files."""

from __future__ import annotations

import json
import plistlib
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
    return {
        "sessionDirectory": str(directory),
        "kind": "import" if imported else "live",
        "hasJSONL": (directory / "transcript.jsonl").is_file(),
        "hasMarkdown": (directory / "transcript.md").is_file(),
        "hasImportResult": (directory / "result.json").is_file(),
        "audioPaths": [str(directory / name) for name in ("meeting.m4a", "me.m4a", "remote.m4a") if (directory / name).is_file()],
    }


def register_archive_tools(mcp: FastMCP) -> None:
    read = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)

    @mcp.tool(annotations=read)
    async def list_sessions(
        output_root: str | None = None,
        kind: Literal["all", "live", "import"] = "all",
        offset: Annotated[int, Field(ge=0)] = 0,
        limit: Annotated[int, Field(ge=1, le=200)] = 50,
    ) -> dict[str, Any]:
        """List saved/live session folders, newest modified first, with output paths.
        Defaults to the running app's effective save folder, or the saved preference
        when offline, then ~/Documents/Scribird. Supply output_root to inspect another
        root (including CLI/MCP file imports, which default to ~/Documents/Scribird).
        A Markdown file indicates a finalized snapshot, not that recording is idle.
        No session contents are returned here. Does not move, rename or delete files.
        """
        root = await archive_root(output_root)
        if not root.exists():
            return {"outputRoot": str(root), "total": 0, "offset": offset, "hasMore": False, "sessions": []}
        if not root.is_dir():
            raise ValueError("output_root is not a directory.")
        folders = []
        for directory in root.iterdir():
            if directory.is_symlink() or not directory.is_dir():
                continue
            if not any((directory / name).is_file() for name in ("transcript.jsonl", "transcript.md", "result.json")):
                continue
            info = session_info(directory)
            if kind == "all" or info["kind"] == kind:
                folders.append((directory.stat().st_mtime_ns, info))
        folders.sort(key=lambda item: (item[0], item[1]["sessionDirectory"]), reverse=True)
        page = [info for _, info in folders[offset:offset + limit]]
        return {"outputRoot": str(root), "total": len(folders), "offset": offset,
                "hasMore": offset + len(page) < len(folders), "sessions": page}

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
        """
        directory = absolute_directory(session_directory)
        if not directory.is_dir():
            raise ValueError("session_directory must be an existing directory.")
        path = directory / "transcript.jsonl"
        if not path.is_file() or path.is_symlink():
            raise ValueError("This session has no regular transcript.jsonl file.")
        segments = []
        total = 0
        incomplete = False
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
                if offset <= total < offset + limit:
                    segments.append(segment)
                total += 1
        info = session_info(directory)
        return {**info, "jsonlPath": str(path), "markdownPath": str(directory / "transcript.md"),
                "total": total, "offset": offset, "hasMore": offset + len(segments) < total,
                "incompleteTrailingLine": incomplete,
                "text": "\n".join(segment["text"] for segment in segments), "segments": segments}
