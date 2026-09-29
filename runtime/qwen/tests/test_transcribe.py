"""Check model-cache and chunk-completion contracts without downloading or running a model."""
import tempfile
import base64
import json
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import sys

import numpy as np
import soundfile as sf
from huggingface_hub.errors import LocalEntryNotFoundError

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import transcribe as worker


class QwenWorkerTests(unittest.TestCase):
    def test_liveChunks_reuseModelAndPreserveExplicitOrAutomaticLanguage(self):
        """Two independent chunks load once, with auto detection reserved for the mixed setting."""
        from unittest.mock import Mock
        model = Mock()
        model.generate.return_value = SimpleNamespace(text="recognized", generation_tokens=1)
        audio = base64.b64encode(np.full(1600, 0.1, dtype="<f4").tobytes()).decode()
        requests = [json.dumps({"audio": audio, "language": language}) for language in ["english", "auto"]]
        events = []
        with patch.object(worker, "model_directory", return_value=self.snapshot), \
             patch("mlx_audio.stt.load", return_value=model) as load:
            worker.live(requests, events.append)
        load.assert_called_once()
        self.assertEqual([c.kwargs["language"] for c in model.generate.call_args_list], ["English", None])
        self.assertEqual(events, [{"event": "ready"}, {"event": "result", "text": "recognized"},
                                  {"event": "result", "text": "recognized"}])

    def setUp(self):
        """Keep all generated cache and media under a private disposable root."""
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.snapshot = self.root / "snapshot"
        self.snapshot.mkdir()
        for name in worker.MODEL_FILES:
            (self.snapshot / name).write_bytes(b"test asset")

    def test_completeCachedModel_usesPinnedLocalSnapshotWithoutNetworkLookup(self):
        """A ready model must be reused locally with the exact selected repository and revision."""
        with patch("huggingface_hub.snapshot_download", return_value=str(self.snapshot)) as download, \
             patch.object(Path, "home", return_value=self.root):
            directory = worker.model_directory()
        download.assert_called_once_with(
            "Alkd/Qwen3-ASR-1.7B-MLX-8bit", revision=worker.MODEL_REVISION,
            allow_patterns=worker.MODEL_FILES, local_files_only=True,
        )
        self.assertTrue((directory / "model.safetensors").is_symlink())
        self.assertTrue((directory / "preprocessor_config.json").is_file())

    def test_missingCache_downloadsOnlyPinnedModelAssets(self):
        """Initial setup may fetch model files, but no media path or audio enters the request."""
        with patch("huggingface_hub.snapshot_download", side_effect=[
            LocalEntryNotFoundError("missing"), str(self.snapshot)
        ]) as download, patch.object(Path, "home", return_value=self.root):
            worker.model_directory()
        self.assertEqual(download.call_count, 2)
        self.assertEqual(download.call_args.args, (worker.MODEL_ID,))
        self.assertEqual(download.call_args.kwargs, {
            "revision": worker.MODEL_REVISION, "allow_patterns": worker.MODEL_FILES,
        })

    def test_multiChunkAudio_emitsContiguousOriginalTimesAndCompletion(self):
        """Chunking must neither lose trailing audio nor reset subsequent chunk timestamps."""
        audio = self.root / "audio.wav"
        sf.write(audio, np.full(21 * 16000, 0.1, dtype=np.float32), 16000, subtype="FLOAT")
        model = SimpleNamespace(generate=lambda *a, **k: SimpleNamespace(text="recognized", generation_tokens=1))
        events = []
        with patch.object(worker, "model_directory", return_value=self.snapshot), \
             patch("mlx_audio.stt.load", return_value=model):
            worker.transcribe(str(audio), "english", events.append)
        self.assertEqual([(e["start"], e["end"]) for e in events if e["event"] == "segment"], [(0, 20), (20, 21)])
        self.assertEqual(events[-1], {"event": "complete"})

    def test_silentAudio_doesNotInvokeGenerationAndCompletesEmpty(self):
        """Complete silence must not become a generated sentence."""
        audio = self.root / "silence.wav"
        sf.write(audio, np.zeros(16000, dtype=np.float32), 16000, subtype="FLOAT")
        def unexpected(*args, **kwargs):
            """Make model invocation on silence an observable test failure."""
            self.fail("Silent audio reached model generation")
        events = []
        with patch.object(worker, "model_directory", return_value=self.snapshot), \
             patch("mlx_audio.stt.load", return_value=SimpleNamespace(generate=unexpected)):
            worker.transcribe(str(audio), "english", events.append)
        self.assertEqual(events, [{"event": "complete"}])

    def test_decodingLimit_doesNotEmitTruncatedSegmentOrCompletion(self):
        """A token-limit stop must be reported as failure, not a valid shortened transcript."""
        audio = self.root / "audio.wav"
        sf.write(audio, np.full(16000, 0.1, dtype=np.float32), 16000, subtype="FLOAT")
        model = SimpleNamespace(generate=lambda *a, **k: SimpleNamespace(text="truncated", generation_tokens=1024))
        events = []
        with patch.object(worker, "model_directory", return_value=self.snapshot), \
             patch("mlx_audio.stt.load", return_value=model):
            with self.assertRaisesRegex(RuntimeError, "decoding limit"):
                worker.transcribe(str(audio), "english", events.append)
        self.assertEqual(events, [])


if __name__ == "__main__":
    unittest.main()
