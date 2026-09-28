import asyncio
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import server


class TranscriptionToolTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name) / "sample ; $(literal).mp3"
        self.source.write_bytes(b"test audio placeholder")
        self.result = {
            "sourcePath": str(self.source), "durationSeconds": 1,
            "language": "english", "text": "Last sentence.",
            "segments": [{"id": "test", "speaker": "unknown", "start": 0, "end": 1,
                          "text": "Last sentence.", "locale": "en_US"}],
            "outputDirectory": self.temp.name, "jsonlPath": str(Path(self.temp.name) / "transcript.jsonl"),
            "markdownPath": str(Path(self.temp.name) / "transcript.md"),
            "engine": "speech-analyzer", "timestampGranularity": "utterance",
            "model": "Apple SpeechTranscriber (en_US)",
        }
        Path(self.result["jsonlPath"]).write_text(json.dumps(self.result["segments"][0]) + "\n")
        Path(self.result["markdownPath"]).write_text("Last sentence.")

    async def test_paths_are_passed_as_arguments_without_a_shell(self):
        process = AsyncMock(returncode=0)
        process.communicate.return_value = (json.dumps(self.result).encode(), b"")
        with patch.object(server, "executable_path", return_value=Path("/tmp/Scribird")), \
             patch.object(server.asyncio, "create_subprocess_exec", return_value=process) as spawn:
            result = await server.transcribe_audio(str(self.source), output_root=self.temp.name)
        self.assertEqual(result.text, "Last sentence.")
        self.assertEqual(spawn.call_args.kwargs["env"]["_SCRIBIRD_MCP_DEFER_COMPLETION"], "1")
        self.assertTrue((Path(self.temp.name) / "result.json").is_file())
        self.assertEqual(spawn.call_args.args, (
            "/tmp/Scribird", "--transcribe", str(self.source), "--language", "english",
            "--engine", "speech-analyzer",
            "--output-root", self.temp.name,
        ))

    async def test_failures_are_tool_errors_instead_of_empty_success(self):
        for exit_code, output, error in [(1, b"", b"model missing"), (0, b"not JSON", b""), (0, b"{}", b"")]:
            with self.subTest(exit_code=exit_code, output=output):
                process = AsyncMock(returncode=exit_code)
                process.communicate.return_value = (output, error)
                with patch.object(server, "executable_path", return_value=Path("/tmp/Scribird")), \
                     patch.object(server.asyncio, "create_subprocess_exec", return_value=process):
                    with self.assertRaises(ValueError):
                        await server.transcribe_audio(str(self.source))

    async def test_invalid_paths_do_not_launch_process(self):
        with patch.object(server.asyncio, "create_subprocess_exec") as spawn:
            for path in ["relative.mp3", self.temp.name, "https://example.com/audio.mp3"]:
                with self.assertRaises(ValueError):
                    await server.transcribe_audio(path)
            with self.assertRaises(ValueError):
                await server.transcribe_audio(str(self.source), output_root="relative")
        spawn.assert_not_called()

    async def test_timeout_and_cancellation_stop_child(self):
        for failure in [TimeoutError(), asyncio.CancelledError()]:
            with self.subTest(failure=type(failure).__name__):
                process = AsyncMock(returncode=None)
                process.communicate.side_effect = failure
                with patch.object(server, "executable_path", return_value=Path("/tmp/Scribird")), \
                     patch.object(server.asyncio, "create_subprocess_exec", return_value=process), \
                     patch.object(server, "stop_process", new_callable=AsyncMock) as stop:
                    with self.assertRaises(ValueError if isinstance(failure, TimeoutError) else type(failure)):
                        await server.transcribe_audio(str(self.source))
                    stop.assert_awaited_once_with(process)

    async def test_tool_schema_exposes_validated_inputs_and_local_write_hints(self):
        tool = next(tool for tool in await server.mcp.list_tools() if tool.name == "transcribe_audio")
        self.assertEqual(tool.name, "transcribe_audio")
        self.assertEqual(tool.inputSchema["required"], ["file_path"])
        self.assertEqual(tool.inputSchema["properties"]["language"]["enum"], ["english", "korean"])
        self.assertEqual(tool.inputSchema["properties"]["engine"]["enum"], ["speech-analyzer", "qwen3"])
        self.assertFalse(tool.annotations.readOnlyHint)
        self.assertFalse(tool.annotations.destructiveHint)
        self.assertTrue(tool.annotations.openWorldHint)
        self.assertNotIn("ctx", tool.inputSchema["properties"])
        self.assertEqual(tool.inputSchema["properties"]["timeout_seconds"]["default"], 600)
        self.assertEqual(tool.inputSchema["properties"]["timeout_seconds"]["minimum"], 1)
        self.assertEqual(tool.inputSchema["properties"]["timeout_seconds"]["maximum"], 3600)

    async def test_timeoutAfterWorkerExit_doesNotCommitCompletion(self):
        """Even a worker that already exited cannot commit before the coordinator collects its response."""
        process = AsyncMock(returncode=0)
        process.communicate.side_effect = TimeoutError()
        with patch.object(server, "executable_path", return_value=Path("/tmp/Scribird")), \
             patch.object(server.asyncio, "create_subprocess_exec", return_value=process):
            with self.assertRaises(ValueError):
                await server.transcribe_audio(str(self.source))
        self.assertFalse((Path(self.temp.name) / "result.json").exists())

    async def test_cancellationAfterResultCollection_doesNotCommitCompletion(self):
        """Cancellation during the final async boundary must retain partial files without a marker."""
        process = AsyncMock(returncode=0)
        process.communicate.return_value = (json.dumps(self.result).encode(), b"")
        context = AsyncMock()
        context.report_progress.side_effect = [None, asyncio.CancelledError()]
        with patch.object(server, "executable_path", return_value=Path("/tmp/Scribird")), \
             patch.object(server.asyncio, "create_subprocess_exec", return_value=process):
            with self.assertRaises(asyncio.CancelledError):
                await server.transcribe_audio(str(self.source), ctx=context)
        self.assertFalse((Path(self.temp.name) / "result.json").exists())
        self.assertTrue(Path(self.result["jsonlPath"]).exists())

    def test_missingArtifact_cannotCreateCompletionMarker(self):
        """A valid-looking worker payload is insufficient when its promised document is missing."""
        Path(self.result["markdownPath"]).unlink()
        with self.assertRaises(ValueError):
            server.commit_result(server.TranscriptionResult.model_validate(self.result))
        self.assertFalse((Path(self.temp.name) / "result.json").exists())

    async def test_stop_process_terminates_and_reaps_real_child(self):
        process = await asyncio.create_subprocess_exec(
            sys.executable, "-c", "import time; time.sleep(60)", start_new_session=True
        )
        await server.stop_process(process)
        self.assertIsNotNone(process.returncode)


if __name__ == "__main__":
    unittest.main()
