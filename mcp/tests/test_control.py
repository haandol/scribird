import asyncio
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import server
import app_client


class LiveTransportTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sc-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.socket = str(Path(self.temp.name) / "control.sock")
        self.env = patch.dict(os.environ, {"SCRIBIRD_CONTROL_SOCKET": self.socket})
        self.env.start()
        self.addCleanup(self.env.stop)

    async def host(self, handler):
        listener = await asyncio.start_unix_server(handler, self.socket)
        self.addAsyncCleanup(listener.wait_closed)
        self.addCleanup(listener.close)
        return listener

    async def test_fragmented_reply_and_unicode_arguments_round_trip(self):
        captured = []

        async def reply(reader, writer):
            captured.append(json.loads(await reader.readline()))
            writer.write(b'{"result":')
            await writer.drain()
            writer.write(b'{"state":"recording"}}\n')
            await writer.drain()
            writer.close()

        await self.host(reply)
        result = await app_client.control_request("set_transcript_root", {"path": "/tmp/회의 $(literal)"})
        self.assertEqual(result, {"state": "recording"})
        self.assertEqual(captured[0]["arguments"]["path"], "/tmp/회의 $(literal)")

    async def test_server_error_propagates_and_is_not_retried(self):
        requests = []

        async def reply(reader, writer):
            requests.append(await reader.readline())
            writer.write(b'{"error":"model missing"}\n')
            await writer.drain()
            writer.close()

        await self.host(reply)
        with self.assertRaisesRegex(ValueError, "model missing"):
            await app_client.control_request("set_recording_language", {"language": "auto"})
        self.assertEqual(len(requests), 1)

    async def test_missing_app_is_actionable(self):
        with self.assertRaises(app_client.AppUnavailable):
            await app_client.control_request("get_app_status")

    async def test_timeout_warns_of_unknown_outcome_and_does_not_repeat(self):
        received = []
        finished = asyncio.Event()

        async def reply(reader, writer):
            received.append(await reader.readline())
            await reader.read()
            writer.close()
            finished.set()

        await self.host(reply)
        with self.assertRaisesRegex(ValueError, "may still finish"):
            await app_client.control_request("start_new_session", timeout=0.01)
        await asyncio.wait_for(finished.wait(), 1)
        self.assertEqual(len(received), 1)

    async def test_discovery_rejects_multiple_instances_without_sending_a_command(self):
        clients = []

        async def reply(reader, writer):
            clients.append(await reader.read())
            writer.close()

        first = await asyncio.start_unix_server(reply, self.socket)
        second_path = str(Path(self.temp.name) / "second.sock")
        second = await asyncio.start_unix_server(reply, second_path)
        try:
            with patch.dict(os.environ, {}, clear=True), \
                 patch.object(app_client.Path, "lstat", return_value=Path(self.temp.name).lstat()), \
                 patch.object(app_client.stat, "S_ISSOCK", return_value=True), \
                 patch.object(app_client.Path, "glob", return_value=[Path(self.socket), Path(second_path)]):
                with self.assertRaisesRegex(ValueError, "Multiple Scribird"):
                    await app_client.control_request("start_recording")
        finally:
            first.close()
            second.close()
            await first.wait_closed()
            await second.wait_closed()
        self.assertTrue(all(not data for data in clients))

    async def test_tools_have_languages_bounds_and_correct_network_hints(self):
        tools = {tool.name: tool for tool in await server.mcp.list_tools()}
        self.assertEqual(len(tools), 23)
        language = tools["set_recording_language"].inputSchema["properties"]["language"]
        self.assertEqual(language["enum"], ["english", "korean", "auto"])
        self.assertTrue(tools["get_app_status"].annotations.readOnlyHint)
        self.assertFalse(tools["start_new_session"].annotations.idempotentHint)
        for name in ("launch_app", "install_speech_model", "check_for_updates", "transcribe_audio"):
            self.assertTrue(tools[name].annotations.openWorldHint, name)
        for name in ("get_settings", "set_recording_language", "list_sessions", "read_session"):
            self.assertFalse(tools[name].annotations.openWorldHint, name)
        self.assertEqual(tools["get_live_transcript"].inputSchema["properties"]["limit"]["maximum"], 1000)


class ArchiveTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.live = self.root / "2026-09-28_120000"
        self.live.mkdir()
        self.imported = self.root / "import-test"
        self.imported.mkdir()
        self.lines = [dict(id=str(i), speaker="remote", start=i, end=i + 1, text=f"sentence {i}") for i in range(3)]
        self.jsonl = self.live / "transcript.jsonl"
        self.jsonl.write_text("".join(json.dumps(line) + "\n" for line in self.lines))
        (self.imported / "transcript.jsonl").write_text("")
        (self.imported / "result.json").write_text("{}")

    async def call(self, name, args):
        _, result = await server.mcp.call_tool(name, args)
        return result

    async def test_saved_sessions_pagination_filter_and_paths(self):
        result = await self.call("list_sessions", {"output_root": str(self.root), "limit": 1})
        self.assertEqual(result["total"], 2)
        self.assertTrue(result["hasMore"])
        result = await self.call("list_sessions", {"output_root": str(self.root), "kind": "live"})
        self.assertEqual(result["sessions"][0]["sessionDirectory"], str(self.live))
        self.assertEqual(result["total"], 1)

    async def test_paginated_read_keeps_original_file_and_reports_partial_tail(self):
        with self.jsonl.open("a") as file:
            file.write('{"text":"unfinished')
        original = self.jsonl.read_bytes()
        result = await self.call("read_session", {"session_directory": str(self.live), "offset": 1, "limit": 1})
        self.assertEqual(result["segments"], [self.lines[1]])
        self.assertEqual(result["text"], "sentence 1")
        self.assertTrue(result["hasMore"])
        self.assertTrue(result["incompleteTrailingLine"])
        self.assertEqual(self.jsonl.read_bytes(), original)

    async def test_complete_corrupt_line_is_not_silently_skipped(self):
        self.jsonl.write_text('{"text": broken}\n')
        with self.assertRaisesRegex(Exception, "Malformed.*line 1"):
            await self.call("read_session", {"session_directory": str(self.live)})

    async def test_missing_roots_and_relative_paths(self):
        result = await self.call("list_sessions", {"output_root": str(self.root / "missing")})
        self.assertEqual(result["sessions"], [])
        with self.assertRaisesRegex(Exception, "absolute"):
            await self.call("list_sessions", {"output_root": "relative"})


if __name__ == "__main__":
    unittest.main()
