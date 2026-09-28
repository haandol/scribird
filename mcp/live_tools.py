"""MCP controls for the running app, using its private local Unix socket."""

from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Annotated, Any, Literal

from mcp.server.fastmcp import FastMCP
from mcp.types import ToolAnnotations
from pydantic import Field


from app_client import AppUnavailable, control_request


def register_live_tools(mcp: FastMCP, executable_path) -> None:
    read = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)
    change = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=True, openWorldHint=False)
    action = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=False, openWorldHint=False)
    external = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=True, openWorldHint=True)

    @mcp.tool(annotations=external)
    async def launch_app() -> dict[str, Any]:
        """Launch the built Scribird app in the background, without starting a recording.

        Prefer get_app_status when already running. Live tools require the updated
        app; file transcription and saved-session reads work without it.
        macOS may install the mandatory English speech model at app launch.
        """
        try:
            return await control_request("get_app_status")
        except AppUnavailable:
            pass
        binary = executable_path()
        bundle = binary.parents[2]
        if bundle.suffix != ".app":
            raise ValueError("Live recording requires a signed .app bundle. Set SCRIBIRD_EXECUTABLE to its Contents/MacOS/Scribird executable.")
        process = await asyncio.create_subprocess_exec("/usr/bin/open", "-g", str(bundle),
                                                       stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        _, error = await process.communicate()
        if process.returncode:
            raise ValueError(error.decode(errors="replace").strip() or "Could not launch Scribird.")
        for _ in range(40):
            try:
                return await control_request("get_app_status")
            except AppUnavailable:
                await asyncio.sleep(0.25)
        raise AppUnavailable("Scribird launched but its control socket did not appear. An older running copy may need to be quit and the updated bundle reopened.")

    @mcp.tool(annotations=read)
    async def get_app_status() -> dict[str, Any]:
        """Read recording state, actual language, active sources/meters, warnings, paths,
        pending MCP operation, update-check result and the app's supported commands.
        'auto' means Korean + English together. Reading does not start recording.
        """
        return await control_request("get_app_status")

    @mcp.tool(annotations=action)
    async def start_recording(language: Literal["english", "korean", "auto"] | None = None) -> dict[str, Any]:
        """Start live microphone + system-audio recording using the app's capture paths.

        language selects English, Korean, or Korean + English ('auto'). Omission
        uses the app's saved language. Models must be installed first. Returns
        actual language, active sources and warnings; one source may be unavailable.
        If already recording, returns that session (different language is an error).
        """
        return await control_request("start_recording", {} if language is None else {"language": language}, timeout=120)

    @mcp.tool(annotations=change)
    async def stop_recording() -> dict[str, Any]:
        """Stop capture and await transcript/audio finalization. Returns saved paths.
        The app's opensFolderOnStop preference controls whether Finder opens.
        A timeout does not cancel finalization: inspect status before retrying.
        """
        return await control_request("stop_recording", timeout=120)

    @mcp.tool(annotations=action)
    async def start_new_session() -> dict[str, Any]:
        """While recording, finish the old archive and start a new one without stopping
        capture. When idle, clear the displayed transcript only; saved files remain.
        Do not retry blindly after a timeout: this action creates another boundary.
        """
        return await control_request("start_new_session", timeout=120)

    @mcp.tool(annotations=change)
    async def set_recording_language(language: Literal["english", "korean", "auto"]) -> dict[str, Any]:
        """Choose the live/saved meeting language, including during a recording.
        'auto' is Korean + English together and requires both models. The app drains
        pending text before detaching a language; capture, audio files and session
        stay open. Missing models or a failed switch are errors, not silent success.
        """
        return await control_request("set_recording_language", {"language": language}, timeout=120)

    @mcp.tool(annotations=change)
    async def set_microphone_muted(muted: bool) -> dict[str, Any]:
        """Set microphone mute explicitly during recording. Excludes microphone audio
        from transcription and saved audio; system audio continues. Does not change
        the system-wide microphone or other apps. No active microphone is an error.
        """
        return await control_request("set_microphone_muted", {"muted": muted})

    @mcp.tool(annotations=read)
    async def get_live_transcript(
        include_partial: bool = True,
        offset: Annotated[int, Field(ge=0)] = 0,
        limit: Annotated[int, Field(ge=1, le=1000)] = 200,
    ) -> dict[str, Any]:
        """Read a page of the current/last displayed transcript with source speakers
        me/remote and isFinal flags. Partial text can change. Offsets are for the
        current snapshot, not a stable event cursor; re-read after a language switch
        or session change. Use read_session for persisted, finalized archive text.
        """
        return await control_request("get_live_transcript", {"include_partial": include_partial, "offset": offset, "limit": limit})

    @mcp.tool(annotations=read)
    async def get_settings() -> dict[str, Any]:
        """Read actual app settings: meeting/interface language, output root, audio
        saving, open-folder preference, output locks and all three shortcuts.
        """
        return await control_request("get_settings")

    @mcp.tool(annotations=change)
    async def set_recording_preferences(saves_audio: bool | None = None, opens_folder_on_stop: bool | None = None) -> dict[str, Any]:
        """Save audio-retention and/or Finder-opening preferences. saves_audio may
        change only while idle/failed; opens_folder_on_stop may change during recording.
        A rejected combination changes neither setting. Omitted values are preserved.
        """
        arguments = {k: v for k, v in {"saves_audio": saves_audio, "opens_folder_on_stop": opens_folder_on_stop}.items() if v is not None}
        return await control_request("set_recording_preferences", arguments)

    @mcp.tool(annotations=change)
    async def set_transcript_root(path: str | None) -> dict[str, Any]:
        """Choose the folder for future live recordings, or null to restore default.
        Accepts an absolute local path or ~; only allowed while idle/failed. Does
        not move existing recordings. If the folder later becomes unusable, live
        recording uses the default folder and reports a warning while keeping the choice.
        """
        if path is not None:
            expanded = Path(path).expanduser()
            if not expanded.is_absolute():
                raise ValueError("path must be absolute, or null for the default folder.")
            path = str(expanded)
        return await control_request("set_transcript_root", {"path": path})

    @mcp.tool(annotations=change)
    async def set_interface_language(language: Literal["english", "korean"]) -> dict[str, Any]:
        """Change the app's display language immediately. Does not change the meeting's
        recognition language or the archive's fixed English headings/speaker labels.
        """
        return await control_request("set_interface_language", {"language": language})

    @mcp.tool(annotations=read)
    async def list_audio_devices() -> dict[str, Any]:
        """List direction-filtered microphone/system devices with stable UIDs,
        selected/default UIDs and missing-device fallback status. Does not change
        the Mac's default devices. Pass a listed UID to select_audio_device.
        """
        return await control_request("list_audio_devices")

    @mcp.tool(annotations=change)
    async def select_audio_device(source: Literal["microphone", "system"], uid: str | None) -> dict[str, Any]:
        """Pin Scribird's capture source to a listed device UID, or null to follow
        the system default. May reconnect only that source during recording without
        rotating the session. Does not alter macOS default audio devices. Inspect
        activeSources/warnings afterward; reconnect failures can disable one source.
        """
        return await control_request("select_audio_device", {"source": source, "uid": uid})

    @mcp.tool(annotations=read)
    async def get_speech_models() -> dict[str, Any]:
        """Refresh installed English/Korean SpeechAnalyzer models and available live
        language modes. Also poll installation states and errors. Does not download.
        """
        return await control_request("get_speech_models")

    @mcp.tool(annotations=external)
    async def install_speech_model(language: Literal["english", "korean"]) -> dict[str, Any]:
        """Request a macOS speech-model download for the selected language. Returns
        immediately; poll get_speech_models until installed or failed. Does not start
        recording or change the current meeting language. This is an explicit network
        download request; audio and transcripts are not uploaded. Qwen is separate.
        """
        return await control_request("install_speech_model", {"language": language})

    @mcp.tool(annotations=change)
    async def set_keyboard_shortcut(
        slot: Literal["transcript_window", "settings_window", "microphone_mute"],
        key_code: Annotated[int, Field(ge=0, le=127)] | None = None,
        modifiers: list[Literal["command", "option", "control", "shift"]] | None = None,
        reset: bool = False,
    ) -> dict[str, Any]:
        """Set one shortcut using a macOS physical key code and modifier names, or
        reset=true with no key_code/modifiers. Must include command/option/control;
        conflicts with another Scribird shortcut are rejected. Transcript-window
        shortcut is global; settings/mute shortcuts act only while Scribird has focus.
        Read get_settings for the saved combination and errors.
        """
        args = {"slot": slot, "reset": reset}
        if key_code is not None:
            args["key_code"] = key_code
        if modifiers is not None:
            args["modifiers"] = modifiers
        return await control_request("set_keyboard_shortcut", args)

    @mcp.tool(annotations=change)
    async def show_window(window: Literal["transcript", "settings", "file_transcription"]) -> dict[str, Any]:
        """Show the requested Scribird window. This explicit UI action may activate
        Scribird. Other live tools control app objects without keyboard/mouse input.
        """
        return await control_request("show_window", {"window": window})

    @mcp.tool(annotations=external)
    async def check_for_updates() -> dict[str, Any]:
        """Request one GitHub release check. Poll get_app_status.updates for the result.
        Does not download, install or restart the app and sends no meeting data.
        """
        return await control_request("check_for_updates")

    @mcp.tool(annotations=change)
    async def dismiss_error() -> dict[str, Any]:
        """Dismiss the recorder's failed state, retaining saved files. Does not retry
        recording or grant missing macOS permissions.
        """
        return await control_request("dismiss_error")
