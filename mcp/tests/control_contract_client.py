"""Invoked by the Swift lifecycle test: real MCP/Unix transport, fake capture only."""
import asyncio
from datetime import timedelta
import json
import os
from pathlib import Path
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def main():
    socket, root = sys.argv[1:]
    params = StdioServerParameters(command=sys.executable,
        args=[str(Path(__file__).resolve().parents[1] / "server.py")],
        env={**os.environ, "SCRIBIRD_CONTROL_SOCKET": socket})
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write, read_timeout_seconds=timedelta(seconds=10)) as client:
            await client.initialize()
            tools = {tool.name: tool for tool in (await client.list_tools()).tools}
            assert len(tools) == 23, list(tools)
            assert tools["set_recording_language"].inputSchema["properties"]["language"]["enum"] == ["english", "korean", "auto"]

            async def call(name, args=None, error=False):
                response = await client.call_tool(name, args or {})
                assert bool(response.isError) == error, (name, response)
                return response.structuredContent

            initial = await call("get_app_status")
            assert initial["state"] == "idle"
            assert set(initial["commands"]) == set(tools) - {"transcribe_audio", "launch_app", "list_sessions", "read_session"}
            assert set((await call("get_speech_models"))["availableLanguages"]) == {"english", "korean", "auto"}
            await call("set_recording_preferences", {"saves_audio": False, "opens_folder_on_stop": False})
            await call("set_transcript_root", {"path": root})
            started = await call("start_recording", {"language": "auto"})
            first = started["currentSessionDirectory"]
            assert started["language"] == "auto" and started["state"] == "recording"
            for language in ("korean", "english", "auto"):
                result = await call("set_recording_language", {"language": language})
                assert result["language"] == language and result["currentSessionDirectory"] == first
            await call("set_transcript_root", {"path": root}, error=True)
            await call("set_recording_preferences", {"saves_audio": True}, error=True)
            await call("set_recording_language", {"language": "japanese"}, error=True)
            await call("get_live_transcript", {"limit": -1}, error=True)
            await call("get_live_transcript")
            await call("list_audio_devices")
            await call("select_audio_device", {"source": "microphone", "uid": "missing-uid"}, error=True)
            rotated = await call("start_new_session")
            assert rotated["currentSessionDirectory"] != first
            stopped = await call("stop_recording")
            assert stopped["state"] == "idle" and stopped["currentSessionDirectory"] is None
            assert Path(first, "transcript.md").is_file()
            assert Path(stopped["lastSessionDirectory"], "transcript.md").is_file()
            assert (await call("list_sessions", {"output_root": root}))["total"] == 2
            assert (await call("read_session", {"session_directory": first}))["segments"] == []
            await call("set_microphone_muted", {"muted": True}, error=True)
            print(json.dumps({"tools": len(tools), "languageModes": 3, "sessions": 2, "status": "passed"}))


if __name__ == "__main__":
    asyncio.run(asyncio.wait_for(main(), timeout=30))
