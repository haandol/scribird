import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from datetime import timedelta

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


@unittest.skipUnless(os.environ.get("SCRIBIRD_FILE_FIXTURE"), "Set SCRIBIRD_FILE_FIXTURE to generated sample.mp3")
class StdioIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def test_client_initialization_tool_discovery_and_real_file_transcription(self):
        source = Path(os.environ["SCRIBIRD_FILE_FIXTURE"]).resolve()
        parameters = StdioServerParameters(
            command=sys.executable,
            args=[str(Path(__file__).resolve().parents[1] / "server.py")],
            env=dict(os.environ),
        )
        evidence = []
        with tempfile.TemporaryDirectory(prefix="scribird-mcp-e2e-") as output:
            async with stdio_client(parameters) as (read, write):
                async with ClientSession(read, write, read_timeout_seconds=timedelta(seconds=120)) as client:
                    await client.initialize()
                    tools = await client.list_tools()
                    self.assertIn("transcribe_audio", [tool.name for tool in tools.tools])
                    directories = set()
                    for fixture in [source, *[source.with_suffix(ext) for ext in [".wav", ".m4a", ".aiff", ".caf"]]]:
                        if not fixture.exists():
                            continue
                        original = fixture.read_bytes()
                        response = await client.call_tool("transcribe_audio", {
                            "file_path": str(fixture), "output_root": output,
                        })
                        self.assertFalse(response.isError, response.content)
                        result = response.structuredContent
                        self.assertIsNotNone(result)
                        self.assertIn("project meeting", result["text"].lower())
                        self.assertIn("final transcript", result["text"].lower())
                        self.assertTrue(all(s["speaker"] == "unknown" for s in result["segments"]))
                        self.assertNotIn(result["outputDirectory"], directories)
                        directories.add(result["outputDirectory"])
                        self.assertEqual(original, fixture.read_bytes())
                        persisted = [json.loads(line) for line in Path(result["jsonlPath"]).read_text().splitlines()]
                        self.assertEqual(len(persisted), len(result["segments"]))
                        self.assertIn("final transcript", Path(result["markdownPath"]).read_text().lower())
                        evidence.append({"format": fixture.suffix, "segments": len(persisted), "status": "passed"})
                    for name in ["broken.mp3", "missing.mp3"]:
                        response = await client.call_tool("transcribe_audio", {
                            "file_path": str(source.parent / name), "output_root": output,
                        })
                        self.assertTrue(response.isError)
                        evidence.append({"file": name, "status": "tool_error"})
                    silence = source.parent / "silence.wav"
                    if silence.exists():
                        response = await client.call_tool("transcribe_audio", {
                            "file_path": str(silence), "output_root": output,
                        })
                        self.assertFalse(response.isError, response.content)
                        self.assertEqual(response.structuredContent["text"], "")
                        self.assertEqual(response.structuredContent["segments"], [])
                        evidence.append({"file": "silence.wav", "status": "empty_success"})
                    korean = source.parent / "korean.mp3"
                    if korean.exists():
                        response = await client.call_tool("transcribe_audio", {
                            "file_path": str(korean), "language": "korean", "output_root": output,
                        })
                        self.assertFalse(response.isError, response.content)
                        self.assertIn("프로젝트", response.structuredContent["text"])
                        self.assertIn("마지막", response.structuredContent["text"])
                        evidence.append({"file": "korean.mp3", "status": "passed"})
                    if (os.environ.get("SCRIBIRD_QWEN_TESTS") == "1"
                            and os.environ.get("HF_HUB_OFFLINE") == "1"
                            and os.environ.get("SCRIBIRD_QWEN_PYTHON")):
                        for fixture, language, keyword in [(source, "english", "final transcript"),
                                                           (korean, "korean", "마지막")]:
                            response = await client.call_tool("transcribe_audio", {
                                "file_path": str(fixture), "language": language,
                                "engine": "qwen3", "output_root": output,
                            })
                            self.assertFalse(response.isError, response.content)
                            result = response.structuredContent
                            self.assertIn(keyword, result["text"].lower())
                            self.assertEqual(result["engine"], "qwen3")
                            self.assertEqual(result["model"], "Alkd/Qwen3-ASR-1.7B-MLX-8bit")
                            self.assertEqual(result["timestampGranularity"], "chunk")
                            evidence.append({"engine": "qwen3", "language": language, "status": "passed"})
                        temporary_audio = Path(tempfile.gettempdir())
                        before = set(temporary_audio.glob("scribird-audio-*"))
                        response = await client.call_tool("transcribe_audio", {
                            "file_path": str(source), "engine": "qwen3",
                            "output_root": output, "timeout_seconds": 1,
                        })
                        self.assertTrue(response.isError)
                        self.assertTrue(any("exceeded 1 seconds" in getattr(item, "text", "") for item in response.content))
                        self.assertEqual(set(temporary_audio.glob("scribird-audio-*")) - before, set())
                        evidence.append({"engine": "qwen3", "status": "timeout_and_temporary_audio_cleanup_passed"})
        print(json.dumps(evidence, ensure_ascii=False))
