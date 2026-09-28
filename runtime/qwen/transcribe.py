"""Pinned local Qwen3 inference; stdout is a JSONL protocol, diagnostics use stderr."""
import argparse
import contextlib
import json
import math
import os
import signal
from pathlib import Path
import sys
import uuid

os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["DO_NOT_TRACK"] = "1"

MODEL_ID = "Alkd/Qwen3-ASR-1.7B-MLX-8bit"
MODEL_REVISION = "b85224831c8109b261947e4c6daf5e89823f9c76"
MODEL_FILES = ["config.json", "model.safetensors", "model.safetensors.index.json",
               "tokenizer_config.json", "vocab.json", "merges.txt"]


def model_directory():
    from huggingface_hub import snapshot_download
    from huggingface_hub.errors import LocalEntryNotFoundError
    try:
        snapshot = snapshot_download(MODEL_ID, revision=MODEL_REVISION,
                                     allow_patterns=MODEL_FILES, local_files_only=True)
        if not all((Path(snapshot) / name).is_file() for name in MODEL_FILES):
            raise LocalEntryNotFoundError("The cached model is incomplete")
    except LocalEntryNotFoundError:
        print("Downloading " + MODEL_ID + " (first use)", file=sys.stderr, flush=True)
        snapshot = snapshot_download(MODEL_ID, revision=MODEL_REVISION, allow_patterns=MODEL_FILES)
    # 이 변환본에는 전처리 설정이 없어 공식 원본의 설정을 함께 제공한다.
    # HF 스냅샷과 가중치는 변경하지 않고 별도 디렉터리에서 참조한다.
    directory = Path.home() / "Library/Application Support/Scribird/Qwen3" / MODEL_REVISION
    directory.mkdir(parents=True, exist_ok=True)
    for name in MODEL_FILES:
        target = directory / name
        if not target.exists():
            try:
                target.symlink_to(Path(snapshot) / name)
            except FileExistsError:
                pass
    config = Path(__file__).with_name("preprocessor_config.json").read_bytes()
    target = directory / "preprocessor_config.json"
    if not target.exists():
        temporary = directory / ("preprocessor-" + str(uuid.uuid4()) + ".tmp")
        temporary.write_bytes(config)
        temporary.replace(target)
    return directory


def transcribe(audio_path, language, emit):
    import numpy as np
    import soundfile as sf
    from scipy.signal import resample_poly
    from mlx_audio.stt import load

    model = load(str(model_directory()))
    with sf.SoundFile(audio_path) as audio:
        sample_rate = audio.samplerate
        offset = 0
        while True:
            samples = audio.read(sample_rate * 20, dtype="float32", always_2d=True)
            if not len(samples):
                break
            frames = len(samples)
            mono = samples.mean(axis=1)
            # 완전 무음에서 생성 모델이 만들어 낸 문장을 결과로 저장하지 않는다.
            if np.max(np.abs(mono)) > 1e-7:
                divisor = math.gcd(sample_rate, 16000)
                if sample_rate != 16000:
                    mono = resample_poly(mono, 16000 // divisor, sample_rate // divisor).astype(np.float32)
                result = model.generate(mono, language=language.title(), max_tokens=1024, verbose=False)
                if result.generation_tokens >= 1024:
                    raise RuntimeError("Qwen3 reached the decoding limit; the chunk was not saved as a complete transcript.")
                text = result.text.strip()
                if text:
                    emit({"event": "segment", "start": offset / sample_rate,
                          "end": (offset + frames) / sample_rate, "text": text})
            offset += frames
    emit({"event": "complete"})


def main():
    # Swift의 신호 수신기는 SIG_IGN을 사용한다. 상속된 무시 상태를 해제해야
    # 취소 요청으로 이 자식이 종료되고 부모가 임시 오디오를 정리할 수 있다.
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    signal.signal(signal.SIGINT, signal.default_int_handler)
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", required=True)
    parser.add_argument("--language", choices=["english", "korean"], required=True)
    args = parser.parse_args()
    protocol = sys.stdout
    def emit(event):
        protocol.write(json.dumps(event, ensure_ascii=False) + "\n")
        protocol.flush()
    try:
        with contextlib.redirect_stdout(sys.stderr):
            transcribe(args.audio, args.language, emit)
    except Exception as error:
        print(f"Qwen3 transcription failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
