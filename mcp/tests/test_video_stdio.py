"""Exercise video extraction through the public MCP contract without media playback."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from datetime import timedelta

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


@unittest.skipUnless(os.environ.get("SCRIBIRD_VIDEO_FIXTURE_DIR"), "Set SCRIBIRD_VIDEO_FIXTURE_DIR to generated videos")
class VideoStdioTests(unittest.IsolatedAsyncioTestCase):
    async def test_video_transcription_preservesMediaAndTimelineForBothEngines(self):
        """Public tool results must identify the original video and include its final speech."""
        source = Path(os.environ["SCRIBIRD_VIDEO_FIXTURE_DIR"])
        parameters = StdioServerParameters(command=sys.executable,
            args=[str(Path(__file__).resolve().parents[1] / "server.py")], env=dict(os.environ))
        engines = ["speech-analyzer"]
        if os.environ.get("SCRIBIRD_QWEN_TESTS") == "1" and os.environ.get("HF_HUB_OFFLINE") == "1":
            engines.append("qwen3")
        evidence = []
        with tempfile.TemporaryDirectory(prefix="scribird-video-mcp-") as root:
            async with stdio_client(parameters) as (read, write):
                async with ClientSession(read, write, read_timeout_seconds=timedelta(seconds=120)) as client:
                    await client.initialize()
                    for engine in engines:
                        antiphase = source / "antiphase.wav"
                        if antiphase.exists():
                            response = await client.call_tool("transcribe_audio", {
                                "file_path": str(antiphase), "engine": engine, "output_root": root,
                            })
                            self.assertFalse(response.isError, response.content)
                            self.assertIn("final transcript", response.structuredContent["text"].lower())
                        videos = [source / "offset.mp4", source / "offset.mov"]
                        if (source / "antiphase.mp4").exists():
                            videos.append(source / "antiphase.mp4")
                        for video in videos:
                            original = video.read_bytes()
                            response = await client.call_tool("transcribe_audio", {
                                "file_path": str(video), "engine": engine, "output_root": root,
                            })
                            self.assertFalse(response.isError, response.content)
                            result = response.structuredContent
                            self.assertEqual(result["sourcePath"], str(video))
                            self.assertAlmostEqual(result["durationSeconds"], 12, places=3)
                            self.assertIn("final transcript", result["text"].lower())
                            self.assertTrue(result["model"])
                            self.assertTrue(all(0 <= s["start"] <= s["end"] <= 12 for s in result["segments"]))
                            self.assertEqual(video.read_bytes(), original)
                            self.assertEqual(sorted(p.name for p in Path(result["outputDirectory"]).iterdir()),
                                             ["result.json", "transcript.jsonl", "transcript.md"])
                            evidence.append({"engine": engine, "video": video.name, "status": "passed"})
                    response = await client.call_tool("transcribe_audio", {
                        "file_path": str(source / "no-audio.mp4"), "output_root": root,
                    })
                    self.assertTrue(response.isError)
        print(json.dumps(evidence))
